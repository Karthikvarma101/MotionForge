import AppKit
import MFRender
import UniformTypeIdentifiers

extension UTType {
    static let motionForgeBundle = UTType(exportedAs: "com.motionforge.bundle", conformingTo: .data)
}

/// File › Export / Import Project Bundle: a project and every piece of media it uses in one
/// .mfbundle file (a zip), for moving a project to another Mac or sending it to someone.
/// The engine writes and checks the bundle folder (mf/Bundle.hpp); `ditto` zips and unzips it.
enum ProjectBundle {
    struct Exported {
        let url: URL
        let mediaFiles: Int
        let mediaBytes: UInt64
        let missing: [String]
    }

    enum Failure: LocalizedError {
        case tool(String)
        case unsafe(String)
        var errorDescription: String? {
            switch self {
            case .tool(let message): return message
            case .unsafe(let entry): return "The bundle has a file outside its own folder (\(entry)), so MotionForge won't open it."
            }
        }
    }

    /// Copies the project and its media into a folder (main actor: it reads the document), then
    /// zips it off the main thread and moves the zip to `url`.
    @MainActor static func export(engine: MFEngine, to url: URL) async throws -> Exported {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: work) }
        let tree = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        let report = try engine.writeBundle(toDirectory: tree.path)
        let zip = work.appendingPathComponent("bundle.zip")
        // --keepParent: unzipping it by hand gives one tidy folder.
        try await run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", tree.path, zip.path])
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }  // the save panel already asked
        try fm.moveItem(at: zip, to: url)
        return Exported(url: url,
                        mediaFiles: (report["mediaFiles"] as? NSNumber)?.intValue ?? 0,
                        mediaBytes: (report["mediaBytes"] as? NSNumber)?.uint64Value ?? 0,
                        missing: report["missing"] as? [String] ?? [])
    }

    /// Unpacks `bundle` into the new folder `destination` and returns the project file in it,
    /// renamed after the folder. Entry names are checked before anything is extracted.
    static func unpack(_ bundle: URL, into destination: URL) async throws -> URL {
        let fm = FileManager.default
        let listing = try await run("/usr/bin/zipinfo", ["-1", bundle.path])
        for entry in listing.split(separator: "\n").map(String.init) where !entry.isEmpty {
            guard MFEngine.isSafeBundleEntry(entry) else { throw Failure.unsafe(entry) }
        }
        let parent = destination.deletingLastPathComponent()
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
        defer { try? fm.removeItem(at: work) }
        try await run("/usr/bin/ditto", ["-x", "-k", bundle.path, work.path])
        let projectPath = try MFEngine.projectPath(inBundleDirectory: work.path)
        let root = URL(fileURLWithPath: projectPath).deletingLastPathComponent()
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }  // the panel asked
        try fm.moveItem(at: root, to: destination)
        let project = destination.appendingPathComponent("project.mfproj")
        let named = destination.appendingPathComponent(destination.lastPathComponent + ".mfproj")
        try fm.moveItem(at: project, to: named)
        return named
    }

    /// Runs a command-line tool off the main thread; returns its output, throws on failure.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.tool(message.isEmpty ? "\((tool as NSString).lastPathComponent) failed" : message)
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }
}

extension EditorModel {
    func exportBundlePanel() {
        closeCoalescedEdit()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.motionForgeBundle]
        panel.nameFieldStringValue = displayName + ".mfbundle"
        panel.message = "The bundle holds this project and a copy of all its images and audio."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bundleActivity = "Exporting bundle…"
        Task { @MainActor in
            defer { bundleActivity = nil }
            do {
                let r = try await ProjectBundle.export(engine: engine, to: url)
                let size = ByteCountFormatter.string(fromByteCount: Int64(r.mediaBytes), countStyle: .file)
                var text = "Saved “\(url.lastPathComponent)” with \(r.mediaFiles) media file\(r.mediaFiles == 1 ? "" : "s") (\(size))."
                if !r.missing.isEmpty { text += "\n\nNot found, so not included: " + r.missing.joined(separator: ", ") }
                alertMessage = text
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                alertMessage = "Couldn’t export the bundle: \(error.localizedDescription)"
            }
        }
    }

    func importBundlePanel() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.motionForgeBundle, .zip]
        panel.message = "Choose a MotionForge project bundle (.mfbundle)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importBundle(url, askedToDiscard: true)
    }

    /// Asks where to put the project folder, unpacks the bundle there and opens it.
    func importBundle(_ bundle: URL, askedToDiscard: Bool = false) {
        guard askedToDiscard || confirmDiscardChanges() else { return }
        let panel = NSSavePanel()
        panel.title = "Import Project Bundle"
        panel.message = "MotionForge makes a folder here with the project and its media."
        panel.prompt = "Import"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = bundle.deletingPathExtension().lastPathComponent
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        bundleActivity = "Importing bundle…"
        Task { @MainActor in
            defer { bundleActivity = nil }
            do {
                let project = try await ProjectBundle.unpack(bundle, into: destination)
                open(url: project)
            } catch {
                alertMessage = "Couldn’t import “\(bundle.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
    }
}
