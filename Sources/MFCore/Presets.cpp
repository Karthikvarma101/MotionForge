#include "mf/Presets.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include "mf/Evaluator.hpp"
#include "mf/Json.hpp"
#include "mf/ProjectIO.hpp"

namespace mf {

namespace {

constexpr const char* kFormat = "motionforge.preset";

bool relativeProp(PropId id) { return id == PropId::Position || id == PropId::AnchorPoint || id == PropId::Rotation; }

void earliest(const Property& p, double& t0) {
    for (const Keyframe& k : p.keyframes) t0 = std::min(t0, k.time);
}

// Property as JSON with key times shifted by -t0 and, for relative tracks, values minus `base`.
Json shiftedProperty(const Property& p, const PropDef& def, double t0, const Value* base) {
    Json o = Json::object();
    Json v = Json::array();
    for (int i = 0; i < def.dims; ++i) v.push(Json(p.value[size_t(i)]));
    o.set("value", std::move(v));
    if (!p.keyframes.empty()) {
        Json keys = Json::array();
        for (Keyframe k : p.keyframes) {
            k.time -= t0;
            if (base)
                for (int i = 0; i < def.dims; ++i) k.value[size_t(i)] -= (*base)[size_t(i)];
            keys.push(keyframeToJson(k, def));
        }
        o.set("keyframes", std::move(keys));
    }
    return o;
}

// Keys from shifted JSON, placed at `time` (and offset by `base` for relative tracks).
std::vector<Keyframe> placedKeys(const Json& pj, double time, double fps, const Value* base, const Value& fallback) {
    std::vector<Keyframe> keys;
    for (const Json& kj : pj.get("keyframes").items()) {
        Keyframe k = keyframeFromJson(kj, fallback);
        k.time = std::round((k.time + time) * fps) / fps;
        if (base)
            for (int i = 0; i < 4; ++i) k.value[size_t(i)] += (*base)[size_t(i)];
        keys.push_back(k);
    }
    return keys;
}

Value staticValue(const Json& pj, const Value& fallback) {
    Value v = fallback;
    const auto& items = pj.get("value").items();
    for (size_t i = 0; i < std::min<size_t>(items.size(), 4); ++i) v[i] = items[i].number(fallback[i]);
    return v;
}

}  // namespace

std::string makePreset(const Project& project, ObjectId comp, ObjectId layerId, const std::string& name,
                       const std::string& category) {
    const Composition* c = project.findComposition(comp);
    const Layer* l = c ? c->findLayer(layerId) : nullptr;
    if (!l) return {};
    double t0 = std::numeric_limits<double>::infinity();
    for (const Property& p : l->props) earliest(p, t0);
    for (const Effect& e : l->effects)
        for (const Property& p : e.params) earliest(p, t0);
    for (const TextAnimator& a : l->animators)
        for (const Property& p : a.params) earliest(p, t0);
    if (!std::isfinite(t0)) t0 = 0;

    Json root = Json::object();
    root.set("format", Json(kFormat));
    root.set("version", Json(1));
    root.set("name", Json(name));
    root.set("category", Json(category));
    Json tracks = Json::array();
    for (int i = 0; i < kPropCount; ++i) {
        const auto id = static_cast<PropId>(i);
        const Property& p = l->props[size_t(i)];
        if (!p.animated()) continue;
        const PropDef& def = propDef(id);
        Json tj = Json::object();
        tj.set("property", Json(def.key));
        const bool rel = relativeProp(id);
        tj.set("relative", Json(rel));
        // Entrances end on the layer's own value; everything else starts from it.
        const Value base = category == "Entrances" ? p.keyframes.back().value : p.keyframes.front().value;
        tj.set("track", shiftedProperty(p, def, t0, rel ? &base : nullptr));
        tracks.push(std::move(tj));
    }
    root.set("tracks", std::move(tracks));
    Json effects = Json::array();
    for (const Effect& e : l->effects) {
        const EffectDef& def = effectDef(e.type);
        Json ej = Json::object();
        ej.set("type", Json(def.key));
        ej.set("enabled", Json(e.enabled));
        Json params = Json::object();
        for (size_t k = 0; k < def.params.size() && k < e.params.size(); ++k)
            params.set(def.params[k].key, shiftedProperty(e.params[k], def.params[k], t0, nullptr));
        ej.set("params", std::move(params));
        effects.push(std::move(ej));
    }
    root.set("effects", std::move(effects));
    Json animators = Json::array();
    for (const TextAnimator& a : l->animators) {
        Json aj = Json::object();
        aj.set("shape", Json(selectorShapeKey(a.shape)));
        aj.set("unit", Json(selectorUnitKey(a.unit)));
        Json params = Json::object();
        for (int k = 0; k < kAnimParamCount; ++k) {
            const PropDef& def = animParamDef(static_cast<AnimParam>(k));
            params.set(def.key, shiftedProperty(a.params[size_t(k)], def, t0, nullptr));
        }
        aj.set("params", std::move(params));
        animators.push(std::move(aj));
    }
    root.set("animators", std::move(animators));
    return root.dump(2);
}

bool presetHeader(const std::string& json, std::string& name, std::string& category) {
    Json root;
    std::string err;
    if (!Json::parse(json, root, err) || root.get("format").string() != kFormat) return false;
    name = root.get("name").string();
    category = root.get("category").string();
    return true;
}

int applyPreset(Document& doc, ObjectId comp, const std::vector<ObjectId>& layers, double time, const std::string& json,
                std::string& error) {
    Json root;
    if (!Json::parse(json, root, error) || root.get("format").string() != kFormat) {
        error = "Not a MotionForge preset";
        return 0;
    }
    const Composition* c0 = doc.project().findComposition(comp);
    if (!c0) return 0;
    const double fps = c0->fps;
    int applied = 0;
    std::vector<std::string> skipped;
    doc.beginGroup("Apply Preset: " + root.get("name").string());
    for (ObjectId lid : layers) {
        const Layer* l = doc.project().findComposition(comp)->findLayer(lid);
        if (!l || l->kind == LayerKind::Null) continue;
        std::vector<std::pair<PropRef, std::vector<Keyframe>>> tracks;

        for (const Json& tj : root.get("tracks").items()) {
            const auto id = propFromKey(tj.get("property").string());
            if (!id) continue;
            const Json& pj = tj.get("track");
            const Layer* cur = doc.project().findComposition(comp)->findLayer(lid);
            const Value base = evaluateProperty(cur->prop(*id), *id, time);
            const bool rel = tj.get("relative").boolean(false);
            tracks.push_back({PropRef::layer(*id), placedKeys(pj, time, fps, rel ? &base : nullptr, base)});
        }
        for (const Json& ej : root.get("effects").items()) {
            const auto type = effectTypeFromKey(ej.get("type").string());
            if (!type) continue;
            const ObjectId fx = doc.addEffect(comp, lid, *type);
            if (!fx) continue;
            ++applied;
            doc.setEffectEnabled(comp, lid, fx, ej.get("enabled").boolean(true));
            const auto& params = effectDef(*type).params;
            for (size_t k = 0; k < params.size(); ++k) {
                const Json& pj = ej.get("params").get(params[k].key);
                if (pj.isNull()) continue;
                const PropRef ref = PropRef::effect(fx, int(k));
                doc.setPropertyValue(comp, lid, ref, time, staticValue(pj, params[k].defaultValue));
                auto keys = placedKeys(pj, time, fps, nullptr, params[k].defaultValue);
                if (!keys.empty()) tracks.push_back({ref, std::move(keys)});
            }
        }
        for (const Json& aj : root.get("animators").items()) {
            if (l->kind != LayerKind::Text) {
                skipped.push_back("text animators (\"" + l->name + "\" is not a text layer)");
                break;
            }
            const ObjectId an = doc.addTextAnimator(comp, lid, Document::AnimatorPreset::Opacity);
            if (!an) continue;
            ++applied;
            doc.setTextAnimatorOptions(comp, lid, an, true,
                                       selectorShapeFromKey(aj.get("shape").string()).value_or(SelectorShape::Square),
                                       selectorUnitFromKey(aj.get("unit").string()).value_or(SelectorUnit::Characters));
            for (int k = 0; k < kAnimParamCount; ++k) {
                const PropDef& def = animParamDef(static_cast<AnimParam>(k));
                const Json& pj = aj.get("params").get(def.key);
                if (pj.isNull()) continue;
                const PropRef ref = PropRef::animator(an, static_cast<AnimParam>(k));
                doc.setPropertyValue(comp, lid, ref, time, staticValue(pj, def.defaultValue));
                auto keys = placedKeys(pj, time, fps, nullptr, def.defaultValue);
                if (!keys.empty()) tracks.push_back({ref, std::move(keys)});
            }
        }
        applied += doc.insertKeyframes(comp, lid, tracks);
    }
    doc.endGroup();
    if (!skipped.empty()) {
        std::sort(skipped.begin(), skipped.end());
        skipped.erase(std::unique(skipped.begin(), skipped.end()), skipped.end());
        error = "Skipped: ";
        for (size_t i = 0; i < skipped.size(); ++i) error += (i ? "; " : "") + skipped[i];
    }
    return applied;
}

// ---------------------------------------------------------------------------------------------
// Built-ins, made with the same editing calls as the app.

namespace {

struct Builder {
    Document d{makeDefaultProject(1920, 1080, 30, 10)};
    ObjectId comp = d.project().activeComposition;
    ObjectId layer;
    explicit Builder(LayerKind kind) { layer = d.addLayer(comp, kind); }
    PropRef L(PropId p) { return PropRef::layer(p); }
    void keys(PropRef ref, std::initializer_list<std::pair<double, Value>> ks, bool ease = true) {
        d.setPropertyAnimated(comp, layer, ref, true, ks.begin()->first);
        for (const auto& [t, v] : ks) d.setPropertyValue(comp, layer, ref, t, v);
        if (!ease) return;
        const Layer* l = d.project().activeComp()->findLayer(layer);
        const int n = int(resolveProperty(*l, ref)->keyframes.size());
        for (int i = 0; i < n; ++i) d.setKeyframeInterpolation(comp, layer, ref, i, Interp::Bezier, Interp::Bezier);
    }
    PresetInfo done(const char* name, const char* category, const char* summary) {
        return {name, category, summary, makePreset(d.project(), comp, layer, name, category)};
    }
};

Value v1(double x) { return {x, 0, 0, 0}; }
Value v2(double x, double y) { return {x, y, 0, 0}; }

std::vector<PresetInfo> makeBuiltIns() {
    std::vector<PresetInfo> out;
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Opacity), {{0, v1(0)}, {0.5, v1(100)}});
        out.push_back(b.done("Fade In", "Entrances", "Opacity 0 → 100% over 0.5 s, eased."));
    }
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Scale), {{0, v2(0, 0)}, {0.27, v2(112, 112)}, {0.43, v2(100, 100)}});
        b.keys(b.L(PropId::Opacity), {{0, v1(0)}, {0.13, v1(100)}});
        out.push_back(b.done("Pop In", "Entrances", "Scales up with a small overshoot."));
    }
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Position), {{0, v2(960, 660)}, {0.6, v2(960, 540)}});
        b.keys(b.L(PropId::Opacity), {{0, v1(0)}, {0.4, v1(100)}});
        out.push_back(b.done("Slide Up", "Entrances", "Rises 120 px into place and fades in."));
    }
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Rotation), {{0, v1(-180)}, {0.6, v1(0)}});
        b.keys(b.L(PropId::Scale), {{0, v2(0, 0)}, {0.6, v2(100, 100)}});
        out.push_back(b.done("Spin In", "Entrances", "Half a turn while scaling up from nothing."));
    }
    {
        Builder b(LayerKind::Shape);
        const ObjectId fx = b.d.addEffect(b.comp, b.layer, EffectType::GaussianBlur);
        b.keys(PropRef::effect(fx, 0), {{0, v1(60)}, {0.6, v1(0)}});
        b.keys(b.L(PropId::Opacity), {{0, v1(0)}, {0.4, v1(100)}});
        out.push_back(b.done("Blur In", "Entrances", "Comes into focus from a 60 px blur."));
    }
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Opacity), {{0, v1(100)}, {0.5, v1(0)}});
        out.push_back(b.done("Fade Out", "Exits", "Opacity 100 → 0% over 0.5 s, eased."));
    }
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Position), {{0, v2(960, 540)}, {0.5, v2(960, 420)}});
        b.keys(b.L(PropId::Opacity), {{0.1, v1(100)}, {0.5, v1(0)}});
        out.push_back(b.done("Slide Out Up", "Exits", "Rises 120 px and fades out."));
    }
    {
        Builder b(LayerKind::Shape);
        const ObjectId fx = b.d.addEffect(b.comp, b.layer, EffectType::Glow);
        b.d.setPropertyValue(b.comp, b.layer, PropRef::effect(fx, 1), 0, v1(60));
        b.keys(PropRef::effect(fx, 2), {{0, v1(40)}, {0.5, v1(170)}, {1.0, v1(40)}});
        out.push_back(b.done("Glow Pulse", "Attention", "One soft glow pulse over a second."));
    }
    {
        Builder b(LayerKind::Shape);
        b.keys(b.L(PropId::Scale), {{0, v2(100, 100)}, {0.12, v2(112, 112)}, {0.24, v2(96, 96)}, {0.36, v2(100, 100)}});
        out.push_back(b.done("Bounce", "Attention", "A quick squash-and-settle scale bounce."));
    }
    {
        Builder b(LayerKind::Shape);
        const ObjectId fx = b.d.addEffect(b.comp, b.layer, EffectType::DropShadow);
        b.d.setPropertyValue(b.comp, b.layer, PropRef::effect(fx, 1), 0, v1(45));
        b.d.setPropertyValue(b.comp, b.layer, PropRef::effect(fx, 3), 0, v1(18));
        b.d.setPropertyValue(b.comp, b.layer, PropRef::effect(fx, 4), 0, v1(42));
        out.push_back(b.done("Soft Shadow", "Styles", "A soft drop shadow (no animation)."));
    }
    {
        Builder b(LayerKind::Text);
        const ObjectId an = b.d.addTextAnimator(b.comp, b.layer, Document::AnimatorPreset::Opacity);
        b.keys(PropRef::animator(an, AnimParam::Start), {{0, v1(0)}, {1.5, v1(100)}}, false);
        out.push_back(b.done("Typewriter", "Text", "Characters appear one by one over 1.5 s."));
    }
    {
        Builder b(LayerKind::Text);
        const ObjectId an = b.d.addTextAnimator(b.comp, b.layer, Document::AnimatorPreset::Opacity);
        b.d.setPropertyValue(b.comp, b.layer, PropRef::animator(an, AnimParam::Position), 0, v2(0, 60));
        b.d.setPropertyValue(b.comp, b.layer, PropRef::animator(an, AnimParam::End), 0, v1(30));
        b.d.setTextAnimatorOptions(b.comp, b.layer, an, true, SelectorShape::RampUp, SelectorUnit::Characters);
        b.keys(PropRef::animator(an, AnimParam::Offset), {{0, v1(-30)}, {1.2, v1(100)}}, false);
        out.push_back(b.done("Fade Up by Character", "Text", "A soft wave of characters rising into place."));
    }
    {
        Builder b(LayerKind::Text);
        const ObjectId an = b.d.addTextAnimator(b.comp, b.layer, Document::AnimatorPreset::Scale);
        b.d.setPropertyValue(b.comp, b.layer, PropRef::animator(an, AnimParam::Opacity), 0, v1(0));
        b.d.setPropertyValue(b.comp, b.layer, PropRef::animator(an, AnimParam::End), 0, v1(25));
        b.d.setTextAnimatorOptions(b.comp, b.layer, an, true, SelectorShape::RampUp, SelectorUnit::Words);
        b.keys(PropRef::animator(an, AnimParam::Offset), {{0, v1(-25)}, {1.0, v1(100)}}, false);
        out.push_back(b.done("Pop by Word", "Text", "Words pop in one after another."));
    }
    return out;
}

}  // namespace

const std::vector<PresetInfo>& builtInPresets() {
    static const std::vector<PresetInfo> presets = makeBuiltIns();
    return presets;
}

}  // namespace mf
