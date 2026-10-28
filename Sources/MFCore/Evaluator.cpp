#include "mf/Evaluator.hpp"

#include <bit>
#include <cmath>
#include <cstring>

namespace mf {

namespace {

Affine localTransform(const Layer& l, double t) {
    const Value anchor = evaluateProperty(l.prop(PropId::AnchorPoint), PropId::AnchorPoint, t);
    const Value pos = evaluateProperty(l.prop(PropId::Position), PropId::Position, t);
    const Value scl = evaluateProperty(l.prop(PropId::Scale), PropId::Scale, t);
    const Value rot = evaluateProperty(l.prop(PropId::Rotation), PropId::Rotation, t);
    return Affine::translate(pos[0], pos[1]) * Affine::rotateDegrees(rot[0]) *
           Affine::scale(scl[0] / 100.0, scl[1] / 100.0) * Affine::translate(-anchor[0], -anchor[1]);
}

struct Hasher {
    uint64_t h = 1469598103934665603ull;
    void bytes(const void* p, size_t n) {
        const auto* c = static_cast<const unsigned char*>(p);
        for (size_t i = 0; i < n; ++i) {
            h ^= c[i];
            h *= 1099511628211ull;
        }
    }
    void u64(uint64_t v) { bytes(&v, sizeof v); }
    // Normalise -0.0 to 0.0 so equal values always hash equally.
    void f64(double v) { u64(v == 0 ? 0 : std::bit_cast<uint64_t>(v)); }
};

// Effects that would not change a single pixel are dropped, so they cost nothing and leave the
// frame hash (and therefore the cache) untouched.
bool effectIsNoop(const EffectEval& e) {
    const auto& v = e.v;
    switch (e.type) {
        case EffectType::GaussianBlur: return v[0] < 0.05;
        case EffectType::DropShadow: return v[3] <= 0 || v[4] <= 0;  // colour alpha, opacity
        case EffectType::Glow: return v[2] <= 0;                      // intensity
        case EffectType::BrightnessContrast: return v[0] == 0 && v[1] == 0;
        case EffectType::HueSaturation: return std::fmod(v[0], 360.0) == 0 && v[1] == 0 && v[2] == 0;
        case EffectType::Fill: return v[3] <= 0 || v[4] <= 0;
        case EffectType::Count: break;
    }
    return true;
}

// Fills everything except transform/visibility-independent layout. Returns false when the layer
// produces no pixels at `time`.
bool buildItem(const Project& project, const Composition& comp, const Layer& l, double time, const Affine& toTarget,
               FrameDesc& f, DrawItem& d) {
    if (l.kind == LayerKind::Null) return false;
    d.layerId = l.id;
    d.kind = l.kind;
    d.shape = l.shape;
    d.blend = l.blend;
    d.opacity = evaluateProperty(l.prop(PropId::Opacity), PropId::Opacity, time)[0] / 100.0;
    if (d.opacity <= 0) return false;
    d.toTarget = toTarget * layerWorldTransform(comp, l, time);
    if (std::abs(d.toTarget.determinant()) < 1e-12) return false;  // collapsed by a 0% scale
    layerLocalBounds(project, l, time, d.boundsMin, d.boundsMax);

    if (l.kind == LayerKind::Image) {
        const Asset* a = project.findAsset(l.asset);
        if (!a || a->missing || a->width <= 0 || a->height <= 0) return false;
        d.asset = a->id;
        d.assetGeneration = a->generation;
    } else {
        d.fillOn = l.fillEnabled;
        d.strokeOn = l.strokeEnabled;
        d.fill = evaluateProperty(l.prop(PropId::FillColor), PropId::FillColor, time);
        d.stroke = evaluateProperty(l.prop(PropId::StrokeColor), PropId::StrokeColor, time);
        d.strokeWidth = d.strokeOn ? evaluateProperty(l.prop(PropId::StrokeWidth), PropId::StrokeWidth, time)[0] : 0;
        d.roundness = evaluateProperty(l.prop(PropId::Roundness), PropId::Roundness, time)[0];
        d.points = std::round(evaluateProperty(l.prop(PropId::Points), PropId::Points, time)[0]);
        d.innerRatio = evaluateProperty(l.prop(PropId::InnerRatio), PropId::InnerRatio, time)[0];
        if (!d.fillOn) d.fill = {0, 0, 0, 0};
        if (!d.strokeOn) d.stroke = {0, 0, 0, 0};
        if (d.fill[3] <= 0 && (d.stroke[3] <= 0 || d.strokeWidth <= 0)) return false;
    }

    d.maskStart = uint32_t(f.masks.size());
    for (const Mask& m : l.masks) {
        if (!m.enabled) continue;
        MaskEval e;
        e.shape = m.shape;
        e.mode = m.mode;
        e.inverted = m.inverted;
        const Value pos = evaluateProperty(m.param(MaskParam::Position), maskParamDef(MaskParam::Position), time);
        const Value size = evaluateProperty(m.param(MaskParam::Size), maskParamDef(MaskParam::Size), time);
        e.center = {pos[0], pos[1]};
        e.halfSize = {size[0] * 0.5, size[1] * 0.5};
        e.roundness = evaluateProperty(m.param(MaskParam::Roundness), maskParamDef(MaskParam::Roundness), time)[0];
        e.feather = evaluateProperty(m.param(MaskParam::Feather), maskParamDef(MaskParam::Feather), time)[0];
        e.expansion = evaluateProperty(m.param(MaskParam::Expansion), maskParamDef(MaskParam::Expansion), time)[0];
        e.opacity = evaluateProperty(m.param(MaskParam::Opacity), maskParamDef(MaskParam::Opacity), time)[0] / 100.0;
        f.masks.push_back(e);
    }
    d.maskCount = uint32_t(f.masks.size()) - d.maskStart;

    d.effectStart = uint32_t(f.effects.size());
    for (const Effect& fx : l.effects) {
        if (!fx.enabled) continue;
        const EffectDef& def = effectDef(fx.type);
        EffectEval e;
        e.type = fx.type;
        size_t slot = 0;
        for (size_t i = 0; i < def.params.size() && i < fx.params.size(); ++i) {
            const Value v = evaluateProperty(fx.params[i], def.params[i], time);
            for (int k = 0; k < def.params[i].dims && slot < e.v.size(); ++k) e.v[slot++] = v[size_t(k)];
        }
        if (!effectIsNoop(e)) f.effects.push_back(e);
    }
    d.effectCount = uint32_t(f.effects.size()) - d.effectStart;
    return true;
}

void hashItem(Hasher& h, const FrameDesc& f, const DrawItem& d) {
    h.u64(static_cast<uint64_t>(d.kind) | static_cast<uint64_t>(d.shape) << 8 | static_cast<uint64_t>(d.blend) << 16 |
          static_cast<uint64_t>(d.fillOn) << 24 | static_cast<uint64_t>(d.strokeOn) << 25 |
          static_cast<uint64_t>(d.matteMode) << 32);
    for (double v : {d.toTarget.a, d.toTarget.b, d.toTarget.c, d.toTarget.d, d.toTarget.tx, d.toTarget.ty, d.opacity,
                     d.boundsMin.x, d.boundsMin.y, d.boundsMax.x, d.boundsMax.y, d.strokeWidth, d.roundness, d.points,
                     d.innerRatio})
        h.f64(v);
    for (int i = 0; i < 4; ++i) {
        h.f64(d.fill[i]);
        h.f64(d.stroke[i]);
    }
    h.u64(d.asset);
    h.u64(d.assetGeneration);
    h.u64(d.maskCount);
    for (uint32_t i = 0; i < d.maskCount; ++i) {
        const MaskEval& m = f.masks[d.maskStart + i];
        h.u64(uint64_t(m.shape) | uint64_t(m.mode) << 8 | uint64_t(m.inverted) << 16);
        for (double v : {m.center.x, m.center.y, m.halfSize.x, m.halfSize.y, m.roundness, m.feather, m.expansion, m.opacity})
            h.f64(v);
    }
    h.u64(d.effectCount);
    for (uint32_t i = 0; i < d.effectCount; ++i) {
        const EffectEval& e = f.effects[d.effectStart + i];
        h.u64(uint64_t(e.type));
        for (double v : e.v) h.f64(v);
    }
    if (d.matte >= 0) hashItem(h, f, f.mattes[size_t(d.matte)]);
    // layerId is deliberately not hashed: two layers drawing identical pixels are identical frames.
}

}  // namespace

int FrameDesc::offscreenItems() const {
    int n = 0;
    for (const DrawItem& d : items) n += d.needsOffscreen() ? 1 : 0;
    return n;
}

Affine layerWorldTransform(const Composition& comp, const Layer& layer, double time) {
    Affine m = localTransform(layer, time);
    ObjectId parent = layer.parent;
    for (int depth = 0; parent != 0 && depth < 64; ++depth) {
        const Layer* p = comp.findLayer(parent);
        if (!p) break;
        m = localTransform(*p, time) * m;
        parent = p->parent;
    }
    return m;
}

void layerLocalBounds(const Project& project, const Layer& layer, double time, Vec2& mn, Vec2& mx) {
    switch (layer.kind) {
        case LayerKind::Image: {
            const Asset* a = project.findAsset(layer.asset);
            const double w = a ? a->width : 0, h = a ? a->height : 0;
            mn = {0, 0};
            mx = {w, h};
            return;
        }
        case LayerKind::Shape: {
            const Value sz = evaluateProperty(layer.prop(PropId::ShapeSize), PropId::ShapeSize, time);
            mn = {-sz[0] * 0.5, -sz[1] * 0.5};
            mx = {sz[0] * 0.5, sz[1] * 0.5};
            return;
        }
        case LayerKind::Null:
            mn = {0, 0};
            mx = {100, 100};
            return;
    }
}

FrameDesc evaluateFrame(const Project& project, const Composition& comp, double time, double scale,
                        EvalStats* stats) {
    FrameDesc f;
    f.compId = comp.id;
    f.scale = scale;
    f.time = time;
    f.width = std::max(1, static_cast<int>(std::lround(comp.width * scale)));
    f.height = std::max(1, static_cast<int>(std::lround(comp.height * scale)));
    const Affine toTarget = Affine::scale(f.width / double(comp.width), f.height / double(comp.height));

    f.items.reserve(comp.layers.size());
    // layers[0] is the top of the stack, so paint from the back.
    for (auto it = comp.layers.rbegin(); it != comp.layers.rend(); ++it) {
        const Layer& l = *it;
        if (stats) ++stats->layersVisited;
        if (!l.activeAt(time)) continue;
        DrawItem d;
        if (!buildItem(project, comp, l, time, toTarget, f, d)) continue;

        if (l.hasMatte()) {
            const Layer* src = comp.findLayer(l.matteLayer);
            DrawItem m;
            // A matte source draws through its user even when its own visibility is off.
            const bool have = src && src->id != l.id && src->inTimeRange(time) &&
                              buildItem(project, comp, *src, time, toTarget, f, m);
            const bool inverted = l.matteMode == MatteMode::AlphaInverted || l.matteMode == MatteMode::LumaInverted;
            if (have) {
                d.matte = int32_t(f.mattes.size());
                d.matteMode = l.matteMode;
                f.mattes.push_back(m);
            } else if (!inverted) {
                continue;  // an empty matte hides the layer entirely
            }
        }
        f.items.push_back(d);
    }
    if (stats) stats->itemsEmitted += static_cast<int>(f.items.size());
    f.hash = hashFrame(f);
    return f;
}

double effectScale(const DrawItem& d) { return std::sqrt(std::abs(d.toTarget.determinant())); }

double effectReach(const FrameDesc& f, const DrawItem& d) {
    const double k = effectScale(d);
    double reach = 0;
    for (uint32_t i = 0; i < d.effectCount; ++i) {
        const EffectEval& e = f.effects[d.effectStart + i];
        switch (e.type) {
            case EffectType::GaussianBlur: reach += e.v[0] * k; break;
            case EffectType::DropShadow: reach += (e.v[6] + e.v[7]) * k; break;  // distance + softness
            case EffectType::Glow: reach += e.v[1] * k; break;
            default: break;
        }
    }
    return reach;
}

uint64_t hashFrame(const FrameDesc& f) {
    Hasher h;
    h.u64(f.compId);
    h.u64(static_cast<uint64_t>(f.width) << 32 | static_cast<uint32_t>(f.height));
    h.u64(f.items.size());
    for (const DrawItem& d : f.items) hashItem(h, f, d);
    return h.h;
}

ObjectId hitTest(const Project& project, const Composition& comp, double time, Vec2 p) {
    for (const Layer& l : comp.layers) {  // top first
        if (!l.activeAt(time)) continue;
        Affine inv;
        if (!layerWorldTransform(comp, l, time).inverse(inv)) continue;
        const Vec2 q = inv.apply(p);
        Vec2 mn, mx;
        layerLocalBounds(project, l, time, mn, mx);
        if (q.x < mn.x || q.y < mn.y || q.x > mx.x || q.y > mx.y) continue;
        if (l.kind == LayerKind::Shape && l.shape == ShapeType::Ellipse) {
            const double rx = (mx.x - mn.x) * 0.5, ry = (mx.y - mn.y) * 0.5;
            if (rx <= 0 || ry <= 0) continue;
            const double ex = (q.x - (mn.x + rx)) / rx, ey = (q.y - (mn.y + ry)) / ry;
            if (ex * ex + ey * ey > 1) continue;
        }
        return l.id;
    }
    return 0;
}

std::array<Vec2, 4> layerCorners(const Project& project, const Composition& comp, const Layer& layer, double time) {
    Vec2 mn, mx;
    layerLocalBounds(project, layer, time, mn, mx);
    const Affine m = layerWorldTransform(comp, layer, time);
    return {m.apply({mn.x, mn.y}), m.apply({mx.x, mn.y}), m.apply({mx.x, mx.y}), m.apply({mn.x, mx.y})};
}

std::array<Vec2, 4> maskCorners(const Composition& comp, const Layer& layer, const Mask& mask, double time) {
    const Value pos = evaluateProperty(mask.param(MaskParam::Position), maskParamDef(MaskParam::Position), time);
    const Value size = evaluateProperty(mask.param(MaskParam::Size), maskParamDef(MaskParam::Size), time);
    const double hx = size[0] * 0.5, hy = size[1] * 0.5;
    const Affine m = layerWorldTransform(comp, layer, time);
    return {m.apply({pos[0] - hx, pos[1] - hy}), m.apply({pos[0] + hx, pos[1] - hy}), m.apply({pos[0] + hx, pos[1] + hy}),
            m.apply({pos[0] - hx, pos[1] + hy})};
}

}  // namespace mf
