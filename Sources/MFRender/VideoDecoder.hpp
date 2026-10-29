// MotionForge renderer — video footage. Frames are decoded by AVFoundation (VideoToolbox, in
// hardware) into IOSurface-backed BGRA pixel buffers that Metal samples without a copy. The clip's
// rotation is applied and HDR / wide-gamut footage is converted to the Rec. 709 working space.
// Objective-C++ only.
#pragma once

#import <Metal/Metal.h>

#include <cstdint>
#include <memory>
#include <string>

namespace mf {

class VideoDecoder {
public:
    // `fps` and `frameCount` as the project recorded them for the clip.
    VideoDecoder(id<MTLDevice> device, std::string path, double fps, int64_t frameCount);
    ~VideoDecoder();
    VideoDecoder(const VideoDecoder&) = delete;
    VideoDecoder& operator=(const VideoDecoder&) = delete;

    // The texture for `frame`. When that frame isn't decoded yet this is the nearest decoded one
    // before it (or nil) with *exact = false, and decoding starts in the background. A few frames
    // after it are decoded too, so playback finds them ready.
    id<MTLTexture> texture(int64_t frame, bool* exact);
    // Export and tests: blocks until `frame` is decoded. False if the clip can't be read.
    bool decodeSync(int64_t frame, double timeoutSeconds);
    void purge();  // memory pressure: drop the decoded frames
    size_t bytes() const;
    std::string error() const;

    // Displayed size (rotation applied), length, frame rate and whether it has sound.
    static bool probe(const std::string& path, int& width, int& height, double& duration, double& fps, bool& hasAudio,
                      std::string& error);

private:
    struct Impl;
    std::shared_ptr<Impl> impl_;  // shared with the decode queue's blocks
};

}  // namespace mf
