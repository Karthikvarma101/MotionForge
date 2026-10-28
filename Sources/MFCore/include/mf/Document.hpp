// MotionForge core — the editable document: all mutations go through here so that undo/redo,
// dirty tracking and revision counting stay correct.
//
// Undo uses whole-project snapshots. Projects hold no pixel data (media lives in the renderer's
// asset cache) and baked tracks are shared between snapshots, so a snapshot is small — a few KB
// for typical motion-graphics comps — and snapshot undo is trivially correct for every operation,
// including ones added later. Very large (imported) projects are bounded by a byte budget.
// Interactive drags are wrapped in begin/endGroup so a whole drag is one undo step.
#pragma once

#include <cstdint>
#include <deque>
#include <optional>
#include <utility>
#include <vector>
#include <string>

#include "mf/Model.hpp"

namespace mf {

// One keyframe anywhere in a composition.
struct KeyAddress {
    ObjectId layer = 0;
    PropRef prop;
    int index = 0;
    bool operator==(const KeyAddress&) const = default;
};

class Document {
public:
    Document() : project_(makeDefaultProject()) {}
    explicit Document(Project p) : project_(std::move(p)) {}

    const Project& project() const { return project_; }
    uint64_t revision() const { return revision_; }  // bumps on every change (incl. undo/redo)
    bool dirty() const { return revision_ != savedRevision_; }
    void markSaved() { savedRevision_ = revision_; }
    void replaceProject(Project p);  // open/new: clears history
    void clearHistory();             // forget undo/redo and treat the current state as saved
    void markUnsaved() { savedRevision_ = 0; }  // e.g. restored from an autosave

    // --- undo -------------------------------------------------------------------------------
    bool canUndo() const { return !undo_.empty(); }
    bool canRedo() const { return !redo_.empty(); }
    std::string undoLabel() const { return undo_.empty() ? "" : undo_.back().label; }
    std::string redoLabel() const { return redo_.empty() ? "" : redo_.back().label; }
    bool undo();
    bool redo();
    void beginGroup(const std::string& label);  // nestable; one snapshot for the outermost group
    void endGroup();
    size_t undoDepth() const { return undo_.size(); }
    static constexpr size_t kMaxUndo = 500;
    static constexpr size_t kUndoBudget = 1ull << 30;  // bytes of snapshots kept for undo + redo
    size_t undoBytes() const { return undoBytes_; }

    // --- composition ------------------------------------------------------------------------
    bool setCompositionSettings(ObjectId comp, int width, int height, double fps, double duration, Value background,
                                const std::string& name);
    ObjectId addComposition(const std::string& name, int width, int height, double fps, double duration);
    // Which composition the editor shows. Not an undoable edit (like scrolling), but saved.
    bool setActiveComposition(ObjectId comp);
    // A layer showing `source` in `comp`; refused when it would make a composition contain itself.
    ObjectId addPrecompLayer(ObjectId comp, ObjectId source);
    bool setPrecompOptions(ObjectId comp, ObjectId layer, bool collapse, bool timeRemap, double startTime);

    // --- assets & layers --------------------------------------------------------------------
    ObjectId addImageAsset(const std::string& path, const std::string& name, int width, int height);
    ObjectId addLayer(ObjectId comp, LayerKind kind, ShapeType shape = ShapeType::Rectangle, ObjectId asset = 0);
    bool removeLayer(ObjectId comp, ObjectId layer);
    ObjectId duplicateLayer(ObjectId comp, ObjectId layer);
    bool removeLayers(ObjectId comp, const std::vector<ObjectId>& layers);              // one undo step
    std::vector<ObjectId> duplicateLayers(ObjectId comp, const std::vector<ObjectId>& layers);
    // Inserts copies of `layers` (e.g. from the clipboard) above stack index `atIndex`, with fresh
    // ids. Parent / matte links between the inserted layers are kept, links to anything else are
    // cleared. Media in `assets` is matched to this project's media by path or added.
    std::vector<ObjectId> insertLayers(ObjectId comp, std::vector<Layer> layers, const std::vector<Asset>& assets,
                                       int atIndex);
    bool moveLayer(ObjectId comp, ObjectId layer, int newIndex);  // 0 = top
    bool setLayerName(ObjectId comp, ObjectId layer, const std::string& name);
    bool setLayerVisible(ObjectId comp, ObjectId layer, bool visible);
    bool setLayerTiming(ObjectId comp, ObjectId layer, double in, double out);
    bool setLayerParent(ObjectId comp, ObjectId layer, ObjectId parent);  // refuses cycles
    bool setLayerBlend(ObjectId comp, ObjectId layer, BlendMode mode);
    bool setLayerShape(ObjectId comp, ObjectId layer, ShapeType shape);
    bool setLayerFillStroke(ObjectId comp, ObjectId layer, bool fillOn, bool strokeOn);

