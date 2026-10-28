#import "MFRender/MetalRenderer.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include <algorithm>
#include <chrono>
#include <cmath>

#include "Shaders.hpp"

namespace mf {

namespace {

// Mirrors `struct Item` in Shaders.hpp.
struct ItemGPU {
    float m0[4];
    float m1[4];
    float bounds[4];
    float fill[4];
    float stroke[4];
    float p0[4];
    float p1[4];
};
static_assert(sizeof(ItemGPU) == 112, "ItemGPU must match the MSL layout");

// Mirrors `struct Mask` in Shaders.hpp.
struct MaskGPU {
    float a[4];
    float b[4];
    float c[4];
};
static_assert(sizeof(MaskGPU) == 48, "MaskGPU must match the MSL layout");

struct FxParams {
    float a[4] = {0, 0, 0, 0};
    float b[4] = {0, 0, 0, 0};
    float c[4] = {0, 0, 0, 0};
    float d[4] = {0, 0, 0, 0};
};

struct FrameUniformsGPU {
    float targetSize[2];
    float pad[2];
};

struct PresentUniformsGPU {
    float compOrigin[2];
    float compSize[2];
    float background[4];
    float viewerBg[4];
    float checker;
    float checkerSize;
    float pad[2];
};

double nowMs() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

void packItem(const DrawItem& d, ItemGPU& g) {
    const Affine& m = d.toTarget;
    g.m0[0] = float(m.a);
    g.m0[1] = float(m.b);
    g.m0[2] = float(m.c);
    g.m0[3] = float(m.d);
    g.m1[0] = float(m.tx);
    g.m1[1] = float(m.ty);
    g.m1[2] = float(d.opacity);
    g.m1[3] = float(static_cast<int>(d.kind));
    g.bounds[0] = float(d.boundsMin.x);
    g.bounds[1] = float(d.boundsMin.y);
    g.bounds[2] = float(d.boundsMax.x);
    g.bounds[3] = float(d.boundsMax.y);
    for (int i = 0; i < 4; ++i) {
        g.fill[i] = float(d.fill[size_t(i)]);
        g.stroke[i] = float(d.stroke[size_t(i)]);
    }
    g.p0[0] = float(d.strokeWidth);
    g.p0[1] = float(d.roundness);
    g.p0[2] = float(d.points);
    g.p0[3] = float(d.innerRatio);
    g.p1[0] = float(static_cast<int>(d.shape));
    g.p1[1] = float(static_cast<int>(d.blend));
    g.p1[2] = 0;  // mask start / count are filled in by the pass
    g.p1[3] = 0;
}

void packMask(const MaskEval& m, MaskGPU& g) {
    g.a[0] = float(m.center.x);
    g.a[1] = float(m.center.y);
    g.a[2] = float(m.halfSize.x);
    g.a[3] = float(m.halfSize.y);
    g.b[0] = float(m.roundness);
    g.b[1] = float(m.feather);
    g.b[2] = float(m.expansion);
    g.b[3] = float(m.opacity);
    g.c[0] = float(static_cast<int>(m.shape));
    g.c[1] = float(static_cast<int>(m.mode));
    g.c[2] = m.inverted ? 1.f : 0.f;
    g.c[3] = 0;
}

int orientedSwap(CFDictionaryRef props) {
    int orientation = 1;
    if (CFNumberRef o = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyOrientation))
        CFNumberGetValue(o, kCFNumberIntType, &orientation);
    return orientation >= 5 && orientation <= 8;  // 90° rotations swap width/height
}

uint64_t costKey(const FrameDesc& f) {
    return (uint64_t(f.compId) << 32) ^ (uint64_t(f.width) << 16) ^ uint64_t(f.height);
}

// Region (target pixels) an offscreen layer needs: its transformed bounds plus whatever its effects
// can reach, limited to the frame grown by that reach. Sizes are rounded up to 64 px so textures
// from the pool fit moving/animated layers frame after frame.
bool offscreenRegion(const FrameDesc& f, const DrawItem& d, int out[4]) {
    const Affine& m = d.toTarget;
    const double px = 1.0 / std::sqrt(std::max(std::abs(m.determinant()), 1e-12));
    const double pad = d.strokeWidth * 0.5 + 2 * px;
    const Vec2 corners[4] = {{d.boundsMin.x - pad, d.boundsMin.y - pad},
                             {d.boundsMax.x + pad, d.boundsMin.y - pad},
                             {d.boundsMax.x + pad, d.boundsMax.y + pad},
                             {d.boundsMin.x - pad, d.boundsMax.y + pad}};
    double x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
    for (const Vec2& c : corners) {
        const Vec2 p = m.apply(c);
        x0 = std::min(x0, p.x);
        y0 = std::min(y0, p.y);
        x1 = std::max(x1, p.x);
        y1 = std::max(y1, p.y);
    }
    const double reach = effectReach(f, d) + 2;
    x0 = std::max(x0 - reach, -reach);
    y0 = std::max(y0 - reach, -reach);
    x1 = std::min(x1 + reach, f.width + reach);
    y1 = std::min(y1 + reach, f.height + reach);
    if (x1 <= x0 || y1 <= y0) return false;
    const int ix = int(std::floor(x0)), iy = int(std::floor(y0));
    auto roundUp = [](int v) { return std::min(8192, ((v + 63) / 64) * 64); };
    out[0] = ix;
    out[1] = iy;
    out[2] = roundUp(int(std::ceil(x1)) - ix);
    out[3] = roundUp(int(std::ceil(y1)) - iy);
    return true;
}

}  // namespace

