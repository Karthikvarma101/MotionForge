#include "mf/Commands.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <optional>

namespace mf {
namespace {

// The catalog, as JSON so it reads like what Claude sees. Shared argument shapes:
//   composition  id (number) or name (string); omitted = the active composition
//   layer        id (number) or name (string)
//   property     a key from get_layer, e.g. "position", "scale", "rotation", "opacity", "fillColor";
//                with "effect" (id) or "mask" (id) or "animator" (id) it names that item's parameter
//   value        number, [x, y] / [r, g, b, a] (colours 0–1), or "#RRGGBB" for colours
constexpr const char* kCatalogJson = R"JSON([
{"name": "get_project", "scope": "document",
 "description": "Overview of the open MotionForge project: every composition (id, name, size, fps, duration, layer count, which one is active) and all imported media. Call this first.",
 "inputSchema": {"type": "object", "properties": {}}},

{"name": "get_composition", "scope": "document",
 "description": "A composition's settings and its layers from top to bottom: id, name, kind, timing, parent, blend mode, matte, effects, masks, which properties are animated, and transform values at `time`.",
 "inputSchema": {"type": "object", "properties": {
   "composition": {"type": ["integer", "string"], "description": "Id or name; default the active composition"},
   "time": {"type": "number", "description": "Seconds; default 0"}}}},

{"name": "get_layer", "scope": "document",
 "description": "Everything about one layer: each property's key, label, value at `time`, and keyframes (time, value, interpolation); effects and masks with their parameters; text and text animators.",
 "inputSchema": {"type": "object", "required": ["layer"], "properties": {
   "composition": {"type": ["integer", "string"]},
   "layer": {"type": ["integer", "string"], "description": "Layer id or name"},
   "time": {"type": "number"}}}},

{"name": "list_effects", "scope": "document",
 "description": "The effects you can add with add_effect, with each parameter's key, default and range.",
 "inputSchema": {"type": "object", "properties": {}}},

{"name": "create_composition", "scope": "document",
 "description": "Creates a composition and makes it the active one.",
 "inputSchema": {"type": "object", "required": ["name"], "properties": {
   "name": {"type": "string"},
   "width": {"type": "integer", "description": "Pixels, default 1920"},
   "height": {"type": "integer", "description": "Pixels, default 1080 (use 1080x1920 for vertical video)"},
   "fps": {"type": "number", "description": "Default 30"},
   "duration": {"type": "number", "description": "Seconds, default 10"},
   "background": {"description": "Colour: [r,g,b,a] 0–1 or \"#RRGGBB\""}}}},

{"name": "set_composition", "scope": "document",
 "description": "Changes a composition's name, size, frame rate, duration or background colour.",
 "inputSchema": {"type": "object", "properties": {
   "composition": {"type": ["integer", "string"]},
   "name": {"type": "string"}, "width": {"type": "integer"}, "height": {"type": "integer"},
   "fps": {"type": "number"}, "duration": {"type": "number"}, "background": {}}}},

{"name": "set_active_composition", "scope": "document",
 "description": "Shows a composition in the editor (and makes it the one other tools default to).",
 "inputSchema": {"type": "object", "required": ["composition"], "properties": {
   "composition": {"type": ["integer", "string"]}}}},

{"name": "add_layer", "scope": "document",
 "description": "Adds a layer at the top of the composition. kind: shape (with shape rectangle/ellipse/polygon/star), text, null (a controller for parenting), image (a still or video footage) or audio (with `asset`, see import_media), precomp (with `source_composition`). Optional starting values are set without keyframes. Returns the new layer's id.",
 "inputSchema": {"type": "object", "required": ["kind"], "properties": {
   "composition": {"type": ["integer", "string"]},
   "kind": {"type": "string", "enum": ["shape", "text", "null", "image", "audio", "precomp", "camera"]},
   "shape": {"type": "string", "enum": ["rectangle", "ellipse", "polygon", "star"]},
   "name": {"type": "string"},
   "text": {"type": "string", "description": "Text layers; \\n starts a new line"},
   "font": {"type": "string", "description": "PostScript font name, e.g. Helvetica-Bold, Futura-Bold, Georgia"},
   "asset": {"type": ["integer", "string"], "description": "Media id or name (image / audio layers)"},
   "source_composition": {"type": ["integer", "string"]},
   "position": {"description": "[x, y] in composition pixels; default the centre"},
   "size": {"description": "[w, h] shape size in pixels"},
   "fillColor": {}, "strokeColor": {}, "strokeWidth": {"type": "number"},
   "fontSize": {"type": "number"}, "opacity": {"type": "number"},
   "in": {"type": "number", "description": "Seconds the layer starts"},
   "out": {"type": "number", "description": "Seconds the layer ends"}}}},

{"name": "delete_layers", "scope": "document",
 "description": "Deletes layers.",
 "inputSchema": {"type": "object", "required": ["layers"], "properties": {
   "composition": {"type": ["integer", "string"]},
   "layers": {"type": "array", "items": {"type": ["integer", "string"]}}}}},

{"name": "duplicate_layer", "scope": "document",
 "description": "Duplicates a layer (with its keyframes, effects and masks). Returns the copy's id.",
 "inputSchema": {"type": "object", "required": ["layer"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]}}}},

{"name": "set_layer", "scope": "document",
 "description": "Changes a layer's settings: name, visibility, timing (in/out seconds), parent (a layer, or 0 for none), blend mode, shape type, fill/stroke on or off, start_time (precomp/audio/video content offset), stack position (`index`, 0 = top), track matte and the 3D switch (`three_d`: then positionZ, rotationX, rotationY animate it, seen through the topmost camera layer).",
 "inputSchema": {"type": "object", "required": ["layer"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "name": {"type": "string"}, "visible": {"type": "boolean"},
   "in": {"type": "number"}, "out": {"type": "number"},
   "parent": {"type": ["integer", "string"]},
   "blend": {"type": "string", "enum": ["normal", "add", "multiply", "screen", "overlay", "darken", "lighten"]},
   "shape": {"type": "string", "enum": ["rectangle", "ellipse", "polygon", "star"]},
   "fill": {"type": "boolean"}, "stroke": {"type": "boolean"},
   "start_time": {"type": "number"}, "three_d": {"type": "boolean"},
   "index": {"type": "integer"},
   "matte_layer": {"type": ["integer", "string"], "description": "Layer used as this layer's track matte (it is hidden); 0 clears"},
   "matte_mode": {"type": "string", "enum": ["alpha", "alphaInverted", "luma", "lumaInverted", "none"]}}}},

