// Shader A/B harness: renders identical frames through different shape pipelines, interleaved frame
// by frame so clock/thermal drift affects every variant equally, and compares GPU time.
//
//   benchmarks/ab/run.sh [--layers N] [--frames N]
//
// Variants
//   phase1   the Phase 1 fragment shader (benchmarks/ab/phase1_shaders.hpp)
//   current  today's shader, mask-free specialisation (what plain layers use)
//   masked   today's shader, mask-enabled specialisation with zero masks (what plain layers would
//            cost if the pipelines were not specialised)
//
// The pass is what MetalRenderer encodes for a frame of plain shape layers: one RGBA16F render
// pass, clear, one instanced draw of 112-byte instances, programmable blending.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "../../Sources/MFRender/Shaders.hpp"
#include "mf/Document.hpp"
#include "mf/Evaluator.hpp"
#include "phase1_shaders.hpp"

using namespace mf;

namespace {

struct ItemGPU {
    float m0[4], m1[4], bounds[4], fill[4], stroke[4], p0[4], p1[4];
};
static_assert(sizeof(ItemGPU) == 112);

void packItem(const DrawItem& d, ItemGPU& g) {
    const Affine& m = d.toTarget;
    g = {{float(m.a), float(m.b), float(m.c), float(m.d)},
         {float(m.tx), float(m.ty), float(d.opacity), float(int(d.kind))},
         {float(d.boundsMin.x), float(d.boundsMin.y), float(d.boundsMax.x), float(d.boundsMax.y)},
         {float(d.fill[0]), float(d.fill[1]), float(d.fill[2]), float(d.fill[3])},
         {float(d.stroke[0]), float(d.stroke[1]), float(d.stroke[2]), float(d.stroke[3])},
         {float(d.strokeWidth), float(d.roundness), float(d.points), float(d.innerRatio)},
         {float(int(d.shape)), float(int(d.blend)), 0, 0}};
}

// Same scene generator as mfbench (same seed, same parameters) for plain shape layers.
Project makeScene(int w, int h, int n) {
    Document d(makeDefaultProject(w, h, 30, 10));
    const ObjectId comp = d.project().activeComposition;
    std::mt19937 rng(1234);
    auto U = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    for (int i = 0; i < n; ++i) {
        const ObjectId l = d.addLayer(comp, LayerKind::Shape, static_cast<ShapeType>(i % 4));
        const double s = U(40, 300);
        d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {s, s * U(0.5, 1.5), 0, 0});
        d.setPropertyValue(comp, l, PropId::FillColor, 0, {U(0, 1), U(0, 1), U(0, 1), 1});
        d.setPropertyValue(comp, l, PropId::Roundness, 0, {U(0, 30), 0, 0, 0});
        if (rng() % 5 == 0) {
            d.setLayerFillStroke(comp, l, true, true);
            d.setPropertyValue(comp, l, PropId::StrokeWidth, 0, {U(2, 12), 0, 0, 0});
        }
        if (rng() % 5 == 0) d.setLayerBlend(comp, l, static_cast<BlendMode>(1 + rng() % 6));
        d.setPropertyValue(comp, l, PropId::Opacity, 0, {U(30, 100), 0, 0, 0});
        d.setPropertyAnimated(comp, l, PropId::Position, true, 0);
        d.setPropertyValue(comp, l, PropId::Position, 0, {U(0, w), U(0, h), 0, 0});
        d.setPropertyValue(comp, l, PropId::Position, 10, {U(0, w), U(0, h), 0, 0});
        d.setPropertyAnimated(comp, l, PropId::Rotation, true, 0);
        d.setPropertyValue(comp, l, PropId::Rotation, 10, {U(-720, 720), 0, 0, 0});
    }
    return d.project();
}

