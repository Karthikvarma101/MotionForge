import AppKit
import Foundation
import Security
import SwiftUI

/// New versions from the GitHub repository's releases: Home shows one when it's out, and the app
/// installs it itself — download the disk image, check it is MotionForge signed like this copy and
/// newer, put it where this copy is, and reopen.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let title: String
        let notes: String
        let page: URL
        let download: URL
        let bytes: Int
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var state: State = .idle

    static let repository = UserDefaults.standard.string(forKey: "updateRepository") ?? "Karthikvarma101/MotionForge"
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private let env = ProcessInfo.processInfo.environment
    private var feed: URL {  // scripted checks point it at a local file
        env["MOTIONFORGE_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
    }

    /// At launch and when Home appears: at most every six hours (always when asked).
    func check(force: Bool = false) async {
        let last = UserDefaults.standard.double(forKey: "updateLastCheck")
        guard force || Date().timeIntervalSince1970 - last > 6 * 3600 || env["MOTIONFORGE_UPDATE_FEED"] != nil else { return }
        if case .downloading = state { return }
        guard state != .installing, state != .checking else { return }
        state = .checking
        do {
            var request = URLRequest(url: feed)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MotionForge/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError("GitHub answered \(http.statusCode)")
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
            let release = try Self.parse(data)
            available = Self.isNewer(release.version, than: Self.currentVersion) ? release : nil
            state = available == nil ? .upToDate : .idle
        } catch {
            state = force ? .failed("Couldn’t check for updates: \(error.localizedDescription)") : .idle
        }
    }

    /// "Later": this version isn't offered again (a newer one will be).
    func skip() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "updateSkipped") }
        available = nil
    }

    var isSkipped: Bool { available.map { UserDefaults.standard.string(forKey: "updateSkipped") == $0.version } ?? false }

    static func parse(_ data: Data) throws -> Release {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String else { throw UpdateError("No release found") }
        let assets = o["assets"] as? [[String: Any]] ?? []
        // The drag-to-Applications disk image (a zip of the app would do too).
        let pick = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            ?? assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        guard let pick, let url = (pick["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError("The release \(tag) has no download")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, title: o["name"] as? String ?? "MotionForge \(version)", notes: o["body"] as? String ?? "",
                       page: (o["html_url"] as? String).flatMap(URL.init(string:)) ?? url, download: url, bytes: pick["size"] as? Int ?? 0)
    }

    /// 0.10.0 is newer than 0.9.2; "1.2" equals "1.2.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Installing

    /// Downloads and installs `release`, then quits so the helper can swap the app and reopen it.
    /// `confirm` asks about unsaved work first (false: nothing happens).
    func install(_ release: Release, confirm: () -> Bool) async {
        guard confirm() else { return }
        let target = URL(fileURLWithPath: env["MOTIONFORGE_UPDATE_TARGET"] ?? Bundle.main.bundlePath)
        do {
            state = .downloading(0)
            let file = try await download(release.download)
            state = .installing
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("MotionForge-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let app = try await unpack(file, into: work)
            try verify(app, newerThan: Self.currentVersion)
            let folder = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: folder.path) else {
                // Somewhere this user can't write (or a translocated copy): let them drag it in.
                NSWorkspace.shared.open(file)
                state = .failed("MotionForge can’t replace itself in \(folder.path). The new version is open in Finder: drag it to Applications.")
                return
            }
            let staged = folder.appendingPathComponent(".MotionForge-\(release.version)-update.app")
            try? FileManager.default.removeItem(at: staged)
            try await run("/usr/bin/ditto", [app.path, staged.path])  // keeps the signature intact
            try launchSwapHelper(staged: staged, target: target)
            quittingForUpdate = true
            NSApp.terminate(nil)
        } catch {
            state = .failed("The update didn’t install: \(error.localizedDescription)")
        }
    }

    /// Set while quitting to install: the unsaved-work question was already asked.
    private(set) var quittingForUpdate = false

    private func download(_ url: URL) async throws -> URL {
        let progress = DownloadProgress { [weak self] f in
            Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(f) } }
        }
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: progress)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("The download failed (\(http.statusCode))") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MotionForge-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    /// The app inside a disk image (copied out, image detached) or a zip.
    private func unpack(_ file: URL, into work: URL) async throws -> URL {
        let out = work.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if file.pathExtension.lowercased() == "zip" {
            try await run("/usr/bin/ditto", ["-x", "-k", file.path, out.path])
        } else {
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, file.path])
            defer { Task { try? await run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) } }
            guard let name = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateError("No app in the disk image")
            }
            try await run("/usr/bin/ditto", [mount.appendingPathComponent(name).path, out.appendingPathComponent(name).path])
        }
        guard let name = try FileManager.default.contentsOfDirectory(atPath: out.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("No app in the download")
        }
        return out.appendingPathComponent(name)
    }

    /// Valid signature, the same app (bundle id) from the same developer (team) as this copy, and
    /// newer: anything else could be someone else's code, so it is never installed.
    func verify(_ app: URL, newerThan current: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download isn’t an app")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw UpdateError("The new version’s signature is broken") }
        let theirs = Self.signing(code)
        var mine = (identifier: String?.none, team: String?.none)
        var me: SecCode?
        var myStatic: SecStaticCode?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic {
            mine = Self.signing(myStatic)
        }
        let bundleID = Bundle(url: app)?.bundleIdentifier
        guard bundleID == (Bundle.main.bundleIdentifier ?? "com.motionforge.MotionForge"), theirs.identifier == bundleID else {
            throw UpdateError("The download isn’t MotionForge")
        }
        if let team = mine.team, theirs.team != team {  // signed by someone else
            throw UpdateError("The new version isn’t signed by the same developer")
        }
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard Self.isNewer(version, than: current) else { throw UpdateError("The download (\(version)) isn’t newer than this copy") }
    }

    private static func signing(_ code: SecStaticCode) -> (identifier: String?, team: String?) {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, nil) }
        return (dict[kSecCodeInfoIdentifier as String] as? String, dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// A small shell script that waits for this process to end, swaps the app bundles (putting the
    /// old one back if that fails) and opens the new one.
    private func launchSwapHelper(staged: URL, target: URL) throws {
        let script = """
        pid="$1"; target="$2"; staged="$3"; relaunch="$4"
        for i in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        old="$target.old-$$"
        if [ -e "$target" ]; then mv "$target" "$old" || exit 1; fi
        if mv "$staged" "$target"; then rm -rf "$old"; else [ -e "$old" ] && mv "$old" "$target"; exit 1; fi
        [ "$relaunch" = 1 ] && /usr/bin/open "$target"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "motionforge-update", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path,
                       env["MOTIONFORGE_UPDATE_NO_RELAUNCH"] == nil ? "1" : "0"]
        try p.run()  // outlives this process
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { c.resume(returning: out) } else {
                    c.resume(throwing: UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reports a download's progress (0–1).
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in report(p.fractionCompleted) }
    }
}

/// Home: a new version is out (with what's new), its download and install, or why it failed.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    @ObservedObject var model: EditorModel

    var body: some View {
        if let r = updater.available, !updater.isSkipped || busyOrFailed {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New update: \(r.title)").font(.system(size: 13, weight: .semibold))
                    Text(Self.summary(r.notes)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                switch updater.state {
                case .downloading(let p):
                    ProgressView(value: p).frame(width: 150)
                    Text("Downloading \(Int(p * 100))%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Installing — MotionForge will reopen").font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(3).frame(maxWidth: 340, alignment: .trailing)
                    Button("Download Manually") { NSWorkspace.shared.open(r.page) }
                default:
                    Button("What’s New") { NSWorkspace.shared.open(r.page) }
                    Button("Later") { updater.skip() }
                    Button("Update Now") {
                        Task { await updater.install(r) { model.readyToQuitForUpdate() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Downloads \(r.bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file) : "the update"), installs it in place of this copy and reopens MotionForge")
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 36)
            .padding(.bottom, 18)
        }
    }

    private var busyOrFailed: Bool {
        switch updater.state {
        case .downloading, .installing, .failed: return true
        default: return false
        }
    }

    /// The release notes' first points, as plain text.
    static func summary(_ notes: String) -> String {
        let lines = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
        return lines.prefix(3).joined(separator: " · ")
    }
}
