// MotionForge — mixing audio clips with AVFoundation.
//
// Each clip goes on a composition track; clips that don't overlap share a track, so a voice-over cut
// into many pieces stays a handful of tracks. Gain is applied through the audio mix (volume points and
// linear ramps), which both AVPlayer and AVAssetReaderAudioMixOutput honour.
#import "MFAudioInternal.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>

using namespace mf;

@interface MFAudioClipInfo ()
@property(nonatomic, readwrite) uint64_t layerID;
@property(nonatomic, readwrite, copy) NSString* path;
@property(nonatomic, readwrite) double start, sourceStart, duration;
@property(nonatomic, readwrite) NSArray<NSNumber*>* gainTimes;
@property(nonatomic, readwrite) NSArray<NSNumber*>* gainValues;
@end

@implementation MFAudioClipInfo
- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MFAudioClipInfo class]]) return NO;
    MFAudioClipInfo* o = object;
    return o.layerID == _layerID && [o.path isEqualToString:_path] && o.start == _start && o.sourceStart == _sourceStart &&
           o.duration == _duration && [o.gainTimes isEqualToArray:_gainTimes] && [o.gainValues isEqualToArray:_gainValues];
}
- (NSUInteger)hash { return NSUInteger(_layerID) ^ _path.hash ^ NSUInteger(_start * 1000); }
@end

NSArray<MFAudioClipInfo*>* MFAudioClipInfos(const std::vector<AudioClip>& clips) {
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:clips.size()];
    for (const AudioClip& c : clips) {
        MFAudioClipInfo* i = [MFAudioClipInfo new];
        i.layerID = c.layer;
        i.path = @(c.path.c_str());
        i.start = c.start;
        i.sourceStart = c.sourceStart;
        i.duration = c.duration;
        NSMutableArray* times = [NSMutableArray arrayWithCapacity:c.gain.size()];
        NSMutableArray* values = [NSMutableArray arrayWithCapacity:c.gain.size()];
        for (const auto& [t, g] : c.gain) {
            [times addObject:@(t)];
            [values addObject:@(g)];
        }
        i.gainTimes = times;
        i.gainValues = values;
        [out addObject:i];
    }
    return out;
}

@interface MFAudioMix ()
@property(nonatomic, readwrite) AVComposition* composition;
@property(nonatomic, readwrite) AVAudioMix* audioMix;
@property(nonatomic, readwrite) double origin;
@end

namespace {

constexpr int32_t kTimescale = 48000;
CMTime seconds(double s) { return CMTimeMakeWithSeconds(s, kTimescale); }

AVAssetTrack* firstAudioTrack(NSString* path) {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack*>* t, NSError*) {
        tracks = t;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return tracks.firstObject;
}

}  // namespace

@implementation MFAudioMix

+ (MFAudioMix*)mixWithClips:(NSArray<MFAudioClipInfo*>*)clips origin:(double)origin error:(NSError**)error {
    AVMutableComposition* comp = [AVMutableComposition composition];
    NSMutableDictionary<NSString*, AVAssetTrack*>* sources = [NSMutableDictionary dictionary];
    struct Lane {
        AVMutableCompositionTrack* track;
        AVMutableAudioMixInputParameters* params;
        double end;
    };
    std::vector<Lane> lanes;
    for (MFAudioClipInfo* clip in clips) {
        const double start = clip.start - origin;
        double sourceStart = clip.sourceStart, duration = clip.duration;
        if (start + duration <= 0) continue;
        double at = start;
        if (at < 0) {  // the mix starts partway into this clip
            sourceStart -= at;
            duration += at;
            at = 0;
        }
        AVAssetTrack* src = sources[clip.path];
        if (!src) {
            src = firstAudioTrack(clip.path);
            if (!src) {
                if (error)
                    *error = [NSError errorWithDomain:MFErrorDomain code:40
                                             userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"No audio in %@", clip.path.lastPathComponent]}];
                continue;
            }
            sources[clip.path] = src;
        }
        auto lane = std::find_if(lanes.begin(), lanes.end(), [&](const Lane& l) { return l.end <= at + 1e-6; });
        if (lane == lanes.end()) {
            AVMutableCompositionTrack* t = [comp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            if (!t) continue;
            lanes.push_back({t, [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:t], 0});
            lane = lanes.end() - 1;
        }
        NSError* e = nil;
        if (![lane->track insertTimeRange:CMTimeRangeMake(seconds(sourceStart), seconds(duration)) ofTrack:src atTime:seconds(at) error:&e]) {
            if (error) *error = e;
            continue;
        }
        lane->end = at + duration;
        // Gain: a constant, or linear ramps between the breakpoints (clipped to the mix).
        NSArray<NSNumber*>* times = clip.gainTimes;
        NSArray<NSNumber*>* values = clip.gainValues;
        if (values.count <= 1) {
            [lane->params setVolume:values.count ? values[0].floatValue : 1.f atTime:seconds(at)];
        } else {
            for (NSUInteger k = 0; k + 1 < values.count; ++k) {
                double t0 = times[k].doubleValue - origin, t1 = times[k + 1].doubleValue - origin;
                float g0 = values[k].floatValue, g1 = values[k + 1].floatValue;
                if (t1 <= 0) continue;
                if (t0 < 0) {
                    g0 += (g1 - g0) * float(-t0 / (t1 - t0));
                    t0 = 0;
                }
                if (t1 - t0 < 1e-4) continue;
                [lane->params setVolumeRampFromStartVolume:g0 toEndVolume:g1 timeRange:CMTimeRangeMake(seconds(t0), seconds(t1 - t0))];
            }
        }
    }
    if (lanes.empty()) return nil;
    AVMutableAudioMix* mix = [AVMutableAudioMix audioMix];
    NSMutableArray* params = [NSMutableArray array];
    for (const Lane& l : lanes) [params addObject:l.params];
    mix.inputParameters = params;
    MFAudioMix* m = [MFAudioMix new];
    m.composition = comp;
    m.audioMix = mix;
    m.origin = origin;
    return m;
}

@end
