#include "mf/Evaluator.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <unordered_map>

namespace mf {

namespace {

TextMeasurer& measurer() {
    static TextMeasurer m;
    return m;
}

TextStyle styleFor(const Layer& l, double t) {
    TextStyle st;
    st.text = l.text.string;
    st.font = l.text.font;
    st.align = l.text.align;
    st.size = evaluateProperty(l.prop(PropId::FontSize), PropId::FontSize, t)[0];
    st.tracking = evaluateProperty(l.prop(PropId::Tracking), PropId::Tracking, t)[0];
    st.lineHeight = evaluateProperty(l.prop(PropId::LineHeight), PropId::LineHeight, t)[0];
    return st;
}

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
        case EffectType::GradientRamp: return v[13] >= 100;  // fully blended with the original
        case EffectType::Count: break;
    }
    return true;
}

// Per-frame lookup of compositions by id (imported projects can have thousands).
struct CompIndex {
    const Project& project;
    std::unordered_map<ObjectId, const Composition*> map;
    explicit CompIndex(const Project& p) : project(p) {
        if (p.compositions.size() > 8)
            for (const Composition& c : p.compositions) map.emplace(c.id, &c);
    }
    const Composition* find(ObjectId id) const {
        if (map.empty()) return project.findComposition(id);
        auto it = map.find(id);
        return it == map.end() ? nullptr : it->second;
    }
};

void evaluateLayers(const CompIndex& ix, const Composition& comp, double time, double shutter, const Affine& toTarget,
                    FrameDesc& f, EvalStats* stats, int depth);

// Target-pixel box around everything a nested frame draws (offscreen region of a collapsed precomp).
void nestedTargetBounds(const FrameDesc& nf, Vec2& mn, Vec2& mx) {
    mn = {1e30, 1e30};
    mx = {-1e30, -1e30};
    for (const DrawItem& d : nf.items) {
        const double px = 1.0 / std::sqrt(std::max(std::abs(d.toTarget.determinant()), 1e-12));
        Vec2 a = d.boundsMin, b = d.boundsMax;
        double pad = d.strokeWidth * 0.5 + 2 * px;
        if (d.kind == LayerKind::Text) pad += std::max(b.x - a.x, b.y - a.y) * (d.animatorCount ? 0.75 : 0.1);
        a = {a.x - pad, a.y - pad};
        b = {b.x + pad, b.y + pad};
        const double reach = effectReach(nf, d) + 2;
        for (Vec2 c : {a, Vec2{b.x, a.y}, b, Vec2{a.x, b.y}}) {
            const Vec2 q = d.toTarget.apply(c);
            mn = {std::min(mn.x, q.x - reach), std::min(mn.y, q.y - reach)};
            mx = {std::max(mx.x, q.x + reach), std::max(mx.y, q.y + reach)};
        }
    }
}

