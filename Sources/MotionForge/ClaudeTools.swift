import AppKit
import Foundation
import MFRender

/// One tool call's answer in MCP terms: text (JSON) and/or a PNG, or an error message.
struct ClaudeToolOutput {
    var text: String
    var png: Data?
    var isError = false

    /// MCP `tools/call` result.
    var mcpResult: [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
        return ["content": content, "isError": isError]
    }
}

/// Runs Claude's tools against the open editor. Document tools go to the engine (mf/Commands.hpp);
/// host tools (rendering, media, files, export, playhead, selection) are answered here. Shared by
/// the MCP bridge and the in-app Claude panel.
@MainActor
final class ClaudeToolHost {
    unowned let model: EditorModel

    init(model: EditorModel) { self.model = model }

    /// [{name, description, inputSchema}] as MCP lists them.
    static let catalog: [[String: Any]] = {
        let data = Data(MFEngine.claudeToolCatalogJSON().utf8)
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.map { t in t.filter { $0.key != "host" } }
    }()

    func run(_ name: String, arguments: [String: Any]) async -> ClaudeToolOutput {
        // Shared projects undo per person, through the collaboration session.
        if name == "undo" || name == "redo", model.collab != nil {
            let can = name == "undo" ? model.canUndo : model.canRedo
            guard can else { return ClaudeToolOutput(text: "Nothing to \(name).", isError: true) }
            name == "undo" ? model.undo() : model.redo()
            return ClaudeToolOutput(text: "{\"\(name == "undo" ? "undid" : "redid")\": true}")
        }
        let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let before = model.engine.revision
        var handled: ObjCBool = true
        var message: NSString?
        let result = model.engine.runClaudeTool(name, arguments: argsJSON, handled: &handled, error: &message)
        if handled.boolValue {
            if model.engine.revision != before { changed() }
            if let result { return ClaudeToolOutput(text: result) }
            return ClaudeToolOutput(text: (message as String?) ?? "Failed", isError: true)
        }
        do {
            return try await runHost(name, arguments)
        } catch {
            return ClaudeToolOutput(text: error.localizedDescription, isError: true)
        }
    }

    /// After an edit: show it (leave Home), refresh the editor, follow a composition switch.
    private func changed() {
        if model.showHome { model.enterWorkspace() }
        model.closeCoalescedEdit()
        model.refresh()
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func json(_ object: Any) -> ClaudeToolOutput {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ClaudeToolOutput(text: String(decoding: data, as: UTF8.self))
    }

    private func path(_ args: [String: Any], _ key: String = "path") throws -> URL {
        guard let raw = args[key] as? String, !raw.isEmpty else { throw Failure("`\(key)` is required") }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Failure("`\(key)` must be an absolute path") }
        return URL(fileURLWithPath: expanded)
    }

