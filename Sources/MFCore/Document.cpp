#include "mf/Document.hpp"

#include <algorithm>
#include <climits>
#include <cmath>
#include <unordered_map>

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

// A new keyframe: spatial properties default to smooth (Auto) motion paths, like most motion tools.
Keyframe newKey(const PropDef& def, double time, const Value& v) {
    Keyframe k;
    k.time = time;
    k.value = v;
    if (def.spatial) k.spatial = Spatial::Auto;
    return k;
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

std::string uniqueCompName(const Project& p, const std::string& base) {
    auto taken = [&](const std::string& n) {
        return std::any_of(p.compositions.begin(), p.compositions.end(), [&](const Composition& c) { return c.name == n; });
    };
    if (!taken(base)) return base;
    for (int i = 2;; ++i) {
        std::string n = base + " " + std::to_string(i);
        if (!taken(n)) return n;
    }
}

// Moves everything a layer shows in time by `dt`: its span, source time, keys and baked tracks.
void shiftLayerTime(Layer& l, double dt) {
    auto shift = [dt](Property& p) {
        for (Keyframe& k : p.keyframes) k.time += dt;
        if (p.samples) {
            SampledTrack s = *p.samples;
            s.t0 += dt;
            p.samples = Shared<SampledTrack>(std::move(s));
        }
    };
    auto shiftPath = [dt](Shared<PathTrack>& t) {
        if (!t) return;
        PathTrack copy = *t;
        copy.t0 += dt;
        t = Shared<PathTrack>(std::move(copy));
    };
    for (Property& p : l.props) shift(p);
    for (Mask& m : l.masks) {
        for (Property& p : m.params) shift(p);
        shiftPath(m.pathTrack);
    }
    for (Effect& e : l.effects)
        for (Property& p : e.params) shift(p);
    for (TextAnimator& a : l.animators)
        for (Property& p : a.params) shift(p);
    shiftPath(l.pathTrack);
    l.inPoint += dt;
    l.outPoint += dt;
    l.startTime += dt;
}

}  // namespace

void Document::applyExternal(Project p) {
    const ObjectId next = std::max(project_.nextId, p.nextId);
    project_ = std::move(p);
    project_.nextId = next;
    groupDepth_ = 0;
    groupRecorded_ = false;
    undo_.clear();
    redo_.clear();
    undoBytes_ = 0;
    touched();
}

void Document::replaceProject(Project p) {
    project_ = std::move(p);
    undo_.clear();
    redo_.clear();
    undoBytes_ = 0;
    groupDepth_ = 0;
    groupRecorded_ = false;
    touched();
    markSaved();
}

void Document::clearHistory() {
    undo_.clear();
    redo_.clear();
    undoBytes_ = 0;
    groupDepth_ = 0;
    groupRecorded_ = false;
    markSaved();
}

size_t approxSnapshotBytes(const Project& p) {
    size_t n = sizeof(Project) + p.assets.size() * sizeof(Asset);
    auto prop = [](const Property& q) { return q.keyframes.size() * sizeof(Keyframe); };
    auto path = [](const BezierPath& b) { return b.vertices.size() * sizeof(PathVertex); };
    for (const Composition& c : p.compositions) {
        n += sizeof(Composition);
        for (const Layer& l : c.layers) {
            n += sizeof(Layer) + l.name.size() + l.text.string.size() + path(l.path);
            for (const Property& q : l.props) n += prop(q);
            for (const Mask& m : l.masks) {
                n += sizeof(Mask) + path(m.path);
                for (const Property& q : m.params) n += prop(q);
            }
            for (const Effect& e : l.effects) {
                n += sizeof(Effect) + e.params.size() * sizeof(Property);
                for (const Property& q : e.params) n += prop(q);
            }
            for (const TextAnimator& a : l.animators) {
                n += sizeof(TextAnimator);
                for (const Property& q : a.params) n += prop(q);
            }
        }
    }
    return n;
}

void Document::push(std::deque<Snapshot>& stack, Project p, std::string label) {
    const size_t bytes = approxSnapshotBytes(p);
    stack.push_back({std::move(p), std::move(label), bytes});
    undoBytes_ += bytes;
}

// Oldest undo steps go first; redo is cleared by every edit anyway.
void Document::trimHistory() {
    while (!undo_.empty() && (undo_.size() > kMaxUndo || (undoBytes_ > kUndoBudget && undo_.size() > 1))) {
        undoBytes_ -= undo_.front().bytes;
        undo_.pop_front();
    }
}

Project& Document::edit(const std::string& label) {
    if (groupDepth_ > 0) {
        if (!groupRecorded_) {
            push(undo_, project_, groupLabel_.empty() ? label : groupLabel_);
            groupRecorded_ = true;
            ++editSerial_;
        }
    } else {
        push(undo_, project_, label);
        ++editSerial_;
    }
    for (const Snapshot& r : redo_) undoBytes_ -= r.bytes;
    redo_.clear();
    trimHistory();
    touched();
    return project_;
}

