// MotionForge renderer — Metal compositing backend (Objective-C++ only; not part of the Swift module).
//
// Design notes
//  * One render pass per composition frame into an RGBA16Float, premultiplied target.
//  * Every directly drawn layer becomes one 112-byte instance in a shared (unified-memory,
//    zero-copy) buffer; consecutive shape layers are one instanced draw call, image layers batch
//    per texture. Shapes and masks are analytic SDFs with analytic anti-aliasing (no MSAA memory).
//  * Layers with effects or a track matte are first rendered into a padded offscreen region just
//    big enough for them, run through their effect chain (compute kernels, MPS Gaussian blur),
//    matted, and then drawn into the composition as a textured quad with their blend mode.
//    Intermediate textures are recycled within the frame, so a chain of N effects needs ~3.
//  * Frames are cached by the evaluation hash of their draw list in a byte-budgeted LRU, as
//    8-bit copies (half the memory of the working format), and only when they are expensive to
//    re-render (cost measured on the GPU) or contain effects.
//  * Nothing here waits on the GPU except the explicit synchronous readback used by tests/CLI.
#pragma once

#import <Metal/Metal.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "mf/Evaluator.hpp"
#include "mf/LruCache.hpp"

@class MPSImageGaussianBlur;

namespace mf {

struct PresentParams {
    double originX = 0, originY = 0;  // composition top-left, drawable pixels
    double scale = 1;                 // drawable pixels per composition pixel
    int compWidth = 1, compHeight = 1;
    Value background{0, 0, 0, 1};
    bool checkerboard = false;
    Value viewerBackground{0.105, 0.105, 0.115, 1};
};

struct RendererStats {
    uint64_t framesEncoded = 0;
    uint64_t cacheHits = 0, cacheMisses = 0;
    uint64_t cacheAdmitted = 0, cacheSkippedCheap = 0;
    uint64_t drawCalls = 0;           // last encoded frame
    uint64_t offscreenLayers = 0;     // last encoded frame
    double lastEncodeMs = 0;          // CPU: building instances + encoding the composite
    double lastGpuMs = 0;             // GPU: execution time of the last completed composite
    double avgGpuMs = 0;              // exponential moving average
    size_t cacheBytes = 0, cacheBudget = 0, cacheFrames = 0;
    size_t poolBytes = 0, assetBytes = 0;
    size_t deviceAllocated = 0, recommendedWorkingSet = 0;
    int pendingAssets = 0;
    uint64_t pressureEvents = 0;
};

enum class PressureLevel { Normal, Warning, Critical };

// Smart: cache frames whose measured composite cost is at least the admission threshold, or that
// contain effects/mattes. All: cache everything. Off: never cache.
enum class CachePolicy { Smart = 0, All, Off };

class MetalRenderer {
public:
    static std::unique_ptr<MetalRenderer> create(id<MTLDevice> device, std::string& error);
    ~MetalRenderer();

    id<MTLDevice> device() const { return device_; }
    id<MTLCommandQueue> queue() const { return queue_; }
    bool programmableBlending() const { return fbFetch_; }
    double shaderCompileMs() const { return compileMs_; }

    // ---- media --------------------------------------------------------------------------
    static bool probeImage(const std::string& path, int& width, int& height, std::string& error);
    // Decode + upload on a background queue; `done` is called on the main queue.
    void requestImage(ObjectId asset, uint32_t generation, const std::string& path,
                      std::function<void(bool ok, const std::string& error)> done);
    bool loadImageSync(ObjectId asset, uint32_t generation, const std::string& path, std::string& error);
    bool hasImage(ObjectId asset, uint32_t generation) const;
    bool imagePending(ObjectId asset, uint32_t generation) const;

    // ---- compositing --------------------------------------------------------------------
    // Returns the frame. On a cache hit the texture belongs to the cache; otherwise the composite
    // is encoded into `cb` and the returned texture is recycled when `releaseOn` (default `cb`)
    // completes — pass the command buffer that presents it. `complete` = false means media is
    // still loading; such frames are drawn but never cached.
    id<MTLTexture> compositeFrame(const FrameDesc& f, id<MTLCommandBuffer> cb, bool useCache, bool* cacheHit,
                                  bool* complete, id<MTLCommandBuffer> releaseOn = nil);
    void encodePresent(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor* pass, id<MTLTexture> frame,
                       const PresentParams& p, int targetWidth, int targetHeight);

    // Synchronous render + readback of premultiplied RGBA floats (tests, CLI, export).
    bool renderToRGBA(const FrameDesc& f, std::vector<float>& rgba, double* gpuMs, std::string& error);

    // ---- frame cache --------------------------------------------------------------------
    bool cacheContains(uint64_t hash) const;
    bool wouldCache(const FrameDesc& f) const;  // admission decision, without rendering
    void setCachePolicy(CachePolicy p);
    CachePolicy cachePolicy() const;
    void setAdmissionThresholdMs(double ms);
    double measuredCostMs(const FrameDesc& f) const;  // EMA of GPU composite time, 0 if unknown

