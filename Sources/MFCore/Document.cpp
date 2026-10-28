#include "mf/Document.hpp"

#include <algorithm>
#include <cmath>

#include "mf/Evaluator.hpp"

namespace mf {

namespace {

constexpr double kTimeEps = 1e-6;

int findKeyAt(const Property& p, double t) {
    for (size_t i = 0; i < p.keyframes.size(); ++i)
        if (std::abs(p.keyframes[i].time - t) < kTimeEps) return static_cast<int>(i);
    return -1;
}

// Inserts or replaces a key at `k.time`, keeping the list sorted. Returns the index.
int putKey(Property& p, const Keyframe& k) {
    if (int i = findKeyAt(p, k.time); i >= 0) {
        p.keyframes[i].value = k.value;
        return i;
    }
    auto it = std::upper_bound(p.keyframes.begin(), p.keyframes.end(), k.time,
                               [](double t, const Keyframe& x) { return t < x.time; });
    return static_cast<int>(p.keyframes.insert(it, k) - p.keyframes.begin());
}

std::string uniqueName(const Composition& c, const std::string& base) {
    auto taken = [&](const std::string& n) {
        return std::any_of(c.layers.begin(), c.layers.end(), [&](const Layer& l) { return l.name == n; });
    };
    if (!taken(base)) return base;
    for (int i = 2;; ++i) {
        std::string n = base + " " + std::to_string(i);
        if (!taken(n)) return n;
    }
}

}  // namespace

void Document::replaceProject(Project p) {
    project_ = std::move(p);
    undo_.clear();
    redo_.clear();
    groupDepth_ = 0;
    groupRecorded_ = false;
    touched();
    markSaved();
}

void Document::clearHistory() {
    undo_.clear();
    redo_.clear();
    groupDepth_ = 0;
    groupRecorded_ = false;
    markSaved();
}

Project& Document::edit(const std::string& label) {
    if (groupDepth_ > 0) {
        if (!groupRecorded_) {
            undo_.push_back({project_, groupLabel_.empty() ? label : groupLabel_});
            groupRecorded_ = true;
        }
    } else {
        undo_.push_back({project_, label});
    }
    while (undo_.size() > kMaxUndo) undo_.pop_front();
    redo_.clear();
    touched();
    return project_;
}

bool Document::undo() {
    if (undo_.empty()) return false;
    redo_.push_back({project_, undo_.back().label});
    project_ = std::move(undo_.back().project);
    undo_.pop_back();
    touched();
    return true;
}

bool Document::redo() {
    if (redo_.empty()) return false;
    undo_.push_back({project_, redo_.back().label});
    project_ = std::move(redo_.back().project);
    redo_.pop_back();
    touched();
    return true;
}

void Document::beginGroup(const std::string& label) {
    if (groupDepth_++ == 0) {
        groupRecorded_ = false;
        groupLabel_ = label;
    }
}

void Document::endGroup() {
    if (groupDepth_ > 0 && --groupDepth_ == 0) groupRecorded_ = false;
}

Layer* Document::layerFor(ObjectId comp, ObjectId layer) {
    Composition* c = project_.findComposition(comp);
    return c ? c->findLayer(layer) : nullptr;
}

// ---------------------------------------------------------------------------------------------

bool Document::setCompositionSettings(ObjectId comp, int width, int height, double fps, double duration,
                                      Value background, const std::string& name) {
    if (!project_.findComposition(comp) || width < 1 || height < 1 || width > 16384 || height > 16384 || fps < 1 ||
        fps > 240 || duration <= 0)
        return false;
    Composition& c = *edit("Composition Settings").findComposition(comp);
    c.width = width;
    c.height = height;
    c.fps = fps;
    c.duration = std::max(duration, 1.0 / fps);
    c.background = background;
    if (!name.empty()) c.name = name;
    return true;
}

ObjectId Document::addImageAsset(const std::string& path, const std::string& name, int width, int height) {
    for (const Asset& a : project_.assets)
        if (a.path == path) return a.id;  // importing the same file twice reuses the asset
    Project& p = edit("Import");
    Asset a;
    a.id = p.allocateId();
    a.kind = AssetKind::Image;
    a.path = path;
    a.name = name;
    a.width = width;
    a.height = height;
    p.assets.push_back(a);
    return a.id;
}

ObjectId Document::addLayer(ObjectId comp, LayerKind kind, ShapeType shape, ObjectId asset) {
    if (!project_.findComposition(comp)) return 0;
    if (kind == LayerKind::Image && !project_.findAsset(asset)) return 0;
    Project& p = edit("New Layer");
    Composition& c = *p.findComposition(comp);
    Layer l = makeLayer(kind, c, p.allocateId(), p.findAsset(asset));
    l.shape = shape;
    if (kind == LayerKind::Shape) {
        static const char* names[] = {"Rectangle", "Ellipse", "Polygon", "Star"};
        l.name = names[static_cast<int>(shape)];
        if (shape == ShapeType::Polygon) l.prop(PropId::Points).value[0] = 6;
    }
    l.name = uniqueName(c, l.name);
    c.layers.insert(c.layers.begin(), l);  // new layers go on top
    return l.id;
}

bool Document::removeLayer(ObjectId comp, ObjectId layer) {
    if (!layerFor(comp, layer)) return false;
    Composition& c = *edit("Delete Layer").findComposition(comp);
    c.layers.erase(c.layers.begin() + c.indexOf(layer));
    for (Layer& l : c.layers) {
        if (l.parent == layer) l.parent = 0;  // children keep their own local transform
        if (l.matteLayer == layer) {
            l.matteLayer = 0;
            l.matteMode = MatteMode::None;
        }
    }
    return true;
}

ObjectId Document::duplicateLayer(ObjectId comp, ObjectId layer) {
    if (!layerFor(comp, layer)) return 0;
    Project& p = edit("Duplicate Layer");
    Composition& c = *p.findComposition(comp);
    const int idx = c.indexOf(layer);
    Layer copy = c.layers[idx];
    copy.id = p.allocateId();
    for (Mask& m : copy.masks) m.id = p.allocateId();
    for (Effect& e : copy.effects) e.id = p.allocateId();
    copy.name = uniqueName(c, copy.name);
    c.layers.insert(c.layers.begin() + idx, copy);
    return copy.id;
}

bool Document::moveLayer(ObjectId comp, ObjectId layer, int newIndex) {
    Composition* c0 = project_.findComposition(comp);
    if (!c0) return false;
    const int from = c0->indexOf(layer);
    if (from < 0) return false;
    newIndex = std::clamp(newIndex, 0, static_cast<int>(c0->layers.size()) - 1);
    if (newIndex == from) return false;
    Composition& c = *edit("Reorder Layers").findComposition(comp);
    Layer l = std::move(c.layers[from]);
    c.layers.erase(c.layers.begin() + from);
    c.layers.insert(c.layers.begin() + newIndex, std::move(l));
    return true;
}

bool Document::setLayerName(ObjectId comp, ObjectId layer, const std::string& name) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || name.empty() || l0->name == name) return false;
    edit("Rename Layer");
    layerFor(comp, layer)->name = name;
    return true;
}

