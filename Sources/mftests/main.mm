// MotionForge test runner: core model + evaluation + project IO + undo + cache policy, and GPU
// render-correctness checks that read back real Metal output.
//
//   swift run -c release mftests            # all tests
//   swift run -c release mftests render     # only tests whose name contains "render"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <numeric>
#include <string>
#include <vector>

#include "MFEngine.h"
#include "MFRender/MetalRenderer.hpp"
#include "../MFRender/TextEngine.hpp"
#include "mf/Audio.hpp"
#include "mf/Clipboard.hpp"
#include "mf/Presets.hpp"
#include "mf/Document.hpp"
#include "mf/Evaluator.hpp"
#include "mf/Json.hpp"
#include "mf/LruCache.hpp"
#include "mf/ProjectIO.hpp"

using namespace mf;
namespace fs = std::filesystem;

// ---- tiny test harness ----------------------------------------------------------------------

static int gChecks = 0, gFailures = 0;
static const char* gCurrent = "";

#define CHECK(cond)                                                                        \
    do {                                                                                   \
        ++gChecks;                                                                         \
        if (!(cond)) {                                                                     \
            ++gFailures;                                                                   \
            std::fprintf(stderr, "    FAIL [%s] %s:%d  %s\n", gCurrent, __FILE__, __LINE__, #cond); \
        }                                                                                  \
    } while (0)

#define CHECK_NEAR(a, b, eps)                                                                      \
    do {                                                                                           \
        ++gChecks;                                                                                 \
        const double _a = (a), _b = (b);                                                           \
        if (!(std::abs(_a - _b) <= (eps))) {                                                       \
            ++gFailures;                                                                           \
            std::fprintf(stderr, "    FAIL [%s] %s:%d  %s = %.6f, expected %.6f ± %g\n", gCurrent, __FILE__, \
                         __LINE__, #a, _a, _b, double(eps));                                       \
        }                                                                                          \
    } while (0)

struct Test {
    const char* name;
    std::function<void()> fn;
};
static std::vector<Test>& registry() {
    static std::vector<Test> r;
    return r;
}
struct Register {
    Register(const char* n, std::function<void()> f) { registry().push_back({n, std::move(f)}); }
};
#define TEST(name)                                     \
    static void test_##name();                         \
    static Register reg_##name(#name, test_##name);    \
    static void test_##name()

// ---- helpers --------------------------------------------------------------------------------

static MetalRenderer& gpu() {
    static std::unique_ptr<MetalRenderer> r = [] {
        std::string err;
        auto x = MetalRenderer::create(nil, err);
        if (!x) {
            std::fprintf(stderr, "Metal unavailable: %s\n", err.c_str());
            std::exit(2);
        }
        return x;
    }();
    return *r;
}

struct Image {
    int w = 0, h = 0;
    std::vector<float> px;  // premultiplied RGBA
    float a(int x, int y) const { return px[(size_t(y) * w + x) * 4 + 3]; }
    const float* at(int x, int y) const { return &px[(size_t(y) * w + x) * 4]; }
};

static Image render(const Project& p, double t = 0, double scale = 1) {
    const Composition& c = *p.activeComp();
    FrameDesc f = evaluateFrame(p, c, t, scale);
    Image img;
    img.w = f.width;
    img.h = f.height;
    std::string err;
    if (!gpu().renderToRGBA(f, img.px, nullptr, err)) std::fprintf(stderr, "    render error: %s\n", err.c_str());
    return img;
}

struct Coverage {
    double area = 0, cx = 0, cy = 0, maxAlpha = 0;
    int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;  // pixels with alpha > 0.5
};
static Coverage coverage(const Image& img) {
    Coverage c;
    for (int y = 0; y < img.h; ++y)
        for (int x = 0; x < img.w; ++x) {
            const double a = img.a(x, y);
            c.area += a;
            c.cx += a * (x + 0.5);
            c.cy += a * (y + 0.5);
            c.maxAlpha = std::max(c.maxAlpha, a);
            if (a > 0.5) {
                c.minX = std::min(c.minX, x);
                c.minY = std::min(c.minY, y);
                c.maxX = std::max(c.maxX, x);
                c.maxY = std::max(c.maxY, y);
            }
        }
    if (c.area > 0) {
        c.cx /= c.area;
        c.cy /= c.area;
    }
    return c;
}

// Document with a 640x360 transparent comp and one 200x100 white rectangle at the centre.
static Document rectDoc(ObjectId* layerOut) {
    Document d(makeDefaultProject(640, 360, 30, 4));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addLayer(comp, LayerKind::Shape, ShapeType::Rectangle);
    d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {200, 100, 0, 0});
    d.setPropertyValue(comp, l, PropId::FillColor, 0, {1, 1, 1, 1});
    *layerOut = l;
    return d;
}

static std::string tempDir(const char* name) {
    fs::path p = fs::path(NSTemporaryDirectory().fileSystemRepresentation) / ("mftests-" + std::to_string(getpid())) / name;
    fs::create_directories(p);
    return p.string();
}

// 4x4 PNG: red | green over blue | white quadrants (2x2 each).
static void writeQuadrantPNG(const std::string& path) {
    const uint8_t q[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}};
    uint8_t px[4 * 4 * 4];
    for (int y = 0; y < 4; ++y)
        for (int x = 0; x < 4; ++x) {
            const int k = (y / 2) * 2 + (x / 2);
            std::memcpy(&px[(y * 4 + x) * 4], q[k], 4);
        }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, 4, 4, 8, 16, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    CGImageDestinationRef dst =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    CGImageDestinationAddImage(dst, img, nullptr);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

// =============================================================================================
// Core
// =============================================================================================

TEST(math_affine) {
    const Affine r = Affine::rotateDegrees(90);
    const Vec2 p = r.apply({1, 0});
    CHECK_NEAR(p.x, 0, 1e-12);
    CHECK_NEAR(p.y, 1, 1e-12);  // +90° turns +x towards +y (clockwise on a y-down screen)
    const Affine m = Affine::translate(10, -4) * Affine::rotateDegrees(33) * Affine::scale(2, 0.5);
    Affine inv;
    CHECK(m.inverse(inv));
    const Vec2 q = (inv * m).apply({7, 3});
    CHECK_NEAR(q.x, 7, 1e-9);
    CHECK_NEAR(q.y, 3, 1e-9);
    CHECK(!Affine::scale(0, 1).inverse(inv));
}

TEST(keyframes_interpolation) {
    Property p;
    Keyframe a, b;
    a.time = 0;
    a.value = {0, 100, 0, 0};
    b.time = 2;
    b.value = {10, 300, 0, 0};
    p.keyframes = {a, b};
    CHECK_NEAR(evaluateProperty(p, PropId::Position, 1)[0], 5, 1e-9);
    CHECK_NEAR(evaluateProperty(p, PropId::Position, 1)[1], 200, 1e-9);
    CHECK_NEAR(evaluateProperty(p, PropId::Position, -5)[0], 0, 1e-12);  // clamps before first key
    CHECK_NEAR(evaluateProperty(p, PropId::Position, 9)[0], 10, 1e-12);  // and after last

    p.keyframes[0].outInterp = Interp::Hold;
    CHECK_NEAR(evaluateProperty(p, PropId::Position, 1.99)[0], 0, 1e-12);

    p.keyframes[0].outInterp = Interp::Bezier;
    p.keyframes[1].inInterp = Interp::Bezier;
    const double mid = evaluateProperty(p, PropId::Position, 1)[0];
    const double early = evaluateProperty(p, PropId::Position, 0.5)[0];
    CHECK_NEAR(mid, 5, 1e-6);  // symmetric ease passes through the midpoint
    CHECK(early < 2.5);        // slow start
    CHECK(early > 0);

    // Opacity is clamped to its definition's range even if keys overshoot.
    Property o;
    o.value = {150, 0, 0, 0};
    CHECK_NEAR(evaluateProperty(o, PropId::Opacity, 0)[0], 100, 1e-12);
}

TEST(bezier_timing_monotonic) {
    double prev = -1;
    for (int i = 0; i <= 100; ++i) {
        const double v = cubicBezierTiming(0.33, 0, 0.67, 1, i / 100.0);
        CHECK(v >= prev - 1e-9);
        prev = v;
    }
    CHECK_NEAR(cubicBezierTiming(0.33, 0, 0.67, 1, 0), 0, 1e-12);
    CHECK_NEAR(cubicBezierTiming(0.33, 0, 0.67, 1, 1), 1, 1e-12);
    CHECK_NEAR(cubicBezierTiming(1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3, 0.37), 0.37, 1e-6);  // linear controls
}

TEST(transform_and_parenting) {
    Composition c;
    c.width = 1000;
    c.height = 1000;
    Layer parent = makeLayer(LayerKind::Null, c, 1);
    parent.prop(PropId::Position).value = {500, 500, 0, 0};
    parent.prop(PropId::Rotation).value[0] = 90;
    Layer child = makeLayer(LayerKind::Shape, c, 2);
    child.parent = 1;
    child.prop(PropId::Position).value = {100, 0, 0, 0};  // 100 px along the parent's +x
    child.prop(PropId::AnchorPoint).value = {0, 0, 0, 0};
    c.layers = {child, parent};
    const Vec2 o = layerWorldTransform(c, c.layers[0], 0).apply({0, 0});
    CHECK_NEAR(o.x, 500, 1e-9);
    CHECK_NEAR(o.y, 600, 1e-9);  // parent's +x is the comp's +y after a 90° turn

    // Anchor point is the pivot for scale and rotation.
    Layer s = makeLayer(LayerKind::Shape, c, 3);
    s.prop(PropId::Position).value = {200, 200, 0, 0};
    s.prop(PropId::AnchorPoint).value = {50, 0, 0, 0};
    s.prop(PropId::Scale).value = {200, 200, 0, 0};
    const Vec2 q = layerWorldTransform(c, s, 0).apply({50, 0});
    CHECK_NEAR(q.x, 200, 1e-9);
    CHECK_NEAR(q.y, 200, 1e-9);
}

TEST(evaluation_timing_and_visibility) {
    Document d(makeDefaultProject(320, 240, 25, 4));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId a = d.addLayer(comp, LayerKind::Shape);
    const ObjectId n = d.addLayer(comp, LayerKind::Null);
    d.setLayerTiming(comp, a, 1.0, 2.0);
    const Composition& c = *d.project().activeComp();
    CHECK(evaluateFrame(d.project(), c, 0.5).items.empty());
    CHECK(evaluateFrame(d.project(), c, 1.0).items.size() == 1);   // in point inclusive
    CHECK(evaluateFrame(d.project(), c, 2.0).items.empty());       // out point exclusive
    d.setLayerVisible(comp, a, false);
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 1.5).items.empty());
    (void)n;
}

TEST(frame_hash_precise_invalidation) {
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setPropertyAnimated(comp, l, PropId::Position, true, 0);              // key at t=0
    d.setPropertyValue(comp, l, PropId::Position, 2.0, {500, 100, 0, 0});    // key at t=2
    const uint64_t h0 = evaluateFrame(d.project(), *d.project().activeComp(), 0).hash;
    const uint64_t h1 = evaluateFrame(d.project(), *d.project().activeComp(), 1).hash;
    CHECK(h0 == evaluateFrame(d.project(), *d.project().activeComp(), 0).hash);  // deterministic
    CHECK(h0 != h1);

    // Editing the key at t=2 changes t=1 but leaves the frame at t=0 untouched -> still cached.
    d.setPropertyValue(comp, l, PropId::Position, 2.0, {600, 300, 0, 0});
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).hash == h0);
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 1).hash != h1);

    // Preview resolution is part of the key.
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0, 0.5).hash != h0);
}

TEST(undo_redo_and_groups) {
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    const Project before = d.project();
    const size_t depth = d.undoDepth();

    d.setPropertyValue(comp, l, PropId::Position, 0, {10, 20, 0, 0});
    CHECK(d.canUndo());
    CHECK(d.undo());
    CHECK(d.project() == before);
    CHECK(d.redo());
    CHECK_NEAR(d.project().activeComp()->findLayer(l)->prop(PropId::Position).value[0], 10, 0);

    // A drag = many updates inside one group = one undo step.
    d.beginGroup("Drag");
    for (int i = 0; i < 25; ++i) d.setPropertyValue(comp, l, PropId::Position, 0, {double(i), 0, 0, 0});
    d.endGroup();
    CHECK(d.undoDepth() == depth + 2);
    CHECK(d.undoLabel() == "Drag");
    d.undo();
    CHECK_NEAR(d.project().activeComp()->findLayer(l)->prop(PropId::Position).value[0], 10, 0);

    // No-op edits don't create undo steps.
    const size_t n = d.undoDepth();
    d.setPropertyValue(comp, l, PropId::Position, 0, {10, 20, 0, 0});
    CHECK(d.undoDepth() == n);
    CHECK(d.dirty());
}

TEST(parenting_rules) {
    Document d(makeDefaultProject(1000, 1000, 30, 4));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId a = d.addLayer(comp, LayerKind::Null);
    const ObjectId b = d.addLayer(comp, LayerKind::Shape);
    d.setPropertyValue(comp, a, PropId::Position, 0, {300, 300, 0, 0});
    d.setPropertyValue(comp, a, PropId::Rotation, 0, {30, 0, 0, 0});
    d.setPropertyValue(comp, a, PropId::Scale, 0, {50, 50, 0, 0});
    d.setPropertyValue(comp, b, PropId::Position, 0, {700, 400, 0, 0});
    const Composition& c0 = *d.project().activeComp();
    const auto before = layerCorners(d.project(), c0, *c0.findLayer(b), 0);
    CHECK(d.setLayerParent(comp, b, a));
    const Composition& c1 = *d.project().activeComp();
    const auto after = layerCorners(d.project(), c1, *c1.findLayer(b), 0);
    for (int i = 0; i < 4; ++i) {  // parenting keeps the layer where it was on screen
        CHECK_NEAR(after[i].x, before[i].x, 1e-6);
        CHECK_NEAR(after[i].y, before[i].y, 1e-6);
    }
    CHECK(!d.setLayerParent(comp, a, b));  // cycle refused
    CHECK(!d.setLayerParent(comp, a, a));
}

