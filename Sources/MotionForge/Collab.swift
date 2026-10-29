import AppKit
import CryptoKit
import Foundation
import MFRender

// Live collaboration (Pro): friends, shared projects and co-editing. The server side is
// supabase/migrations/20261029000000_collaboration.sql; the merge logic is mf/Sync.hpp.

// MARK: - Server calls

struct CollabError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

struct Friend: Identifiable, Hashable {
    let friendshipID: String
    let id: String  // user id
    let email: String
    let name: String
    let avatarURL: URL?
    let accepted: Bool
    let incoming: Bool
    let isPro: Bool
    var displayName: String { name.isEmpty ? email : name }
}

struct SharedProject: Identifiable, Hashable {
    struct Member: Hashable {
        let userID: String
        let name: String
        let email: String
        let avatarURL: URL?
        let role: String
        let joined: Bool
        let isPro: Bool
    }
    let id: String
    let name: String
    let ownerName: String
    let role: String
    let joined: Bool
    let slot: Int
    let updatedAt: Date?
    let members: [Member]
    var isOwner: Bool { role == "owner" }
}

@MainActor
enum CollabAPI {
    static func rpc(_ account: AccountModel, _ name: String, _ body: [String: Any] = [:]) async throws -> Any {
        guard let base = AccountConfig.url else { throw CollabError("Accounts aren’t set up in this build.") }
        guard let token = await account.validAccessToken() else { throw CollabError("Sign in to collaborate.") }
        var r = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/\(name)"))
        r.httpMethod = "POST"
        r.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200..<300).contains(code) else {
            let message = (json as? [String: Any])?["message"] as? String ?? "Server error \(code)"
            throw CollabError(message)
        }
        return json ?? NSNull()
    }

    static func friends(_ account: AccountModel) async throws -> [Friend] {
        let rows = try await rpc(account, "my_friends") as? [[String: Any]] ?? []
        return rows.map { r in
            Friend(friendshipID: r["friendship_id"] as? String ?? "", id: r["user_id"] as? String ?? "",
                   email: r["email"] as? String ?? "", name: r["name"] as? String ?? "",
                   avatarURL: (r["avatar_url"] as? String).flatMap(URL.init(string:)),
                   accepted: (r["status"] as? String) == "accepted", incoming: r["incoming"] as? Bool ?? false,
                   isPro: r["is_pro"] as? Bool ?? false)
        }
    }

    static func projects(_ account: AccountModel) async throws -> [SharedProject] {
        let rows = try await rpc(account, "my_shared_projects") as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rows.map { r in
            let members = (r["members"] as? [[String: Any]] ?? []).map { m in
                SharedProject.Member(userID: m["user_id"] as? String ?? "", name: m["name"] as? String ?? "",
                                     email: m["email"] as? String ?? "",
                                     avatarURL: (m["avatar_url"] as? String).flatMap(URL.init(string:)),
                                     role: m["role"] as? String ?? "editor", joined: (m["status"] as? String) == "joined",
                                     isPro: m["is_pro"] as? Bool ?? false)
            }
            return SharedProject(id: r["project_id"] as? String ?? "", name: r["name"] as? String ?? "Untitled",
                                 ownerName: r["owner_name"] as? String ?? "", role: r["role"] as? String ?? "editor",
                                 joined: (r["status"] as? String) == "joined", slot: r["slot"] as? Int ?? 2,
                                 updatedAt: (r["updated_at"] as? String).flatMap { iso.date(from: $0) }, members: members)
        }
    }

    // Storage: <project>/<sha256>.<ext> in the private "project-media" bucket.
    static func storageRequest(_ account: AccountModel, _ path: String, method: String) async throws -> URLRequest {
        guard let base = AccountConfig.url else { throw CollabError("Accounts aren’t set up in this build.") }
        guard let token = await account.validAccessToken() else { throw CollabError("Sign in to collaborate.") }
        let route = method == "GET" ? "storage/v1/object/authenticated/project-media/" : "storage/v1/object/project-media/"
        var r = URLRequest(url: URL(string: base.absoluteString + "/" + route + path)!)
        r.httpMethod = method
        r.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 300
        return r
    }
}

// MARK: - Realtime (Phoenix channels over a WebSocket)

