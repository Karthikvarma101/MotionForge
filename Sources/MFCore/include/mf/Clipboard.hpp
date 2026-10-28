// MotionForge core — copy/paste of layers and keyframes as self-describing JSON (the app puts it on
// the system pasteboard, so it also works between projects).
#pragma once

#include <string>
#include <vector>

#include "mf/Document.hpp"

namespace mf {

enum class ClipboardKind { None, Layers, Keyframes };
ClipboardKind clipboardKind(const std::string& text);

// Layers in stacking order, with the media they use. Parent / matte links between copied
// layers survive the paste; links to layers that weren't copied are dropped.
std::string copyLayers(const Project& project, ObjectId comp, const std::vector<ObjectId>& layers);
// Inserts at stack index `atIndex` (0 = top). Returns the new layer ids, top first.
std::vector<ObjectId> pasteLayers(Document& doc, ObjectId comp, const std::string& text, int atIndex, std::string& error);

// Keyframes keep their spacing: times are stored relative to the earliest copied key.
// Tracks identify their property by name, effect type + slot, or mask slot, so keys can be
// pasted onto a different layer that has the same kind of property.
std::string copyKeyframes(const Project& project, ObjectId comp, const std::vector<KeyAddress>& keys);
// Pastes with the earliest key at `time`. With several targets, the n-th copied layer's tracks go
// to the n-th target (when counts match); otherwise everything goes to targets[0]. One undo step.
// Returns the number of keys written; `error` explains tracks that had nowhere to go.
int pasteKeyframes(Document& doc, ObjectId comp, const std::vector<ObjectId>& targets, double time,
                   const std::string& text, std::string& error);

}  // namespace mf
