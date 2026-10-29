// MotionForge core — evaluates a composition at a time into a flat, renderer-ready draw list.
//
// The draw list is the contract between the CPU (timeline evaluation) and the GPU (Metal
// renderer). Its 64-bit content hash is the frame-cache key, which gives dependency-based cache
// invalidation for free: an edit only invalidates the frames whose evaluated result changed.
#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <optional>
#include <vector>

#include "mf/Math.hpp"
#include "mf/Model.hpp"

namespace mf {

// Text metrics come from the platform layer (CoreText in the renderer). Until one is installed a
// rough estimate is used, so the core stays testable without a font system.
struct TextStyle {
    std::string text, font;
    double size = 100, tracking = 0, lineHeight = 1.2;
    TextAlign align = TextAlign::Center;
};
// Selector units in `text` as the text engine counts them (characters are UTF-16 units without
// line breaks; words start at a non-space after a space or line start).
int textUnitCount(const std::string& text, SelectorUnit unit);
using TextMeasurer = std::function<void(const TextStyle&, Vec2& mn, Vec2& mx)>;
void setTextMeasurer(TextMeasurer m);
// Layout box of the text in layer space: x = 0 is the alignment point, y = 0 the first baseline.
void measureText(const TextStyle& style, Vec2& mn, Vec2& mx);

struct AnimatorEval {
    SelectorShape shape = SelectorShape::Square;
    SelectorUnit unit = SelectorUnit::Characters;
    double start = 0, end = 1, offset = 0, amount = 1;  // fractions
    Vec2 position;
    double scale = 1, rotation = 0, opacity = 1;
    std::vector<float> unitAmounts;  // staggered animators: the amount of every unit (replaces `amount`)
    double amountOf(int unit) const {
        return unitAmounts.empty() ? amount : unitAmounts[size_t(std::clamp(unit, 0, int(unitAmounts.size()) - 1))];
    }
};

struct MaskEval {
    MaskShape shape = MaskShape::Rectangle;
    MaskMode mode = MaskMode::Add;
    bool inverted = false;
    Vec2 center, halfSize;  // layer space
    double roundness = 0, feather = 0, expansion = 0, opacity = 1;
    BezierPath path;  // MaskShape::Path (layer space, before the centre offset)
};

struct FrameDesc;

// Effect parameters flattened in definition order (each parameter takes `dims` slots).
struct EffectEval {
    EffectType type = EffectType::GaussianBlur;
    std::array<double, 16> v{};
};

struct DrawItem {
    ObjectId layerId = 0;
    LayerKind kind = LayerKind::Shape;
    ShapeType shape = ShapeType::Rectangle;
    BlendMode blend = BlendMode::Normal;
    Affine toTarget;            // layer space -> render-target pixels (preview scale applied)
    // 3D layers are a perspective (projective) map: target = toTarget(p) / (persp·p + perspW).
    // 2D layers keep persp 0, perspW 1.
    Vec2 persp{};
    double perspW = 1;
    bool threeD = false;
    double depth = 0;           // 3D: distance in front of the camera (3D layers paint far to near)
    bool projective() const { return persp.x != 0 || persp.y != 0 || perspW != 1; }
    Vec2 project(Vec2 p) const {
        const double w = persp.x * p.x + persp.y * p.y + perspW;
        const Vec2 q = toTarget.apply(p);
        return std::abs(w) > 1e-12 ? Vec2{q.x / w, q.y / w} : q;
    }
    // outer ∘ this: a 2D transform applied after this one (an offscreen region's offset).
    void prepend(const Affine& o) {
        const Affine m = toTarget;
        toTarget = {o.a * m.a + o.c * m.b + o.tx * persp.x, o.b * m.a + o.d * m.b + o.ty * persp.x,
                    o.a * m.c + o.c * m.d + o.tx * persp.y, o.b * m.c + o.d * m.d + o.ty * persp.y,
                    o.a * m.tx + o.c * m.ty + o.tx * perspW, o.b * m.tx + o.d * m.ty + o.ty * perspW};
    }
    // this ∘ inner: a 2D transform applied first (a glyph inside a text layer).
    void append(const Affine& g) {
        toTarget = toTarget * g;
        const Vec2 p = persp;
        persp = {p.x * g.a + p.y * g.b, p.x * g.c + p.y * g.d};
        perspW = p.x * g.tx + p.y * g.ty + perspW;
    }
    double opacity = 1;         // 0–1
    Vec2 boundsMin, boundsMax;  // content rectangle in layer space
    Value fill{}, stroke{};     // straight RGBA
    bool fillOn = true, strokeOn = false;
    double strokeWidth = 0, roundness = 0, points = 5, innerRatio = 0.5;
    ObjectId asset = 0;
    uint32_t assetGeneration = 0;
    int64_t videoFrame = -1;                    // footage: the source frame shown (-1 = a still image)
    uint32_t maskStart = 0, maskCount = 0;      // into FrameDesc::masks
    uint32_t effectStart = 0, effectCount = 0;  // into FrameDesc::effects
    int32_t matte = -1;                         // into FrameDesc::mattes
    MatteMode matteMode = MatteMode::None;
    BezierPath path;                            // ShapeType::Path
    double trimStart = 0, trimEnd = 1, trimOffset = 0;  // fractions of the path length
    TextStyle text;                             // LayerKind::Text
    bool strokeOverFill = false;                // text
    uint32_t animatorStart = 0, animatorCount = 0;  // into FrameDesc::animators
    // LayerKind::Precomp: the source composition, already transformed into this frame's target
    // pixels. `clipSize` > 0 clips it to the source's frame (layer space [0, clipSize]).
    std::shared_ptr<const FrameDesc> nested;
    Vec2 clipSize;