{"name": "set_property", "scope": "document",
 "description": "Sets a property. If it is animated, this writes a keyframe at `time`; otherwise it sets the fixed value. Use set_keyframes to animate.",
 "inputSchema": {"type": "object", "required": ["layer", "property", "value"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "property": {"type": "string"}, "value": {},
   "time": {"type": "number", "description": "Seconds; default 0"},
   "effect": {"type": "integer"}, "mask": {"type": "integer"}, "animator": {"type": "integer"}}}},

{"name": "set_keyframes", "scope": "document",
 "description": "Animates a property with keyframes. Each key: time (s), value, optional interpolation linear (default), ease (ease in and out), ease_in, ease_out or hold. replace=true removes the property's existing keys first.",
 "inputSchema": {"type": "object", "required": ["layer", "property", "keyframes"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "property": {"type": "string"},
   "effect": {"type": "integer"}, "mask": {"type": "integer"}, "animator": {"type": "integer"},
   "replace": {"type": "boolean"},
   "keyframes": {"type": "array", "items": {"type": "object", "required": ["time", "value"], "properties": {
     "time": {"type": "number"}, "value": {},
     "interpolation": {"type": "string", "enum": ["linear", "ease", "ease_in", "ease_out", "hold"]}}}}}}},

{"name": "remove_keyframes", "scope": "document",
 "description": "Removes keyframes at the given times, or all of them (the property keeps its value at `time`, default 0).",
 "inputSchema": {"type": "object", "required": ["layer", "property"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "property": {"type": "string"},
   "effect": {"type": "integer"}, "mask": {"type": "integer"}, "animator": {"type": "integer"},
   "times": {"type": "array", "items": {"type": "number"}}, "time": {"type": "number"}}}},

{"name": "set_text", "scope": "document",
 "description": "Changes a text layer's text, font (PostScript name) or alignment.",
 "inputSchema": {"type": "object", "required": ["layer"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "text": {"type": "string"}, "font": {"type": "string"},
   "align": {"type": "string", "enum": ["left", "center", "right"]}}}},

{"name": "add_text_animator", "scope": "document",
 "description": "Adds a range-selector text animator that offsets one property per character (preset opacity, position, scale or rotation). Animate its \"start\"/\"end\"/\"offset\" (percent) with set_keyframes and animator=<id> to sweep it across the text. Returns its id.",
 "inputSchema": {"type": "object", "required": ["layer", "preset"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "preset": {"type": "string", "enum": ["opacity", "position", "scale", "rotation"]}}}},

{"name": "add_effect", "scope": "document",
 "description": "Adds an effect to a layer (see list_effects). Returns the effect id; change its parameters with set_property and effect=<id>.",
 "inputSchema": {"type": "object", "required": ["layer", "effect"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "effect": {"type": "string", "description": "Effect key, e.g. gaussianBlur, dropShadow, glow"}}}},

{"name": "remove_effect", "scope": "document",
 "description": "Removes an effect from a layer.",
 "inputSchema": {"type": "object", "required": ["layer", "effect"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "effect": {"type": "integer"}}}},

{"name": "add_mask", "scope": "document",
 "description": "Adds a rectangle or ellipse mask to a layer (centred, covering 60% of it). Change it with set_property and mask=<id> (position, size, roundness, feather, expansion, opacity). Returns its id.",
 "inputSchema": {"type": "object", "required": ["layer", "shape"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "shape": {"type": "string", "enum": ["rectangle", "ellipse"]},
   "mode": {"type": "string", "enum": ["add", "subtract", "intersect", "difference"]},
   "inverted": {"type": "boolean"}}}},

{"name": "remove_mask", "scope": "document",
 "description": "Removes a mask from a layer.",
 "inputSchema": {"type": "object", "required": ["layer", "mask"], "properties": {
   "composition": {"type": ["integer", "string"]}, "layer": {"type": ["integer", "string"]},
   "mask": {"type": "integer"}}}},

{"name": "undo", "scope": "document",
 "description": "Undoes the last change (yours or the user's).",
 "inputSchema": {"type": "object", "properties": {}}},

{"name": "redo", "scope": "document",
 "description": "Redoes the last undone change.",
 "inputSchema": {"type": "object", "properties": {}}},

{"name": "render_frame", "scope": "host",
 "description": "Renders the active composition at `time` and returns it as an image, so you can see your work. Use it to check layouts and animation.",
 "inputSchema": {"type": "object", "properties": {
   "time": {"type": "number", "description": "Seconds; default the editor's current time"},
   "max_size": {"type": "integer", "description": "Longest side in pixels, default 1024"}}}},

{"name": "import_media", "scope": "host",
 "description": "Imports video footage (MOV, MP4, M4V, MPG, MTS…), an image (PNG, JPEG, HEIC, WebP, AVIF, PSD, EXR, camera RAW, SVG, PDF…) or audio file (WAV, MP3, M4A, AIFF…) from an absolute path on this Mac. Footage plays in image layers (with its sound). With add_layer=true (default) it is also added as a layer to the active composition. Returns the asset id (and layer id).",
 "inputSchema": {"type": "object", "required": ["path"], "properties": {
   "path": {"type": "string"}, "add_layer": {"type": "boolean"}}}},

{"name": "get_editor_state", "scope": "host",
 "description": "What the user is looking at: the project file, the current time, the selected layers, whether it is playing, and whether there are unsaved changes.",
 "inputSchema": {"type": "object", "properties": {}}},

{"name": "set_time", "scope": "host",
 "description": "Moves the editor's playhead to `time` seconds.",
 "inputSchema": {"type": "object", "required": ["time"], "properties": {"time": {"type": "number"}}}},

{"name": "select_layers", "scope": "host",
 "description": "Selects layers in the editor so the user sees them in the timeline and inspector.",
 "inputSchema": {"type": "object", "required": ["layers"], "properties": {
   "layers": {"type": "array", "items": {"type": ["integer", "string"]}}}}},

{"name": "save_project", "scope": "host",
 "description": "Saves the project to its file, or to `path` (an absolute path ending in .mfproj) for an untitled project or Save As.",
 "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},

{"name": "open_project", "scope": "host",
 "description": "Opens a .mfproj file. Fails if the current project has unsaved changes and save_first is not true.",
 "inputSchema": {"type": "object", "required": ["path"], "properties": {
   "path": {"type": "string"}, "save_first": {"type": "boolean"}}}},

{"name": "export_video", "scope": "host",
 "description": "Exports the active composition (or the from/to range in seconds) to `path`. format: h264 (default), hevc, prores, prores4444 or png (a folder of PNG frames). Exporting needs MotionForge Pro. Returns when the export has started; the export window shows progress.",
 "inputSchema": {"type": "object", "required": ["path"], "properties": {
   "path": {"type": "string"},
   "format": {"type": "string", "enum": ["h264", "hevc", "prores", "prores4444", "png"]},
   "from": {"type": "number"}, "to": {"type": "number"}}}}
])JSON";

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