/// The small part of Supabase Realtime collaboration needs: one private channel with broadcast
/// (edits) and presence (who is here, what they have selected).
@MainActor
final class RealtimeChannel: NSObject, URLSessionWebSocketDelegate {
    let topic: String
    var onBroadcast: ((String, [String: Any]) -> Void)?  // event, payload
    var onPresence: (([String: [[String: Any]]]) -> Void)?  // key → metas
    var onStatus: ((String) -> Void)?  // "joined", "closed", "error: …"

    private let accessToken: () async -> String?
    private let presenceKey: String
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var ref = 0
    private var joinRef = ""
    private var heartbeat: Timer?
    private var presence: [String: [[String: Any]]] = [:]
    private var tracked: [String: Any]?
    private var closedByUs = false
    private var reconnectDelay: TimeInterval = 1
    private(set) var joined = false

    init(topic: String, presenceKey: String, accessToken: @escaping () async -> String?) {
        self.topic = "realtime:" + topic
        self.presenceKey = presenceKey
        self.accessToken = accessToken
    }

    func connect() {
        guard let base = AccountConfig.url, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        comps.scheme = "wss"
        comps.path = "/realtime/v1/websocket"
        comps.queryItems = [URLQueryItem(name: "apikey", value: AccountConfig.publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let url = comps.url else { return }
        closedByUs = false
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        let task = s.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        socket = task
        task.resume()
        receive()
        Task { await join() }
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(topic: "phoenix", event: "heartbeat", payload: [:]) }
        }
    }

    func close() {
        closedByUs = true
        heartbeat?.invalidate()
        if joined { send(event: "phx_leave", payload: [:]) }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()  // the session holds its delegate (us) until invalidated
        session = nil
        joined = false
    }

    func broadcast(_ event: String, _ payload: [String: Any]) {
        guard joined else { return }
        send(event: "broadcast", payload: ["type": "broadcast", "event": event, "payload": payload])
    }

    func track(_ meta: [String: Any]) {
        tracked = meta
        guard joined else { return }
        send(event: "presence", payload: ["type": "presence", "event": "track", "payload": meta])
    }

    /// After a token refresh (they last an hour).
    func refreshToken() async {
        guard joined, let token = await accessToken() else { return }
        send(event: "access_token", payload: ["access_token": token])
    }

    private func join() async {
        // No token is also what a refresh that failed offline (just after waking) looks like, so keep trying.
        guard let token = await accessToken() else { dropped("error: Sign in to collaborate."); return }
        ref += 1
        joinRef = String(ref)
        let config: [String: Any] = ["broadcast": ["ack": false, "self": false],
                                     "presence": ["key": presenceKey, "enabled": true],
                                     "postgres_changes": [], "private": true]
        send(event: "phx_join", payload: ["config": config, "access_token": token], ref: joinRef)
    }

    private func send(topic: String? = nil, event: String, payload: [String: Any], ref explicit: String? = nil) {
        guard let socket else { return }
        let r: String
        if let explicit { r = explicit } else { ref += 1; r = String(ref) }
        var message: [String: Any] = ["topic": topic ?? self.topic, "event": event, "payload": payload, "ref": r]
        if topic == nil { message["join_ref"] = joinRef }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive() {
        guard let task = socket else { return }
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                // A socket already given up on fails here too; it must not start a second reconnect.
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if case .data(let data) = message { self.handle(String(decoding: data, as: UTF8.self)) }
                    self.receive()
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              (m["topic"] as? String) == topic else { return }
        let event = m["event"] as? String ?? ""
        let payload = m["payload"] as? [String: Any] ?? [:]
        switch event {
        case "phx_reply":
            guard (m["ref"] as? String) == joinRef else { return }
            if (payload["status"] as? String) == "ok" {
                joined = true
                reconnectDelay = 1
                onStatus?("joined")
                if let tracked { track(tracked) }
            } else {
                let reason = ((payload["response"] as? [String: Any])?["reason"] as? String) ?? "The live session refused the connection."
                // Most refusals pass: the first join after the server sat idle for days arrives before it has
                // set up the day (MissingPartition), or the token just expired. Only a non-member is final.
                if reason.localizedCaseInsensitiveContains("unauthorized") { onStatus?("error: " + reason) } else { dropped() }
            }
        case "broadcast":
            onBroadcast?(payload["event"] as? String ?? "", payload["payload"] as? [String: Any] ?? [:])
        case "presence_state":
            presence = [:]
            for (key, value) in payload { presence[key] = (value as? [String: Any])?["metas"] as? [[String: Any]] ?? [] }
            onPresence?(presence)
        case "presence_diff":
            for (key, value) in payload["leaves"] as? [String: Any] ?? [:] {
                let gone = Set(((value as? [String: Any])?["metas"] as? [[String: Any]] ?? []).compactMap { $0["phx_ref"] as? String })
                presence[key] = (presence[key] ?? []).filter { !gone.contains($0["phx_ref"] as? String ?? "") }
                if presence[key]?.isEmpty == true { presence[key] = nil }
            }
            for (key, value) in payload["joins"] as? [String: Any] ?? [:] {
                presence[key, default: []].append(contentsOf: (value as? [String: Any])?["metas"] as? [[String: Any]] ?? [])
            }
            onPresence?(presence)
        case "phx_error", "phx_close":
            joined = false
            if !closedByUs { dropped() }
        case "system":
            if (payload["status"] as? String) == "error" { onStatus?("error: " + (payload["message"] as? String ?? "Live session error")) }
        default:
            break
        }
    }

    /// Lost the connection or refused: reconnect with backoff (the session pulls what it missed when it rejoins).
    private func dropped(_ status: String = "closed") {
        guard !closedByUs else { return }
        joined = false
        onStatus?(status)
        socket?.cancel()
        socket = nil
        session?.invalidateAndCancel()  // or it keeps holding us as its delegate
        session = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { if let self, !self.closedByUs { self.connect() } }
        }
    }
}