// Scratch textures for one frame. Released textures are reused by later steps of the same frame
// (Metal orders the passes), and everything goes back to the shared pool when the frame's command
// buffer completes.
struct MetalRenderer::Arena {
    std::vector<id<MTLTexture>> all, free;
    id<MTLBuffer> buffer = nil;  // instances + masks for every pass of the frame
    size_t used = 0;
};

std::unique_ptr<MetalRenderer> MetalRenderer::create(id<MTLDevice> device, std::string& error) {
    std::unique_ptr<MetalRenderer> r(new MetalRenderer());
    if (!r->init(device, error)) return nullptr;
    return r;
}

MetalRenderer::~MetalRenderer() {
    // Completion handlers capture `this`; drain the queue before tearing down.
    if (queue_) {
        id<MTLCommandBuffer> cb = [queue_ commandBuffer];
        [cb commit];
        [cb waitUntilCompleted];
    }
}

bool MetalRenderer::init(id<MTLDevice> device, std::string& error) {
    device_ = device ? device : MTLCreateSystemDefaultDevice();
    if (!device_) {
        error = "No Metal device available";
        return false;
    }
    queue_ = [device_ newCommandQueue];
    queue_.label = @"MotionForge.render";
    fbFetch_ = [device_ supportsFamily:MTLGPUFamilyApple7];  // M1 and later

    MTLCompileOptions* opts = [MTLCompileOptions new];
    opts.preprocessorMacros = @{@"MF_FBFETCH" : @(fbFetch_ ? 1 : 0)};
    NSError* err = nil;
    const double t0 = nowMs();
    id<MTLLibrary> lib = [device_ newLibraryWithSource:@(shaders::kSource) options:opts error:&err];
    compileMs_ = nowMs() - t0;
    if (!lib) {
        error = std::string("Shader compilation failed: ") + (err ? err.localizedDescription.UTF8String : "unknown");
        return false;
    }

    auto makeItemPSO = [&](NSString* fragment, NSString* label, bool masks) -> id<MTLRenderPipelineState> {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.label = label;
        MTLFunctionConstantValues* fc = [MTLFunctionConstantValues new];
        bool m = masks;
        [fc setConstantValue:&m type:MTLDataTypeBool atIndex:0];
        NSError* fe = nil;
        d.vertexFunction = [lib newFunctionWithName:@"item_vertex" constantValues:fc error:&fe];
        d.fragmentFunction = [lib newFunctionWithName:fragment constantValues:fc error:&fe];
        if (!d.vertexFunction || !d.fragmentFunction) {
            error = std::string("Shader specialisation failed: ") + (fe ? fe.localizedDescription.UTF8String : "");
            return nil;
        }
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        if (!fbFetch_) {
            auto* ca = d.colorAttachments[0];
            ca.blendingEnabled = YES;
            ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
            ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        }
        NSError* e = nil;
        id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:d error:&e];
        if (!pso) error = std::string("Pipeline creation failed: ") + (e ? e.localizedDescription.UTF8String : "");
        return pso;
    };
    auto makeKernel = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [lib newFunctionWithName:name];
        NSError* e = nil;
        id<MTLComputePipelineState> pso = fn ? [device_ newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!pso) error = std::string("Kernel creation failed: ") + name.UTF8String;
        return pso;
    };
    shapePSO_ = makeItemPSO(@"shape_fragment", @"shapes", false);
    imagePSO_ = makeItemPSO(@"image_fragment", @"images", false);
    shapeMaskPSO_ = makeItemPSO(@"shape_fragment", @"masked shapes", true);
    imageMaskPSO_ = makeItemPSO(@"image_fragment", @"masked images", true);
    fxShadow_ = makeKernel(@"fx_shadow");
    fxOver_ = makeKernel(@"fx_over");
    fxBright_ = makeKernel(@"fx_bright");
    fxGlow_ = makeKernel(@"fx_glow");
    fxColor_ = makeKernel(@"fx_color");
    fxMatte_ = makeKernel(@"fx_matte");
    toRGBA8_ = makeKernel(@"to_rgba8");
    presentVS_ = [lib newFunctionWithName:@"present_vertex"];
    presentFS_ = [lib newFunctionWithName:@"present_fragment"];
    if (!shapePSO_ || !imagePSO_ || !shapeMaskPSO_ || !imageMaskPSO_ || !fxShadow_ || !fxOver_ || !fxBright_ || !fxGlow_ || !fxColor_ || !fxMatte_ ||
        !toRGBA8_ || !presentVS_ || !presentFS_) {
        if (error.empty()) error = "Missing shader functions";
        return false;
    }

    auto sampler = [&](MTLSamplerMinMagFilter f, MTLSamplerMipFilter mip) {
        MTLSamplerDescriptor* s = [MTLSamplerDescriptor new];
        s.minFilter = s.magFilter = f;
        s.mipFilter = mip;
        s.sAddressMode = s.tAddressMode = MTLSamplerAddressModeClampToEdge;
        return [device_ newSamplerStateWithDescriptor:s];
    };
    linearMip_ = sampler(MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterLinear);
    linear_ = sampler(MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterNotMipmapped);
    nearest_ = sampler(MTLSamplerMinMagFilterNearest, MTLSamplerMipFilterNotMipmapped);

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:1
                                                                                 height:1
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    emptyTexture_ = [device_ newTextureWithDescriptor:td];
    const uint16_t zero[4] = {0, 0, 0, 0};
    [emptyTexture_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
    emptyMasks_ = [device_ newBufferWithLength:sizeof(MaskGPU) options:MTLResourceStorageModeShared];

    cache_.setEvictionHandler([this](const uint64_t&, id<MTLTexture>&& t, size_t) { recycleLocked(t); });
    cache_.setBudget(512ull << 20);  // callers normally size this from physical memory
    return true;
}