// Values out: 1-D properties as a number, others as an array of their dims.
Json valueOut(const Value& v, int dims) {
    if (dims <= 1) return Json(v[0]);
    Json a = Json::array();
    for (int i = 0; i < dims; ++i) a.push(Json(std::round(v[size_t(i)] * 10000) / 10000));
    return a;
}

const char* interpOut(const Keyframe& k) {
    const bool in = k.inInterp == Interp::Bezier, out = k.outInterp == Interp::Bezier;
    if (k.outInterp == Interp::Hold) return "hold";
    if (in && out) return "ease";
    if (in) return "ease_in";
    if (out) return "ease_out";
    return "linear";
}

struct Ctx {
    Document& doc;
    const Json& args;
    ObjectId comp = 0;
    std::string error;
    const Project& p() const { return doc.project(); }
    const Composition* c() const { return p().findComposition(comp); }
};

ToolResult fail(std::string message) {
    ToolResult r;
    r.ok = false;
    r.error = std::move(message);
    return r;
}

ToolResult okValue(Json v) {
    ToolResult r;
    r.value = std::move(v);
    return r;
}

bool needComp(Ctx& x) {
    x.comp = x.args.has("composition") ? resolveComposition(x.p(), x.args.get("composition")) : x.p().activeComposition;
    if (!x.c()) {
        x.error = x.args.has("composition") ? "No composition " + x.args.get("composition").dump(0) + " (see get_project)"
                                            : "There is no active composition.";
        return false;
    }
    return true;
}

ObjectId needLayer(Ctx& x, const char* key = "layer") {
    if (!needComp(x)) return 0;
    const ObjectId id = resolveLayer(*x.c(), x.args.get(key));
    if (!id) x.error = std::string("No layer ") + x.args.get(key).dump(0) + " in “" + x.c()->name + "” (see get_composition)";
    return id;
}

// The property named by args: layer property, or a parameter of args.effect / .mask / .animator.
struct ResolvedProp {
    PropRef ref;
    const PropDef* def = nullptr;
};
std::optional<ResolvedProp> resolveProp(Ctx& x, const Layer& l) {
    const std::string key = x.args.get("property").string();
    const std::string k = lower(key);
    auto match = [&](const PropDef& d) { return lower(d.key) == k || lower(d.label) == k; };
    if (x.args.has("effect")) {
        const ObjectId eid = static_cast<ObjectId>(x.args.get("effect").number());
        const Effect* e = l.findEffect(eid);
        if (!e) { x.error = "Layer “" + l.name + "” has no effect " + std::to_string(eid); return std::nullopt; }
        const EffectDef& ed = effectDef(e->type);
        for (size_t i = 0; i < ed.params.size(); ++i)
            if (match(ed.params[i])) return ResolvedProp{PropRef::effect(eid, int(i)), &ed.params[i]};
        x.error = std::string(ed.label) + " has no parameter “" + key + "” (see list_effects)";
        return std::nullopt;
    }
    if (x.args.has("mask")) {
        const ObjectId mid = static_cast<ObjectId>(x.args.get("mask").number());
        if (!l.findMask(mid)) { x.error = "Layer “" + l.name + "” has no mask " + std::to_string(mid); return std::nullopt; }
        for (int i = 0; i < kMaskParamCount; ++i)
            if (match(maskParamDef(MaskParam(i)))) return ResolvedProp{PropRef::mask(mid, MaskParam(i)), &maskParamDef(MaskParam(i))};
        x.error = "Masks have no parameter “" + key + "” (position, size, roundness, feather, expansion, opacity)";
        return std::nullopt;
    }
    if (x.args.has("animator")) {
        const ObjectId aid = static_cast<ObjectId>(x.args.get("animator").number());
        if (!l.findAnimator(aid)) { x.error = "Layer “" + l.name + "” has no text animator " + std::to_string(aid); return std::nullopt; }
        for (int i = 0; i < kAnimParamCount; ++i)
            if (match(animParamDef(AnimParam(i)))) return ResolvedProp{PropRef::animator(aid, AnimParam(i)), &animParamDef(AnimParam(i))};
        x.error = "Text animators have no parameter “" + key + "” (start, end, offset, amount, position, scale, rotation, opacity)";
        return std::nullopt;
    }
    for (int i = 0; i < kPropCount; ++i)
        if (match(propDef(PropId(i)))) return ResolvedProp{PropRef::layer(PropId(i)), &propDef(PropId(i))};
    x.error = "No property “" + key + "” (e.g. position, scale, rotation, opacity, anchorPoint, size, fillColor; see get_layer)";
    return std::nullopt;
}

// Which layer properties mean something for this kind of layer.
std::vector<PropId> relevantProps(const Layer& l) {
    std::vector<PropId> v;
    if (l.kind == LayerKind::Audio) return {PropId::AudioLevel};
    if (l.kind == LayerKind::Camera) return {PropId::Position, PropId::PositionZ, PropId::RotationX, PropId::RotationY, PropId::Rotation, PropId::CameraZoom};
    v = {PropId::AnchorPoint, PropId::Position, PropId::Scale, PropId::Rotation, PropId::Opacity};
    if (l.threeD) v.insert(v.end(), {PropId::PositionZ, PropId::RotationX, PropId::RotationY});
    if (l.kind == LayerKind::Shape) {
        if (l.shape != ShapeType::Path) v.insert(v.end(), {PropId::ShapeSize, PropId::Roundness});
        v.insert(v.end(), {PropId::FillColor, PropId::StrokeColor, PropId::StrokeWidth});
        if (l.shape == ShapeType::Polygon || l.shape == ShapeType::Star) v.push_back(PropId::Points);
        if (l.shape == ShapeType::Star) v.push_back(PropId::InnerRatio);
        if (l.shape == ShapeType::Path) v.insert(v.end(), {PropId::TrimStart, PropId::TrimEnd, PropId::TrimOffset});
    } else if (l.kind == LayerKind::Text) {
        v.insert(v.end(), {PropId::FontSize, PropId::Tracking, PropId::LineHeight, PropId::FillColor, PropId::StrokeColor,
                           PropId::StrokeWidth});
    } else if (l.kind == LayerKind::Precomp && l.timeRemap) {
        v.push_back(PropId::TimeRemap);
    }
    return v;
}

Json propOut(const Property& prop, const PropDef& def, double t, bool withKeys) {
    Json j = Json::object();
    j.set("key", Json(def.key));
    j.set("label", Json(def.label));
    j.set("value", valueOut(evaluateProperty(prop, def, t), def.dims));
    if (def.isColor) j.set("color", Json(true));
    if (prop.baked()) j.set("baked", Json(true));
    if (withKeys && prop.animated()) {
        Json keys = Json::array();
        for (const Keyframe& k : prop.keyframes) {
            Json kj = Json::object();
            kj.set("time", Json(k.time));
            kj.set("value", valueOut(k.value, def.dims));
            kj.set("interpolation", Json(interpOut(k)));
            keys.push(std::move(kj));
        }
        j.set("keyframes", std::move(keys));
    }
    return j;
}