TEST(keyframe_editing) {
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setPropertyAnimated(comp, l, PropId::Opacity, true, 0);
    d.setPropertyValue(comp, l, PropId::Opacity, 1, {50, 0, 0, 0});
    d.setPropertyValue(comp, l, PropId::Opacity, 2, {0, 0, 0, 0});
    auto keys = [&] { return d.project().activeComp()->findLayer(l)->prop(PropId::Opacity).keyframes; };
    CHECK(keys().size() == 3);
    const int idx = d.moveKeyframe(comp, l, PropId::Opacity, 2, 1.0);  // onto the key at t=1: replaces it
    CHECK(idx == 1);
    CHECK(keys().size() == 2);
    CHECK_NEAR(keys()[1].value[0], 0, 0);
    CHECK(d.removeKeyframe(comp, l, PropId::Opacity, 0));
    CHECK(d.removeKeyframe(comp, l, PropId::Opacity, 0));
    CHECK(keys().empty());
    CHECK_NEAR(d.project().activeComp()->findLayer(l)->prop(PropId::Opacity).value[0], 0, 0);  // keeps last value
}

TEST(json_roundtrip) {
    Json o = Json::object();
    o.set("name", Json("Tëst \"q\" \n ✓"));
    o.set("n", Json(0.1));
    o.set("big", Json(int64_t(1) << 50));
    Json arr = Json::array();
    arr.push(Json(true));
    arr.push(Json());
    arr.push(Json(-3.25e-7));
    o.set("arr", arr);
    Json back;
    std::string err;
    CHECK(Json::parse(o.dump(), back, err));
    CHECK(back.get("name").string() == "Tëst \"q\" \n ✓");
    CHECK(back.get("n").number() == 0.1);  // shortest round-trip formatting is exact
    CHECK(back.get("big").number() == double(int64_t(1) << 50));
    CHECK(back.get("arr").items().size() == 3);
    CHECK(back.get("arr").items()[2].number() == -3.25e-7);
    CHECK(Json::parse("{\"a\":\"\\u00e9\\ud83d\\ude00\"}", back, err) && back.get("a").string() == "é😀");
    CHECK(!Json::parse("{\"a\": [1, 2}", back, err));
    CHECK(!Json::parse("{} trailing", back, err));
}

TEST(project_file_roundtrip_and_portability) {
    // Build a project with an image asset living next to the project file.
    const std::string dirA = tempDir("projA");
    fs::create_directories(fs::path(dirA) / "media");
    const std::string png = (fs::path(dirA) / "media" / "quad.png").string();
    writeQuadrantPNG(png);

    Document d(makeDefaultProject(1080, 1920, 24, 6));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId asset = d.addImageAsset(png, "quad.png", 4, 4);
    const ObjectId img = d.addLayer(comp, LayerKind::Image, ShapeType::Rectangle, asset);
    const ObjectId star = d.addLayer(comp, LayerKind::Shape, ShapeType::Star);
    d.setLayerBlend(comp, star, BlendMode::Screen);
    d.setLayerParent(comp, img, star);
    d.setPropertyAnimated(comp, star, PropId::Rotation, true, 0);
    d.setPropertyValue(comp, star, PropId::Rotation, 3, {270, 0, 0, 0});
    d.setKeyframeInterpolation(comp, star, PropId::Rotation, 0, Interp::Linear, Interp::Bezier);
    d.setLayerName(comp, star, "Star ★");

    const std::string file = (fs::path(dirA) / "test.mfproj").string();
    std::string err;
    CHECK(saveProjectFile(d.project(), file, err));
    Project loaded;
    CHECK(loadProjectFile(file, loaded, err));
    CHECK(loaded == d.project());

    // Move the whole folder: the relative path must win over the stale absolute one.
    const std::string dirB = tempDir("projB_moved");
    fs::remove_all(dirB);
    fs::rename(dirA, dirB);
    Project moved;
    CHECK(loadProjectFile((fs::path(dirB) / "test.mfproj").string(), moved, err));
    CHECK(!moved.assets.empty() && !moved.assets[0].missing);
    CHECK(!moved.assets.empty() && fs::path(moved.assets[0].path) == fs::path(dirB) / "media" / "quad.png");

    // Missing media is flagged, not fatal.
    fs::remove(fs::path(dirB) / "media" / "quad.png");
    Project missing;
    CHECK(loadProjectFile((fs::path(dirB) / "test.mfproj").string(), missing, err));
    CHECK(!missing.assets.empty() && missing.assets[0].missing);
}

TEST(project_file_rejects_bad_input) {
    Project p;
    std::string err;
    CHECK(!deserializeProject("not json", "", p, err));
    CHECK(!deserializeProject("{\"format\":\"something.else\",\"version\":1}", "", p, err));
    CHECK(!deserializeProject("{\"format\":\"motionforge.project\",\"version\":99,\"compositions\":[]}", "", p, err));
    CHECK(err.find("version 99") != std::string::npos);
}

TEST(lru_cache_budget) {
    std::vector<int> evicted;
    LruCache<int, int> c(300, [&](const int& k, int&&, size_t) { evicted.push_back(k); });
    c.insert(1, 10, 100);
    c.insert(2, 20, 100);
    c.insert(3, 30, 100);
    CHECK(c.find(1) != nullptr);  // 1 becomes most recent
    c.insert(4, 40, 100);         // evicts the least recent: 2
    CHECK(evicted.size() == 1 && evicted[0] == 2);
    CHECK(c.bytes() == 300);
    CHECK(!c.insert(5, 50, 1000));  // bigger than the whole budget: rejected, not cached
    CHECK(c.size() == 3);
    c.purgeTo(100);
    CHECK(c.size() == 1 && c.contains(4));
    c.setBudget(0);
    CHECK(c.size() == 0 && c.bytes() == 0);
}

// =============================================================================================
// GPU render correctness
// =============================================================================================

TEST(render_rect_area_and_centre) {
    ObjectId l;
    Document d = rectDoc(&l);
    const Coverage c = coverage(render(d.project()));
    CHECK_NEAR(c.area, 200 * 100, 200 * 100 * 0.005);
    CHECK_NEAR(c.cx, 320, 0.05);
    CHECK_NEAR(c.cy, 180, 0.05);
    CHECK_NEAR(c.maxAlpha, 1, 1e-3);
}

TEST(render_position_moves_pixels) {
    ObjectId l;
    Document d = rectDoc(&l);
    d.setPropertyValue(d.project().activeComposition, l, PropId::Position, 0, {413.5, 122.25, 0, 0});
    const Coverage c = coverage(render(d.project()));
    CHECK_NEAR(c.cx, 413.5, 0.05);  // sub-pixel accurate
    CHECK_NEAR(c.cy, 122.25, 0.05);
    CHECK_NEAR(c.area, 20000, 100);
}

TEST(render_scale_changes_area) {
    ObjectId l;
    Document d = rectDoc(&l);
    d.setPropertyValue(d.project().activeComposition, l, PropId::Scale, 0, {150, 50, 0, 0});
    const Coverage c = coverage(render(d.project()));
    CHECK_NEAR(c.area, 20000 * 1.5 * 0.5, 20000 * 0.75 * 0.01);
    CHECK(c.maxX - c.minX + 1 == 300);
    CHECK(c.maxY - c.minY + 1 == 50);
}

TEST(render_opacity_scales_alpha) {
    ObjectId l;
    Document d = rectDoc(&l);
    d.setPropertyValue(d.project().activeComposition, l, PropId::Opacity, 0, {50, 0, 0, 0});
    const Image img = render(d.project());
    const Coverage c = coverage(img);
    CHECK_NEAR(c.maxAlpha, 0.5, 0.002);  // half-float precision
    CHECK_NEAR(c.area, 10000, 60);
    CHECK_NEAR(img.at(320, 180)[0], 0.5, 0.002);  // premultiplied white at 50%
}

TEST(render_rotation_swaps_extent) {
    ObjectId l;
    Document d = rectDoc(&l);
    d.setPropertyValue(d.project().activeComposition, l, PropId::Rotation, 0, {90, 0, 0, 0});
    const Coverage c = coverage(render(d.project()));
    CHECK(c.maxX - c.minX + 1 == 100);
    CHECK(c.maxY - c.minY + 1 == 200);
    CHECK_NEAR(c.area, 20000, 100);
}

TEST(render_ellipse_star_polygon) {
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setLayerShape(comp, l, ShapeType::Ellipse);
    CHECK_NEAR(coverage(render(d.project())).area, M_PI * 100 * 50, M_PI * 100 * 50 * 0.01);

    d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {200, 200, 0, 0});
    d.setLayerShape(comp, l, ShapeType::Polygon);
    d.setPropertyValue(comp, l, PropId::Points, 0, {6, 0, 0, 0});
    const double hexArea = 1.5 * std::sqrt(3.0) * 100 * 100;  // regular hexagon, circumradius 100
    CHECK_NEAR(coverage(render(d.project())).area, hexArea, hexArea * 0.01);

    d.setLayerShape(comp, l, ShapeType::Star);
    d.setPropertyValue(comp, l, PropId::Points, 0, {5, 0, 0, 0});
    d.setPropertyValue(comp, l, PropId::InnerRatio, 0, {0.5, 0, 0, 0});
    // Star area = n * R * r * sin(pi/n)
    const double starArea = 5 * 100 * 50 * std::sin(M_PI / 5);
    const Image si = render(d.project());
    const Coverage s = coverage(si);
    CHECK_NEAR(s.area, starArea, starArea * 0.015);
    // First point straight up: the tip reaches y = 80 (a downward point would stop near y = 99).
    int tipY = 1 << 30;
    for (int y = 0; y < si.h; ++y)
        for (int x = 0; x < si.w; ++x)
            if (si.a(x, y) > 0.02 && y < tipY) tipY = y;
    CHECK_NEAR(tipY, 80, 1);
}

TEST(render_stroke) {
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setLayerFillStroke(comp, l, false, true);
    d.setPropertyValue(comp, l, PropId::StrokeWidth, 0, {10, 0, 0, 0});
    const Image img = render(d.project());
    // Centred stroke: the outline is 10 px wide around the 200x100 path.
    const double expected = 210 * 110 - 190 * 90;
    CHECK_NEAR(coverage(img).area, expected, expected * 0.01);
    CHECK(img.a(320, 180) < 1e-3);  // hollow
}

TEST(render_stacking_and_blend_modes) {
    Document d(makeDefaultProject(64, 64, 30, 1));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId bottom = d.addLayer(comp, LayerKind::Shape);  // ends up below `top`
    const ObjectId top = d.addLayer(comp, LayerKind::Shape);
    for (ObjectId id : {bottom, top}) d.setPropertyValue(comp, id, PropId::ShapeSize, 0, {40, 40, 0, 0});
    d.setPropertyValue(comp, bottom, PropId::FillColor, 0, {0.2, 0.6, 1.0, 1});
    d.setPropertyValue(comp, top, PropId::FillColor, 0, {1.0, 0.5, 0.0, 1});
    auto centre = [&] {
        const Image img = render(d.project());
        const float* p = img.at(32, 32);
        return std::array<float, 4>{p[0], p[1], p[2], p[3]};
    };
    auto c = centre();  // normal: the top layer wins, even inside a single instanced draw
    CHECK_NEAR(c[0], 1.0, 2e-3);
    CHECK_NEAR(c[1], 0.5, 2e-3);
    CHECK_NEAR(c[2], 0.0, 2e-3);

    d.setLayerBlend(comp, top, BlendMode::Multiply);
    c = centre();
    CHECK_NEAR(c[0], 0.2, 2e-3);
    CHECK_NEAR(c[1], 0.3, 2e-3);
    CHECK_NEAR(c[2], 0.0, 2e-3);

    d.setLayerBlend(comp, top, BlendMode::Screen);
    c = centre();
    CHECK_NEAR(c[0], 1.0, 2e-3);
    CHECK_NEAR(c[1], 0.8, 2e-3);
    CHECK_NEAR(c[2], 1.0, 2e-3);

    d.setLayerBlend(comp, top, BlendMode::Add);
    c = centre();
    CHECK_NEAR(c[0], 1.0, 2e-3);
    CHECK_NEAR(c[1], 1.0, 2e-3);
    CHECK_NEAR(c[2], 1.0, 2e-3);

    // Blending over transparency leaves the source unchanged (premultiplied formula).
    d.setLayerVisible(comp, bottom, false);
    d.setLayerBlend(comp, top, BlendMode::Multiply);
    c = centre();
    CHECK_NEAR(c[0], 1.0, 2e-3);
    CHECK_NEAR(c[3], 1.0, 2e-3);
}

TEST(render_image_layer_pixels) {
    const std::string dir = tempDir("img");
    const std::string png = (fs::path(dir) / "quad.png").string();
    writeQuadrantPNG(png);
    Document d(makeDefaultProject(8, 8, 30, 1));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId asset = d.addImageAsset(png, "quad.png", 4, 4);
    d.addLayer(comp, LayerKind::Image, ShapeType::Rectangle, asset);  // centred: covers pixels 2..5
    std::string err;
    CHECK(gpu().loadImageSync(asset, 0, png, err));
    const Image img = render(d.project());
    auto near = [](const float* p, float r, float g, float b) {
        return std::abs(p[0] - r) < 2e-3 && std::abs(p[1] - g) < 2e-3 && std::abs(p[2] - b) < 2e-3 &&
               std::abs(p[3] - 1) < 2e-3;
    };
    CHECK(near(img.at(2, 2), 1, 0, 0));
    CHECK(near(img.at(5, 2), 0, 1, 0));
    CHECK(near(img.at(2, 5), 0, 0, 1));
    CHECK(near(img.at(5, 5), 1, 1, 1));
    CHECK(img.a(1, 1) < 1e-3 && img.a(6, 6) < 1e-3);
}

