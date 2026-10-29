import AppKit
import MFRender

/// Scripted check of the After Effects shortcuts (scripts/ui-demo-shortcuts.sh). Keys are posted to the
/// app's own event queue and mouse drags sent to its own window, so they take the same path as real
/// input: the key monitor, then the menus' key equivalents. Screenshots and `shortcuts.json` go to the
/// output folder.
extension UIDemo {
    @MainActor static func runShortcuts(model: EditorModel, outputDirectory: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log: [[String: Any]] = []
            var failures: [String] = []
            @MainActor func check(_ ok: Bool, _ what: String, _ detail: Any? = nil) {
                print("ui-demo-shortcuts \(ok ? "ok  " : "FAIL") \(what)\(detail.map { " (\($0))" } ?? "")")
                if !ok { failures.append(what) }
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }),
                  var viewer = findViewerView(in: window.contentView) else {
                print("ui-demo-shortcuts: no window"); exit(4)
            }
            window.makeKeyAndOrderFront(nil)
            @MainActor func capture(_ name: String, _ w: NSWindow? = nil) {
                let win = w ?? window
                if let v = win.contentView?.superview ?? win.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
                }
                log.append(["screenshot": name])
            }
            @MainActor func pause(_ s: Double = 0.2) async { try? await Task.sleep(for: .seconds(s)) }
            /// A key press as the keyboard sends it, through the app's own event queue (never system-wide).
            @MainActor func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
                if flags.contains(.command) || flags.contains(.option) {
                    // Menu shortcuts: only an event made from a CGEvent carries the keyboard data the
                    // menus match ⇧ and ⌥ combinations against. It is posted to this app, not the system.
                    for down in [true, false] {
                        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                        var f: CGEventFlags = []
                        if flags.contains(.command) { f.insert(.maskCommand) }
                        if flags.contains(.option) { f.insert(.maskAlternate) }
                        if flags.contains(.shift) { f.insert(.maskShift) }
                        cg.flags = f
                        if let e = NSEvent(cgEvent: cg) { NSApp.postEvent(e, atStart: false) }
                    }
                    await pause(0.25)
                    return
                }
                let shown = flags.contains(.shift) ? chars.uppercased() : chars
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: shown,
                                                charactersIgnoringModifiers: shown, isARepeat: false, keyCode: code) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
                await pause(0.25)
            }
            @MainActor func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
                let e = NSEvent.mouseEvent(with: type, location: viewer.convert(p, to: nil), modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                // Straight to the viewer: while you work in another app the window isn't key, and a
                // window's first click would only bring it forward.
                switch type {
                case .leftMouseDown: viewer.mouseDown(with: e)
                case .leftMouseDragged: viewer.mouseDragged(with: e)
                default: viewer.mouseUp(with: e)
                }
            }
            @MainActor func view(_ comp: CGPoint) -> CGPoint { model.viewerGeometry(viewer.bounds.size).toView(comp) }
            @MainActor func dragComp(_ a: CGPoint, _ b: CGPoint, through mid: [CGPoint] = [], _ flags: NSEvent.ModifierFlags = []) async {
                let pts = [a] + mid + [b]
                mouse(.leftMouseDown, view(a), flags)
                for (p, q) in zip(pts, pts.dropFirst()) {
                    for i in 1...8 {
                        let t = Double(i) / 8
                        mouse(.leftMouseDragged, view(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)), flags)
                    }
                }
                mouse(.leftMouseUp, view(b), flags)
                await pause()
            }
            @MainActor func clickComp(_ p: CGPoint, _ flags: NSEvent.ModifierFlags = []) async {
                mouse(.leftMouseDown, view(p), flags)
                mouse(.leftMouseUp, view(p), flags)
                await pause()
            }
            @MainActor func layer(named name: String) -> MFLayerInfo? { model.layers.first { $0.name == name } }
            @MainActor func value(_ p: MFProp, _ id: UInt64) -> MFValue { model.engine.value(of: p, layer: id, time: model.time.time) }
            func near(_ a: Double, _ b: Double, _ eps: Double = 0.5) -> Bool { abs(a - b) <= eps }

            await pause(1.5)
            model.showProjectPanel = true; model.showTimeline = true; model.showInspector = true
            window.makeFirstResponder(viewer)
            await pause(0.5)

            // 1. Every menu shortcut is there, and no two menu items share one.
            var equivalents: [String: [String]] = [:]
            func walk(_ menu: NSMenu, _ path: String) {
                for item in menu.items {
                    if let sub = item.submenu { walk(sub, path + item.title + " ▸ ") }
                    guard !item.keyEquivalent.isEmpty, !item.isAlternate, !item.isHidden else { continue }
                    var mods = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                    var k = item.keyEquivalent
                    if k != k.lowercased() { mods.insert(.shift); k = k.lowercased() }  // "D" means ⇧D
                    let sig = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") +
                        (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "") + k.uppercased()
                    equivalents[sig, default: []].append(path + item.title)
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            let expected: [(String, String)] = [
                ("⌥⌘N", "New Project"), ("⌘N", "New Composition"), ("⌘O", "Open Project…"), ("⌘S", "Save"),
                ("⇧⌘S", "Save As…"), ("⌘I", "Import Media…"), ("⌘M", "Export Video…"), ("⌥⌘M", "Export with Last Settings…"),
                ("⌘K", "Composition Settings…"), ("⌘,", "Settings…"), ("⌘Z", "Undo"), ("⇧⌘Z", "Redo"),
                ("⌥⌘Z", "Step Backward"), ("⇧⌘D", "Split Layer"), ("⇧⌘C", "Pre-compose…"), ("⇧⌘X", "Trim Comp to Work Area"),
                ("⌘T", "Type"), ("⌘/", "Keyboard Shortcuts"),
            ]
            for (sig, title) in expected {
                let holders = equivalents[sig] ?? []
                check(holders.contains { $0.hasSuffix(title) || $0.hasSuffix(" ▸ " + title) || $0.contains(title) }, "menu \(sig) is \(title)", holders)
            }
            let clashes = equivalents.filter { $0.value.count > 1 }
            check(clashes.isEmpty, "no two menu items share a shortcut", clashes)
            log.append(["menuShortcuts": equivalents.mapValues { $0.joined(separator: " | ") }])

            // 2. Tools by key; Q twice moves to the next shape; ⌘T (a menu shortcut) is Type; Esc goes back.
            for (k, code, t) in [("h", UInt16(4), EditorTool.hand), ("z", 6, .zoom), ("w", 13, .rotate), ("y", 16, .panBehind),
                                 ("g", 5, .pen), ("q", 12, .shape), ("v", 9, .select)] {
                await key(k, code)
                check(model.tool == t, "\(k.uppercased()) picks the \(t.name) tool", "\(model.tool)")
            }
            await key("q", 12)
            let firstShape = model.shapeTool
            await key("q", 12)
            check(model.tool == .shape && model.shapeTool != firstShape, "Q again picks the next shape", model.shapeTool.toolName)
            capture("shortcuts-01-shape-tool")
            await key("t", 17, .command)
            check(model.tool == .type, "⌘T picks the Type tool", "\(model.tool)")
            await key("\u{1b}", 53)
            check(model.tool == .select, "Esc goes back to Selection")
            model.shapeTool = .rectangle

            // 3. Property reveal on the selected layer, and on all layers with nothing selected.
            guard let star = layer(named: "Star")?.layerID, let ring = layer(named: "Ring")?.layerID else {
                print("ui-demo-shortcuts: no starter scene"); exit(4)
            }
            model.selectLayer(star, mode: .replace)
            await key("p", 35)
            check(model.propertyReveal[star] == .props([.position]), "P shows Position")
            await key("r", 15, .shift)
            check(model.propertyReveal[star] == .props([.position, .rotation]), "⇧R adds Rotation")
            await key("p", 35, .shift)
            check(model.propertyReveal[star] == .props([.rotation]), "⇧P takes Position away again")
            await key("t", 17)
            check(model.propertyReveal[star] == .props([.opacity]), "T shows Opacity")
            capture("shortcuts-02-reveal-opacity")
            await key("t", 17)
            check(model.propertyReveal[star] == nil, "T again hides it")
            await key("u", 32)
            check(model.propertyReveal[star] == .animated, "U shows animated properties")
            await pause(0.5)  // two U presses close together are UU
            await key("u", 32)
            check(model.propertyReveal[star] == nil, "U again hides them")
            await pause(0.5)
            await key("u", 32)
            let modified = model.engine.modifiedProperties(layer: star).count
            await key("u", 32)
            check(model.propertyReveal[star] == .modified, "UU shows modified properties", "\(modified) modified")
            capture("shortcuts-03-reveal-modified")
            model.clearSelection()
            await key("s", 1)
            check(model.layers.allSatisfy { model.propertyReveal[$0.layerID] == .props([.scale]) }, "S with nothing selected shows Scale on every layer")
            model.hideRevealedProperties()

            // 4. Work area: B at 1 s, N at 3 s (its frame included); the export defaults to it.
            let fd = model.frameDuration
            model.time.time = 1
            await key("b", 11)
            model.time.time = 3
            await key("n", 45)
            check(model.comp.hasWorkArea && near(model.comp.workAreaStart, 1, 1e-6) && near(model.comp.workAreaEnd, 3 + fd, 1e-6),
                  "B / N set the work area", "\(model.comp.workAreaStart)–\(model.comp.workAreaEnd)")
            capture("shortcuts-04-work-area")

            // 5. RAM Preview: the first pass renders every work-area frame, then it plays in real time, looping.
            await key("0", 82, .numericPad)
            check(model.ramPreview && model.time.isPlaying, "0 starts RAM Preview")
            var minT = Double.infinity, maxT = -Double.infinity
            var sawFill = false
            for _ in 0..<60 {
                await pause(0.1)
                minT = min(minT, model.time.time)
                maxT = max(maxT, model.time.time)
                if model.perf.ramPreviewFill != nil { sawFill = true }
            }
            check(minT >= 1 - 1e-6 && maxT <= 3 + 1e-6, "RAM Preview stays in the work area", "\(minT)–\(maxT)")
            check(sawFill || model.perf.cachedFrames.count > 0, "RAM Preview renders frames into the cache")
            let cached = model.engine.cachedFrames(forQualityDivisor: model.perf.currentDivisor)
            let wanted = IndexSet(integersIn: Int((1 / fd).rounded())..<Int(((3 + fd) / fd).rounded()))
            check(wanted.isSubset(of: cached), "every work-area frame is cached", "\(cached.intersection(wanted).count)/\(wanted.count)")
            await key(" ", 49)
            await pause(0.3)
            check(!model.ramPreview && !model.time.isPlaying && model.engine.cachePolicy == model.cachePolicy,
                  "Space stops it and the cache setting is back")

            // 6. Split Layer (⇧⌘D) at 2 s, then Undo (⌘Z).
            let before = model.layers.count
            model.selectLayer(star, mode: .replace)
            model.time.time = 2
            await key("d", 2, [.command, .shift])
            let second = model.selection.flatMap { id in model.layers.first { $0.layerID == id } }
            check(model.layers.count == before + 1 && second.map { near($0.inPoint, 2, 1e-6) } == true, "⇧⌘D splits the layer at the playhead",
                  second.map { "\($0.name) from \($0.inPoint)" })
            capture("shortcuts-05-split")
            await key("z", 6, .command)
            check(model.layers.count == before, "⌘Z undoes the split")

            // 7. Pre-compose (the menu's dialog is skipped here), then Step Backward (⌥⌘Z).
            let comps = model.engine.compositions.count
            model.selectLayers([star, ring])
            model.precomposeSelection(named: "Test Pre-comp")
            let pre = model.layers.first { $0.kind == .precomp && $0.name == "Test Pre-comp" }
            check(model.engine.compositions.count == comps + 1 && pre != nil && model.layers.count == before - 1,
                  "Pre-compose moves the layers into a new comp")
            capture("shortcuts-06-precomposed")
            await key("z", 6, [.command, .option])
            check(model.engine.compositions.count == comps && model.layers.count == before, "⌥⌘Z (Step Backward) undoes it")

            // 8. Trim Comp to Work Area (⇧⌘X) and New Composition (⌘N), each undone.
            let duration = model.comp.duration
            await key("x", 7, [.command, .shift])
            check(near(model.comp.duration, 2 + fd, 1e-6) && !model.comp.hasWorkArea, "⇧⌘X trims the comp to the work area", model.comp.duration)
            await key("z", 6, .command)
            check(near(model.comp.duration, duration, 1e-6) && model.comp.hasWorkArea, "⌘Z puts the comp back")
            let mainComp = model.comp.compID
            await key("n", 45, .command)
            check(model.engine.compositions.count == comps + 1 && model.comp.compID != mainComp, "⌘N makes a new composition")
            await key("z", 6, .command)
            if model.comp.compID != mainComp { model.openComposition(mainComp) }
            check(model.engine.compositions.count == comps, "⌘Z removes it again")
            model.clearWorkArea()

            // 9. The tools in the viewer (a new one if switching compositions rebuilt it).
            await pause(0.5)
            if let v = findViewerView(in: window.contentView) { viewer = v }
            model.setZoom(nil, viewSize: viewer.bounds.size)
            window.makeFirstResponder(viewer)
            await key("q", 12)  // rectangle
            let layersBefore = model.layers.count
            await dragComp(CGPoint(x: 300, y: 200), CGPoint(x: 700, y: 500))
            let rect = model.selection.flatMap { id in model.layers.first { $0.layerID == id } }
            let size = rect.map { value(.size, $0.layerID) }
            check(model.layers.count == layersBefore + 1 && rect?.shape == .rectangle && size.map { near($0.x, 400, 2) && near($0.y, 300, 2) } == true
                  && rect.map { near(value(.position, $0.layerID).x, 500, 2) } == true, "the Shape tool draws a 400×300 rectangle",
                  size.map { "\($0.x)×\($0.y)" })
            guard let rid = rect?.layerID else { print("ui-demo-shortcuts: no rectangle"); exit(4) }
            await key("w", 13)
            await dragComp(CGPoint(x: 700, y: 350), CGPoint(x: 500, y: 550), through: [CGPoint(x: 641, y: 491)])
            check(near(value(.rotation, rid).x, 90, 2), "the Rotation tool turns it 90°", value(.rotation, rid).x)
            capture("shortcuts-07-rotated")
            let quad = model.engine.quad(forLayer: rid, time: model.time.time)
            let anchor = value(.anchorPoint, rid)
            await key("y", 16)
            await dragComp(CGPoint(x: 500, y: 350), CGPoint(x: 580, y: 350))
            let quad2 = model.engine.quad(forLayer: rid, time: model.time.time)
            let anchor2 = value(.anchorPoint, rid)
            let still = [(quad.topLeft, quad2.topLeft), (quad.bottomRight, quad2.bottomRight)].allSatisfy { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < 1 }
            check(still && hypot(anchor2.x - anchor.x, anchor2.y - anchor.y) > 70, "Pan Behind moves the anchor point, not the layer",
                  "anchor moved \(Int(hypot(anchor2.x - anchor.x, anchor2.y - anchor.y)))")
            capture("shortcuts-08-anchor-moved")
            await key("h", 4)
            let pan = model.pan
            mouse(.leftMouseDown, CGPoint(x: 300, y: 300))
            for i in 1...6 { mouse(.leftMouseDragged, CGPoint(x: 300 + 10 * i, y: 300 + 5 * i)) }
            mouse(.leftMouseUp, CGPoint(x: 360, y: 330))
            await pause()
            check(near(model.pan.width - pan.width, 60, 1) && near(model.pan.height - pan.height, 30, 1), "the Hand tool pans the viewer")
            await key("z", 6)
            let fit = model.viewerGeometry(viewer.bounds.size).scale
            await clickComp(CGPoint(x: 960, y: 540))
            check(near((model.zoom ?? 0) / fit, 2, 0.01), "a Zoom tool click zooms in")
            await clickComp(CGPoint(x: 960, y: 540), .option)
            check(near((model.zoom ?? 0) / fit, 1, 0.01), "⌥-click zooms back out")
            model.setZoom(nil, viewSize: viewer.bounds.size)
            await key("t", 17, .command)
            let texts = model.layers.filter { $0.kind == .text }.count
            await clickComp(CGPoint(x: 400, y: 260))
            await pause(0.6)
            let text = model.selection.flatMap { id in model.layers.first { $0.layerID == id } }
            check(model.layers.filter { $0.kind == .text }.count == texts + 1 && text.map { near(value(.position, $0.layerID).x, 400, 2) } == true,
                  "the Type tool places a text layer at the click")
            check(window.firstResponder is NSTextView && model.tool == .select, "…with the cursor in its text, ready to type")
            capture("shortcuts-09-type")
            window.makeFirstResponder(viewer)

            // 10. Help ▸ Keyboard Shortcuts (⌘/) and Preferences (⌥⌘;).
            await key("/", 44, .command)
            await pause(0.6)
            check(model.showShortcuts, "⌘/ opens the shortcut sheet")
            if let sheet = window.attachedSheet { capture("shortcuts-10-sheet", sheet) }
            model.showShortcuts = false
            await pause(0.6)
            let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            await key(";", 41, [.command, .option])
            await pause(1.0)
            let settings = NSApp.windows.first { $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0)) }
            check(settings != nil, "⌥⌘; opens Preferences", settings?.title)
            if let settings {
                capture("shortcuts-11-preferences", settings)
                settings.close()
            }

            log.append(["failures": failures])
            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("shortcuts.json"))
            }
            print(failures.isEmpty ? "ui-demo-shortcuts: all checks passed" : "ui-demo-shortcuts: FAILED \(failures)")
            model.engine.markCleanForNewDocument()  // nothing to save: quit without asking
            model.applicationWillTerminate()
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    @MainActor private static func findViewerView(in view: NSView?) -> ViewerMTKView? {
        guard let view else { return nil }
        if let v = view as? ViewerMTKView { return v }
        for sub in view.subviews { if let v = findViewerView(in: sub) { return v } }
        return nil
    }
}