Json layerSummary(const Composition& c, const Layer& l, double t) {
    Json j = Json::object();
    j.set("id", Json(l.id));
    j.set("index", Json(c.indexOf(l.id)));
    j.set("name", Json(l.name));
    j.set("kind", Json(layerKindKey(l.kind)));
    if (l.threeD) j.set("three_d", Json(true));
    if (l.kind == LayerKind::Shape) j.set("shape", Json(shapeTypeKey(l.shape)));
    if (!l.visible) j.set("visible", Json(false));
    j.set("in", Json(l.inPoint));
    j.set("out", Json(l.outPoint));
    if (l.parent) j.set("parent", Json(l.parent));
    if (l.blend != BlendMode::Normal) j.set("blend", Json(blendModeKey(l.blend)));
    if (l.hasMatte()) {
        j.set("matte_layer", Json(l.matteLayer));
        j.set("matte_mode", Json(matteModeKey(l.matteMode)));
    }
    if (l.kind == LayerKind::Text) j.set("text", Json(l.text.string));
    if (l.asset) j.set("asset", Json(l.asset));
    if (l.source) j.set("source_composition", Json(l.source));
    Json animated = Json::array();
    for (int i = 0; i < kPropCount; ++i)
        if (l.props[size_t(i)].animated() || l.props[size_t(i)].baked()) animated.push(Json(propDef(PropId(i)).key));
    if (!animated.items().empty()) j.set("animated", std::move(animated));
    if (l.kind != LayerKind::Audio) {
        Json tr = Json::object();
        for (PropId id : {PropId::Position, PropId::Scale, PropId::Rotation, PropId::Opacity})
            tr.set(propDef(id).key, valueOut(evaluateProperty(l.prop(id), id, t), propDef(id).dims));
        j.set("transform", std::move(tr));
    }
    if (!l.effects.empty()) {
        Json e = Json::array();
        for (const Effect& fx : l.effects) {
            Json ej = Json::object();
            ej.set("id", Json(fx.id));
            ej.set("effect", Json(effectDef(fx.type).key));
            if (!fx.enabled) ej.set("enabled", Json(false));
            e.push(std::move(ej));
        }
        j.set("effects", std::move(e));
    }
    if (!l.masks.empty()) {
        Json m = Json::array();
        for (const Mask& mk : l.masks) {
            Json mj = Json::object();
            mj.set("id", Json(mk.id));
            mj.set("shape", Json(maskShapeKey(mk.shape)));
            mj.set("mode", Json(maskModeKey(mk.mode)));
            m.push(std::move(mj));
        }
        j.set("masks", std::move(m));
    }
    return j;
}

Json compSummary(const Project& p, const Composition& c) {
    Json j = Json::object();
    j.set("id", Json(c.id));
    j.set("name", Json(c.name));
    j.set("width", Json(c.width));
    j.set("height", Json(c.height));
    j.set("fps", Json(c.fps));
    j.set("duration", Json(c.duration));
    j.set("background", valueOut(c.background, 4));
    j.set("layers", Json(int(c.layers.size())));
    if (c.id == p.activeComposition) j.set("active", Json(true));
    return j;
}

// Runs `body` as one undo step "Claude: <tool>".
template <typename F>
ToolResult edit(Document& doc, const std::string& tool, F&& body) {
    doc.beginGroup("Claude: " + tool);
    ToolResult r = body();
    doc.endGroup();
    return r;
}

bool setStatic(Ctx& x, ObjectId layer, PropId id, const Json& v) {
    const PropDef& d = propDef(id);
    Value val{};
    if (!valueFromArgument(v, d.dims, d.isColor, val)) {
        x.error = std::string("Can't read ") + d.key + " value " + v.dump(0);
        return false;
    }
    return x.doc.setPropertyValue(x.comp, layer, PropRef::layer(id), 0, val);
}

// Writes the interpolation named by `name` on key `index` of `ref`.
void applyInterp(Document& doc, ObjectId comp, ObjectId layer, PropRef ref, int index, const std::string& name) {
    Interp in = Interp::Linear, out = Interp::Linear;
    if (name == "ease") in = out = Interp::Bezier;
    else if (name == "ease_in") in = Interp::Bezier;
    else if (name == "ease_out") out = Interp::Bezier;
    else if (name == "hold") in = out = Interp::Hold;
    doc.setKeyframeInterpolation(comp, layer, ref, index, in, out);
}

const Property* propertyOf(const Layer& l, PropRef r) { return resolveProperty(l, r); }

int keyIndexAt(const Property& p, double t) {
    for (size_t i = 0; i < p.keyframes.size(); ++i)
        if (std::abs(p.keyframes[i].time - t) < 1e-6) return int(i);
    return -1;
}

// ---- tools ------------------------------------------------------------------------------------

ToolResult getProject(Ctx& x) {
    Json j = Json::object();
    Json comps = Json::array();
    for (const Composition& c : x.p().compositions) comps.push(compSummary(x.p(), c));
    j.set("compositions", std::move(comps));
    j.set("activeComposition", Json(x.p().activeComposition));
    Json assets = Json::array();
    for (const Asset& a : x.p().assets) {
        Json aj = Json::object();
        aj.set("id", Json(a.id));
        aj.set("name", Json(a.name));
        aj.set("kind", Json(a.kind == AssetKind::Audio ? "audio" : a.kind == AssetKind::Video ? "video" : "image"));
        if (a.kind != AssetKind::Audio) { aj.set("width", Json(a.width)); aj.set("height", Json(a.height)); }
        if (a.kind != AssetKind::Image) aj.set("duration", Json(a.duration));
        if (a.kind == AssetKind::Video) { aj.set("fps", Json(a.fps)); aj.set("has_audio", Json(a.hasAudio)); }
        if (a.missing) aj.set("missing", Json(true));
        assets.push(std::move(aj));
    }
    j.set("media", std::move(assets));
    return okValue(std::move(j));
}

ToolResult getComposition(Ctx& x) {
    if (!needComp(x)) return fail(x.error);
    const double t = x.args.get("time").number(0);
    Json j = compSummary(x.p(), *x.c());
    Json layers = Json::array();
    for (const Layer& l : x.c()->layers) layers.push(layerSummary(*x.c(), l, t));
    j.set("layers", std::move(layers));
    j.set("note", Json("Layer 0 is the top of the stack. Times are seconds; positions are composition pixels from the top-left."));
    return okValue(std::move(j));
}

