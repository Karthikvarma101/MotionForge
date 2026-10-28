// MotionForge core — animation presets: a layer's effects, text animators and keyframed
// properties, stored with times relative to the preset start so they can be applied to any layer
// at any time. Position-like tracks are stored as offsets from the layer's own value, so
// "Slide Up" ends where the layer already is instead of jumping to where the preset was made.
#pragma once

#include <string>
#include <vector>

#include "mf/Document.hpp"

namespace mf {

struct PresetInfo {
    std::string name, category, summary, json;
};

// Built-in presets (entrances, exits, attention, styles, text).
const std::vector<PresetInfo>& builtInPresets();

// Captures `layer`'s animation as a preset. Position/rotation tracks are stored as offsets from
// their last key for "Entrances" (the layer animates *into* its current value) and from their
// first key otherwise.
std::string makePreset(const Project& project, ObjectId comp, ObjectId layer, const std::string& name,
                       const std::string& category);
bool presetHeader(const std::string& json, std::string& name, std::string& category);

// Applies to every target layer with the preset's start at `time`, as one undo step. Returns how
// many effects, animators and keyframes were added; `error` names anything that didn't fit (e.g.
// text animators on a shape layer).
int applyPreset(Document& doc, ObjectId comp, const std::vector<ObjectId>& layers, double time, const std::string& json,
                std::string& error);

}  // namespace mf