bool Document::setLayerVisible(ObjectId comp, ObjectId layer, bool visible) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->visible == visible) return false;
    edit("Toggle Visibility");
    layerFor(comp, layer)->visible = visible;
    return true;
}

bool Document::setLayerTiming(ObjectId comp, ObjectId layer, double in, double out) {
    Layer* l0 = layerFor(comp, layer);
    const Composition* c = project_.findComposition(comp);
    if (!l0 || !c) return false;
    const double minLen = c->frameDuration();
    if (out - in < minLen) out = in + minLen;
    if (std::abs(l0->inPoint - in) < kTimeEps && std::abs(l0->outPoint - out) < kTimeEps) return false;
    edit("Layer Timing");
    Layer* l = layerFor(comp, layer);
    l->inPoint = in;
    l->outPoint = out;
    return true;
}

bool Document::setLayerParent(ObjectId comp, ObjectId layer, ObjectId parent) {
    Composition* c = project_.findComposition(comp);
    Layer* l0 = c ? c->findLayer(layer) : nullptr;
    if (!l0 || l0->parent == parent || parent == layer) return false;
    if (parent) {
        if (!c->findLayer(parent)) return false;
        for (ObjectId p = parent; p; p = c->findLayer(p)->parent)  // would create a cycle?
            if (p == layer) return false;
    }
    // Keep the layer visually where it is: rebase its transform into the new parent's space.
    // Only the static case is rebased; animated transforms are left as-is.
    const double t = 0;
    const Affine oldWorld = layerWorldTransform(*c, *l0, t);
    Affine parentWorld;
    if (parent) parentWorld = layerWorldTransform(*c, *c->findLayer(parent), t);
    Affine invParent;
    const bool canRebase = parentWorld.inverse(invParent) && !l0->prop(PropId::Position).animated() &&
                           !l0->prop(PropId::Rotation).animated() && !l0->prop(PropId::Scale).animated();

    edit("Set Parent");
    Layer* l = layerFor(comp, layer);
    l->parent = parent;
    if (canRebase) {
        const Affine local = invParent * oldWorld;  // = T(pos) R S T(-anchor)
        const Value anchor = l->prop(PropId::AnchorPoint).value;
        const double sx = std::hypot(local.a, local.b);
        const double rot = std::atan2(local.b, local.a) * 180.0 / std::numbers::pi;
        const double sy = local.determinant() / (sx > 0 ? sx : 1);
        const Vec2 pos = local.apply({anchor[0], anchor[1]});
        l->prop(PropId::Position).value = {pos.x, pos.y, 0, 0};
        l->prop(PropId::Rotation).value[0] = rot;
        l->prop(PropId::Scale).value = {sx * 100, sy * 100, 0, 0};
    }
    return true;
}