ToolResult getLayer(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    const Layer& l = *x.c()->findLayer(id);
    const double t = x.args.get("time").number(0);
    Json j = layerSummary(*x.c(), l, t);
    Json props = Json::array();
    for (PropId pid : relevantProps(l)) props.push(propOut(l.prop(pid), propDef(pid), t, true));
    j.set("properties", std::move(props));
    if (l.kind == LayerKind::Text) {
        j.set("font", Json(l.text.font));
        j.set("align", Json(textAlignKey(l.text.align)));
        Json anims = Json::array();
        for (const TextAnimator& a : l.animators) {
            Json aj = Json::object();
            aj.set("id", Json(a.id));
            aj.set("name", Json(a.name));
            Json ps = Json::array();
            for (int i = 0; i < kAnimParamCount; ++i) ps.push(propOut(a.params[size_t(i)], animParamDef(AnimParam(i)), t, true));
            aj.set("parameters", std::move(ps));
            anims.push(std::move(aj));
        }
        if (!anims.items().empty()) j.set("animators", std::move(anims));
    }
    Json effects = Json::array();
    for (const Effect& fx : l.effects) {
        const EffectDef& d = effectDef(fx.type);
        Json ej = Json::object();
        ej.set("id", Json(fx.id));
        ej.set("effect", Json(d.key));
        ej.set("enabled", Json(fx.enabled));
        Json ps = Json::array();
        for (size_t i = 0; i < d.params.size() && i < fx.params.size(); ++i) ps.push(propOut(fx.params[i], d.params[i], t, true));
        ej.set("parameters", std::move(ps));
        effects.push(std::move(ej));
    }
    j.set("effects", std::move(effects));
    Json masks = Json::array();
    for (const Mask& mk : l.masks) {
        Json mj = Json::object();
        mj.set("id", Json(mk.id));
        mj.set("shape", Json(maskShapeKey(mk.shape)));
        mj.set("mode", Json(maskModeKey(mk.mode)));
        mj.set("inverted", Json(mk.inverted));
        Json ps = Json::array();
        for (int i = 0; i < kMaskParamCount; ++i) ps.push(propOut(mk.params[size_t(i)], maskParamDef(MaskParam(i)), t, true));
        mj.set("parameters", std::move(ps));
        masks.push(std::move(mj));
    }
    j.set("masks", std::move(masks));
    return okValue(std::move(j));
}

ToolResult listEffects() {
    Json list = Json::array();
    for (int i = 0; i < kEffectTypeCount; ++i) {
        const EffectDef& d = effectDef(EffectType(i));
        Json e = Json::object();
        e.set("effect", Json(d.key));
        e.set("label", Json(d.label));
        e.set("summary", Json(d.summary));
        Json ps = Json::array();
        for (const PropDef& p : d.params) {
            Json pj = Json::object();
            pj.set("key", Json(p.key));
            pj.set("label", Json(p.label));
            pj.set("default", valueOut(p.defaultValue, p.dims));
            pj.set("min", Json(p.minValue));
            pj.set("max", Json(p.maxValue));
            if (p.isColor) pj.set("color", Json(true));
            ps.push(std::move(pj));
        }
        e.set("parameters", std::move(ps));
        list.push(std::move(e));
    }
    Json j = Json::object();
    j.set("effects", std::move(list));
    return okValue(std::move(j));
}

ToolResult createComposition(Ctx& x) {
    const Json& a = x.args;
    const std::string name = a.get("name").string().empty() ? std::string("Composition") : a.get("name").string();
    const int w = std::clamp(int(a.get("width").number(1920)), 16, 16384);
    const int h = std::clamp(int(a.get("height").number(1080)), 16, 16384);
    const double fps = std::clamp(a.get("fps").number(30), 1.0, 240.0);
    const double dur = std::clamp(a.get("duration").number(10), 0.1, 36000.0);
    return edit(x.doc, "create_composition", [&] {
        const ObjectId id = x.doc.addComposition(name, w, h, fps, dur);
        if (!id) return fail("Couldn't create the composition.");
        if (a.has("background")) {
            Value bg{};
            if (valueFromArgument(a.get("background"), 4, true, bg)) {
                const Composition* c = x.p().findComposition(id);
                x.doc.setCompositionSettings(id, c->width, c->height, c->fps, c->duration, bg, c->name);
            }
        }
        x.doc.setActiveComposition(id);
        Json j = Json::object();
        j.set("composition", Json(id));
        return okValue(std::move(j));
    });
}

ToolResult setComposition(Ctx& x) {
    if (!needComp(x)) return fail(x.error);
    const Composition& c = *x.c();
    const Json& a = x.args;
    Value bg = c.background;
    if (a.has("background") && !valueFromArgument(a.get("background"), 4, true, bg)) return fail("Can't read the background colour.");
    const int w = a.has("width") ? std::clamp(int(a.get("width").number()), 16, 16384) : c.width;
    const int h = a.has("height") ? std::clamp(int(a.get("height").number()), 16, 16384) : c.height;
    const double fps = a.has("fps") ? std::clamp(a.get("fps").number(), 1.0, 240.0) : c.fps;
    const double dur = a.has("duration") ? std::clamp(a.get("duration").number(), 0.1, 36000.0) : c.duration;
    const std::string name = a.has("name") ? a.get("name").string() : c.name;
    return edit(x.doc, "set_composition", [&] {
        if (!x.doc.setCompositionSettings(x.comp, w, h, fps, dur, bg, name)) return fail("Couldn't change the composition.");
        return okValue(compSummary(x.p(), *x.c()));
    });
}

ToolResult setActiveComposition(Ctx& x) {
    if (!needComp(x)) return fail(x.error);
    x.doc.setActiveComposition(x.comp);
    return okValue(compSummary(x.p(), *x.c()));
}