// MARK: - A live shared editing session

@MainActor
final class CollabSession: ObservableObject {
    struct Participant: Identifiable, Hashable {
        let id: String  // presence key: user id
        let name: String
        let avatarURL: URL?
        let color: Int
        let selectedLayers: [UInt64]
        let composition: UInt64
    }

    let project: SharedProject
    @Published private(set) var participants: [Participant] = []  // others who are here now
    @Published private(set) var connected = false
    @Published private(set) var problem: String?
    @Published private(set) var pendingUploads = 0
    @Published private(set) var pendingDownloads = 0
    var isActive: Bool { channel != nil }

    private unowned let editor: EditorModel
    private let account: AccountModel
    let sync: MFCollabSync
    private let clientID = UUID().uuidString.lowercased()
    private var channel: RealtimeChannel?
    private var flushScheduled = false
    private var dbQueue: [String: [String: Any]] = [:]  // key → piece, latest wins
    private var dbTimer: Timer?
    private var tokenTimer: Timer?
    private var mediaNames: [String: (Date, UInt64, String)] = [:]  // path → (modified, size, media name)
    private var localMedia: [String: String] = [:]  // media name → original file on this Mac
    private var uploaded = Set<String>()
    private var downloading = Set<String>()
    private var tooBig = Set<String>()

    static let colors = [0xFF7A59, 0x4FC3F7, 0xB388FF, 0x69F0AE, 0xFFD54F, 0xF06292]

