#include "mf/Model.hpp"

#include <algorithm>
#include <cmath>

namespace mf {

namespace {

constexpr double kBig = 1e9;

const PropDef kPropDefs[kPropCount] = {
    {"anchorPoint", "Anchor Point", 2, {0, 0, 0, 0}, -kBig, kBig, false, true},
    {"position", "Position", 2, {960, 540, 0, 0}, -kBig, kBig, false, true},
    {"scale", "Scale", 2, {100, 100, 0, 0}, -100000, 100000, false},
    {"rotation", "Rotation", 1, {0, 0, 0, 0}, -kBig, kBig, false},
    {"opacity", "Opacity", 1, {100, 0, 0, 0}, 0, 100, false},
    {"size", "Size", 2, {400, 400, 0, 0}, 0, 100000, false},
    {"roundness", "Roundness", 1, {0, 0, 0, 0}, 0, 100000, false},
    {"fillColor", "Fill Color", 4, {0.96, 0.75, 0.18, 1}, 0, 1, true},
    {"strokeColor", "Stroke Color", 4, {1, 1, 1, 1}, 0, 1, true},
    {"strokeWidth", "Stroke Width", 1, {8, 0, 0, 0}, 0, 10000, false},
    {"points", "Points", 1, {5, 0, 0, 0}, 3, 64, false},
    {"innerRatio", "Inner Radius", 1, {0.45, 0, 0, 0}, 0.01, 1, false},
};

template <typename E, size_t N>
std::optional<E> fromKey(std::string_view key, const char* const (&keys)[N]) {
    for (size_t i = 0; i < N; ++i)
        if (key == keys[i]) return static_cast<E>(i);
    return std::nullopt;
}

const char* const kInterpKeys[] = {"linear", "hold", "bezier"};
const char* const kSpatialKeys[] = {"linear", "auto", "bezier"};
const char* const kLayerKindKeys[] = {"shape", "image", "null"};
const char* const kShapeTypeKeys[] = {"rectangle", "ellipse", "polygon", "star"};
const char* const kBlendKeys[] = {"normal", "add", "multiply", "screen", "overlay", "darken", "lighten"};
const char* const kMaskShapeKeys[] = {"rectangle", "ellipse"};
const char* const kMaskModeKeys[] = {"add", "subtract", "intersect", "difference"};
const char* const kMatteModeKeys[] = {"none", "alpha", "alphaInverted", "luma", "lumaInverted"};

const PropDef kMaskParamDefs[kMaskParamCount] = {
    {"position", "Mask Position", 2, {0, 0, 0, 0}, -kBig, kBig, false, true},
    {"size", "Mask Size", 2, {200, 200, 0, 0}, 0, 100000, false},
    {"roundness", "Mask Roundness", 1, {0, 0, 0, 0}, 0, 100000, false},
    {"feather", "Mask Feather", 1, {0, 0, 0, 0}, 0, 10000, false},
    {"expansion", "Mask Expansion", 1, {0, 0, 0, 0}, -10000, 10000, false},
    {"opacity", "Mask Opacity", 1, {100, 0, 0, 0}, 0, 100, false},
};

const std::vector<EffectDef>& effectDefs() {
    static const std::vector<EffectDef> defs = {
        {"gaussianBlur", "Gaussian Blur", "Blur & Sharpen", "Soft blur of the layer; radius in layer pixels.",
         {{"radius", "Blur Radius", 1, {20, 0, 0, 0}, 0, 2000, false}}},
        {"dropShadow", "Drop Shadow", "Perspective", "Offset, softened shadow behind the layer.",
         {{"color", "Shadow Color", 4, {0, 0, 0, 1}, 0, 1, true},
          {"opacity", "Shadow Opacity", 1, {60, 0, 0, 0}, 0, 100, false},
          {"direction", "Direction", 1, {135, 0, 0, 0}, -36000, 36000, false},
          {"distance", "Distance", 1, {20, 0, 0, 0}, 0, 10000, false},
          {"softness", "Softness", 1, {30, 0, 0, 0}, 0, 2000, false}}},
        {"glow", "Glow", "Stylize", "Blooms the bright parts of the layer.",
         {{"threshold", "Glow Threshold", 1, {50, 0, 0, 0}, 0, 100, false},
          {"radius", "Glow Radius", 1, {40, 0, 0, 0}, 0, 2000, false},
          {"intensity", "Glow Intensity", 1, {100, 0, 0, 0}, 0, 1000, false}}},
        {"brightnessContrast", "Brightness & Contrast", "Color Correction", "Lifts or lowers levels and contrast.",
         {{"brightness", "Brightness", 1, {0, 0, 0, 0}, -100, 100, false},
          {"contrast", "Contrast", 1, {0, 0, 0, 0}, -100, 100, false}}},
        {"hueSaturation", "Hue/Saturation", "Color Correction", "Rotates hue, changes saturation and lightness.",
         {{"hue", "Hue", 1, {0, 0, 0, 0}, -36000, 36000, false},
          {"saturation", "Saturation", 1, {0, 0, 0, 0}, -100, 100, false},
          {"lightness", "Lightness", 1, {0, 0, 0, 0}, -100, 100, false}}},
        {"fill", "Fill", "Generate", "Replaces the layer's colour, keeping its alpha.",
         {{"color", "Fill Color", 4, {1, 0.25, 0.25, 1}, 0, 1, true},
          {"opacity", "Fill Opacity", 1, {100, 0, 0, 0}, 0, 100, false}}},
    };
    return defs;
}

Value clampValue(Value v, const PropDef& def) {
    for (int i = 0; i < def.dims; ++i) v[i] = std::clamp(v[i], def.minValue, def.maxValue);
    return v;
}

// Bezier control for one side of a segment. Linear sides sit on the diagonal so a linear/linear
// segment is exactly linear; eased sides have zero speed (flat tangent).
void segmentControls(const Keyframe& k0, const Keyframe& k1, double& x1, double& y1, double& x2, double& y2) {
    if (k0.outInterp == Interp::Bezier) {
        x1 = std::clamp(k0.easeOut, 0.0, 1.0);
        y1 = 0;
    } else {
        x1 = y1 = 1.0 / 3.0;
    }
    if (k1.inInterp == Interp::Bezier) {
        x2 = 1.0 - std::clamp(k1.easeIn, 0.0, 1.0);
        y2 = 1;
    } else {
        x2 = y2 = 2.0 / 3.0;
    }
}

}  // namespace

const PropDef& propDef(PropId id) { return kPropDefs[static_cast<size_t>(id)]; }

std::optional<PropId> propFromKey(std::string_view key) {
    for (int i = 0; i < kPropCount; ++i)
        if (key == kPropDefs[i].key) return static_cast<PropId>(i);
    return std::nullopt;
}

const char* interpKey(Interp v) { return kInterpKeys[static_cast<size_t>(v)]; }
const char* layerKindKey(LayerKind v) { return kLayerKindKeys[static_cast<size_t>(v)]; }
const char* shapeTypeKey(ShapeType v) { return kShapeTypeKeys[static_cast<size_t>(v)]; }
const char* blendModeKey(BlendMode v) { return kBlendKeys[static_cast<size_t>(v)]; }
std::optional<Interp> interpFromKey(std::string_view k) { return fromKey<Interp>(k, kInterpKeys); }
const char* spatialKey(Spatial v) { return kSpatialKeys[static_cast<size_t>(v)]; }
std::optional<Spatial> spatialFromKey(std::string_view k) { return fromKey<Spatial>(k, kSpatialKeys); }
std::optional<LayerKind> layerKindFromKey(std::string_view k) { return fromKey<LayerKind>(k, kLayerKindKeys); }
std::optional<ShapeType> shapeTypeFromKey(std::string_view k) { return fromKey<ShapeType>(k, kShapeTypeKeys); }
std::optional<BlendMode> blendModeFromKey(std::string_view k) { return fromKey<BlendMode>(k, kBlendKeys); }

double cubicBezierTiming(double x1, double y1, double x2, double y2, double u) {
    if (u <= 0) return 0;
    if (u >= 1) return 1;
    auto bez = [](double p1, double p2, double s) {
        const double is = 1 - s;
        return 3 * is * is * s * p1 + 3 * is * s * s * p2 + s * s * s;
    };
    auto dbez = [](double p1, double p2, double s) {
        const double is = 1 - s;
        return 3 * is * is * p1 + 6 * is * s * (p2 - p1) + 3 * s * s * (1 - p2);
    };
    // Newton first (fast, usually converges in 3–4 steps), bisection as the safe fallback.
    double s = u;
    for (int i = 0; i < 8; ++i) {
        const double err = bez(x1, x2, s) - u;
        if (std::abs(err) < 1e-9) return bez(y1, y2, s);
        const double dv = dbez(x1, x2, s);
        if (std::abs(dv) < 1e-9) break;
        s -= err / dv;
        if (s < 0 || s > 1) break;
    }
    double lo = 0, hi = 1;
    s = u;
    for (int i = 0; i < 60; ++i) {
        const double x = bez(x1, x2, s);
        if (std::abs(x - u) < 1e-10) break;
        (x < u ? lo : hi) = s;
        s = 0.5 * (lo + hi);
    }
    return bez(y1, y2, s);
}

Value evaluateProperty(const Property& p, PropId id, double time) { return evaluateProperty(p, propDef(id), time); }

void spatialHandles(const std::vector<Keyframe>& keys, size_t i, Value& in, Value& out) {
    in = out = Value{};
    const Keyframe& k = keys[i];
    if (k.spatial == Spatial::Bezier) {
        in = k.tangentIn;
        out = k.tangentOut;
        return;
    }
    if (k.spatial == Spatial::Linear || i == 0 || i + 1 >= keys.size()) return;  // ends stay straight
    // Auto: handles along the line from the previous to the next key, each a third as long as
    // the segment it belongs to (smooth through the key, no overshoot on uneven spacing).
    const Value& a = keys[i - 1].value;
    const Value& b = keys[i + 1].value;
    const double dx = b[0] - a[0], dy = b[1] - a[1];
    const double len = std::hypot(dx, dy);
    if (len < 1e-9) return;
    const double lin = std::hypot(k.value[0] - a[0], k.value[1] - a[1]);
    const double lout = std::hypot(b[0] - k.value[0], b[1] - k.value[1]);
    in = {-dx / len * lin / 3, -dy / len * lin / 3, 0, 0};
    out = {dx / len * lout / 3, dy / len * lout / 3, 0, 0};
}

namespace {

struct Seg {
    double p[4][2];  // cubic control points
};

Seg spatialSegment(const std::vector<Keyframe>& keys, size_t i0) {
    Value in0, out0, in1, out1;
    spatialHandles(keys, i0, in0, out0);
    spatialHandles(keys, i0 + 1, in1, out1);
    const Value& a = keys[i0].value;
    const Value& b = keys[i0 + 1].value;
    return Seg{{{a[0], a[1]}, {a[0] + out0[0], a[1] + out0[1]}, {b[0] + in1[0], b[1] + in1[1]}, {b[0], b[1]}}};
}

bool segmentCurved(const std::vector<Keyframe>& keys, size_t i0) {
    const Seg s = spatialSegment(keys, i0);
    // Straight if both handles lie on the chord (zero handles are the common case).
    auto onChord = [&](const double* c) {
        const double cx = s.p[3][0] - s.p[0][0], cy = s.p[3][1] - s.p[0][1];
        const double vx = c[0] - s.p[0][0], vy = c[1] - s.p[0][1];
        return std::abs(cx * vy - cy * vx) < 1e-9 * std::max(1.0, cx * cx + cy * cy);
    };
    return !(onChord(s.p[1]) && onChord(s.p[2]));
}

void bezierPoint(const Seg& s, double t, double& x, double& y) {
    const double it = 1 - t;
    const double a = it * it * it, b = 3 * it * it * t, c = 3 * it * t * t, d = t * t * t;
    x = a * s.p[0][0] + b * s.p[1][0] + c * s.p[2][0] + d * s.p[3][0];
    y = a * s.p[0][1] + b * s.p[1][1] + c * s.p[2][1] + d * s.p[3][1];
}

// Point at fraction `f` of the curve's arc length: temporal easing controls speed *along* the
// path, so linear timing moves at constant speed even around curves.
void bezierAtDistance(const Seg& s, double f, double& x, double& y) {
    constexpr int N = 48;
    double len[N + 1];
    double px = s.p[0][0], py = s.p[0][1];
    len[0] = 0;
    for (int j = 1; j <= N; ++j) {
        double qx, qy;
        bezierPoint(s, double(j) / N, qx, qy);
        len[j] = len[j - 1] + std::hypot(qx - px, qy - py);
        px = qx;
        py = qy;
    }
    if (len[N] <= 0) {
        bezierPoint(s, f, x, y);
        return;
    }
    const double target = std::clamp(f, 0.0, 1.0) * len[N];
    int j = int(std::lower_bound(len, len + N + 1, target) - len);
    j = std::clamp(j, 1, N);
    const double seg = len[j] - len[j - 1];
    const double t = (double(j - 1) + (seg > 0 ? (target - len[j - 1]) / seg : 0)) / N;
    bezierPoint(s, t, x, y);
}

}  // namespace

std::vector<std::array<double, 2>> sampleMotionPath(const Property& p, int perSegment) {
    std::vector<std::array<double, 2>> pts;
    const auto& keys = p.keyframes;
    if (keys.empty()) return pts;
    pts.push_back({keys[0].value[0], keys[0].value[1]});
    for (size_t i = 0; i + 1 < keys.size(); ++i) {
        const Seg s = spatialSegment(keys, i);
        for (int j = 1; j <= perSegment; ++j) {
            double x, y;
            bezierPoint(s, double(j) / perSegment, x, y);
            pts.push_back({x, y});
        }
    }
    return pts;
}

Value evaluateProperty(const Property& p, const PropDef& def, double time) {
    const auto& keys = p.keyframes;
    if (keys.empty()) return clampValue(p.value, def);
    if (time <= keys.front().time) return clampValue(keys.front().value, def);
    if (time >= keys.back().time) return clampValue(keys.back().value, def);

    // First key with time > `time`; keys are sorted and there are at least two here.
    auto it = std::upper_bound(keys.begin(), keys.end(), time,
                               [](double t, const Keyframe& k) { return t < k.time; });
    const Keyframe& k1 = *it;
    const Keyframe& k0 = *(it - 1);
    if (k0.outInterp == Interp::Hold) return clampValue(k0.value, def);

    const double span = k1.time - k0.time;
    const double u = span > 0 ? (time - k0.time) / span : 1.0;
    double x1, y1, x2, y2;
    segmentControls(k0, k1, x1, y1, x2, y2);
    const bool linear = k0.outInterp == Interp::Linear && k1.inInterp == Interp::Linear;
    const double f = linear ? u : cubicBezierTiming(x1, y1, x2, y2, u);

    Value out{};
    for (int i = 0; i < def.dims; ++i) out[i] = k0.value[i] + (k1.value[i] - k0.value[i]) * f;
    if (def.spatial && def.dims >= 2) {
        const size_t i0 = size_t(it - keys.begin()) - 1;
        if (segmentCurved(keys, i0)) bezierAtDistance(spatialSegment(keys, i0), f, out[0], out[1]);
    }
    return clampValue(out, def);
}

// ---------------------------------------------------------------------------------------------

const PropDef& maskParamDef(MaskParam p) { return kMaskParamDefs[static_cast<size_t>(p)]; }
const char* maskShapeKey(MaskShape v) { return kMaskShapeKeys[static_cast<size_t>(v)]; }
const char* maskModeKey(MaskMode v) { return kMaskModeKeys[static_cast<size_t>(v)]; }
const char* matteModeKey(MatteMode v) { return kMatteModeKeys[static_cast<size_t>(v)]; }
std::optional<MaskShape> maskShapeFromKey(std::string_view k) { return fromKey<MaskShape>(k, kMaskShapeKeys); }
std::optional<MaskMode> maskModeFromKey(std::string_view k) { return fromKey<MaskMode>(k, kMaskModeKeys); }
std::optional<MatteMode> matteModeFromKey(std::string_view k) { return fromKey<MatteMode>(k, kMatteModeKeys); }

const EffectDef& effectDef(EffectType t) { return effectDefs()[static_cast<size_t>(t)]; }
std::optional<EffectType> effectTypeFromKey(std::string_view k) {
    for (int i = 0; i < kEffectTypeCount; ++i)
        if (k == effectDefs()[i].key) return static_cast<EffectType>(i);
    return std::nullopt;
}

Effect makeEffect(EffectType t, ObjectId id) {
    Effect e;
    e.id = id;
    e.type = t;
    for (const PropDef& d : effectDef(t).params) {
        Property p;
        p.value = d.defaultValue;
        e.params.push_back(p);
    }
    return e;
}

Mask* Layer::findMask(ObjectId mid) {
    for (auto& m : masks)
        if (m.id == mid) return &m;
    return nullptr;
}
const Mask* Layer::findMask(ObjectId mid) const { return const_cast<Layer*>(this)->findMask(mid); }
Effect* Layer::findEffect(ObjectId eid) {
    for (auto& e : effects)
        if (e.id == eid) return &e;
    return nullptr;
}
const Effect* Layer::findEffect(ObjectId eid) const { return const_cast<Layer*>(this)->findEffect(eid); }

Property* resolveProperty(Layer& l, PropRef r) {
    switch (r.owner) {
        case PropOwner::Layer:
            return (r.index >= 0 && r.index < kPropCount) ? &l.props[size_t(r.index)] : nullptr;
        case PropOwner::Mask: {
            Mask* m = l.findMask(r.ownerId);
            return (m && r.index >= 0 && r.index < kMaskParamCount) ? &m->params[size_t(r.index)] : nullptr;
        }
        case PropOwner::Effect: {
            Effect* e = l.findEffect(r.ownerId);
            return (e && r.index >= 0 && r.index < int(e->params.size())) ? &e->params[size_t(r.index)] : nullptr;
        }
    }
    return nullptr;
}
const Property* resolveProperty(const Layer& l, PropRef r) { return resolveProperty(const_cast<Layer&>(l), r); }

const PropDef* propertyDef(const Layer& l, PropRef r) {
    if (!resolveProperty(l, r)) return nullptr;
    switch (r.owner) {
        case PropOwner::Layer: return &propDef(static_cast<PropId>(r.index));
        case PropOwner::Mask: return &maskParamDef(static_cast<MaskParam>(r.index));
        case PropOwner::Effect: return &effectDef(l.findEffect(r.ownerId)->type).params[size_t(r.index)];
    }
    return nullptr;
}

Layer* Composition::findLayer(ObjectId lid) {
    for (auto& l : layers)
        if (l.id == lid) return &l;
    return nullptr;
}
const Layer* Composition::findLayer(ObjectId lid) const {
    return const_cast<Composition*>(this)->findLayer(lid);
}
int Composition::indexOf(ObjectId lid) const {
    for (size_t i = 0; i < layers.size(); ++i)
        if (layers[i].id == lid) return static_cast<int>(i);
    return -1;
}

Composition* Project::findComposition(ObjectId cid) {
    for (auto& c : compositions)
        if (c.id == cid) return &c;
    return nullptr;
}
const Composition* Project::findComposition(ObjectId cid) const {
    return const_cast<Project*>(this)->findComposition(cid);
}
Asset* Project::findAsset(ObjectId aid) {
    for (auto& a : assets)
        if (a.id == aid) return &a;
    return nullptr;
}
const Asset* Project::findAsset(ObjectId aid) const { return const_cast<Project*>(this)->findAsset(aid); }

Layer makeLayer(LayerKind kind, const Composition& comp, ObjectId id, const Asset* asset) {
    Layer l;
    l.id = id;
    l.kind = kind;
    for (int i = 0; i < kPropCount; ++i) l.props[i].value = kPropDefs[i].defaultValue;
    l.prop(PropId::Position).value = {comp.width * 0.5, comp.height * 0.5, 0, 0};
    l.inPoint = 0;
    l.outPoint = comp.duration;
    switch (kind) {
        case LayerKind::Shape: {
            const double s = std::round(std::min(comp.width, comp.height) * 0.35);
            l.prop(PropId::ShapeSize).value = {s, s, 0, 0};
            l.name = "Shape";
            break;
        }
        case LayerKind::Image:
            if (asset) {
                l.asset = asset->id;
                l.name = asset->name;
                l.prop(PropId::AnchorPoint).value = {asset->width * 0.5, asset->height * 0.5, 0, 0};
            } else {
                l.name = "Image";
            }
            break;
        case LayerKind::Null:
            l.name = "Null";
            l.prop(PropId::ShapeSize).value = {100, 100, 0, 0};
            break;
    }
    return l;
}

Project makeDefaultProject(int width, int height, double fps, double duration) {
    Project p;
    Composition c;
    c.id = p.allocateId();
    c.width = width;
    c.height = height;
    c.fps = fps;
    c.duration = duration;
    p.activeComposition = c.id;
    p.compositions.push_back(std::move(c));
    return p;
}

}  // namespace mf
