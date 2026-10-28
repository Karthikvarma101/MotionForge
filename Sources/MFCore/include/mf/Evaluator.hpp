// MotionForge core — evaluates a composition at a time into a flat, renderer-ready draw list.
//
// The draw list is the contract between the CPU (timeline evaluation) and the GPU (Metal
// renderer). Its 64-bit content hash is the frame-cache key, which gives dependency-based cache
// invalidation for free: an edit only invalidates the frames whose evaluated result changed.
#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <vector>

#include "mf/Math.hpp"
#include "mf/Model.hpp"

namespace mf {

struct MaskEval {
    MaskShape shape = MaskShape::Rectangle;
    MaskMode mode = MaskMode::Add;
    bool inverted = false;
    Vec2 center, halfSize;  // layer space
    double roundness = 0, feather = 0, expansion = 0, opacity = 1;
};

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
    double opacity = 1;         // 0–1
    Vec2 boundsMin, boundsMax;  // content rectangle in layer space
    Value fill{}, stroke{};     // straight RGBA
    bool fillOn = true, strokeOn = false;
    double strokeWidth = 0, roundness = 0, points = 5, innerRatio = 0.5;
    ObjectId asset = 0;
    uint32_t assetGeneration = 0;
    uint32_t maskStart = 0, maskCount = 0;      // into FrameDesc::masks
    uint32_t effectStart = 0, effectCount = 0;  // into FrameDesc::effects
    int32_t matte = -1;                         // into FrameDesc::mattes
    MatteMode matteMode = MatteMode::None;

    // Effects and track mattes need the layer rendered on its own first; everything else is
    // drawn straight into the composition.
    bool needsOffscreen() const { return effectCount > 0 || matte >= 0; }
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

// Local content bounds of a layer (image size, shape size centred on the origin, null marker).
void layerLocalBounds(const Project& project, const Layer& layer, double time, Vec2& mn, Vec2& mx);

FrameDesc evaluateFrame(const Project& project, const Composition& comp, double time, double scale = 1.0,
                        EvalStats* stats = nullptr);

// How far (in render-target pixels) an item's effects can reach beyond its own pixels.
double effectReach(const FrameDesc& f, const DrawItem& d);
// Uniform scale from layer space to render-target pixels; spatial effect parameters use it so a
// blur looks the same at every preview resolution and follows the layer's own scale.
double effectScale(const DrawItem& d);

// Topmost visible, active layer under a composition-space point (null layers included so they can
// be selected in the viewer). Returns 0 when nothing is hit.
ObjectId hitTest(const Project& project, const Composition& comp, double time, Vec2 compPoint);

// Four corners (TL, TR, BR, BL) of a layer's bounds in composition pixels, for selection overlays.
std::array<Vec2, 4> layerCorners(const Project& project, const Composition& comp, const Layer& layer, double time);
// Same for a mask's rectangle.
std::array<Vec2, 4> maskCorners(const Composition& comp, const Layer& layer, const Mask& mask, double time);

// FNV-1a over the semantic content of a frame description.
uint64_t hashFrame(const FrameDesc& f);

}  // namespace mf
