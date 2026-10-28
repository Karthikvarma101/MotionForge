// mfcli — headless MotionForge tool (same engine and renderer as the app).
//
//   mfcli info   <project.mfproj>
//   mfcli render <project.mfproj> <out.png> [--time S] [--scale F] [--transparent]
//   mfcli frames <project.mfproj> <out-dir> [--from S] [--to S] [--scale F]      PNG sequence
//   mfcli demo   <out-dir>     builds a project, edits position / scale / opacity, renders each
//                              state, measures the pixels and writes a side-by-side sheet
//   mfcli effects-demo <out-dir>   one tile per effect, mask and track matte, as a contact sheet
//   mfcli phase4-demo <out-dir>    text, text animators, bezier shapes, trim paths, bezier masks, presets
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#include <algorithm>
#include <chrono>

#include "MFEngine.h"
#include "MFRender/MetalRenderer.hpp"
#include "mf/Evaluator.hpp"
#include "mf/ProjectIO.hpp"

namespace {

int usage() {
    std::fprintf(stderr,
                 "usage:\n"
                 "  mfcli info   <project.mfproj>\n"
                 "  mfcli render <project.mfproj> <out.png> [--time S] [--scale F] [--transparent] [--no-motion-blur]\n"
                 "  mfcli frames <project.mfproj> <out-dir> [--from S] [--to S] [--scale F] [--no-motion-blur]\n"
                 "  mfcli time   <project.mfproj> [--from S] [--to S] [--step S] [--scale F]   (CPU evaluate + GPU render per frame)\n"
                 "  mfcli demo   <out-dir>\n"
                 "  mfcli effects-demo <out-dir>\n"
                 "  mfcli phase4-demo <out-dir>\n");
    return 64;
}

double argDouble(int argc, const char* argv[], const char* name, double fallback) {
    for (int i = 0; i + 1 < argc; ++i)
        if (std::strcmp(argv[i], name) == 0) return std::atof(argv[i + 1]);
    return fallback;
}
bool argFlag(int argc, const char* argv[], const char* name) {
    for (int i = 0; i < argc; ++i)
        if (std::strcmp(argv[i], name) == 0) return true;
    return false;
}

MFEngine* makeEngine() {
    NSError* error = nil;
    MFEngine* e = [[MFEngine alloc] initWithDevice:nil error:&error];
    if (!e) std::fprintf(stderr, "Metal unavailable: %s\n", error.localizedDescription.UTF8String);
    return e;
}

MFEngine* openProject(const char* path) {
    MFEngine* e = makeEngine();
    if (!e) return nil;
    NSError* error = nil;
    if (![e openProjectAtPath:@(path) error:&error]) {
        std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    if (![e waitForMediaWithTimeout:60]) std::fprintf(stderr, "warning: media still loading after 60 s\n");
    for (MFAssetInfo* a in e.assets)
        if (a.missing) std::fprintf(stderr, "warning: missing media %s\n", a.path.UTF8String);
    return e;
}

// Alpha-weighted centroid, coverage area and peak alpha of a rendered RGBA image.
struct Measure {
    double area = 0, cx = 0, cy = 0, peak = 0;
};
Measure measure(CGImageRef img) {
    const size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    std::vector<uint8_t> px(w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    Measure m;
    for (size_t y = 0; y < h; ++y)
        for (size_t x = 0; x < w; ++x) {
            const double a = px[(y * w + x) * 4 + 3] / 255.0;
            m.area += a;
            m.cx += a * (x + 0.5);
            m.cy += a * (y + 0.5);
            m.peak = std::max(m.peak, a);
        }
    if (m.area > 0) {
        m.cx /= m.area;
        m.cy /= m.area;
    }
    return m;
}

bool writePNG(CGImageRef img, const std::string& path) {
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())], (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    if (!dst) return false;
    CGImageDestinationAddImage(dst, img, nullptr);
    const bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok;
}

void drawText(CGContextRef ctx, const std::string& s, double x, double y, double size, CGColorRef color) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, nullptr);
    NSDictionary* attrs = @{(id)kCTFontAttributeName : (__bridge id)font, (id)kCTForegroundColorAttributeName : (__bridge id)color};
    NSAttributedString* as = [[NSAttributedString alloc] initWithString:@(s.c_str()) attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGContextSetTextPosition(ctx, x, y);
    CTLineDraw(line, ctx);
    CFRelease(line);
    CFRelease(font);
}

int cmdInfo(const char* path) {
    MFEngine* e = openProject(path);
    if (!e) return 1;
    MFCompositionInfo* c = e.composition;
    std::printf("%s: %ldx%ld, %.3f fps, %.2f s, %lu layers, %lu media\n", c.name.UTF8String, long(c.width),
                long(c.height), c.fps, c.duration, (unsigned long)e.layers.count, (unsigned long)e.assets.count);
    for (MFLayerInfo* l in e.layers) {
        const char* kinds[] = {"shape", "image", "null"};
        MFValue p = [e valueOf:MFPropPosition layer:l.layerID time:0];
        std::printf("  %-20s %-6s in %.2f out %.2f  pos(0) %.1f, %.1f%s\n", l.name.UTF8String, kinds[l.kind], l.inPoint,
                    l.outPoint, p.x, p.y, l.allKeyframeTimes.count ? "  [animated]" : "");
    }
    return 0;
}

int cmdRender(int argc, const char* argv[]) {
    MFEngine* e = openProject(argv[2]);
    if (!e) return 1;
    NSError* error = nil;
    e.renderMotionBlur = !argFlag(argc, argv, "--no-motion-blur");
    const double t = argDouble(argc, argv, "--time", 0), scale = argDouble(argc, argv, "--scale", 1);
    if (![e writePNGAtTime:t scale:scale transparent:argFlag(argc, argv, "--transparent") toPath:@(argv[3]) error:&error]) {
        std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    std::printf("wrote %s\n", argv[3]);
    return 0;
}

// Per-frame cost of a real project, measured (not estimated): CPU evaluation of the timeline,
// GPU time of the composite, with and without the composition's motion blur.
int cmdTime(int argc, const char* argv[]) {
    using clock = std::chrono::steady_clock;
    mf::Project p;
    std::string err;
    const auto tl0 = clock::now();
    if (!mf::loadProjectFile(argv[2], p, err)) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 1;
    }
    const double loadMs = std::chrono::duration<double, std::milli>(clock::now() - tl0).count();
    const mf::Composition* c = p.activeComp();
    if (!c) return 1;
    auto r = mf::MetalRenderer::create(nil, err);
    if (!r) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 1;
    }
    for (const mf::Asset& a : p.assets)
        if (!a.missing && !r->loadImageSync(a.id, a.generation, a.path, err)) std::fprintf(stderr, "media: %s\n", err.c_str());
    size_t layers = 0;
    for (const mf::Composition& k : p.compositions) layers += k.layers.size();
    const double from = argDouble(argc, argv, "--from", 0), to = argDouble(argc, argv, "--to", c->duration);
    const double step = argDouble(argc, argv, "--step", 1.0), scale = argDouble(argc, argv, "--scale", 1);
    std::vector<double> eval, gpu, items, blurGpu;
    const std::vector<double> offs = mf::motionBlurOffsets(p, *c);
    std::vector<float> px;
    for (double t = from; t < to; t += step) {
        const auto t0 = clock::now();
        const mf::FrameDesc f = mf::evaluateFrame(p, *c, t, scale);
        eval.push_back(std::chrono::duration<double, std::milli>(clock::now() - t0).count());
        size_t n = 0;
        std::function<void(const mf::FrameDesc&)> count = [&](const mf::FrameDesc& d) {
            for (const mf::DrawItem& it : d.items) {
                ++n;
                if (it.nested) count(*it.nested);
            }
        };
        count(f);
        items.push_back(double(n));
        double g = 0;
        if (!r->renderToRGBA(f, px, &g, err)) std::fprintf(stderr, "t=%.2f: %s\n", t, err.c_str());
        gpu.push_back(g);
        if (offs.size() > 1) {  // same rule as the exporter: identical subframes render once
            std::vector<mf::FrameDesc> fs;
            for (double o : offs) fs.push_back(mf::evaluateFrame(p, *c, t, scale, nullptr, o));
            const bool still = std::all_of(fs.begin(), fs.end(), [&](const mf::FrameDesc& x) { return x.hash == fs[0].hash; });
            double sum = 0;
            for (size_t k = 0; k < (still ? 1 : fs.size()); ++k) {
                double gb = 0;
                r->renderToRGBA(fs[k], px, &gb, err);
                sum += gb;
            }
            blurGpu.push_back(sum);
        }
    }
    auto stat = [](std::vector<double> v, double q) {
        if (v.empty()) return 0.0;
        std::sort(v.begin(), v.end());
        return v[std::min(v.size() - 1, size_t(q * double(v.size())))];
    };
    std::printf("%s: %zu compositions, %zu layers, loaded in %.0f ms; %zu frames sampled (%g s apart) at %.0f%%\n",
                c->name.c_str(), p.compositions.size(), layers, loadMs, eval.size(), step, scale * 100);
    std::printf("  draw items per frame   median %.0f   max %.0f\n", stat(items, 0.5), stat(items, 1.0));
    std::printf("  CPU evaluate           median %.2f ms   p95 %.2f ms   max %.2f ms\n", stat(eval, 0.5), stat(eval, 0.95), stat(eval, 1.0));
    std::printf("  GPU composite          median %.2f ms   p95 %.2f ms   max %.2f ms\n", stat(gpu, 0.5), stat(gpu, 0.95), stat(gpu, 1.0));
    if (!blurGpu.empty())
        std::printf("  GPU with motion blur   median %.2f ms   p95 %.2f ms   (%zu subframes)\n", stat(blurGpu, 0.5), stat(blurGpu, 0.95), offs.size());
    return 0;
}