// Which composition is shown isn't an edit, so undo and redo stay in the one you're looking at
// (when it still exists) instead of jumping back to wherever the snapshot was taken.
bool Document::undo() {
    if (undo_.empty()) return false;
    const ObjectId shown = project_.activeComposition;
    push(redo_, project_, undo_.back().label);
    undoBytes_ -= undo_.back().bytes;
    project_ = std::move(undo_.back().project);
    undo_.pop_back();
    if (project_.findComposition(shown)) project_.activeComposition = shown;
    touched();
    return true;
}

bool Document::redo() {
    if (redo_.empty()) return false;
    const ObjectId shown = project_.activeComposition;
    push(undo_, project_, redo_.back().label);
    undoBytes_ -= redo_.back().bytes;
    project_ = std::move(redo_.back().project);
    redo_.pop_back();
    if (project_.findComposition(shown)) project_.activeComposition = shown;
    trimHistory();
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

ObjectId Document::addComposition(const std::string& name, int width, int height, double fps, double duration) {
    if (width < 1 || height < 1 || width > 16384 || height > 16384 || fps < 1 || fps > 240 || duration <= 0) return 0;
    Project& p = edit("New Composition");
    Composition c;
    c.id = p.allocateId();
    c.name = name.empty() ? "Comp " + std::to_string(p.compositions.size() + 1) : name;
    c.width = width;
    c.height = height;
    c.fps = fps;
    c.duration = std::max(duration, 1.0 / fps);
    p.compositions.push_back(std::move(c));
    return p.compositions.back().id;
}

bool Document::setActiveComposition(ObjectId comp) {
    if (!project_.findComposition(comp) || project_.activeComposition == comp) return false;
    project_.activeComposition = comp;
    // Navigation, not an edit: views refresh, but a saved document stays saved.
    const bool wasClean = !dirty();
    touched();
    if (wasClean) markSaved();
    return true;
}

ObjectId Document::addPrecompLayer(ObjectId comp, ObjectId source) {
    const Composition* c0 = project_.findComposition(comp);
    const Composition* s0 = project_.findComposition(source);
    // `source` must not already show `comp` (directly or nested), and a comp can't show itself.
    if (!c0 || !s0 || compUses(project_, source, comp)) return 0;
    Project& p = edit("New Precomp Layer");
    Composition& c = *p.findComposition(comp);
    Layer l = makePrecompLayer(c, *p.findComposition(source), p.allocateId());
    l.name = uniqueName(c, l.name);
    c.layers.insert(c.layers.begin(), l);
    return l.id;
}

bool Document::setLayerStartTime(ObjectId comp, ObjectId layer, double startTime) {
    const Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->startTime == startTime) return false;
    const Asset* a = project_.findAsset(l0->asset);
    const bool footage = l0->kind == LayerKind::Image && a && a->isVideo();
    if (l0->kind != LayerKind::Precomp && l0->kind != LayerKind::Audio && !footage) return false;
    edit("Move Layer in Time").findComposition(comp)->findLayer(layer)->startTime = startTime;
    return true;
}

bool Document::setWorkArea(ObjectId comp, double start, double end) {
    const Composition* c0 = project_.findComposition(comp);
    if (!c0) return false;
    const double fd = c0->frameDuration();
    start = std::clamp(c0->snapToFrame(start), 0.0, std::max(0.0, c0->duration - fd));
    end = end < 0 ? -1 : std::clamp(c0->snapToFrame(end), start + fd, std::max(c0->duration, start + fd));
    if (end >= c0->duration - kTimeEps) end = -1;
    if (std::abs(start - c0->workStart) < kTimeEps && std::abs(end - c0->workEnd) < kTimeEps) return false;
    Composition& c = *edit("Work Area").findComposition(comp);
    c.workStart = start;
    c.workEnd = end;
    return true;
}

bool Document::trimToWorkArea(ObjectId comp) {
    const Composition* c0 = project_.findComposition(comp);
    if (!c0 || !c0->hasWorkArea()) return false;
    const double start = c0->workAreaStart(), end = c0->workAreaEnd();
    Composition& c = *edit("Trim Comp to Work Area").findComposition(comp);
    if (start > 0)
        for (Layer& l : c.layers) shiftLayerTime(l, -start);
    c.duration = std::max(end - start, c.frameDuration());
    c.workStart = 0;
    c.workEnd = -1;
    return true;
}