id<MTLRenderPipelineState> MetalRenderer::presentPipeline(MTLPixelFormat format) {
    std::lock_guard lock(mutex_);
    auto it = presentPSOs_.find(format);
    if (it != presentPSOs_.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.label = @"present";
    d.vertexFunction = presentVS_;
    d.fragmentFunction = presentFS_;
    d.colorAttachments[0].pixelFormat = format;
    NSError* e = nil;
    id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:d error:&e];
    if (pso) presentPSOs_[format] = pso;
    return pso;
}

// ---- resource pools -------------------------------------------------------------------------

namespace {
uint64_t poolKey(uint64_t kind, NSUInteger w, NSUInteger h) { return (kind << 60) | (uint64_t(w) << 30) | uint64_t(h); }
size_t textureBytes(id<MTLTexture> t) {
    return size_t(t.width) * size_t(t.height) * (t.pixelFormat == MTLPixelFormatRGBA8Unorm ? 4 : 8);
}
uint64_t kindOf(id<MTLTexture> t) {
    if (t.pixelFormat == MTLPixelFormatRGBA8Unorm) return 2;
    return (t.usage & MTLTextureUsageShaderWrite) ? 1 : 0;
}
}  // namespace

id<MTLTexture> MetalRenderer::acquire(int w, int h, PoolKind kind) {
    const uint64_t k = static_cast<uint64_t>(kind);
    {
        std::lock_guard lock(mutex_);
        auto it = pool_.find(poolKey(k, NSUInteger(w), NSUInteger(h)));
        if (it != pool_.end() && !it->second.empty()) {
            id<MTLTexture> t = it->second.back();
            it->second.pop_back();
            poolBytes_ -= textureBytes(t);
            return t;
        }
    }
    const MTLPixelFormat fmt = kind == PoolKind::Cache8 ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                  width:NSUInteger(w)
                                                                                 height:NSUInteger(h)
                                                                              mipmapped:NO];
    switch (kind) {
        case PoolKind::Target: td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; break;
        case PoolKind::Scratch:
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            break;
        case PoolKind::Cache8: td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; break;
    }
    td.storageMode = MTLStorageModePrivate;  // GPU-only; render targets get lossless compression
    id<MTLTexture> t = [device_ newTextureWithDescriptor:td];
    t.label = kind == PoolKind::Target ? @"composite" : kind == PoolKind::Scratch ? @"layer" : @"cached frame";
    return t;
}

void MetalRenderer::recycleLocked(id<MTLTexture> t) {
    if (!t) return;
    const size_t bytes = textureBytes(t);
    if (poolBytes_ + bytes > poolBudget_) return;  // let ARC free it
    pool_[poolKey(kindOf(t), t.width, t.height)].push_back(t);
    poolBytes_ += bytes;
}

void MetalRenderer::recycle(id<MTLTexture> t) {
    std::lock_guard lock(mutex_);
    recycleLocked(t);
}

id<MTLBuffer> MetalRenderer::acquireBuffer(size_t bytes) {
    {
        std::lock_guard lock(mutex_);
        auto best = freeBuffers_.end();
        for (auto it = freeBuffers_.begin(); it != freeBuffers_.end(); ++it)
            if ((*it).length >= bytes && (best == freeBuffers_.end() || (*it).length < (*best).length)) best = it;
        if (best != freeBuffers_.end()) {
            id<MTLBuffer> b = *best;
            freeBuffers_.erase(best);
            return b;
        }
    }
    size_t cap = 64 * 1024;
    while (cap < bytes) cap <<= 1;
    // Shared storage: on unified memory the CPU writes instances the GPU reads directly, no copy.
    id<MTLBuffer> b = [device_ newBufferWithLength:cap options:MTLResourceStorageModeShared];
    b.label = @"instances";
    return b;
}

void MetalRenderer::recycleBuffer(id<MTLBuffer> b) {
    std::lock_guard lock(mutex_);
    if (freeBuffers_.size() < 16) freeBuffers_.push_back(b);
}

// ---- media ----------------------------------------------------------------------------------

bool MetalRenderer::probeImage(const std::string& path, int& width, int& height, std::string& error) {
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!src) {
        error = "Cannot open image " + path;
        return false;
    }
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr);
    CFRelease(src);
    if (!props) {
        error = "Unsupported image " + path;
        return false;
    }
    int w = 0, h = 0;
    if (CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth))
        CFNumberGetValue(n, kCFNumberIntType, &w);
    if (CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight))
        CFNumberGetValue(n, kCFNumberIntType, &h);
    if (orientedSwap(props)) std::swap(w, h);
    CFRelease(props);
    if (w <= 0 || h <= 0) {
        error = "Image has no pixels: " + path;
        return false;
    }
    width = w;
    height = h;
    return true;
}

