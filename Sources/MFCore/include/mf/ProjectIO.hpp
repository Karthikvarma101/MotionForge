// MotionForge core — versioned project file (.mfproj, JSON) with portable asset references.
//
// Assets are stored with a path relative to the project file plus an absolute fallback. On load
// the relative path wins (so a project folder can be moved or copied to another Mac), then the
// absolute path; assets found in neither place are kept and flagged `missing`.
#pragma once

#include <string>

#include "mf/Json.hpp"
#include "mf/Model.hpp"

namespace mf {

inline constexpr const char* kProjectFormat = "motionforge.project";

// `projectDir` is the directory the file will live in ("" = store absolute paths only).
std::string serializeProject(const Project& project, const std::string& projectDir);
bool deserializeProject(const std::string& text, const std::string& projectDir, Project& out, std::string& error);

// Atomic save: writes "<path>.tmp" then renames it over `path`, so a crash mid-save never
// leaves a truncated project behind.
bool saveProjectFile(const Project& project, const std::string& path, std::string& error);
bool loadProjectFile(const std::string& path, Project& out, std::string& error);
bool writeFileAtomic(const std::string& path, const std::string& contents, std::string& error);

// Building blocks shared with the clipboard.
Json keyframeToJson(const Keyframe& k, const PropDef& def);
Keyframe keyframeFromJson(const Json& j, const Value& fallback);
Json layerToJson(const Layer& l);
// `comp` supplies defaults for properties missing from the JSON; `maxId` (optional) is raised to
// the largest id found.
Layer layerFromJson(const Json& j, const Composition& comp, ObjectId* maxId);

}  // namespace mf
