// MotionForge core — document model: project, assets, compositions, layers, animatable properties.
#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "mf/Math.hpp"

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
    FontSize,         // px (text)
    Tracking,         // 1/1000 em added between characters (text)
    LineHeight,       // multiple of the font size (text)
    TrimStart,        // percent of the path length (bezier paths)
    TrimEnd,          // percent
    TrimOffset,       // percent, shifts the trimmed range along the path
    TimeRemap,        // seconds of source time shown (precomp layers with time remapping)
    AudioLevel,       // dB relative to the source, -48 (silent) to 0 (audio layers)
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
    // Speed of a Bezier side as a slope of the segment's normalised timing curve (0 = ease to a
    // stop, 1 = linear speed, >1 overshoot, <0 anticipation). Edited in the graph editor.
    double inSlope = 0, outSlope = 0;
    bool operator==(const Keyframe&) const = default;
};

// Immutable payload shared between copies of a project (undo snapshots, the render thread), with
// value semantics for comparison.
template <typename T>
struct Shared {
    std::shared_ptr<const T> ptr;
    Shared() = default;
    explicit Shared(T v) : ptr(std::make_shared<const T>(std::move(v))) {}
    explicit operator bool() const { return bool(ptr); }
    const T* operator->() const { return ptr.get(); }
    const T& operator*() const { return *ptr; }
    void reset() { ptr.reset(); }
    bool operator==(const Shared& o) const { return ptr == o.ptr || (ptr && o.ptr && *ptr == *o.ptr); }
};

// Animation baked to one value per frame (e.g. imported After Effects expressions and rigs).
// Sample i is the value at t0 + i / rate; values between samples are interpolated linearly and
// the first/last sample holds outside the track.
struct SampledTrack {
    double t0 = 0, rate = 30;
    int dims = 1;
    std::vector<float> data;  // `dims` floats per sample
    size_t count() const { return dims > 0 ? data.size() / size_t(dims) : 0; }
    Value at(double time) const;
    bool operator==(const SampledTrack&) const = default;
};