// Fills everything except transform/visibility-independent layout. Returns false when the layer
// produces no pixels at `time`.
bool buildItem(const CompIndex& ix, const Composition& comp, const Layer& l, double baseTime, double shutter,
               const Affine& toTarget, FrameDesc& f, DrawItem& d, int depth) {
    const Project& project = ix.project;
    const double time = l.motionBlur ? baseTime + shutter : baseTime;
    if (l.kind == LayerKind::Null || l.kind == LayerKind::Audio) return false;
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
    } else if (l.kind == LayerKind::Precomp) {
        const Composition* src = ix.find(l.source);
        if (!src || src->id == comp.id || depth + 1 >= kMaxNesting) return false;
        auto nf = std::make_shared<FrameDesc>();
        nf->compId = src->id;
        nf->width = f.width;
        nf->height = f.height;
        nf->scale = f.scale;
        nf->time = l.sourceTime(baseTime);
        const double childShutter = (l.motionBlur || l.collapse) ? l.sourceTime(baseTime + shutter) - nf->time : 0;
        evaluateLayers(ix, *src, nf->time, childShutter, d.toTarget, *nf, nullptr, depth + 1);
        if (nf->items.empty()) return false;
        nf->hash = hashFrame(*nf);
        if (l.collapse) {
            // Not clipped: the region is whatever the layers cover, as a box in layer space.
            Vec2 tmn, tmx;
            nestedTargetBounds(*nf, tmn, tmx);
            Affine inv;
            if (!d.toTarget.inverse(inv)) return false;
            d.boundsMin = {1e30, 1e30};
            d.boundsMax = {-1e30, -1e30};
            for (Vec2 c : {tmn, Vec2{tmx.x, tmn.y}, tmx, Vec2{tmn.x, tmx.y}}) {
                const Vec2 q = inv.apply(c);
                d.boundsMin = {std::min(d.boundsMin.x, q.x), std::min(d.boundsMin.y, q.y)};
                d.boundsMax = {std::max(d.boundsMax.x, q.x), std::max(d.boundsMax.y, q.y)};
            }
        }
        d.nested = std::move(nf);
        if (!l.collapse) {
            d.clipSize = {double(src->width), double(src->height)};
        }
    } else if (l.kind == LayerKind::Text) {
        d.text = styleFor(l, time);
        d.fillOn = l.fillEnabled;
        d.fill = l.fillEnabled ? evaluateProperty(l.prop(PropId::FillColor), PropId::FillColor, time) : Value{};
        d.strokeOn = l.strokeEnabled;
        if (d.strokeOn) {
            d.stroke = evaluateProperty(l.prop(PropId::StrokeColor), PropId::StrokeColor, time);
            d.strokeWidth = evaluateProperty(l.prop(PropId::StrokeWidth), PropId::StrokeWidth, time)[0];
            if (d.stroke[3] <= 0 || d.strokeWidth <= 0) {
                d.strokeOn = false;
                d.stroke = {};
                d.strokeWidth = 0;
            }
        }
        d.strokeOverFill = l.text.strokeOverFill;
        if (d.text.text.empty() || (d.fill[3] <= 0 && !d.strokeOn)) return false;
        d.animatorStart = uint32_t(f.animators.size());
        for (const TextAnimator& a : l.animators) {
            if (!a.enabled) continue;
            auto v = [&](AnimParam p) { return evaluateProperty(a.param(p), animParamDef(p), time); };
            AnimatorEval e;
            e.shape = a.shape;
            e.unit = a.unit;
            e.start = v(AnimParam::Start)[0] / 100.0;
            e.end = v(AnimParam::End)[0] / 100.0;
            e.offset = v(AnimParam::Offset)[0] / 100.0;
            e.amount = v(AnimParam::Amount)[0] / 100.0;
            const Value pos = v(AnimParam::Position);
            e.position = {pos[0], pos[1]};
            e.scale = v(AnimParam::Scale)[0] / 100.0;
            e.rotation = v(AnimParam::Rotation)[0];
            e.opacity = v(AnimParam::Opacity)[0] / 100.0;
            const bool noop = e.position.x == 0 && e.position.y == 0 && e.scale == 1 && e.rotation == 0 && e.opacity == 1;
            if (noop) continue;
            if (a.stagger != 0) {
                const int n = std::min(textUnitCount(d.text.text, a.unit), 4096);
                e.unitAmounts.resize(size_t(std::max(n, 1)));
                bool any = false;
                for (int i = 0; i < int(e.unitAmounts.size()); ++i) {
                    const double ti = time - a.stagger * i;
                    e.unitAmounts[size_t(i)] = float(evaluateProperty(a.param(AnimParam::Amount), animParamDef(AnimParam::Amount), ti)[0] / 100.0);
                    any = any || e.unitAmounts[size_t(i)] != 0;
                }
                if (any) f.animators.push_back(std::move(e));
            } else if (e.amount != 0) {
                f.animators.push_back(e);
            }
        }
        d.animatorCount = uint32_t(f.animators.size()) - d.animatorStart;
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
        if (l.shape == ShapeType::Path) {
            d.path = layerPathAt(l, time);
            if (d.path.empty()) return false;
            d.trimStart = evaluateProperty(l.prop(PropId::TrimStart), PropId::TrimStart, time)[0] / 100.0;
            d.trimEnd = evaluateProperty(l.prop(PropId::TrimEnd), PropId::TrimEnd, time)[0] / 100.0;
            d.trimOffset = evaluateProperty(l.prop(PropId::TrimOffset), PropId::TrimOffset, time)[0] / 100.0;
        }
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
        if (m.shape == MaskShape::Path) {
            e.path = maskPathAt(m, time);
            if (e.path.empty()) continue;
        }
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

void hashPath(Hasher& h, const BezierPath& p) {
    h.u64(p.vertices.size() | (uint64_t(p.closed) << 40));
    for (const PathVertex& v : p.vertices)
        for (double x : {v.p.x, v.p.y, v.in.x, v.in.y, v.out.x, v.out.y}) h.f64(x);
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
        if (m.shape == MaskShape::Path) hashPath(h, m.path);
    }
    if (d.shape == ShapeType::Path && d.kind == LayerKind::Shape) {
        hashPath(h, d.path);
        for (double v : {d.trimStart, d.trimEnd, d.trimOffset}) h.f64(v);
    }
    if (d.nested) {
        h.u64(d.nested->hash);
        h.f64(d.clipSize.x);
        h.f64(d.clipSize.y);
    }
    if (d.kind == LayerKind::Text) {
        h.bytes(d.text.text.data(), d.text.text.size());
        h.u64(0x7e47);
        h.bytes(d.text.font.data(), d.text.font.size());
        h.u64(uint64_t(d.text.align) | uint64_t(d.strokeOverFill) << 8);
        for (double v : {d.text.size, d.text.tracking, d.text.lineHeight}) h.f64(v);
        for (uint32_t i = 0; i < d.animatorCount; ++i) {
            const AnimatorEval& a = f.animators[d.animatorStart + i];
            h.u64(uint64_t(a.shape) | uint64_t(a.unit) << 8);
            for (double v : {a.start, a.end, a.offset, a.amount, a.position.x, a.position.y, a.scale, a.rotation, a.opacity})
                h.f64(v);
            if (!a.unitAmounts.empty()) h.bytes(a.unitAmounts.data(), a.unitAmounts.size() * sizeof(float));
        }
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
            if (layer.shape == ShapeType::Path) {
                pathBounds(layerPathAt(layer, time), mn, mx);
                return;
            }
            const Value sz = evaluateProperty(layer.prop(PropId::ShapeSize), PropId::ShapeSize, time);
            mn = {-sz[0] * 0.5, -sz[1] * 0.5};
            mx = {sz[0] * 0.5, sz[1] * 0.5};
            return;
        }
        case LayerKind::Null:
            mn = {0, 0};
            mx = {100, 100};
            return;
        case LayerKind::Text:
            measureText(styleFor(layer, time), mn, mx);
            return;
        case LayerKind::Precomp: {
            const Composition* src = project.findComposition(layer.source);
            mn = {0, 0};
            mx = src ? Vec2{double(src->width), double(src->height)} : Vec2{100, 100};
            return;
        }
        case LayerKind::Audio:
            mn = mx = {0, 0};
            return;
    }
}