TEST(render_preview_resolution) {
    ObjectId l;
    Document d = rectDoc(&l);
    const Image half = render(d.project(), 0, 0.5);
    CHECK(half.w == 320 && half.h == 180);
    const Coverage c = coverage(half);
    CHECK_NEAR(c.area, 5000, 50);
    CHECK_NEAR(c.cx, 160, 0.05);
}

TEST(render_frame_cache_hits) {
    ObjectId l;
    Document d = rectDoc(&l);
    MetalRenderer& r = gpu();
    r.setCacheBudget(256ull << 20);
    r.setCachePolicy(CachePolicy::All);
    r.clearCache();
    const FrameDesc f = evaluateFrame(d.project(), *d.project().activeComp(), 0);
    bool hit = false, complete = false;
    id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
    id<MTLTexture> t1 = r.compositeFrame(f, cb, true, &hit, &complete);
    [cb commit];
    CHECK(!hit && complete && t1 != nil);
    cb = [r.queue() commandBuffer];
    id<MTLTexture> t2 = r.compositeFrame(f, cb, true, &hit, &complete);
    [cb commit];
    [cb waitUntilCompleted];
    CHECK(hit && t2 != nil);
    CHECK(t2.pixelFormat == MTLPixelFormatRGBA8Unorm);  // cached copies are 8-bit: half the memory
    CHECK(r.stats().cacheBytes == cachedFrameBytes(f.width, f.height));
    // Budget too small for one frame: nothing is retained.
    r.setCacheBudget(cachedFrameBytes(f.width, f.height) - 1);
    CHECK(r.stats().cacheFrames == 0);
    r.setCacheBudget(256ull << 20);
    r.setCachePolicy(CachePolicy::Smart);
}

// Smart caching: a frame cheaper to redraw than the threshold is not kept; one with effects is.
// The threshold is set so the decision doesn't depend on how fast this GPU happens to be.
TEST(render_cache_admission_is_cost_aware) {
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    MetalRenderer& r = gpu();
    r.setCachePolicy(CachePolicy::Smart);
    r.clearCache();
    auto renderOnce = [&](const FrameDesc& f, bool useCache) {
        bool hit = false, complete = false;
        id<MTLCommandBuffer> cb = [r.queue() commandBuffer];
        r.compositeFrame(f, cb, useCache, &hit, &complete);
        [cb commit];
        [cb waitUntilCompleted];
        return hit;
    };
    const FrameDesc cheap = evaluateFrame(d.project(), *d.project().activeComp(), 0);
    renderOnce(cheap, false);
    CHECK(r.measuredCostMs(cheap) > 0);       // GPU time is measured for every composite
    r.setAdmissionThresholdMs(1e6);           // nothing is "expensive"…
    CHECK(!r.wouldCache(cheap));
    renderOnce(cheap, true);
    CHECK(!r.cacheContains(cheap.hash));      // …so a plain frame is drawn, not kept
    r.setAdmissionThresholdMs(0);             // everything is "expensive"
    CHECK(r.wouldCache(cheap));

    r.setAdmissionThresholdMs(1e6);
    d.addEffect(comp, l, EffectType::GaussianBlur);
    const FrameDesc blurred = evaluateFrame(d.project(), *d.project().activeComp(), 0);
    CHECK(r.wouldCache(blurred));             // frames with effects are always worth keeping
    renderOnce(blurred, true);
    CHECK(r.cacheContains(blurred.hash));
    CHECK(renderOnce(blurred, true));         // second request is a hit
    r.setAdmissionThresholdMs(0.75);
}

// =============================================================================================
// Effects, masks, track mattes (Phase 3)
// =============================================================================================

// Solid-colour rectangle w x h at the centre of a 640x360 comp.
static Document colorRectDoc(ObjectId* layerOut, double w, double h, Value color) {
    Document d(makeDefaultProject(640, 360, 30, 4));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addLayer(comp, LayerKind::Shape, ShapeType::Rectangle);
    d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {w, h, 0, 0});
    d.setPropertyValue(comp, l, PropId::FillColor, 0, color);
    *layerOut = l;
    return d;
}

static void setFx(Document& d, ObjectId l, ObjectId fx, int param, Value v) {
    d.setPropertyValue(d.project().activeComposition, l, PropRef::effect(fx, param), 0, v);
}

TEST(effect_blur_conserves_mass_and_spreads) {
    ObjectId l;
    Document d = colorRectDoc(&l, 200, 100, {1, 1, 1, 1});
    const ObjectId fx = d.addEffect(d.project().activeComposition, l, EffectType::GaussianBlur);
    setFx(d, l, fx, 0, {30, 0, 0, 0});
    const Image img = render(d.project());
    const Coverage c = coverage(img);
    CHECK_NEAR(c.area, 20000, 20000 * 0.01);  // blur moves alpha, never creates or loses it
    CHECK_NEAR(c.cx, 320, 0.1);
    CHECK(img.a(320, 180 - 50 - 12) > 0.05);  // spread beyond the original top edge
    CHECK(img.a(320, 180) > 0.9);             // centre stays nearly solid
    CHECK(c.maxY - c.minY + 1 >= 98 && c.maxY - c.minY + 1 <= 102);  // 50% contour stays on the edge
}

TEST(effect_blur_matches_across_preview_resolutions) {
    ObjectId l;
    Document d = colorRectDoc(&l, 200, 100, {1, 1, 1, 1});
    const ObjectId fx = d.addEffect(d.project().activeComposition, l, EffectType::GaussianBlur);
    setFx(d, l, fx, 0, {30, 0, 0, 0});
    const Image full = render(d.project(), 0, 1.0);
    const Image half = render(d.project(), 0, 0.5);
    // 12 px above the edge at full resolution is 6 px above it at half resolution.
    CHECK_NEAR(full.a(320, 130 - 12), half.a(160, 65 - 6), 0.04);
    CHECK_NEAR(coverage(half).area, 5000, 5000 * 0.015);
}

TEST(effect_drop_shadow) {
    ObjectId l;
    Document d = colorRectDoc(&l, 100, 100, {1, 1, 1, 1});
    const ObjectId fx = d.addEffect(d.project().activeComposition, l, EffectType::DropShadow);
    setFx(d, l, fx, 1, {100, 0, 0, 0});  // opacity
    setFx(d, l, fx, 2, {90, 0, 0, 0});   // direction: right
    setFx(d, l, fx, 3, {40, 0, 0, 0});   // distance
    setFx(d, l, fx, 4, {0, 0, 0, 0});    // hard shadow
    const Image img = render(d.project());
    const float* inside = img.at(320, 180);
    CHECK_NEAR(inside[0], 1, 2e-3);              // layer stays on top
    const float* shadow = img.at(320 + 50 + 20, 180);
    CHECK_NEAR(shadow[3], 1, 2e-3);              // black, opaque shadow to the right
    CHECK_NEAR(shadow[0], 0, 2e-3);
    CHECK(img.a(320 - 50 - 10, 180) < 1e-3);     // nothing to the left
    CHECK_NEAR(coverage(img).area, 10000 + 40 * 100, 150);
}

TEST(effect_glow) {
    ObjectId l;
    Document d = colorRectDoc(&l, 100, 100, {1, 1, 1, 1});
    const ObjectId fx = d.addEffect(d.project().activeComposition, l, EffectType::Glow);
    setFx(d, l, fx, 1, {40, 0, 0, 0});
    const Image img = render(d.project());
    CHECK(img.a(320, 180 - 50 - 8) > 0.05);   // light spills outside the layer
    CHECK_NEAR(img.at(320, 180)[0], 1, 2e-3);  // white stays white
    CHECK(coverage(img).area > 10000 * 1.1);

    // A dark layer is below the threshold: no glow at all.
    d.setPropertyValue(d.project().activeComposition, l, PropId::FillColor, 0, {0.1, 0.1, 0.1, 1});
    CHECK_NEAR(coverage(render(d.project())).area, 10000, 60);
}

TEST(effect_brightness_contrast) {
    ObjectId l;
    Document d = colorRectDoc(&l, 100, 100, {0.5, 0.5, 0.5, 1});
    const ObjectId comp = d.project().activeComposition;
    const ObjectId fx = d.addEffect(comp, l, EffectType::BrightnessContrast);
    setFx(d, l, fx, 0, {50, 0, 0, 0});
    CHECK_NEAR(render(d.project()).at(320, 180)[0], 0.75, 3e-3);
    setFx(d, l, fx, 0, {0, 0, 0, 0});
    setFx(d, l, fx, 1, {50, 0, 0, 0});
    CHECK_NEAR(render(d.project()).at(320, 180)[0], 0.5, 3e-3);  // mid-grey is the contrast pivot
    d.setPropertyValue(comp, l, PropId::FillColor, 0, {0.6, 0.6, 0.6, 1});
    CHECK_NEAR(render(d.project()).at(320, 180)[0], 0.5 + 0.1 / (1 - 0.45), 4e-3);
}

TEST(effect_hue_saturation_and_fill) {
    ObjectId l;
    Document d = colorRectDoc(&l, 100, 100, {1, 0, 0, 1});
    const ObjectId comp = d.project().activeComposition;
    const ObjectId fx = d.addEffect(comp, l, EffectType::HueSaturation);
    setFx(d, l, fx, 0, {120, 0, 0, 0});
    const float* g = render(d.project()).at(320, 180);
    CHECK_NEAR(g[0], 0, 3e-3);  // red + 120° = green
    CHECK_NEAR(g[1], 1, 3e-3);
    CHECK_NEAR(g[2], 0, 3e-3);
    setFx(d, l, fx, 0, {0, 0, 0, 0});
    setFx(d, l, fx, 1, {-100, 0, 0, 0});
    const float* grey = render(d.project()).at(320, 180);
    CHECK_NEAR(grey[0], 0.5, 3e-3);
    CHECK_NEAR(grey[1], 0.5, 3e-3);

    d.removeEffect(comp, l, fx);
    const ObjectId fill = d.addEffect(comp, l, EffectType::Fill);
    setFx(d, l, fill, 0, {0.2, 0.4, 1.0, 1});
    const Image img = render(d.project());
    CHECK_NEAR(img.at(320, 180)[2], 1.0, 3e-3);
    CHECK_NEAR(img.at(320, 180)[1], 0.4, 3e-3);
    CHECK_NEAR(coverage(img).area, 10000, 60);  // alpha untouched
}

TEST(effect_disable_and_noop_leave_frame_unchanged) {
    ObjectId l;
    Document d = colorRectDoc(&l, 100, 100, {1, 1, 1, 1});
    const ObjectId comp = d.project().activeComposition;
    const uint64_t plain = evaluateFrame(d.project(), *d.project().activeComp(), 0).hash;
    const ObjectId fx = d.addEffect(comp, l, EffectType::GaussianBlur);
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).hash != plain);
    d.setEffectEnabled(comp, l, fx, false);
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).hash == plain);
    d.setEffectEnabled(comp, l, fx, true);
    setFx(d, l, fx, 0, {0, 0, 0, 0});  // zero radius = no-op: same frame, served from the same cache entry
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).hash == plain);

    // Effect parameters animate like any property.
    d.setPropertyAnimated(comp, l, PropRef::effect(fx, 0), true, 0);
    d.setPropertyValue(comp, l, PropRef::effect(fx, 0), 1.0, {40, 0, 0, 0});
    const FrameDesc mid = evaluateFrame(d.project(), *d.project().activeComp(), 0.5);
    CHECK(mid.effects.size() == 1 && std::abs(mid.effects[0].v[0] - 20) < 1e-9);
    CHECK(d.undo() && d.undo());
    CHECK(!d.project().activeComp()->findLayer(l)->effects[0].params[0].animated());
}

TEST(mask_modes) {
    ObjectId l;
    Document d = colorRectDoc(&l, 200, 100, {1, 1, 1, 1});
    const ObjectId comp = d.project().activeComposition;
    const ObjectId m = d.addMask(comp, l, MaskShape::Ellipse);
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Size), 0, {200, 100, 0, 0});
    const double ellipse = M_PI * 100 * 50;
    CHECK_NEAR(coverage(render(d.project())).area, ellipse, ellipse * 0.01);
    d.setMaskMode(comp, l, m, MaskMode::Subtract, false);
    CHECK_NEAR(coverage(render(d.project())).area, 20000 - ellipse, (20000 - ellipse) * 0.03);
    d.setMaskMode(comp, l, m, MaskMode::Add, true);  // inverted add == subtract
    CHECK_NEAR(coverage(render(d.project())).area, 20000 - ellipse, (20000 - ellipse) * 0.03);

    // Two masks: ellipse intersected with the left half.
    d.setMaskMode(comp, l, m, MaskMode::Add, false);
    const ObjectId half = d.addMask(comp, l, MaskShape::Rectangle);
    d.setPropertyValue(comp, l, PropRef::mask(half, MaskParam::Position), 0, {-50, 0, 0, 0});
    d.setPropertyValue(comp, l, PropRef::mask(half, MaskParam::Size), 0, {100, 100, 0, 0});
    d.setMaskMode(comp, l, half, MaskMode::Intersect, false);
    const Coverage c = coverage(render(d.project()));
    CHECK_NEAR(c.area, ellipse / 2, ellipse / 2 * 0.015);
    CHECK(c.cx < 320);

    // Feather softens the edge but keeps the area; mask opacity scales it.
    d.removeMask(comp, l, half);
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Feather), 0, {20, 0, 0, 0});
    CHECK_NEAR(coverage(render(d.project())).area, ellipse, ellipse * 0.04);
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Feather), 0, {0, 0, 0, 0});
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Opacity), 0, {50, 0, 0, 0});
    CHECK_NEAR(coverage(render(d.project())).maxAlpha, 0.5, 3e-3);
    d.setMaskEnabled(comp, l, m, false);
    CHECK_NEAR(coverage(render(d.project())).area, 20000, 100);
}