ToolResult addLayer(Ctx& x) {
    if (!needComp(x)) return fail(x.error);
    const Json& a = x.args;
    const std::string kind = lower(a.get("kind").string());
    return edit(x.doc, "add_layer", [&]() -> ToolResult {
        ObjectId id = 0;
        if (kind == "precomp") {
            const ObjectId src = resolveComposition(x.p(), a.get("source_composition"));
            if (!src) return fail("add_layer kind=precomp needs source_composition (see get_project)");
            id = x.doc.addPrecompLayer(x.comp, src);
            if (!id) return fail("A composition can't contain itself.");
        } else if (kind == "image" || kind == "audio") {
            ObjectId asset = 0;
            const Json& ref = a.get("asset");
            for (const Asset& as : x.p().assets) {
                if ((ref.isNumber() && as.id == ObjectId(ref.number())) || (ref.isString() && lower(as.name) == lower(ref.string()))) {
                    asset = as.id;
                    break;
                }
            }
            if (!asset) return fail("add_layer kind=" + kind + " needs an imported `asset` (see import_media / get_project)");
            const Asset* as = x.p().findAsset(asset);
            if ((as->kind == AssetKind::Audio) != (kind == "audio"))
                return fail("That media is " + std::string(as->kind == AssetKind::Audio ? "audio (kind audio)" : "a picture (kind image)") + ".");
            id = x.doc.addLayer(x.comp, as->kind == AssetKind::Audio ? LayerKind::Audio : LayerKind::Image, ShapeType::Rectangle, asset);
        } else {
            std::optional<LayerKind> lk = kind == "shape" ? LayerKind::Shape : kind == "text" ? LayerKind::Text
                                        : kind == "null" ? LayerKind::Null : kind == "camera" ? LayerKind::Camera : std::optional<LayerKind>{};
            if (!lk) return fail("Unknown layer kind “" + kind + "” (shape, text, null, image, audio, precomp, camera)");
            ShapeType shape = ShapeType::Rectangle;
            if (a.has("shape")) {
                auto st = shapeTypeFromKey(lower(a.get("shape").string()));
                if (!st || *st == ShapeType::Path) return fail("shape must be rectangle, ellipse, polygon or star");
                shape = *st;
            }
            id = x.doc.addLayer(x.comp, *lk, shape);
        }
        if (!id) return fail("Couldn't add the layer.");
        if (a.has("name")) x.doc.setLayerName(x.comp, id, a.get("name").string());
        const Layer* l = x.c()->findLayer(id);
        if (l->kind == LayerKind::Text && (a.has("text") || a.has("font"))) {
            TextData td = l->text;
            if (a.has("text")) td.string = a.get("text").string();
            if (a.has("font")) td.font = a.get("font").string();
            x.doc.setLayerText(x.comp, id, td);
            if (!a.has("name") && a.has("text")) x.doc.setLayerName(x.comp, id, td.string.substr(0, td.string.find('\n')).substr(0, 40));
        }
        static const std::pair<const char*, PropId> optional[] = {
            {"position", PropId::Position}, {"size", PropId::ShapeSize}, {"fillColor", PropId::FillColor},
            {"strokeColor", PropId::StrokeColor}, {"strokeWidth", PropId::StrokeWidth}, {"fontSize", PropId::FontSize},
            {"opacity", PropId::Opacity}};
        for (const auto& [key, pid] : optional) {
            if (a.has(key) && !setStatic(x, id, pid, a.get(key))) return fail(x.error);
        }
        if (a.has("strokeColor") || a.has("strokeWidth")) x.doc.setLayerFillStroke(x.comp, id, x.c()->findLayer(id)->fillEnabled, true);
        if (a.has("in") || a.has("out")) {
            const Layer* nl = x.c()->findLayer(id);
            x.doc.setLayerTiming(x.comp, id, a.get("in").number(nl->inPoint), a.get("out").number(nl->outPoint));
        }
        Json j = Json::object();
        j.set("layer", Json(id));
        j.set("name", Json(x.c()->findLayer(id)->name));
        return okValue(std::move(j));
    });
}

ToolResult deleteLayers(Ctx& x) {
    if (!needComp(x)) return fail(x.error);
    std::vector<ObjectId> ids;
    for (const Json& r : x.args.get("layers").items()) {
        const ObjectId id = resolveLayer(*x.c(), r);
        if (!id) return fail("No layer " + r.dump(0));
        ids.push_back(id);
    }
    if (ids.empty()) return fail("layers is empty");
    return edit(x.doc, "delete_layers", [&] {
        if (!x.doc.removeLayers(x.comp, ids)) return fail("Couldn't delete the layers.");
        Json j = Json::object();
        j.set("deleted", Json(int(ids.size())));
        return okValue(std::move(j));
    });
}

ToolResult duplicateLayer(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    return edit(x.doc, "duplicate_layer", [&] {
        const ObjectId copy = x.doc.duplicateLayer(x.comp, id);
        if (!copy) return fail("Couldn't duplicate the layer.");
        Json j = Json::object();
        j.set("layer", Json(copy));
        return okValue(std::move(j));
    });
}

ToolResult setLayer(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    const Json& a = x.args;
    return edit(x.doc, "set_layer", [&]() -> ToolResult {
        const Layer* l = x.c()->findLayer(id);
        if (a.has("name")) x.doc.setLayerName(x.comp, id, a.get("name").string());
        if (a.has("visible")) x.doc.setLayerVisible(x.comp, id, a.get("visible").boolean(true));
        if (a.has("in") || a.has("out")) {
            l = x.c()->findLayer(id);
            const double in = a.get("in").number(l->inPoint), out = a.get("out").number(l->outPoint);
            if (out <= in) return fail("out must be after in");
            x.doc.setLayerTiming(x.comp, id, in, out);
        }
        if (a.has("parent")) {
            const Json& pr = a.get("parent");
            const ObjectId parent = (pr.isNumber() && pr.number() == 0) ? 0 : resolveLayer(*x.c(), pr);
            if (!(pr.isNumber() && pr.number() == 0) && !parent) return fail("No parent layer " + pr.dump(0));
            if (!x.doc.setLayerParent(x.comp, id, parent)) return fail("That parent would make a loop.");
        }
        if (a.has("blend")) {
            auto b = blendModeFromKey(lower(a.get("blend").string()));
            if (!b) return fail("Unknown blend mode");
            x.doc.setLayerBlend(x.comp, id, *b);
        }
        if (a.has("shape")) {
            auto st = shapeTypeFromKey(lower(a.get("shape").string()));
            if (!st || *st == ShapeType::Path) return fail("shape must be rectangle, ellipse, polygon or star");
            x.doc.setLayerShape(x.comp, id, *st);
        }
        if (a.has("fill") || a.has("stroke")) {
            l = x.c()->findLayer(id);
            x.doc.setLayerFillStroke(x.comp, id, a.get("fill").boolean(l->fillEnabled), a.get("stroke").boolean(l->strokeEnabled));
        }
        if (a.has("three_d")) {
            l = x.c()->findLayer(id);
            if (a.get("three_d").boolean(false) && (l->kind == LayerKind::Audio || l->kind == LayerKind::Precomp))
                return fail("Audio and precomp layers can't be 3D");
            x.doc.setLayerThreeD(x.comp, id, a.get("three_d").boolean(false));
        }
        if (a.has("start_time")) x.doc.setLayerStartTime(x.comp, id, a.get("start_time").number());
        if (a.has("matte_layer") || a.has("matte_mode")) {
            const Json& mr = a.get("matte_layer");
            const ObjectId matte = (mr.isNull() || (mr.isNumber() && mr.number() == 0)) ? 0 : resolveLayer(*x.c(), mr);
            auto mode = a.has("matte_mode") ? matteModeFromKey(a.get("matte_mode").string()) : std::optional<MatteMode>(MatteMode::Alpha);
            if (!mode) return fail("Unknown matte_mode");
            if (!x.doc.setLayerMatte(x.comp, id, matte, matte ? *mode : MatteMode::None)) return fail("Couldn't set that track matte.");
        }
        if (a.has("index")) x.doc.moveLayer(x.comp, id, std::clamp(int(a.get("index").number()), 0, int(x.c()->layers.size()) - 1));
        return okValue(layerSummary(*x.c(), *x.c()->findLayer(id), 0));
    });
}