ObjectId Document::precompose(ObjectId comp, const std::vector<ObjectId>& ids, const std::string& name) {
    const Composition* c0 = project_.findComposition(comp);
    if (!c0) return 0;
    std::vector<ObjectId> moving;  // stack order
    for (const Layer& l : c0->layers)
        if (std::find(ids.begin(), ids.end(), l.id) != ids.end()) moving.push_back(l.id);
    if (moving.empty()) return 0;
    auto moved = [&](ObjectId id) { return id != 0 && std::find(moving.begin(), moving.end(), id) != moving.end(); };

    Project& p = edit("Pre-compose");
    Composition inner;
    int top = 0;
    {
        Composition& c = *p.findComposition(comp);
        top = c.indexOf(moving.front());
        inner.id = p.allocateId();
        inner.name = uniqueCompName(p, name.empty() ? c.name + " Comp" : name);
        inner.folder = c.folder;
        inner.width = c.width;
        inner.height = c.height;
        inner.fps = c.fps;
        inner.duration = c.duration;
        inner.background = c.background;
        inner.motionBlur = c.motionBlur;
        inner.shutterAngle = c.shutterAngle;
        inner.shutterPhase = c.shutterPhase;
        inner.motionBlurSamples = c.motionBlurSamples;
        for (Layer& l : c.layers)
            if (moved(l.id)) inner.layers.push_back(std::move(l));
        c.layers.erase(std::remove_if(c.layers.begin(), c.layers.end(), [&](const Layer& l) { return moved(l.id); }),
                       c.layers.end());
        // A link can't reach into another composition.
        for (Layer& l : c.layers) {
            if (moved(l.parent)) l.parent = 0;
            if (moved(l.matteLayer)) {
                l.matteLayer = 0;
                l.matteMode = MatteMode::None;
            }
        }
        for (Layer& l : inner.layers) {
            if (l.parent && !moved(l.parent)) l.parent = 0;
            if (l.matteLayer && !moved(l.matteLayer)) {
                l.matteLayer = 0;
                l.matteMode = MatteMode::None;
            }
        }
    }
    const ObjectId innerId = inner.id;
    p.compositions.push_back(std::move(inner));
    Composition& host = *p.findComposition(comp);  // the push may have moved it
    Layer pl = makePrecompLayer(host, *p.findComposition(innerId), p.allocateId());
    pl.name = uniqueName(host, pl.name);
    host.layers.insert(host.layers.begin() + std::clamp(top, 0, int(host.layers.size())), std::move(pl));
    return innerId;
}

bool Document::setPrecompOptions(ObjectId comp, ObjectId layer, bool collapse, bool timeRemap, double startTime) {
    const Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind != LayerKind::Precomp) return false;
    if (l0->collapse == collapse && l0->timeRemap == timeRemap && l0->startTime == startTime) return false;
    Layer& l = *edit("Precomp Options").findComposition(comp)->findLayer(layer);
    if (timeRemap && !l.timeRemap && !l.prop(PropId::TimeRemap).animated() && !l.prop(PropId::TimeRemap).baked()) {
        // Start remapping as an identity map over the layer's span: key in -> source time.
        Property& r = l.prop(PropId::TimeRemap);
        Keyframe a, b;
        a.time = l.inPoint;
        a.value = {l.inPoint - startTime, 0, 0, 0};
        b.time = l.outPoint;
        b.value = {l.outPoint - startTime, 0, 0, 0};
        r.keyframes = {a, b};
    }
    l.collapse = collapse;
    l.timeRemap = timeRemap;
    l.startTime = startTime;
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

ObjectId Document::addAudioAsset(const std::string& path, const std::string& name, double duration) {
    for (const Asset& a : project_.assets)
        if (a.path == path) return a.id;
    Project& p = edit("Import");
    Asset a;
    a.id = p.allocateId();
    a.kind = AssetKind::Audio;
    a.path = path;
    a.name = name;
    a.duration = duration;
    p.assets.push_back(a);
    return a.id;
}

ObjectId Document::addVideoAsset(const std::string& path, const std::string& name, int width, int height, double duration,
                                 double fps, bool hasAudio) {
    for (const Asset& a : project_.assets)
        if (a.path == path) return a.id;
    Project& p = edit("Import");
    Asset a;
    a.id = p.allocateId();
    a.kind = AssetKind::Video;
    a.path = path;
    a.name = name;
    a.width = width;
    a.height = height;
    a.duration = duration;
    a.fps = fps;
    a.hasAudio = hasAudio;
    p.assets.push_back(a);
    return a.id;
}

ObjectId Document::addLayer(ObjectId comp, LayerKind kind, ShapeType shape, ObjectId asset) {
    if (!project_.findComposition(comp)) return 0;
    if (kind == LayerKind::Image || kind == LayerKind::Audio) {
        const Asset* a = project_.findAsset(asset);
        if (!a || (a->kind == AssetKind::Audio) != (kind == LayerKind::Audio)) return 0;
    }
    Project& p = edit("New Layer");
    Composition& c = *p.findComposition(comp);
    Layer l = makeLayer(kind, c, p.allocateId(), p.findAsset(asset));
    l.shape = shape;
    if (kind == LayerKind::Shape) {
        static const char* names[] = {"Rectangle", "Ellipse", "Polygon", "Star", "Shape"};
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
    for (TextAnimator& a : copy.animators) a.id = p.allocateId();
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

bool Document::setLayerThreeD(ObjectId comp, ObjectId layer, bool threeD) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->threeD == threeD || l0->kind == LayerKind::Audio || l0->kind == LayerKind::Precomp ||
        l0->kind == LayerKind::Camera)
        return false;
    edit(threeD ? "3D Layer" : "2D Layer");
    layerFor(comp, layer)->threeD = threeD;
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
    if (p0->baked()) {
        // Baked animation keeps its motion: the whole track shifts so it passes through `v` at `time`.
        const Value cur = evaluateProperty(*p0, def, time);
        if (cur == v) return false;
        SampledTrack t = *p0->samples;
        for (size_t i = 0; i < t.count(); ++i)
            for (int k = 0; k < std::min(def.dims, t.dims); ++k) {
                float& x = t.data[i * size_t(t.dims) + size_t(k)];
                x = float(std::clamp(double(x) + v[size_t(k)] - cur[size_t(k)], def.minValue, def.maxValue));
            }
        edit(std::string("Change ") + def.label);
        resolveProperty(*layerFor(comp, layer), prop)->samples = Shared<SampledTrack>(std::move(t));
        return true;
    }
    edit(std::string("Change ") + def.label);
    Property& p = *resolveProperty(*layerFor(comp, layer), prop);
    if (p.animated()) {
        putKey(p, newKey(def, time, v));
    } else {
        p.value = v;
    }
    return true;
}

