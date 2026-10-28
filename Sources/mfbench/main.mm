// MotionForge renderer benchmark.
//
//   swift run -c release mfbench [--frames N] [--out DIR] [--quick] [--snapshots DIR]
//
// Every scenario animates every layer, so each frame is unique and the frame cache is bypassed:
// the numbers are raw evaluate + encode + GPU cost, not cache hits. Measurements:
//   eval    CPU time to evaluate the timeline into a draw list (per frame)
//   encode  CPU time to pack instances and encode the composite pass
//   gpu     GPU execution time of one composite command buffer, measured with no overlap
//   fps     sustained throughput with up to 3 frames in flight (wall clock, N frames)
//   latency one frame end to end (evaluate -> encode -> commit -> wait), no overlap
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/sysctl.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <random>
#include <string>
#include <vector>

#include "MFRender/MetalRenderer.hpp"
#include "mf/Document.hpp"
#include "mf/Evaluator.hpp"

using namespace mf;
namespace fs = std::filesystem;

namespace {

double nowMs() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

struct Dist {
    double median = 0, p95 = 0, mean = 0;
};
Dist dist(std::vector<double> v) {
    Dist d;
    if (v.empty()) return d;
    std::sort(v.begin(), v.end());
    d.median = v[v.size() / 2];
    d.p95 = v[std::min(v.size() - 1, size_t(std::ceil(v.size() * 0.95)) - 1)];
    double s = 0;
    for (double x : v) s += x;
    d.mean = s / double(v.size());
    return d;
}

std::string sysctlString(const char* name) {
    char buf[256] = {};
    size_t len = sizeof buf;
    return sysctlbyname(name, buf, &len, nullptr, 0) == 0 ? std::string(buf) : std::string("?");
}
int sysctlInt(const char* name) {
    int v = 0;
    size_t len = sizeof v;
    return sysctlbyname(name, &v, &len, nullptr, 0) == 0 ? v : 0;
}

const char* thermal() {
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: return "nominal";
        case NSProcessInfoThermalStateFair: return "fair";
        case NSProcessInfoThermalStateSerious: return "serious";
        case NSProcessInfoThermalStateCritical: return "critical";
    }
    return "?";
}

// Smooth closed blob (pen-like: every point has handles) or an open wavy line, in layer space.
BezierPath benchPath(std::mt19937& rng, double radius, int points, bool closed) {
    auto U = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    BezierPath p;
    p.closed = closed;
    for (int k = 0; k < points; ++k) {
        if (closed) {
            const double a = 2 * M_PI * k / points, r = radius * U(0.6, 1.0);
            const Vec2 pt{std::cos(a) * r, std::sin(a) * r};
            const Vec2 t{-std::sin(a) * r * 0.3, std::cos(a) * r * 0.3};  // tangent handles keep it smooth
            p.vertices.push_back({pt, t * -1.0, t});
        } else {
            const double x = -radius + 2 * radius * k / (points - 1), y = U(-radius, radius) * 0.5;
            p.vertices.push_back({{x, y}, {-radius / points, 0}, {radius / points, 0}});
        }
    }
    return p;
}

// Per-layer decoration (effects, masks, mattes) applied after the layer is created.
using Decorate = std::function<void(Document&, ObjectId comp, ObjectId layer, int index)>;

