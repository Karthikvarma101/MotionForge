#include "mf/ProjectIO.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "mf/Json.hpp"

namespace fs = std::filesystem;

namespace mf {

namespace {
Json valueToJson(const Value& v, int dims);
Value valueFromJson(const Json& j, const Value& fallback);
}  // namespace

Json keyframeToJson(const Keyframe& k, const PropDef& def) {
    Json kj = Json::object();
    kj.set("t", Json(k.time));
    kj.set("v", valueToJson(k.value, def.dims));
    kj.set("in", Json(interpKey(k.inInterp)));
    kj.set("out", Json(interpKey(k.outInterp)));
    kj.set("easeIn", Json(k.easeIn));
    kj.set("easeOut", Json(k.easeOut));
    if (k.inSlope != 0) kj.set("inSlope", Json(k.inSlope));
    if (k.outSlope != 0) kj.set("outSlope", Json(k.outSlope));
    if (def.spatial) {
        kj.set("spatial", Json(spatialKey(k.spatial)));
        if (k.spatial == Spatial::Bezier) {
            kj.set("ti", valueToJson(k.tangentIn, 2));
            kj.set("to", valueToJson(k.tangentOut, 2));
        }
    }
    return kj;
}

Keyframe keyframeFromJson(const Json& kj, const Value& fallback) {
    Keyframe k;
    k.time = kj.get("t").number();
    k.value = valueFromJson(kj.get("v"), fallback);
    k.inInterp = interpFromKey(kj.get("in").string()).value_or(Interp::Linear);
    k.outInterp = interpFromKey(kj.get("out").string()).value_or(Interp::Linear);
    k.easeIn = kj.get("easeIn").number(1.0 / 3.0);
    k.easeOut = kj.get("easeOut").number(1.0 / 3.0);
    k.inSlope = kj.get("inSlope").number(0);
    k.outSlope = kj.get("outSlope").number(0);
    // Files before version 3 had straight motion paths: a missing "spatial" means Linear.
    k.spatial = spatialFromKey(kj.get("spatial").string()).value_or(Spatial::Linear);
    if (k.spatial == Spatial::Bezier) {
        k.tangentIn = valueFromJson(kj.get("ti"), Value{});
        k.tangentOut = valueFromJson(kj.get("to"), Value{});
    }
    return k;
}

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

// Baked tracks are float32 little-endian blobs in base64: compact, and parsed without building a
// JSON node per number.
std::string base64(const void* data, size_t n) {
    static const char* k = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const auto* b = static_cast<const unsigned char*>(data);
    std::string out;
    out.reserve((n + 2) / 3 * 4);
    for (size_t i = 0; i < n; i += 3) {
        const uint32_t v = uint32_t(b[i]) << 16 | (i + 1 < n ? uint32_t(b[i + 1]) << 8 : 0) | (i + 2 < n ? b[i + 2] : 0);
        out += k[v >> 18 & 63];
        out += k[v >> 12 & 63];
        out += i + 1 < n ? k[v >> 6 & 63] : '=';
        out += i + 2 < n ? k[v & 63] : '=';
    }
    return out;
}

std::vector<float> floatsFromBase64(const std::string& s) {
    static const auto table = [] {
        std::array<int8_t, 256> t{};
        t.fill(-1);
        const char* k = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; i < 64; ++i) t[uint8_t(k[i])] = int8_t(i);
        return t;
    }();
    std::vector<uint8_t> bytes;
    bytes.reserve(s.size() / 4 * 3);
    uint32_t acc = 0;
    int bits = 0;
    for (char c : s) {
        const int v = table[uint8_t(c)];
        if (v < 0) continue;  // padding / whitespace
        acc = acc << 6 | uint32_t(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes.push_back(uint8_t(acc >> bits));
        }
    }
    std::vector<float> out(bytes.size() / 4);
    std::memcpy(out.data(), bytes.data(), out.size() * 4);
    return out;
}

Json samplesToJson(const SampledTrack& t) {
    Json o = Json::object();
    o.set("t0", Json(t.t0));
    o.set("rate", Json(t.rate));
    o.set("dims", Json(t.dims));
    o.set("data", Json(base64(t.data.data(), t.data.size() * sizeof(float))));
    return o;
}