ToolResult setProperty(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    auto rp = resolveProp(x, *x.c()->findLayer(id));
    if (!rp) return fail(x.error);
    Value v{};
    if (!valueFromArgument(x.args.get("value"), rp->def->dims, rp->def->isColor, v))
        return fail(std::string("Can't read value ") + x.args.get("value").dump(0) + " for " + rp->def->key + " (" +
                    std::to_string(rp->def->dims) + (rp->def->isColor ? " components, 0–1, or \"#RRGGBB\")" : " number(s))"));
    const double t = x.args.get("time").number(0);
    return edit(x.doc, "set_property", [&] {
        if (!x.doc.setPropertyValue(x.comp, id, rp->ref, t, v)) return fail("Couldn't set " + std::string(rp->def->key));
        const Property* p = propertyOf(*x.c()->findLayer(id), rp->ref);
        return okValue(propOut(*p, *rp->def, t, false));
    });
}

ToolResult setKeyframes(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    auto rp = resolveProp(x, *x.c()->findLayer(id));
    if (!rp) return fail(x.error);
    struct K { double t; Value v; std::string interp; };
    std::vector<K> keys;
    for (const Json& k : x.args.get("keyframes").items()) {
        K key{k.get("time").number(0), {}, k.get("interpolation").string()};
        if (!valueFromArgument(k.get("value"), rp->def->dims, rp->def->isColor, key.v))
            return fail("Can't read keyframe value " + k.get("value").dump(0));
        keys.push_back(std::move(key));
    }
    if (keys.empty()) return fail("keyframes is empty");
    return edit(x.doc, "set_keyframes", [&] {
        const Property* p = propertyOf(*x.c()->findLayer(id), rp->ref);
        if (p->baked()) return fail(std::string(rp->def->key) + " is baked animation from an import; it can't take keyframes.");
        if (x.args.get("replace").boolean(false) && p->animated()) x.doc.setPropertyAnimated(x.comp, id, rp->ref, false, keys.front().t);
        for (const K& k : keys) {
            p = propertyOf(*x.c()->findLayer(id), rp->ref);
            if (!p->animated()) x.doc.setPropertyAnimated(x.comp, id, rp->ref, true, k.t);
            x.doc.setPropertyValue(x.comp, id, rp->ref, k.t, k.v);
            p = propertyOf(*x.c()->findLayer(id), rp->ref);
            const int idx = keyIndexAt(*p, k.t);
            if (idx >= 0) applyInterp(x.doc, x.comp, id, rp->ref, idx, k.interp);
        }
        p = propertyOf(*x.c()->findLayer(id), rp->ref);
        return okValue(propOut(*p, *rp->def, keys.front().t, true));
    });
}

ToolResult removeKeyframes(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    auto rp = resolveProp(x, *x.c()->findLayer(id));
    if (!rp) return fail(x.error);
    return edit(x.doc, "remove_keyframes", [&] {
        const Property* p = propertyOf(*x.c()->findLayer(id), rp->ref);
        int removed = 0;
        if (x.args.has("times")) {
            for (const Json& tj : x.args.get("times").items()) {
                p = propertyOf(*x.c()->findLayer(id), rp->ref);
                const int idx = keyIndexAt(*p, tj.number());
                if (idx >= 0 && x.doc.removeKeyframe(x.comp, id, rp->ref, idx)) ++removed;
            }
        } else if (p->animated()) {
            removed = int(p->keyframes.size());
            x.doc.setPropertyAnimated(x.comp, id, rp->ref, false, x.args.get("time").number(0));
        }
        Json j = Json::object();
        j.set("removed", Json(removed));
        return okValue(std::move(j));
    });
}

ToolResult setText(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    const Layer& l = *x.c()->findLayer(id);
    if (l.kind != LayerKind::Text) return fail("“" + l.name + "” isn't a text layer.");
    TextData td = l.text;
    if (x.args.has("text")) td.string = x.args.get("text").string();
    if (x.args.has("font")) td.font = x.args.get("font").string();
    if (x.args.has("align")) {
        auto al = textAlignFromKey(lower(x.args.get("align").string()));
        if (!al) return fail("align must be left, center or right");
        td.align = *al;
    }
    return edit(x.doc, "set_text", [&] {
        if (!x.doc.setLayerText(x.comp, id, td)) return fail("Couldn't change the text.");
        Json j = Json::object();
        j.set("text", Json(td.string));
        j.set("font", Json(td.font));
        return okValue(std::move(j));
    });
}

ToolResult addTextAnimator(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    const std::string preset = lower(x.args.get("preset").string());
    using P = Document::AnimatorPreset;
    std::optional<P> p = preset == "opacity" ? P::Opacity : preset == "position" ? P::Position
                       : preset == "scale" ? P::Scale : preset == "rotation" ? P::Rotation : std::optional<P>{};
    if (!p) return fail("preset must be opacity, position, scale or rotation");
    return edit(x.doc, "add_text_animator", [&] {
        const ObjectId a = x.doc.addTextAnimator(x.comp, id, *p);
        if (!a) return fail("Text animators only go on text layers.");
        Json j = Json::object();
        j.set("animator", Json(a));
        return okValue(std::move(j));
    });
}

ToolResult addEffect(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    const std::string key = x.args.get("effect").string();
    std::optional<EffectType> type = effectTypeFromKey(key);
    if (!type) {
        for (int i = 0; i < kEffectTypeCount; ++i)
            if (lower(effectDef(EffectType(i)).label) == lower(key) || lower(effectDef(EffectType(i)).key) == lower(key)) type = EffectType(i);
    }
    if (!type) return fail("Unknown effect “" + key + "” (see list_effects)");
    return edit(x.doc, "add_effect", [&] {
        const ObjectId e = x.doc.addEffect(x.comp, id, *type);
        if (!e) return fail("Couldn't add the effect.");
        Json j = Json::object();
        j.set("effect", Json(e));
        return okValue(std::move(j));
    });
}

ToolResult removeEffect(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    return edit(x.doc, "remove_effect", [&] {
        if (!x.doc.removeEffect(x.comp, id, ObjectId(x.args.get("effect").number()))) return fail("No such effect on that layer.");
        return okValue(Json::object());
    });
}