int cmdFrames(int argc, const char* argv[]) {
    MFEngine* e = openProject(argv[2]);
    if (!e) return 1;
    MFCompositionInfo* c = e.composition;
    e.renderMotionBlur = !argFlag(argc, argv, "--no-motion-blur");
    const double from = argDouble(argc, argv, "--from", 0), to = argDouble(argc, argv, "--to", c.duration);
    const double scale = argDouble(argc, argv, "--scale", 1);
    [[NSFileManager defaultManager] createDirectoryAtPath:@(argv[3]) withIntermediateDirectories:YES attributes:nil error:nil];
    const long first = std::lround(from * c.fps), last = std::lround(to * c.fps);
    const double t0 = CFAbsoluteTimeGetCurrent();
    for (long f = first; f < last; ++f) {
        @autoreleasepool {
            NSString* path = [NSString stringWithFormat:@"%s/frame_%05ld.png", argv[3], f];
            NSError* error = nil;
            if (![e writePNGAtTime:double(f) / c.fps scale:scale transparent:NO toPath:path error:&error]) {
                std::fprintf(stderr, "frame %ld: %s\n", f, error.localizedDescription.UTF8String);
                return 1;
            }
        }
    }
    std::printf("wrote %ld frames to %s in %.2f s (PNG encode included)\n", last - first, argv[3], CFAbsoluteTimeGetCurrent() - t0);
    return 0;
}