TEST(mask_with_effect_masks_before_blur) {
    ObjectId l;
    Document d = colorRectDoc(&l, 200, 100, {1, 1, 1, 1});
    const ObjectId comp = d.project().activeComposition;
    const ObjectId m = d.addMask(comp, l, MaskShape::Rectangle);
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Size), 0, {100, 100, 0, 0});
    const ObjectId fx = d.addEffect(comp, l, EffectType::GaussianBlur);
    setFx(d, l, fx, 0, {20, 0, 0, 0});
    const Image img = render(d.project());
    CHECK_NEAR(coverage(img).area, 10000, 150);  // the blur spreads the masked 100x100, not the 200x100
    CHECK(img.a(320 - 50 - 6, 180) > 0.02);      // soft edge outside the mask
    CHECK(img.a(320 - 95, 180) < 0.002);         // but nothing where the mask cut the layer
}

TEST(mask_on_image_layer) {
    const std::string dir = tempDir("maskimg");
    const std::string png = (fs::path(dir) / "quad.png").string();
    writeQuadrantPNG(png);
    Document d(makeDefaultProject(8, 8, 30, 1));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId asset = d.addImageAsset(png, "quad.png", 4, 4);
    const ObjectId l = d.addLayer(comp, LayerKind::Image, ShapeType::Rectangle, asset);
    const ObjectId m = d.addMask(comp, l, MaskShape::Rectangle);
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Position), 0, {1, 1, 0, 0});
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Size), 0, {2, 2, 0, 0});
    std::string err;
    CHECK(gpu().loadImageSync(asset, 0, png, err));
    const Image img = render(d.project());
    CHECK(img.a(2, 2) > 0.99 && img.at(2, 2)[0] > 0.99);  // red quadrant kept
    CHECK(img.a(5, 2) < 1e-3 && img.a(5, 5) < 1e-3);      // the rest is masked away
}

TEST(track_matte_modes) {
    Document d(makeDefaultProject(640, 360, 30, 4));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId fill = d.addLayer(comp, LayerKind::Shape, ShapeType::Rectangle);
    d.setPropertyValue(comp, fill, PropId::ShapeSize, 0, {400, 200, 0, 0});
    d.setPropertyValue(comp, fill, PropId::FillColor, 0, {1, 1, 1, 1});
    const ObjectId matte = d.addLayer(comp, LayerKind::Shape, ShapeType::Ellipse);  // on top
    d.setPropertyValue(comp, matte, PropId::ShapeSize, 0, {200, 200, 0, 0});
    d.setPropertyValue(comp, matte, PropId::FillColor, 0, {1, 1, 1, 1});
    CHECK(d.setLayerMatte(comp, fill, matte, MatteMode::Alpha));
    CHECK(!d.project().activeComp()->findLayer(matte)->visible);  // matte layer hidden automatically
    CHECK(!d.setLayerMatte(comp, fill, fill, MatteMode::Alpha));   // not itself
    const double circle = M_PI * 100 * 100;
    CHECK_NEAR(coverage(render(d.project())).area, circle, circle * 0.01);

    d.setLayerMatte(comp, fill, matte, MatteMode::AlphaInverted);
    CHECK_NEAR(coverage(render(d.project())).area, 80000 - circle, (80000 - circle) * 0.01);

    d.setPropertyValue(comp, matte, PropId::FillColor, 0, {0.5, 0.5, 0.5, 1});
    d.setLayerMatte(comp, fill, matte, MatteMode::Luma);
    const Image luma = render(d.project());
    CHECK_NEAR(luma.a(320, 180), 0.5, 4e-3);  // 50% grey matte -> 50% alpha
    CHECK(luma.a(320 + 150, 180) < 1e-3);     // outside the circle the matte is empty

    // Matte source out of its time range: an alpha matte hides the layer, an inverted one shows all.
    d.setLayerMatte(comp, fill, matte, MatteMode::Alpha);
    d.setLayerTiming(comp, matte, 2, 4);
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).items.empty());
    d.setLayerMatte(comp, fill, matte, MatteMode::AlphaInverted);
    CHECK_NEAR(coverage(render(d.project())).area, 80000, 300);

    // Deleting the matte layer clears the reference.
    d.removeLayer(comp, matte);
    CHECK(!d.project().activeComp()->findLayer(fill)->hasMatte());
}

TEST(project_file_v2_effects_masks_mattes) {
    Document d(makeDefaultProject(1920, 1080, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId a = d.addLayer(comp, LayerKind::Shape, ShapeType::Star);
    const ObjectId b = d.addLayer(comp, LayerKind::Shape, ShapeType::Ellipse);
    const ObjectId fx = d.addEffect(comp, a, EffectType::DropShadow);
    d.setPropertyAnimated(comp, a, PropRef::effect(fx, 3), true, 0);
    d.setPropertyValue(comp, a, PropRef::effect(fx, 3), 2, {80, 0, 0, 0});
    d.addEffect(comp, a, EffectType::HueSaturation);
    const ObjectId m = d.addMask(comp, a, MaskShape::Ellipse);
    d.setMaskMode(comp, a, m, MaskMode::Difference, true);
    d.setPropertyValue(comp, a, PropRef::mask(m, MaskParam::Feather), 0, {12, 0, 0, 0});
    d.setLayerMatte(comp, a, b, MatteMode::LumaInverted);
    const std::string text = serializeProject(d.project(), "");
    CHECK(text.find("\"version\": " + std::to_string(Project::kFormatVersion)) != std::string::npos);
    Project back;
    std::string err;
    CHECK(deserializeProject(text, "", back, err));
    CHECK(back == d.project());

    // A version-1 file (no masks/effects keys) still opens.
    const std::string v1 = R"({"format":"motionforge.project","version":1,"nextId":3,"activeComposition":1,
        "assets":[],"compositions":[{"id":1,"name":"Old","width":640,"height":360,"fps":24,"duration":2,
        "layers":[{"id":2,"name":"Box","kind":"shape","shape":"rectangle","properties":{}}]}]})";
    Project old;
    CHECK(deserializeProject(v1, "", old, err));
    CHECK(old.compositions.size() == 1 && old.compositions[0].layers.size() == 1 &&
          old.compositions[0].layers[0].effects.empty());
}

// =============================================================================================
// Phase 2: motion paths, multi-selection operations, clipboard
// =============================================================================================

// Layer with position keys at t = 0, 1, 2 through (100,500) (500,100) (900,500).
static Document pathDoc(ObjectId* layerOut) {
    Document d(makeDefaultProject(1000, 600, 30, 3));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addLayer(comp, LayerKind::Shape);
    d.setPropertyAnimated(comp, l, PropId::Position, true, 0);
    d.setPropertyValue(comp, l, PropId::Position, 0, {100, 500, 0, 0});
    d.setPropertyValue(comp, l, PropId::Position, 1, {500, 100, 0, 0});
    d.setPropertyValue(comp, l, PropId::Position, 2, {900, 500, 0, 0});
    *layerOut = l;
    return d;
}

static Vec2 posAt(const Document& d, ObjectId l, double t) {
    const Value v = evaluateProperty(d.project().activeComp()->findLayer(l)->prop(PropId::Position), PropId::Position, t);
    return {v[0], v[1]};
}

static double turnDegrees(Vec2 a, Vec2 b, Vec2 c) {  // angle between a->b and b->c
    const double a1 = std::atan2(b.y - a.y, b.x - a.x), a2 = std::atan2(c.y - b.y, c.x - b.x);
    double d = std::abs(a2 - a1) * 180 / M_PI;
    return d > 180 ? 360 - d : d;
}

TEST(spatial_auto_bezier_is_smooth_and_hits_keys) {
    ObjectId l;
    Document d = pathDoc(&l);
    const Property& p = d.project().activeComp()->findLayer(l)->prop(PropId::Position);
    CHECK(p.keyframes.size() == 3 && p.keyframes[1].spatial == Spatial::Auto);  // new position keys are smooth
    const Vec2 mid = posAt(d, l, 1);
    CHECK_NEAR(mid.x, 500, 1e-9);
    CHECK_NEAR(mid.y, 100, 1e-9);
    // No corner at the middle key…
    CHECK(turnDegrees(posAt(d, l, 0.99), mid, posAt(d, l, 1.01)) < 3);
    // …and the path bows outward instead of following the straight chord.
    const Vec2 q = posAt(d, l, 0.5);
    const double chordDist = std::abs((500 - 100) * (500 - q.y) - (100 - 500) * (100 - q.x)) / std::hypot(400, 400);
    CHECK(chordDist > 10);

    // Linear spatial keys give straight segments with a corner.
    const ObjectId comp = d.project().activeComposition;
    for (int i = 0; i < 3; ++i) d.setKeyframeSpatial(comp, l, PropRef::layer(PropId::Position), i, Spatial::Linear, {}, {});
    CHECK(turnDegrees(posAt(d, l, 0.99), posAt(d, l, 1), posAt(d, l, 1.01)) > 80);
    const Vec2 lin = posAt(d, l, 0.5);
    CHECK_NEAR(lin.x, 300, 1e-9);
    CHECK_NEAR(lin.y, 300, 1e-9);
}

TEST(spatial_linear_timing_moves_at_constant_speed) {
    ObjectId l;
    Document d = pathDoc(&l);
    // Equal time steps cover equal distances along the curve (arc-length parameterisation).
    std::vector<double> steps;
    Vec2 prev = posAt(d, l, 0);
    for (int i = 1; i <= 30; ++i) {
        const Vec2 cur = posAt(d, l, i / 30.0);
        steps.push_back(std::hypot(cur.x - prev.x, cur.y - prev.y));
        prev = cur;
    }
    const double mean = std::accumulate(steps.begin(), steps.end(), 0.0) / steps.size();
    for (double s : steps) CHECK_NEAR(s, mean, mean * 0.02);
}

TEST(spatial_explicit_bezier_handles) {
    Property p;
    Keyframe a, b;
    a.time = 0;
    a.value = {0, 0, 0, 0};
    a.spatial = Spatial::Bezier;
    a.tangentOut = {0, 100, 0, 0};
    b.time = 1;
    b.value = {100, 0, 0, 0};
    b.spatial = Spatial::Bezier;
    b.tangentIn = {0, 100, 0, 0};
    p.keyframes = {a, b};
    const Value v = evaluateProperty(p, PropId::Position, 0.5);
    CHECK_NEAR(v[0], 50, 0.5);  // symmetric arch: halfway in time is the apex
    CHECK_NEAR(v[1], 75, 0.5);
    const auto path = sampleMotionPath(p, 16);
    CHECK(path.size() == 17);
    CHECK_NEAR(path[8][1], 75, 1e-9);

    // Files written before version 3 have no "spatial" key: their paths stay straight.
    Json kj;
    std::string err;
    CHECK(Json::parse(R"({"t":0,"v":[1,2],"in":"linear","out":"linear"})", kj, err));
    CHECK(keyframeFromJson(kj, {}).spatial == Spatial::Linear);
    const Keyframe back = keyframeFromJson(keyframeToJson(a, propDef(PropId::Position)), {});
    CHECK(back == a);
}

TEST(spatial_handle_edit_invalidates_only_between_keys) {
    ObjectId l;
    Document d = pathDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    auto hashAt = [&](double t) { return evaluateFrame(d.project(), *d.project().activeComp(), t).hash; };
    const uint64_t atKey = hashAt(1), between = hashAt(0.5), later = hashAt(1.5);
    d.setKeyframeSpatial(comp, l, PropRef::layer(PropId::Position), 0, Spatial::Bezier, {0, 0, 0, 0}, {0, -200, 0, 0});
    CHECK(hashAt(1) == atKey);       // keys stay where they are
    CHECK(hashAt(0.5) != between);   // the curve between key 0 and 1 changed
    CHECK(hashAt(1.5) == later);     // the next segment didn't
    d.undo();
    CHECK(hashAt(0.5) == between);
}

TEST(multi_keyframe_move_delete_ease) {
    ObjectId l;
    Document d = pathDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setPropertyAnimated(comp, l, PropId::Opacity, true, 0);
    d.setPropertyValue(comp, l, PropId::Opacity, 2, {0, 0, 0, 0});
    const PropRef pos = PropRef::layer(PropId::Position), op = PropRef::layer(PropId::Opacity);
    const size_t depth = d.undoDepth();
    // Move position keys 1 and 2 and opacity key 0 by +0.5 s in one step.
    const auto moved = d.moveKeyframes(comp, {{l, pos, 1}, {l, pos, 2}, {l, op, 0}}, 0.5);
    CHECK(d.undoDepth() == depth + 1);
    const Layer& L = *d.project().activeComp()->findLayer(l);
    CHECK_NEAR(L.prop(PropId::Position).keyframes[1].time, 1.5, 1e-9);
    CHECK_NEAR(L.prop(PropId::Position).keyframes[2].time, 2.5, 1e-9);
    CHECK_NEAR(L.prop(PropId::Opacity).keyframes[0].time, 0.5, 1e-9);
    CHECK(moved.size() == 3 && moved[0].index == 1 && moved[1].index == 2 && moved[2].index == 0);
    // Landing on an unselected key replaces it.
    const auto onto = d.moveKeyframes(comp, {{l, pos, 1}}, -1.5);  // 1.5 -> 0.0, onto key 0
    const Layer& L2 = *d.project().activeComp()->findLayer(l);
    CHECK(L2.prop(PropId::Position).keyframes.size() == 2);
    CHECK(onto[0].index == 0);
    CHECK_NEAR(L2.prop(PropId::Position).keyframes[0].value[0], 500, 1e-9);
    // Ease several keys, then delete several.
    CHECK(d.setKeyframesInterpolation(comp, {{l, pos, 0}, {l, op, 0}}, Interp::Bezier, Interp::Bezier));
    CHECK(d.project().activeComp()->findLayer(l)->prop(PropId::Opacity).keyframes[0].outInterp == Interp::Bezier);
    CHECK(d.removeKeyframes(comp, {{l, pos, 0}, {l, pos, 1}, {l, pos, 0}}));
    CHECK(d.project().activeComp()->findLayer(l)->prop(PropId::Position).keyframes.empty());
    d.undo();
    CHECK(d.project().activeComp()->findLayer(l)->prop(PropId::Position).keyframes.size() == 2);
    // A key's value can be edited away from the playhead (motion-path drag).
    CHECK(d.setKeyframeValue(comp, l, pos, 1, {10, 20, 0, 0}));
    CHECK_NEAR(d.project().activeComp()->findLayer(l)->prop(PropId::Position).keyframes[1].value[1], 20, 0);
}