bool Document::setLayerBlend(ObjectId comp, ObjectId layer, BlendMode mode) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->blend == mode) return false;
    edit("Blend Mode");
    layerFor(comp, layer)->blend = mode;
    return true;
}

bool Document::setLayerShape(ObjectId comp, ObjectId layer, ShapeType shape) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind != LayerKind::Shape || l0->shape == shape) return false;
    edit("Shape Type");
    layerFor(comp, layer)->shape = shape;
    return true;
}

bool Document::setLayerFillStroke(ObjectId comp, ObjectId layer, bool fillOn, bool strokeOn) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || (l0->fillEnabled == fillOn && l0->strokeEnabled == strokeOn)) return false;
    edit("Fill/Stroke");
    Layer* l = layerFor(comp, layer);
    l->fillEnabled = fillOn;
    l->strokeEnabled = strokeOn;
    return true;
}

// ---------------------------------------------------------------------------------------------

bool Document::setPropertyValue(ObjectId comp, ObjectId layer, PropRef prop, double time, Value v) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0) return false;
    const PropDef& def = *propertyDef(*l0, prop);
    for (int i = def.dims; i < 4; ++i) v[size_t(i)] = 0;
    for (int i = 0; i < def.dims; ++i) v[size_t(i)] = std::clamp(v[size_t(i)], def.minValue, def.maxValue);
    if (!p0->animated() && p0->value == v) return false;
    if (p0->animated()) {
        const int k = findKeyAt(*p0, time);
        if (k >= 0 && p0->keyframes[size_t(k)].value == v) return false;
    }
    edit(std::string("Change ") + def.label);
    Property& p = *resolveProperty(*layerFor(comp, layer), prop);
    if (p.animated()) {
        Keyframe k;
        k.time = time;
        k.value = v;
        putKey(p, k);
    } else {
        p.value = v;
    }
    return true;
}

