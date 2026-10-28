// MotionForge core — document model: project, assets, compositions, layers, animatable properties.
#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace mf {

using ObjectId = uint64_t;  // 0 means "none"
using Value = std::array<double, 4>;

// ---------------------------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------------------------

// Dense ids: every layer carries the full array; layer kinds simply ignore what they don't use.
enum class PropId : uint8_t {
    AnchorPoint = 0,  // px, layer space
    Position,         // px, parent (or comp) space
    Scale,            // percent
    Rotation,         // degrees, clockwise
    Opacity,          // percent 0–100
    ShapeSize,        // px
    Roundness,        // px (rectangle corner radius / polygon & star rounding)
    FillColor,        // straight RGBA 0–1, sRGB-encoded
    StrokeColor,      // straight RGBA 0–1, sRGB-encoded
    StrokeWidth,      // px
    Points,           // polygon / star point count
    InnerRatio,       // star inner radius as a fraction of the outer radius
    Count
};
inline constexpr int kPropCount = static_cast<int>(PropId::Count);

struct PropDef {
    const char* key;   // stable identifier used in project files
    const char* label;
    int dims;
    Value defaultValue;
    double minValue, maxValue;  // applied per component
    bool isColor;
    bool spatial = false;  // a 2D position: keyframes follow a (bezier) motion path
};
const PropDef& propDef(PropId id);
std::optional<PropId> propFromKey(std::string_view key);

enum class Interp : uint8_t { Linear = 0, Hold, Bezier };
const char* interpKey(Interp);
std::optional<Interp> interpFromKey(std::string_view);

// How a spatial property's motion path passes through a keyframe. Linear: straight segments
// (a corner at the key). Auto: smooth curve with handles derived from the neighbouring keys.
// Bezier: explicit handles (tangentIn / tangentOut, offsets from the key's value).
enum class Spatial : uint8_t { Linear = 0, Auto, Bezier };
const char* spatialKey(Spatial);
std::optional<Spatial> spatialFromKey(std::string_view);

// Temporal interpolation of the segment leaving a keyframe is decided by `outInterp` of the earlier
// key and `inInterp` of the later key. Bezier sides use the influence (0–1, like "Easy Ease" 33%)
// with zero speed, producing a cubic-bezier timing curve.
struct Keyframe {
    double time = 0;  // seconds, composition time
    Value value{};
    Interp inInterp = Interp::Linear;
    Interp outInterp = Interp::Linear;
    double easeIn = 1.0 / 3.0;
    double easeOut = 1.0 / 3.0;
    Spatial spatial = Spatial::Linear;  // spatial properties only
    Value tangentIn{}, tangentOut{};    // Bezier handles, relative to `value`
    bool operator==(const Keyframe&) const = default;
};

struct Property {
    Value value{};                    // used when there are no keyframes
    std::vector<Keyframe> keyframes;  // sorted by time
    bool animated() const { return !keyframes.empty(); }
    bool operator==(const Property&) const = default;
};

// Value at `time`, clamped to the definition's range.
Value evaluateProperty(const Property& p, const PropDef& def, double time);
Value evaluateProperty(const Property& p, PropId id, double time);
// Cubic-bezier timing (CSS semantics): returns progress for normalized time u in [0,1].
double cubicBezierTiming(double x1, double y1, double x2, double y2, double u);

// Resolved spatial handles of keys[i] (Auto computed from neighbours, Linear = zero), as offsets.
void spatialHandles(const std::vector<Keyframe>& keys, size_t i, Value& in, Value& out);
// Points along a spatial property's whole motion path (x, y of the value), `perSegment` per segment.
std::vector<std::array<double, 2>> sampleMotionPath(const Property& p, int perSegment);

// ---------------------------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------------------------

enum class LayerKind : uint8_t { Shape = 0, Image, Null };
enum class ShapeType : uint8_t { Rectangle = 0, Ellipse, Polygon, Star };
enum class BlendMode : uint8_t { Normal = 0, Add, Multiply, Screen, Overlay, Darken, Lighten, Count };

