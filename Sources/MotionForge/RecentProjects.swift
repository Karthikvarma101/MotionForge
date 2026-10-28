import AppKit
import MFRender

/// A project the Home window offers to reopen.
struct RecentProject: Codable, Identifiable, Hashable {
    var path: String
    var opened: Date
    var compName: String
    var width: Int
    var height: Int
    var fps: Double
    var duration: Double
    var compositions: Int

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var thumbnailURL: URL { RecentProjects.thumbnailURL(for: path) }
}

/// Recently opened / saved projects (newest first) with a small rendered thumbnail each, kept in
/// user defaults and Application Support.
enum RecentProjects {
    private static let key = "recentProjects"
    private static let limit = 24

    static var thumbnailDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionForge/Thumbnails", isDirectory: true)
    }

    static func thumbnailURL(for path: String) -> URL {
        // Stable per path (Swift's hashValue is randomised per launch).
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return thumbnailDirectory.appendingPathComponent(String(h, radix: 16) + ".png")
    }

    static func all() -> [RecentProject] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentProject].self, from: data) else { return [] }
        return list.sorted { $0.opened > $1.opened }
    }

    private static func store(_ list: [RecentProject]) {
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Records `url` as just opened or saved, with a thumbnail of the active composition at `time`
    /// (default: a third of the way in).
    @MainActor static func note(_ url: URL, engine: MFEngine, time: Double? = nil) {
        let c = engine.composition
        let entry = RecentProject(path: url.path, opened: Date(), compName: c.name, width: c.width, height: c.height,
                                  fps: c.fps, duration: c.duration, compositions: engine.compositions.count)
        store([entry] + all().filter { $0.path != url.path })
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let t = min(max(0, time ?? c.duration * 0.3), max(0, c.duration - 1 / max(c.fps, 1)))
        renderThumbnail(url.path, engine: engine, time: t, attemptsLeft: 10)
    }

    /// Images in a just-opened project are still decoding, and a frame that needs them is refused:
    /// try again shortly.
    @MainActor private static func renderThumbnail(_ path: String, engine: MFEngine, time: Double, attemptsLeft: Int) {
        let c = engine.composition
        let scale = min(1, 480 / Double(max(c.width, 1)))
        let was = engine.renderMotionBlur
        engine.renderMotionBlur = false  // a thumbnail doesn't need it, and stays instant
        let ok = (try? engine.writePNG(atTime: time, scale: scale, transparent: false, toPath: thumbnailURL(for: path).path)) != nil
        engine.renderMotionBlur = was
        if !ok, attemptsLeft > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { renderThumbnail(path, engine: engine, time: time, attemptsLeft: attemptsLeft - 1) }
            }
        }
    }

    static func remove(_ path: String) {
        store(all().filter { $0.path != path })
        try? FileManager.default.removeItem(at: thumbnailURL(for: path))
    }

    /// First run: pick up what macOS remembers, until projects get opened here.
    static func importSystemRecentsIfEmpty() {
        guard all().isEmpty else { return }
        let urls = NSDocumentController.shared.recentDocumentURLs.filter { $0.pathExtension == "mfproj" }
        let entries = urls.enumerated().map { i, u in
            RecentProject(path: u.path, opened: Date().addingTimeInterval(-Double(i)), compName: "", width: 0, height: 0,
                          fps: 0, duration: 0, compositions: 0)
        }
        if !entries.isEmpty { store(entries) }
    }
}