Shared<SampledTrack> samplesFromJson(const Json& j) {
    SampledTrack t;
    t.t0 = j.get("t0").number(0);
    t.rate = j.get("rate").number(30);
    t.dims = std::clamp(int(j.get("dims").number(1)), 1, 4);
    t.data = floatsFromBase64(j.get("data").string());
    t.data.resize(t.count() * size_t(t.dims));
    if (t.rate <= 0 || t.count() == 0) return {};
    return Shared<SampledTrack>(std::move(t));
}

// Frames as [vertexCount, closed, (x, y, inX, inY, outX, outY) * vertexCount] ...
Json pathTrackToJson(const PathTrack& t) {
    std::vector<float> f;
    for (const BezierPath& p : t.frames) {
        f.push_back(float(p.vertices.size()));
        f.push_back(p.closed ? 1.f : 0.f);
        for (const PathVertex& v : p.vertices)
            for (double x : {v.p.x, v.p.y, v.in.x, v.in.y, v.out.x, v.out.y}) f.push_back(float(x));
    }
    Json o = Json::object();
    o.set("t0", Json(t.t0));
    o.set("rate", Json(t.rate));
    o.set("frames", Json(int64_t(t.frames.size())));
    o.set("data", Json(base64(f.data(), f.size() * sizeof(float))));
    return o;
}

Shared<PathTrack> pathTrackFromJson(const Json& j) {
    PathTrack t;
    t.t0 = j.get("t0").number(0);
    t.rate = j.get("rate").number(30);
    const std::vector<float> f = floatsFromBase64(j.get("data").string());
    for (size_t i = 0; i + 2 <= f.size();) {
        const size_t n = size_t(std::max(0.f, f[i]));
        BezierPath p;
        p.closed = f[i + 1] != 0;
        i += 2;
        if (i + n * 6 > f.size()) break;
        for (size_t v = 0; v < n; ++v, i += 6)
            p.vertices.push_back({{f[i], f[i + 1]}, {f[i + 2], f[i + 3]}, {f[i + 4], f[i + 5]}});
        t.frames.push_back(std::move(p));
    }
    if (t.frames.empty() || t.rate <= 0) return {};
    return Shared<PathTrack>(std::move(t));
}

Json propertyToJson(const Property& p, const PropDef& def) {
    Json o = Json::object();
    o.set("value", valueToJson(p.value, def.dims));
    if (p.samples) o.set("samples", samplesToJson(*p.samples));
    if (!p.keyframes.empty()) {
        Json keys = Json::array();
        for (const Keyframe& k : p.keyframes) keys.push(keyframeToJson(k, def));
        o.set("keyframes", std::move(keys));
    }
    return o;
}

