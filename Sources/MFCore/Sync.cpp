#include "mf/Sync.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <limits>

#include "mf/Json.hpp"
#include "mf/ProjectIO.hpp"

namespace mf {
namespace {

// Objects with sorted keys, so equal content is equal text whichever way it was built (the server's
// jsonb reorders keys).
Json sortedCopy(const Json& j) {
    if (j.isArray()) {
        Json a = Json::array();
        for (const Json& v : j.items()) a.push(sortedCopy(v));
        return a;
    }
    if (j.isObject()) {
        Json::Object members;
        for (const auto& [k, v] : j.members()) members.emplace_back(k, sortedCopy(v));
        std::sort(members.begin(), members.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
        return Json(std::move(members));
    }
    return j;
}

std::string canonical(const Json& j) { return sortedCopy(j).dump(0); }

std::string compKey(ObjectId c) { return "comp/" + std::to_string(c); }
std::string assetKey(ObjectId a) { return "asset/" + std::to_string(a); }
std::string layerKey(ObjectId c, ObjectId l) { return "layer/" + std::to_string(c) + "/" + std::to_string(l); }
std::string propPrefix(ObjectId c, ObjectId l) { return "prop/" + std::to_string(c) + "/" + std::to_string(l) + "/"; }

// "layer/12/34" → (12, 34); "prop/12/34/position" → (12, 34).
bool parseLayerKey(const std::string& key, ObjectId& comp, ObjectId& layer) {
    const size_t start = key.rfind("layer/", 0) == 0 ? 6 : key.rfind("prop/", 0) == 0 ? 5 : std::string::npos;
    if (start == std::string::npos) return false;
    char* end = nullptr;
    comp = std::strtoull(key.c_str() + start, &end, 10);
    if (!end || *end != '/') return false;
    layer = std::strtoull(end + 1, &end, 10);
    return end && (*end == 0 || *end == '/');
}

bool parseId(const std::string& key, const char* prefix, ObjectId& id) {
    const size_t n = std::strlen(prefix);
    if (key.compare(0, n, prefix) != 0) return false;
    char* end = nullptr;
    id = std::strtoull(key.c_str() + n, &end, 10);
    return end && *end == 0;
}

bool sameSettings(const Composition& a, const Composition& b) {
    return a.name == b.name && a.folder == b.folder && a.width == b.width && a.height == b.height && a.fps == b.fps &&
           a.duration == b.duration && a.background == b.background && a.motionBlur == b.motionBlur &&
           a.shutterAngle == b.shutterAngle && a.shutterPhase == b.shutterPhase &&
           a.motionBlurSamples == b.motionBlurSamples && a.workStart == b.workStart && a.workEnd == b.workEnd;
}

bool sameBase(const Layer& a, const Layer& b) {
    Layer x = a;
    x.props = b.props;
    return x == b;
}

// Small per-Mac offset so two people inserting into the same gap don't pick the same position.
double clientJitter(const std::string& client) {
    uint32_t h = 2166136261u;
    for (unsigned char ch : client) h = (h ^ ch) * 16777619u;
    return (double(h % 1000) / 1000.0 - 0.5) * 0.5;  // -0.25 … 0.25
}

}  // namespace

std::string piecesToJson(const std::vector<SyncPiece>& pieces) {
    std::string out = "[";
    for (size_t i = 0; i < pieces.size(); ++i) {
        const SyncPiece& p = pieces[i];
        if (i) out += ",";
        out += "{\"k\":" + Json(p.key).dump(0) + ",\"v\":" + (p.value.empty() ? std::string("null") : p.value) +
               ",\"c\":" + std::to_string(p.clock) + ",\"n\":" + Json(p.client).dump(0) + "}";
    }
    return out + "]";
}

bool piecesFromJson(const std::string& text, std::vector<SyncPiece>& out, std::string& error) {
    Json j;
    if (!Json::parse(text, j, error)) return false;
    if (!j.isArray()) {
        error = "pieces must be an array";
        return false;
    }
    out.clear();
    for (const Json& p : j.items()) {
        if (!p.get("k").isString() || !p.get("n").isString()) continue;
        SyncPiece s;
        s.key = p.get("k").string();
        s.value = p.get("v").isNull() ? std::string() : canonical(p.get("v"));
        s.clock = static_cast<int64_t>(p.get("c").number(0));
        s.client = p.get("n").string();
        out.push_back(std::move(s));
    }
    return true;
}

SyncEngine::SyncEngine(std::string clientId) : client_(std::move(clientId)) {}

const SyncPiece* SyncEngine::piece(const std::string& key) const {
    auto it = shadow_.find(key);
    return it == shadow_.end() ? nullptr : &it->second;
}

void SyncEngine::assignZ(const Composition& c, PieceMap& out) {
    (void)out;
    const size_t n = c.layers.size();
    std::vector<double> z(n, 0);
    std::vector<bool> known(n, false);
    for (size_t i = 0; i < n; ++i) {
        auto it = z_.find(c.layers[i].id);
        if (it != z_.end()) { z[i] = it->second; known[i] = true; }
    }
    // Keep the longest run of known positions that is already in order (strictly decreasing down the
    // stack); give everything else a position between its kept neighbours.
    std::vector<size_t> idx;
    for (size_t i = 0; i < n; ++i)
        if (known[i]) idx.push_back(i);
    std::vector<int> len(idx.size(), 1), prev(idx.size(), -1);
    int best = -1;
    for (size_t a = 0; a < idx.size(); ++a) {
        for (size_t b = 0; b < a; ++b)
            if (z[idx[b]] > z[idx[a]] && len[b] + 1 > len[a]) { len[a] = len[b] + 1; prev[a] = int(b); }
        if (best < 0 || len[a] > len[size_t(best)]) best = int(a);
    }
    std::vector<bool> keep(n, false);
    for (int k = best; k >= 0; k = prev[size_t(k)]) keep[idx[size_t(k)]] = true;

    const double jitter = clientJitter(client_);
    bool collapsed = false;
    size_t i = 0;
    while (i < n) {
        if (keep[i]) { ++i; continue; }
        size_t j = i;
        while (j < n && !keep[j]) ++j;  // [i, j) need positions
        const size_t m = j - i;
        const bool hasAbove = i > 0, hasBelow = j < n;
        const double hi = hasAbove ? z[i - 1] : 0, lo = hasBelow ? z[j] : 0;
        for (size_t k = 0; k < m; ++k) {
            double v;
            if (hasAbove && hasBelow) {
                const double step = (hi - lo) / double(m + 1);
                if (step < 1e-9) collapsed = true;
                v = hi - step * (double(k) + 1 + jitter * 0.5);
            } else if (hasBelow) {
                v = lo + double(m - k) + jitter * 0.5;
            } else if (hasAbove) {
                v = hi - double(k + 1) - jitter * 0.5;
            } else {
                v = double(m - k);
            }
            z[i + k] = v;
        }
        i = j;
    }
    // Positions squeezed too close together: renumber the whole stack.
    for (size_t k = 1; k < n && !collapsed; ++k) collapsed = !(z[k - 1] > z[k]);
    if (collapsed)
        for (size_t k = 0; k < n; ++k) z[k] = double(n - k);
    for (size_t k = 0; k < n; ++k) z_[c.layers[k].id] = z[k];
}

// Values of every piece of `p` that differs from `previous` (all of them when null), with
// deletions for what `previous` had and `p` doesn't.
SyncEngine::PieceMap SyncEngine::explode(const Project& p, const Project* previous, const std::set<std::string>*) {
    PieceMap out;
    for (const Asset& a : p.assets) {
        const Asset* old = previous ? previous->findAsset(a.id) : nullptr;
        if (old && *old == a) continue;
        Json j = Json::object();
        j.set("id", Json(a.id));
        j.set("kind", Json(a.kind == AssetKind::Audio ? "audio" : a.kind == AssetKind::Video ? "video" : "image"));
        j.set("name", Json(a.name));
        j.set("width", Json(a.width));
        j.set("height", Json(a.height));
        j.set("duration", Json(a.duration));
        if (a.kind == AssetKind::Video) {
            j.set("fps", Json(a.fps));
            j.set("hasAudio", Json(a.hasAudio));
        }
        j.set("media", Json(mediaNameForAsset ? mediaNameForAsset(a) : std::string()));
        out[assetKey(a.id)] = canonical(j);
    }
    if (previous)
        for (const Asset& a : previous->assets)
            if (!p.findAsset(a.id)) out[assetKey(a.id)] = "";

    auto dropLayer = [&](ObjectId c, ObjectId l) {
        out[layerKey(c, l)] = "";
        for (int i = 0; i < kPropCount; ++i) out[propPrefix(c, l) + propDef(PropId(i)).key] = "";
        z_.erase(l);
    };

    for (const Composition& c : p.compositions) {
        const Composition* old = previous ? previous->findComposition(c.id) : nullptr;
        if (!old || !sameSettings(*old, c)) out[compKey(c.id)] = canonical(compositionToJson(c, false));
        std::map<ObjectId, double> before;
        for (const Layer& l : c.layers)
            if (auto it = z_.find(l.id); it != z_.end()) before[l.id] = it->second;
        assignZ(c, out);
        for (const Layer& l : c.layers) {
            const Layer* ol = old ? old->findLayer(l.id) : nullptr;
            const bool moved = !before.count(l.id) || before[l.id] != z_[l.id];
            const bool baseChanged = !ol || moved || !sameBase(*ol, l);
            bool anyProp = !ol;
            for (int i = 0; i < kPropCount && !anyProp; ++i) anyProp = !(ol->props[size_t(i)] == l.props[size_t(i)]);
            if (!baseChanged && !anyProp) continue;
            Json lj = layerToJson(l);
            if (baseChanged) {
                Json::Object base;
                for (const auto& [k, v] : lj.members())
                    if (k != "properties") base.emplace_back(k, v);
                base.emplace_back("z", Json(z_[l.id]));
                out[layerKey(c.id, l.id)] = canonical(Json(std::move(base)));
            }
            const Json& props = lj.get("properties");
            for (int i = 0; i < kPropCount; ++i) {
                if (ol && ol->props[size_t(i)] == l.props[size_t(i)]) continue;
                const char* key = propDef(PropId(i)).key;
                out[propPrefix(c.id, l.id) + key] = canonical(props.get(key));
            }
        }
        if (old)
            for (const Layer& l : old->layers)
                if (!c.findLayer(l.id)) dropLayer(c.id, l.id);
    }
    if (previous)
        for (const Composition& c : previous->compositions)
            if (!p.findComposition(c.id)) {
                out[compKey(c.id)] = "";
                for (const Layer& l : c.layers) dropLayer(c.id, l.id);
            }
    return out;
}

std::vector<SyncPiece> SyncEngine::writeLocal(const PieceMap& values, bool newStep, bool recordUndo) {
    std::vector<SyncPiece> sent;
    Step* step = nullptr;
    bool createdStep = false;
    for (const auto& [key, value] : values) {
        auto it = shadow_.find(key);
        const std::string before = it == shadow_.end() ? std::string() : it->second.value;
        if (before == value) continue;
        SyncPiece p{key, value, ++clock_, client_};
        shadow_[key] = p;
        sent.push_back(p);
        if (!recordUndo) continue;
        if (!step) {
            if (newStep || !stepOpen_ || undo_.empty()) {
                undo_.push_back({});
                createdStep = true;
                stepOpen_ = true;
            }
            step = &undo_.back();
        }
        auto [ch, inserted] = step->changes.try_emplace(key, before, value);
        if (!inserted) ch->second.second = value;
    }
    if (createdStep && step && step->changes.empty()) undo_.pop_back();
    if (recordUndo && !sent.empty()) {
        redo_.clear();
        if (undo_.size() > 500) undo_.erase(undo_.begin());
    }
    return sent;
}

std::vector<SyncPiece> SyncEngine::start(const Project& p) {
    shadow_.clear();
    z_.clear();
    undo_.clear();
    redo_.clear();
    stepOpen_ = false;
    clock_ = 0;
    std::vector<SyncPiece> pieces = writeLocal(explode(p, nullptr, nullptr), false, false);
    last_ = p;
    return pieces;
}

Project SyncEngine::join(const std::vector<SyncPiece>& pieces, const Project& view) {
    shadow_.clear();
    z_.clear();
    undo_.clear();
    redo_.clear();
    stepOpen_ = false;
    clock_ = 0;
    std::set<std::string> keys;
    for (const SyncPiece& p : pieces) {
        auto it = shadow_.find(p.key);
        if (it == shadow_.end() || p.newerThan(it->second)) shadow_[p.key] = p;
        clock_ = std::max(clock_, p.clock);
        keys.insert(p.key);
    }
    Project project;
    project.compositions.clear();
    project.assets.clear();
    project.activeComposition = 0;
    rebuild(keys, project);
    if (project.findComposition(view.activeComposition)) project.activeComposition = view.activeComposition;
    ObjectId maxId = 0;
    for (const Asset& a : project.assets) maxId = std::max(maxId, a.id);
    for (const Composition& c : project.compositions) {
        maxId = std::max(maxId, c.id);
        for (const Layer& l : c.layers) maxId = std::max(maxId, l.id);
    }
    project.nextId = std::max<ObjectId>(maxId + 1, 1);
    last_ = project;
    return project;
}

std::vector<SyncPiece> SyncEngine::collectLocal(const Project& now, bool newStep) {
    std::vector<SyncPiece> sent = writeLocal(explode(now, &last_, nullptr), newStep, true);
    last_ = now;
    return sent;
}

bool SyncEngine::applyRemote(const std::vector<SyncPiece>& pieces, Project& project) {
    std::set<std::string> keys;
    for (const SyncPiece& p : pieces) {
        clock_ = std::max(clock_, p.clock);
        auto it = shadow_.find(p.key);
        if (it != shadow_.end() && !p.newerThan(it->second)) continue;
        if (it != shadow_.end() && it->second.value == p.value) {
            it->second = p;  // same content, newer stamp
            continue;
        }
        shadow_[p.key] = p;
        keys.insert(p.key);
    }
    if (keys.empty()) return false;
    stepOpen_ = false;  // a drag that continues after someone else's edit starts a new step
    return rebuild(keys, project);
}

bool SyncEngine::rebuild(const std::set<std::string>& keys, Project& project) {
    std::set<ObjectId> assets, comps;
    std::set<std::pair<ObjectId, ObjectId>> layers;
    for (const std::string& k : keys) {
        ObjectId a = 0, c = 0, l = 0;
        if (parseId(k, "asset/", a)) assets.insert(a);
        else if (parseId(k, "comp/", c)) comps.insert(c);
        else if (parseLayerKey(k, c, l)) layers.insert({c, l});
    }

    for (ObjectId id : assets) {
        const SyncPiece* sp = piece(assetKey(id));
        auto it = std::find_if(project.assets.begin(), project.assets.end(), [&](const Asset& a) { return a.id == id; });
        if (!sp || sp->deleted()) {
            if (it != project.assets.end()) project.assets.erase(it);
            continue;
        }
        Json j;
        std::string err;
        if (!Json::parse(sp->value, j, err)) continue;
        Asset a;
        a.id = id;
        const std::string kind = j.get("kind").string();
        a.kind = kind == "audio" ? AssetKind::Audio : kind == "video" ? AssetKind::Video : AssetKind::Image;
        a.fps = j.get("fps").number(0);
        a.hasAudio = j.get("hasAudio").boolean(false);
        a.name = j.get("name").string();
        a.width = int(j.get("width").number());
        a.height = int(j.get("height").number());
        a.duration = j.get("duration").number();
        const std::string media = j.get("media").string();
        a.path = (!media.empty() && pathForMedia) ? pathForMedia(media) : std::string();
        std::error_code ec;
        a.missing = a.path.empty() || !std::filesystem::exists(a.path, ec);
        if (it != project.assets.end()) {
            a.generation = it->generation + (it->path != a.path || it->missing != a.missing ? 1 : 0);
            *it = std::move(a);
        } else {
            project.assets.push_back(std::move(a));
        }
    }

    for (ObjectId id : comps) {
        const SyncPiece* sp = piece(compKey(id));
        auto it = std::find_if(project.compositions.begin(), project.compositions.end(),
                               [&](const Composition& c) { return c.id == id; });
        if (!sp || sp->deleted()) {
            if (it != project.compositions.end()) project.compositions.erase(it);
            continue;
        }
        Json j;
        std::string err;
        if (!Json::parse(sp->value, j, err)) continue;
        Composition settings = compositionFromJson(j, nullptr);
        if (it != project.compositions.end()) {
            settings.layers = std::move(it->layers);
            *it = std::move(settings);
        } else {
            project.compositions.push_back(std::move(settings));
            // Its layers may have arrived first.
            const std::string prefix = "layer/" + std::to_string(id) + "/";
            for (auto lt = shadow_.lower_bound(prefix); lt != shadow_.end() && lt->first.compare(0, prefix.size(), prefix) == 0; ++lt) {
                ObjectId c = 0, l = 0;
                if (parseLayerKey(lt->first, c, l)) layers.insert({c, l});
            }
        }
    }

    std::set<ObjectId> touchedComps;
    for (const auto& [cid, lid] : layers) {
        Composition* c = project.findComposition(cid);
        if (!c) continue;
        touchedComps.insert(cid);
        const SyncPiece* base = piece(layerKey(cid, lid));
        auto it = std::find_if(c->layers.begin(), c->layers.end(), [&](const Layer& l) { return l.id == lid; });
        if (!base || base->deleted()) {
            if (it != c->layers.end()) c->layers.erase(it);
            z_.erase(lid);
            continue;
        }
        Json lj;
        std::string err;
        if (!Json::parse(base->value, lj, err)) continue;
        Json props = Json::object();
        const std::string prefix = propPrefix(cid, lid);
        for (auto pt = shadow_.lower_bound(prefix); pt != shadow_.end() && pt->first.compare(0, prefix.size(), prefix) == 0; ++pt) {
            if (pt->second.deleted()) continue;
            Json pj;
            if (Json::parse(pt->second.value, pj, err)) props.set(pt->first.substr(prefix.size()), std::move(pj));
        }
        lj.set("properties", std::move(props));
        Layer l = layerFromJson(lj, *c, nullptr);
        l.id = lid;
        z_[lid] = lj.get("z").number(0);
        if (it != c->layers.end()) *it = std::move(l);
        else c->layers.push_back(std::move(l));
    }
    for (ObjectId cid : touchedComps) {
        Composition* c = project.findComposition(cid);
        std::stable_sort(c->layers.begin(), c->layers.end(), [&](const Layer& a, const Layer& b) {
            const double za = z_[a.id], zb = z_[b.id];
            return za != zb ? za > zb : a.id < b.id;
        });
        dropDanglingLinks(*c);
    }
    if (!project.compositions.empty() && !project.findComposition(project.activeComposition))
        project.activeComposition = project.compositions.front().id;
    last_ = project;
    return true;
}

std::vector<SyncPiece> SyncEngine::revert(std::vector<Step>& from, std::vector<Step>& to, Project& project) {
    if (from.empty()) return {};
    Step s = std::move(from.back());
    from.pop_back();
    stepOpen_ = false;
    PieceMap values;
    Step back;
    for (const auto& [key, change] : s.changes) {
        const SyncPiece* cur = piece(key);
        const std::string now = cur ? cur->value : std::string();
        if (now != change.second) continue;  // someone changed it since: their edit stands
        values[key] = change.first;
        back.changes[key] = {change.second, change.first};
    }
    std::vector<SyncPiece> sent = writeLocal(values, false, false);
    if (!back.changes.empty()) to.push_back(std::move(back));
    std::set<std::string> keys;
    for (const auto& [k, v] : values) keys.insert(k);
    if (!keys.empty()) rebuild(keys, project);
    return sent;
}

std::vector<SyncPiece> SyncEngine::undo(Project& project) { return revert(undo_, redo_, project); }
std::vector<SyncPiece> SyncEngine::redo(Project& project) { return revert(redo_, undo_, project); }

bool SyncEngine::refreshMedia(Project& project) {
    bool changed = false;
    for (Asset& a : project.assets) {
        if (!a.missing) continue;
        const SyncPiece* sp = piece(assetKey(a.id));
        if (!sp || sp->deleted() || !pathForMedia) continue;
        Json j;
        std::string err;
        if (!Json::parse(sp->value, j, err)) continue;
        const std::string media = j.get("media").string();
        if (media.empty()) continue;
        const std::string path = pathForMedia(media);
        std::error_code ec;
        if (!std::filesystem::exists(path, ec)) continue;
        a.path = path;
        a.missing = false;
        a.generation += 1;
        changed = true;
    }
    if (changed) last_ = project;
    return changed;
}

}  // namespace mf