bool MetalRenderer::decodeAndUpload(ObjectId asset, uint32_t generation, const std::string& path, std::string& error) {
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!src) {
        error = "Cannot open image " + path;
        return false;
    }
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr);
    int maxDim = 0;
    if (props) {
        int w = 0, h = 0;
        if (CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth))
            CFNumberGetValue(n, kCFNumberIntType, &w);
        if (CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight))
            CFNumberGetValue(n, kCFNumberIntType, &h);
        maxDim = std::max(w, h);
        CFRelease(props);
    }
    // The thumbnail API applies EXIF orientation; asking for the full size keeps full resolution.
    NSDictionary* opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(std::min(std::max(maxDim, 1), 16384)),
        (id)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!img) {
        error = "Cannot decode image " + path;
        return false;
    }
    const size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // Premultiplied RGBA8 in sRGB: matches the compositor's display-referred sRGB working space.
    CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, w * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CGImageRelease(img);
        error = "Out of memory decoding " + path;
        return false;
    }
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGImageRelease(img);

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [device_ newTextureWithDescriptor:td];
    id<MTLBuffer> staging = [device_ newBufferWithBytes:CGBitmapContextGetData(ctx)
                                                 length:w * h * 4
                                                options:MTLResourceStorageModeShared];
    CGContextRelease(ctx);
    if (!tex || !staging) {
        error = "Out of GPU memory loading " + path;
        return false;
    }
    tex.label = @(path.c_str()).lastPathComponent;
    id<MTLCommandBuffer> cb = [queue_ commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:staging
               sourceOffset:0
          sourceBytesPerRow:w * 4
        sourceBytesPerImage:w * h * 4
                 sourceSize:MTLSizeMake(w, h, 1)
                  toTexture:tex
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit generateMipmapsForTexture:tex];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];  // background queue only
    if (cb.status == MTLCommandBufferStatusError) {
        error = "GPU upload failed for " + path;
        return false;
    }
    std::lock_guard lock(mutex_);
    ImageEntry& e = images_[asset];
    e.generation = generation;
    e.texture = tex;
    e.pending = false;
    e.bytes = w * h * 4 * 4 / 3;  // + mip chain
    return true;
}

void MetalRenderer::requestImage(ObjectId asset, uint32_t generation, const std::string& path,
                                 std::function<void(bool, const std::string&)> done) {
    {
        std::lock_guard lock(mutex_);
        ImageEntry& e = images_[asset];
        if ((e.texture && e.generation == generation) || (e.pending && e.generation == generation)) return;
        e.generation = generation;
        e.pending = true;
        e.texture = nil;
    }
    std::string p = path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string err;
        const bool ok = decodeAndUpload(asset, generation, p, err);
        if (!ok) {
            std::lock_guard lock(mutex_);
            images_[asset].pending = false;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(ok, err);
        });
    });
}

bool MetalRenderer::loadImageSync(ObjectId asset, uint32_t generation, const std::string& path, std::string& error) {
    return decodeAndUpload(asset, generation, path, error);
}

bool MetalRenderer::hasImage(ObjectId asset, uint32_t generation) const { return imageTexture(asset, generation) != nil; }

bool MetalRenderer::imagePending(ObjectId asset, uint32_t generation) const {
    std::lock_guard lock(mutex_);
    auto it = images_.find(asset);
    return it != images_.end() && it->second.pending && it->second.generation == generation;
}

id<MTLTexture> MetalRenderer::imageTexture(ObjectId asset, uint32_t generation) const {
    std::lock_guard lock(mutex_);
    auto it = images_.find(asset);
    if (it == images_.end() || it->second.generation != generation) return nil;
    return it->second.texture;
}

// ---- compositing ----------------------------------------------------------------------------

void MetalRenderer::runKernel(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> pso,
                              const std::vector<id<MTLTexture>>& textures, const void* params, size_t length) {
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    for (size_t i = 0; i < textures.size(); ++i) [enc setTexture:textures[i] atIndex:i];
    if (params) [enc setBytes:params length:length atIndex:0];
    id<MTLTexture> out = textures.back();
    const NSUInteger tw = pso.threadExecutionWidth, th = std::max<NSUInteger>(1, pso.maxTotalThreadsPerThreadgroup / tw);
    [enc dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(tw, std::min<NSUInteger>(th, 16), 1)];
    [enc endEncoding];
}

id<MTLTexture> MetalRenderer::blur(id<MTLCommandBuffer> cb, id<MTLTexture> src, double sigma, Arena& arena) {
    if (sigma < 0.2) return src;
    // Quantise sigma (1/8 px) so animated radii reuse a handful of MPS kernels.
    const int key = int(std::lround(sigma * 8));
    MPSImageGaussianBlur* k = nil;
    {
        std::lock_guard lock(mutex_);
        auto it = blurKernels_.find(key);
        if (it != blurKernels_.end()) k = it->second;
    }
    if (!k) {
        k = [[MPSImageGaussianBlur alloc] initWithDevice:device_ sigma:float(key / 8.0)];
        k.edgeMode = MPSImageEdgeModeZero;  // outside the region is transparent
        std::lock_guard lock(mutex_);
        if (blurKernels_.size() > 64) blurKernels_.clear();
        blurKernels_[key] = k;
    }
    id<MTLTexture> dst = nil;
    for (auto it = arena.free.begin(); it != arena.free.end(); ++it)
        if ((*it).width == src.width && (*it).height == src.height) {
            dst = *it;
            arena.free.erase(it);
            break;
        }
    if (!dst) {
        dst = acquire(int(src.width), int(src.height), PoolKind::Scratch);
        arena.all.push_back(dst);
    }
    [k encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst];
    arena.free.push_back(src);
    return dst;
}