struct Property {
    Value value{};                    // used when there are no keyframes
    std::vector<Keyframe> keyframes;  // sorted by time
    Shared<SampledTrack> samples;     // baked animation; overrides `value` and `keyframes`
    bool animated() const { return !keyframes.empty(); }
    bool baked() const { return bool(samples); }
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

enum class LayerKind : uint8_t { Shape = 0, Image, Null, Text, Precomp, Audio };
enum class ShapeType : uint8_t { Rectangle = 0, Ellipse, Polygon, Star, Path };

// A cubic bezier path: each vertex has handles relative to its point (zero = sharp corner).
struct PathVertex {
    Vec2 p, in, out;
    bool operator==(const PathVertex&) const = default;
};
struct BezierPath {
    std::vector<PathVertex> vertices;
    bool closed = true;
    bool operator==(const BezierPath&) const = default;
    bool empty() const { return vertices.size() < 2; }
};
// Polyline approximation within `tolerance` (same units as the path).
std::vector<Vec2> flattenPath(const BezierPath& p, double tolerance);
// Linear blend of two paths with the same vertex count and closedness (otherwise `a`).
BezierPath lerpPath(const BezierPath& a, const BezierPath& b, double t);

// A path baked to one shape per frame (animated shape and mask paths from other applications).
// Consecutive frames with the same topology are interpolated; others switch at the frame.
struct PathTrack {
    double t0 = 0, rate = 30;
    std::vector<BezierPath> frames;
    BezierPath at(double time) const;
    bool operator==(const PathTrack&) const = default;
};
void pathBounds(const BezierPath& p, Vec2& mn, Vec2& mx);  // control-point hull (contains the curve)

// ---------------------------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------------------------

enum class TextAlign : uint8_t { Left = 0, Center, Right };
const char* textAlignKey(TextAlign);
std::optional<TextAlign> textAlignFromKey(std::string_view);

struct TextData {
    std::string string = "Text";  // "\n" starts a new line
    std::string font = "Helvetica-Bold";  // PostScript name
    TextAlign align = TextAlign::Center;
    bool strokeOverFill = false;  // with the layer's stroke on: stroke drawn over each glyph's fill
    bool operator==(const TextData&) const = default;
};

// Text animator with a range selector: selected characters/words/lines are offset, scaled,
// rotated and faded by the animator's amounts, weighted by how much of each unit is selected.
enum class SelectorShape : uint8_t { Square = 0, RampUp, RampDown, Triangle, Round, Smooth };
enum class SelectorUnit : uint8_t { Characters = 0, Words, Lines };
enum class AnimParam : uint8_t { Start = 0, End, Offset, Amount, Position, Scale, Rotation, Opacity, Count };
inline constexpr int kAnimParamCount = static_cast<int>(AnimParam::Count);
const PropDef& animParamDef(AnimParam p);
const char* selectorShapeKey(SelectorShape);
const char* selectorUnitKey(SelectorUnit);
std::optional<SelectorShape> selectorShapeFromKey(std::string_view);
std::optional<SelectorUnit> selectorUnitFromKey(std::string_view);

struct TextAnimator {
    ObjectId id = 0;
    std::string name = "Animator";
    bool enabled = true;
    SelectorShape shape = SelectorShape::Square;
    SelectorUnit unit = SelectorUnit::Characters;
    // Seconds by which each successive unit sees the Amount curve later (a cascade from one curve).
    double stagger = 0;
    std::array<Property, kAnimParamCount> params{};
    Property& param(AnimParam p) { return params[static_cast<size_t>(p)]; }
    const Property& param(AnimParam p) const { return params[static_cast<size_t>(p)]; }
    bool operator==(const TextAnimator&) const = default;
};
TextAnimator makeTextAnimator(ObjectId id);
// Selection weight (0–1) of unit `i` of `n` for a range [start, end] (fractions, offset applied).
double selectorWeight(SelectorShape shape, double start, double end, int i, int n);
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

enum class MaskShape : uint8_t { Rectangle = 0, Ellipse, Path };
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
    BezierPath path;  // MaskShape::Path, in layer space (Position offsets it)
    Shared<PathTrack> pathTrack;  // animated path (replaces `path` when set)
    Property& param(MaskParam p) { return params[static_cast<size_t>(p)]; }
    const Property& param(MaskParam p) const { return params[static_cast<size_t>(p)]; }
    bool operator==(const Mask&) const = default;
};

// ---------------------------------------------------------------------------------------------
// Effects (GPU image operations applied to the masked layer, in stack order)
// ---------------------------------------------------------------------------------------------

enum class EffectType : uint8_t { GaussianBlur = 0, DropShadow, Glow, BrightnessContrast, HueSaturation, Fill, GradientRamp, Count };
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
    ObjectId asset = 0;    // image and audio layers
    std::array<Property, kPropCount> props{};
    std::vector<Mask> masks;      // applied in order
    std::vector<Effect> effects;  // applied in order, after masks
    ObjectId matteLayer = 0;
    MatteMode matteMode = MatteMode::None;
    BezierPath path;                      // ShapeType::Path, in layer space
    Shared<PathTrack> pathTrack;          // animated path (replaces `path` when set)
    TextData text;                        // LayerKind::Text
    std::vector<TextAnimator> animators;  // LayerKind::Text
    // LayerKind::Precomp: another composition drawn as this layer. Its time 0 is at `startTime`
    // in this composition, or the source time comes from the TimeRemap property. Collapsed
    // precomps draw their layers straight into this composition (no clipping to the source's
    // frame); others are composited as one group, clipped to the source's frame.
    ObjectId source = 0;
    double startTime = 0;  // precomp and audio layers: where source time 0 sits in this composition
    bool timeRemap = false;
    bool collapse = false;
    bool motionBlur = false;  // blurred along its motion when the composition renders with motion blur

    Property& prop(PropId id) { return props[static_cast<size_t>(id)]; }
    const Property& prop(PropId id) const { return props[static_cast<size_t>(id)]; }
    bool activeAt(double t) const { return visible && t >= inPoint && t < outPoint; }
    bool inTimeRange(double t) const { return t >= inPoint && t < outPoint; }
    bool hasMatte() const { return matteLayer != 0 && matteMode != MatteMode::None; }
    double sourceTime(double t) const;  // precomp layers: source composition time shown at `t`
    Mask* findMask(ObjectId id);
    const Mask* findMask(ObjectId id) const;
    Effect* findEffect(ObjectId id);
    const Effect* findEffect(ObjectId id) const;
    TextAnimator* findAnimator(ObjectId id);
    const TextAnimator* findAnimator(ObjectId id) const;
    bool operator==(const Layer&) const = default;
};

