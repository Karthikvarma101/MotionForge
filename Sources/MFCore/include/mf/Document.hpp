// MotionForge core — the editable document: all mutations go through here so that undo/redo,
// dirty tracking and revision counting stay correct.
//
// Undo uses whole-project snapshots. Projects hold no pixel data (media lives in the renderer's
// asset cache), so a snapshot is small — a few KB for typical motion-graphics comps — and
// snapshot undo is trivially correct for every operation, including ones added later.
// Interactive drags are wrapped in begin/endGroup so a whole drag is one undo step.
#pragma once

#include <cstdint>
#include <deque>
#include <string>

#include "mf/Model.hpp"

namespace mf {

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

    // --- composition ------------------------------------------------------------------------
    bool setCompositionSettings(ObjectId comp, int width, int height, double fps, double duration, Value background,
                                const std::string& name);

    // --- assets & layers --------------------------------------------------------------------
    ObjectId addImageAsset(const std::string& path, const std::string& name, int width, int height);
    ObjectId addLayer(ObjectId comp, LayerKind kind, ShapeType shape = ShapeType::Rectangle, ObjectId asset = 0);
    bool removeLayer(ObjectId comp, ObjectId layer);
    ObjectId duplicateLayer(ObjectId comp, ObjectId layer);
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

    // --- properties & keyframes -------------------------------------------------------------
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
    };
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
};

}  // namespace mf
