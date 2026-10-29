#import "MFRender/MetalRenderer.hpp"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cmath>

#include "Shaders.hpp"
#include "TextEngine.hpp"
#include "VideoDecoder.hpp"

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
    float p2[4];  // bezier paths: fill edge start/count, stroke edge start/count
    float m3[4];  // 3D layers: perspective row (gx, gy, w)
};
static_assert(sizeof(ItemGPU) == 144, "ItemGPU must match the MSL layout");

struct EdgeGPU {
    float x0, y0, x1, y1;
};

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
    g.p2[0] = g.p2[1] = g.p2[2] = g.p2[3] = 0;
    g.m3[0] = float(d.persp.x);
    g.m3[1] = float(d.persp.y);
    g.m3[2] = float(d.perspW);
    g.m3[3] = 0;
}

void appendEdges(const std::vector<Vec2>& pts, bool close, std::vector<EdgeGPU>& out) {
    for (size_t i = 0; i + 1 < pts.size(); ++i)
        out.push_back({float(pts[i].x), float(pts[i].y), float(pts[i + 1].x), float(pts[i + 1].y)});
    if (close && pts.size() > 2 && (pts.front().x != pts.back().x || pts.front().y != pts.back().y))
        out.push_back({float(pts.back().x), float(pts.back().y), float(pts.front().x), float(pts.front().y)});
}

// Stroke edges of a polyline trimmed to [start, end] (+ offset) as fractions of its length.
// Closed paths wrap around; open paths clamp.
void trimmedEdges(const std::vector<Vec2>& pts, bool closed, double s, double e, double o, std::vector<EdgeGPU>& out) {
    if (pts.size() < 2) return;
    std::vector<double> len(pts.size(), 0);
    for (size_t i = 1; i < pts.size(); ++i) len[i] = len[i - 1] + std::hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
    const double T = len.back();
    if (T <= 0) return;
    if (e < s) std::swap(s, e);
    if (e - s >= 1 - 1e-9) {
        appendEdges(pts, false, out);
        return;
    }
    auto range = [&](double A, double B) {
        for (size_t i = 0; i + 1 < pts.size(); ++i) {
            const double l0 = len[i], l1 = len[i + 1];
            const double a = std::max(A, l0), b = std::min(B, l1);
            if (b <= a || l1 <= l0) continue;
            auto at = [&](double d) {
                const double t = (d - l0) / (l1 - l0);
                return Vec2{pts[i].x + (pts[i + 1].x - pts[i].x) * t, pts[i].y + (pts[i + 1].y - pts[i].y) * t};
            };
            const Vec2 p = at(a), q = at(b);
            out.push_back({float(p.x), float(p.y), float(q.x), float(q.y)});
        }
    };
    double a = s + o, b = e + o;
    if (closed) {
        const double k = std::floor(a);
        a -= k;
        b -= k;
        if (b > 1) {
            range(a * T, T);
            range(0, (b - 1) * T);
        } else {
            range(a * T, b * T);
        }
    } else {
        a = std::clamp(a, 0.0, 1.0);
        b = std::clamp(b, 0.0, 1.0);
        if (b > a) range(a * T, b * T);
    }
}

// Per-glyph transform (layer space) and opacity from the text animators.
Affine glyphTransform(const FrameDesc& f, const DrawItem& d, const TextLayout& lay, const GlyphInfo& g, double* opacity) {
    Vec2 off{0, 0};
    double s = 1, rot = 0, op = 1;
    for (uint32_t i = 0; i < d.animatorCount; ++i) {
        const AnimatorEval& a = f.animators[d.animatorStart + i];
        const int n = a.unit == SelectorUnit::Characters ? lay.characters : a.unit == SelectorUnit::Words ? lay.words : lay.lines;
        const int idx = a.unit == SelectorUnit::Characters ? g.character : a.unit == SelectorUnit::Words ? g.word : g.line;
        const double w = selectorWeight(a.shape, a.start + a.offset, a.end + a.offset, idx, n) * a.amountOf(idx);
        if (w == 0) continue;
        off = off + a.position * w;
        s *= 1 + (a.scale - 1) * w;
        rot += a.rotation * w;
        op *= 1 + (a.opacity - 1) * w;
    }
    *opacity = std::clamp(op, 0.0, 1.0);
    // Characters scale and rotate about their baseline centre.
    const Vec2 anchor{g.origin.x + (g.rect.origin.x + g.rect.size.width * 0.5), g.origin.y};
    return Affine::translate(anchor.x + off.x, anchor.y + off.y) * Affine::rotateDegrees(rot) * Affine::scale(s, s) *
           Affine::translate(-anchor.x, -anchor.y);
}