    // ---- memory -------------------------------------------------------------------------
    void setCacheBudget(size_t bytes);
    void setPoolBudget(size_t bytes);
    void clearCache();
    void handleMemoryPressure(PressureLevel level);
    RendererStats stats() const;
    void resetCounters();

private:
    enum class PoolKind : uint64_t { Target = 0, Scratch = 1, Cache8 = 2 };
    struct Arena;  // per-frame scratch textures + one sub-allocated instance buffer
    struct PassItem {
        DrawItem d;
        id<MTLTexture> tex = nil;  // overrides the image asset (offscreen results)
        bool masks = true;
    };
    struct Prepared {
        id<MTLTexture> tex = nil;
        int x = 0, y = 0;
    };

    MetalRenderer() = default;
    bool init(id<MTLDevice> device, std::string& error);
    id<MTLTexture> acquire(int w, int h, PoolKind kind);
    void recycle(id<MTLTexture> t);
    void recycleLocked(id<MTLTexture> t);
    id<MTLBuffer> acquireBuffer(size_t bytes);
    void recycleBuffer(id<MTLBuffer> b);
    id<MTLTexture> imageTexture(ObjectId asset, uint32_t generation) const;
    id<MTLRenderPipelineState> presentPipeline(MTLPixelFormat format);
    bool decodeAndUpload(ObjectId asset, uint32_t generation, const std::string& path, std::string& error);
    bool admitLocked(const FrameDesc& f) const;

    void encodeComposite(const FrameDesc& f, id<MTLCommandBuffer> cb, id<MTLTexture> target, bool* complete);
    void encodeItemsPass(id<MTLCommandBuffer> cb, id<MTLTexture> target, const FrameDesc& f,
                         const std::vector<PassItem>& items, Arena& arena, bool* complete, uint64_t* draws);
    Prepared renderOffscreen(id<MTLCommandBuffer> cb, const FrameDesc& f, const DrawItem& d, bool keepOpacity,
                             const int* region, Arena& arena, bool* complete);
    id<MTLTexture> applyEffect(id<MTLCommandBuffer> cb, id<MTLTexture> src, const EffectEval& e, double scale,
                               Arena& arena);
    id<MTLTexture> blur(id<MTLCommandBuffer> cb, id<MTLTexture> src, double sigma, Arena& arena);
    void runKernel(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> pso, const std::vector<id<MTLTexture>>& textures,
                   const void* params, size_t length);

    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLRenderPipelineState> shapePSO_ = nil, imagePSO_ = nil;              // no masks
    id<MTLRenderPipelineState> shapeMaskPSO_ = nil, imageMaskPSO_ = nil;      // with masks
    id<MTLComputePipelineState> fxShadow_ = nil, fxOver_ = nil, fxBright_ = nil, fxGlow_ = nil, fxColor_ = nil,
                                fxMatte_ = nil, toRGBA8_ = nil;
    id<MTLFunction> presentVS_ = nil, presentFS_ = nil;
    std::unordered_map<NSUInteger, id<MTLRenderPipelineState>> presentPSOs_;  // by drawable pixel format
    id<MTLSamplerState> linearMip_ = nil, linear_ = nil, nearest_ = nil;
    id<MTLTexture> emptyTexture_ = nil;
    id<MTLBuffer> emptyMasks_ = nil;
    bool fbFetch_ = false;
    double compileMs_ = 0;

    mutable std::mutex mutex_;  // guards everything below (Metal completion handlers run on other threads)
    LruCache<uint64_t, id<MTLTexture>> cache_;
    std::unordered_map<uint64_t, std::vector<id<MTLTexture>>> pool_;  // key: kind | w | h
    size_t poolBytes_ = 0, poolBudget_ = 512ull << 20;
    std::vector<id<MTLBuffer>> freeBuffers_;
    std::unordered_map<int, MPSImageGaussianBlur*> blurKernels_;  // by quantised sigma
    struct ImageEntry {
        uint32_t generation = 0;
        id<MTLTexture> texture = nil;
        bool pending = false;
        size_t bytes = 0;
    };
    std::unordered_map<ObjectId, ImageEntry> images_;
    std::unordered_map<uint64_t, double> costMs_;  // per comp + output size
    CachePolicy policy_ = CachePolicy::Smart;
    double admitMs_ = 0.75;
    RendererStats stats_;
};

// Bytes of one RGBA16F working frame, and of one cached (RGBA8) frame.
inline size_t targetBytes(int w, int h) { return static_cast<size_t>(w) * static_cast<size_t>(h) * 8; }
inline size_t cachedFrameBytes(int w, int h) { return static_cast<size_t>(w) * static_cast<size_t>(h) * 4; }

}  // namespace mf