int cmdDemo(const char* dir) {
    MFEngine* e = makeEngine();
    if (!e) return 1;
    NSString* out = @(dir);
    [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];

    [e newProjectWithWidth:1920 height:1080 fps:30 duration:5];
    [e setCompositionWidth:1920 height:1080 fps:30 duration:5 background:MFValue{0.07, 0.075, 0.09, 1} name:@"Demo"];
    const uint64_t box = [e addShapeLayer:MFShapeTypeRectangle];
    [e setLayer:box name:@"Box"];
    [e setPropertyValue:MFValue{400, 240, 0, 0} prop:MFPropSize layer:box time:0];
    [e setPropertyValue:MFValue{40, 0, 0, 0} prop:MFPropRoundness layer:box time:0];
    [e setPropertyValue:MFValue{0.33, 0.62, 1.0, 1} prop:MFPropFillColor layer:box time:0];

    struct Step {
        const char* file;
        const char* label;
        MFProp prop;
        MFValue value;
        const char* expect;
    };
    const Step steps[] = {
        {"1-base.png", "Base: position 960,540 · scale 100% · opacity 100%", MFPropPosition, {960, 540, 0, 0},
         "centroid (960, 540), area 400x240 minus corners"},
        {"2-position.png", "Position → 1400, 300", MFPropPosition, {1400, 300, 0, 0}, "centroid moves to (1400, 300), area unchanged"},
        {"3-scale.png", "Scale → 150%", MFPropScale, {150, 150, 0, 0}, "area × 2.25, centroid unchanged"},
        {"4-opacity.png", "Opacity → 40%", MFPropOpacity, {40, 0, 0, 0}, "peak alpha 0.40, area × 0.40"},
    };

    std::vector<CGImageRef> images;
    std::vector<Measure> ms;
    std::printf("%-16s %-14s %-22s %-10s %s\n", "state", "area px", "centroid", "peak α", "expected");
    for (const Step& s : steps) {
        [e setPropertyValue:s.value prop:s.prop layer:box time:0];
        NSError* error = nil;
        CGImageRef alpha = [e copyImageAtTime:0 scale:1 transparent:YES error:&error];  // for measuring
        CGImageRef shown = [e copyImageAtTime:0 scale:0.5 transparent:NO error:&error];
        if (!alpha || !shown) {
            std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        const Measure m = measure(alpha);
        CGImageRelease(alpha);
        writePNG(shown, std::string(dir) + "/" + s.file);
        images.push_back(shown);
        ms.push_back(m);
        std::printf("%-16s %-14.0f (%7.2f, %7.2f)     %-10.3f %s\n", s.file, m.area, m.cx, m.cy, m.peak, s.expect);
    }
    const bool ok = std::abs(ms[1].cx - 1400) < 0.5 && std::abs(ms[1].cy - 300) < 0.5 && std::abs(ms[1].area / ms[0].area - 1) < 0.01 &&
                    std::abs(ms[2].area / ms[1].area - 2.25) < 0.02 && std::abs(ms[3].peak - 0.40) < 0.01 &&
                    std::abs(ms[3].area / ms[2].area - 0.40) < 0.01;
    std::printf("checks: %s\n", ok ? "PASS — every edit changed the rendered pixels exactly as expected" : "FAIL");

    // 2x2 contact sheet with captions.
    const size_t cw = CGImageGetWidth(images[0]), ch = CGImageGetHeight(images[0]), pad = 24, cap = 44;
    const size_t W = cw * 2 + pad * 3, H = (ch + cap) * 2 + pad * 3;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, W, H, 8, W * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
    CGContextSetRGBFillColor(ctx, 0.11, 0.11, 0.12, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));
    CGColorRef white = CGColorCreateSRGB(0.92, 0.92, 0.94, 1), grey = CGColorCreateSRGB(0.6, 0.62, 0.66, 1);
    for (size_t i = 0; i < 4; ++i) {
        const size_t col = i % 2, row = i / 2;
        const double x = double(pad + col * (cw + pad));
        const double yTop = double(pad + row * (ch + cap + pad));          // from the top
        const double y = double(H) - yTop - double(cap) - double(ch);      // CG origin is bottom-left
        CGContextDrawImage(ctx, CGRectMake(x, y, cw, ch), images[i]);
        drawText(ctx, steps[i].label, x, y + ch + 22, 17, white);
        char m[160];
        std::snprintf(m, sizeof m, "measured: area %.0f px · centroid (%.1f, %.1f) · peak alpha %.2f", ms[i].area, ms[i].cx,
                      ms[i].cy, ms[i].peak);
        drawText(ctx, m, x, y + ch + 4, 13, grey);
    }
    CGImageRef sheet = CGBitmapContextCreateImage(ctx);
    writePNG(sheet, std::string(dir) + "/demo-sheet.png");
    CGImageRelease(sheet);
    CGContextRelease(ctx);
    CGColorRelease(white);
    CGColorRelease(grey);
    CGColorSpaceRelease(cs);
    for (CGImageRef i : images) CGImageRelease(i);

    NSError* error = nil;
    [e saveProjectToPath:[out stringByAppendingPathComponent:@"demo.mfproj"] error:&error];
    std::printf("wrote %s/demo-sheet.png, four state PNGs and demo.mfproj\n", dir);
    return ok ? 0 : 1;
}