bool Document::setPropertyAnimated(ObjectId comp, ObjectId layer, PropRef prop, bool animated, double time) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || (p0->animated() == animated && !p0->baked())) return false;
    const Value current = evaluateProperty(*p0, *propertyDef(*l0, prop), time);
    edit(p0->baked() ? "Remove Baked Animation" : animated ? "Enable Keyframes" : "Remove Keyframes");
    Property& p = *resolveProperty(*layerFor(comp, layer), prop);
    p.samples.reset();  // switching to (or off) keyframes replaces a baked track
    if (animated) {
        p.keyframes = {newKey(*propertyDef(*layerFor(comp, layer), prop), time, current)};
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
    const Keyframe k = newKey(*propertyDef(*l0, prop), time, current);
    edit("Add Keyframe");
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
    if (!l0 || l0->kind == LayerKind::Null || l0->kind == LayerKind::Audio || type == EffectType::Count) return 0;
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
    if (!l0 || l0->kind == LayerKind::Null || l0->kind == LayerKind::Audio) return 0;
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

// ---------------------------------------------------------------------------------------------
// Keyframe editing beyond the playhead, and multi-selection

bool Document::setKeyframeValue(ObjectId comp, ObjectId layer, PropRef prop, int index, Value v) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || index < 0 || index >= int(p0->keyframes.size())) return false;
    const PropDef& def = *propertyDef(*l0, prop);
    for (int i = def.dims; i < 4; ++i) v[size_t(i)] = 0;
    for (int i = 0; i < def.dims; ++i) v[size_t(i)] = std::clamp(v[size_t(i)], def.minValue, def.maxValue);
    if (p0->keyframes[size_t(index)].value == v) return false;
    edit(std::string("Change ") + def.label);
    resolveProperty(*layerFor(comp, layer), prop)->keyframes[size_t(index)].value = v;
    return true;
}

bool Document::setKeyframeSpatial(ObjectId comp, ObjectId layer, PropRef prop, int index, Spatial mode, Value tin,
                                  Value tout) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || !propertyDef(*l0, prop)->spatial || index < 0 || index >= int(p0->keyframes.size())) return false;
    if (mode != Spatial::Bezier) tin = tout = Value{};
    const Keyframe& k0 = p0->keyframes[size_t(index)];
    if (k0.spatial == mode && k0.tangentIn == tin && k0.tangentOut == tout) return false;
    edit("Motion Path");
    Keyframe& k = resolveProperty(*layerFor(comp, layer), prop)->keyframes[size_t(index)];
    k.spatial = mode;
    k.tangentIn = tin;
    k.tangentOut = tout;
    return true;
}

namespace {
bool sameTrack(const KeyAddress& a, const KeyAddress& b) { return a.layer == b.layer && a.prop == b.prop; }
}  // namespace

std::vector<KeyAddress> Document::moveKeyframes(ObjectId comp, const std::vector<KeyAddress>& keys, double dt) {
    std::vector<KeyAddress> result = keys;
    if (keys.empty() || std::abs(dt) < kTimeEps) return result;
    for (const KeyAddress& k : keys) {  // validate everything before touching the document
        Layer* l = layerFor(comp, k.layer);
        const Property* p = l ? resolveProperty(*l, k.prop) : nullptr;
        if (!p || k.index < 0 || k.index >= int(p->keyframes.size())) return keys;
    }
    edit(keys.size() == 1 ? "Move Keyframe" : "Move Keyframes");
    std::vector<bool> done(keys.size(), false);
    for (size_t a = 0; a < keys.size(); ++a) {
        if (done[a]) continue;
        // All selected keys of this property.
        std::vector<size_t> group;
        for (size_t b = a; b < keys.size(); ++b)
            if (!done[b] && sameTrack(keys[a], keys[b])) group.push_back(b);
        Property& p = *resolveProperty(*layerFor(comp, keys[a].layer), keys[a].prop);
        struct Tagged {
            Keyframe k;
            int tag;  // index into `group`, or -1 for unselected keys
        };
        std::vector<Tagged> moved, rest;
        std::vector<bool> selected(p.keyframes.size(), false);
        for (size_t gi = 0; gi < group.size(); ++gi) {
            const int idx = keys[group[gi]].index;
            if (selected[size_t(idx)]) continue;  // the same key listed twice
            selected[size_t(idx)] = true;
            Keyframe k = p.keyframes[size_t(idx)];
            k.time += dt;
            moved.push_back({k, int(gi)});
        }
        for (size_t i = 0; i < p.keyframes.size(); ++i) {
            if (selected[i]) continue;
            const bool covered = std::any_of(moved.begin(), moved.end(), [&](const Tagged& m) {
                return std::abs(m.k.time - p.keyframes[i].time) < kTimeEps;
            });
            if (!covered) rest.push_back({p.keyframes[i], -1});
        }
        std::vector<Tagged> merged = rest;
        merged.insert(merged.end(), moved.begin(), moved.end());
        std::stable_sort(merged.begin(), merged.end(), [](const Tagged& x, const Tagged& y) { return x.k.time < y.k.time; });
        p.keyframes.clear();
        for (size_t i = 0; i < merged.size(); ++i) {
            p.keyframes.push_back(merged[i].k);
            if (merged[i].tag >= 0) {
                // Every listing of this key (duplicates included) gets its new index.
                const int oldIdx = keys[group[size_t(merged[i].tag)]].index;
                for (size_t gi : group)
                    if (keys[gi].index == oldIdx) result[gi].index = int(i);
            }
        }
        for (size_t gi : group) done[gi] = true;
    }
    return result;
}

