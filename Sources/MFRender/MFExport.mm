// MotionForge — background video / image-sequence export.
//
// The exporter copies the project when it is created (cheap: baked tracks are shared), renders it
// with its own MetalRenderer on a serial queue and feeds AVAssetWriter (hardware H.264 / HEVC /
// ProRes). Motion-blur subframes are averaged on the GPU and frames come back as 8-bit BGRA, so
// the CPU only copies rows. The composition's audio layers (and an optional extra soundtrack) are
// mixed to PCM and encoded as AAC alongside.
#import "MFEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "MFAudioInternal.h"
#include "MFRender/MetalRenderer.hpp"
#include "mf/Audio.hpp"
#include "mf/Evaluator.hpp"

using namespace mf;

@interface MFEngine (Snapshot)
- (mf::Project)mf_projectSnapshot;
@end

@implementation MFExportSettings
- (instancetype)init {
    if ((self = [super init])) {
        _format = MFExportFormatH264;
        _scale = 1;
        _motionBlur = YES;
        _includeAudioLayers = YES;
    }
    return self;
}
@end

@interface MFExportProgress ()
@property(nonatomic, readwrite) NSInteger framesDone, framesTotal;
@property(nonatomic, readwrite) double elapsed, framesPerSecond;
@end
@implementation MFExportProgress
@end

