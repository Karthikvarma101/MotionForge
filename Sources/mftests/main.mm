// MotionForge test runner: core model + evaluation + project IO + undo + cache policy, and GPU
// render-correctness checks that read back real Metal output.
//
//   swift run -c release mftests            # all tests
//   swift run -c release mftests render     # only tests whose name contains "render"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

#include "MFEngine.h"
#include "MFRender/MetalRenderer.hpp"
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
    CHECK(text.find("\"version\": 2") != std::string::npos);
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