bool Document::removeKeyframes(ObjectId comp, const std::vector<KeyAddress>& keys) {
    std::vector<KeyAddress> valid;
    for (const KeyAddress& k : keys) {
        Layer* l = layerFor(comp, k.layer);
        const Property* p = l ? resolveProperty(*l, k.prop) : nullptr;
        if (p && k.index >= 0 && k.index < int(p->keyframes.size()) &&
            std::find(valid.begin(), valid.end(), k) == valid.end())
            valid.push_back(k);
    }
    if (valid.empty()) return false;
    edit(valid.size() == 1 ? "Delete Keyframe" : "Delete Keyframes");
    // Highest index first so earlier erasures don't shift later ones.
    std::sort(valid.begin(), valid.end(), [](const KeyAddress& a, const KeyAddress& b) { return a.index > b.index; });
    for (const KeyAddress& k : valid) {
        Property& p = *resolveProperty(*layerFor(comp, k.layer), k.prop);
        if (p.keyframes.size() == 1) p.value = p.keyframes.front().value;  // keeps its last value
        p.keyframes.erase(p.keyframes.begin() + k.index);
    }
    return true;
}

bool Document::setKeyframesInterpolation(ObjectId comp, const std::vector<KeyAddress>& keys, std::optional<Interp> in,
                                         std::optional<Interp> out) {
    bool any = false;
    for (const KeyAddress& k : keys) {
        Layer* l = layerFor(comp, k.layer);
        const Property* p = l ? resolveProperty(*l, k.prop) : nullptr;
        if (!p || k.index < 0 || k.index >= int(p->keyframes.size())) continue;
        const Keyframe& kf = p->keyframes[size_t(k.index)];
        if ((in && kf.inInterp != *in) || (out && kf.outInterp != *out)) any = true;
    }
    if (!any) return false;
    edit("Keyframe Interpolation");
    for (const KeyAddress& k : keys) {
        Layer* l = layerFor(comp, k.layer);
        Property* p = l ? resolveProperty(*l, k.prop) : nullptr;
        if (!p || k.index < 0 || k.index >= int(p->keyframes.size())) continue;
        Keyframe& kf = p->keyframes[size_t(k.index)];
        if (in) kf.inInterp = *in;
        if (out) kf.outInterp = *out;
    }
    return true;
}

int Document::insertKeyframes(ObjectId comp, ObjectId layer,
                              const std::vector<std::pair<PropRef, std::vector<Keyframe>>>& tracks) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0) return 0;
    bool any = false;
    for (const auto& [ref, keys] : tracks) any = any || (resolveProperty(*l0, ref) && !keys.empty());
    if (!any) return 0;
    edit("Paste Keyframes");
    Layer& l = *layerFor(comp, layer);
    int written = 0;
    for (const auto& [ref, keys] : tracks) {
        Property* p = resolveProperty(l, ref);
        if (!p) continue;
        const PropDef& def = *propertyDef(l, ref);
        for (Keyframe k : keys) {
            for (int i = def.dims; i < 4; ++i) k.value[size_t(i)] = 0;
            for (int i = 0; i < def.dims; ++i) k.value[size_t(i)] = std::clamp(k.value[size_t(i)], def.minValue, def.maxValue);
            if (!def.spatial) {
                k.spatial = Spatial::Linear;
                k.tangentIn = k.tangentOut = Value{};
            }
            if (int i = findKeyAt(*p, k.time); i >= 0) p->keyframes.erase(p->keyframes.begin() + i);
            auto it = std::upper_bound(p->keyframes.begin(), p->keyframes.end(), k.time,
                                       [](double t, const Keyframe& x) { return t < x.time; });
            p->keyframes.insert(it, k);
            ++written;
        }
    }
    return written;
}

// ---------------------------------------------------------------------------------------------
// Several layers at once

