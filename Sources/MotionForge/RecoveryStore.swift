import Foundation
import MFRender

/// Autosave + crash recovery.
///
/// A `session.lock` file exists while the app runs and is removed on a clean quit. If it is
/// still there at launch and an autosave exists, the previous session crashed (or was killed)
/// with unsaved work, and the user is offered the autosave.
enum RecoveryStore {
    struct Pending {
        let projectURL: URL
        let originalURL: URL?
        let date: Date
    }

    static var directory: URL {
        // Scripted runs use their own folder so they never touch a running editor's autosave.
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_RECOVERY_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionForge/Recovery", isDirectory: true)
    }

    static var autosaveURL: URL { directory.appendingPathComponent("autosave.mfproj") }
    private static var infoURL: URL { directory.appendingPathComponent("autosave.json") }
    private static var lockURL: URL { directory.appendingPathComponent("session.lock") }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func write(engine: MFEngine, originalURL: URL?) throws {
        ensureDirectory()
        try engine.writeRecoveryCopy(toPath: autosaveURL.path)
        let info: [String: String] = [
            "originalPath": originalURL?.path ?? "",
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])
        try data.write(to: infoURL, options: .atomic)
    }

    static func pendingRecovery() -> Pending? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lockURL.path), fm.fileExists(atPath: autosaveURL.path) else { return nil }
        var original: URL?
        var date = (try? fm.attributesOfItem(atPath: autosaveURL.path)[.modificationDate] as? Date) ?? Date()
        if let data = try? Data(contentsOf: infoURL),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            if let p = info["originalPath"], !p.isEmpty { original = URL(fileURLWithPath: p) }
            if let d = info["date"], let parsed = ISO8601DateFormatter().date(from: d) { date = parsed }
        }
        return Pending(projectURL: autosaveURL, originalURL: original, date: date)
    }

    static func beginSession() {
        ensureDirectory()
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: lockURL, atomically: true, encoding: .utf8)
    }

    /// Clean quit: the user already chose to save or discard, so the autosave is no longer needed.
    static func endSession(keepAutosave: Bool) {
        try? FileManager.default.removeItem(at: lockURL)
        if !keepAutosave { clear() }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: autosaveURL)
        try? FileManager.default.removeItem(at: infoURL)
    }
}