bool Document::setPropertyAnimated(ObjectId comp, ObjectId layer, PropRef prop, bool animated, double time) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || p0->animated() == animated) return false;
    const Value current = evaluateProperty(*p0, *propertyDef(*l0, prop), time);
    edit(animated ? "Enable Keyframes" : "Remove Keyframes");
    Property& p = *resolveProperty(*layerFor(comp, layer), prop);
    if (animated) {
        Keyframe k;
        k.time = time;
        k.value = current;
        p.keyframes = {k};
    } else {
        p.keyframes.clear();
        p.value = current;
    }
    return true;
}

bool Document::addKeyframe(ObjectId comp, ObjectId layer, PropRef prop, double time) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || findKeyAt(*p0, time) >= 0) return false;
    const Value current = evaluateProperty(*p0, *propertyDef(*l0, prop), time);
    edit("Add Keyframe");
    Keyframe k;
    k.time = time;
    k.value = current;
    putKey(*resolveProperty(*layerFor(comp, layer), prop), k);
    return true;
}

bool Document::removeKeyframe(ObjectId comp, ObjectId layer, PropRef prop, int index) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || index < 0 || index >= static_cast<int>(p0->keyframes.size())) return false;
    edit("Delete Keyframe");
    Property& p = *resolveProperty(*layerFor(comp, layer), prop);
    if (p.keyframes.size() == 1) p.value = p.keyframes.front().value;  // removing the last key keeps its value
    p.keyframes.erase(p.keyframes.begin() + index);
    return true;
}

int Document::moveKeyframe(ObjectId comp, ObjectId layer, PropRef prop, int index, double newTime) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || index < 0 || index >= static_cast<int>(p0->keyframes.size())) return -1;
    if (std::abs(p0->keyframes[size_t(index)].time - newTime) < kTimeEps) return index;
    edit("Move Keyframe");
    Property& p = *resolveProperty(*layerFor(comp, layer), prop);
    Keyframe k = p.keyframes[size_t(index)];
    p.keyframes.erase(p.keyframes.begin() + index);
    k.time = newTime;
    if (int existing = findKeyAt(p, newTime); existing >= 0) p.keyframes.erase(p.keyframes.begin() + existing);
    auto it = std::upper_bound(p.keyframes.begin(), p.keyframes.end(), k.time,
                               [](double t, const Keyframe& x) { return t < x.time; });
    return static_cast<int>(p.keyframes.insert(it, k) - p.keyframes.begin());
}

bool Document::setKeyframeInterpolation(ObjectId comp, ObjectId layer, PropRef prop, int index, Interp in,
                                        Interp out) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || index < 0 || index >= static_cast<int>(p0->keyframes.size())) return false;
    const Keyframe& k0 = p0->keyframes[size_t(index)];
    if (k0.inInterp == in && k0.outInterp == out) return false;
    edit("Keyframe Interpolation");
    Keyframe& k = resolveProperty(*layerFor(comp, layer), prop)->keyframes[size_t(index)];
    k.inInterp = in;
    k.outInterp = out;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Effects, masks, mattes

ObjectId Document::addEffect(ObjectId comp, ObjectId layer, EffectType type) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind == LayerKind::Null || type == EffectType::Count) return 0;
    Project& p = edit(std::string("Add ") + effectDef(type).label);
    Effect e = makeEffect(type, p.allocateId());
    layerFor(comp, layer)->effects.push_back(e);
    return e.id;
}

bool Document::removeEffect(ObjectId comp, ObjectId layer, ObjectId effect) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || !l0->findEffect(effect)) return false;
    edit("Remove Effect");
    auto& fx = layerFor(comp, layer)->effects;
    fx.erase(std::remove_if(fx.begin(), fx.end(), [&](const Effect& e) { return e.id == effect; }), fx.end());
    return true;
}

bool Document::moveEffect(ObjectId comp, ObjectId layer, ObjectId effect, int newIndex) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0) return false;
    auto& fx0 = l0->effects;
    auto it = std::find_if(fx0.begin(), fx0.end(), [&](const Effect& e) { return e.id == effect; });
    if (it == fx0.end()) return false;
    const int from = int(it - fx0.begin());
    newIndex = std::clamp(newIndex, 0, int(fx0.size()) - 1);
    if (newIndex == from) return false;
    edit("Reorder Effects");
    auto& fx = layerFor(comp, layer)->effects;
    Effect e = fx[size_t(from)];
    fx.erase(fx.begin() + from);
    fx.insert(fx.begin() + newIndex, e);
    return true;
}

