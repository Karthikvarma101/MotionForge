// MotionForge core — project bundles: the project plus a copy of every piece of media it uses, in
// one folder that the app zips into a single .mfbundle file, so a project moves to another Mac whole.
//
//   project.mfproj   media referenced as Media/<file> (relative only)
//   Media/<file>     one copy per media file; clashing names get " 2", " 3"…
//   bundle.json      format, version, the app that wrote it, date, media and missing lists
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "mf/Model.hpp"

namespace mf {

inline constexpr const char* kBundleFormat = "motionforge.bundle";
inline constexpr const char* kBundleProjectFile = "project.mfproj";
inline constexpr const char* kBundleManifestFile = "bundle.json";

struct BundleReport {
    int mediaFiles = 0;                 // files copied into Media/
    uint64_t mediaBytes = 0;
    std::vector<std::string> missing;   // asset names whose file couldn't be found (kept, flagged missing)
};

// Writes the bundle tree into `dir`, which must not exist yet or be empty.
bool writeProjectBundle(const Project& project, const std::string& dir, const std::string& generator,
                        BundleReport& report, std::string& error);

// Checks an unpacked bundle (manifest format, project file present, every file inside `dir`, no
// links) and returns the path of its project file.
bool checkProjectBundle(const std::string& dir, std::string& projectPath, std::string& error);

// Archive entry names (from the zip's listing) that are safe to unpack: relative, no "..", no
// absolute paths. Used before anything is extracted.
bool isSafeBundleEntry(const std::string& entry);

}  // namespace mf
