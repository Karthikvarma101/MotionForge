#include "mf/Bundle.hpp"

#include <chrono>
#include <ctime>
#include <filesystem>
#include <map>
#include <set>

#include "mf/Json.hpp"
#include "mf/ProjectIO.hpp"

namespace fs = std::filesystem;

namespace mf {
namespace {

// "logo.png" → "logo 2.png" until the name is free.
std::string uniqueName(const std::string& name, std::set<std::string>& used) {
    fs::path p(name.empty() ? std::string("media") : name);
    const std::string stem = p.stem().string(), ext = p.extension().string();
    std::string candidate = p.filename().string();
    for (int n = 2; used.count(candidate); ++n) candidate = stem + " " + std::to_string(n) + ext;
    used.insert(candidate);
    return candidate;
}

std::string isoNow() {
    const std::time_t t = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    char buf[32];
    std::strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&t));
    return buf;
}

}  // namespace

bool writeProjectBundle(const Project& project, const std::string& dir, const std::string& generator,
                        BundleReport& report, std::string& error) {
    report = {};
    std::error_code ec;
    const fs::path root(dir);
    if (fs::exists(root, ec) && !fs::is_empty(root, ec)) {
        error = "The bundle folder isn't empty: " + dir;
        return false;
    }
    fs::create_directories(root / "Media", ec);
    if (ec) {
        error = "Couldn't create " + (root / "Media").string() + ": " + ec.message();
        return false;
    }

    Project copy = project;
    std::map<std::string, std::string> copiedAs;  // source path → bundle file name
    std::set<std::string> used;
    Json media = Json::array();
    for (Asset& a : copy.assets) {
        const std::string source = a.path;
        auto it = copiedAs.find(source);
        if (it == copiedAs.end()) {
            const std::string name = uniqueName(fs::path(source).filename().string(), used);
            if (!source.empty() && fs::is_regular_file(source, ec)) {
                fs::copy_file(source, root / "Media" / name, fs::copy_options::overwrite_existing, ec);
                if (ec) {
                    error = "Couldn't copy " + source + ": " + ec.message();
                    return false;
                }
                const uint64_t bytes = fs::file_size(root / "Media" / name, ec);
                report.mediaFiles += 1;
                report.mediaBytes += ec ? 0 : bytes;
                Json m = Json::object();
                m.set("file", Json("Media/" + name));
                m.set("bytes", Json(bytes));
                media.push(std::move(m));
            } else {
                report.missing.push_back(a.name.empty() ? fs::path(source).filename().string() : a.name);
            }
            it = copiedAs.emplace(source, name).first;
        }
        a.path = (root / "Media" / it->second).string();
    }

    if (!writeFileAtomic((root / kBundleProjectFile).string(), serializeProject(copy, dir, false), error)) return false;

    Json manifest = Json::object();
    manifest.set("format", Json(kBundleFormat));
    manifest.set("version", Json(1));
    manifest.set("generator", Json(generator));
    manifest.set("created", Json(isoNow()));
    manifest.set("project", Json(kBundleProjectFile));
    manifest.set("media", std::move(media));
    Json missing = Json::array();
    for (const std::string& m : report.missing) missing.push(Json(m));
    manifest.set("missing", std::move(missing));
    return writeFileAtomic((root / kBundleManifestFile).string(), manifest.dump(), error);
}

bool isSafeBundleEntry(const std::string& entry) {
    if (entry.empty() || entry.front() == '/' || entry.front() == '\\') return false;
    if (entry.find('\0') != std::string::npos || entry.find('\\') != std::string::npos) return false;
    for (const fs::path& part : fs::path(entry)) {
        if (part == "..") return false;
    }
    return true;
}

bool checkProjectBundle(const std::string& dir, std::string& projectPath, std::string& error) {
    std::error_code ec;
    const fs::path root = fs::weakly_canonical(fs::path(dir), ec);
    if (ec || !fs::is_directory(root, ec)) {
        error = "Not a MotionForge bundle folder.";
        return false;
    }
    // Every entry must be a plain file or folder inside the bundle: no links that point elsewhere.
    for (auto it = fs::recursive_directory_iterator(root, fs::directory_options::none, ec);
         !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        const fs::file_status st = it->symlink_status(ec);
        if (fs::is_symlink(st)) {
            error = "The bundle contains a link (" + it->path().filename().string() + "), which MotionForge won't open.";
            return false;
        }
        if (!fs::is_regular_file(st) && !fs::is_directory(st)) {
            error = "The bundle contains something that isn't a file: " + it->path().filename().string();
            return false;
        }
    }
    if (ec) {
        error = "Couldn't read the bundle: " + ec.message();
        return false;
    }

    // The zip may hold the bundle at its root or inside one folder.
    fs::path base = root;
    if (!fs::exists(base / kBundleManifestFile)) {
        fs::path only;
        int dirs = 0;
        for (const auto& e : fs::directory_iterator(root, ec)) {
            if (e.is_directory() && e.path().filename() != "__MACOSX") { only = e.path(); ++dirs; }
        }
        if (dirs == 1 && fs::exists(only / kBundleManifestFile)) base = only;
    }
    std::string text, perr;
    Json manifest;
    {
        FILE* f = std::fopen((base / kBundleManifestFile).string().c_str(), "rb");
        if (!f) {
            error = "This isn't a MotionForge project bundle (no bundle.json).";
            return false;
        }
        char buf[8192];
        size_t n;
        while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) text.append(buf, n);
        std::fclose(f);
    }
    if (!Json::parse(text, manifest, perr) || manifest.get("format").string() != kBundleFormat) {
        error = "This isn't a MotionForge project bundle.";
        return false;
    }
    const fs::path project = base / kBundleProjectFile;
    if (!fs::is_regular_file(project, ec)) {
        error = "The bundle has no project file.";
        return false;
    }
    projectPath = project.string();
    return true;
}

}  // namespace mf