    private func runHost(_ name: String, _ args: [String: Any]) async throws -> ClaudeToolOutput {
        switch name {
        case "render_frame":
            let t = (args["time"] as? Double) ?? model.time.time
            let maxSize = Double((args["max_size"] as? Int) ?? 1024)
            let comp = model.engine.composition
            let scale = min(1, maxSize / Double(max(comp.width, comp.height, 1)))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("motionforge-claude-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            try model.engine.writePNG(atTime: t, scale: scale, transparent: false, toPath: file.path)
            let png = try Data(contentsOf: file)
            return ClaudeToolOutput(text: "Frame at \(String(format: "%.2f", t)) s of “\(comp.name)” (\(comp.width)×\(comp.height), shown at \(Int(scale * 100))%).", png: png)

        case "import_media":
            let url = try path(args)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("No file at \(url.path)") }
            let before = Set(model.assets.map(\.assetID))
            let layersBefore = Set(model.layers.map(\.layerID))
            model.alertMessage = nil
            model.importMedia(urls: [url], addToComposition: (args["add_layer"] as? Bool) ?? true)
            if let message = model.alertMessage {
                model.alertMessage = nil
                throw Failure(message)
            }
            changed()
            let asset = model.assets.first { !before.contains($0.assetID) }
            let layer = model.layers.first { !layersBefore.contains($0.layerID) }
            var out: [String: Any] = ["asset": asset?.assetID ?? 0, "name": asset?.name ?? url.lastPathComponent]
            if let layer { out["layer"] = layer.layerID }
            return json(out)

        case "get_editor_state":
            var out: [String: Any] = [
                "project": model.projectURL?.path ?? "untitled",
                "name": model.displayName,
                "time": model.time.time,
                "playing": model.time.isPlaying,
                "unsavedChanges": model.engine.dirty,
                "composition": ["id": model.comp.compID, "name": model.comp.name],
                "selectedLayers": model.selectedLayerIDs.compactMap { id in
                    model.layers.first { $0.layerID == id }.map { ["id": $0.layerID, "name": $0.name] }
                },
                "homeScreen": model.showHome,
            ]
            if let collab = model.collab {
                out["sharedProject"] = collab.project.name
                out["othersHere"] = collab.participants.map(\.name)
            }
            return json(out)

        case "set_time":
            guard let t = args["time"] as? Double else { throw Failure("`time` is required") }
            model.time.time = min(max(0, t), model.comp.duration)
            return json(["time": model.time.time])

        case "select_layers":
            let refs = args["layers"] as? [Any] ?? []
            let ids: [UInt64] = refs.compactMap { ref in
                if let n = ref as? NSNumber { return model.layers.first { $0.layerID == n.uint64Value }?.layerID }
                if let s = ref as? String { return model.layers.first { $0.name.caseInsensitiveCompare(s) == .orderedSame }?.layerID }
                return nil
            }
            guard !ids.isEmpty else { throw Failure("None of those layers are in the active composition.") }
            if model.showHome { model.enterWorkspace() }
            model.selectLayers(ids)
            return json(["selected": ids])

        case "save_project":
            if let raw = args["path"] as? String, !raw.isEmpty {
                var url = try path(args)
                if url.pathExtension != "mfproj" { url.appendPathExtension("mfproj") }
                guard model.write(to: url) else { throw Failure(model.takeAlert() ?? "Couldn’t save.") }
                return json(["saved": url.path])
            }
            guard let url = model.projectURL else {
                throw Failure("The project is untitled: pass `path` (e.g. ~/Documents/My Project.mfproj).")
            }
            guard model.write(to: url) else { throw Failure(model.takeAlert() ?? "Couldn’t save.") }
            return json(["saved": url.path])

        case "open_project":
            let url = try path(args)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("No file at \(url.path)") }
            if model.engine.dirty {
                guard (args["save_first"] as? Bool) == true else {
                    throw Failure("The open project has unsaved changes. Call again with save_first=true (saves it first) or ask the user.")
                }
                guard let current = model.projectURL, model.write(to: current) else {
                    throw Failure("The open project is untitled; save it with save_project and a path first.")
                }
            }
            model.open(url: url)
            if let message = model.takeAlert(), model.projectURL != url { throw Failure(message) }
            return json(["opened": url.path, "compositions": model.engine.compositions.count])

        case "export_video":
            guard model.account.canExport else {
                model.showPaywall = true
                throw Failure("Exporting needs MotionForge Pro. The subscription sheet is now open in the app for the user.")
            }
            guard model.exporter == nil else { throw Failure("An export is already running.") }
            let settings = MFExportSettings()
            switch (args["format"] as? String) ?? "h264" {
            case "hevc": settings.format = .hevc
            case "prores": settings.format = .proRes422
            case "prores4444": settings.format = .proRes4444
            case "png": settings.format = .pngSequence
            default: settings.format = .h264
            }
            if let from = args["from"] as? Double { settings.startTime = from }
            if let to = args["to"] as? Double { settings.endTime = to }
            var url = try path(args)
            if let ext = settings.format.fileExtension, url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
            model.startExport(settings, to: url, summary: "Started by Claude")
            if let message = model.takeAlert() { throw Failure(message) }
            model.showExportWindow()
            return json(["exporting": url.path])

        default:
            throw Failure("Unknown tool “\(name)”.")
        }
    }
}

extension EditorModel {
    /// Reads and clears the pending alert (tools report errors to Claude, not to a dialog).
    func takeAlert() -> String? {
        defer { alertMessage = nil }
        return alertMessage
    }
}

/// The local end of the MCP bridge: a Unix socket (owner-only) that the `mfmcp` helper inside the
/// app bundle connects to. Claude Desktop / Claude Code start `mfmcp`; it speaks MCP over stdio and
/// forwards `tools/list` and `tools/call` here as one JSON object per line.
@MainActor
final class ClaudeBridgeServer {
    static var socketURL: URL {
        if let p = ProcessInfo.processInfo.environment["MOTIONFORGE_CLAUDE_SOCKET"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionForge/claude.sock")
    }

    private let host: ClaudeToolHost
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private(set) var clients = 0

    init(host: ClaudeToolHost) { self.host = host }

    final class Connection {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    func start() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(url.path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        for c in connections.values { c.source?.cancel(); close(c.fd) }
        connections = [:]
        if listenFD >= 0 { close(listenFD) }
        unlink(Self.socketURL.path)
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // Accepted sockets inherit O_NONBLOCK; replies (frames are ~1 MB) are written blocking.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let c = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(c) } }
        source.resume()
        c.source = source
        connections[fd] = c
        clients = connections.count
    }

    private func read(_ c: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(c.fd, &chunk, chunk.count)
        if n <= 0 {
            c.source?.cancel()
            close(c.fd)
            connections[c.fd] = nil
            clients = connections.count
            return
        }
        c.buffer.append(contentsOf: chunk[0..<n])
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            let line = c.buffer[c.buffer.startIndex..<nl]
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            Task { @MainActor in
                let reply = await self.handle(request)
                self.send(reply, to: c)
            }
        }
    }

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        switch request["method"] as? String {
        case "tools/list":
            return ["id": id, "result": ["tools": ClaudeToolHost.catalog]]
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let output = await host.run(name, arguments: params["arguments"] as? [String: Any] ?? [:])
            return ["id": id, "result": output.mcpResult]
        default:
            return ["id": id, "error": ["code": -32601, "message": "Unknown method"]]
        }
    }

    private func send(_ reply: [String: Any], to c: Connection) {
        guard connections[c.fd] === c, var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.append(0x0A)
        let fd = c.fd
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if w <= 0 { break }
                    off += w
                }
            }
        }
    }
}