// Grid of captioned images.
CGImageRef contactSheet(const std::vector<CGImageRef>& images, const std::vector<std::string>& captions, size_t columns) {
    const size_t cw = CGImageGetWidth(images[0]), ch = CGImageGetHeight(images[0]), pad = 20, cap = 30;
    const size_t rows = (images.size() + columns - 1) / columns;
    const size_t W = cw * columns + pad * (columns + 1), H = (ch + cap) * rows + pad * (rows + 1);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, W, H, 8, W * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
    CGContextSetRGBFillColor(ctx, 0.11, 0.11, 0.12, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));
    CGColorRef white = CGColorCreateSRGB(0.92, 0.92, 0.94, 1);
    for (size_t i = 0; i < images.size(); ++i) {
        const size_t col = i % columns, row = i / columns;
        const double x = double(pad + col * (cw + pad));
        const double y = double(H) - double(pad + row * (ch + cap + pad)) - double(cap) - double(ch);
        CGContextDrawImage(ctx, CGRectMake(x, y, cw, ch), images[i]);
        drawText(ctx, captions[i], x, y + ch + 9, 16, white);
    }
    CGImageRef sheet = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorRelease(white);
    CGColorSpaceRelease(cs);
    return sheet;
}

int cmdEffectsDemo(const char* dir) {
    MFEngine* e = makeEngine();
    if (!e) return 1;
    [[NSFileManager defaultManager] createDirectoryAtPath:@(dir) withIntermediateDirectories:YES attributes:nil error:nil];
    struct Tile {
        const char* caption;
        std::function<void(MFEngine*, uint64_t star, uint64_t card)> apply;
    };
    auto fxParam = [](MFEngine* en, uint64_t layer, MFEffectType t, std::vector<std::pair<int, MFValue>> ps) {
        const uint64_t fx = [en addEffect:t layer:layer];
        for (const auto& [i, v] : ps) [en setRefValue:v ref:MFPropRef{MFPropOwnerEffect, fx, i} layer:layer time:0];
    };
    const std::vector<Tile> tiles = {
        {"Original", [](MFEngine*, uint64_t, uint64_t) {}},
        {"Gaussian Blur 24 px (star)", [&](MFEngine* en, uint64_t s, uint64_t) { fxParam(en, s, MFEffectTypeGaussianBlur, {{0, {24, 0, 0, 0}}}); }},
        {"Drop Shadow (card)", [&](MFEngine* en, uint64_t, uint64_t c) {
             fxParam(en, c, MFEffectTypeDropShadow, {{1, {80, 0, 0, 0}}, {3, {30, 0, 0, 0}}, {4, {40, 0, 0, 0}}});
         }},
        {"Glow (star)", [&](MFEngine* en, uint64_t s, uint64_t) {
             fxParam(en, s, MFEffectTypeGlow, {{0, {30, 0, 0, 0}}, {1, {90, 0, 0, 0}}, {2, {150, 0, 0, 0}}});
         }},
        {"Brightness -40, Contrast +60 (card)", [&](MFEngine* en, uint64_t, uint64_t c) {
             fxParam(en, c, MFEffectTypeBrightnessContrast, {{0, {-40, 0, 0, 0}}, {1, {60, 0, 0, 0}}});
         }},
        {"Hue/Saturation: hue +150° (both)", [&](MFEngine* en, uint64_t s, uint64_t c) {
             fxParam(en, s, MFEffectTypeHueSaturation, {{0, {150, 0, 0, 0}}});
             fxParam(en, c, MFEffectTypeHueSaturation, {{0, {150, 0, 0, 0}}});
         }},
        {"Fill white (star)", [&](MFEngine* en, uint64_t s, uint64_t) { fxParam(en, s, MFEffectTypeFill, {{0, {1, 1, 1, 1}}}); }},
        {"Feathered ellipse mask (card)", [&](MFEngine* en, uint64_t, uint64_t c) {
             const uint64_t m = [en addMask:MFMaskShapeEllipse layer:c];
             [en setRefValue:MFValue{560, 300, 0, 0} ref:MFPropRef{MFPropOwnerMask, m, 1} layer:c time:0];
             [en setRefValue:MFValue{60, 0, 0, 0} ref:MFPropRef{MFPropOwnerMask, m, 3} layer:c time:0];
         }},
        {"Track matte: card shown through star", [&](MFEngine* en, uint64_t s, uint64_t c) {
             [en setLayer:c matte:s mode:MFMatteModeAlpha];
         }},
    };
    std::vector<CGImageRef> images;
    std::vector<std::string> captions;
    for (const Tile& t : tiles) {
        [e newProjectWithWidth:960 height:540 fps:30 duration:1];
        [e setCompositionWidth:960 height:540 fps:30 duration:1 background:MFValue{0.07, 0.075, 0.09, 1} name:@"Effects"];
        const uint64_t card = [e addShapeLayer:MFShapeTypeRectangle];
        [e setPropertyValue:MFValue{700, 380, 0, 0} prop:MFPropSize layer:card time:0];
        [e setPropertyValue:MFValue{60, 0, 0, 0} prop:MFPropRoundness layer:card time:0];
        [e setPropertyValue:MFValue{0.93, 0.27, 0.42, 1} prop:MFPropFillColor layer:card time:0];
        [e setPropertyValue:MFValue{480, 290, 0, 0} prop:MFPropPosition layer:card time:0];
        const uint64_t star = [e addShapeLayer:MFShapeTypeStar];
        [e setPropertyValue:MFValue{300, 300, 0, 0} prop:MFPropSize layer:star time:0];
        [e setPropertyValue:MFValue{0.98, 0.78, 0.2, 1} prop:MFPropFillColor layer:star time:0];
        [e setPropertyValue:MFValue{480, 260, 0, 0} prop:MFPropPosition layer:star time:0];
        t.apply(e, star, card);
        NSError* error = nil;
        CGImageRef img = [e copyImageAtTime:0 scale:0.5 transparent:NO error:&error];
        if (!img) {
            std::fprintf(stderr, "%s: %s\n", t.caption, error.localizedDescription.UTF8String);
            return 1;
        }
        images.push_back(img);
        captions.push_back(t.caption);
    }
    CGImageRef sheet = contactSheet(images, captions, 3);
    const std::string out = std::string(dir) + "/effects-sheet.png";
    writePNG(sheet, out);
    CGImageRelease(sheet);
    for (CGImageRef i : images) CGImageRelease(i);
    std::printf("wrote %s (%zu tiles)\n", out.c_str(), tiles.size());
    return 0;
}