ToolResult addMask(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    auto shape = maskShapeFromKey(lower(x.args.get("shape").string()));
    if (!shape || *shape == MaskShape::Path) return fail("shape must be rectangle or ellipse");
    std::optional<MaskMode> mode = MaskMode::Add;
    if (x.args.has("mode")) mode = maskModeFromKey(lower(x.args.get("mode").string()));
    if (!mode) return fail("mode must be add, subtract, intersect or difference");
    return edit(x.doc, "add_mask", [&] {
        const ObjectId m = x.doc.addMask(x.comp, id, *shape);
        if (!m) return fail("Couldn't add the mask.");
        x.doc.setMaskMode(x.comp, id, m, *mode, x.args.get("inverted").boolean(false));
        Json j = Json::object();
        j.set("mask", Json(m));
        return okValue(std::move(j));
    });
}

ToolResult removeMask(Ctx& x) {
    const ObjectId id = needLayer(x);
    if (!id) return fail(x.error);
    return edit(x.doc, "remove_mask", [&] {
        if (!x.doc.removeMask(x.comp, id, ObjectId(x.args.get("mask").number()))) return fail("No such mask on that layer.");
        return okValue(Json::object());
    });
}

ToolResult undoRedo(Document& doc, bool undo) {
    const std::string label = undo ? doc.undoLabel() : doc.redoLabel();
    if (!(undo ? doc.undo() : doc.redo())) return fail(undo ? "Nothing to undo." : "Nothing to redo.");
    Json j = Json::object();
    j.set(undo ? "undid" : "redid", Json(label));
    return okValue(std::move(j));
}

}  // namespace

const std::vector<ToolDef>& toolCatalog() {
    static const std::vector<ToolDef> catalog = [] {
        std::vector<ToolDef> v;
        Json j;
        std::string err;
        if (!Json::parse(kCatalogJson, j, err)) return v;  // caught by the tests
        for (const Json& t : j.items()) {
            v.push_back(ToolDef{t.get("name").string(), t.get("description").string(), t.get("inputSchema"),
                                t.get("scope").string() == "host"});
        }
        return v;
    }();
    return catalog;
}

const ToolDef* findTool(const std::string& name) {
    for (const ToolDef& t : toolCatalog())
        if (t.name == name) return &t;
    return nullptr;
}

ObjectId resolveComposition(const Project& p, const Json& ref) {
    if (ref.isNumber()) return p.findComposition(ObjectId(ref.number())) ? ObjectId(ref.number()) : 0;
    if (ref.isString()) {
        for (const Composition& c : p.compositions)
            if (lower(c.name) == lower(ref.string())) return c.id;
    }
    return 0;
}

ObjectId resolveLayer(const Composition& c, const Json& ref) {
    if (ref.isNumber()) return c.findLayer(ObjectId(ref.number())) ? ObjectId(ref.number()) : 0;
    if (ref.isString()) {
        for (const Layer& l : c.layers)
            if (lower(l.name) == lower(ref.string())) return l.id;
        // "12" as a string still means id 12.
        char* end = nullptr;
        const unsigned long long n = std::strtoull(ref.string().c_str(), &end, 10);
        if (end && *end == 0 && c.findLayer(ObjectId(n))) return ObjectId(n);
    }
    return 0;
}

bool valueFromArgument(const Json& j, int dims, bool isColor, Value& out) {
    out = Value{0, 0, 0, isColor ? 1.0 : 0.0};
    if (j.isNumber()) {
        for (int i = 0; i < std::max(1, dims); ++i) out[size_t(i)] = j.number();
        if (isColor) out[3] = 1;
        return std::isfinite(j.number());
    }
    if (j.isString() && isColor) {
        std::string s = j.string();
        if (!s.empty() && s[0] == '#') s.erase(0, 1);
        if (s.size() != 6 && s.size() != 8) return false;
        for (char c : s)
            if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
        for (size_t i = 0; i < s.size() / 2; ++i) out[i] = std::stoi(s.substr(i * 2, 2), nullptr, 16) / 255.0;
        if (s.size() == 6) out[3] = 1;
        return true;
    }
    if (j.isArray()) {
        const auto& items = j.items();
        if (items.empty()) return false;
        for (size_t i = 0; i < items.size() && i < 4; ++i) {
            if (!items[i].isNumber() || !std::isfinite(items[i].number())) return false;
            out[i] = items[i].number();
        }
        // Colours given as 0–255 are scaled down.
        if (isColor && std::any_of(out.begin(), out.begin() + std::min<size_t>(3, items.size()), [](double v) { return v > 1.0; }))
            for (size_t i = 0; i < 3; ++i) out[i] /= 255.0;
        if (isColor && items.size() == 3) out[3] = 1;
        if (!isColor && items.size() == 1 && dims > 1) out[1] = out[0];  // uniform scale
        return true;
    }
    if (j.isObject()) {
        static const char* names[] = {"x", "y", "z", "w"};
        static const char* colorNames[] = {"r", "g", "b", "a"};
        bool any = false;
        for (size_t i = 0; i < 4; ++i) {
            const Json& v = j.get(isColor ? colorNames[i] : names[i]);
            if (v.isNumber()) { out[i] = v.number(); any = true; }
        }
        return any;
    }
    return false;
}

ToolResult runTool(Document& doc, const std::string& name, const Json& args) {
    const ToolDef* def = findTool(name);
    if (!def) return fail("Unknown tool “" + name + "”.");
    if (def->host) {
        ToolResult r;
        r.handled = false;
        return r;
    }
    static const Json emptyArgs = Json::object();
    Ctx x{doc, args.isObject() ? args : emptyArgs, 0, {}};
    if (name == "get_project") return getProject(x);
    if (name == "get_composition") return getComposition(x);
    if (name == "get_layer") return getLayer(x);
    if (name == "list_effects") return listEffects();
    if (name == "create_composition") return createComposition(x);
    if (name == "set_composition") return setComposition(x);
    if (name == "set_active_composition") return setActiveComposition(x);
    if (name == "add_layer") return addLayer(x);
    if (name == "delete_layers") return deleteLayers(x);
    if (name == "duplicate_layer") return duplicateLayer(x);
    if (name == "set_layer") return setLayer(x);
    if (name == "set_property") return setProperty(x);
    if (name == "set_keyframes") return setKeyframes(x);
    if (name == "remove_keyframes") return removeKeyframes(x);
    if (name == "set_text") return setText(x);
    if (name == "add_text_animator") return addTextAnimator(x);
    if (name == "add_effect") return addEffect(x);
    if (name == "remove_effect") return removeEffect(x);
    if (name == "add_mask") return addMask(x);
    if (name == "remove_mask") return removeMask(x);
    if (name == "undo") return undoRedo(doc, true);
    if (name == "redo") return undoRedo(doc, false);
    return fail("Tool “" + name + "” isn't implemented.");
}

}  // namespace mf