// Composition with `n` animated layers. Mixed shape types, ~20% stroked, ~20% non-normal blend.
Project makeScene(int w, int h, int n, int imageLayers, ObjectId* imageAsset, const std::string& imagePath,
                  const Decorate& decorate = {}, LayerKind kind = LayerKind::Shape) {
    Document d(makeDefaultProject(w, h, 30, 10));
    const ObjectId comp = d.project().activeComposition;
    std::mt19937 rng(1234);
    auto U = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    ObjectId asset = 0;
    if (imageLayers > 0) asset = d.addImageAsset(imagePath, "bench.png", 1024, 1024);
    *imageAsset = asset;
    for (int i = 0; i < n + imageLayers; ++i) {
        const bool image = i < imageLayers;
        const ShapeType st = static_cast<ShapeType>(i % 4);
        const ObjectId l = image ? d.addLayer(comp, LayerKind::Image, ShapeType::Rectangle, asset)
                                 : d.addLayer(comp, kind, st);
        if (!image) {
            const double s = U(40, 300);
            d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {s, s * U(0.5, 1.5), 0, 0});
            d.setPropertyValue(comp, l, PropId::FillColor, 0, {U(0, 1), U(0, 1), U(0, 1), 1});
            d.setPropertyValue(comp, l, PropId::Roundness, 0, {U(0, 30), 0, 0, 0});
            if (rng() % 5 == 0) {
                d.setLayerFillStroke(comp, l, true, true);
                d.setPropertyValue(comp, l, PropId::StrokeWidth, 0, {U(2, 12), 0, 0, 0});
            }
        } else {
            d.setPropertyValue(comp, l, PropId::Scale, 0, {U(10, 40), U(10, 40), 0, 0});
        }
        if (rng() % 5 == 0) d.setLayerBlend(comp, l, static_cast<BlendMode>(1 + rng() % 6));
        d.setPropertyValue(comp, l, PropId::Opacity, 0, {U(30, 100), 0, 0, 0});
        // Animate position and rotation across the whole comp so every frame differs.
        d.setPropertyAnimated(comp, l, PropId::Position, true, 0);
        d.setPropertyValue(comp, l, PropId::Position, 0, {U(0, w), U(0, h), 0, 0});
        d.setPropertyValue(comp, l, PropId::Position, 10, {U(0, w), U(0, h), 0, 0});
        d.setPropertyAnimated(comp, l, PropId::Rotation, true, 0);
        d.setPropertyValue(comp, l, PropId::Rotation, 10, {U(-720, 720), 0, 0, 0});
        if (decorate) decorate(d, comp, l, i);
    }
    return d.project();
}