id<MTLTexture> MetalRenderer::applyEffect(id<MTLCommandBuffer> cb, id<MTLTexture> src, const EffectEval& e,
                                          double scale, Arena& arena) {
    auto take = [&](id<MTLTexture> like) {
        for (auto it = arena.free.begin(); it != arena.free.end(); ++it)
            if ((*it).width == like.width && (*it).height == like.height) {
                id<MTLTexture> t = *it;
                arena.free.erase(it);
                return t;
            }
        id<MTLTexture> t = acquire(int(like.width), int(like.height), PoolKind::Scratch);
        arena.all.push_back(t);
        return t;
    };
    auto release = [&](id<MTLTexture> t) { arena.free.push_back(t); };
    const auto& v = e.v;
    FxParams p;
    switch (e.type) {
        case EffectType::GaussianBlur:
            // Radius is the visible extent (~3 sigma), in layer pixels.
            return blur(cb, src, v[0] * scale / 3.0, arena);

        case EffectType::DropShadow: {
            // Direction: 0° points up, clockwise (135° = down-right), as in most motion tools.
            const double rad = v[5] * M_PI / 180.0, dist = v[6] * scale;
            for (int i = 0; i < 4; ++i) p.a[i] = float(v[size_t(i)]);
            p.b[0] = float(std::sin(rad) * dist);
            p.b[1] = float(-std::cos(rad) * dist);
            p.b[2] = float(v[4] / 100.0);
            id<MTLTexture> shadow = take(src);
            runKernel(cb, fxShadow_, {src, shadow}, &p, sizeof p);
            shadow = blur(cb, shadow, v[7] * scale / 3.0, arena);
            id<MTLTexture> out = take(src);
            runKernel(cb, fxOver_, {src, shadow, out}, nullptr, 0);
            release(src);
            release(shadow);
            return out;
        }

        case EffectType::Glow: {
            p.a[0] = float(v[0] / 100.0);
            id<MTLTexture> bright = take(src);
            runKernel(cb, fxBright_, {src, bright}, &p, sizeof p);
            id<MTLTexture> glow = blur(cb, bright, v[1] * scale / 3.0, arena);
            FxParams g;
            g.a[0] = float(v[2] / 100.0);
            id<MTLTexture> out = take(src);
            runKernel(cb, fxGlow_, {src, glow, out}, &g, sizeof g);
            release(src);
            release(glow);
            return out;
        }

        case EffectType::BrightnessContrast:
        case EffectType::HueSaturation:
        case EffectType::Fill: {
            if (e.type == EffectType::BrightnessContrast) {
                p.a[0] = float(v[0]);
                p.a[1] = float(v[1]);
                p.d[0] = 0;
            } else if (e.type == EffectType::HueSaturation) {
                p.a[0] = float(v[0]);
                p.a[1] = float(v[1]);
                p.a[2] = float(v[2]);
                p.d[0] = 1;
            } else {
                for (int i = 0; i < 4; ++i) p.a[i] = float(v[size_t(i)]);
                p.b[0] = float(v[4] / 100.0);
                p.d[0] = 2;
            }
            id<MTLTexture> out = take(src);
            runKernel(cb, fxColor_, {src, out}, &p, sizeof p);
            release(src);
            return out;
        }
        case EffectType::Count: break;
    }
    return src;
}