// Layer-space box around every animated glyph (offscreen regions must contain moved characters).
void textGlyphBounds(const FrameDesc& f, const DrawItem& d, Vec2& mn, Vec2& mx) {
    auto lay = layoutText(d.text);
    mn = d.boundsMin;
    mx = d.boundsMax;
    if (d.animatorCount == 0) return;
    for (const GlyphInfo& g : lay->glyphs) {
        double op;
        const Affine t = glyphTransform(f, d, *lay, g, &op);
        const CGRect r = g.rect;
        for (Vec2 c : {Vec2{r.origin.x, -r.origin.y}, Vec2{r.origin.x + r.size.width, -r.origin.y},
                       Vec2{r.origin.x, -(r.origin.y + r.size.height)}, Vec2{r.origin.x + r.size.width, -(r.origin.y + r.size.height)}}) {
            const Vec2 q = t.apply(g.origin + c);
            mn = {std::min(mn.x, q.x), std::min(mn.y, q.y)};
            mx = {std::max(mx.x, q.x), std::max(mx.y, q.y)};
        }
    }
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
    Vec2 bmn = d.boundsMin, bmx = d.boundsMax;
    if (d.kind == LayerKind::Text) textGlyphBounds(f, d, bmn, bmx);
    const Vec2 corners[4] = {{bmn.x - pad, bmn.y - pad}, {bmx.x + pad, bmn.y - pad}, {bmx.x + pad, bmx.y + pad}, {bmn.x - pad, bmx.y + pad}};
    double x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
    for (const Vec2& c : corners) {
        const Vec2 p = d.project(c);
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
    // Image decodes run on a background queue with `this`: let them finish first (a short-lived
    // engine, e.g. one opened just to read a file, can go away while its media is still decoding).
    dispatch_group_wait(decodes_, DISPATCH_TIME_FOREVER);
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

    auto makeItemPSO = [&](NSString* fragment, NSString* label, bool masks, bool paths = false) -> id<MTLRenderPipelineState> {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.label = label;
        MTLFunctionConstantValues* fc = [MTLFunctionConstantValues new];
        bool m = masks, p = paths;
        [fc setConstantValue:&m type:MTLDataTypeBool atIndex:0];
        [fc setConstantValue:&p type:MTLDataTypeBool atIndex:1];
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
    glyphPSO_ = makeItemPSO(@"glyph_fragment", @"glyphs", false);
    shapePathPSO_ = makeItemPSO(@"shape_fragment", @"paths", false, true);
    shapePathMaskPSO_ = makeItemPSO(@"shape_fragment", @"masked paths", true, true);
    imagePathMaskPSO_ = makeItemPSO(@"image_fragment", @"images with path masks", true, true);
    {
        // Masks on assembled text: destination x mask, via fixed-function blending.
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.label = @"mask apply";
        MTLFunctionConstantValues* fc = [MTLFunctionConstantValues new];
        bool m = true;
        [fc setConstantValue:&m type:MTLDataTypeBool atIndex:0];
        [fc setConstantValue:&m type:MTLDataTypeBool atIndex:1];
        NSError* e = nil;
        d.vertexFunction = [lib newFunctionWithName:@"item_vertex" constantValues:fc error:&e];
        d.fragmentFunction = [lib newFunctionWithName:@"mask_apply_fragment" constantValues:fc error:&e];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        auto* ca = d.colorAttachments[0];
        ca.blendingEnabled = YES;
        ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = MTLBlendFactorZero;
        ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        maskApplyPSO_ = [device_ newRenderPipelineStateWithDescriptor:d error:&e];
    }
    glyphs_ = std::make_unique<GlyphSheetCache>(device_);
    static std::once_flag measurerOnce;
    std::call_once(measurerOnce, [] {
        setTextMeasurer([](const TextStyle& st, Vec2& mn, Vec2& mx) {
            auto lay = layoutText(st);
            mn = lay->mn;
            mx = lay->mx;
        });
    });
    fxShadow_ = makeKernel(@"fx_shadow");
    fxOver_ = makeKernel(@"fx_over");
    fxBright_ = makeKernel(@"fx_bright");
    fxGlow_ = makeKernel(@"fx_glow");
    fxColor_ = makeKernel(@"fx_color");
    fxMatte_ = makeKernel(@"fx_matte");
    fxRamp_ = makeKernel(@"fx_ramp");
    fxAccum_ = makeKernel(@"fx_accum");
    toBGRA8_ = makeKernel(@"to_bgra8");
    toRGBA8_ = makeKernel(@"to_rgba8");
    presentVS_ = [lib newFunctionWithName:@"present_vertex"];
    presentFS_ = [lib newFunctionWithName:@"present_fragment"];
    if (!shapePSO_ || !imagePSO_ || !shapeMaskPSO_ || !imageMaskPSO_ || !glyphPSO_ || !maskApplyPSO_ || !shapePathPSO_ ||
        !shapePathMaskPSO_ || !imagePathMaskPSO_ || !fxShadow_ || !fxOver_ || !fxBright_ || !fxGlow_ || !fxColor_ || !fxMatte_ || !fxRamp_ || !fxAccum_ || !toBGRA8_ ||
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

namespace {

// SVG and PDF artwork, which ImageIO doesn't read: drawn by AppKit, small artwork at about 1000 px so
// it stays sharp when scaled up (the first page of a PDF).
CGImageRef rasterizeVector(NSURL* url) {
    NSImage* img = [[NSImage alloc] initWithContentsOfURL:url];
    if (!img || img.size.width < 1 || img.size.height < 1) return nullptr;
    const double s = std::max(1.0, 1000.0 / std::max(img.size.width, img.size.height));
    const size_t w = size_t(std::clamp(std::lround(img.size.width * s), 1L, 8192L));
    const size_t h = size_t(std::clamp(std::lround(img.size.height * s), 1L, 8192L));
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nullptr;
    NSGraphicsContext* g = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = g;
    [img drawInRect:NSMakeRect(0, 0, w, h) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

bool isVectorFile(const std::string& path) {
    NSString* ext = @(path.c_str()).pathExtension.lowercaseString;
    return [ext isEqualToString:@"svg"] || [ext isEqualToString:@"svgz"] || [ext isEqualToString:@"pdf"] ||
           [ext isEqualToString:@"ai"] || [ext isEqualToString:@"eps"];
}

}  // namespace

bool MetalRenderer::probeImage(const std::string& path, int& width, int& height, std::string& error) {
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    if (isVectorFile(path)) {
        CGImageRef img = rasterizeVector(url);
        if (!img) {
            error = "Cannot read the artwork in " + path;
            return false;
        }
        width = int(CGImageGetWidth(img));
        height = int(CGImageGetHeight(img));
        CGImageRelease(img);
        return true;
    }
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
    CGImageRef img = nullptr;
    if (isVectorFile(path)) {
        img = rasterizeVector(url);
    } else {
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
    img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    }
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
    dispatch_group_async(decodes_, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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

void MetalRenderer::registerVideo(ObjectId asset, uint32_t generation, const std::string& path, double fps,
                                  int64_t frameCount) {
    std::lock_guard lock(mutex_);
    VideoEntry& e = videos_[asset];
    if (e.decoder && e.generation == generation) return;
    e.generation = generation;
    e.decoder = std::make_shared<VideoDecoder>(device_, path, fps, frameCount);
}

std::shared_ptr<VideoDecoder> MetalRenderer::videoDecoder(ObjectId asset, uint32_t generation) const {
    std::lock_guard lock(mutex_);
    auto it = videos_.find(asset);
    return it != videos_.end() && it->second.generation == generation ? it->second.decoder : nullptr;
}

id<MTLTexture> MetalRenderer::videoTexture(const DrawItem& d, bool* exact) const {
    *exact = false;
    auto decoder = videoDecoder(d.asset, d.assetGeneration);
    return decoder ? decoder->texture(d.videoFrame, exact) : nil;
}

bool MetalRenderer::prepareVideoFrames(const FrameDesc& f, double timeoutSeconds, std::string& error) {
    auto item = [&](const DrawItem& d) -> bool {
        if (d.nested && !prepareVideoFrames(*d.nested, timeoutSeconds, error)) return false;
        if (d.videoFrame < 0) return true;
        auto decoder = videoDecoder(d.asset, d.assetGeneration);
        if (!decoder) return true;  // not registered: drawn without it (as missing media is)
        if (decoder->decodeSync(d.videoFrame, timeoutSeconds)) return true;
        error = decoder->error().empty() ? "Timed out decoding a video frame" : decoder->error();
        return false;
    };
    for (const DrawItem& d : f.items)
        if (!item(d)) return false;
    for (const DrawItem& d : f.mattes)
        if (!item(d)) return false;
    return true;
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
                                          double scale, const Affine& layerToRegion, Arena& arena) {
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
        case EffectType::GradientRamp: {
            const Vec2 a = layerToRegion.apply({v[0], v[1]}), b = layerToRegion.apply({v[6], v[7]});
            p.a[0] = float(a.x);
            p.a[1] = float(a.y);
            p.a[2] = float(b.x);
            p.a[3] = float(b.y);
            for (int i = 0; i < 4; ++i) {
                p.b[i] = float(v[size_t(2 + i)]);
                p.c[i] = float(v[size_t(8 + i)]);
            }
            p.d[0] = float(v[12]);
            p.d[1] = float(v[13] / 100.0);
            id<MTLTexture> out = take(src);
            runKernel(cb, fxRamp_, {src, out}, &p, sizeof p);
            release(src);
            return out;
        }
        case EffectType::Count: break;
    }
    return src;
}

void MetalRenderer::appendGlyphs(const FrameDesc& f, const DrawItem& d, std::vector<PassItem>& out) {
    auto lay = layoutText(d.text);
    if (lay->glyphs.empty()) return;
    auto sheet = glyphs_->sheet(d.text, *lay, effectScale(d), d.strokeOn ? d.strokeWidth : 0);
    if (!sheet || !sheet->texture) return;
    for (size_t i = 0; i < lay->glyphs.size(); ++i) {
        const SheetRect& r = sheet->rects[i];
        if (r.empty) continue;
        const GlyphInfo& g = lay->glyphs[i];
        double op = 1;
        const Affine t = glyphTransform(f, d, *lay, g, &op);
        if (op <= 0 || std::abs(t.determinant()) < 1e-12) continue;
        PassItem pi;
        pi.role = PassItem::Role::Glyph;
        pi.masks = false;
        pi.tex = sheet->texture;
        pi.d.layerId = d.layerId;
        pi.d.kind = LayerKind::Text;
        pi.d.blend = d.blend;
        pi.d.toTarget = d.toTarget;
        pi.d.persp = d.persp;
        pi.d.perspW = d.perspW;
        pi.d.append(t);  // the glyph inside the (possibly 3D) layer
        pi.d.opacity = d.opacity * op;
        pi.d.fill = d.fillOn ? d.fill : Value{};
        pi.d.stroke = {r.u0, r.v0, r.u1, r.v1};
        pi.d.strokeOverFill = d.strokeOverFill;
        if (d.strokeOn) pi.glyphStroke = d.stroke;
        pi.d.boundsMin = g.origin + r.qmin;
        pi.d.boundsMax = g.origin + r.qmax;
        out.push_back(pi);
    }
}

void MetalRenderer::encodeItemsPass(id<MTLCommandBuffer> cb, id<MTLTexture> target, const FrameDesc& f,
                                    const std::vector<PassItem>& items, Arena& arena, bool* complete, uint64_t* draws,
                                    bool clear) {
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    enc.label = @"layers";
    const size_t n = items.size();
    if (n == 0) {
        [enc endEncoding];
        return;
    }
    // Instances, masks and flattened path edges for this pass.
    std::vector<ItemGPU> gi(n);
    std::vector<MaskGPU> gm;
    std::vector<EdgeGPU> ge;
    for (size_t i = 0; i < n; ++i) {
        const PassItem& it = items[i];
        packItem(it.d, gi[i]);
        if (it.role == PassItem::Role::Glyph) {
            for (int k = 0; k < 4; ++k) gi[i].p2[k] = float(it.glyphStroke[size_t(k)]);
            gi[i].p0[0] = 0;  // the quad already covers the stroke
            gi[i].p0[2] = it.d.strokeOverFill ? 1.f : 0.f;
        }
        const double tol = 0.25 / std::max(effectScale(it.d), 1e-6);  // a quarter of a target pixel
        if (it.role == PassItem::Role::Normal && it.d.kind == LayerKind::Shape && it.d.shape == ShapeType::Path) {
            const auto pts = flattenPath(it.d.path, tol);
            gi[i].p2[0] = float(ge.size());
            appendEdges(pts, true, ge);
            gi[i].p2[1] = float(ge.size()) - gi[i].p2[0];
            gi[i].p2[2] = float(ge.size());
            if (it.d.strokeWidth > 0) trimmedEdges(pts, it.d.path.closed, it.d.trimStart, it.d.trimEnd, it.d.trimOffset, ge);
            gi[i].p2[3] = float(ge.size()) - gi[i].p2[2];
        }
        if (it.masks && it.d.maskCount) {
            gi[i].p1[2] = float(gm.size());
            gi[i].p1[3] = float(it.d.maskCount);
            for (uint32_t k = 0; k < it.d.maskCount; ++k) {
                const MaskEval& m = f.masks[it.d.maskStart + k];
                MaskGPU g;
                packMask(m, g);
                if (m.shape == MaskShape::Path) {
                    g.a[2] = float(ge.size());
                    appendEdges(flattenPath(m.path, tol), true, ge);
                    g.a[3] = float(ge.size()) - g.a[2];
                }
                gm.push_back(g);
            }
        }
    }
    // Sub-allocate from the frame's buffer (256-byte aligned sections).
    auto align = [](size_t v) { return (v + 255) & ~size_t(255); };
    const size_t itemBytes = n * sizeof(ItemGPU);
    const size_t maskBytes = std::max<size_t>(1, gm.size()) * sizeof(MaskGPU);
    const size_t edgeBytes = std::max<size_t>(1, ge.size()) * sizeof(EdgeGPU);
    const size_t offset = align(arena.used);
    const size_t maskOffset = align(offset + itemBytes);
    const size_t edgeOffset = align(maskOffset + maskBytes);
    if (!arena.buffer || edgeOffset + edgeBytes > arena.buffer.length) {
        // The up-front estimate was too small (many glyphs or path edges). Retire the old buffer
        // with the frame and continue in a bigger one.
        [enc endEncoding];
        id<MTLBuffer> old = arena.buffer;
        if (old) [cb addCompletedHandler:^(id<MTLCommandBuffer>) { recycleBuffer(old); }];
        arena.buffer = acquireBuffer(std::max<size_t>(itemBytes + maskBytes + edgeBytes + 1024, 256 * 1024) * 2);
        arena.used = 0;
        encodeItemsPass(cb, target, f, items, arena, complete, draws, clear);
        return;
    }
    arena.used = edgeOffset + edgeBytes;
    uint8_t* base = static_cast<uint8_t*>(arena.buffer.contents);
    std::memcpy(base + offset, gi.data(), itemBytes);
    if (!gm.empty()) std::memcpy(base + maskOffset, gm.data(), gm.size() * sizeof(MaskGPU));
    if (!ge.empty()) std::memcpy(base + edgeOffset, ge.data(), ge.size() * sizeof(EdgeGPU));

    const FrameUniformsGPU fu{{float(target.width), float(target.height)}, {0, 0}};
    [enc setVertexBytes:&fu length:sizeof fu atIndex:0];
    [enc setVertexBuffer:arena.buffer offset:offset atIndex:1];
    [enc setFragmentBuffer:arena.buffer offset:offset atIndex:1];
    [enc setFragmentBuffer:arena.buffer offset:maskOffset atIndex:2];
    [enc setFragmentBuffer:arena.buffer offset:edgeOffset atIndex:3];
    [enc setFragmentSamplerState:linearMip_ atIndex:0];

    // Consecutive items sharing a pipeline and texture are one instanced draw.
    bool staleVideo = false;
    auto drawState = [&](const PassItem& it, id<MTLTexture>* tex) -> id<MTLRenderPipelineState> {
        const bool m = it.masks && it.d.maskCount > 0;
        bool pathMask = false;
        for (uint32_t k = 0; m && k < it.d.maskCount; ++k) pathMask = pathMask || f.masks[it.d.maskStart + k].shape == MaskShape::Path;
        *tex = nil;
        switch (it.role) {
            case PassItem::Role::MaskApply: return maskApplyPSO_;
            case PassItem::Role::Glyph: *tex = it.tex; return glyphPSO_;
            case PassItem::Role::Normal: break;
        }
        if (it.d.kind == LayerKind::Image) {
            if (it.tex) {
                *tex = it.tex;
            } else if (it.d.videoFrame >= 0) {  // footage: a stand-in frame keeps playback smooth, never cached
                bool exact = false;
                *tex = videoTexture(it.d, &exact);
                if (!exact) staleVideo = true;
            } else {
                *tex = imageTexture(it.d.asset, it.d.assetGeneration);
            }
            return pathMask ? imagePathMaskPSO_ : m ? imageMaskPSO_ : imagePSO_;
        }
        if (it.d.shape == ShapeType::Path || pathMask) return m ? shapePathMaskPSO_ : shapePathPSO_;
        return m ? shapeMaskPSO_ : shapePSO_;
    };
    id<MTLRenderPipelineState> bound = nil;
    size_t i = 0;
    while (i < n) {
        id<MTLTexture> tex = nil;
        id<MTLRenderPipelineState> pso = drawState(items[i], &tex);
        size_t j = i + 1;
        for (; j < n; ++j) {
            id<MTLTexture> t2 = nil;
            if (drawState(items[j], &t2) != pso || t2 != tex) break;
        }
        const bool needsTexture = pso == imagePSO_ || pso == imageMaskPSO_ || pso == imagePathMaskPSO_ || pso == glyphPSO_;
        if (needsTexture && !tex) {  // media still decoding: draw the rest, mark the frame incomplete
            *complete = false;
            i = j;
            continue;
        }
        if (bound != pso) [enc setRenderPipelineState:(bound = pso)];
        if (tex) [enc setFragmentTexture:tex atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:j - i baseInstance:i];
        ++*draws;
        i = j;
    }
    [enc endEncoding];
    if (staleVideo) *complete = false;
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
    pi.d.prepend(Affine::translate(-r[0], -r[1]));  // (3D layers stay in perspective)
    pi.d.blend = BlendMode::Normal;
    if (!keepOpacity) pi.d.opacity = 1;
    uint64_t draws = 0;
    if (d.nested) {
        // A precomp: its own layers (with their effects, mattes and blend modes) as one group.
        uint64_t nestedOffscreen = 0;
        encodeLayers(*d.nested, cb, layer, r[0], r[1], arena, complete, &draws, &nestedOffscreen);
        if (d.clipSize.x > 0 && d.clipSize.y > 0) {  // not collapsed: clipped to the source's frame
            FrameDesc clip;
            MaskEval m;
            m.center = d.clipSize * 0.5;
            m.halfSize = d.clipSize * 0.5;
            clip.masks.push_back(m);
            DrawItem c = d;
            c.maskStart = 0;
            c.maskCount = 1;
            applyMasks(cb, layer, clip, c, r, arena, complete);
        }
        if (d.maskCount > 0) applyMasks(cb, layer, f, d, r, arena, complete);
        if (keepOpacity && d.opacity < 1) {
            FxParams p;
            p.a[0] = p.a[1] = p.a[2] = p.a[3] = 1;
            p.b[0] = float(d.opacity);
            p.d[0] = 3;  // scale
            id<MTLTexture> out = acquire(r[2], r[3], PoolKind::Scratch);
            arena.all.push_back(out);
            runKernel(cb, fxColor_, {layer, out}, &p, sizeof p);
            arena.free.push_back(layer);
            layer = out;
        }
    } else {
        std::vector<PassItem> pass;
        if (d.kind == LayerKind::Text) appendGlyphs(f, pi.d, pass);
        else pass.push_back(pi);
        encodeItemsPass(cb, layer, f, pass, arena, complete, &draws);
        // Text is drawn glyph by glyph: multiply the assembled text by its masks.
        if (d.kind == LayerKind::Text && d.maskCount > 0) applyMasks(cb, layer, f, d, r, arena, complete);
    }

    const double scale = effectScale(d);
    for (uint32_t i = 0; i < d.effectCount; ++i)
        layer = applyEffect(cb, layer, f.effects[d.effectStart + i], scale, pi.d.toTarget, arena);

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

void MetalRenderer::applyMasks(id<MTLCommandBuffer> cb, id<MTLTexture> tex, const FrameDesc& f, const DrawItem& d,
                               const int* r, Arena& arena, bool* complete) {
    // One quad over the whole region, in the layer's space, multiplying by the masks.
    PassItem m;
    m.role = PassItem::Role::MaskApply;
    m.d = d;
    m.d.prepend(Affine::translate(-r[0], -r[1]));
    m.d.strokeWidth = 0;
    m.d.nested = nullptr;
    // The region's corners in layer space (through the perspective of a 3D layer).
    LayerMapping map;
    map.aff = m.d.toTarget;
    map.persp = m.d.persp;
    map.perspW = m.d.perspW;
    Vec2 mn{1e300, 1e300}, mx{-1e300, -1e300};
    for (Vec2 c : {Vec2{0, 0}, Vec2{double(r[2]), 0}, Vec2{double(r[2]), double(r[3])}, Vec2{0, double(r[3])}}) {
        Vec2 q;
        if (!map.inverse(c, q)) {  // past a 3D layer's horizon: its own bounds cover it
            mn = d.boundsMin;
            mx = d.boundsMax;
            break;
        }
        mn = {std::min(mn.x, q.x), std::min(mn.y, q.y)};
        mx = {std::max(mx.x, q.x), std::max(mx.y, q.y)};
    }
    m.d.boundsMin = mn;
    m.d.boundsMax = mx;
    uint64_t draws = 0;
    encodeItemsPass(cb, tex, f, {m}, arena, complete, &draws, false);
}

void MetalRenderer::encodeLayers(const FrameDesc& f, id<MTLCommandBuffer> cb, id<MTLTexture> target, int ox, int oy,
                                 Arena& arena, bool* complete, uint64_t* draws, uint64_t* offscreen) {
    const Affine shift = Affine::translate(-ox, -oy);
    // 1. Layers with effects / mattes, and precomps, rendered on their own first.
    std::vector<PassItem> items;
    items.reserve(f.items.size());
    for (const DrawItem& d : f.items) {
        PassItem pi;
        pi.d = d;
        pi.d.nested = nullptr;  // the pass never needs it; don't copy the reference around
        pi.d.prepend(shift);
        if (d.kind == LayerKind::Text && !d.needsOffscreen()) {
            appendGlyphs(f, pi.d, items);
            continue;
        }
        if (d.needsOffscreen()) {
            ++*offscreen;
            const Prepared p = renderOffscreen(cb, f, d, false, nullptr, arena, complete);
            if (!p.tex) continue;
            // Keep the result out of the free list: the composite pass below still reads it.
            arena.free.erase(std::remove(arena.free.begin(), arena.free.end(), p.tex), arena.free.end());
            DrawItem q;
            q.layerId = d.layerId;
            q.kind = LayerKind::Image;
            q.blend = d.blend;
            q.opacity = d.opacity;
            q.toTarget = Affine::translate(p.x - ox, p.y - oy);
            q.boundsMin = {0, 0};
            q.boundsMax = {double(p.tex.width), double(p.tex.height)};
            pi.d = q;
            pi.tex = p.tex;
            pi.masks = false;  // masks were applied offscreen
        }
        items.push_back(pi);
    }
    // 2. The layers themselves, bottom to top, in one pass.
    encodeItemsPass(cb, target, f, items, arena, complete, draws);
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
        size_t glyphs = 0;
        for (const DrawItem& d : f.items) glyphs += d.kind == LayerKind::Text ? d.text.text.size() * 2 : 0;
        const size_t bytes = (f.items.size() * 2 + f.mattes.size() + glyphs) * sizeof(ItemGPU) +
                             f.masks.size() * 2 * sizeof(MaskGPU) + passes * 512 + sizeof(MaskGPU);
        arena->buffer = acquireBuffer(bytes);
    }

    uint64_t draws = 0, offscreen = 0;
    encodeLayers(f, cb, target, 0, 0, *arena, complete, &draws, &offscreen);

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
    if (!prepareVideoFrames(f, 20, error)) return false;
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

bool MetalRenderer::renderToBGRA8(const std::vector<FrameDesc>& subframes, const Value& background, bool straightAlpha,
                                  uint8_t* dst, size_t dstRowBytes, std::string& error) {
    if (subframes.empty()) {
        error = "Nothing to render";
        return false;
    }
    for (const FrameDesc& f : subframes)
        if (!prepareVideoFrames(f, 20, error)) return false;
    const int w = subframes[0].width, h = subframes[0].height;
    id<MTLCommandBuffer> cb = [queue_ commandBuffer];
    bool complete = true;
    std::vector<id<MTLTexture>> used;
    id<MTLTexture> image = nil;
    if (subframes.size() == 1) {
        image = acquire(w, h, PoolKind::Target);
        used.push_back(image);
        encodeComposite(subframes[0], cb, image, &complete);
    } else {
        image = acquire(w, h, PoolKind::Scratch);
        used.push_back(image);
        for (size_t k = 0; k < subframes.size(); ++k) {
            id<MTLTexture> t = acquire(w, h, PoolKind::Target);
            used.push_back(t);
            bool c = true;
            encodeComposite(subframes[k], cb, t, &c);
            complete = complete && c;
            FxParams p;
            p.a[0] = 1.f / float(subframes.size());
            p.a[1] = k == 0 ? 1.f : 0.f;
            runKernel(cb, fxAccum_, {t, image}, &p, sizeof p);
        }
    }
    if (!exportTexture_ || int(exportTexture_.width) != w || int(exportTexture_.height) != h) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:NSUInteger(w)
                                                                                     height:NSUInteger(h)
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        exportTexture_ = [device_ newTextureWithDescriptor:td];
        exportBuffer_ = [device_ newBufferWithLength:size_t(w) * size_t(h) * 4 options:MTLResourceStorageModeShared];
    }
    FxParams q;
    for (int i = 0; i < 3; ++i) q.a[i] = float(background[size_t(i)]);
    q.b[0] = straightAlpha ? 1.f : 0.f;
    runKernel(cb, toBGRA8_, {image, exportTexture_}, &q, sizeof q);
    const size_t rowBytes = size_t(w) * 4;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:exportTexture_
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(NSUInteger(w), NSUInteger(h), 1)
                        toBuffer:exportBuffer_
               destinationOffset:0
          destinationBytesPerRow:rowBytes
        destinationBytesPerImage:rowBytes * size_t(h)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    for (id<MTLTexture> t : used) recycle(t);
    if (cb.status == MTLCommandBufferStatusError) {
        error = std::string("GPU error: ") + (cb.error ? cb.error.localizedDescription.UTF8String : "unknown");
        return false;
    }
    if (!complete) {
        error = "Frame references media that is not loaded";
        return false;
    }
    const auto* src = static_cast<const uint8_t*>(exportBuffer_.contents);
    for (int y = 0; y < h; ++y) std::memcpy(dst + size_t(y) * dstRowBytes, src + size_t(y) * rowBytes, rowBytes);
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
    if (level == PressureLevel::Critical)
        for (auto& [id, v] : videos_) v.decoder->purge();  // decoded again on demand
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
    for (const auto& [id, v] : videos_) s.assetBytes += v.decoder->bytes();
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