TEST(multi_layer_delete_and_duplicate) {
    Document d(makeDefaultProject(640, 360, 30, 2));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId a = d.addLayer(comp, LayerKind::Null);
    const ObjectId b = d.addLayer(comp, LayerKind::Shape);
    const ObjectId c = d.addLayer(comp, LayerKind::Shape);
    d.setLayerParent(comp, b, a);
    d.setLayerMatte(comp, c, b, MatteMode::Alpha);
    const size_t depth = d.undoDepth();
    const auto dup = d.duplicateLayers(comp, {a, b});
    CHECK(dup.size() == 2 && d.undoDepth() == depth + 1);
    const Composition& C = *d.project().activeComp();
    CHECK(C.layers.size() == 5);
    // Copies come back top-first (b above a), and b's copy is parented to a's copy, not to a.
    CHECK(C.findLayer(dup[0])->parent == dup[1]);
    CHECK(C.findLayer(dup[1])->name != C.findLayer(a)->name);
    CHECK(C.indexOf(dup[0]) < C.indexOf(dup[1]));
    CHECK(d.removeLayers(comp, {a, b}));
    const Composition& C2 = *d.project().activeComp();
    CHECK(C2.layers.size() == 3);
    CHECK(!C2.findLayer(c)->hasMatte());  // matte source deleted -> link cleared
    d.undo();
    CHECK(d.project().activeComp()->layers.size() == 5);
}

TEST(clipboard_layers_between_projects) {
    const std::string dir = tempDir("clip");
    const std::string png = (fs::path(dir) / "quad.png").string();
    writeQuadrantPNG(png);
    Document src(makeDefaultProject(640, 360, 30, 2));
    const ObjectId sc = src.project().activeComposition;
    const ObjectId asset = src.addImageAsset(png, "quad.png", 4, 4);
    const ObjectId ctrl = src.addLayer(sc, LayerKind::Null);
    const ObjectId img = src.addLayer(sc, LayerKind::Image, ShapeType::Rectangle, asset);
    const ObjectId outsider = src.addLayer(sc, LayerKind::Null);
    const ObjectId star = src.addLayer(sc, LayerKind::Shape, ShapeType::Star);
    src.setLayerParent(sc, img, ctrl);
    src.setLayerParent(sc, star, outsider);
    src.setLayerMatte(sc, star, img, MatteMode::Luma);
    src.addEffect(sc, star, EffectType::Glow);
    src.addMask(sc, star, MaskShape::Ellipse);
    const std::string text = copyLayers(src.project(), sc, {star, img, ctrl});
    CHECK(clipboardKind(text) == ClipboardKind::Layers);

    Document dst(makeDefaultProject(1920, 1080, 25, 4));
    const ObjectId dc = dst.project().activeComposition;
    std::string err;
    const auto pasted = pasteLayers(dst, dc, text, 0, err);
    CHECK(pasted.size() == 3);
    const Composition& D = *dst.project().activeComp();
    CHECK(D.layers.size() == 3 && D.layers[0].id == pasted[0]);  // stacking order kept: star on top
    const Layer& pStar = *D.findLayer(pasted[0]);
    const Layer& pImg = *D.findLayer(pasted[1]);
    const Layer& pCtrl = *D.findLayer(pasted[2]);
    CHECK(pImg.parent == pCtrl.id);                     // link inside the copied set survives
    CHECK(pStar.parent == 0);                           // link to a layer that wasn't copied is dropped
    CHECK(pStar.matteLayer == pImg.id && pStar.matteMode == MatteMode::Luma);
    CHECK(dst.project().assets.size() == 1 && dst.project().assets[0].path == png);  // media came along
    CHECK(pImg.asset == dst.project().assets[0].id);
    CHECK(pStar.effects.size() == 1 && pStar.masks.size() == 1);
    // Pasting again into the same comp reuses the media and keeps ids and names unique.
    const auto again = pasteLayers(dst, dc, text, 0, err);
    CHECK(again.size() == 3 && dst.project().assets.size() == 1);
    CHECK(dst.project().activeComp()->findLayer(again[0])->name != pStar.name);
    std::vector<ObjectId> all;
    for (const Layer& l : dst.project().activeComp()->layers) {
        all.push_back(l.id);
        for (const Mask& m : l.masks) all.push_back(m.id);
        for (const Effect& e : l.effects) all.push_back(e.id);
    }
    std::sort(all.begin(), all.end());
    CHECK(std::adjacent_find(all.begin(), all.end()) == all.end());  // every id unique
    CHECK(pasteLayers(dst, dc, "{\"format\":\"something\"}", 0, err).empty());
}

TEST(clipboard_keyframes_relative_and_mapped) {
    ObjectId a;
    Document d = pathDoc(&a);
    const ObjectId comp = d.project().activeComposition;
    const ObjectId glow = d.addEffect(comp, a, EffectType::Glow);
    d.setPropertyAnimated(comp, a, PropRef::effect(glow, 1), true, 1);
    d.setPropertyValue(comp, a, PropRef::effect(glow, 1), 2, {90, 0, 0, 0});
    const ObjectId b = d.addLayer(comp, LayerKind::Shape);
    // Copy position keys at t=1,2 and the glow radius keys at t=1,2.
    const std::string text = copyKeyframes(d.project(), comp,
                                           {{a, PropRef::layer(PropId::Position), 1}, {a, PropRef::layer(PropId::Position), 2},
                                            {a, PropRef::effect(glow, 1), 0}, {a, PropRef::effect(glow, 1), 1}});
    CHECK(clipboardKind(text) == ClipboardKind::Keyframes);
    std::string err;
    // B has no Glow: position keys paste, the glow track is reported as skipped.
    CHECK(pasteKeyframes(d, comp, {b}, 3.0, text, err) == 2);
    CHECK(err.find("glow") != std::string::npos);
    const Property& bp = d.project().activeComp()->findLayer(b)->prop(PropId::Position);
    CHECK(bp.keyframes.size() == 2);
    CHECK_NEAR(bp.keyframes[0].time, 3.0, 1e-9);  // earliest copied key lands on the playhead
    CHECK_NEAR(bp.keyframes[1].time, 4.0, 1e-9);  // spacing kept
    CHECK_NEAR(bp.keyframes[0].value[0], 500, 1e-9);
    // Once B has a Glow, its radius track pastes too.
    const ObjectId bGlow = d.addEffect(comp, b, EffectType::Glow);
    err.clear();
    CHECK(pasteKeyframes(d, comp, {b}, 0.0, text, err) == 4);
    CHECK(err.empty());
    CHECK(d.project().activeComp()->findLayer(b)->findEffect(bGlow)->params[1].keyframes.size() == 2);
    // The paste was one undo step.
    d.undo();
    CHECK(d.project().activeComp()->findLayer(b)->findEffect(bGlow)->params[1].keyframes.empty());
}

// =============================================================================================
// Phase 4: text, bezier paths, trim paths, graph easing, presets
// =============================================================================================

static Document textDoc(ObjectId* layerOut, const std::string& text, TextAlign align = TextAlign::Center) {
    Document d(makeDefaultProject(1280, 360, 30, 4));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addLayer(comp, LayerKind::Text);
    TextData td;
    td.string = text;
    td.font = "Helvetica-Bold";
    td.align = align;
    d.setLayerText(comp, l, td);
    d.setPropertyValue(comp, l, PropId::FontSize, 0, {100, 0, 0, 0});
    d.setPropertyValue(comp, l, PropId::Position, 0, {640, 220, 0, 0});
    *layerOut = l;
    return d;
}

TEST(text_renders_with_coretext_metrics) {
    ObjectId l;
    Document d = textDoc(&l, "MOTION");
    gpu();  // installs the CoreText measurer
    const Composition& c = *d.project().activeComp();
    Vec2 mn, mx;
    layerLocalBounds(d.project(), *c.findLayer(l), 0, mn, mx);
    CHECK(mx.x - mn.x > 250 && mx.x - mn.x < 500);  // real metrics, not the estimate
    CHECK_NEAR((mn.x + mx.x) / 2, 0, 1);            // centred on the anchor
    const Coverage cov = coverage(render(d.project()));
    CHECK(cov.area > 5000);
    CHECK_NEAR(cov.cx, 640, (mx.x - mn.x) * 0.08);   // ink centred around the position
    CHECK(cov.minY >= 220 - 80 && cov.maxY <= 222);  // caps sit on the baseline at y = 220
    // Changing the text changes the frame; same text, same hash.
    const uint64_t h = evaluateFrame(d.project(), c, 0).hash;
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).hash == h);
    TextData td = c.findLayer(l)->text;
    td.string = "MOTIOM";
    d.setLayerText(d.project().activeComposition, l, td);
    CHECK(evaluateFrame(d.project(), *d.project().activeComp(), 0).hash != h);
}

TEST(text_alignment_and_tracking) {
    gpu();
    auto inkBox = [](const Document& d) { return coverage(render(d.project())); };
    ObjectId a, b, c2;
    Document left = textDoc(&a, "HELLO", TextAlign::Left);
    Document right = textDoc(&b, "HELLO", TextAlign::Right);
    const Coverage cl = inkBox(left), cr = inkBox(right);
    CHECK(cl.minX >= 638 && cl.minX <= 650);  // left-aligned text starts at the anchor
    CHECK(cr.maxX >= 630 && cr.maxX <= 642);  // right-aligned text ends there
    Document tracked = textDoc(&c2, "HELLO", TextAlign::Left);
    tracked.setPropertyValue(tracked.project().activeComposition, c2, PropId::Tracking, 0, {200, 0, 0, 0});
    const Coverage ct = inkBox(tracked);
    // 4 gaps x 200/1000 em x 100 px = 80 px wider.
    CHECK_NEAR((ct.maxX - ct.minX) - (cl.maxX - cl.minX), 80, 3);
}

TEST(text_animator_range_selector) {
    gpu();
    ObjectId l;
    Document d = textDoc(&l, "AAAAAAAAAA", TextAlign::Left);
    const ObjectId comp = d.project().activeComposition;
    d.setPropertyValue(comp, l, PropId::Position, 0, {100, 220, 0, 0});  // all ten characters on screen
    const double full = coverage(render(d.project())).area;
    const ObjectId an = d.addTextAnimator(comp, l, Document::AnimatorPreset::Opacity);  // opacity 0 on the selection
    d.setPropertyValue(comp, l, PropRef::animator(an, AnimParam::End), 0, {50, 0, 0, 0});
    const Coverage half = coverage(render(d.project()));
    CHECK_NEAR(half.area, full / 2, full * 0.03);  // first 5 of 10 characters hidden
    CHECK(half.minX > 100 + 300);                  // what remains is the right half
    // Typewriter: animate Start 0 -> 100 over 1 s; at 0.3 s three characters show.
    d.setPropertyValue(comp, l, PropRef::animator(an, AnimParam::End), 0, {100, 0, 0, 0});
    d.setPropertyAnimated(comp, l, PropRef::animator(an, AnimParam::Start), true, 0);
    d.setPropertyValue(comp, l, PropRef::animator(an, AnimParam::Start), 1, {100, 0, 0, 0});
    CHECK_NEAR(coverage(render(d.project(), 0.3)).area, full * 0.3, full * 0.03);
    // Position animator moves the selected characters (offscreen regions follow them).
    const ObjectId mv = d.addTextAnimator(comp, l, Document::AnimatorPreset::Position);  // (0, 80)
    d.setPropertyValue(comp, l, PropRef::animator(mv, AnimParam::Position), 0, {0, -100, 0, 0});
    d.setTextAnimatorOptions(comp, l, an, false, SelectorShape::Square, SelectorUnit::Characters);
    ObjectId ref;
    Document still = textDoc(&ref, "AAAAAAAAAA", TextAlign::Left);
    still.setPropertyValue(still.project().activeComposition, ref, PropId::Position, 0, {100, 220, 0, 0});
    CHECK_NEAR(coverage(render(d.project())).cy, coverage(render(still.project())).cy - 100, 1.5);
    CHECK(std::abs(selectorWeight(SelectorShape::Triangle, 0, 1, 2, 5) - 1) < 1e-9);  // centre unit fully selected
    CHECK(std::abs(selectorWeight(SelectorShape::RampUp, 0, 0.5, 9, 10) - 1) < 1e-9);  // after the range: selected
    CHECK(std::abs(selectorWeight(SelectorShape::RampDown, 0.5, 1, 0, 10) - 1) < 1e-9);
}