MFPathVertex* V(double x, double y, double ix = 0, double iy = 0, double ox = 0, double oy = 0) {
    return [[MFPathVertex alloc] initWithPoint:CGPointMake(x, y) inTangent:CGPointMake(ix, iy) outTangent:CGPointMake(ox, oy)];
}

int cmdPhase4Demo(const char* dir) {
    MFEngine* e = makeEngine();
    if (!e) return 1;
    [[NSFileManager defaultManager] createDirectoryAtPath:@(dir) withIntermediateDirectories:YES attributes:nil error:nil];
    auto preset = [](NSString* name) -> NSString* {
        for (MFPresetInfo* p in [MFEngine builtInPresets])
            if ([p.name isEqualToString:name]) return p.json;
        return @"";
    };
    struct Tile {
        const char* caption;
        double time;
        std::function<void(MFEngine*)> build;
    };
    auto text = [](MFEngine* en, NSString* s, double size) {
        const uint64_t t = [en addTextLayer:s];
        [en setLayer:t text:s font:@"AvenirNext-Heavy" align:MFTextAlignCenter];
        [en setPropertyValue:MFValue{size, 0, 0, 0} prop:MFPropFontSize layer:t time:0];
        [en setPropertyValue:MFValue{480, 300, 0, 0} prop:MFPropPosition layer:t time:0];
        return t;
    };
    const std::vector<Tile> tiles = {
        {"Text layer (Avenir Next Heavy, 110 px)", 0, [&](MFEngine* en) { text(en, @"MotionForge", 110); }},
        {"Typewriter preset, 0.75 s into 1.5 s", 0.75, [&](MFEngine* en) {
             const uint64_t t = text(en, @"Typewriter", 120);
             [en applyPreset:preset(@"Typewriter") layers:@[ @(t) ] time:0 message:nil];
         }},
        {"Fade Up by Character, mid-way", 0.55, [&](MFEngine* en) {
             const uint64_t t = text(en, @"Fade Up!", 140);
             [en applyPreset:preset(@"Fade Up by Character") layers:@[ @(t) ] time:0 message:nil];
         }},
        {"Rotation animator, Smooth selector by word", 0, [&](MFEngine* en) {
             const uint64_t t = text(en, @"one two three", 96);
             const uint64_t a = [en addTextAnimator:MFAnimatorPresetRotation layer:t];
             [en setTextAnimator:a layer:t enabled:YES shape:MFSelectorShapeSmooth unit:MFSelectorUnitWords];
             [en setRefValue:MFValue{25, 0, 0, 0} ref:MFPropRef{MFPropOwnerTextAnimator, a, 6} layer:t time:0];
         }},
        {"Pen-drawn bezier shape (heart)", 0, [&](MFEngine* en) {
             const uint64_t s = [en addPathLayerWithVertices:@[ V(480, 210, -60, -60, 60, -60), V(660, 260, 0, -80, 0, 90),
                                                               V(480, 430, 70, -40, -70, -40), V(300, 260, 0, 90, 0, -80) ]
                                                      closed:YES];
             [en setPropertyValue:MFValue{0.93, 0.27, 0.42, 1} prop:MFPropFillColor layer:s time:0];
         }},
        {"Open path + Trim Paths (line drawing itself, 60%)", 0, [&](MFEngine* en) {
             const uint64_t s = [en addPathLayerWithVertices:@[ V(160, 380, 0, 0, 120, -260), V(480, 300, -120, 0, 120, 0),
                                                               V(800, 220, -120, 260, 0, 0) ]
                                                      closed:NO];
             [en setPropertyValue:MFValue{24, 0, 0, 0} prop:MFPropStrokeWidth layer:s time:0];
             [en setPropertyValue:MFValue{0.98, 0.78, 0.2, 1} prop:MFPropStrokeColor layer:s time:0];
             [en setPropertyValue:MFValue{60, 0, 0, 0} prop:MFPropTrimEnd layer:s time:0];
         }},
        {"Bezier mask (pen) cutting a rectangle", 0, [&](MFEngine* en) {
             const uint64_t r = [en addShapeLayer:MFShapeTypeRectangle];
             [en setPropertyValue:MFValue{700, 360, 0, 0} prop:MFPropSize layer:r time:0];
             [en setPropertyValue:MFValue{0.33, 0.62, 1, 1} prop:MFPropFillColor layer:r time:0];
             [en addPathMaskWithVertices:@[ V(-300, 150, 0, 0, 100, -250), V(0, -170, -150, 0, 150, 0), V(300, 150, -100, -250, 0, 0) ]
                                   layer:r];
         }},
        {"Pop In preset at 0.25 s (overshoot)", 0.25, [&](MFEngine* en) {
             const uint64_t s = [en addShapeLayer:MFShapeTypeStar];
             [en setPropertyValue:MFValue{300, 300, 0, 0} prop:MFPropSize layer:s time:0];
             [en setPropertyValue:MFValue{0.98, 0.78, 0.2, 1} prop:MFPropFillColor layer:s time:0];
             [en applyPreset:preset(@"Pop In") layers:@[ @(s) ] time:0 message:nil];
         }},
        {"Masked text + glow", 0, [&](MFEngine* en) {
             const uint64_t t = text(en, @"GLOW", 200);
             const uint64_t m = [en addMask:MFMaskShapeEllipse layer:t];
             [en setRefValue:MFValue{0, -70, 0, 0} ref:MFPropRef{MFPropOwnerMask, m, 0} layer:t time:0];
             [en setRefValue:MFValue{560, 160, 0, 0} ref:MFPropRef{MFPropOwnerMask, m, 1} layer:t time:0];
             [en addEffect:MFEffectTypeGlow layer:t];
         }},
    };
    std::vector<CGImageRef> images;
    std::vector<std::string> captions;
    for (const Tile& t : tiles) {
        [e newProjectWithWidth:960 height:540 fps:30 duration:2];
        [e setCompositionWidth:960 height:540 fps:30 duration:2 background:MFValue{0.07, 0.075, 0.09, 1} name:@"Phase 4"];
        t.build(e);
        NSError* error = nil;
        CGImageRef img = [e copyImageAtTime:t.time scale:0.5 transparent:NO error:&error];
        if (!img) {
            std::fprintf(stderr, "%s: %s\n", t.caption, error.localizedDescription.UTF8String);
            return 1;
        }
        images.push_back(img);
        captions.push_back(t.caption);
    }
    CGImageRef sheet = contactSheet(images, captions, 3);
    const std::string out = std::string(dir) + "/phase4-sheet.png";
    writePNG(sheet, out);
    CGImageRelease(sheet);
    for (CGImageRef i : images) CGImageRelease(i);
    std::printf("wrote %s (%zu tiles)\n", out.c_str(), tiles.size());
    return 0;
}

}  // namespace

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 3) return usage();
        const std::string cmd = argv[1];
        if (cmd == "info") return cmdInfo(argv[2]);
        if (cmd == "render" && argc >= 4) return cmdRender(argc, argv);
        if (cmd == "time") return cmdTime(argc, argv);
        if (cmd == "frames" && argc >= 4) return cmdFrames(argc, argv);
        if (cmd == "demo") return cmdDemo(argv[2]);
        if (cmd == "effects-demo") return cmdEffectsDemo(argv[2]);
        if (cmd == "phase4-demo") return cmdPhase4Demo(argv[2]);
        return usage();
    }
}