    // --- effects, masks, track mattes ------------------------------------------------------
    ObjectId addEffect(ObjectId comp, ObjectId layer, EffectType type);
    bool removeEffect(ObjectId comp, ObjectId layer, ObjectId effect);
    bool moveEffect(ObjectId comp, ObjectId layer, ObjectId effect, int newIndex);
    bool setEffectEnabled(ObjectId comp, ObjectId layer, ObjectId effect, bool enabled);
    // New masks are centred on the layer's content and cover 60% of it.
    ObjectId addMask(ObjectId comp, ObjectId layer, MaskShape shape);
    bool removeMask(ObjectId comp, ObjectId layer, ObjectId mask);
    bool setMaskMode(ObjectId comp, ObjectId layer, ObjectId mask, MaskMode mode, bool inverted);
    bool setMaskShape(ObjectId comp, ObjectId layer, ObjectId mask, MaskShape shape);
    bool setMaskEnabled(ObjectId comp, ObjectId layer, ObjectId mask, bool enabled);
    // Uses `matteLayer` as this layer's track matte and hides the matte layer (it still drives the
    // matte). matteLayer = 0 or mode None clears it. Refuses the layer itself.
    bool setLayerMatte(ObjectId comp, ObjectId layer, ObjectId matteLayer, MatteMode mode);

    // --- text, paths ------------------------------------------------------------------------
    bool setLayerText(ObjectId comp, ObjectId layer, const TextData& text);
    enum class AnimatorPreset { Opacity, Position, Scale, Rotation };
    // Adds a range-selector animator with one property set (e.g. Opacity 0%): animate its Range
    // Start / End / Offset to sweep the effect across the text.
    ObjectId addTextAnimator(ObjectId comp, ObjectId layer, AnimatorPreset preset);
    bool removeTextAnimator(ObjectId comp, ObjectId layer, ObjectId animator);
    bool setTextAnimatorOptions(ObjectId comp, ObjectId layer, ObjectId animator, bool enabled, SelectorShape shape,
                                SelectorUnit unit);
    // A new bezier shape layer from points drawn in composition space (pen tool). The layer is
    // positioned at the path's centre; open paths get a stroke, closed ones a fill.
    ObjectId addPathLayer(ObjectId comp, const std::vector<PathVertex>& compSpace, bool closed);
    bool setLayerPath(ObjectId comp, ObjectId layer, const BezierPath& path);
    ObjectId addPathMask(ObjectId comp, ObjectId layer, const BezierPath& layerSpace);
    bool setMaskPath(ObjectId comp, ObjectId layer, ObjectId mask, const BezierPath& layerSpace);