TEST(text_masks_and_effects) {
    gpu();
    ObjectId l;
    Document d = textDoc(&l, "WWWWWW", TextAlign::Center);
    const ObjectId comp = d.project().activeComposition;
    const Coverage full = coverage(render(d.project()));
    const ObjectId m = d.addMask(comp, l, MaskShape::Rectangle);
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Position), 0, {-500, -40, 0, 0});
    d.setPropertyValue(comp, l, PropRef::mask(m, MaskParam::Size), 0, {1000, 400, 0, 0});  // left half only
    const Coverage masked = coverage(render(d.project()));
    CHECK_NEAR(masked.area, full.area / 2, full.area * 0.04);
    CHECK(masked.maxX <= 641);
    d.removeMask(comp, l, m);
    const ObjectId fx = d.addEffect(comp, l, EffectType::GaussianBlur);
    d.setPropertyValue(comp, l, PropRef::effect(fx, 0), 0, {15, 0, 0, 0});
    CHECK_NEAR(coverage(render(d.project())).area, full.area, full.area * 0.02);  // blur keeps the ink
}

static BezierPath polygonPath(std::initializer_list<Vec2> pts, bool closed = true) {
    BezierPath p;
    for (Vec2 v : pts) p.vertices.push_back({v, {0, 0}, {0, 0}});
    p.closed = closed;
    return p;
}

TEST(path_fill_stroke_and_trim) {
    Document d(makeDefaultProject(640, 360, 30, 2));
    const ObjectId comp = d.project().activeComposition;
    // Pen-drawn triangle in comp space: the layer sits at its centre.
    const ObjectId l = d.addPathLayer(comp, {{{220, 280}, {}, {}}, {{420, 280}, {}, {}}, {{320, 80}, {}, {}}}, true);
    const Layer& L = *d.project().activeComp()->findLayer(l);
    CHECK(L.shape == ShapeType::Path && L.fillEnabled && !L.strokeEnabled);
    CHECK_NEAR(L.prop(PropId::Position).value[0], 320, 1e-9);
    CHECK_NEAR(L.prop(PropId::Position).value[1], 180, 1e-9);
    d.setPropertyValue(comp, l, PropId::FillColor, 0, {1, 1, 1, 1});
    CHECK_NEAR(coverage(render(d.project())).area, 0.5 * 200 * 200, 200);

    // Bezier circle (4 vertices, kappa handles) of radius 100.
    const double k = 0.5522847498 * 100;
    BezierPath circle;
    circle.vertices = {{{0, -100}, {-k, 0}, {k, 0}}, {{100, 0}, {0, -k}, {0, k}}, {{0, 100}, {k, 0}, {-k, 0}}, {{-100, 0}, {0, k}, {0, -k}}};
    d.setLayerPath(comp, l, circle);
    CHECK_NEAR(coverage(render(d.project())).area, M_PI * 100 * 100, M_PI * 100 * 100 * 0.01);

    // Open polyline 200 px long, stroked 10 px: rectangle plus two round caps.
    d.setLayerPath(comp, l, polygonPath({{-100, 0}, {100, 0}}, false));
    d.setLayerFillStroke(comp, l, false, true);
    d.setPropertyValue(comp, l, PropId::StrokeWidth, 0, {10, 0, 0, 0});
    const double line = 200 * 10 + M_PI * 25;
    CHECK_NEAR(coverage(render(d.project())).area, line, line * 0.02);
    // Trim Paths: the first half of the line.
    d.setPropertyValue(comp, l, PropId::TrimEnd, 0, {50, 0, 0, 0});
    const Coverage trimmed = coverage(render(d.project()));
    CHECK_NEAR(trimmed.area, 100 * 10 + M_PI * 25, (100 * 10 + M_PI * 25) * 0.03);
    CHECK(trimmed.cx < 320);
    // Closed square outline trimmed to half its perimeter, with the offset wrapping round.
    d.setLayerPath(comp, l, polygonPath({{-50, -50}, {50, -50}, {50, 50}, {-50, 50}}));
    d.setPropertyValue(comp, l, PropId::TrimOffset, 0, {75, 0, 0, 0});
    const double halfSquare = 200 * 10 + M_PI * 25;
    CHECK_NEAR(coverage(render(d.project())).area, halfSquare, halfSquare * 0.06);
}

TEST(bezier_mask_on_layer) {
    ObjectId l;
    Document d = rectDoc(&l);  // 200x100 white
    const ObjectId comp = d.project().activeComposition;
    const ObjectId m = d.addPathMask(comp, l, polygonPath({{-100, 50}, {100, 50}, {0, -50}}));  // triangle in layer space
    CHECK(m != 0);
    CHECK_NEAR(coverage(render(d.project())).area, 0.5 * 200 * 100, 150);
    d.setMaskMode(comp, l, m, MaskMode::Subtract, false);
    CHECK_NEAR(coverage(render(d.project())).area, 20000 - 10000, 150);
}

TEST(graph_editor_speed_and_overshoot) {
    Property p;
    Keyframe a, b;
    a.time = 0;
    a.value = {0, 0, 0, 0};
    a.outInterp = Interp::Bezier;
    b.time = 1;
    b.value = {100, 0, 0, 0};
    b.inInterp = Interp::Bezier;
    p.keyframes = {a, b};
    const PropDef& def = propDef(PropId::Rotation);  // unclamped
    const double eased = evaluateProperty(p, def, 0.25)[0];
    p.keyframes[0].outSlope = 1;  // leave at linear speed instead of from rest
    CHECK(evaluateProperty(p, def, 0.25)[0] > eased + 5);
    p.keyframes[0].outSlope = 0;
    p.keyframes[1].inSlope = -3;  // arrive "from above": overshoot before settling
    double peak = 0;
    for (int i = 0; i <= 100; ++i) peak = std::max(peak, evaluateProperty(p, def, i / 100.0)[0]);
    CHECK(peak > 103);
    CHECK_NEAR(evaluateProperty(p, def, 1.0)[0], 100, 1e-9);

    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setPropertyAnimated(comp, l, PropId::Rotation, true, 0);
    d.setPropertyValue(comp, l, PropId::Rotation, 1, {90, 0, 0, 0});
    CHECK(d.setKeyframeEase(comp, l, PropRef::layer(PropId::Rotation), 0, true, 0.6, 0.5));
    const Keyframe& k0 = d.project().activeComp()->findLayer(l)->prop(PropId::Rotation).keyframes[0];
    CHECK(k0.outInterp == Interp::Bezier && std::abs(k0.easeOut - 0.6) < 1e-12 && std::abs(k0.outSlope - 0.5) < 1e-12);
    Json kj;
    std::string err;
    CHECK(Json::parse(keyframeToJson(k0, propDef(PropId::Rotation)).dump(), kj, err));
    CHECK(keyframeFromJson(kj, {}) == k0);
}

TEST(presets_builtin_and_round_trip) {
    CHECK(builtInPresets().size() >= 12);
    const PresetInfo* fade = nullptr;
    const PresetInfo* slide = nullptr;
    const PresetInfo* typewriter = nullptr;
    for (const PresetInfo& p : builtInPresets()) {
        if (p.name == "Fade In") fade = &p;
        if (p.name == "Slide Up") slide = &p;
        if (p.name == "Typewriter") typewriter = &p;
    }
    CHECK(fade && slide && typewriter);
    if (!fade || !slide || !typewriter) return;
    ObjectId l;
    Document d = rectDoc(&l);
    const ObjectId comp = d.project().activeComposition;
    d.setPropertyValue(comp, l, PropId::Position, 0, {300, 200, 0, 0});
    std::string err;
    CHECK(applyPreset(d, comp, {l}, 2.0, fade->json, err) == 2);
    const auto& op = d.project().activeComp()->findLayer(l)->prop(PropId::Opacity).keyframes;
    CHECK(op.size() == 2 && std::abs(op[0].time - 2.0) < 1e-9 && std::abs(op[1].time - 2.5) < 1e-9);
    CHECK(op.size() == 2 && op[0].value[0] == 0 && op[1].value[0] == 100);
    // Slide Up ends where the layer already is (offsets, not absolute positions).
    applyPreset(d, comp, {l}, 0.0, slide->json, err);
    const auto& pos = d.project().activeComp()->findLayer(l)->prop(PropId::Position).keyframes;
    CHECK(pos.size() == 2);
    if (pos.size() == 2) {
        CHECK_NEAR(pos[0].value[1], 320, 1e-6);
        CHECK_NEAR(pos[1].value[1], 200, 1e-6);
        CHECK_NEAR(pos[1].value[0], 300, 1e-6);
    }
    // Text presets need a text layer; on a shape they're reported, not half-applied.
    err.clear();
    applyPreset(d, comp, {l}, 0.0, typewriter->json, err);
    CHECK(err.find("text") != std::string::npos);
    ObjectId t;
    Document td = textDoc(&t, "HELLO");
    err.clear();
    CHECK(applyPreset(td, td.project().activeComposition, {t}, 1.0, typewriter->json, err) > 0);
    const Layer& T = *td.project().activeComp()->findLayer(t);
    CHECK(T.animators.size() == 1 && T.animators[0].param(AnimParam::Start).keyframes.size() == 2);
    // A user preset made from a layer with a glow re-creates the effect and its keys elsewhere.
    const ObjectId glow = d.addEffect(comp, l, EffectType::Glow);
    d.setPropertyAnimated(comp, l, PropRef::effect(glow, 2), true, 1);
    d.setPropertyValue(comp, l, PropRef::effect(glow, 2), 2, {200, 0, 0, 0});
    const std::string mine = makePreset(d.project(), comp, l, "Mine", "My Presets");
    std::string name, cat;
    CHECK(presetHeader(mine, name, cat) && name == "Mine" && cat == "My Presets");
    const ObjectId other = d.addLayer(comp, LayerKind::Shape, ShapeType::Ellipse);
    CHECK(applyPreset(d, comp, {other}, 5.0, mine, err) > 0);
    const Layer& O = *d.project().activeComp()->findLayer(other);
    CHECK(O.effects.size() == 1 && O.effects[0].type == EffectType::Glow);
    CHECK(!O.effects.empty() && O.effects[0].params[2].keyframes.size() == 2);
}