bool Document::removeLayers(ObjectId comp, const std::vector<ObjectId>& ids) {
    Composition* c0 = project_.findComposition(comp);
    if (!c0) return false;
    std::vector<ObjectId> valid;
    for (ObjectId id : ids)
        if (c0->findLayer(id) && std::find(valid.begin(), valid.end(), id) == valid.end()) valid.push_back(id);
    if (valid.empty()) return false;
    edit(valid.size() == 1 ? "Delete Layer" : "Delete Layers");
    Composition& c = *project_.findComposition(comp);
    auto gone = [&](ObjectId id) { return std::find(valid.begin(), valid.end(), id) != valid.end(); };
    c.layers.erase(std::remove_if(c.layers.begin(), c.layers.end(), [&](const Layer& l) { return gone(l.id); }),
                   c.layers.end());
    for (Layer& l : c.layers) {
        if (gone(l.parent)) l.parent = 0;
        if (gone(l.matteLayer)) {
            l.matteLayer = 0;
            l.matteMode = MatteMode::None;
        }
    }
    return true;
}

std::vector<ObjectId> Document::duplicateLayers(ObjectId comp, const std::vector<ObjectId>& ids) {
    std::vector<Layer> copies;
    int top = INT32_MAX;
    if (const Composition* c = project_.findComposition(comp))
        for (const Layer& l : c->layers)  // keep stacking order
            if (std::find(ids.begin(), ids.end(), l.id) != ids.end()) {
                copies.push_back(l);
                top = std::min(top, c->indexOf(l.id));
            }
    if (copies.empty()) return {};
    return insertLayers(comp, std::move(copies), {}, top);
}

std::vector<ObjectId> Document::splitLayers(ObjectId comp, const std::vector<ObjectId>& ids, double time) {
    const Composition* c0 = project_.findComposition(comp);
    if (!c0) return {};
    const double t = c0->snapToFrame(time), fd = c0->frameDuration();
    std::vector<ObjectId> splitting;
    for (ObjectId id : ids)
        if (const Layer* l = c0->findLayer(id);
            l && t - l->inPoint >= fd - kTimeEps && l->outPoint - t >= fd - kTimeEps &&
            std::find(splitting.begin(), splitting.end(), id) == splitting.end())
            splitting.push_back(id);
    if (splitting.empty()) return {};
    Project& p = edit(splitting.size() == 1 ? "Split Layer" : "Split Layers");
    Composition& c = *p.findComposition(comp);
    std::vector<ObjectId> out;
    for (ObjectId id : splitting) {
        const int idx = c.indexOf(id);
        Layer copy = c.layers[idx];  // keeps its name, like the halves of a cut clip
        copy.id = p.allocateId();
        for (Mask& m : copy.masks) m.id = p.allocateId();
        for (Effect& e : copy.effects) e.id = p.allocateId();
        for (TextAnimator& a : copy.animators) a.id = p.allocateId();
        copy.inPoint = t;
        c.layers[idx].outPoint = t;
        c.layers.insert(c.layers.begin() + idx, std::move(copy));
        out.push_back(c.layers[idx].id);
    }
    return out;
}

std::vector<ObjectId> Document::insertLayers(ObjectId comp, std::vector<Layer> layers, const std::vector<Asset>& assets,
                                             int atIndex) {
    if (!project_.findComposition(comp) || layers.empty()) return {};
    Project& p = edit(layers.size() == 1 ? "Paste Layer" : "Paste Layers");
    Composition& c = *p.findComposition(comp);
    // Media: reuse this project's asset for the same file, otherwise add it.
    std::unordered_map<ObjectId, ObjectId> assetMap;
    for (const Asset& a : assets) {
        ObjectId id = 0;
        for (const Asset& mine : p.assets)
            if (mine.path == a.path) id = mine.id;
        if (!id && !a.path.empty()) {
            Asset copy = a;
            copy.id = id = p.allocateId();
            p.assets.push_back(copy);
        }
        assetMap[a.id] = id;
    }
    std::unordered_map<ObjectId, ObjectId> idMap;
    for (Layer& l : layers) {
        const ObjectId fresh = p.allocateId();
        idMap[l.id] = fresh;
        l.id = fresh;
        for (Mask& m : l.masks) m.id = p.allocateId();
        for (Effect& e : l.effects) e.id = p.allocateId();
        for (TextAnimator& a : l.animators) a.id = p.allocateId();
        if (l.kind == LayerKind::Image || l.kind == LayerKind::Audio) {
            auto it = assetMap.find(l.asset);
            if (it != assetMap.end()) l.asset = it->second;
            else if (!p.findAsset(l.asset)) l.asset = 0;
        }
        l.name = uniqueName(c, l.name);
    }
    std::vector<ObjectId> out;
    for (Layer& l : layers) {
        auto pi = idMap.find(l.parent);
        l.parent = pi != idMap.end() ? pi->second : 0;
        auto mi = idMap.find(l.matteLayer);
        if (mi != idMap.end()) {
            l.matteLayer = mi->second;
        } else {
            l.matteLayer = 0;
            l.matteMode = MatteMode::None;
        }
        out.push_back(l.id);
    }
    atIndex = std::clamp(atIndex, 0, int(c.layers.size()));
    c.layers.insert(c.layers.begin() + atIndex, layers.begin(), layers.end());
    return out;
}