void MetalRenderer::encodeItemsPass(id<MTLCommandBuffer> cb, id<MTLTexture> target, const FrameDesc& f,
                                    const std::vector<PassItem>& items, Arena& arena, bool* complete, uint64_t* draws) {
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    enc.label = @"layers";
    const size_t n = items.size();
    if (n == 0) {
        [enc endEncoding];
        return;
    }
    size_t maskCount = 0;
    for (const PassItem& it : items) maskCount += it.masks ? it.d.maskCount : 0;
    // Sub-allocate this pass's instances and masks from the frame's buffer (256-byte aligned).
    const size_t itemBytes = n * sizeof(ItemGPU);
    const size_t maskBytes = std::max<size_t>(1, maskCount) * sizeof(MaskGPU);
    const size_t offset = (arena.used + 255) & ~size_t(255);
    const size_t maskOffset = (offset + itemBytes + 255) & ~size_t(255);
    if (!arena.buffer || maskOffset + maskBytes > arena.buffer.length) {
        // Rare: the up-front estimate was too small. Retire the old buffer with the frame.
        id<MTLBuffer> old = arena.buffer;
        if (old) [cb addCompletedHandler:^(id<MTLCommandBuffer>) { recycleBuffer(old); }];
        arena.buffer = acquireBuffer(std::max<size_t>(itemBytes + maskBytes + 512, 256 * 1024));
        arena.used = 0;
        encodeItemsPass(cb, target, f, items, arena, complete, draws);  // retry into the new buffer
        [enc endEncoding];
        return;
    }
    arena.used = maskOffset + maskBytes;
    auto* g = reinterpret_cast<ItemGPU*>(static_cast<uint8_t*>(arena.buffer.contents) + offset);
    auto* mg = reinterpret_cast<MaskGPU*>(static_cast<uint8_t*>(arena.buffer.contents) + maskOffset);
    size_t mi = 0;
    for (size_t i = 0; i < n; ++i) {
        const PassItem& it = items[i];
        packItem(it.d, g[i]);
        if (it.masks && it.d.maskCount) {
            g[i].p1[2] = float(mi);
            g[i].p1[3] = float(it.d.maskCount);
            for (uint32_t k = 0; k < it.d.maskCount; ++k) packMask(f.masks[it.d.maskStart + k], mg[mi++]);
        }
    }
    const FrameUniformsGPU fu{{float(target.width), float(target.height)}, {0, 0}};
    [enc setVertexBytes:&fu length:sizeof fu atIndex:0];
    [enc setVertexBuffer:arena.buffer offset:offset atIndex:1];
    [enc setFragmentBuffer:arena.buffer offset:offset atIndex:1];
    [enc setFragmentBuffer:arena.buffer offset:maskOffset atIndex:2];
    [enc setFragmentSamplerState:linearMip_ atIndex:0];

    id<MTLRenderPipelineState> bound = nil;
    auto textureFor = [&](const PassItem& it) -> id<MTLTexture> {
        return it.tex ? it.tex : imageTexture(it.d.asset, it.d.assetGeneration);
    };
    auto masked = [](const PassItem& it) { return it.masks && it.d.maskCount > 0; };
    size_t i = 0;
    while (i < n) {
        const PassItem& it = items[i];
        const bool m = masked(it);
        size_t j = i + 1;
        if (it.d.kind == LayerKind::Image) {
            id<MTLTexture> tex = textureFor(it);
            while (j < n && items[j].d.kind == LayerKind::Image && masked(items[j]) == m && textureFor(items[j]) == tex) ++j;
            if (!tex) {  // still decoding: draw the rest, mark the frame incomplete
                *complete = false;
                i = j;
                continue;
            }
            id<MTLRenderPipelineState> pso = m ? imageMaskPSO_ : imagePSO_;
            if (bound != pso) [enc setRenderPipelineState:(bound = pso)];
            [enc setFragmentTexture:tex atIndex:0];
        } else {
            while (j < n && items[j].d.kind != LayerKind::Image && masked(items[j]) == m) ++j;
            id<MTLRenderPipelineState> pso = m ? shapeMaskPSO_ : shapePSO_;
            if (bound != pso) [enc setRenderPipelineState:(bound = pso)];
        }
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:j - i baseInstance:i];
        ++*draws;
        i = j;
    }
    [enc endEncoding];
}

MetalRenderer::Prepared MetalRenderer::renderOffscreen(id<MTLCommandBuffer> cb, const FrameDesc& f, const DrawItem& d,
                                                      bool keepOpacity, const int* forced, Arena& arena,
                                                      bool* complete) {
    Prepared out;
    int r[4];
    if (forced) std::copy(forced, forced + 4, r);
    else if (!offscreenRegion(f, d, r)) return out;
    id<MTLTexture> layer = nil;
    for (auto it = arena.free.begin(); it != arena.free.end(); ++it)
        if (int((*it).width) == r[2] && int((*it).height) == r[3]) {
            layer = *it;
            arena.free.erase(it);
            break;
        }
    if (!layer) {
        layer = acquire(r[2], r[3], PoolKind::Scratch);
        arena.all.push_back(layer);
    }

    // The layer itself, in region coordinates. Opacity and blend mode are applied when the result
    // is composited (effects see the full-opacity layer); a matte source keeps its opacity.
    PassItem pi;
    pi.d = d;
    pi.d.toTarget = Affine::translate(-r[0], -r[1]) * d.toTarget;
    pi.d.blend = BlendMode::Normal;
    if (!keepOpacity) pi.d.opacity = 1;
    uint64_t draws = 0;
    encodeItemsPass(cb, layer, f, {pi}, arena, complete, &draws);

    const double scale = effectScale(d);
    for (uint32_t i = 0; i < d.effectCount; ++i) layer = applyEffect(cb, layer, f.effects[d.effectStart + i], scale, arena);

    if (d.matte >= 0) {
        const Prepared m = renderOffscreen(cb, f, f.mattes[size_t(d.matte)], true, r, arena, complete);
        id<MTLTexture> matted = nil;
        for (auto it = arena.free.begin(); it != arena.free.end(); ++it)
            if ((*it).width == layer.width && (*it).height == layer.height) {
                matted = *it;
                arena.free.erase(it);
                break;
            }
        if (!matted) {
            matted = acquire(r[2], r[3], PoolKind::Scratch);
            arena.all.push_back(matted);
        }
        FxParams p;
        p.a[0] = float(static_cast<int>(d.matteMode));
        runKernel(cb, fxMatte_, {layer, m.tex ? m.tex : emptyTexture_, matted}, &p, sizeof p);
        arena.free.push_back(layer);
        if (m.tex) arena.free.push_back(m.tex);
        layer = matted;
    }
    out.tex = layer;
    out.x = r[0];
    out.y = r[1];
    return out;
}