id<MTLRenderPipelineState> makePSO(id<MTLDevice> dev, const char* source, int masks /* -1 = no constant */) {
    MTLCompileOptions* opts = [MTLCompileOptions new];
    opts.preprocessorMacros = @{@"MF_FBFETCH" : @1};
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(source) options:opts error:&err];
    if (!lib) {
        std::fprintf(stderr, "compile failed: %s\n", err.localizedDescription.UTF8String);
        std::exit(2);
    }
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    if (masks < 0) {
        d.vertexFunction = [lib newFunctionWithName:@"item_vertex"];
        d.fragmentFunction = [lib newFunctionWithName:@"shape_fragment"];
    } else {
        MTLFunctionConstantValues* fc = [MTLFunctionConstantValues new];
        bool m = masks != 0;
        [fc setConstantValue:&m type:MTLDataTypeBool atIndex:0];
        d.vertexFunction = [lib newFunctionWithName:@"item_vertex" constantValues:fc error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"shape_fragment" constantValues:fc error:&err];
    }
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso) {
        std::fprintf(stderr, "pipeline failed: %s\n", err.localizedDescription.UTF8String);
        std::exit(2);
    }
    return pso;
}

double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}
double p95(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[std::min(v.size() - 1, size_t(v.size() * 0.95))];
}

}  // namespace

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        int layers = 5000, frames = 240;
        for (int i = 1; i + 1 < argc; ++i) {
            if (std::string(argv[i]) == "--layers") layers = std::atoi(argv[++i]);
            else if (std::string(argv[i]) == "--frames") frames = std::atoi(argv[++i]);
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        struct Variant {
            const char* name;
            id<MTLRenderPipelineState> pso;
            std::vector<double> gpu;
        };
        std::vector<Variant> variants = {
            {"phase1", makePSO(dev, phase1::kSource, -1), {}},
            {"current", makePSO(dev, shaders::kSource, 0), {}},
            {"masked", makePSO(dev, shaders::kSource, 1), {}},
        };

        const Project p = makeScene(1920, 1080, layers);
        const Composition& c = *p.activeComp();
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                      width:1920
                                                                                     height:1080
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> buf = [dev newBufferWithLength:size_t(layers) * sizeof(ItemGPU) + 4096 options:MTLResourceStorageModeShared];
        id<MTLBuffer> masks = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];

        auto renderWith = [&](Variant& v, size_t n, bool record) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            const float size[4] = {1920, 1080, 0, 0};
            [enc setRenderPipelineState:v.pso];
            [enc setVertexBytes:size length:sizeof size atIndex:0];
            [enc setVertexBuffer:buf offset:0 atIndex:1];
            [enc setFragmentBuffer:buf offset:0 atIndex:1];
            [enc setFragmentBuffer:masks offset:0 atIndex:2];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:n baseInstance:0];
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            if (record) v.gpu.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
        };

        for (int f = -10; f < frames; ++f) {  // first 10 frames warm up, not recorded
            const FrameDesc fd = evaluateFrame(p, c, double(std::max(f, 0) % int(c.frameCount())) / c.fps);
            auto* g = static_cast<ItemGPU*>(buf.contents);
            for (size_t i = 0; i < fd.items.size(); ++i) packItem(fd.items[i], g[i]);
            // Rotate the order every frame so no variant always runs first (or last).
            for (size_t k = 0; k < variants.size(); ++k)
                renderWith(variants[(size_t(f + 10) + k) % variants.size()], fd.items.size(), f >= 0);
        }

        std::printf("Shader A/B on %s: %d shape layers at 1080p, %d frames per variant, interleaved\n",
                    dev.name.UTF8String, layers, frames);
        const double base = median(variants[0].gpu);
        for (const Variant& v : variants)
            std::printf("  %-8s GPU median %7.3f ms   p95 %7.3f ms   vs phase1 %+6.1f%%\n", v.name, median(v.gpu), p95(v.gpu),
                        (median(v.gpu) / base - 1) * 100);
        return 0;
    }
}
