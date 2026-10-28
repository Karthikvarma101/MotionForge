// mfcli — headless MotionForge tool (same engine and renderer as the app).
//
//   mfcli info   <project.mfproj>
//   mfcli render <project.mfproj> <out.png> [--time S] [--scale F] [--transparent]
//   mfcli frames <project.mfproj> <out-dir> [--from S] [--to S] [--scale F]      PNG sequence
//   mfcli demo   <out-dir>     builds a project, edits position / scale / opacity, renders each
//                              state, measures the pixels and writes a side-by-side sheet
//   mfcli effects-demo <out-dir>   one tile per effect, mask and track matte, as a contact sheet
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

#include "MFEngine.h"

namespace {

int usage() {
    std::fprintf(stderr,
                 "usage:\n"
                 "  mfcli info   <project.mfproj>\n"
                 "  mfcli render <project.mfproj> <out.png> [--time S] [--scale F] [--transparent]\n"
                 "  mfcli frames <project.mfproj> <out-dir> [--from S] [--to S] [--scale F]\n"
                 "  mfcli demo   <out-dir>\n"
                 "  mfcli effects-demo <out-dir>\n");
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
    const double t = argDouble(argc, argv, "--time", 0), scale = argDouble(argc, argv, "--scale", 1);
    if (![e writePNGAtTime:t scale:scale transparent:argFlag(argc, argv, "--transparent") toPath:@(argv[3]) error:&error]) {
        std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    std::printf("wrote %s\n", argv[3]);
    return 0;
}

int cmdFrames(int argc, const char* argv[]) {
    MFEngine* e = openProject(argv[2]);
    if (!e) return 1;
    MFCompositionInfo* c = e.composition;
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

}  // namespace

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 3) return usage();
        const std::string cmd = argv[1];
        if (cmd == "info") return cmdInfo(argv[2]);
        if (cmd == "render" && argc >= 4) return cmdRender(argc, argv);
        if (cmd == "frames" && argc >= 4) return cmdFrames(argc, argv);
        if (cmd == "demo") return cmdDemo(argv[2]);
        if (cmd == "effects-demo") return cmdEffectsDemo(argv[2]);
        return usage();
    }
}