    init(project: SharedProject, editor: EditorModel) {
        self.project = project
        self.editor = editor
        self.account = editor.account
        sync = MFCollabSync(engine: editor.engine, clientID: clientID, slot: project.slot)
        sync.mediaNameForAsset = { [weak self] _, path in
            MainActor.assumeIsolated { self?.mediaName(forFile: path) ?? "" }
        }
        sync.pathForMedia = { [weak self] media in
            MainActor.assumeIsolated { self?.localPath(forMedia: media) ?? "" }
        }
    }

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MotionForge/Shared", isDirectory: true)
    }
    private var cacheDir: URL { Self.cacheRoot.appendingPathComponent(project.id, isDirectory: true) }

    // MARK: Start / join / leave

    /// Owner: seeds the server with the open project, then goes live.
    func startSharing() async throws {
        let pieces = sync.startSharing()
        try await push(json: pieces)
        connect()
    }

    /// Everyone else: loads the shared project into the editor, then goes live.
    func join() async throws {
        let all = try await CollabAPI.rpc(account, "pull_objects", ["pid": project.id])
        let data = try JSONSerialization.data(withJSONObject: all)
        try sync.join(withPieces: String(decoding: data, as: UTF8.self))
        connect()
    }

    func leave() {
        flushNow()
        pushQueuedToServer()
        channel?.close()
        channel = nil
        dbTimer?.invalidate()
        tokenTimer?.invalidate()
        connected = false
        participants = []
    }

    private func connect() {
        let presenceKey = account.user?.id ?? clientID
        let ch = RealtimeChannel(topic: "project:" + project.id, presenceKey: presenceKey) { [weak account] in
            await account?.validAccessToken()
        }
        ch.onBroadcast = { [weak self] event, payload in self?.received(event, payload) }
        ch.onPresence = { [weak self] state in self?.presenceChanged(state) }
        ch.onStatus = { [weak self] status in self?.statusChanged(status) }
        channel = ch
        ch.connect()
        trackPresence()
        dbTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushQueuedToServer() }
        }
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.channel?.refreshToken() } }
        }
    }

    private func statusChanged(_ status: String) {
        if status == "joined" {
            let wasReconnect = !connected && problem != nil
            connected = true
            problem = nil
            if wasReconnect { Task { await catchUp() } }
        } else if status == "closed" {
            connected = false
            problem = "Reconnecting…"
        } else if status.hasPrefix("error: ") {
            connected = false
            problem = String(status.dropFirst(7))
        }
    }

    /// After a dropped connection: pull everything and merge (newer pieces win, so this is safe).
    private func catchUp() async {
        guard let all = try? await CollabAPI.rpc(account, "pull_objects", ["pid": project.id]),
              let data = try? JSONSerialization.data(withJSONObject: all) else { return }
        applyRemote(String(decoding: data, as: UTF8.self))
    }

    // MARK: Local edits → everyone

    /// Called after every editor refresh. Edits are gathered for ~40 ms (a drag sends ~25 updates a second).
    func noteLocalEdit() {
        guard sync.hasLocalChanges, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated { self?.flushNow() }
        }
    }

    func flushNow() {
        flushScheduled = false
        send(sync.collectLocalChanges())
    }

    func undo() { send(sync.undo()) }
    func redo() { send(sync.redo()) }

    private func send(_ json: String) {
        guard json != "[]", let pieces = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]],
              !pieces.isEmpty else { return }
        // Broadcast messages are kept small; the server copy is written in batches.
        var chunk: [[String: Any]] = []
        var size = 0
        for p in pieces {
            let s = (try? JSONSerialization.data(withJSONObject: p))?.count ?? 64
            if size + s > 180_000, !chunk.isEmpty {
                channel?.broadcast("pieces", ["pieces": chunk, "from": clientID])
                chunk = []
                size = 0
            }
            chunk.append(p)
            size += s
            if let k = p["k"] as? String { dbQueue[k] = p }
        }
        if !chunk.isEmpty { channel?.broadcast("pieces", ["pieces": chunk, "from": clientID]) }
    }

    private func pushQueuedToServer() {
        guard !dbQueue.isEmpty else { return }
        let batch = Array(dbQueue.values)
        dbQueue = [:]
        Task {
            do {
                for start in stride(from: 0, to: batch.count, by: 400) {
                    let slice = Array(batch[start..<min(start + 400, batch.count)])
                    _ = try await CollabAPI.rpc(account, "push_objects", ["pid": project.id, "pieces": slice])
                }
            } catch {
                // Keep them for the next round (newer pieces for the same key replace them).
                for p in batch { if let k = p["k"] as? String, dbQueue[k] == nil { dbQueue[k] = p } }
                problem = "Couldn’t save to the server: \(error.localizedDescription)"
            }
        }
    }

    private func push(json: String) async throws {
        guard let pieces = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return }
        for start in stride(from: 0, to: pieces.count, by: 400) {
            let slice = Array(pieces[start..<min(start + 400, pieces.count)])
            _ = try await CollabAPI.rpc(account, "push_objects", ["pid": project.id, "pieces": slice])
        }
    }

    // MARK: Everyone → here

    private func received(_ event: String, _ payload: [String: Any]) {
        guard event == "pieces", (payload["from"] as? String) != clientID,
              let pieces = payload["pieces"], let data = try? JSONSerialization.data(withJSONObject: pieces) else { return }
        applyRemote(String(decoding: data, as: UTF8.self))
    }

    private func applyRemote(_ json: String) {
        var pending: NSString?
        let changed = sync.applyRemotePieces(json, pending: &pending)
        if let pending { send(pending as String) }
        if changed { editor.remoteDidChange() }
    }

    // MARK: Presence

    func trackPresence() {
        let me = account.user
        let color = Self.colors[abs(clientID.hashValue) % Self.colors.count]
        channel?.track([
            "name": me?.name.isEmpty == false ? me!.name : (me?.email ?? "Someone"),
            "avatar": me?.avatarURL?.absoluteString ?? "",
            "color": color,
            "client": clientID,
            "layers": editor.selectedLayerIDs.map { NSNumber(value: $0) },
            "comp": NSNumber(value: editor.comp.compID),
        ])
    }

    private func presenceChanged(_ state: [String: [[String: Any]]]) {
        var list: [Participant] = []
        for (key, metas) in state {
            for m in metas where (m["client"] as? String) != clientID {
                list.append(Participant(id: key + (m["client"] as? String ?? ""), name: m["name"] as? String ?? "Someone",
                                        avatarURL: (m["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                        color: m["color"] as? Int ?? 0x4FC3F7,
                                        selectedLayers: (m["layers"] as? [NSNumber] ?? []).map(\.uint64Value),
                                        composition: (m["comp"] as? NSNumber)?.uint64Value ?? 0))
            }
        }
        participants = list.sorted { $0.name < $1.name }
    }

    /// Who else has `layer` selected (for the timeline).
    func others(on layer: UInt64) -> [Participant] { participants.filter { $0.selectedLayers.contains(layer) } }

    // MARK: Media

    /// "<sha256>.<ext>" for a file; starts its upload the first time.
    private func mediaName(forFile path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return "" }
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        if let cached = mediaNames[path], cached.0 == modified, cached.1 == size { return cached.2 }
        // Files already in the shared cache are named by their hash.
        if url.deletingLastPathComponent().path == cacheDir.path {
            mediaNames[path] = (modified, size, url.lastPathComponent)
            return url.lastPathComponent
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        let name = ext.isEmpty ? hash : hash + "." + ext
        mediaNames[path] = (modified, size, name)
        localMedia[name] = path
        upload(name, from: url, size: size)
        return name
    }

    private func localPath(forMedia media: String) -> String {
        if let original = localMedia[media], FileManager.default.fileExists(atPath: original) { return original }
        let file = cacheDir.appendingPathComponent(media)
        if !FileManager.default.fileExists(atPath: file.path) { download(media, to: file) }
        return file.path
    }

    private func upload(_ name: String, from url: URL, size: UInt64) {
        guard !uploaded.contains(name) else { return }
        uploaded.insert(name)
        guard size <= 50 << 20 else {
            tooBig.insert(url.lastPathComponent)
            problem = "“\(url.lastPathComponent)” is over 50 MB, so others won’t see it. Use a smaller file."
            return
        }
        pendingUploads += 1
        let account = self.account, pid = project.id
        Task {
            defer { pendingUploads -= 1 }
            do {
                var r = try await CollabAPI.storageRequest(account, "\(pid)/\(name)", method: "POST")
                r.setValue("false", forHTTPHeaderField: "x-upsert")
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await URLSession.shared.upload(for: r, fromFile: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(decoding: data, as: UTF8.self)
                // Someone already uploaded the same file: fine.
                if !(200..<300).contains(code) && !(code == 409 || text.contains("Duplicate") || text.contains("already exists")) {
                    uploaded.remove(name)
                    problem = "Couldn’t upload “\(url.lastPathComponent)” (\(code))."
                }
            } catch {
                uploaded.remove(name)
                problem = "Couldn’t upload “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
    }

    private func download(_ media: String, to file: URL) {
        guard !downloading.contains(media) else { return }
        downloading.insert(media)
        pendingDownloads += 1
        let account = self.account, pid = project.id
        Task {
            defer { pendingDownloads -= 1; downloading.remove(media) }
            for attempt in 0..<6 {
                do {
                    let r = try await CollabAPI.storageRequest(account, "\(pid)/\(media)", method: "GET")
                    let (tmp, response) = try await URLSession.shared.download(for: r)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? FileManager.default.removeItem(at: file)
                        try FileManager.default.moveItem(at: tmp, to: file)
                        if sync.refreshMedia() { editor.remoteDidChange() }
                        return
                    }
                } catch {}
                // Not uploaded yet (the owner may still be sending it): try again shortly.
                try? await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
            }
        }
    }
}
