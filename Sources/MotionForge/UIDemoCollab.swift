import AppKit
import CryptoKit
import MFRender

/// Live check of collaboration against the real server (scripts/ui-demo-collab.sh), signed in as the
/// person using this Mac. The editor shares a small project; a second editor ("B": its own engine,
/// merge state and live connection, in this process) joins it. Both edit — including the same property
/// at the same moment — and the check looks at presence, per-person undo, the shared media and what the
/// server kept, then stops sharing (which deletes the shared project). Results go to collab.json.
extension UIDemo {
    @MainActor final class Peer {
        let engine: MFEngine
        let sync: MFCollabSync
        let client: String
        var channel: RealtimeChannel?
        var joined = false
        var error: String?
        var received = 0
        init(engine: MFEngine, client: String, slot: Int) {
            self.engine = engine
            self.client = client
            sync = MFCollabSync(engine: engine, clientID: client, slot: slot)
        }
    }

    @MainActor static func runCollab(model: EditorModel, outputDirectory: String) {
        ignoresKeys = true
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log: [[String: Any]] = []
            var failures: [String] = []
            @MainActor func check(_ ok: Bool, _ what: String) {
                if !ok { failures.append(what) }
                log.append(["check": what, "ok": ok])
                print("ui-demo-collab \(ok ? "ok  " : "FAIL") \(what)")
            }
            @MainActor func note(_ key: String, _ value: Any) { log.append([key: value]); print("ui-demo-collab \(key): \(value)") }
            @MainActor func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while !done() {
                    if Date() > end { return false }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return true
            }
            let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            window?.makeKeyAndOrderFront(nil)
            @MainActor func capture(_ name: String) {
                // The frame view, so the toolbar (who is here, Share) is in the picture too.
                guard let v = window?.contentView?.superview ?? window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            }
            @MainActor func finish() -> Never {
                log.append(["failures": failures])
                if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted]) {
                    try? data.write(to: out.appendingPathComponent("collab.json"))
                }
                print(failures.isEmpty ? "ui-demo-collab: all checks passed" : "ui-demo-collab: FAILED \(failures)")
                model.applicationWillTerminate()
                exit(failures.isEmpty ? 0 : 1)
            }
            let account = model.account

            // Signed in (macOS may ask once whether this build may read the Keychain) with a usable token.
            guard await wait(180, { account.isSignedIn }) else {
                check(false, "signed in (sign in to MotionForge, and allow the Keychain request)")
                finish()
            }
            guard await account.validAccessToken() != nil else {
                check(false, "sign-in token is current (switch to MotionForge once so it refreshes, then run again)")
                finish()
            }
            _ = await wait(15) { Date().timeIntervalSince(account.entitlement.checked) < 60 }
            note("pro", account.isPro)

            // Friends: the list loads, and the server knows this account (its profile was created).
            do {
                let friends = try await CollabAPI.friends(account)
                note("friends", friends.count)
                check(true, "friend list loads")
            } catch { check(false, "friend list loads: \(error.localizedDescription)") }
            do {
                _ = try await CollabAPI.rpc(account, "send_friend_request", ["friend_email": account.user?.email ?? ""])
                check(false, "a friend request to yourself is refused")
            } catch {
                check(error.localizedDescription.contains("your own account"), "a friend request to yourself is refused (\(error.localizedDescription))")
            }

            guard account.isPro else {
                // The server must refuse too, not just the app.
                do {
                    _ = try await CollabAPI.rpc(account, "create_shared_project", ["project_name": "MotionForge test", "pieces": []])
                    check(false, "the server refuses sharing without Pro")
                } catch {
                    check(error.localizedDescription.contains("Pro"), "the server refuses sharing without Pro (\(error.localizedDescription))")
                }
                note("stopped", "this account isn't Pro, so the live part can't run")
                finish()
            }

            // A: the editor, sharing a project with an image in it.
            let png = out.appendingPathComponent("shared-logo.png")
            let img = NSImage(size: NSSize(width: 320, height: 160), flipped: false) { r in
                NSColor.systemTeal.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 10, dy: 10), xRadius: 30, yRadius: 30).fill()
                return true
            }
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: png)
            }
            model.importMedia(urls: [png], addToComposition: true)
            model.engine.markCleanForNewDocument()
            model.alertMessage = nil
            await model.startSharing()
            guard let session = model.collab else {
                check(false, "start sharing (\(model.alertMessage ?? "no session"))")
                finish()
            }
            let pid = session.project.id
            check(true, "start sharing")
            var peers: [Peer] = []
            var stopped = false
            @MainActor func cleanUp() async {
                for p in peers { p.channel?.close() }
                peers = []
                guard !stopped else { return }
                stopped = true
                await model.stopSharing()
                await model.social.load(force: true)
                check(model.collab == nil && model.social.project(pid) == nil, "stopping deletes the shared project")
                do {
                    _ = try await CollabAPI.rpc(account, "pull_objects", ["pid": pid])
                    check(false, "after stopping, the server refuses the old project")
                } catch { check(true, "after stopping, the server refuses the old project") }
            }

            check(await wait(20) { session.connected }, "A joins the live channel (\(session.problem ?? "ok"))")
            check(await wait(40) { session.pendingUploads == 0 }, "the image uploads")
            check(session.problem == nil, "no problems reported (\(session.problem ?? "none"))")
            await model.social.load(force: true)
            check(model.social.project(pid)?.isOwner == true, "the shared project is listed as yours")
            try? await Task.sleep(for: .seconds(0.5))
            capture("collab-01-shared")

            // Document tools (the same ones Claude uses) read and edit either side.
            @MainActor func tool(_ engine: MFEngine, _ name: String, _ args: [String: Any]) -> Any? {
                guard let data = try? JSONSerialization.data(withJSONObject: args) else { return nil }
                var handled: ObjCBool = false
                var message: NSString?
                guard let json = engine.runClaudeTool(name, arguments: String(decoding: data, as: UTF8.self), handled: &handled, error: &message) else {
                    failures.append("\(name): \(message ?? "failed")")
                    return nil
                }
                return (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? NSNull()
            }
            // The active composition's layers as "id name", and one property's value.
            @MainActor func layers(_ engine: MFEngine) -> [String] {
                guard let obj = tool(engine, "get_composition", ["composition": model.comp.compID]) as? [String: Any],
                      let list = obj["layers"] as? [[String: Any]] else { return [] }
                return list.map { "\($0["id"] ?? "?") \($0["name"] ?? "?")" }.sorted()
            }
            @MainActor func value(_ engine: MFEngine, layer: UInt64, _ key: String) -> Double? {
                guard let obj = tool(engine, "get_layer", ["layer": layer]) else { return nil }
                func find(_ o: Any) -> Double? {
                    if let d = o as? [String: Any] {
                        if (d["key"] as? String) == key, let v = d["value"] as? Double { return v }
                        for v in d.values { if let r = find(v) { return r } }
                    } else if let a = o as? [Any] {
                        for v in a { if let r = find(v) { return r } }
                    }
                    return nil
                }
                return find((obj as? [String: Any])?["properties"] ?? obj)
            }
            @MainActor func run(_ engine: MFEngine, _ name: String, _ args: [String: Any]) -> Bool { tool(engine, name, args) != nil }

            // B joins from what the server stored, and goes live on the same channel.
            @MainActor func join(_ client: String, slot: Int, live: Bool) async -> Peer? {
                guard let engine = try? MFEngine(device: model.engine.device) else { return nil }
                let p = Peer(engine: engine, client: client, slot: slot)
                let media = out.appendingPathComponent("\(client)-media", isDirectory: true)
                p.sync.mediaNameForAsset = { _, _ in "" }
                p.sync.pathForMedia = { name in media.appendingPathComponent(name).path }
                do {
                    let all = try await CollabAPI.rpc(account, "pull_objects", ["pid": pid])
                    try p.sync.join(withPieces: String(decoding: try JSONSerialization.data(withJSONObject: all), as: UTF8.self))
                } catch {
                    check(false, "\(client) joins: \(error.localizedDescription)")
                    return nil
                }
                peers.append(p)
                guard live else { return p }
                let ch = RealtimeChannel(topic: "project:" + pid, presenceKey: account.user?.id ?? client) { [weak account] in
                    await account?.validAccessToken()
                }
                ch.onStatus = { [weak p] status in
                    if status == "joined" { p?.joined = true }
                    if status.hasPrefix("error: ") { p?.error = String(status.dropFirst(7)) }
                }
                ch.onBroadcast = { [weak p] event, payload in
                    guard let p, event == "pieces", (payload["from"] as? String) != p.client, let pieces = payload["pieces"],
                          let data = try? JSONSerialization.data(withJSONObject: pieces) else { return }
                    var pending: NSString?
                    _ = p.sync.applyRemotePieces(String(decoding: data, as: UTF8.self), pending: &pending)
                    p.received += 1
                }
                p.channel = ch
                ch.connect()
                ch.track(["name": "Test editor B", "avatar": "", "color": 0x69F0AE, "client": client,
                          "layers": [NSNumber](), "comp": NSNumber(value: model.comp.compID)])
                return p
            }
            @MainActor func send(_ p: Peer) async {
                let json = p.sync.collectLocalChanges()
                guard let pieces = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]], !pieces.isEmpty else { return }
                p.channel?.broadcast("pieces", ["pieces": pieces, "from": p.client])
                do { _ = try await CollabAPI.rpc(account, "push_objects", ["pid": pid, "pieces": pieces]) }
                catch { failures.append("B push: \(error.localizedDescription)") }
            }

            guard let b = await join("ui-demo-b", slot: 60, live: true) else { await cleanUp(); finish() }
            check(layers(b.engine) == layers(model.engine), "B loads the same layers from the server")
            note("layers", layers(model.engine))

            // Shared media: B fetches the image from storage; it is byte-for-byte the original.
            for asset in b.engine.assets() where asset.missing {
                let name = URL(fileURLWithPath: asset.path).lastPathComponent
                do {
                    let r = try await CollabAPI.storageRequest(account, "\(pid)/\(name)", method: "GET")
                    let (data, response) = try await URLSession.shared.data(for: r)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    check(code == 200, "B downloads \(name.prefix(12))… (\(code))")
                    try FileManager.default.createDirectory(at: URL(fileURLWithPath: asset.path).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: URL(fileURLWithPath: asset.path))
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let original = (try? Data(contentsOf: png)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                    check(name.hasPrefix(hash) && hash == original, "the shared image matches the original")
                } catch { check(false, "B downloads the image: \(error.localizedDescription)") }
            }
            _ = b.sync.refreshMedia()
            check(!b.engine.assets().isEmpty && b.engine.assets().allSatisfy { !$0.missing }, "B has every media file")

            check(await wait(20) { b.joined || b.error != nil } && b.error == nil, "B joins the private live channel (\(b.error ?? "ok"))")
            check(await wait(15) { session.participants.contains { $0.id.hasSuffix(b.client) } }, "A sees B (presence)")
            try? await Task.sleep(for: .seconds(0.5))
            capture("collab-02-presence")

            // A → B, live.
            model.addShape(.star)
            let star = model.selection ?? 0
            check(await wait(10) { layers(b.engine) == layers(model.engine) }, "B sees A's new layer live")

            // B → A, live: B renames A's image layer.
            let image = model.layers.first { $0.layerID != star }?.layerID ?? 0
            if run(b.engine, "set_layer", ["layer": image, "name": "Renamed by B"]) { await send(b) }
            check(await wait(10) { model.layers.contains { $0.name == "Renamed by B" } }, "A sees B's rename live")

            // Undo is per person: A's undo removes A's star, not B's rename.
            model.undo()
            check(await wait(10) {
                !model.layers.contains { $0.layerID == star } && model.layers.contains { $0.name == "Renamed by B" }
                    && layers(b.engine) == layers(model.engine)
            }, "A's undo takes back only A's star, on both")
            model.redo()
            check(await wait(10) { model.layers.contains { $0.layerID == star } && layers(b.engine) == layers(model.engine) },
                  "A's redo brings the star back, on both")

            // The same property, changed by both before either hears from the other: both end up equal.
            _ = run(model.engine, "set_property", ["layer": star, "property": "opacity", "value": 30])
            model.refresh()
            _ = run(b.engine, "set_property", ["layer": star, "property": "opacity", "value": 70])
            await send(b)
            try? await Task.sleep(for: .seconds(3))
            let va = value(model.engine, layer: star, "opacity"), vb = value(b.engine, layer: star, "opacity")
            note("opacity after a simultaneous edit (A, B)", [va ?? -1, vb ?? -1])
            check(va != nil && va == vb && (va == 30 || va == 70), "a simultaneous edit settles on one value for both")

            // The server copy: someone joining now sees exactly this.
            try? await Task.sleep(for: .seconds(3))
            if let c = await join("ui-demo-c", slot: 61, live: false) {
                check(layers(c.engine) == layers(model.engine), "someone joining later gets the same layers")
                check(value(c.engine, layer: star, "opacity") == va, "someone joining later gets the settled value")
            }
            capture("collab-03-edited")

            await cleanUp()
            finish()
        }
    }
}
