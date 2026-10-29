#import "VideoDecoder.hpp"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <map>
#include <mutex>

namespace mf {

namespace {

constexpr int64_t kAhead = 8;           // frames decoded after the one asked for (playback)
constexpr size_t kBudget = 512ull << 20;  // decoded frames kept per clip

// The asset, its first video track and a video composition that shows the track upright and in
// Rec. 709 (HDR is tone-mapped), at the clip's own frame rate.
struct Opened {
    AVURLAsset* asset = nil;
    AVAssetTrack* track = nil;
    AVMutableVideoComposition* composition = nil;
    bool hasAudio = false;
    double duration = 0, fps = 0;
    int width = 0, height = 0;
    std::string error;
};

// AVFoundation loads asynchronously; these run on a queue that never delivers its callbacks.
Opened open(const std::string& path) {
    Opened o;
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    o.asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray<AVAssetTrack*>* videos = nil;
    __block NSArray<AVAssetTrack*>* audios = nil;
    __block NSError* failure = nil;
    [o.asset loadTracksWithMediaType:AVMediaTypeVideo
                   completionHandler:^(NSArray<AVAssetTrack*>* t, NSError* e) {
                       videos = t;
                       failure = e;
                       dispatch_semaphore_signal(done);
                   }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [o.asset loadTracksWithMediaType:AVMediaTypeAudio
                   completionHandler:^(NSArray<AVAssetTrack*>* t, NSError*) {
                       audios = t;
                       dispatch_semaphore_signal(done);
                   }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    o.track = videos.firstObject;
    o.hasAudio = audios.count > 0;
    if (!o.track) {
        o.error = failure ? failure.localizedDescription.UTF8String : "No video in " + path;
        return o;
    }
    [o.asset loadValuesAsynchronouslyForKeys:@[ @"duration" ] completionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [o.track loadValuesAsynchronouslyForKeys:@[ @"nominalFrameRate", @"minFrameDuration" ]
                           completionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    __block AVVideoComposition* vc = nil;
    [AVVideoComposition videoCompositionWithPropertiesOfAsset:o.asset
                                            completionHandler:^(AVVideoComposition* c, NSError* e) {
                                                vc = c;
                                                if (e) failure = e;
                                                dispatch_semaphore_signal(done);
                                            }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!vc) {
        o.error = failure ? failure.localizedDescription.UTF8String : "Cannot read the video in " + path;
        return o;
    }
    o.duration = CMTimeGetSeconds(o.asset.duration);
    double fps = o.track.nominalFrameRate;
    if (!(fps > 0)) {
        const double md = CMTimeGetSeconds(o.track.minFrameDuration);
        fps = md > 0 ? 1.0 / md : 30;
    }
    o.fps = std::clamp(fps, 1.0, 480.0);
    o.composition = [vc mutableCopy];
    // 1/fps exactly for the usual broadcast rates (29.97 = 1001/30000), so frames land on indices.
    o.composition.frameDuration = CMTimeMakeWithSeconds(1.0 / o.fps, 600000);
    o.composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2;
    o.composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2;
    o.composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2;
    o.width = std::max(1, int(std::lround(std::abs(o.composition.renderSize.width))));
    o.height = std::max(1, int(std::lround(std::abs(o.composition.renderSize.height))));
    if (!(o.duration > 0)) o.error = "The video in " + path + " has no length";
    return o;
}

}  // namespace

struct VideoDecoder::Impl {
    struct Frame {
        CVPixelBufferRef pixels = nullptr;
        CVMetalTextureRef ref = nullptr;
        id<MTLTexture> texture = nil;
        uint64_t used = 0;
        ~Frame() {
            texture = nil;
            if (ref) CFRelease(ref);
            if (pixels) CVPixelBufferRelease(pixels);
        }
    };

    id<MTLDevice> device = nil;
    std::string path;
    double fps = 30;
    int64_t frameCount = 1;
    dispatch_queue_t queue = nil;
    CVMetalTextureCacheRef textures = nullptr;

    mutable std::mutex m;  // guards everything down to the decode-queue state
    std::condition_variable changed;
    std::map<int64_t, std::shared_ptr<Frame>> frames;  // a held frame (variable rate) shares its buffer
    uint64_t tick = 0;
    int64_t wanted = -1;
    bool running = false, failed = false;
    std::string failure;
    size_t frameBytes = 0;

    // Decode queue only.
    Opened source;
    bool opened = false;
    AVAssetReader* reader = nil;
    AVAssetReaderVideoCompositionOutput* output = nil;
    int64_t next = 0, last = -1;  // what this reader delivers next / delivered last
    bool backedOff = false;

    ~Impl() {
        frames.clear();
        if (textures) CFRelease(textures);
    }

    size_t capacity() const { return frameBytes ? std::clamp<size_t>(kBudget / frameBytes, 12, 240) : 24; }

    void evictLocked() {
        while (frames.size() > capacity()) {
            auto victim = frames.end();
            for (auto it = frames.begin(); it != frames.end(); ++it) {
                if (wanted >= 0 && it->first >= wanted && it->first <= wanted + kAhead) continue;
                if (victim == frames.end() || it->second->used < victim->second->used) victim = it;
            }
            if (victim == frames.end()) return;
            frames.erase(victim);
        }
    }

    void request(const std::shared_ptr<Impl>& self, int64_t frame) {
        std::lock_guard lock(m);
        if (failed) return;
        wanted = std::clamp<int64_t>(frame, 0, frameCount - 1);
        if (running) return;
        bool missing = false;
        for (int64_t i = wanted; i <= std::min(wanted + kAhead, frameCount - 1) && !missing; ++i) missing = !frames.count(i);
        if (!missing) return;
        running = true;
        std::shared_ptr<Impl> keep = self;  // a block holds a C++ reference by address: copy, so the job keeps us alive
        dispatch_async(queue, ^{ keep->pump(); });
    }

    bool startReader(int64_t frame) {
        reader = nil;
        output = nil;
        NSError* e = nil;
        AVAssetReader* r = [AVAssetReader assetReaderWithAsset:source.asset error:&e];
        if (!r) {
            fail(e ? e.localizedDescription.UTF8String : "Cannot read " + path);
            return false;
        }
        NSDictionary* settings = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferMetalCompatibilityKey : @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        AVAssetReaderVideoCompositionOutput* o =
            [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[ source.track ]
                                                                                    videoSettings:settings];
        o.videoComposition = source.composition;
        o.alwaysCopiesSampleData = NO;
        if (![r canAddOutput:o]) {
            fail("Cannot decode " + path);
            return false;
        }
        [r addOutput:o];
        const CMTime start = CMTimeMultiply(source.composition.frameDuration, int32_t(std::min<int64_t>(frame, INT32_MAX)));
        r.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
        if (![r startReading]) {
            fail(r.error ? r.error.localizedDescription.UTF8String : "Cannot decode " + path);
            return false;
        }
        reader = r;
        output = o;
        next = frame;
        last = -1;
        return true;
    }

    // One decoded frame into the cache; false at the end of the clip (or on an error).
    bool readOne() {
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (!sample) return false;
        CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
        const double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        auto f = std::make_shared<Frame>();
        if (image) {
            const size_t w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image);
            if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textures, image, nullptr,
                                                          MTLPixelFormatBGRA8Unorm, w, h, 0, &f->ref) == kCVReturnSuccess) {
                f->pixels = CVPixelBufferRetain(image);
                f->texture = CVMetalTextureGetTexture(f->ref);
            }
            std::lock_guard lock(m);
            frameBytes = w * h * 4;
        }
        CFRelease(sample);
        if (!f->texture) return true;  // an empty sample: skip it
        const int64_t idx = std::llround(pts * fps);
        std::lock_guard lock(m);
        f->used = ++tick;
        // A variable-rate clip skips indices: the previous frame holds until this one.
        if (last >= 0 && idx > last + 1 && idx - last <= int64_t(fps * 2))
            if (auto held = frames.find(last); held != frames.end())
                for (int64_t i = last + 1; i < idx; ++i) frames[i] = held->second;
        frames[idx] = f;
        last = std::max(last, idx);
        next = last + 1;
        evictLocked();
        changed.notify_all();
        return true;
    }

    void fail(const std::string& why) {
        std::lock_guard lock(m);
        failed = true;
        failure = why;
        running = false;
        changed.notify_all();
    }

    void pump() {
        if (!opened) {
            opened = true;
            source = open(path);
            if (!source.error.empty()) return fail(source.error);
            if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &textures) != kCVReturnSuccess)
                return fail("Cannot share video frames with the GPU");
        }
        for (;;) {
            int64_t target = -1, need = -1;
            {
                std::lock_guard lock(m);
                target = wanted;
                for (int64_t i = target; target >= 0 && i <= std::min(target + kAhead, frameCount - 1); ++i)
                    if (!frames.count(i)) {
                        need = i;
                        break;
                    }
                if (need < 0) {
                    running = false;
                    changed.notify_all();
                    return;
                }
            }
            // Read on when the frame is just ahead (sequential playback / export), otherwise seek.
            if (!reader || need < next || need > next + int64_t(fps * 2)) {
                if (!startReader(need)) return;
            }
            if (readOne()) continue;
            // The clip ended before `need` (it is shorter than its recorded length): those frames
            // show the last one. A seek that landed past the real end backs off a second first.
            reader = nil;
            output = nil;
            bool empty = false;
            {
                std::lock_guard lock(m);
                empty = frames.empty();
            }
            if (empty && need > 0 && !backedOff) {
                backedOff = true;
                if (!startReader(std::max<int64_t>(0, need - int64_t(fps)))) return;
                continue;
            }
            std::lock_guard lock(m);
            auto held = frames.end();
            if (!frames.empty()) {
                auto after = frames.upper_bound(need);
                held = after == frames.begin() ? after : std::prev(after);
            }
            if (held == frames.end()) {
                failed = true;
                failure = "No frames could be decoded from " + path;
                running = false;
                changed.notify_all();
                return;
            }
            for (int64_t i = need; i <= std::min(target + kAhead, frameCount - 1); ++i)
                if (!frames.count(i)) frames[i] = held->second;
            changed.notify_all();
        }
    }
};