    // --- properties & keyframes -------------------------------------------------------------
    // Graph editor: sets one side of a keyframe to Bezier with this influence (0–1) and speed
    // (slope of the normalised timing curve: 0 eases to a stop, 1 is linear speed).
    bool setKeyframeEase(ObjectId comp, ObjectId layer, PropRef prop, int index, bool outgoing, double influence,
                         double slope);
    // If the property is animated, writes (adds or replaces) a keyframe at `time`, otherwise sets
    // the static value — the same rule as a stopwatch-style motion tool.
    bool setPropertyValue(ObjectId comp, ObjectId layer, PropRef prop, double time, Value v);
    // Turning animation on adds a key at `time` with the current value; off keeps the value at `time`.
    bool setPropertyAnimated(ObjectId comp, ObjectId layer, PropRef prop, bool animated, double time);
    bool addKeyframe(ObjectId comp, ObjectId layer, PropRef prop, double time);  // at current value
    bool removeKeyframe(ObjectId comp, ObjectId layer, PropRef prop, int index);
    // Moves a key to a new time (replacing a key already there). Returns its new index or -1.
    int moveKeyframe(ObjectId comp, ObjectId layer, PropRef prop, int index, double newTime);
    bool setKeyframeInterpolation(ObjectId comp, ObjectId layer, PropRef prop, int index, Interp in, Interp out);
    bool setKeyframeValue(ObjectId comp, ObjectId layer, PropRef prop, int index, Value v);
    // Spatial properties: Linear / Auto ignore the tangents; Bezier stores them (offsets).
    bool setKeyframeSpatial(ObjectId comp, ObjectId layer, PropRef prop, int index, Spatial mode, Value tangentIn,
                            Value tangentOut);

    // Several keyframes at once (any layers/properties), as one undo step. Moving shifts every
    // selected key by `dt`; a selected key landing on an unselected one replaces it. Returns the
    // keys' new addresses, in the order given.
    std::vector<KeyAddress> moveKeyframes(ObjectId comp, const std::vector<KeyAddress>& keys, double dt);
    bool removeKeyframes(ObjectId comp, const std::vector<KeyAddress>& keys);
    bool setKeyframesInterpolation(ObjectId comp, const std::vector<KeyAddress>& keys, std::optional<Interp> in,
                                   std::optional<Interp> out);
    // Pastes keyframe tracks onto a layer (one undo step). Keys replace keys at the same time;
    // a property that wasn't animated becomes animated. Returns the number of keys written.
    int insertKeyframes(ObjectId comp, ObjectId layer, const std::vector<std::pair<PropRef, std::vector<Keyframe>>>& tracks);

    // Layer-property shorthands.
    bool setPropertyValue(ObjectId c, ObjectId l, PropId p, double t, Value v) { return setPropertyValue(c, l, PropRef::layer(p), t, v); }
    bool setPropertyAnimated(ObjectId c, ObjectId l, PropId p, bool a, double t) { return setPropertyAnimated(c, l, PropRef::layer(p), a, t); }
    bool addKeyframe(ObjectId c, ObjectId l, PropId p, double t) { return addKeyframe(c, l, PropRef::layer(p), t); }
    bool removeKeyframe(ObjectId c, ObjectId l, PropId p, int i) { return removeKeyframe(c, l, PropRef::layer(p), i); }
    int moveKeyframe(ObjectId c, ObjectId l, PropId p, int i, double t) { return moveKeyframe(c, l, PropRef::layer(p), i, t); }
    bool setKeyframeInterpolation(ObjectId c, ObjectId l, PropId p, int i, Interp in, Interp out) {
        return setKeyframeInterpolation(c, l, PropRef::layer(p), i, in, out);
    }

private:
    struct Snapshot {
        Project project;
        std::string label;
        size_t bytes = 0;
    };
    void push(std::deque<Snapshot>& stack, Project p, std::string label);
    void trimHistory();
    // Records an undo point (unless inside a group) and returns the mutable project.
    Project& edit(const std::string& label);
    void touched() { ++revision_; }
    Layer* layerFor(ObjectId comp, ObjectId layer);

    Project project_;
    std::deque<Snapshot> undo_, redo_;
    int groupDepth_ = 0;
    bool groupRecorded_ = false;
    std::string groupLabel_;
    uint64_t revision_ = 1;
    uint64_t savedRevision_ = 1;
    size_t undoBytes_ = 0;
};

// Approximate memory of one copy of `p` (shared baked tracks excluded: copies share them).
size_t approxSnapshotBytes(const Project& p);

}  // namespace mf