// Premultiplied RGBA8 -> PNG.
void writePNG(const std::string& path, std::vector<uint8_t>& px, int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, size_t(w) * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())], (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    CGImageDestinationAddImage(dst, img, nullptr);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

void writeNoisePNG(const std::string& path, int size) {
    std::vector<uint8_t> px(size_t(size) * size * 4);
    std::mt19937 rng(7);
    for (int y = 0; y < size; ++y)
        for (int x = 0; x < size; ++x) {
            uint8_t* p = &px[(size_t(y) * size + x) * 4];
            p[0] = uint8_t(x * 255 / size);
            p[1] = uint8_t(y * 255 / size);
            p[2] = uint8_t(rng() & 255);
            p[3] = 255;
        }
    writePNG(path, px, size, size);
}

struct Result {
    std::string name;
    int width, height, layers, frames;
    Dist eval, encode, gpu, latency;
    double fps;
    uint64_t drawCalls;
    uint64_t offscreen;
};

Result runScenario(MetalRenderer& r, const std::string& name, const Project& p, int frames) {
    const Composition& c = *p.activeComp();
    Result res{name, c.width, c.height, int(c.layers.size()), frames, {}, {}, {}, {}, 0, 0, 0};
    std::vector<double> evalMs, encodeMs, latencyMs;
    std::vector<double> gpuMs;
    auto timeAt = [&](int i) { return (i % int(c.frameCount())) / c.fps; };

    // Warm-up (pipeline state, buffer pool, texture pool).
    for (int i = 0; i < 10; ++i) {
        const FrameDesc f = evaluateFrame(p, c, timeAt(i));
        id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
        bool hit, complete;
        r.compositeFrame(f, cb, false, &hit, &complete);
        [cb commit];
        [cb waitUntilCompleted];
    }

    // Throughput: up to 3 frames in flight, like the viewer.
    dispatch_semaphore_t inflight = dispatch_semaphore_create(3);
    const double t0 = nowMs();
    id<MTLCommandBuffer> last = nil;
    for (int i = 0; i < frames; ++i) {
        dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
        const double e0 = nowMs();
        const FrameDesc f = evaluateFrame(p, c, timeAt(i));
        const double e1 = nowMs();
        id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
        bool hit, complete;
        r.compositeFrame(f, cb, false, &hit, &complete);
        const double e2 = nowMs();
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(inflight); }];
        [cb commit];
        evalMs.push_back(e1 - e0);
        encodeMs.push_back(e2 - e1);
        last = cb;
    }
    [last waitUntilCompleted];
    const double wall = nowMs() - t0;
    for (int i = 0; i < 3; ++i) dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);  // all handlers ran
    for (int i = 0; i < 3; ++i) dispatch_semaphore_signal(inflight);  // libdispatch traps if freed below its start value
    res.fps = frames / (wall / 1000.0);
    res.drawCalls = r.stats().drawCalls;
    res.offscreen = r.stats().offscreenLayers;

    // Latency and GPU time: one frame at a time, nothing overlapping. (GPU start/end stamps of
    // overlapping command buffers overlap too, so per-frame GPU cost is only meaningful serially.)
    for (int i = 0; i < 60; ++i) {
        const double l0 = nowMs();
        const FrameDesc f = evaluateFrame(p, c, timeAt(i * 7));
        id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
        bool hit, complete;
        r.compositeFrame(f, cb, false, &hit, &complete);
        [cb commit];
        [cb waitUntilCompleted];
        latencyMs.push_back(nowMs() - l0);
        gpuMs.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
    }
    res.eval = dist(evalMs);
    res.encode = dist(encodeMs);
    res.gpu = dist(gpuMs);
    res.latency = dist(latencyMs);
    return res;
}

}  // namespace

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        int frames = 240;
        bool quick = false;
        std::string outDir, snapshotDir;
        for (int i = 1; i < argc; ++i) {
            const std::string a = argv[i];
            if (a == "--frames" && i + 1 < argc) frames = std::max(10, std::atoi(argv[++i]));
            else if (a == "--out" && i + 1 < argc) outDir = argv[++i];
            else if (a == "--quick") quick = true;
            else if (a == "--snapshots" && i + 1 < argc) snapshotDir = argv[++i];  // one PNG per scenario, to check what is measured
        }
        if (quick) frames = std::min(frames, 60);

        std::string err;
        auto renderer = MetalRenderer::create(nil, err);
        if (!renderer) {
            std::fprintf(stderr, "Metal unavailable: %s\n", err.c_str());
            return 2;
        }
        MetalRenderer& r = *renderer;
        id<MTLDevice> dev = r.device();

        const fs::path tmp = fs::path(NSTemporaryDirectory().fileSystemRepresentation) / "mfbench";
        fs::create_directories(tmp);
        const std::string png = (tmp / "bench-1024.png").string();
        writeNoisePNG(png, 1024);

        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        char header[1024];
        std::snprintf(header, sizeof header,
                      "- Machine: %s, %s (%d performance + %d efficiency cores), %.0f GB unified memory\n"
                      "- GPU: %s, recommended working set %.1f GB, programmable blending: %s\n"
                      "- macOS %ld.%ld.%ld, runtime shader compile %.0f ms this launch (Metal caches compiled shaders after the first run)\n"
                      "- Frames per scenario: %d, every layer animated (cache bypassed), thermal state at start: %s\n",
                      sysctlString("hw.model").c_str(), sysctlString("machdep.cpu.brand_string").c_str(),
                      sysctlInt("hw.perflevel0.physicalcpu"), sysctlInt("hw.perflevel1.physicalcpu"),
                      double(NSProcessInfo.processInfo.physicalMemory) / (1ull << 30), dev.name.UTF8String,
                      double(dev.recommendedMaxWorkingSetSize) / (1ull << 30), r.programmableBlending() ? "yes" : "no",
                      long(os.majorVersion), long(os.minorVersion), long(os.patchVersion), r.shaderCompileMs(), frames,
                      thermal());
        std::printf("MotionForge renderer benchmark\n%s\n", header);

        struct Spec {
            const char* name;
            int w, h, shapes, images;
            Decorate decorate = {};
            LayerKind kind = LayerKind::Shape;
        };
        auto fx = [](EffectType t, std::vector<std::pair<int, Value>> params) {
            return [t, params](Document& d, ObjectId comp, ObjectId l, int) {
                const ObjectId e = d.addEffect(comp, l, t);
                for (const auto& [i, v] : params) d.setPropertyValue(comp, l, PropRef::effect(e, i), 0, v);
            };
        };
        // A full-frame layer (index 0) blurred; the rest plain.
        auto fullFrameBlur = [](double radius) {
            return [radius](Document& d, ObjectId comp, ObjectId l, int i) {
                if (i != 0) return;
                const Composition& c = *d.project().findComposition(comp);
                d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {double(c.width), double(c.height), 0, 0});
                d.setPropertyAnimated(comp, l, PropId::Position, false, 0);
                d.setPropertyAnimated(comp, l, PropId::Rotation, false, 0);
                d.setPropertyValue(comp, l, PropId::Position, 0, {c.width / 2.0, c.height / 2.0, 0, 0});
                d.setPropertyValue(comp, l, PropId::Rotation, 0, {0, 0, 0, 0});
                d.setPropertyValue(comp, l, PropId::Opacity, 0, {100, 0, 0, 0});
                const ObjectId e = d.addEffect(comp, l, EffectType::GaussianBlur);
                d.setPropertyAnimated(comp, l, PropRef::effect(e, 0), true, 0);  // animated radius: every frame differs
                d.setPropertyValue(comp, l, PropRef::effect(e, 0), 0, {radius * 0.5, 0, 0, 0});
                d.setPropertyValue(comp, l, PropRef::effect(e, 0), 10, {radius, 0, 0, 0});
            };
        };
        auto twoMasks = [](Document& d, ObjectId comp, ObjectId l, int) {
            d.addMask(comp, l, MaskShape::Ellipse);
            const ObjectId m = d.addMask(comp, l, MaskShape::Rectangle);
            d.setMaskMode(comp, l, m, MaskMode::Subtract, false);
            d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Feather), 0, {6, 0, 0, 0});
        };
        auto matteEveryOther = [](Document& d, ObjectId comp, ObjectId l, int i) {
            // Each odd layer is matted by the layer created just before it.
            if (i % 2 == 1) {
                const auto& layers = d.project().findComposition(comp)->layers;
                d.setLayerMatte(comp, l, layers[1].id, MatteMode::Alpha);  // layers[0] is `l` (new layers go on top)
            }
        };
        // Phase 4: text (30 characters per layer) and pen-style bezier paths.
        auto text30 = [](bool animator) {
            return [animator](Document& d, ObjectId comp, ObjectId l, int i) {
                TextData td;
                td.string = "Motion graphics on Apple M5 " + std::to_string(10 + i % 90);  // 30 characters
                td.font = "AvenirNext-Heavy";
                d.setLayerText(comp, l, td);
                d.setPropertyValue(comp, l, PropId::FontSize, 0, {64, 0, 0, 0});
                if (!animator) return;
                // A wave of characters rising and fading in: the selector offset sweeps across
                // the text over the whole comp, so every frame is different.
                const ObjectId a = d.addTextAnimator(comp, l, Document::AnimatorPreset::Opacity);
                d.setPropertyValue(comp, l, PropRef::animator(a, AnimParam::Position), 0, {0, 40, 0, 0});
                d.setPropertyValue(comp, l, PropRef::animator(a, AnimParam::End), 0, {30, 0, 0, 0});
                d.setTextAnimatorOptions(comp, l, a, true, SelectorShape::RampUp, SelectorUnit::Characters);
                d.setPropertyAnimated(comp, l, PropRef::animator(a, AnimParam::Offset), true, 0);
                d.setPropertyValue(comp, l, PropRef::animator(a, AnimParam::Offset), 0, {-30, 0, 0, 0});
                d.setPropertyValue(comp, l, PropRef::animator(a, AnimParam::Offset), 10, {100, 0, 0, 0});
            };
        };
        auto blobs = [](Document& d, ObjectId comp, ObjectId l, int i) {
            std::mt19937 rng(uint32_t(100 + i));
            d.setLayerPath(comp, l, benchPath(rng, 120, 8, true));
            d.setLayerFillStroke(comp, l, true, true);
            d.setPropertyValue(comp, l, PropId::StrokeWidth, 0, {4, 0, 0, 0});
        };
        auto trimmedLines = [](Document& d, ObjectId comp, ObjectId l, int i) {
            std::mt19937 rng(uint32_t(200 + i));
            d.setLayerPath(comp, l, benchPath(rng, 150, 6, false));
            d.setLayerFillStroke(comp, l, false, true);
            d.setPropertyValue(comp, l, PropId::StrokeWidth, 0, {8, 0, 0, 0});
            d.setPropertyAnimated(comp, l, PropId::TrimEnd, true, 0);
            d.setPropertyValue(comp, l, PropId::TrimEnd, 0, {0, 0, 0, 0});
            d.setPropertyValue(comp, l, PropId::TrimEnd, 10, {100, 0, 0, 0});
        };
        auto bezierMask = [](Document& d, ObjectId comp, ObjectId l, int i) {
            std::mt19937 rng(uint32_t(300 + i));
            d.addPathMask(comp, l, benchPath(rng, 90, 6, true));
        };
        std::vector<Spec> specs = {
            {"1080p, 10 shapes", 1920, 1080, 10, 0},
            {"1080p, 100 shapes", 1920, 1080, 100, 0},
            {"1080p, 1,000 shapes", 1920, 1080, 1000, 0},
            {"1080p, 5,000 shapes", 1920, 1080, 5000, 0},
            {"9:16 1080x1920, 500 shapes", 1080, 1920, 500, 0},
            {"4K UHD, 1,000 shapes", 3840, 2160, 1000, 0},
            {"1080p, 100 image layers (1024 px)", 1920, 1080, 0, 100},
            {"4K UHD, 50 images + 500 shapes", 3840, 2160, 500, 50},
            // Phase 3: effects, masks, mattes
            {"1080p, 100 shapes, each Gaussian Blur 20 px", 1920, 1080, 100, 0, fx(EffectType::GaussianBlur, {{0, {20, 0, 0, 0}}})},
            {"1080p, 20 shapes, Drop Shadow + Glow each", 1920, 1080, 20, 0,
             [fx](Document& d, ObjectId c, ObjectId l, int i) {
                 fx(EffectType::DropShadow, {})(d, c, l, i);
                 fx(EffectType::Glow, {{0, {30, 0, 0, 0}}})(d, c, l, i);
             }},
            {"1080p, 100 shapes, Hue/Sat + Brightness each", 1920, 1080, 100, 0,
             [fx](Document& d, ObjectId c, ObjectId l, int i) {
                 fx(EffectType::HueSaturation, {{0, {90, 0, 0, 0}}})(d, c, l, i);
                 fx(EffectType::BrightnessContrast, {{0, {20, 0, 0, 0}}})(d, c, l, i);
             }},
            {"1080p, full-frame layer, Gaussian Blur 25-50 px", 1920, 1080, 1, 0, fullFrameBlur(50)},
            {"4K UHD, full-frame layer, Gaussian Blur 50-100 px", 3840, 2160, 1, 0, fullFrameBlur(100)},
            {"1080p, 500 shapes with 2 masks each (1 feathered)", 1920, 1080, 500, 0, twoMasks},
            {"1080p, 100 shapes, 50 track mattes", 1920, 1080, 100, 0, matteEveryOther},
            // Phase 4: text and bezier paths
            {"1080p, 100 text layers x 30 chars (3,000 glyphs)", 1920, 1080, 100, 0, text30(false), LayerKind::Text},
            {"1080p, 20 text layers x 30 chars, range animator", 1920, 1080, 20, 0, text30(true), LayerKind::Text},
            {"1080p, 200 bezier paths (8 smooth pts, fill+stroke)", 1920, 1080, 200, 0, blobs},
            {"1080p, 200 open paths, Trim Paths animated, 8 px", 1920, 1080, 200, 0, trimmedLines},
            {"1080p, 200 shapes with a bezier mask each", 1920, 1080, 200, 0, bezierMask},
        };
        if (quick) specs.resize(4);

        std::vector<Result> results;
        for (const Spec& s : specs) {
            ObjectId asset = 0;
            const Project p = makeScene(s.w, s.h, s.shapes, s.images, &asset, png, s.decorate, s.kind);
            if (asset) {
                if (!r.loadImageSync(asset, 0, png, err)) {
                    std::fprintf(stderr, "image load failed: %s\n", err.c_str());
                    return 3;
                }
            }
            Result res = runScenario(r, s.name, p, frames);
            if (!snapshotDir.empty()) {
                const Composition& c = *p.activeComp();
                std::vector<float> rgba;
                std::string e;
                if (r.renderToRGBA(evaluateFrame(p, c, 5.0), rgba, nullptr, e)) {
                    std::vector<uint8_t> px(rgba.size());
                    for (size_t k = 0; k < rgba.size(); ++k) px[k] = uint8_t(std::clamp(rgba[k], 0.0f, 1.0f) * 255 + 0.5f);
                    std::filesystem::create_directories(snapshotDir);
                    writePNG(snapshotDir + "/" + std::to_string(&s - specs.data() + 1) + ".png", px, c.width, c.height);
                }
            }
            std::printf("  %-52s eval %7.3f ms  encode %6.3f ms  gpu %7.3f ms (p95 %7.3f)  %7.0f fps  latency %6.2f ms  offscreen %llu\n",
                        res.name.c_str(), res.eval.median, res.encode.median, res.gpu.median, res.gpu.p95, res.fps,
                        res.latency.median, (unsigned long long)res.offscreen);
            results.push_back(res);
            r.clearCache();
        }

        // Cache hit path + dependency-precise invalidation on a 1,000-layer comp.
        ObjectId none = 0;
        Document doc(makeScene(1920, 1080, 1000, 0, &none, png));
        const ObjectId comp = doc.project().activeComposition;
        const Composition& c0 = *doc.project().activeComp();
        r.setCacheBudget(256ull << 20);
        r.setCachePolicy(CachePolicy::All);
        const FrameDesc f0 = evaluateFrame(doc.project(), c0, 0);
        {
            id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
            bool hit, complete;
            r.compositeFrame(f0, cb, true, &hit, &complete);
            [cb commit];
            [cb waitUntilCompleted];
        }
        std::vector<double> hitUs;
        for (int i = 0; i < 200; ++i) {
            const double a = nowMs();
            const FrameDesc f = evaluateFrame(doc.project(), *doc.project().activeComp(), 0);
            id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
            bool hit = false, complete;
            r.compositeFrame(f, cb, true, &hit, &complete);
            hitUs.push_back((nowMs() - a) * 1000.0);
            [cb commit];
        }
        const Dist hitDist = dist(hitUs);
        // One layer of the 1,000 is trimmed to 0–2 s; changing its colour must invalidate exactly
        // the 60 frames it appears in and none of the other 240.
        const ObjectId target = doc.project().activeComp()->layers[0].id;
        doc.setLayerTiming(comp, target, 0, 2);
        std::vector<uint64_t> before;
        for (int i = 0; i < 300; ++i) before.push_back(evaluateFrame(doc.project(), *doc.project().activeComp(), i / 30.0).hash);
        doc.setPropertyValue(comp, target, PropId::FillColor, 0, {0.1, 0.9, 0.3, 1});
        int changed = 0;
        for (int i = 0; i < 300; ++i)
            changed += evaluateFrame(doc.project(), *doc.project().activeComp(), i / 30.0).hash != before[size_t(i)];
        std::printf("\n  cache hit (evaluate + lookup, 1,000 layers): median %.1f µs, p95 %.1f µs\n", hitDist.median, hitDist.p95);
        std::printf("  invalidation: recolouring 1 layer (visible 0–2 s) of 1,000 changed %d of 300 frames (expected 60)\n", changed);
        std::printf("  thermal state at end: %s\n", thermal());

        if (!outDir.empty()) {
            fs::create_directories(outDir);
            NSDateFormatter* df = [NSDateFormatter new];
            df.dateFormat = @"yyyy-MM-dd";
            const std::string date = [df stringFromDate:[NSDate date]].UTF8String;
            const std::string md = (fs::path(outDir) / ("results-" + date + ".md")).string();
            FILE* f = std::fopen(md.c_str(), "w");
            if (f) {
                std::fprintf(f, "# MotionForge renderer benchmark — %s\n\n%s\n", date.c_str(), header);
                std::fprintf(f, "Command: `.build/release/mfbench --frames %d`\n\n", frames);
                std::fprintf(f, "| Scenario | Layers | Offscreen layers | Eval (CPU) ms | Encode (CPU) ms | GPU ms median | GPU ms p95 | Throughput fps (3 in flight) | 1-frame latency ms | Draw calls |\n");
                std::fprintf(f, "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
                for (const Result& x : results)
                    std::fprintf(f, "| %s | %d | %llu | %.3f | %.3f | %.3f | %.3f | %.0f | %.2f | %llu |\n", x.name.c_str(),
                                 x.layers, (unsigned long long)x.offscreen, x.eval.median, x.encode.median, x.gpu.median,
                                 x.gpu.p95, x.fps, x.latency.median, (unsigned long long)x.drawCalls);
                std::fprintf(f, "\n- Cache hit (evaluate + lookup, 1,000 layers): median %.1f µs, p95 %.1f µs\n", hitDist.median, hitDist.p95);
                std::fprintf(f, "- Dependency-based invalidation: recolouring 1 layer (visible 0–2 s) out of 1,000 changed %d of 300 frame hashes (expected 60): only frames whose evaluated result changed are re-rendered\n", changed);
                std::fprintf(f, "- Frame-cache footprint (8-bit premultiplied copies): %.1f MB per 1080p frame, %.1f MB per 4K frame — %d s of 1080p30 per GB\n",
                             cachedFrameBytes(1920, 1080) / 1048576.0, cachedFrameBytes(3840, 2160) / 1048576.0,
                             int((1ull << 30) / cachedFrameBytes(1920, 1080) / 30));
                std::fprintf(f, "- Thermal state at end: %s\n", thermal());
                std::fprintf(f, "\nThroughput = frames / wall-clock time with up to 3 frames in flight; it is bounded by whichever of CPU evaluate+encode or GPU execution is slower. These are renderer-only numbers (no viewer presentation, no media decode).\n");
                std::fclose(f);
                std::printf("\nwrote %s\n", md.c_str());
            }
        }
        fs::remove_all(tmp);
        return 0;
    }
}