const char* layerKindKey(LayerKind);
const char* shapeTypeKey(ShapeType);
const char* blendModeKey(BlendMode);
std::optional<LayerKind> layerKindFromKey(std::string_view);
std::optional<ShapeType> shapeTypeFromKey(std::string_view);
std::optional<BlendMode> blendModeFromKey(std::string_view);

// ---------------------------------------------------------------------------------------------
// Masks (layer-space shapes that cut the layer's pixels before effects run)
// ---------------------------------------------------------------------------------------------

enum class MaskShape : uint8_t { Rectangle = 0, Ellipse };
enum class MaskMode : uint8_t { Add = 0, Subtract, Intersect, Difference };
enum class MaskParam : uint8_t { Position = 0, Size, Roundness, Feather, Expansion, Opacity, Count };
inline constexpr int kMaskParamCount = static_cast<int>(MaskParam::Count);
const PropDef& maskParamDef(MaskParam p);
const char* maskShapeKey(MaskShape);
const char* maskModeKey(MaskMode);
std::optional<MaskShape> maskShapeFromKey(std::string_view);
std::optional<MaskMode> maskModeFromKey(std::string_view);

struct Mask {
    ObjectId id = 0;
    std::string name;
    MaskShape shape = MaskShape::Rectangle;
    MaskMode mode = MaskMode::Add;
    bool inverted = false;
    bool enabled = true;
    std::array<Property, kMaskParamCount> params{};
    Property& param(MaskParam p) { return params[static_cast<size_t>(p)]; }
    const Property& param(MaskParam p) const { return params[static_cast<size_t>(p)]; }
    bool operator==(const Mask&) const = default;
};

// ---------------------------------------------------------------------------------------------
// Effects (GPU image operations applied to the masked layer, in stack order)
// ---------------------------------------------------------------------------------------------

enum class EffectType : uint8_t { GaussianBlur = 0, DropShadow, Glow, BrightnessContrast, HueSaturation, Fill, Count };
inline constexpr int kEffectTypeCount = static_cast<int>(EffectType::Count);

struct EffectDef {
    const char* key;       // stable identifier in project files
    const char* label;
    const char* category;  // for the effects browser
    const char* summary;
    std::vector<PropDef> params;
};
const EffectDef& effectDef(EffectType t);
std::optional<EffectType> effectTypeFromKey(std::string_view);

struct Effect {
    ObjectId id = 0;
    EffectType type = EffectType::GaussianBlur;
    bool enabled = true;
    std::vector<Property> params;  // one per effectDef(type).params
    bool operator==(const Effect&) const = default;
};
Effect makeEffect(EffectType t, ObjectId id);

// Track matte: this layer is shown only where `matteLayer` (any other layer) has alpha / luminance.
enum class MatteMode : uint8_t { None = 0, Alpha, AlphaInverted, Luma, LumaInverted };
const char* matteModeKey(MatteMode);
std::optional<MatteMode> matteModeFromKey(std::string_view);

struct Layer {
    ObjectId id = 0;
    std::string name;
    LayerKind kind = LayerKind::Shape;
    ShapeType shape = ShapeType::Rectangle;
    BlendMode blend = BlendMode::Normal;
    bool visible = true;
    bool fillEnabled = true;
    bool strokeEnabled = false;
    double inPoint = 0;    // seconds; the layer is active on [inPoint, outPoint)
    double outPoint = 10;
    ObjectId parent = 0;
    ObjectId asset = 0;    // image layers
    std::array<Property, kPropCount> props{};
    std::vector<Mask> masks;      // applied in order
    std::vector<Effect> effects;  // applied in order, after masks
    ObjectId matteLayer = 0;
    MatteMode matteMode = MatteMode::None;