// ---------------------------------------------------------------------------------------------
// Text, paths, graph easing

bool Document::setLayerText(ObjectId comp, ObjectId layer, const TextData& text) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind != LayerKind::Text || l0->text == text) return false;
    edit("Edit Text");
    layerFor(comp, layer)->text = text;
    return true;
}

ObjectId Document::addTextAnimator(ObjectId comp, ObjectId layer, AnimatorPreset preset) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind != LayerKind::Text) return 0;
    Project& p = edit("Add Text Animator");
    Layer& l = *layerFor(comp, layer);
    TextAnimator a = makeTextAnimator(p.allocateId());
    switch (preset) {
        case AnimatorPreset::Opacity:
            a.name = "Opacity";
            a.param(AnimParam::Opacity).value[0] = 0;
            break;
        case AnimatorPreset::Position:
            a.name = "Position";
            a.param(AnimParam::Position).value = {0, 80, 0, 0};
            break;
        case AnimatorPreset::Scale:
            a.name = "Scale";
            a.param(AnimParam::Scale).value[0] = 0;
            break;
        case AnimatorPreset::Rotation:
            a.name = "Rotation";
            a.param(AnimParam::Rotation).value[0] = 90;
            break;
    }
    a.name = "Animator " + std::to_string(l.animators.size() + 1) + " (" + a.name + ")";
    l.animators.push_back(a);
    return a.id;
}

bool Document::removeTextAnimator(ObjectId comp, ObjectId layer, ObjectId animator) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || !l0->findAnimator(animator)) return false;
    edit("Remove Text Animator");
    auto& v = layerFor(comp, layer)->animators;
    v.erase(std::remove_if(v.begin(), v.end(), [&](const TextAnimator& a) { return a.id == animator; }), v.end());
    return true;
}

bool Document::setTextAnimatorOptions(ObjectId comp, ObjectId layer, ObjectId animator, bool enabled, SelectorShape shape,
                                      SelectorUnit unit) {
    Layer* l0 = layerFor(comp, layer);
    const TextAnimator* a0 = l0 ? l0->findAnimator(animator) : nullptr;
    if (!a0 || (a0->enabled == enabled && a0->shape == shape && a0->unit == unit)) return false;
    edit("Text Animator");
    TextAnimator* a = layerFor(comp, layer)->findAnimator(animator);
    a->enabled = enabled;
    a->shape = shape;
    a->unit = unit;
    return true;
}

ObjectId Document::addPathLayer(ObjectId comp, const std::vector<PathVertex>& pts, bool closed) {
    if (!project_.findComposition(comp) || pts.size() < 2) return 0;
    BezierPath path;
    path.vertices = pts;
    path.closed = closed;
    Vec2 mn, mx;
    pathBounds(path, mn, mx);
    const Vec2 centre{(mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5};
    for (PathVertex& v : path.vertices) v.p = v.p - centre;
    Project& p = edit("Draw Shape");
    Composition& c = *p.findComposition(comp);
    Layer l = makeLayer(LayerKind::Shape, c, p.allocateId());
    l.shape = ShapeType::Path;
    l.path = path;
    l.prop(PropId::Position).value = {centre.x, centre.y, 0, 0};
    l.fillEnabled = closed;
    l.strokeEnabled = !closed;
    l.name = uniqueName(c, closed ? "Shape" : "Line");
    c.layers.insert(c.layers.begin(), l);
    return l.id;
}

bool Document::setLayerPath(ObjectId comp, ObjectId layer, const BezierPath& path) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind != LayerKind::Shape || l0->path == path) return false;
    edit("Edit Path");
    Layer& l = *layerFor(comp, layer);
    l.path = path;
    l.shape = ShapeType::Path;
    return true;
}

ObjectId Document::addPathMask(ObjectId comp, ObjectId layer, const BezierPath& path) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind == LayerKind::Null || l0->kind == LayerKind::Audio || path.empty()) return 0;
    Project& p = edit("Draw Mask");
    Layer& l = *layerFor(comp, layer);
    Mask m;
    m.id = p.allocateId();
    m.shape = MaskShape::Path;
    m.name = "Mask " + std::to_string(l.masks.size() + 1);
    for (int i = 0; i < kMaskParamCount; ++i) m.params[size_t(i)].value = maskParamDef(static_cast<MaskParam>(i)).defaultValue;
    m.path = path;
    m.path.closed = true;
    l.masks.push_back(m);
    return m.id;
}

bool Document::setMaskPath(ObjectId comp, ObjectId layer, ObjectId mask, const BezierPath& path) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0 || m0->path == path) return false;
    edit("Edit Mask Path");
    Mask* m = layerFor(comp, layer)->findMask(mask);
    m->path = path;
    m->shape = MaskShape::Path;
    return true;
}

