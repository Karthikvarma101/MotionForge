#include "mf/Clipboard.hpp"

#include <algorithm>
#include <limits>
#include <map>

#include "mf/Json.hpp"
#include "mf/ProjectIO.hpp"

namespace mf {

namespace {

constexpr const char* kLayersFormat = "motionforge.layers";
constexpr const char* kKeysFormat = "motionforge.keyframes";

// Position of an effect among the layer's effects of the same type (0 = first Glow, …).
int effectSlot(const Layer& l, ObjectId effect) {
    const Effect* e = l.findEffect(effect);
    if (!e) return -1;
    int slot = 0;
    for (const Effect& x : l.effects) {
        if (x.id == effect) return slot;
        if (x.type == e->type) ++slot;
    }
    return -1;
}

ObjectId effectAtSlot(const Layer& l, EffectType type, int slot) {
    for (const Effect& x : l.effects)
        if (x.type == type && slot-- == 0) return x.id;
    return 0;
}

}  // namespace

ClipboardKind clipboardKind(const std::string& text) {
    Json j;
    std::string err;
    if (!Json::parse(text, j, err)) return ClipboardKind::None;
    const std::string& f = j.get("format").string();
    if (f == kLayersFormat) return ClipboardKind::Layers;
    if (f == kKeysFormat) return ClipboardKind::Keyframes;
    return ClipboardKind::None;
}

std::string copyLayers(const Project& project, ObjectId comp, const std::vector<ObjectId>& ids) {
    const Composition* c = project.findComposition(comp);
    if (!c) return {};
    Json root = Json::object();
    root.set("format", Json(kLayersFormat));
    root.set("version", Json(1));
    Json layers = Json::array(), assets = Json::array();
    std::vector<ObjectId> usedAssets;
    for (const Layer& l : c->layers) {  // stacking order, not selection order
        if (std::find(ids.begin(), ids.end(), l.id) == ids.end()) continue;
        layers.push(layerToJson(l));
        if ((l.kind == LayerKind::Image || l.kind == LayerKind::Audio) && l.asset &&
            std::find(usedAssets.begin(), usedAssets.end(), l.asset) == usedAssets.end())
            usedAssets.push_back(l.asset);
    }
    for (ObjectId aid : usedAssets) {
        const Asset* a = project.findAsset(aid);
        if (!a) continue;
        Json aj = Json::object();
        aj.set("id", Json(a->id));
        aj.set("name", Json(a->name));
        aj.set("path", Json(a->path));
        aj.set("width", Json(a->width));
        aj.set("height", Json(a->height));
        if (a->kind == AssetKind::Audio) {
            aj.set("kind", Json("audio"));
            aj.set("duration", Json(a->duration));
        }
        assets.push(std::move(aj));
    }
    root.set("assets", std::move(assets));
    root.set("layers", std::move(layers));
    return root.dump(0);
}

std::vector<ObjectId> pasteLayers(Document& doc, ObjectId comp, const std::string& text, int atIndex,
                                  std::string& error) {
    Json root;
    if (!Json::parse(text, root, error) || root.get("format").string() != kLayersFormat) {
        error = "The clipboard doesn't contain MotionForge layers";
        return {};
    }
    const Composition* c = doc.project().findComposition(comp);
    if (!c) return {};
    std::vector<Asset> assets;
    for (const Json& aj : root.get("assets").items()) {
        Asset a;
        a.id = static_cast<ObjectId>(aj.get("id").number());
        a.name = aj.get("name").string();
        a.path = aj.get("path").string();
        a.width = int(aj.get("width").number());
        a.height = int(aj.get("height").number());
        a.kind = aj.get("kind").string() == "audio" ? AssetKind::Audio : AssetKind::Image;
        a.duration = aj.get("duration").number(0);
        assets.push_back(a);
    }
    std::vector<Layer> layers;
    for (const Json& lj : root.get("layers").items()) layers.push_back(layerFromJson(lj, *c, nullptr));
    if (layers.empty()) {
        error = "No layers on the clipboard";
        return {};
    }
    return doc.insertLayers(comp, std::move(layers), assets, atIndex);
}

std::string copyKeyframes(const Project& project, ObjectId comp, const std::vector<KeyAddress>& keys) {
    const Composition* c = project.findComposition(comp);
    if (!c || keys.empty()) return {};
    double t0 = std::numeric_limits<double>::infinity();
    for (const KeyAddress& k : keys) {
        const Layer* l = c->findLayer(k.layer);
        const Property* p = l ? resolveProperty(*l, k.prop) : nullptr;
        if (p && k.index >= 0 && k.index < int(p->keyframes.size())) t0 = std::min(t0, p->keyframes[size_t(k.index)].time);
    }
    if (!std::isfinite(t0)) return {};

    // Group by layer (in stacking order) then property.
    Json tracks = Json::array();
    int layerOrder = 0;
    for (const Layer& l : c->layers) {
        std::vector<PropRef> props;
        for (const KeyAddress& k : keys)
            if (k.layer == l.id && std::find(props.begin(), props.end(), k.prop) == props.end()) props.push_back(k.prop);
        if (props.empty()) continue;
        for (const PropRef& ref : props) {
            const Property* p = resolveProperty(l, ref);
            const PropDef* def = propertyDef(l, ref);
            if (!p || !def) continue;
            Json tj = Json::object();
            tj.set("layer", Json(layerOrder));
            switch (ref.owner) {
                case PropOwner::Layer: tj.set("owner", Json("layer")); break;
                case PropOwner::Mask: {
                    int slot = 0;
                    for (size_t i = 0; i < l.masks.size(); ++i)
                        if (l.masks[i].id == ref.ownerId) slot = int(i);
                    tj.set("owner", Json("mask"));
                    tj.set("slot", Json(slot));
                    break;
                }
                case PropOwner::Effect:
                    tj.set("owner", Json("effect"));
                    tj.set("effectType", Json(effectDef(l.findEffect(ref.ownerId)->type).key));
                    tj.set("slot", Json(effectSlot(l, ref.ownerId)));
                    break;
            }
            tj.set("property", Json(def->key));
            Json kj = Json::array();
            std::vector<int> indices;
            for (const KeyAddress& k : keys)
                if (k.layer == l.id && k.prop == ref && k.index >= 0 && k.index < int(p->keyframes.size()) &&
                    std::find(indices.begin(), indices.end(), k.index) == indices.end())
                    indices.push_back(k.index);
            std::sort(indices.begin(), indices.end());
            for (int i : indices) {
                Keyframe k = p->keyframes[size_t(i)];
                k.time -= t0;
                kj.push(keyframeToJson(k, *def));
            }
            tj.set("keys", std::move(kj));
            tracks.push(std::move(tj));
        }
        ++layerOrder;
    }
    Json root = Json::object();
    root.set("format", Json(kKeysFormat));
    root.set("version", Json(1));
    root.set("tracks", std::move(tracks));
    return root.dump(0);
}

int pasteKeyframes(Document& doc, ObjectId comp, const std::vector<ObjectId>& targets, double time,
                   const std::string& text, std::string& error) {
    Json root;
    if (!Json::parse(text, root, error) || root.get("format").string() != kKeysFormat) {
        error = "The clipboard doesn't contain MotionForge keyframes";
        return 0;
    }
    const Composition* c = doc.project().findComposition(comp);
    if (!c || targets.empty()) return 0;
    int sourceLayers = 0;
    for (const Json& tj : root.get("tracks").items()) sourceLayers = std::max(sourceLayers, int(tj.get("layer").number()) + 1);
    const bool spread = sourceLayers == int(targets.size());

    std::map<ObjectId, std::vector<std::pair<PropRef, std::vector<Keyframe>>>> perTarget;
    std::vector<std::string> skipped;
    for (const Json& tj : root.get("tracks").items()) {
        const ObjectId target = spread ? targets[size_t(tj.get("layer").number())] : targets[0];
        const Layer* l = c->findLayer(target);
        if (!l) continue;
        const std::string& owner = tj.get("owner").string();
        const std::string& key = tj.get("property").string();
        const int slot = int(tj.get("slot").number(0));
        PropRef ref;
        bool found = false;
        if (owner == "layer") {
            if (auto id = propFromKey(key)) {
                ref = PropRef::layer(*id);
                found = true;
            }
        } else if (owner == "mask") {
            if (slot >= 0 && slot < int(l->masks.size()))
                for (int i = 0; i < kMaskParamCount; ++i)
                    if (key == maskParamDef(static_cast<MaskParam>(i)).key) {
                        ref = PropRef::mask(l->masks[size_t(slot)].id, static_cast<MaskParam>(i));
                        found = true;
                    }
        } else if (owner == "effect") {
            if (auto type = effectTypeFromKey(tj.get("effectType").string()))
                if (ObjectId e = effectAtSlot(*l, *type, slot)) {
                    const auto& params = effectDef(*type).params;
                    for (size_t i = 0; i < params.size(); ++i)
                        if (key == params[i].key) {
                            ref = PropRef::effect(e, int(i));
                            found = true;
                        }
                }
        }
        if (!found) {
            skipped.push_back(owner == "effect" ? tj.get("effectType").string() + " " + key : owner + " " + key);
            continue;
        }
        const Property* p = resolveProperty(*l, ref);
        std::vector<Keyframe> keys;
        for (const Json& kj : tj.get("keys").items()) {
            Keyframe k = keyframeFromJson(kj, p->value);
            k.time = std::round((k.time + time) * c->fps) / c->fps;  // land on frames
            keys.push_back(k);
        }
        perTarget[target].push_back({ref, std::move(keys)});
    }

    doc.beginGroup("Paste Keyframes");
    int written = 0;
    for (const auto& [target, tracks] : perTarget) written += doc.insertKeyframes(comp, target, tracks);
    doc.endGroup();
    if (!skipped.empty()) {
        error = "Skipped (no matching property on the target layer): ";
        for (size_t i = 0; i < skipped.size(); ++i) error += (i ? ", " : "") + skipped[i];
    }
    return written;
}

}  // namespace mf