    Property& prop(PropId id) { return props[static_cast<size_t>(id)]; }
    const Property& prop(PropId id) const { return props[static_cast<size_t>(id)]; }
    bool activeAt(double t) const { return visible && t >= inPoint && t < outPoint; }
    bool inTimeRange(double t) const { return t >= inPoint && t < outPoint; }
    bool hasMatte() const { return matteLayer != 0 && matteMode != MatteMode::None; }
    Mask* findMask(ObjectId id);
    const Mask* findMask(ObjectId id) const;
    Effect* findEffect(ObjectId id);
    const Effect* findEffect(ObjectId id) const;
    bool operator==(const Layer&) const = default;
};

// Addresses any animatable property of a layer: its own transform/shape properties, a mask
// parameter or an effect parameter. Undo, keyframing and the UI all work through this.
enum class PropOwner : uint8_t { Layer = 0, Mask, Effect };
struct PropRef {
    PropOwner owner = PropOwner::Layer;
    ObjectId ownerId = 0;  // mask / effect id
    int index = 0;         // PropId, MaskParam or effect parameter index
    static PropRef layer(PropId id) { return {PropOwner::Layer, 0, static_cast<int>(id)}; }
    static PropRef mask(ObjectId m, MaskParam p) { return {PropOwner::Mask, m, static_cast<int>(p)}; }
    static PropRef effect(ObjectId e, int param) { return {PropOwner::Effect, e, param}; }
    bool operator==(const PropRef&) const = default;
};
Property* resolveProperty(Layer& l, PropRef r);
const Property* resolveProperty(const Layer& l, PropRef r);
const PropDef* propertyDef(const Layer& l, PropRef r);

// ---------------------------------------------------------------------------------------------
// Assets, compositions, project
// ---------------------------------------------------------------------------------------------

enum class AssetKind : uint8_t { Image = 0 };

struct Asset {
    ObjectId id = 0;
    AssetKind kind = AssetKind::Image;
    std::string name;
    std::string path;          // absolute, resolved at load time
    int width = 0, height = 0; // pixels
    bool missing = false;      // could not be found on load
    uint32_t generation = 0;   // bumped when the media is relinked/reloaded (invalidates caches)
    bool operator==(const Asset&) const = default;
};

struct Composition {
    ObjectId id = 0;
    std::string name = "Main";
    int width = 1920, height = 1080;
    double fps = 30;
    double duration = 10;                 // seconds
    Value background{0.08, 0.08, 0.09, 1};
    std::vector<Layer> layers;            // index 0 is the TOP of the stack

    double frameDuration() const { return 1.0 / fps; }
    int64_t frameCount() const { return static_cast<int64_t>(std::llround(duration * fps)); }
    double snapToFrame(double t) const { return std::round(t * fps) / fps; }

    Layer* findLayer(ObjectId id);
    const Layer* findLayer(ObjectId id) const;
    int indexOf(ObjectId id) const;  // -1 if absent
    bool operator==(const Composition&) const = default;
};

struct Project {
    static constexpr int kFormatVersion = 3;  // 2: masks, effects, track mattes; 3: spatial keyframes
    ObjectId nextId = 1;
    ObjectId activeComposition = 0;
    std::vector<Asset> assets;
    std::vector<Composition> compositions;

    ObjectId allocateId() { return nextId++; }
    Composition* findComposition(ObjectId id);
    const Composition* findComposition(ObjectId id) const;
    Composition* activeComp() { return findComposition(activeComposition); }
    const Composition* activeComp() const { return findComposition(activeComposition); }
    Asset* findAsset(ObjectId id);
    const Asset* findAsset(ObjectId id) const;
    bool operator==(const Project&) const = default;
};

// Fresh layer with the defaults for its kind (AE-like: shapes centred on their origin,
// images anchored at their centre, everything positioned at the composition centre).
Layer makeLayer(LayerKind kind, const Composition& comp, ObjectId id, const Asset* asset = nullptr);
// A new project with one empty composition.
Project makeDefaultProject(int width = 1920, int height = 1080, double fps = 30, double duration = 10);

}  // namespace mf
