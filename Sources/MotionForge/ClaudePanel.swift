import AppKit
import Security
import SwiftUI

// MARK: - Connecting Claude Desktop / Claude Code (MCP)

/// Registers MotionForge's MCP server (`mfmcp`, inside the app bundle) with Claude Desktop or gives
/// the Claude Code command. Uses the person's own Claude plan; no API key involved.
@MainActor
enum ClaudeConnect {
    static var helperURL: URL {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mfmcp")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
        // Development builds: next to the app binary.
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mfmcp")
    }

    static var claudeCodeCommand: String {
        "claude mcp add motionforge --scope user -- \"\(helperURL.path)\""
    }

    static var desktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static func isConnectedToDesktop() -> Bool {
        guard let data = try? Data(contentsOf: desktopConfigURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers["motionforge"] != nil
    }

    /// Adds (or updates) the "motionforge" entry in Claude Desktop's config, keeping everything else.
    static func connectDesktop() throws {
        let url = desktopConfigURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw NSError(domain: "MotionForge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Claude’s settings file isn’t valid JSON, so MotionForge left it alone: \(url.path)"])
            }
            root = parsed
            let backup = url.appendingPathExtension("motionforge-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["motionforge"] = ["command": helperURL.path]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }
}

extension EditorModel {
    func connectClaudeDesktop() {
        let alert = NSAlert()
        alert.messageText = "Connect MotionForge to Claude?"
        alert.informativeText = "This adds MotionForge to Claude’s MCP servers (\(ClaudeConnect.desktopConfigURL.path)), so you can ask Claude to edit the open project. Your other Claude settings are kept. Quit and reopen Claude afterwards."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeConnect.connectDesktop()
            alertMessage = "Connected. Quit and reopen Claude, then ask it something like “Add a title that slides in from the left” — it will appear in MotionForge."
        } catch {
            alertMessage = "Couldn’t connect: \(error.localizedDescription)"
        }
    }

    func copyClaudeCodeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ClaudeConnect.claudeCodeCommand, forType: .string)
        alertMessage = "Copied. Paste it into Terminal to add MotionForge to Claude Code:\n\n\(ClaudeConnect.claudeCodeCommand)"
    }
}

// MARK: - API key (Keychain)

enum ClaudeAPIKey {
    private static let service = "com.motionforge.claude-api-key"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        delete()
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "anthropic", kSecValueData as String: Data(key.utf8)]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

// MARK: - The in-app assistant