    // Effects and track mattes need the layer rendered on its own first; everything else is
    // drawn straight into the composition.
    bool needsOffscreen() const {
        // Text is drawn glyph by glyph, so its masks are applied to the assembled layer offscreen;
        // a precomp is assembled offscreen and composited as one layer.
        return effectCount > 0 || matte >= 0 || (kind == LayerKind::Text && maskCount > 0) || nested != nullptr;
    }
};

struct FrameDesc {
    ObjectId compId = 0;
    int width = 0, height = 0;  // render-target size in pixels (comp size * scale, rounded)
    double scale = 1;           // preview resolution factor (1, 0.5, 0.25 …)
    double time = 0;
    std::vector<DrawItem> items;   // bottom-to-top paint order
    std::vector<DrawItem> mattes;  // matte sources (drawn only through the layers that use them)
    std::vector<MaskEval> masks;
    std::vector<EffectEval> effects;
    std::vector<AnimatorEval> animators;
    uint64_t hash = 0;
    int offscreenItems() const;
};

struct EvalStats {
    int layersVisited = 0;
    int itemsEmitted = 0;
};

// Layer-space -> composition-pixel transform at `time`, including the parent chain.
// Parent cycles (which the editing API prevents) are cut after 64 levels.
Affine layerWorldTransform(const Composition& comp, const Layer& layer, double time);

// 3D: a layer's full transform including its parents (2D parents act at z = 0).
Mat4 layerWorldMatrix(const Composition& comp, const Layer& layer, double time);

// What 3D layers are seen through: the topmost visible camera layer active at `time`, else a
// default 50 mm camera that shows z = 0 exactly as 2D. Camera space: +z ahead, +y down.
struct CameraView {
    Mat4 view;          // composition (world) space -> camera space
    double zoom = 1;    // px: screen = centre + zoom · (x, y) / z
    double cx = 0, cy = 0;
    ObjectId camera = 0;  // 0 = the default camera
};
CameraView cameraAt(const Composition& comp, double time);
// The viewer's own look at a 3D scene (Custom View): while set on this thread, cameraAt() for
// `comp` returns it instead. Export and other threads never see it.
void setViewOverride(ObjectId comp, const CameraView* view);
// A view orbiting the composition's centre: yaw / pitch in degrees, `distance` from the centre
// (the default camera's distance at 1), shifted by `pan` (px, in the view's plane).
CameraView orbitView(const Composition& comp, double yaw, double pitch, double distance, Vec2 pan);

// Layer space -> composition pixels for any layer: a 2D layer's world transform, or a 3D layer's
// perspective view through the camera. `visible` is false when a 3D layer is at or behind the camera.
struct LayerMapping {
    Affine aff;
    Vec2 persp{};
    double perspW = 1;
    bool visible = true;
    Vec2 apply(Vec2 p) const;
    bool inverse(Vec2 compPoint, Vec2& layerPoint) const;  // false off the layer's plane (horizon)
};
LayerMapping layerToComp(const Composition& comp, const Layer& layer, double time, Vec2 boundsMin = {}, Vec2 boundsMax = {});

// Precomps nested deeper than this draw nothing (cycles are refused when editing, too).
inline constexpr int kMaxNesting = 16;

// Shape path of a layer / mask at `time` (the animated path track when there is one).
BezierPath layerPathAt(const Layer& layer, double time);
BezierPath maskPathAt(const Mask& mask, double time);

// Local content bounds of a layer (image size, shape size centred on the origin, null marker).
void layerLocalBounds(const Project& project, const Layer& layer, double time, Vec2& mn, Vec2& mx);

// `shutterOffset` (seconds) moves layers whose motion-blur switch is on: motion blur averages
// frames evaluated across the shutter (see motionBlurOffsets).
FrameDesc evaluateFrame(const Project& project, const Composition& comp, double time, double scale = 1.0,
                        EvalStats* stats = nullptr, double shutterOffset = 0);
// Sample offsets (seconds) for a motion-blurred frame of `comp`; just {0} when nothing in it
// (including nested precomps) has motion blur on or the composition has it off.
std::vector<double> motionBlurOffsets(const Project& project, const Composition& comp);

// How far (in render-target pixels) an item's effects can reach beyond its own pixels.
double effectReach(const FrameDesc& f, const DrawItem& d);
// Uniform scale from layer space to render-target pixels; spatial effect parameters use it so a
// blur looks the same at every preview resolution and follows the layer's own scale.
double effectScale(const DrawItem& d);

// Topmost visible, active layer under a composition-space point (null layers included so they can
// be selected in the viewer). A precomp is hit only where one of its own layers is. Returns 0 when
// nothing is hit.
ObjectId hitTest(const Project& project, const Composition& comp, double time, Vec2 compPoint);

// Four corners (TL, TR, BR, BL) of a layer's bounds in composition pixels, for selection overlays.
std::array<Vec2, 4> layerCorners(const Project& project, const Composition& comp, const Layer& layer, double time);
// Same for a mask's rectangle.
std::array<Vec2, 4> maskCorners(const Composition& comp, const Layer& layer, const Mask& mask, double time);

// FNV-1a over the semantic content of a frame description.
uint64_t hashFrame(const FrameDesc& f);

}  // namespace mf