TEST(project_file_v4_text_paths) {
    Document d(makeDefaultProject(1920, 1080, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId t = d.addLayer(comp, LayerKind::Text);
    TextData td;
    td.string = "Line one\nLine \"two\" ✓";
    td.font = "Georgia-Bold";
    td.align = TextAlign::Right;
    d.setLayerText(comp, t, td);
    const ObjectId an = d.addTextAnimator(comp, t, Document::AnimatorPreset::Rotation);
    d.setTextAnimatorOptions(comp, t, an, true, SelectorShape::Smooth, SelectorUnit::Words);
    d.setPropertyAnimated(comp, t, PropRef::animator(an, AnimParam::Offset), true, 0);
    d.setPropertyValue(comp, t, PropRef::animator(an, AnimParam::Offset), 1, {50, 0, 0, 0});
    const ObjectId p = d.addPathLayer(comp, {{{0, 0}, {}, {30, 0}}, {{100, 50}, {-20, 0}, {}}}, false);
    d.addPathMask(comp, t, polygonPath({{0, 0}, {10, 0}, {0, 10}}));
    d.setPropertyAnimated(comp, p, PropId::TrimEnd, true, 0);
    d.setPropertyValue(comp, p, PropId::TrimEnd, 1, {40, 0, 0, 0});
    d.setKeyframeEase(comp, p, PropRef::layer(PropId::TrimEnd), 0, true, 0.7, 1.5);
    Project back;
    std::string err;
    CHECK(deserializeProject(serializeProject(d.project(), ""), "", back, err));
    CHECK(back == d.project());
}

// ---- Phase 5 prerequisites: precomps, baked tracks (imported projects) ------------------------

// A 400x200 child comp with one opaque rectangle covering [x0, x1] x [y0, y1] (child pixels).
static ObjectId childCompWithRect(Document& d, double x0, double y0, double x1, double y1, Value color) {
    const ObjectId child = d.addComposition("Child", 400, 200, 30, 5);
    const ObjectId r = d.addLayer(child, LayerKind::Shape, ShapeType::Rectangle);
    d.setPropertyValue(child, r, PropId::ShapeSize, 0, {x1 - x0, y1 - y0, 0, 0});
    d.setPropertyValue(child, r, PropId::Position, 0, {(x0 + x1) * 0.5, (y0 + y1) * 0.5, 0, 0});
    d.setPropertyValue(child, r, PropId::FillColor, 0, color);
    return child;
}

TEST(precomp_layer_transforms_and_clips) {
    Document d(makeDefaultProject(800, 400, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    // The rectangle sticks out of the child's frame on the right (x 300..500 of a 400 wide comp).
    const ObjectId child = childCompWithRect(d, 300, 50, 500, 150, {1, 0, 0, 1});
    const ObjectId pl = d.addPrecompLayer(comp, child);
    CHECK(pl != 0);
    CHECK(d.addPrecompLayer(child, comp) == 0);   // would contain itself
    CHECK(d.addPrecompLayer(child, child) == 0);
    // Child top-left at (100, 100) of the parent: anchor (200, 100) at position (300, 200).
    d.setPropertyValue(comp, pl, PropId::Position, 0, {300, 200, 0, 0});
    Image img = render(d.project());
    CHECK(img.at(450, 150)[0] > 0.99);   // child (350, 50) inside the rect
    CHECK(img.a(520, 150) < 0.01);       // child (420, 50): outside the child's frame -> clipped
    CHECK(img.a(380, 150) < 0.01);       // child (280, 50): left of the rect
    // Collapsed: drawn straight into the parent, so nothing is clipped.
    d.setPrecompOptions(comp, pl, true, false, 0);
    img = render(d.project());
    CHECK(img.at(520, 150)[0] > 0.99);
    // Scaled 50% about the anchor: child (350, 100) -> parent (300 + 150*0.5, 200).
    d.setPropertyValue(comp, pl, PropId::Scale, 0, {50, 50, 0, 0});
    img = render(d.project());
    CHECK(img.at(376, 200)[0] > 0.99);
    CHECK(img.a(340, 200) < 0.01);  // child x 280
    // Hit-testing goes into the precomp: only where its rectangle is (child x 300..500 at 50%).
    CHECK(hitTest(d.project(), *d.project().activeComp(), 0, {380, 200}) == pl);   // child (360, 100)
    CHECK(hitTest(d.project(), *d.project().activeComp(), 0, {300, 200}) == 0);    // child (200, 100): empty
}

TEST(precomp_group_opacity_and_time) {
    Document d(makeDefaultProject(800, 400, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId child = childCompWithRect(d, 0, 0, 200, 200, {0, 0, 1, 1});
    // A second, overlapping rectangle: the group at 50% must not show the overlap darker.
    const ObjectId r2 = d.addLayer(child, LayerKind::Shape, ShapeType::Rectangle);
    d.setPropertyValue(child, r2, PropId::ShapeSize, 0, {200, 200, 0, 0});
    d.setPropertyValue(child, r2, PropId::Position, 0, {200, 100, 0, 0});
    d.setPropertyValue(child, r2, PropId::FillColor, 0, {0, 0, 1, 1});
    const ObjectId pl = d.addPrecompLayer(comp, child);
    d.setPropertyValue(comp, pl, PropId::Position, 0, {200, 100, 0, 0});  // child top-left at (0, 0)
    d.setPropertyValue(comp, pl, PropId::Opacity, 0, {50, 0, 0, 0});
    Image img = render(d.project());
    CHECK_NEAR(img.a(50, 100), 0.5, 0.01);   // one rectangle
    CHECK_NEAR(img.a(150, 100), 0.5, 0.01);  // overlap: still one group at 50%
    // Source time: the child's rectangle moves; the layer starts 1 s late, then is remapped.
    d.setPropertyAnimated(child, r2, PropId::Position, true, 0);
    d.setPropertyValue(child, r2, PropId::Position, 1, {200, 300, 0, 0});  // gone below by child t=1
    d.setPrecompOptions(comp, pl, false, false, 1.0);
    const Composition& c = *d.project().activeComp();
    FrameDesc f = evaluateFrame(d.project(), c, 1.0);  // child time 0
    CHECK(f.items.size() == 1 && f.items[0].nested && f.items[0].nested->time == 0);
    CHECK(f.items[0].nested->items.size() == 2);
    d.setPrecompOptions(comp, pl, false, true, 1.0);   // remap: identity over the layer -> in - start
    f = evaluateFrame(d.project(), c, 2.0);
    CHECK_NEAR(f.items[0].nested->time, 1.0, 1e-9);
    // Hashes follow the child: an edit inside it changes the parent frame's hash.
    const uint64_t h0 = evaluateFrame(d.project(), c, 2.0).hash;
    d.setPropertyValue(child, r2, PropId::FillColor, 0, {0, 1, 0, 1});
    CHECK(evaluateFrame(d.project(), c, 2.0).hash != h0);
}

TEST(switching_compositions_is_not_an_edit) {
    Document d(makeDefaultProject(800, 400, 30, 5));
    const ObjectId main = d.project().activeComposition;
    const ObjectId other = d.addComposition("Other", 400, 200, 30, 5);
    d.markSaved();
    const uint64_t rev = d.revision();
    const size_t undo = d.undoDepth();
    CHECK(d.setActiveComposition(other));
    CHECK(d.revision() > rev);       // views refresh
    CHECK(!d.dirty());               // but the saved document stays saved
    CHECK(d.undoDepth() == undo);    // and there is nothing to undo
    CHECK(!d.setActiveComposition(other));
    d.addLayer(other, LayerKind::Shape);
    CHECK(d.dirty());
    CHECK(d.setActiveComposition(main));
    CHECK(d.dirty());                // unsaved edits stay unsaved
}

TEST(baked_tracks_evaluate_edit_and_save) {
    Document d(makeDefaultProject(800, 400, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addLayer(comp, LayerKind::Shape, ShapeType::Ellipse);
    SampledTrack t;
    t.t0 = 1;
    t.rate = 10;
    t.dims = 2;
    t.data = {0, 0, 10, 20, 30, 40};  // t = 1.0, 1.1, 1.2
    Project p = d.project();
    p.activeComp()->findLayer(l)->prop(PropId::Position).samples = Shared<SampledTrack>(t);
    d.replaceProject(p);
    const Layer& L = *d.project().activeComp()->findLayer(l);
    auto pos = [&](double tt) { return evaluateProperty(d.project().activeComp()->findLayer(l)->prop(PropId::Position), PropId::Position, tt); };
    CHECK_NEAR(pos(0)[0], 0, 1e-9);        // holds before
    CHECK_NEAR(pos(1.05)[1], 10, 1e-5);    // interpolates
    CHECK_NEAR(pos(1.2)[0], 30, 1e-5);
    CHECK_NEAR(pos(9)[1], 40, 1e-5);       // holds after
    CHECK(L.prop(PropId::Position).baked());
    // Editing shifts the whole track; undo restores it.
    CHECK(d.setPropertyValue(comp, l, PropId::Position, 1.1, {110, 120, 0, 0}));
    CHECK_NEAR(pos(1.2)[0], 130, 1e-4);
    CHECK(d.undo());
    CHECK_NEAR(pos(1.2)[0], 30, 1e-5);
    // Save / load keeps the samples exactly (float32).
    Project back;
    std::string err;
    CHECK(deserializeProject(serializeProject(d.project(), ""), "", back, err));
    CHECK(back == d.project());
    // Turning the stopwatch on replaces the bake with a key at the current value.
    CHECK(d.setPropertyAnimated(comp, l, PropId::Position, true, 1.1));
    CHECK(!d.project().activeComp()->findLayer(l)->prop(PropId::Position).baked());
    CHECK_NEAR(pos(3)[1], 20, 1e-4);
    // Snapshots share baked data, so a big bake costs undo almost nothing.
    CHECK(approxSnapshotBytes(d.project()) < 64 * 1024);
}

TEST(path_tracks_and_compound_text) {
    BezierPath a = polygonPath({{0, 0}, {100, 0}, {100, 100}});
    BezierPath b = polygonPath({{0, 0}, {200, 0}, {200, 200}});
    PathTrack tr;
    tr.t0 = 0;
    tr.rate = 1;
    tr.frames = {a, b, polygonPath({{0, 0}, {5, 5}})};  // topology change at frame 2
    CHECK_NEAR(tr.at(0.5).vertices[1].p.x, 150, 1e-9);
    CHECK_NEAR(tr.at(1.5).vertices[2].p.y, 200, 1e-9);  // different vertex count: holds frame 1
    CHECK(tr.at(5).vertices.size() == 2);
    Document d(makeDefaultProject(400, 400, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addPathLayer(comp, {{{0, 0}, {}, {}}, {{50, 0}, {}, {}}, {{50, 50}, {}, {}}}, true);
    Project p = d.project();
    Layer& L = *p.activeComp()->findLayer(l);
    L.pathTrack = Shared<PathTrack>(tr);
    const ObjectId m = d.addMask(comp, l, MaskShape::Path);
    (void)m;
    d.replaceProject(p);
    Vec2 mn, mx;
    layerLocalBounds(d.project(), *d.project().activeComp()->findLayer(l), 1.0, mn, mx);
    CHECK_NEAR(mx.x, 200, 1e-9);
    Project back;
    std::string err;
    CHECK(deserializeProject(serializeProject(d.project(), ""), "", back, err));
    CHECK(back == d.project());
    CHECK(textUnitCount("GO\xE2\x80\x82SLOWLY", SelectorUnit::Characters) == 9);
    CHECK(textUnitCount("GO\xE2\x80\x82SLOWLY", SelectorUnit::Words) == 2);
    CHECK(textUnitCount("a b\nc", SelectorUnit::Lines) == 2);
}

TEST(render_text_stroke_and_stagger) {
    Document d(makeDefaultProject(800, 300, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId t = d.addLayer(comp, LayerKind::Text);
    TextData td;
    td.string = "IIII";
    td.font = "Helvetica-Bold";
    d.setLayerText(comp, t, td);
    d.setPropertyValue(comp, t, PropId::FontSize, 0, {200, 0, 0, 0});
    d.setPropertyValue(comp, t, PropId::FillColor, 0, {1, 0, 0, 1});
    d.setPropertyValue(comp, t, PropId::Position, 0, {400, 220, 0, 0});
    const Coverage plain = coverage(render(d.project()));
    d.setLayerFillStroke(comp, t, true, true);
    d.setPropertyValue(comp, t, PropId::StrokeColor, 0, {1, 1, 1, 1});
    d.setPropertyValue(comp, t, PropId::StrokeWidth, 0, {16, 0, 0, 0});
    Image img = render(d.project());
    const Coverage stroked = coverage(img);
    CHECK(stroked.area > plain.area * 1.2);           // the stroke adds an outline
    CHECK(stroked.minY <= plain.minY - 6);            // half the width (8 px) outside the glyphs
    // Fill over stroke (default): glyph interiors stay red; the rim is white.
    int red = 0, white = 0;
    for (int y = 0; y < img.h; ++y)
        for (int x = 0; x < img.w; ++x) {
            const float* c = img.at(x, y);
            if (c[3] > 0.99 && c[0] > 0.99 && c[1] < 0.01) ++red;
            if (c[3] > 0.99 && c[1] > 0.99) ++white;
        }
    CHECK(red > 1000 && white > 500);
    // Stagger: one Amount curve cascades over the characters.
    d.setLayerFillStroke(comp, t, true, false);
    const ObjectId an = d.addTextAnimator(comp, t, Document::AnimatorPreset::Opacity);  // opacity 0 at 100%
    d.setPropertyAnimated(comp, t, PropRef::animator(an, AnimParam::Amount), true, 0);
    d.setPropertyValue(comp, t, PropRef::animator(an, AnimParam::Amount), 1, {0, 0, 0, 0});
    d.setPropertyValue(comp, t, PropRef::animator(an, AnimParam::Amount), 0, {100, 0, 0, 0});
    Project p = d.project();
    p.activeComp()->findLayer(t)->animators[0].stagger = 1.0;
    d.replaceProject(p);
    const FrameDesc f = evaluateFrame(d.project(), *d.project().activeComp(), 1.0);
    CHECK(f.animators.size() == 1 && f.animators[0].unitAmounts.size() == 4);
    if (f.animators.size() == 1 && f.animators[0].unitAmounts.size() == 4) {
        CHECK_NEAR(f.animators[0].unitAmounts[0], 0, 1e-6);  // char 0 at t=1: done
        CHECK_NEAR(f.animators[0].unitAmounts[1], 1, 1e-6);  // char 1 sees t=0: hidden
    }
    const Coverage half = coverage(render(d.project(), 1.0));
    CHECK(half.area < plain.area * 0.4 && half.area > plain.area * 0.1);  // one of four bars
}

// Fonts without the fixed-width Unicode spaces (Baloo 2 has no U+2002) still give them their
// standard width, as After Effects does, instead of whatever the fallback font uses.
TEST(text_fixed_width_spaces_use_unicode_widths) {
    CTFontRef f = CTFontCreateWithName(CFSTR("Baloo2-ExtraBold"), 100, nullptr);
    CFStringRef ps = CTFontCopyPostScriptName(f);
    const bool have = ps && CFStringCompare(ps, CFSTR("Baloo2-ExtraBold"), 0) == kCFCompareEqualTo;
    if (ps) CFRelease(ps);
    CFRelease(f);
    if (!have) {
        std::printf("    (Baloo 2 not installed: skipped)\n");
        return;
    }
    auto width = [](const char* s) {
        TextStyle st;
        st.text = s;
        st.font = "Baloo2-ExtraBold";
        st.size = 100;
        st.align = TextAlign::Left;
        auto lay = layoutText(st);
        return lay->mx.x - lay->mn.x;
    };
    CHECK_NEAR(width("GO\xE2\x80\x82SLOWLY") - width("GOSLOWLY"), 50, 0.5);    // en space: 0.5 em
    CHECK_NEAR(width("GO\xE2\x80\x83SLOWLY") - width("GOSLOWLY"), 100, 0.5);   // em space
    CHECK(width("GO SLOWLY") - width("GOSLOWLY") < 40);                         // the font's own space
}

TEST(render_gradient_ramp_keeps_alpha) {
    Document d(makeDefaultProject(400, 400, 30, 5));
    const ObjectId comp = d.project().activeComposition;
    const ObjectId l = d.addLayer(comp, LayerKind::Shape, ShapeType::Ellipse);
    d.setPropertyValue(comp, l, PropId::ShapeSize, 0, {300, 300, 0, 0});
    const ObjectId fx = d.addEffect(comp, l, EffectType::GradientRamp);
    // Layer space is centred on the ellipse: top -> red, bottom -> blue.
    d.setPropertyValue(comp, l, PropRef::effect(fx, 0), 0, {0, -150, 0, 0});
    d.setPropertyValue(comp, l, PropRef::effect(fx, 1), 0, {1, 0, 0, 1});
    d.setPropertyValue(comp, l, PropRef::effect(fx, 2), 0, {0, 150, 0, 0});
    d.setPropertyValue(comp, l, PropRef::effect(fx, 3), 0, {0, 0, 1, 1});
    const Image img = render(d.project());
    CHECK(img.at(200, 60)[0] > 0.9 && img.at(200, 60)[2] < 0.1);
    CHECK(img.at(200, 340)[2] > 0.9 && img.at(200, 340)[0] < 0.1);
    CHECK_NEAR(img.at(200, 200)[0], 0.5, 0.02);
    CHECK(img.a(10, 10) < 0.01);  // outside the ellipse: still transparent
}

TEST(motion_blur_per_layer_and_through_precomps) {
    Project p = makeDefaultProject(400, 200, 30, 2);
    Composition& c = *p.activeComp();
    c.motionBlur = true;  // 180 degree shutter, phase -90, 8 samples
    Layer mover = makeLayer(LayerKind::Shape, c, p.allocateId());
    mover.prop(PropId::ShapeSize).value = {20, 20, 0, 0};
    Keyframe a, b;
    a.time = 0;
    a.value = {0, 100, 0, 0};
    b.time = 2;
    b.value = {600, 100, 0, 0};  // 10 px per frame
    mover.prop(PropId::Position).keyframes = {a, b};
    Layer still = mover;
    still.id = p.allocateId();
    mover.motionBlur = true;
    c.layers = {mover, still};
    const auto offs = motionBlurOffsets(p, c);
    CHECK(offs.size() == 8);
    CHECK_NEAR(offs.front(), (-90 + 180 * 0.5 / 8) / 360.0 / 30, 1e-12);
    CHECK_NEAR(offs.back(), (-90 + 180 * 7.5 / 8) / 360.0 / 30, 1e-12);
    const FrameDesc f0 = evaluateFrame(p, c, 1.0, 1, nullptr, offs.front());
    const FrameDesc f1 = evaluateFrame(p, c, 1.0, 1, nullptr, offs.back());
    // Items are bottom-to-top: [still, mover]. The mover spans ~4.4 px across the shutter.
    CHECK_NEAR(f1.items[1].toTarget.tx - f0.items[1].toTarget.tx, 600.0 / 2 * (180.0 * 7 / 8 / 360) / 30, 1e-6);
    CHECK_NEAR(f1.items[0].toTarget.tx, f0.items[0].toTarget.tx, 1e-9);
    // A precomp holding one source frame (time remap) does not blur its contents.
    Composition src;
    src.id = p.allocateId();
    src.width = 400;
    src.height = 200;
    src.duration = 2;
    Layer m2 = mover;
    m2.id = p.allocateId();
    src.layers = {m2};
    p.compositions.push_back(src);
    Composition& c2 = *p.activeComp();
    Layer pl = makePrecompLayer(c2, src, p.allocateId());
    pl.timeRemap = true;
    pl.prop(PropId::TimeRemap).value = {0.5, 0, 0, 0};
    pl.collapse = true;
    pl.motionBlur = true;
    c2.layers = {pl};
    const FrameDesc g0 = evaluateFrame(p, c2, 1.0, 1, nullptr, offs.front());
    const FrameDesc g1 = evaluateFrame(p, c2, 1.0, 1, nullptr, offs.back());
    CHECK(g0.items.size() == 1 && g1.items.size() == 1);
    if (g0.items.size() == 1 && g1.items.size() == 1) CHECK_NEAR(g0.items[0].toTarget.tx, g1.items[0].toTarget.tx, 1e-9);
    Project back;
    std::string err;
    CHECK(deserializeProject(serializeProject(p, ""), "", back, err));
    CHECK(back == p);
}

// The exact path the app uses: Objective-C bridge -> document -> renderer -> PNG.
TEST(render_engine_bridge_png) {
    NSError* error = nil;
    MFEngine* e = [[MFEngine alloc] initWithDevice:nil error:&error];
    CHECK(e != nil);
    if (!e) return;
    [e newProjectWithWidth:640 height:360 fps:30 duration:2];
    const uint64_t l = [e addShapeLayer:MFShapeTypeRectangle];
    [e setPropertyValue:MFValue{200, 100, 0, 0} prop:MFPropSize layer:l time:0];
    [e setPropertyValue:MFValue{1, 1, 1, 1} prop:MFPropFillColor layer:l time:0];
    [e setPropertyValue:MFValue{100, 80, 0, 0} prop:MFPropPosition layer:l time:0];
    CGImageRef img = [e copyImageAtTime:0 scale:1 transparent:YES error:&error];
    CHECK(img != nullptr);
    if (img) {
        CHECK(CGImageGetWidth(img) == 640 && CGImageGetHeight(img) == 360);
        CGImageRelease(img);
    }
    const std::string out = (fs::path(tempDir("png")) / "bridge.png").string();
    CHECK([e writePNGAtTime:0 scale:1 transparent:NO toPath:@(out.c_str()) error:&error]);
    CHECK(fs::exists(out) && fs::file_size(out) > 100);
    MFQuad q = [e quadForLayer:l time:0];
    CHECK_NEAR(q.topLeft.x, 0, 1e-9);
    CHECK_NEAR(q.topLeft.y, 30, 1e-9);
    CHECK([e hitTestAtPoint:CGPointMake(100, 80) time:0] == l);
    CHECK([e hitTestAtPoint:CGPointMake(400, 300) time:0] == 0);
    CHECK([e undo]);
    MFValue p = [e valueOf:MFPropPosition layer:l time:0];
    CHECK_NEAR(p.x, 320, 0);
}

// ---- audio ----------------------------------------------------------------------------------

static Asset audioAsset(Project& p, const std::string& path, double duration) {
    Asset a;
    a.id = p.allocateId();
    a.kind = AssetKind::Audio;
    a.name = fs::path(path).filename().string();
    a.path = path;
    a.duration = duration;
    p.assets.push_back(a);
    return a;
}

TEST(audio_clips_through_precomps_trims_and_levels) {
    Project p = makeDefaultProject(640, 360, 30, 20);
    const Asset a = audioAsset(p, "/tmp/mf-voice.wav", 10);
    Composition src;
    src.id = p.allocateId();
    src.duration = 5;
    Layer inner = makeLayer(LayerKind::Audio, src, p.allocateId(), &a);
    CHECK(inner.outPoint == 10 && inner.asset == a.id);
    src.layers = {inner};
    p.compositions.push_back(src);
    Composition& c = *p.activeComp();
    Layer top = makeLayer(LayerKind::Audio, c, p.allocateId(), &a);
    top.startTime = 1;
    top.inPoint = 2;
    top.outPoint = 8;
    top.prop(PropId::AudioLevel).value = {-6, 0, 0, 0};
    Layer muted = top;
    muted.id = p.allocateId();
    muted.visible = false;
    Layer pre = makePrecompLayer(c, src, p.allocateId());
    pre.startTime = 3;
    pre.inPoint = 4;
    pre.outPoint = 20;
    c.layers = {top, muted, pre};

    auto clips = collectAudio(p, c.id);
    CHECK(clips.size() == 2);
    if (clips.size() == 2) {
        // Sorted by start: the top layer plays from 2 s (1 s into the file) for 6 s.
        CHECK_NEAR(clips[0].start, 2, 1e-9);
        CHECK_NEAR(clips[0].sourceStart, 1, 1e-9);
        CHECK_NEAR(clips[0].duration, 6, 1e-9);
        CHECK(clips[0].gain.size() == 1);
        CHECK_NEAR(clips[0].gain[0].second, std::pow(10.0, -6 / 20.0), 1e-9);
        // The nested layer is heard only while the precomp shows its source: [4, 8) on top.
        CHECK(clips[1].layer == inner.id);
        CHECK_NEAR(clips[1].start, 4, 1e-9);
        CHECK_NEAR(clips[1].sourceStart, 1, 1e-9);
        CHECK_NEAR(clips[1].duration, 4, 1e-9);
    }
    // A window cuts clips; time-remapped precomps are not followed.
    clips = collectAudio(p, c.id, 5, 6);
    CHECK(clips.size() == 2);
    if (!clips.empty()) {
        CHECK_NEAR(clips[0].start, 5, 1e-9);
        CHECK_NEAR(clips[0].sourceStart, 4, 1e-9);
        CHECK_NEAR(clips[0].duration, 1, 1e-9);
    }
    c.layers[2].timeRemap = true;
    CHECK(collectAudio(p, c.id).size() == 1);

    // An animated level becomes gain breakpoints; the bottom of the range is silence.
    Keyframe k0, k1;
    k0.time = 2;
    k0.value = {0, 0, 0, 0};
    k1.time = 4;
    k1.value = {-48, 0, 0, 0};
    c.layers[0].prop(PropId::AudioLevel).keyframes = {k0, k1};
    clips = collectAudio(p, c.id);
    CHECK(!clips.empty() && clips[0].gain.size() > 10);
    if (!clips.empty() && clips[0].gain.size() > 10) {
        CHECK_NEAR(clips[0].gain.front().second, 1, 1e-9);
        CHECK_NEAR(clips[0].gain.back().first, 8, 1e-9);
        CHECK(clips[0].gain.back().second == 0);
        for (size_t i = 1; i < clips[0].gain.size(); ++i) CHECK(clips[0].gain[i].second <= clips[0].gain[i - 1].second + 1e-12);
    }
    CHECK(audioLevelGain(-48) == 0 && audioLevelGain(0) == 1);

    // Audio layers draw nothing and can't be clicked.
    CHECK(evaluateFrame(p, c, 3).items.empty());
    CHECK(hitTest(p, c, 3, {320, 180}) == 0);

    Project back;
    std::string err;
    CHECK(deserializeProject(serializeProject(p, ""), "", back, err));
    back.assets[0].missing = false;  // the file doesn't exist here
    CHECK(back == p);
}

// A 1 s 440 Hz tone, written as a WAV file.
static std::string writeTone(const char* name, double seconds) {
    const std::string path = (fs::path(tempDir("audio")) / name).string();
    AVAudioFormat* fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    NSError* e = nil;
    AVAudioFile* f = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:@(path.c_str())]
                                                settings:@{AVFormatIDKey : @(kAudioFormatLinearPCM), AVSampleRateKey : @48000,
                                                           AVNumberOfChannelsKey : @2, AVLinearPCMBitDepthKey : @16}
                                                   error:&e];
    const AVAudioFrameCount n = AVAudioFrameCount(seconds * 48000);
    AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:n];
    buf.frameLength = n;
    for (AVAudioFrameCount i = 0; i < n; ++i)
        buf.floatChannelData[0][i] = buf.floatChannelData[1][i] = float(0.5 * std::sin(2 * M_PI * 440 * i / 48000.0));
    [f writeFromBuffer:buf error:&e];
    return path;
}

static double audioSeconds(const std::string& movie) {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(movie.c_str())] options:nil];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    __block CMTimeRange range = kCMTimeRangeZero;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack*>* t, NSError*) {
        tracks = t;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (tracks.count == 0) return 0;
    [tracks[0] loadValuesAsynchronouslyForKeys:@[ @"timeRange" ] completionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    range = tracks[0].timeRange;
    return CMTimeGetSeconds(range.duration);
}

TEST(audio_import_mix_and_export_bridge) {
    NSError* error = nil;
    MFEngine* e = [[MFEngine alloc] initWithDevice:nil error:&error];
    CHECK(e != nil);
    if (!e) return;
    [e newProjectWithWidth:320 height:180 fps:30 duration:2];
    const std::string tone = writeTone("tone.wav", 1);
    NSNumber* aid = [e importAudioAtPath:@(tone.c_str()) error:&error];
    CHECK(aid != nil);
    if (!aid) return;
    MFAssetInfo* info = [e assets].firstObject;
    CHECK(info.isAudio && info.loaded);
    CHECK_NEAR(info.duration, 1, 1e-6);
    CHECK([e importImageAtPath:@(tone.c_str()) error:nil] == nil);  // not an image
    const uint64_t l = [e addAudioLayerWithAsset:aid.unsignedLongLongValue];
    CHECK(l != 0);
    CHECK([e addImageLayerWithAsset:aid.unsignedLongLongValue] == 0);
    MFLayerInfo* layer = [e layerWithID:l];
    CHECK(layer.kind == MFLayerKindAudio);
    CHECK_NEAR(layer.outPoint, 1, 1e-6);
    CHECK([e setLayer:l startTime:0.5]);
    CHECK([e setLayer:l inPoint:0.5 outPoint:1.5]);
    NSArray<MFAudioClipInfo*>* clips = [e audioClips];
    CHECK(clips.count == 1);
    if (clips.count == 1) {
        CHECK_NEAR(clips[0].start, 0.5, 1e-9);
        CHECK_NEAR(clips[0].duration, 1, 1e-9);
    }
    MFAudioMix* mix = [MFAudioMix mixWithClips:clips origin:0 error:&error];
    CHECK(mix != nil && mix.composition.tracks.count == 1);
    if (mix) CHECK_NEAR(CMTimeGetSeconds(mix.composition.duration), 1.5, 1e-3);

    // Export: the movie carries the mixed audio for the composition's whole length.
    MFExportSettings* s = [MFExportSettings new];
    s.scale = 0.5;
    const std::string out = (fs::path(tempDir("audio")) / "with-audio.mp4").string();
    MFVideoExporter* x = [[MFVideoExporter alloc] initWithEngine:e settings:s outputPath:@(out.c_str()) error:&error];
    CHECK(x != nil);
    if (!x) return;
    __block bool finished = false;
    __block NSError* failure = nil;
    [x startWithProgress:^(MFExportProgress*) {} completion:^(NSError* err) {
        failure = err;
        finished = true;
    }];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while (!finished && [deadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(finished && failure == nil);
    if (failure) std::printf("    export: %s\n", failure.localizedDescription.UTF8String);
    const double secs = audioSeconds(out);
    CHECK(secs > 1.4 && secs < 2.1);  // silence before 0.5 s, the tone, silence to the end (AAC padding)
}

// ---------------------------------------------------------------------------------------------

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* filter = argc > 1 ? argv[1] : nullptr;
        int ran = 0;
        const auto t0 = std::chrono::steady_clock::now();
        for (const Test& t : registry()) {
            if (filter && !std::strstr(t.name, filter)) continue;
            gCurrent = t.name;
            const int before = gFailures;
            @autoreleasepool {
                t.fn();
            }
            std::printf("  %s  %s\n", gFailures == before ? "ok  " : "FAIL", t.name);
            ++ran;
        }
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::printf("\n%d tests, %d checks, %d failures (%.0f ms) on %s\n", ran, gChecks, gFailures, ms,
                    gpu().device().name.UTF8String);
        fs::remove_all(fs::path(NSTemporaryDirectory().fileSystemRepresentation) / ("mftests-" + std::to_string(getpid())));
        return gFailures == 0 ? 0 : 1;
    }
}