/// A chat with Claude (Messages API, the person's own API key) that edits the open project
/// through the same tools as the MCP server. The conversation is append-only: assistant turns are
/// sent back exactly as received (thinking blocks included), and the stable prefix (tools,
/// system prompt, earlier turns) is prompt-cached.
@MainActor
final class ClaudeChat: ObservableObject {
    enum Model: String, CaseIterable, Identifiable {
        case opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .opus: return "Claude Opus 5.5"
            case .sonnet: return "Claude Sonnet 5.5 (faster)"
            case .haiku: return "Claude Haiku 5.5 (fastest, cheapest)"
            }
        }
    }

    struct Item: Identifiable {
        enum Kind { case user, assistant, tool(ok: Bool), notice }
        let id = UUID()
        var kind: Kind
        var text: String
        var detail: String = ""
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published var hasKey = ClaudeAPIKey.read() != nil
    @Published var model = Model(rawValue: UserDefaults.standard.string(forKey: "claude.model") ?? "") ?? .opus {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "claude.model") }
    }

    private var history: [[String: Any]] = []  // API messages, append-only
    private var task: Task<Void, Never>?
    private unowned let host: ClaudeToolHost
    private unowned let editor: EditorModel

    init(editor: EditorModel) {
        self.editor = editor
        self.host = editor.claudeTools
    }

    static let systemPrompt = """
    You are the assistant inside MotionForge, a native macOS motion graphics and compositing app (like After Effects). \
    You edit the user's open project with the tools provided; every change appears live in their editor and each tool \
    call is one undo step, so they can undo anything you do.

    How MotionForge works: a project has compositions; a composition has layers stacked top (index 0) to bottom. \
    Layer kinds: shape (rectangle, ellipse, polygon, star), text, null (a controller for parenting), image, audio and \
    precomp (another composition used as a layer). Times are in seconds, positions are composition pixels from the \
    top-left, scale and opacity are percentages, rotation is degrees clockwise, colours are [r, g, b, a] from 0 to 1 \
    or "#RRGGBB". Animated properties have keyframes; easing makes motion feel natural.

    Work like a motion designer: look first (get_project, get_composition), make focused changes, give layers clear \
    names, and check the result with render_frame at a couple of key times before you say you're done. Keep replies \
    short and plain: say what you changed and where, and ask when the request is ambiguous. Don't save, open other \
    projects or export unless the user asks.
    """

    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasKey = ClaudeAPIKey.save(trimmed)
        if !hasKey { items.append(Item(kind: .notice, text: "Couldn’t store the key in your Keychain.")) }
    }

    func forgetKey() {
        ClaudeAPIKey.delete()
        hasKey = false
    }

    func clear() {
        stop()
        items = []
        history = []
        status = ""
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        status = ""
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        items.append(Item(kind: .user, text: prompt))
        // What the editor shows right now, so "this layer" and "here" make sense to Claude.
        let selected = editor.selectedLayerIDs.compactMap { id in editor.layers.first { $0.layerID == id } }
            .map { "\($0.name) (id \($0.layerID))" }
        let context = "[Editor: composition “\(editor.comp.name)” \(editor.comp.width)×\(editor.comp.height), " +
            "playhead \(String(format: "%.2f", editor.time.time)) s" +
            (selected.isEmpty ? "" : ", selected: " + selected.joined(separator: ", ")) + "]"
        history.append(["role": "user", "content": [["type": "text", "text": context + "\n\n" + prompt]]])
        running = true
        task = Task { [weak self] in await self?.loop() }
    }

    private func loop() async {
        defer { running = false; status = ""; task = nil }
        for _ in 0..<60 {
            if Task.isCancelled { return }
            status = "Claude is thinking…"
            let response: [String: Any]
            do {
                response = try await request()
            } catch is CancellationError {
                return
            } catch {
                items.append(Item(kind: .notice, text: error.localizedDescription))
                // Keep the history valid: drop the unanswered user turn's effect by noting it.
                history.append(["role": "assistant", "content": [["type": "text", "text": "(The request failed.)"]]])
                return
            }
            let content = response["content"] as? [[String: Any]] ?? []
            let stop = response["stop_reason"] as? String ?? ""
            if stop == "refusal" {
                items.append(Item(kind: .notice, text: "Claude declined this request."))
                history.append(["role": "assistant", "content": content.isEmpty ? [["type": "text", "text": "(declined)"]] : content])
                return
            }
            history.append(["role": "assistant", "content": content])  // exactly as received
            for block in content where block["type"] as? String == "text" {
                if let t = block["text"] as? String, !t.isEmpty { items.append(Item(kind: .assistant, text: t)) }
            }
            let calls = content.filter { $0["type"] as? String == "tool_use" }
            guard stop == "tool_use", !calls.isEmpty else {
                if stop == "max_tokens" { items.append(Item(kind: .notice, text: "Claude’s reply was cut off (too long).")) }
                return
            }
            // Tools change the project, so they run one after another; all results go back together.
            var results: [[String: Any]] = []
            for call in calls {
                if Task.isCancelled { return }
                let name = call["name"] as? String ?? ""
                status = "Running \(name)…"
                let input = call["input"] as? [String: Any] ?? [:]
                let out = await host.run(name, arguments: input)
                var resultContent: [[String: Any]] = [["type": "text", "text": out.text]]
                if let png = out.png {
                    resultContent.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                                        "data": png.base64EncodedString()]])
                }
                results.append(["type": "tool_result", "tool_use_id": call["id"] as? String ?? "",
                                "content": resultContent, "is_error": out.isError])
                items.append(Item(kind: .tool(ok: !out.isError), text: Self.describe(name, input),
                                  detail: out.isError ? out.text : ""))
            }
            history.append(["role": "user", "content": results])
        }
        items.append(Item(kind: .notice, text: "Stopped after many steps. Say “continue” to keep going."))
    }

    private static func describe(_ name: String, _ input: [String: Any]) -> String {
        let readable = name.replacingOccurrences(of: "_", with: " ")
        if let p = input["property"] as? String { return "\(readable) · \(p)" }
        if let k = input["kind"] as? String { return "\(readable) · \(k)" }
        if let t = input["text"] as? String { return "\(readable) · “\(t.prefix(30))”" }
        return readable
    }

    private static let tools: [[String: Any]] = ClaudeToolHost.catalog.map { t in
        ["name": t["name"] ?? "", "description": t["description"] ?? "", "input_schema": t["inputSchema"] ?? ["type": "object"]]
    }

    private func request() async throws -> [String: Any] {
        guard let key = ClaudeAPIKey.read() else {
            hasKey = false
            throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: "Add your Anthropic API key first."])
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "system": [["type": "text", "text": Self.systemPrompt]],
            "tools": Self.tools,
            "messages": history,
            "cache_control": ["type": "ephemeral"],  // caches tools + system + the conversation so far
            "output_config": ["effort": "medium"],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if model != .haiku {
            // If a safety classifier declines, the API re-runs the request on its recommended fallback model.
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var delay: UInt64 = 2_000_000_000
        for attempt in 0..<4 {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if code == 200 { return json }
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            if (code == 429 || code == 529 || code >= 500) && attempt < 3 {
                status = "Claude is busy — retrying…"
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            if code == 401 { throw NSError(domain: "Claude", code: code, userInfo: [NSLocalizedDescriptionKey: "The API key was rejected: \(message)"]) }
            throw NSError(domain: "Claude", code: code, userInfo: [NSLocalizedDescriptionKey: "Claude API error: \(message)"])
        }
        throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: "Claude didn’t answer."])
    }
}