VideoDecoder::VideoDecoder(id<MTLDevice> device, std::string path, double fps, int64_t frameCount)
    : impl_(std::make_shared<Impl>()) {
    impl_->device = device;
    impl_->path = std::move(path);
    impl_->fps = fps > 0 ? fps : 30;
    impl_->frameCount = std::max<int64_t>(1, frameCount);
    impl_->queue = dispatch_queue_create("MotionForge.video", DISPATCH_QUEUE_SERIAL);
}

VideoDecoder::~VideoDecoder() = default;

id<MTLTexture> VideoDecoder::texture(int64_t frame, bool* exact) {
    frame = std::clamp<int64_t>(frame, 0, impl_->frameCount - 1);
    id<MTLTexture> out = nil;
    bool found = false;
    {
        std::lock_guard lock(impl_->m);
        auto it = impl_->frames.find(frame);
        if (it != impl_->frames.end()) {
            it->second->used = ++impl_->tick;
            out = it->second->texture;
            found = true;
        } else if (!impl_->frames.empty()) {  // a stand-in until it arrives: the closest earlier frame
            auto near = impl_->frames.lower_bound(frame);
            if (near == impl_->frames.begin()) out = near->second->texture;
            else out = std::prev(near)->second->texture;
        }
    }
    if (exact) *exact = found;
    impl_->request(impl_, frame);  // and keep decoding ahead
    return out;
}