void MetalRenderer::encodeComposite(const FrameDesc& f, id<MTLCommandBuffer> cb, id<MTLTexture> target,
                                    bool* complete) {
    const double t0 = nowMs();
    *complete = true;
    auto arena = std::make_shared<Arena>();
    {
        // One instance buffer for the whole frame: every layer may be drawn twice (offscreen + final),
        // plus its masks (and a matte source's), with per-pass alignment slack.
        const size_t passes = 1 + size_t(f.offscreenItems()) * 2;
        const size_t bytes = (f.items.size() * 2 + f.mattes.size()) * sizeof(ItemGPU) +
                             f.masks.size() * 2 * sizeof(MaskGPU) + passes * 512 + sizeof(MaskGPU);
        arena->buffer = acquireBuffer(bytes);
    }

    // 1. Layers with effects / mattes, rendered on their own first.
    std::vector<PassItem> items;
    items.reserve(f.items.size());
    uint64_t offscreen = 0;
    for (const DrawItem& d : f.items) {
        PassItem pi;
        pi.d = d;
        if (d.needsOffscreen()) {
            ++offscreen;
            const Prepared p = renderOffscreen(cb, f, d, false, nullptr, *arena, complete);
            if (!p.tex) continue;
            // Keep the result out of the free list: the composite pass below still reads it.
            arena->free.erase(std::remove(arena->free.begin(), arena->free.end(), p.tex), arena->free.end());
            DrawItem q;
            q.layerId = d.layerId;
            q.kind = LayerKind::Image;
            q.blend = d.blend;
            q.opacity = d.opacity;
            q.toTarget = Affine::translate(p.x, p.y);
            q.boundsMin = {0, 0};
            q.boundsMax = {double(p.tex.width), double(p.tex.height)};
            pi.d = q;
            pi.tex = p.tex;
            pi.masks = false;  // masks were applied offscreen
        }
        items.push_back(pi);
    }

    // 2. The composition itself, bottom to top, in one pass.
    uint64_t draws = 0;
    encodeItemsPass(cb, target, f, items, *arena, complete, &draws);

    const double encodeMs = nowMs() - t0;
    const uint64_t key = costKey(f);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        const double gpu = (c.GPUEndTime - c.GPUStartTime) * 1000.0;
        if (arena->buffer) recycleBuffer(arena->buffer);
        std::lock_guard lock(mutex_);
        for (id<MTLTexture> t : arena->all) recycleLocked(t);
        stats_.lastGpuMs = gpu;
        stats_.avgGpuMs = stats_.avgGpuMs == 0 ? gpu : stats_.avgGpuMs * 0.9 + gpu * 0.1;
        double& cost = costMs_[key];
        cost = cost == 0 ? gpu : cost * 0.7 + gpu * 0.3;
    }];
    std::lock_guard lock(mutex_);
    stats_.framesEncoded++;
    stats_.lastEncodeMs = encodeMs;
    stats_.drawCalls = draws;
    stats_.offscreenLayers = offscreen;
}

bool MetalRenderer::admitLocked(const FrameDesc& f) const {
    switch (policy_) {
        case CachePolicy::Off: return false;
        case CachePolicy::All: return true;
        case CachePolicy::Smart: {
            if (f.offscreenItems() > 0) return true;
            auto it = costMs_.find(costKey(f));
            return it != costMs_.end() && it->second >= admitMs_;
        }
    }
    return false;
}

id<MTLTexture> MetalRenderer::compositeFrame(const FrameDesc& f, id<MTLCommandBuffer> cb, bool useCache,
                                             bool* cacheHit, bool* complete, id<MTLCommandBuffer> releaseOn) {
    *cacheHit = false;
    *complete = true;
    bool admit = false;
    if (useCache) {
        std::lock_guard lock(mutex_);
        if (__strong id<MTLTexture>* t = cache_.find(f.hash)) {
            stats_.cacheHits++;
            *cacheHit = true;
            return *t;
        }
        stats_.cacheMisses++;
        admit = admitLocked(f);
    }
    id<MTLTexture> target = acquire(f.width, f.height, PoolKind::Target);
    if (!target) return nil;
    encodeComposite(f, cb, target, complete);
    if (admit && *complete) {
        id<MTLTexture> copy = acquire(f.width, f.height, PoolKind::Cache8);
        runKernel(cb, toRGBA8_, {target, copy}, nullptr, 0);
        std::lock_guard lock(mutex_);
        cache_.insert(f.hash, copy, cachedFrameBytes(f.width, f.height));
        stats_.cacheAdmitted++;
    } else if (useCache && *complete) {
        std::lock_guard lock(mutex_);
        stats_.cacheSkippedCheap++;
    }
    [(releaseOn ? releaseOn : cb) addCompletedHandler:^(id<MTLCommandBuffer>) { recycle(target); }];
    return target;
}