BezierPath layerPathAt(const Layer& layer, double time) { return layer.pathTrack ? layer.pathTrack->at(time) : layer.path; }
BezierPath maskPathAt(const Mask& mask, double time) { return mask.pathTrack ? mask.pathTrack->at(time) : mask.path; }

int textUnitCount(const std::string& text, SelectorUnit unit) {
    int chars = 0, words = 0, lines = 1;
    bool inWord = false;
    for (size_t i = 0; i < text.size();) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        const size_t len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        i += len;
        if (c == '\n') {
            ++lines;
            inWord = false;
            continue;
        }
        chars += len == 4 ? 2 : 1;  // UTF-16 units
        const bool space = c == ' ' || c == '\t' || (len == 3 && (c == 0xE2 || c == 0xE3));  // U+2000 spaces, U+3000
        if (!space && !inWord) ++words;
        inWord = !space;
    }
    switch (unit) {
        case SelectorUnit::Characters: return chars;
        case SelectorUnit::Words: return words;
        case SelectorUnit::Lines: return lines;
    }
    return chars;
}

void setTextMeasurer(TextMeasurer m) { measurer() = std::move(m); }

void measureText(const TextStyle& st, Vec2& mn, Vec2& mx) {
    if (measurer()) {
        measurer()(st, mn, mx);
        return;
    }
    // Estimate: 0.55 em per character, ascent 0.75 em, descent 0.25 em.
    size_t lines = 1, longest = 0, cur = 0;
    for (char ch : st.text) {
        if (ch == '\n') {
            ++lines;
            cur = 0;
        } else {
            longest = std::max(longest, ++cur);
        }
    }
    const double w = longest * st.size * (0.55 + st.tracking / 1000.0);
    const double x0 = st.align == TextAlign::Left ? 0 : st.align == TextAlign::Center ? -w / 2 : -w;
    mn = {x0, -0.75 * st.size};
    mx = {x0 + w, (double(lines) - 1) * st.size * st.lineHeight + 0.25 * st.size};
}