bool Document::setEffectEnabled(ObjectId comp, ObjectId layer, ObjectId effect, bool enabled) {
    Layer* l0 = layerFor(comp, layer);
    const Effect* e0 = l0 ? l0->findEffect(effect) : nullptr;
    if (!e0 || e0->enabled == enabled) return false;
    edit(enabled ? "Enable Effect" : "Disable Effect");
    layerFor(comp, layer)->findEffect(effect)->enabled = enabled;
    return true;
}

ObjectId Document::addMask(ObjectId comp, ObjectId layer, MaskShape shape) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind == LayerKind::Null) return 0;
    Vec2 mn, mx;
    layerLocalBounds(project_, *l0, 0, mn, mx);
    Project& p = edit("Add Mask");
    Layer& l = *layerFor(comp, layer);
    Mask m;
    m.id = p.allocateId();
    m.shape = shape;
    m.name = "Mask " + std::to_string(l.masks.size() + 1);
    for (int i = 0; i < kMaskParamCount; ++i) m.params[size_t(i)].value = maskParamDef(static_cast<MaskParam>(i)).defaultValue;
    m.param(MaskParam::Position).value = {(mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, 0, 0};
    m.param(MaskParam::Size).value = {std::round((mx.x - mn.x) * 0.6), std::round((mx.y - mn.y) * 0.6), 0, 0};
    l.masks.push_back(m);
    return m.id;
}

bool Document::removeMask(ObjectId comp, ObjectId layer, ObjectId mask) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || !l0->findMask(mask)) return false;
    edit("Remove Mask");
    auto& ms = layerFor(comp, layer)->masks;
    ms.erase(std::remove_if(ms.begin(), ms.end(), [&](const Mask& m) { return m.id == mask; }), ms.end());
    return true;
}

bool Document::setMaskMode(ObjectId comp, ObjectId layer, ObjectId mask, MaskMode mode, bool inverted) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0 || (m0->mode == mode && m0->inverted == inverted)) return false;
    edit("Mask Mode");
    Mask* m = layerFor(comp, layer)->findMask(mask);
    m->mode = mode;
    m->inverted = inverted;
    return true;
}

bool Document::setMaskShape(ObjectId comp, ObjectId layer, ObjectId mask, MaskShape shape) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0 || m0->shape == shape) return false;
    edit("Mask Shape");
    layerFor(comp, layer)->findMask(mask)->shape = shape;
    return true;
}

bool Document::setMaskEnabled(ObjectId comp, ObjectId layer, ObjectId mask, bool enabled) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0 || m0->enabled == enabled) return false;
    edit(enabled ? "Enable Mask" : "Disable Mask");
    layerFor(comp, layer)->findMask(mask)->enabled = enabled;
    return true;
}

bool Document::setLayerMatte(ObjectId comp, ObjectId layer, ObjectId matteLayer, MatteMode mode) {
    Composition* c = project_.findComposition(comp);
    Layer* l0 = c ? c->findLayer(layer) : nullptr;
    if (!l0) return false;
    if (matteLayer == 0 || mode == MatteMode::None) {
        matteLayer = 0;
        mode = MatteMode::None;
    } else if (matteLayer == layer || !c->findLayer(matteLayer)) {
        return false;
    }
    if (l0->matteLayer == matteLayer && l0->matteMode == mode) return false;
    const ObjectId previous = l0->matteLayer;
    edit(mode == MatteMode::None ? "Remove Track Matte" : "Set Track Matte");
    Composition& cc = *project_.findComposition(comp);
    Layer* l = cc.findLayer(layer);
    l->matteLayer = matteLayer;
    l->matteMode = mode;
    if (matteLayer && matteLayer != previous) cc.findLayer(matteLayer)->visible = false;
    return true;
}

}  // namespace mf