void MetalRenderer::encodePresent(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor* pass, id<MTLTexture> frame,
                                  const PresentParams& p, int targetWidth, int targetHeight) {
    id<MTLRenderPipelineState> pso = presentPipeline(pass.colorAttachments[0].texture.pixelFormat);
    if (!pso) return;
    PresentUniformsGPU u{};
    u.compOrigin[0] = float(p.originX);
    u.compOrigin[1] = float(p.originY);
    u.compSize[0] = float(p.compWidth * p.scale);
    u.compSize[1] = float(p.compHeight * p.scale);
    for (int i = 0; i < 4; ++i) {
        u.background[i] = float(p.background[size_t(i)]);
        u.viewerBg[i] = float(p.viewerBackground[size_t(i)]);
    }
    u.checker = p.checkerboard ? 1.f : 0.f;
    u.checkerSize = 16.f;
    (void)targetWidth;
    (void)targetHeight;

    id<MTLTexture> tex = frame ? frame : emptyTexture_;
    // Crisp pixels when magnified 2x or more, otherwise bilinear.
    const double magnification = frame ? (u.compSize[0] / double(frame.width)) : 1.0;
    id<MTLSamplerState> smp = magnification >= 2.0 ? nearest_ : linear_;

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    enc.label = @"present";
    [enc setRenderPipelineState:pso];
    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
    [enc setFragmentTexture:tex atIndex:0];
    [enc setFragmentSamplerState:smp atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
}

bool MetalRenderer::renderToRGBA(const FrameDesc& f, std::vector<float>& rgba, double* gpuMs, std::string& error) {
    id<MTLTexture> target = acquire(f.width, f.height, PoolKind::Target);
    if (!target) {
        error = "Cannot allocate render target";
        return false;
    }
    id<MTLCommandBuffer> cb = [queue_ commandBuffer];
    bool complete = true;
    encodeComposite(f, cb, target, &complete);
    const size_t rowBytes = size_t(f.width) * 8;
    id<MTLBuffer> rb = [device_ newBufferWithLength:rowBytes * size_t(f.height) options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(NSUInteger(f.width), NSUInteger(f.height), 1)
                        toBuffer:rb
               destinationOffset:0
          destinationBytesPerRow:rowBytes
        destinationBytesPerImage:rowBytes * size_t(f.height)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    recycle(target);
    if (cb.status == MTLCommandBufferStatusError) {
        error = std::string("GPU error: ") + (cb.error ? cb.error.localizedDescription.UTF8String : "unknown");
        return false;
    }
    if (!complete) {
        error = "Frame references media that is not loaded";
        return false;
    }
    if (gpuMs) *gpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
    const size_t count = size_t(f.width) * size_t(f.height) * 4;
    rgba.resize(count);
    const auto* half = static_cast<const _Float16*>(rb.contents);
    for (size_t i = 0; i < count; ++i) rgba[i] = float(half[i]);
    return true;
}

// ---- cache & memory -------------------------------------------------------------------------

bool MetalRenderer::cacheContains(uint64_t hash) const {
    std::lock_guard lock(mutex_);
    return cache_.contains(hash);
}

bool MetalRenderer::wouldCache(const FrameDesc& f) const {
    std::lock_guard lock(mutex_);
    return admitLocked(f);
}

void MetalRenderer::setCachePolicy(CachePolicy p) {
    std::lock_guard lock(mutex_);
    policy_ = p;
    if (p == CachePolicy::Off) cache_.clear();
}

CachePolicy MetalRenderer::cachePolicy() const {
    std::lock_guard lock(mutex_);
    return policy_;
}

void MetalRenderer::setAdmissionThresholdMs(double ms) {
    std::lock_guard lock(mutex_);
    admitMs_ = ms;
}

double MetalRenderer::measuredCostMs(const FrameDesc& f) const {
    std::lock_guard lock(mutex_);
    auto it = costMs_.find(costKey(f));
    return it == costMs_.end() ? 0 : it->second;
}

void MetalRenderer::setCacheBudget(size_t bytes) {
    std::lock_guard lock(mutex_);
    cache_.setBudget(bytes);
}

void MetalRenderer::setPoolBudget(size_t bytes) {
    std::lock_guard lock(mutex_);
    poolBudget_ = bytes;
    if (poolBytes_ > poolBudget_) {
        pool_.clear();
        poolBytes_ = 0;
    }
}

void MetalRenderer::clearCache() {
    std::lock_guard lock(mutex_);
    cache_.clear();
    costMs_.clear();  // composition ids restart per project, so old estimates don't apply
}

void MetalRenderer::handleMemoryPressure(PressureLevel level) {
    std::lock_guard lock(mutex_);
    stats_.pressureEvents++;
    if (level == PressureLevel::Normal) return;
    // Warning: keep a quarter of the cached frames; critical: drop everything that can be
    // recreated. Imported media stays (it would only be re-decoded immediately).
    cache_.purgeTo(level == PressureLevel::Warning ? cache_.budget() / 4 : 0);
    pool_.clear();
    poolBytes_ = 0;
    freeBuffers_.clear();
    blurKernels_.clear();
}

RendererStats MetalRenderer::stats() const {
    std::lock_guard lock(mutex_);
    RendererStats s = stats_;
    s.cacheBytes = cache_.bytes();
    s.cacheBudget = cache_.budget();
    s.cacheFrames = cache_.size();
    s.poolBytes = poolBytes_;
    s.assetBytes = 0;
    s.pendingAssets = 0;
    for (const auto& [id, e] : images_) {
        s.assetBytes += e.texture ? e.bytes : 0;
        s.pendingAssets += e.pending ? 1 : 0;
    }
    s.deviceAllocated = device_.currentAllocatedSize;
    s.recommendedWorkingSet = size_t(device_.recommendedMaxWorkingSetSize);
    return s;
}

void MetalRenderer::resetCounters() {
    std::lock_guard lock(mutex_);
    stats_.framesEncoded = stats_.cacheHits = stats_.cacheMisses = 0;
    stats_.cacheAdmitted = stats_.cacheSkippedCheap = 0;
    stats_.avgGpuMs = 0;
}

}  // namespace mf