namespace {

NSError* exportError(NSInteger code, const std::string& message) {
    return [NSError errorWithDomain:MFErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

// Every subframe of a motion-blurred frame, or just the one when nothing with blur on moves.
std::vector<FrameDesc> subframesAt(const Project& p, const Composition& c, double t, double scale,
                                   const std::vector<double>& offsets) {
    std::vector<FrameDesc> frames;
    for (double o : offsets) frames.push_back(evaluateFrame(p, c, t, scale, nullptr, o));
    for (const FrameDesc& f : frames)
        if (f.hash != frames[0].hash) return frames;
    frames.resize(1);
    return frames;
}

}  // namespace

@implementation MFVideoExporter {
    Project _project;
    ObjectId _comp;
    id<MTLDevice> _device;
    MFExportSettings* _settings;
    std::atomic<bool> _cancelled;
    dispatch_queue_t _queue;
}

- (instancetype)initWithEngine:(MFEngine*)engine settings:(MFExportSettings*)settings outputPath:(NSString*)path
                         error:(NSError**)error {
    if (!(self = [super init])) return nil;
    _project = [engine mf_projectSnapshot];
    _comp = _project.activeComposition;
    _device = engine.device;
    _settings = settings;
    _outputPath = [path copy];
    _cancelled = false;
    _queue = dispatch_queue_create("motionforge.export", DISPATCH_QUEUE_SERIAL);
    if (!_project.findComposition(_comp)) {
        if (error) *error = exportError(20, "No composition to export");
        return nil;
    }
    return self;
}

- (void)cancel {
    _cancelled = true;
}

- (void)startWithProgress:(void (^)(MFExportProgress*))progress completion:(void (^)(NSError*))completion {
    dispatch_async(_queue, ^{
        NSError* err = [self run:progress];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
    });
}

// Runs on the export queue. Returns nil on success.
- (NSError*)run:(void (^)(MFExportProgress*))progressBlock {
    using clock = std::chrono::steady_clock;
    const auto t0 = clock::now();
    std::string err;
    auto renderer = MetalRenderer::create(_device, err);
    if (!renderer) return exportError(21, err);
    renderer->setCachePolicy(CachePolicy::Off);
    for (const Asset& a : _project.assets)
        if (!a.missing && a.kind == AssetKind::Image && !renderer->loadImageSync(a.id, a.generation, a.path, err)) return exportError(22, "Media: " + err);

    const Composition& c = *_project.findComposition(_comp);
    const double fps = c.fps;
    const int64_t total = c.frameCount();
    const int64_t f0 = std::clamp<int64_t>(std::llround(_settings.startTime * fps), 0, std::max<int64_t>(0, total - 1));
    int64_t f1 = _settings.endTime > _settings.startTime ? std::llround(_settings.endTime * fps) : total;
    f1 = std::clamp<int64_t>(f1, f0 + 1, total);
    const double scale = std::clamp(_settings.scale, 0.05, 4.0);
    const std::vector<double> offsets = _settings.motionBlur ? motionBlurOffsets(_project, c) : std::vector<double>{0.0};
    const FrameDesc probe = evaluateFrame(_project, c, f0 / fps, scale);
    const bool alpha = _settings.format == MFExportFormatProRes4444 || _settings.format == MFExportFormatPNGSequence;
    const int w = probe.width, h = probe.height;

    MFExportProgress* prog = [MFExportProgress new];
    prog.framesTotal = NSInteger(f1 - f0);
    auto lastReport = clock::now() - std::chrono::seconds(1);
    auto report = [&](int64_t done, bool force) {
        const auto now = clock::now();
        if (!force && now - lastReport < std::chrono::milliseconds(100)) return;
        lastReport = now;
        MFExportProgress* p = [MFExportProgress new];
        p.framesTotal = prog.framesTotal;
        p.framesDone = NSInteger(done);
        p.elapsed = std::chrono::duration<double>(now - t0).count();
        p.framesPerSecond = p.elapsed > 0 ? double(done) / p.elapsed : 0;
        // Copy the callback out of the lambda's by-reference capture: this block can run after
        // -run: has returned, when that capture points into a dead stack frame.
        void (^callback)(MFExportProgress*) = progressBlock;
        dispatch_async(dispatch_get_main_queue(), ^{ callback(p); });
    };
    auto render = [&](int64_t f, uint8_t* dst, size_t rowBytes, std::string& e) {
        const auto frames = subframesAt(_project, c, double(f) / fps, scale, offsets);
        return renderer->renderToBGRA8(frames, c.background, alpha, dst, rowBytes, e);
    };

    // ---- PNG sequence --------------------------------------------------------------------
    if (_settings.format == MFExportFormatPNGSequence) {
        [[NSFileManager defaultManager] createDirectoryAtPath:_outputPath withIntermediateDirectories:YES attributes:nil error:nil];
        std::vector<uint8_t> px(size_t(w) * size_t(h) * 4);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSError* result = nil;
        for (int64_t f = f0; f < f1 && !result; ++f) {
            if (_cancelled) {
                result = exportError(29, "Export cancelled");
                break;
            }
            @autoreleasepool {
                if (!render(f, px.data(), size_t(w) * 4, err)) {
                    result = exportError(23, err);
                    break;
                }
                // Straight-alpha BGRA as written by the converter (bitmap contexts can't hold straight
                // alpha, so the image wraps the bytes directly: little-endian ARGB = B, G, R, A).
                CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, px.data(), px.size(), nullptr);
                CGImageRef img = CGImageCreate(size_t(w), size_t(h), 8, 32, size_t(w) * 4, cs,
                                               CGBitmapInfo(kCGImageAlphaFirst) | kCGBitmapByteOrder32Little, provider,
                                               nullptr, false, kCGRenderingIntentDefault);
                CGDataProviderRelease(provider);
                NSString* file = [_outputPath stringByAppendingPathComponent:[NSString stringWithFormat:@"frame_%05lld.png", f]];
                CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:file],
                                                                          (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
                bool ok = img && d;
                if (ok) {
                    CGImageDestinationAddImage(d, img, nullptr);
                    ok = CGImageDestinationFinalize(d);
                }
                if (d) CFRelease(d);
                if (img) CGImageRelease(img);
                if (!ok) result = exportError(24, std::string("Cannot write ") + file.UTF8String);
            }
            report(f - f0 + 1, false);
        }
        CGColorSpaceRelease(cs);
        if (!result) report(f1 - f0, true);
        return result;
    }

    // ---- movie ---------------------------------------------------------------------------
    const bool prores = _settings.format == MFExportFormatProRes422 || _settings.format == MFExportFormatProRes4444;
    NSURL* url = [NSURL fileURLWithPath:_outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    NSError* e = nil;
    AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:url fileType:(prores ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4) error:&e];
    if (!writer) return e ?: exportError(25, "Cannot create the movie file");
    // 4:2:0 codecs need even sizes: the last row / column is dropped when odd.
    const int vw = prores ? w : (w & ~1), vh = prores ? h : (h & ~1);
    NSMutableDictionary* video = [@{AVVideoWidthKey : @(vw), AVVideoHeightKey : @(vh)} mutableCopy];
    video[AVVideoColorPropertiesKey] = @{AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
                                         AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
                                         AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2};
    switch (_settings.format) {
        case MFExportFormatHEVC:
        case MFExportFormatH264: {
            const bool hevc = _settings.format == MFExportFormatHEVC;
            // Automatic: about 0.25 bits per pixel per frame for H.264 (15.5 Mb/s at 1080p30), 60% of that for HEVC.
            const double autoRate = double(vw) * vh * fps * (hevc ? 0.15 : 0.25);
            video[AVVideoCodecKey] = hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264;
            NSMutableDictionary* comp = [@{AVVideoAverageBitRateKey : @(_settings.bitsPerSecond > 0 ? double(_settings.bitsPerSecond) : autoRate),
                                           AVVideoExpectedSourceFrameRateKey : @(fps),
                                           AVVideoMaxKeyFrameIntervalKey : @(int(std::lround(fps * 2)))} mutableCopy];
            if (!hevc) comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
            video[AVVideoCompressionPropertiesKey] = comp;
            break;
        }
        case MFExportFormatProRes422: video[AVVideoCodecKey] = AVVideoCodecTypeAppleProRes422; break;
        default: video[AVVideoCodecKey] = AVVideoCodecTypeAppleProRes4444; break;
    }
    AVAssetWriterInput* vin = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:video];
    vin.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor* adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vin
                                   sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                                                 (id)kCVPixelBufferWidthKey : @(vw),
                                                                 (id)kCVPixelBufferHeightKey : @(vh)}];
    if (![writer canAddInput:vin]) return exportError(26, "The encoder rejected these video settings");
    [writer addInput:vin];

    // Audio: the composition's audio layers plus the optional soundtrack (its time 0 at the
    // composition's), mixed to PCM from the export's first frame, re-encoded as AAC.
    const double seconds = double(f1 - f0) / fps;
    AVAssetReader* reader = nil;
    AVAssetReaderAudioMixOutput* aout = nil;
    AVAssetWriterInput* ain = nil;
    std::vector<AudioClip> clips;
    if (_settings.includeAudioLayers) clips = collectAudio(_project, _comp);
    if (_settings.audioPath.length) {
        AVAudioFile* file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:_settings.audioPath] error:&e];
        const double sr = file.processingFormat.sampleRate;
        if (!file || sr <= 0) return exportError(27, std::string("No audio in ") + _settings.audioPath.UTF8String);
        AudioClip track;
        track.path = _settings.audioPath.fileSystemRepresentation;
        track.duration = double(file.length) / sr;
        track.gain = {{0.0, 1.0}};
        clips.push_back(track);
    }
    MFAudioMix* mix = clips.empty() ? nil : [MFAudioMix mixWithClips:MFAudioClipInfos(clips) origin:double(f0) / fps error:&e];
    if (!mix && e) return e;
    if (mix) {
        reader = [AVAssetReader assetReaderWithAsset:mix.composition error:&e];
        if (!reader) return e;
        reader.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(seconds, 48000));
        aout = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:mix.composition.tracks
                                                                       audioSettings:@{AVFormatIDKey : @(kAudioFormatLinearPCM),
                                                                                       AVSampleRateKey : @48000,
                                                                                       AVNumberOfChannelsKey : @2,
                                                                                       AVLinearPCMBitDepthKey : @32,
                                                                                       AVLinearPCMIsFloatKey : @YES,
                                                                                       AVLinearPCMIsNonInterleaved : @NO,
                                                                                       AVLinearPCMIsBigEndianKey : @NO}];
        aout.audioMix = mix.audioMix;
        [reader addOutput:aout];
        AudioChannelLayout layout = {};
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        ain = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                 outputSettings:@{AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                                                                  AVSampleRateKey : @48000,
                                                                  AVNumberOfChannelsKey : @2,
                                                                  AVEncoderBitRateKey : @256000,
                                                                  AVChannelLayoutKey : [NSData dataWithBytes:&layout length:sizeof layout]}];
        ain.expectsMediaDataInRealTime = NO;
        if (![writer canAddInput:ain]) return exportError(28, "The encoder rejected the audio settings");
        [writer addInput:ain];
    }

    if (![writer startWriting]) return writer.error ?: exportError(25, "Cannot start writing");
    if (reader && ![reader startReading]) {
        [writer cancelWriting];
        return reader.error ?: exportError(27, "Cannot read the audio");
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // Both inputs pull data when the writer wants it, so audio and video interleave.
    dispatch_group_t group = dispatch_group_create();
    __block NSError* failure = nil;
    __block int64_t f = f0;
    const int32_t timescale = int32_t(std::lround(fps * 1000));
    dispatch_queue_t vq = dispatch_queue_create("motionforge.export.video", DISPATCH_QUEUE_SERIAL);
    dispatch_group_enter(group);
    __block bool videoDone = false;
    [vin requestMediaDataWhenReadyOnQueue:vq usingBlock:^{
        while (vin.readyForMoreMediaData && !videoDone) {
            if (f >= f1 || _cancelled || failure) {
                [vin markAsFinished];
                videoDone = true;
                dispatch_group_leave(group);
                return;
            }
            @autoreleasepool {
                CVPixelBufferRef buf = nullptr;
                if (CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor.pixelBufferPool, &buf) != kCVReturnSuccess || !buf) {
                    failure = exportError(25, "Out of pixel buffers");
                    continue;
                }
                CVPixelBufferLockBaseAddress(buf, 0);
                std::string e2;
                const size_t rowBytes = CVPixelBufferGetBytesPerRow(buf);
                bool ok;
                if (vw == w && vh == h) {
                    ok = render(f, static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buf)), rowBytes, e2);
                } else {  // odd size: render whole, copy the even part
                    std::vector<uint8_t> tmp(size_t(w) * size_t(h) * 4);
                    ok = render(f, tmp.data(), size_t(w) * 4, e2);
                    for (int y = 0; ok && y < vh; ++y)
                        std::memcpy(static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buf)) + size_t(y) * rowBytes,
                                    tmp.data() + size_t(y) * size_t(w) * 4, size_t(vw) * 4);
                }
                CVPixelBufferUnlockBaseAddress(buf, 0);
                if (alpha)
                    CVBufferSetAttachment(buf, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha,
                                          kCVAttachmentMode_ShouldPropagate);
                if (!ok) {
                    failure = exportError(23, "Frame " + std::to_string(f) + ": " + e2);
                } else if (![adaptor appendPixelBuffer:buf withPresentationTime:CMTimeMake((f - f0) * 1000, timescale)]) {
                    failure = writer.error ?: exportError(25, "The encoder stopped");
                }
                CVPixelBufferRelease(buf);
            }
            ++f;
            report(f - f0, false);
        }
    }];
    if (ain) {
        dispatch_queue_t aq = dispatch_queue_create("motionforge.export.audio", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(group);
        __block bool audioDone = false;
        [ain requestMediaDataWhenReadyOnQueue:aq usingBlock:^{
            while (ain.readyForMoreMediaData && !audioDone) {
                CMSampleBufferRef s = (_cancelled || failure) ? nullptr : [aout copyNextSampleBuffer];
                if (!s) {
                    [ain markAsFinished];
                    audioDone = true;
                    dispatch_group_leave(group);
                    return;
                }
                [ain appendSampleBuffer:s];  // the mix already starts at the export's first frame
                CFRelease(s);
            }
        }];
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (_cancelled || failure) {
        [reader cancelReading];
        [writer cancelWriting];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return failure ?: exportError(29, "Export cancelled");
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return writer.error ?: exportError(25, "Writing the movie failed");
    report(f1 - f0, true);
    return nil;
}

@end