namespace {

// A precomp that can be drawn as if its layers were this composition's own: collapsed, fully
// opaque, normal blending, nothing applied to it as a whole.
bool splicePrecomp(const Layer& l, double time) {
    if (!l.collapse || l.blend != BlendMode::Normal || l.hasMatte()) return false;
    for (const Mask& m : l.masks)
        if (m.enabled) return false;
    for (const Effect& e : l.effects)
        if (e.enabled) return false;
    return evaluateProperty(l.prop(PropId::Opacity), PropId::Opacity, time)[0] >= 100 - 1e-9;
}

void evaluateLayers(const CompIndex& ix, const Composition& comp, double time, double shutter, const Affine& toTarget,
                    FrameDesc& f, EvalStats* stats, int depth) {
    // layers[0] is the top of the stack, so paint from the back.
    for (auto it = comp.layers.rbegin(); it != comp.layers.rend(); ++it) {
        const Layer& l = *it;
        if (stats) ++stats->layersVisited;
        if (!l.activeAt(time)) continue;
        if (l.kind == LayerKind::Precomp && splicePrecomp(l, time)) {
            const Composition* src = ix.find(l.source);
            if (src && src->id != comp.id && depth + 1 < kMaxNesting) {
                const double tl = l.motionBlur ? time + shutter : time;
                const Affine m = toTarget * layerWorldTransform(comp, l, tl);
                const double st = l.sourceTime(time);
                if (std::abs(m.determinant()) >= 1e-12)
                    evaluateLayers(ix, *src, st, l.sourceTime(time + shutter) - st, m, f, stats, depth + 1);
            }
            continue;
        }
        DrawItem d;
        if (!buildItem(ix, comp, l, time, shutter, toTarget, f, d, depth)) continue;

        if (l.hasMatte()) {
            const Layer* src = comp.findLayer(l.matteLayer);
            DrawItem m;
            // A matte source draws through its user even when its own visibility is off.
            const bool have = src && src->id != l.id && src->inTimeRange(time) &&
                              buildItem(ix, comp, *src, time, shutter, toTarget, f, m, depth);
            const bool inverted = l.matteMode == MatteMode::AlphaInverted || l.matteMode == MatteMode::LumaInverted;
            if (have) {
                d.matte = int32_t(f.mattes.size());
                d.matteMode = l.matteMode;
                f.mattes.push_back(m);
            } else if (!inverted) {
                continue;  // an empty matte hides the layer entirely
            }
        }
        f.items.push_back(std::move(d));
    }
}

}  // namespace

FrameDesc evaluateFrame(const Project& project, const Composition& comp, double time, double scale,
                        EvalStats* stats, double shutterOffset) {
    FrameDesc f;
    f.compId = comp.id;
    f.scale = scale;
    f.time = time;
    f.width = std::max(1, static_cast<int>(std::lround(comp.width * scale)));
    f.height = std::max(1, static_cast<int>(std::lround(comp.height * scale)));
    const Affine toTarget = Affine::scale(f.width / double(comp.width), f.height / double(comp.height));
    f.items.reserve(comp.layers.size());
    const CompIndex ix(project);
    evaluateLayers(ix, comp, time, shutterOffset, toTarget, f, stats, 0);
    if (stats) stats->itemsEmitted += static_cast<int>(f.items.size());
    f.hash = hashFrame(f);
    return f;
}

std::vector<double> motionBlurOffsets(const Project& project, const Composition& comp) {
    if (!comp.motionBlur || comp.motionBlurSamples <= 1 || comp.shutterAngle <= 0) return {0.0};
    // Any layer with its switch on, here or in a precomp shown here?
    const CompIndex ix(project);
    std::vector<const Composition*> stack{&comp}, seen;
    bool any = false;
    while (!stack.empty() && !any) {
        const Composition* c = stack.back();
        stack.pop_back();
        if (std::find(seen.begin(), seen.end(), c) != seen.end()) continue;
        seen.push_back(c);
        for (const Layer& l : c->layers) {
            any = any || l.motionBlur;
            if (l.kind == LayerKind::Precomp)
                if (const Composition* s = ix.find(l.source)) stack.push_back(s);
        }
    }
    if (!any) return {0.0};
    std::vector<double> out;
    const int n = comp.motionBlurSamples;
    for (int k = 0; k < n; ++k)
        out.push_back((comp.shutterPhase + comp.shutterAngle * (k + 0.5) / n) / 360.0 / comp.fps);
    return out;
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

namespace {

// `nulls`: whether null layers count (they are selectable at the top level, but inside a precomp
// only drawn content makes it "hit").
ObjectId hitTestIn(const Project& project, const Composition& comp, double time, Vec2 p, bool nulls, int depth) {
    for (const Layer& l : comp.layers) {  // top first
        if (!l.activeAt(time) || l.kind == LayerKind::Audio || (!nulls && l.kind == LayerKind::Null)) continue;
        if (l.kind != LayerKind::Null && evaluateProperty(l.prop(PropId::Opacity), PropId::Opacity, time)[0] <= 0) continue;
        Affine inv;
        if (!layerWorldTransform(comp, l, time).inverse(inv)) continue;
        const Vec2 q = inv.apply(p);
        Vec2 mn, mx;
        layerLocalBounds(project, l, time, mn, mx);
        if (l.kind == LayerKind::Precomp) {
            // Hit where the precomp draws something, not anywhere in its frame (collapsed precomps
            // aren't clipped to it at all).
            const Composition* src = project.findComposition(l.source);
            if (!src || src->id == comp.id || depth + 1 >= kMaxNesting) continue;
            if (!l.collapse && (q.x < mn.x || q.y < mn.y || q.x > mx.x || q.y > mx.y)) continue;
            if (hitTestIn(project, *src, l.sourceTime(time), q, false, depth + 1) == 0) continue;
            return l.id;
        }
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

}  // namespace

ObjectId hitTest(const Project& project, const Composition& comp, double time, Vec2 p) {
    return hitTestIn(project, comp, time, p, true, 0);
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