// MARK: - Panel view

struct ClaudePanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var chat: ClaudeChat
    @State private var draft = ""
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Claude", systemImage: "sparkles").font(.headline)
                Spacer()
                Menu {
                    Picker("Model", selection: $chat.model) {
                        ForEach(ClaudeChat.Model.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("Connect Claude Desktop…") { model.connectClaudeDesktop() }
                    Button("Copy Claude Code Command") { model.copyClaudeCodeCommand() }
                    if chat.hasKey {
                        Divider()
                        Button("Forget API Key") { chat.forgetKey() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                Button { chat.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New conversation")
                    .disabled(chat.items.isEmpty)
                Button { model.showClaudePanel = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Hide the Claude panel")
            }
            .padding(10)
            Divider()
            if chat.hasKey { conversation } else { setup }
        }
        .background(Theme.panel)
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask Claude to build and animate in your project").font(.system(size: 13, weight: .semibold))
                Text("“Make a 5-second title card with my name that fades up”, “slow down the logo animation”, “add a glow to the selected layer”. Claude works in the open project and every change can be undone.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                Text("Use your Claude app (no API key)").font(.system(size: 12, weight: .semibold))
                Text("Connect MotionForge to Claude Desktop or Claude Code and chat there; it uses your Claude plan.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Button("Connect Claude Desktop…") { model.connectClaudeDesktop() }
                    Button("Copy Claude Code Command") { model.copyClaudeCodeCommand() }
                }
                .controlSize(.small)
                Divider()
                Text("Or chat right here with an API key").font(.system(size: 12, weight: .semibold))
                Text("Paste a key from the Anthropic Console. It's kept in your Mac's Keychain and only sent to Anthropic; usage is billed to that key's account.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("sk-ant-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { chat.setKey(keyDraft); keyDraft = "" }
                HStack {
                    Button("Save Key") { chat.setKey(keyDraft); keyDraft = "" }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chat.items.isEmpty {
                            Text("Ask for an animation, a layout change or a fix. Claude can see frames it renders, so it checks its own work.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        ForEach(chat.items) { item in row(item).id(item.id) }
                        if chat.running {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(chat.status).font(.system(size: 11)).foregroundStyle(.secondary) }
                                .id("status")
                        }
                    }
                    .padding(10)
                }
                .onChange(of: chat.items.count) { _, _ in
                    withAnimation { proxy.scrollTo(chat.running ? AnyHashable("status") : AnyHashable(chat.items.last?.id), anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask Claude to edit this project…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(submit)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
                if chat.running {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.borderless).help("Stop")
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.borderless)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(8)
        }
    }

    private func submit() {
        chat.send(draft)
        draft = ""
    }

    @ViewBuilder private func row(_ item: ClaudeChat.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(item.text).font(.system(size: 12)).textSelection(.enabled)
                    .padding(8).background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.28)))
            }
        case .assistant:
            Text((try? AttributedString(markdown: item.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.text))
                .font(.system(size: 12)).textSelection(.enabled)
        case .tool(let ok):
            VStack(alignment: .leading, spacing: 2) {
                Label(item.text, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ok ? Color.secondary : Theme.warning)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        case .notice:
            Label(item.text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.warning)
        }
    }
}