void propertyFromJson(const Json& j, Property& p) {
    p.value = valueFromJson(j.get("value"), p.value);
    p.keyframes.clear();
    for (const Json& kj : j.get("keyframes").items()) p.keyframes.push_back(keyframeFromJson(kj, p.value));
    std::stable_sort(p.keyframes.begin(), p.keyframes.end(),
                     [](const Keyframe& a, const Keyframe& b) { return a.time < b.time; });
    p.samples = j.has("samples") ? samplesFromJson(j.get("samples")) : Shared<SampledTrack>{};
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

Json pathToJson(const BezierPath& p) {
    Json o = Json::object();
    o.set("closed", Json(p.closed));
    Json vs = Json::array();
    for (const PathVertex& v : p.vertices) {
        Json a = Json::array();
        for (double x : {v.p.x, v.p.y, v.in.x, v.in.y, v.out.x, v.out.y}) a.push(Json(x));
        vs.push(std::move(a));
    }
    o.set("vertices", std::move(vs));
    return o;
}

BezierPath pathFromJson(const Json& j) {
    BezierPath p;
    p.closed = j.get("closed").boolean(true);
    for (const Json& a : j.get("vertices").items()) {
        const auto& n = a.items();
        if (n.size() < 6) continue;
        p.vertices.push_back({{n[0].number(), n[1].number()}, {n[2].number(), n[3].number()}, {n[4].number(), n[5].number()}});
    }
    return p;
}

Json layerToJson(const Layer& l) {
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
    if (l.motionBlur) lj.set("motionBlur", Json(true));
    if (l.kind == LayerKind::Precomp) {
        lj.set("source", Json(l.source));
        lj.set("startTime", Json(l.startTime));
        lj.set("timeRemap", Json(l.timeRemap));
        lj.set("collapse", Json(l.collapse));
    }
    if (l.kind == LayerKind::Audio) lj.set("startTime", Json(l.startTime));
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
            if (m.shape == MaskShape::Path) mj.set("path", pathToJson(m.path));
            if (m.pathTrack) mj.set("pathTrack", pathTrackToJson(*m.pathTrack));
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
    if (l.kind == LayerKind::Shape && l.shape == ShapeType::Path) {
        lj.set("path", pathToJson(l.path));
        if (l.pathTrack) lj.set("pathTrack", pathTrackToJson(*l.pathTrack));
    }
    if (l.kind == LayerKind::Text) {
        Json tj = Json::object();
        tj.set("string", Json(l.text.string));
        tj.set("font", Json(l.text.font));
        tj.set("align", Json(textAlignKey(l.text.align)));
        if (l.text.strokeOverFill) tj.set("strokeOverFill", Json(true));
        lj.set("text", std::move(tj));
        if (!l.animators.empty()) {
            Json anims = Json::array();
            for (const TextAnimator& a : l.animators) {
                Json aj = Json::object();
                aj.set("id", Json(a.id));
                aj.set("name", Json(a.name));
                aj.set("enabled", Json(a.enabled));
                aj.set("shape", Json(selectorShapeKey(a.shape)));
                aj.set("unit", Json(selectorUnitKey(a.unit)));
                if (a.stagger != 0) aj.set("stagger", Json(a.stagger));
                Json ap = Json::object();
                for (int k = 0; k < kAnimParamCount; ++k) {
                    const PropDef& def = animParamDef(static_cast<AnimParam>(k));
                    ap.set(def.key, propertyToJson(a.params[size_t(k)], def));
                }
                aj.set("params", std::move(ap));
                anims.push(std::move(aj));
            }
            lj.set("animators", std::move(anims));
        }
    }
    if (l.hasMatte()) {
        Json mt = Json::object();
        mt.set("layer", Json(l.matteLayer));
        mt.set("mode", Json(matteModeKey(l.matteMode)));
        lj.set("trackMatte", std::move(mt));
    }
    return lj;
}

Layer layerFromJson(const Json& lj, const Composition& c, ObjectId* maxId) {
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
    l.motionBlur = lj.get("motionBlur").boolean(false);
    if (kind == LayerKind::Precomp) {
        l.source = static_cast<ObjectId>(lj.get("source").number(0));
        l.startTime = lj.get("startTime").number(0);
        l.timeRemap = lj.get("timeRemap").boolean(false);
        l.collapse = lj.get("collapse").boolean(false);
    }
    if (kind == LayerKind::Audio) l.startTime = lj.get("startTime").number(0);
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
        if (m.shape == MaskShape::Path) m.path = pathFromJson(mj.get("path"));
        if (mj.has("pathTrack")) m.pathTrack = pathTrackFromJson(mj.get("pathTrack"));
        m.enabled = mj.get("enabled").boolean(true);
        for (int k = 0; k < kMaskParamCount; ++k) {
            const PropDef& def = maskParamDef(static_cast<MaskParam>(k));
            m.params[size_t(k)].value = def.defaultValue;
            const Json& pj = mj.get("properties").get(def.key);
            if (!pj.isNull()) propertyFromJson(pj, m.params[size_t(k)]);
        }
        if (maxId) *maxId = std::max(*maxId, m.id);
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
        if (maxId) *maxId = std::max(*maxId, e.id);
        l.effects.push_back(std::move(e));
    }
    if (lj.has("path")) l.path = pathFromJson(lj.get("path"));
    if (lj.has("pathTrack")) l.pathTrack = pathTrackFromJson(lj.get("pathTrack"));
    if (const Json& tj = lj.get("text"); tj.isObject()) {
        l.text.string = tj.get("string").string();
        l.text.font = tj.get("font").string().empty() ? std::string("Helvetica-Bold") : tj.get("font").string();
        l.text.align = textAlignFromKey(tj.get("align").string()).value_or(TextAlign::Center);
        l.text.strokeOverFill = tj.get("strokeOverFill").boolean(false);
    }
    for (const Json& aj : lj.get("animators").items()) {
        TextAnimator a = makeTextAnimator(static_cast<ObjectId>(aj.get("id").number()));
        a.name = aj.get("name").string();
        a.enabled = aj.get("enabled").boolean(true);
        a.shape = selectorShapeFromKey(aj.get("shape").string()).value_or(SelectorShape::Square);
        a.unit = selectorUnitFromKey(aj.get("unit").string()).value_or(SelectorUnit::Characters);
        a.stagger = aj.get("stagger").number(0);
        for (int k = 0; k < kAnimParamCount; ++k) {
            const PropDef& def = animParamDef(static_cast<AnimParam>(k));
            const Json& pj = aj.get("params").get(def.key);
            if (!pj.isNull()) propertyFromJson(pj, a.params[size_t(k)]);
        }
        if (maxId) *maxId = std::max(*maxId, a.id);
        l.animators.push_back(std::move(a));
    }
    const Json& mt = lj.get("trackMatte");
    if (mt.isObject()) {
        l.matteLayer = static_cast<ObjectId>(mt.get("layer").number(0));
        l.matteMode = matteModeFromKey(mt.get("mode").string()).value_or(MatteMode::None);
    }
    if (maxId) *maxId = std::max(*maxId, l.id);
    return l;
}

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
        aj.set("kind", Json(a.kind == AssetKind::Audio ? "audio" : "image"));
        aj.set("name", Json(a.name));
        aj.set("relativePath", Json(relativeTo(a.path, projectDir)));
        aj.set("absolutePath", Json(a.path));
        aj.set("width", Json(a.width));
        aj.set("height", Json(a.height));
        if (a.kind == AssetKind::Audio) aj.set("duration", Json(a.duration));
        assets.push(std::move(aj));
    }
    root.set("assets", std::move(assets));

    Json comps = Json::array();
    for (const Composition& c : project.compositions) {
        Json cj = Json::object();
        cj.set("id", Json(c.id));
        cj.set("name", Json(c.name));
        if (!c.folder.empty()) cj.set("folder", Json(c.folder));
        cj.set("width", Json(c.width));
        cj.set("height", Json(c.height));
        cj.set("fps", Json(c.fps));
        cj.set("duration", Json(c.duration));
        cj.set("background", valueToJson(c.background, 4));
        if (c.motionBlur) {
            Json mb = Json::object();
            mb.set("shutterAngle", Json(c.shutterAngle));
            mb.set("shutterPhase", Json(c.shutterPhase));
            mb.set("samples", Json(c.motionBlurSamples));
            cj.set("motionBlur", std::move(mb));
        }
        Json layers = Json::array();
        for (const Layer& l : c.layers) {
            Json lj = layerToJson(l);
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
        a.kind = aj.get("kind").string() == "audio" ? AssetKind::Audio : AssetKind::Image;
        a.width = static_cast<int>(aj.get("width").number());
        a.height = static_cast<int>(aj.get("height").number());
        a.duration = aj.get("duration").number(0);
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
        c.folder = cj.get("folder").string();
        c.width = std::clamp(static_cast<int>(cj.get("width").number(1920)), 1, 16384);
        c.height = std::clamp(static_cast<int>(cj.get("height").number(1080)), 1, 16384);
        c.fps = std::clamp(cj.get("fps").number(30), 1.0, 240.0);
        c.duration = std::max(cj.get("duration").number(10), c.frameDuration());
        c.background = valueFromJson(cj.get("background"), c.background);
        if (const Json& mb = cj.get("motionBlur"); mb.isObject()) {
            c.motionBlur = true;
            c.shutterAngle = std::clamp(mb.get("shutterAngle").number(180), 0.0, 720.0);
            c.shutterPhase = std::clamp(mb.get("shutterPhase").number(-90), -360.0, 360.0);
            c.motionBlurSamples = std::clamp(int(mb.get("samples").number(8)), 1, 64);
        }
        maxId = std::max(maxId, c.id);
        for (const Json& lj : cj.get("layers").items()) {
            Layer l = layerFromJson(lj, c, &maxId);
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