bool VideoDecoder::decodeSync(int64_t frame, double timeoutSeconds) {
    frame = std::clamp<int64_t>(frame, 0, impl_->frameCount - 1);
    impl_->request(impl_, frame);
    std::unique_lock lock(impl_->m);
    impl_->changed.wait_for(lock, std::chrono::duration<double>(timeoutSeconds),
                            [&] { return impl_->frames.count(frame) > 0 || impl_->failed; });
    return impl_->frames.count(frame) > 0;
}

void VideoDecoder::purge() {
    std::lock_guard lock(impl_->m);
    impl_->frames.clear();
}

size_t VideoDecoder::bytes() const {
    std::lock_guard lock(impl_->m);
    size_t distinct = 0;
    const Impl::Frame* prev = nullptr;
    for (const auto& [i, f] : impl_->frames) {
        if (f.get() != prev) ++distinct;
        prev = f.get();
    }
    return distinct * impl_->frameBytes;
}

std::string VideoDecoder::error() const {
    std::lock_guard lock(impl_->m);
    return impl_->failure;
}

bool VideoDecoder::probe(const std::string& path, int& width, int& height, double& duration, double& fps, bool& hasAudio,
                         std::string& error) {
    Opened o = open(path);  // fine on the main thread: AVFoundation answers on its own queues
    if (!o.error.empty()) {
        error = o.error;
        return false;
    }
    width = o.width;
    height = o.height;
    duration = o.duration;
    fps = o.fps;
    hasAudio = o.hasAudio;
    return true;
}

}  // namespace mf