bool Document::setMaskPathAt(ObjectId comp, ObjectId layer, ObjectId mask, double time, const BezierPath& path) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0 || path.empty()) return false;
    const bool keyed = !m0->pathKeys.empty() || m0->pathTrack;
    if (!keyed) return setMaskPath(comp, layer, mask, path);
    const Composition* c = project_.findComposition(comp);
    const double t = c ? c->snapToFrame(time) : time;
    if (!m0->pathTrack) {
        auto same = std::find_if(m0->pathKeys.begin(), m0->pathKeys.end(), [&](const PathKey& k) { return std::abs(k.time - t) < kTimeEps; });
        if (same != m0->pathKeys.end() && same->path == path) return false;
    }
    edit("Edit Mask Path");
    Mask& m = *layerFor(comp, layer)->findMask(mask);
    if (m.pathTrack) {  // hand corrections on a tracked mask: it becomes keyframes, starting with this one
        m.pathTrack.reset();
        m.pathKeys.clear();
    }
    m.shape = MaskShape::Path;
    auto it = std::find_if(m.pathKeys.begin(), m.pathKeys.end(), [&](const PathKey& k) { return std::abs(k.time - t) < kTimeEps; });
    if (it != m.pathKeys.end()) {
        it->path = path;
    } else {
        auto at = std::upper_bound(m.pathKeys.begin(), m.pathKeys.end(), t, [](double x, const PathKey& k) { return x < k.time; });
        m.pathKeys.insert(at, PathKey{t, path});
    }
    m.path = path;
    return true;
}

bool Document::setMaskPathAnimated(ObjectId comp, ObjectId layer, ObjectId mask, bool animated, double time) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0 || animated == (!m0->pathKeys.empty() || bool(m0->pathTrack))) return false;
    const BezierPath now = maskPathAt(*m0, time);
    if (now.empty()) return false;
    edit(animated ? "Animate Mask Path" : "Stop Animating Mask Path");
    Mask& m = *layerFor(comp, layer)->findMask(mask);
    const Composition* c = project_.findComposition(comp);
    m.shape = MaskShape::Path;
    m.path = now;
    m.pathTrack.reset();
    m.pathKeys.clear();
    if (animated) m.pathKeys.push_back({c ? c->snapToFrame(time) : time, now});
    return true;
}

bool Document::removeMaskPathKey(ObjectId comp, ObjectId layer, ObjectId mask, double time) {
    Layer* l0 = layerFor(comp, layer);
    const Mask* m0 = l0 ? l0->findMask(mask) : nullptr;
    if (!m0) return false;
    auto it = std::find_if(m0->pathKeys.begin(), m0->pathKeys.end(), [&](const PathKey& k) { return std::abs(k.time - time) < 0.5 / 240; });
    if (it == m0->pathKeys.end()) return false;
    const size_t index = size_t(it - m0->pathKeys.begin());
    edit("Delete Mask Path Key");
    Mask& m = *layerFor(comp, layer)->findMask(mask);
    m.path = m.pathKeys[index].path;
    m.pathKeys.erase(m.pathKeys.begin() + index);
    return true;
}

ObjectId Document::addTrackedMask(ObjectId comp, ObjectId layer, const PathTrack& track, const std::string& name) {
    Layer* l0 = layerFor(comp, layer);
    if (!l0 || l0->kind == LayerKind::Null || l0->kind == LayerKind::Audio || track.frames.empty()) return 0;
    Project& p = edit("Roto Brush");
    Layer& l = *layerFor(comp, layer);
    Mask m;
    m.id = p.allocateId();
    m.shape = MaskShape::Path;
    m.name = name.empty() ? "Roto Brush" : name;
    for (int i = 0; i < kMaskParamCount; ++i) m.params[size_t(i)].value = maskParamDef(static_cast<MaskParam>(i)).defaultValue;
    m.param(MaskParam::Feather).value = {2, 0, 0, 0};  // a soft edge hides the outline's steps
    m.path = track.frames.front();
    m.pathTrack = Shared<PathTrack>(track);
    l.masks.push_back(std::move(m));
    return l.masks.back().id;
}

bool Document::setKeyframeEase(ObjectId comp, ObjectId layer, PropRef prop, int index, bool outgoing, double influence,
                               double slope) {
    Layer* l0 = layerFor(comp, layer);
    const Property* p0 = l0 ? resolveProperty(*l0, prop) : nullptr;
    if (!p0 || index < 0 || index >= int(p0->keyframes.size())) return false;
    influence = std::clamp(influence, 0.01, 1.0);
    slope = std::clamp(slope, -20.0, 20.0);
    const Keyframe& k0 = p0->keyframes[size_t(index)];
    if (outgoing ? (k0.outInterp == Interp::Bezier && k0.easeOut == influence && k0.outSlope == slope)
                 : (k0.inInterp == Interp::Bezier && k0.easeIn == influence && k0.inSlope == slope))
        return false;
    edit("Keyframe Velocity");
    Keyframe& k = resolveProperty(*layerFor(comp, layer), prop)->keyframes[size_t(index)];
    if (outgoing) {
        k.outInterp = Interp::Bezier;
        k.easeOut = influence;
        k.outSlope = slope;
    } else {
        k.inInterp = Interp::Bezier;
        k.easeIn = influence;
        k.inSlope = slope;
    }
    return true;
}

}  // namespace mf