// Addresses any animatable property of a layer: its own transform/shape properties, a mask
// parameter or an effect parameter. Undo, keyframing and the UI all work through this.
enum class PropOwner : uint8_t { Layer = 0, Mask, Effect, TextAnimator };
struct PropRef {
    PropOwner owner = PropOwner::Layer;
    ObjectId ownerId = 0;  // mask / effect id
    int index = 0;         // PropId, MaskParam or effect parameter index
    static PropRef layer(PropId id) { return {PropOwner::Layer, 0, static_cast<int>(id)}; }
    static PropRef mask(ObjectId m, MaskParam p) { return {PropOwner::Mask, m, static_cast<int>(p)}; }
    static PropRef effect(ObjectId e, int param) { return {PropOwner::Effect, e, param}; }
    static PropRef animator(ObjectId a, AnimParam p) { return {PropOwner::TextAnimator, a, static_cast<int>(p)}; }
    bool operator==(const PropRef&) const = default;
};
Property* resolveProperty(Layer& l, PropRef r);
const Property* resolveProperty(const Layer& l, PropRef r);
const PropDef* propertyDef(const Layer& l, PropRef r);

// ---------------------------------------------------------------------------------------------
// Assets, compositions, project
// ---------------------------------------------------------------------------------------------

enum class AssetKind : uint8_t { Image = 0, Audio };

struct Asset {
    ObjectId id = 0;
    AssetKind kind = AssetKind::Image;
    std::string name;
    std::string path;          // absolute, resolved at load time
    int width = 0, height = 0; // pixels (images)
    double duration = 0;       // seconds (audio)
    bool missing = false;      // could not be found on load
    uint32_t generation = 0;   // bumped when the media is relinked/reloaded (invalidates caches)
    bool operator==(const Asset&) const = default;
};

struct Composition {
    ObjectId id = 0;
    std::string name = "Main";
    std::string folder;  // project-panel folder path ("02_SCENES/Shapes"), empty = top level
    int width = 1920, height = 1080;
    double fps = 30;
    double duration = 10;                 // seconds
    Value background{0.08, 0.08, 0.09, 1};
    // Motion blur (layers with their switch on): `samples` renders spread over the shutter, which
    // opens `shutterPhase` degrees of a frame before the frame time and stays open `shutterAngle`.
    bool motionBlur = false;
    double shutterAngle = 180, shutterPhase = -90;
    int motionBlurSamples = 8;
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
    // 2: masks, effects, mattes; 3: spatial keys; 4: text, paths, ease speed; 5: precomps, baked tracks;
    // 6: audio assets and layers
    static constexpr int kFormatVersion = 6;
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
// A layer showing `source` inside `comp`, anchored at the source's centre.
Layer makePrecompLayer(const Composition& comp, const Composition& source, ObjectId id);
// True when `comp` shows `target` directly or through nested precomps (adding `target` to
// `comp` would then create a cycle when comp == target or target contains comp).
bool compUses(const Project& project, ObjectId comp, ObjectId target);
// A new project with one empty composition.
Project makeDefaultProject(int width = 1920, int height = 1080, double fps = 30, double duration = 10);

}  // namespace mf
