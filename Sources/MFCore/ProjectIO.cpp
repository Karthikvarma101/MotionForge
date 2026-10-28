#include "mf/ProjectIO.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "mf/Json.hpp"

namespace fs = std::filesystem;

namespace mf {

namespace {

Json valueToJson(const Value& v, int dims) {
    Json a = Json::array();
    for (int i = 0; i < dims; ++i) a.push(Json(v[i]));
    return a;
}

Value valueFromJson(const Json& j, const Value& fallback) {
    Value v = fallback;
    if (j.isNumber()) {
        v[0] = j.number();
        return v;
    }
    const auto& items = j.items();
    for (size_t i = 0; i < std::min<size_t>(items.size(), 4); ++i) v[i] = items[i].number(fallback[i]);
    return v;
}

Json propertyToJson(const Property& p, const PropDef& def) {
    const int dims = def.dims;
    Json o = Json::object();
    o.set("value", valueToJson(p.value, dims));
    if (!p.keyframes.empty()) {
        Json keys = Json::array();
        for (const Keyframe& k : p.keyframes) {
            Json kj = Json::object();
            kj.set("t", Json(k.time));
            kj.set("v", valueToJson(k.value, dims));
            kj.set("in", Json(interpKey(k.inInterp)));
            kj.set("out", Json(interpKey(k.outInterp)));
            kj.set("easeIn", Json(k.easeIn));
            kj.set("easeOut", Json(k.easeOut));
            keys.push(std::move(kj));
        }
        o.set("keyframes", std::move(keys));
    }
    return o;
}

void propertyFromJson(const Json& j, Property& p) {
    p.value = valueFromJson(j.get("value"), p.value);
    p.keyframes.clear();
    for (const Json& kj : j.get("keyframes").items()) {
        Keyframe k;
        k.time = kj.get("t").number();
        k.value = valueFromJson(kj.get("v"), p.value);
        k.inInterp = interpFromKey(kj.get("in").string()).value_or(Interp::Linear);
        k.outInterp = interpFromKey(kj.get("out").string()).value_or(Interp::Linear);
        k.easeIn = kj.get("easeIn").number(1.0 / 3.0);
        k.easeOut = kj.get("easeOut").number(1.0 / 3.0);
        p.keyframes.push_back(k);
    }
    std::stable_sort(p.keyframes.begin(), p.keyframes.end(),
                     [](const Keyframe& a, const Keyframe& b) { return a.time < b.time; });
}

std::string relativeTo(const std::string& path, const std::string& dir) {
    if (dir.empty() || path.empty()) return {};
    std::error_code ec;
    fs::path rel = fs::path(path).lexically_relative(fs::path(dir));
    if (rel.empty()) return {};
    return rel.generic_string();
}

bool exists(const std::string& p) {
    std::error_code ec;
    return !p.empty() && fs::exists(p, ec);
}

}  // namespace

std::string serializeProject(const Project& project, const std::string& projectDir) {
    Json root = Json::object();
    root.set("format", Json(kProjectFormat));
    root.set("version", Json(Project::kFormatVersion));
    root.set("generator", Json("MotionForge 0.1"));
    root.set("nextId", Json(project.nextId));
    root.set("activeComposition", Json(project.activeComposition));

    Json assets = Json::array();
    for (const Asset& a : project.assets) {
        Json aj = Json::object();
        aj.set("id", Json(a.id));
        aj.set("kind", Json("image"));
        aj.set("name", Json(a.name));
        aj.set("relativePath", Json(relativeTo(a.path, projectDir)));
        aj.set("absolutePath", Json(a.path));
        aj.set("width", Json(a.width));
        aj.set("height", Json(a.height));
        assets.push(std::move(aj));
    }
    root.set("assets", std::move(assets));

    Json comps = Json::array();
    for (const Composition& c : project.compositions) {
        Json cj = Json::object();
        cj.set("id", Json(c.id));
        cj.set("name", Json(c.name));
        cj.set("width", Json(c.width));
        cj.set("height", Json(c.height));
        cj.set("fps", Json(c.fps));
        cj.set("duration", Json(c.duration));
        cj.set("background", valueToJson(c.background, 4));
        Json layers = Json::array();
        for (const Layer& l : c.layers) {
            Json lj = Json::object();
            lj.set("id", Json(l.id));
            lj.set("name", Json(l.name));
            lj.set("kind", Json(layerKindKey(l.kind)));
            if (l.kind == LayerKind::Shape) lj.set("shape", Json(shapeTypeKey(l.shape)));
            lj.set("blend", Json(blendModeKey(l.blend)));
            lj.set("visible", Json(l.visible));
            lj.set("fillEnabled", Json(l.fillEnabled));
            lj.set("strokeEnabled", Json(l.strokeEnabled));
            lj.set("in", Json(l.inPoint));
            lj.set("out", Json(l.outPoint));
            lj.set("parent", Json(l.parent));
            lj.set("asset", Json(l.asset));
            Json props = Json::object();
            for (int i = 0; i < kPropCount; ++i) {
                const auto id = static_cast<PropId>(i);
                props.set(propDef(id).key, propertyToJson(l.props[i], propDef(id)));
            }
            lj.set("properties", std::move(props));
            if (!l.masks.empty()) {
                Json masks = Json::array();
                for (const Mask& m : l.masks) {
                    Json mj = Json::object();
                    mj.set("id", Json(m.id));
                    mj.set("name", Json(m.name));
                    mj.set("shape", Json(maskShapeKey(m.shape)));
                    mj.set("mode", Json(maskModeKey(m.mode)));
                    mj.set("inverted", Json(m.inverted));
                    mj.set("enabled", Json(m.enabled));
                    Json mp = Json::object();
                    for (int k = 0; k < kMaskParamCount; ++k) {
                        const PropDef& def = maskParamDef(static_cast<MaskParam>(k));
                        mp.set(def.key, propertyToJson(m.params[size_t(k)], def));
                    }
                    mj.set("properties", std::move(mp));
                    masks.push(std::move(mj));
                }
                lj.set("masks", std::move(masks));
            }
            if (!l.effects.empty()) {
                Json effects = Json::array();
                for (const Effect& e : l.effects) {
                    const EffectDef& def = effectDef(e.type);
                    Json ej = Json::object();
                    ej.set("id", Json(e.id));
                    ej.set("type", Json(def.key));
                    ej.set("enabled", Json(e.enabled));
                    Json ep = Json::object();
                    for (size_t k = 0; k < def.params.size() && k < e.params.size(); ++k)
                        ep.set(def.params[k].key, propertyToJson(e.params[k], def.params[k]));
                    ej.set("params", std::move(ep));
                    effects.push(std::move(ej));
                }
                lj.set("effects", std::move(effects));
            }
            if (l.hasMatte()) {
                Json mt = Json::object();
                mt.set("layer", Json(l.matteLayer));
                mt.set("mode", Json(matteModeKey(l.matteMode)));
                lj.set("trackMatte", std::move(mt));
            }
            layers.push(std::move(lj));
        }
        cj.set("layers", std::move(layers));
        comps.push(std::move(cj));
    }
    root.set("compositions", std::move(comps));
    return root.dump(2) + "\n";
}

bool deserializeProject(const std::string& text, const std::string& projectDir, Project& out, std::string& error) {
    Json root;
    if (!Json::parse(text, root, error)) {
        error = "Not a valid project file (" + error + ")";
        return false;
    }
    if (root.get("format").string() != kProjectFormat) {
        error = "Not a MotionForge project (missing format marker)";
        return false;
    }
    const int version = static_cast<int>(root.get("version").number(0));
    if (version < 1 || version > Project::kFormatVersion) {
        error = "Unsupported project version " + std::to_string(version) + " (this build reads up to " +
                std::to_string(Project::kFormatVersion) + ")";
        return false;
    }
    // Migrations are keyed on `version`. v1 -> v2 only added optional masks/effects/trackMatte
    // keys, so v1 files load unchanged.

    Project p;
    p.nextId = static_cast<ObjectId>(root.get("nextId").number(1));
    p.activeComposition = static_cast<ObjectId>(root.get("activeComposition").number(0));
    ObjectId maxId = 0;

    for (const Json& aj : root.get("assets").items()) {
        Asset a;
        a.id = static_cast<ObjectId>(aj.get("id").number());
        a.name = aj.get("name").string();
        a.width = static_cast<int>(aj.get("width").number());
        a.height = static_cast<int>(aj.get("height").number());
        const std::string rel = aj.get("relativePath").string();
        const std::string abs = aj.get("absolutePath").string();
        const std::string relResolved = (!rel.empty() && !projectDir.empty())
                                            ? (fs::path(projectDir) / rel).lexically_normal().string()
                                            : std::string();
        if (exists(relResolved)) a.path = relResolved;
        else if (exists(abs)) a.path = abs;
        else {
            a.path = !abs.empty() ? abs : relResolved;
            a.missing = true;
        }
        maxId = std::max(maxId, a.id);
        p.assets.push_back(std::move(a));
    }

    for (const Json& cj : root.get("compositions").items()) {
        Composition c;
        c.id = static_cast<ObjectId>(cj.get("id").number());
        c.name = cj.get("name").string();
        c.width = std::clamp(static_cast<int>(cj.get("width").number(1920)), 1, 16384);
        c.height = std::clamp(static_cast<int>(cj.get("height").number(1080)), 1, 16384);
        c.fps = std::clamp(cj.get("fps").number(30), 1.0, 240.0);
        c.duration = std::max(cj.get("duration").number(10), c.frameDuration());
        c.background = valueFromJson(cj.get("background"), c.background);
        maxId = std::max(maxId, c.id);
        for (const Json& lj : cj.get("layers").items()) {
            const LayerKind kind = layerKindFromKey(lj.get("kind").string()).value_or(LayerKind::Shape);
            Layer l = makeLayer(kind, c, static_cast<ObjectId>(lj.get("id").number()));
            l.name = lj.get("name").string();
            l.shape = shapeTypeFromKey(lj.get("shape").string()).value_or(ShapeType::Rectangle);
            l.blend = blendModeFromKey(lj.get("blend").string()).value_or(BlendMode::Normal);
            l.visible = lj.get("visible").boolean(true);
            l.fillEnabled = lj.get("fillEnabled").boolean(true);
            l.strokeEnabled = lj.get("strokeEnabled").boolean(false);
            l.inPoint = lj.get("in").number(0);
            l.outPoint = lj.get("out").number(c.duration);
            l.parent = static_cast<ObjectId>(lj.get("parent").number(0));
            l.asset = static_cast<ObjectId>(lj.get("asset").number(0));
            const Json& props = lj.get("properties");
            for (int i = 0; i < kPropCount; ++i) {
                const auto id = static_cast<PropId>(i);
                const Json& pj = props.get(propDef(id).key);
                if (!pj.isNull()) propertyFromJson(pj, l.props[i]);
            }
            for (const Json& mj : lj.get("masks").items()) {
                Mask m;
                m.id = static_cast<ObjectId>(mj.get("id").number());
                m.name = mj.get("name").string();
                m.shape = maskShapeFromKey(mj.get("shape").string()).value_or(MaskShape::Rectangle);
                m.mode = maskModeFromKey(mj.get("mode").string()).value_or(MaskMode::Add);
                m.inverted = mj.get("inverted").boolean(false);
                m.enabled = mj.get("enabled").boolean(true);
                for (int k = 0; k < kMaskParamCount; ++k) {
                    const PropDef& def = maskParamDef(static_cast<MaskParam>(k));
                    m.params[size_t(k)].value = def.defaultValue;
                    const Json& pj = mj.get("properties").get(def.key);
                    if (!pj.isNull()) propertyFromJson(pj, m.params[size_t(k)]);
                }
                maxId = std::max(maxId, m.id);
                l.masks.push_back(std::move(m));
            }
            for (const Json& ej : lj.get("effects").items()) {
                const auto type = effectTypeFromKey(ej.get("type").string());
                if (!type) continue;  // effect from a newer build: skipped rather than failing the load
                Effect e = makeEffect(*type, static_cast<ObjectId>(ej.get("id").number()));
                e.enabled = ej.get("enabled").boolean(true);
                const EffectDef& def = effectDef(*type);
                for (size_t k = 0; k < def.params.size(); ++k) {
                    const Json& pj = ej.get("params").get(def.params[k].key);
                    if (!pj.isNull()) propertyFromJson(pj, e.params[k]);
                }
                maxId = std::max(maxId, e.id);
                l.effects.push_back(std::move(e));
            }
            const Json& mt = lj.get("trackMatte");
            if (mt.isObject()) {
                l.matteLayer = static_cast<ObjectId>(mt.get("layer").number(0));
                l.matteMode = matteModeFromKey(mt.get("mode").string()).value_or(MatteMode::None);
            }
            maxId = std::max(maxId, l.id);
            c.layers.push_back(std::move(l));
        }
        // Drop dangling parent links rather than failing the whole load.
        for (Layer& l : c.layers) {
            if (l.parent && (!c.findLayer(l.parent) || l.parent == l.id)) l.parent = 0;
            if (l.matteLayer && (!c.findLayer(l.matteLayer) || l.matteLayer == l.id)) {
                l.matteLayer = 0;
                l.matteMode = MatteMode::None;
            }
        }
        p.compositions.push_back(std::move(c));
    }

    if (p.compositions.empty()) {
        error = "Project contains no compositions";
        return false;
    }
    if (!p.findComposition(p.activeComposition)) p.activeComposition = p.compositions.front().id;
    p.nextId = std::max(p.nextId, maxId + 1);
    out = std::move(p);
    return true;
}

bool writeFileAtomic(const std::string& path, const std::string& contents, std::string& error) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) {
            error = "Cannot write " + tmp;
            return false;
        }
        f.write(contents.data(), static_cast<std::streamsize>(contents.size()));
        f.flush();
        if (!f) {
            error = "Write failed for " + tmp;
            return false;
        }
    }
    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) {
        error = "Cannot replace " + path + ": " + ec.message();
        fs::remove(tmp, ec);
        return false;
    }
    return true;
}

bool saveProjectFile(const Project& project, const std::string& path, std::string& error) {
    const std::string dir = fs::path(path).parent_path().string();
    return writeFileAtomic(path, serializeProject(project, dir), error);
}

bool loadProjectFile(const std::string& path, Project& out, std::string& error) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        error = "Cannot open " + path;
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    return deserializeProject(ss.str(), fs::path(path).parent_path().string(), out, error);
}

}  // namespace mf
