import AppKit
import AVFoundation
import MFRender

/// Scripted check of the 3D workspace (scripts/ui-demo-3d.sh): 3D cards at different depths and a
/// 2D title, a camera that moves, the Custom View and Orbit Camera tool, and an export of the move.
/// Renders, `3d.json` and the export go to the output folder.
extension UIDemo {
    @MainActor static func run3D(model: EditorModel, outputDirectory: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            var log: [[String: Any]] = []
            var failures: [String] = []
            @MainActor func check(_ ok: Bool, _ what: String, _ detail: Any? = nil) {
                print("ui-demo-3d \(ok ? "ok  " : "FAIL") \(what)\(detail.map { " (\($0))" } ?? "")")
                log.append(["check": what, "ok": ok, "detail": "\(detail ?? "")"])
                if !ok { failures.append(what) }
            }
            @MainActor func finish() -> Never {
                log.append(["failures": failures])
                if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted]) {
                    try? data.write(to: out.appendingPathComponent("3d.json"))
                }
                print(failures.isEmpty ? "ui-demo-3d: all checks passed" : "ui-demo-3d: FAILED \(failures)")
                model.engine.markCleanForNewDocument()
                model.applicationWillTerminate()
                exit(failures.isEmpty ? 0 : 1)
            }
            @MainActor func render(_ name: String, _ t: Double) {
                try? model.engine.writePNG(atTime: t, scale: 0.5, transparent: false, toPath: out.appendingPathComponent("\(name).png").path)
            }
            @MainActor func centre(_ id: UInt64) -> CGPoint {
                let q = model.engine.quad(forLayer: id, time: model.time.time)
                return CGPoint(x: (q.topLeft.x + q.bottomRight.x) / 2, y: (q.topLeft.y + q.bottomRight.y) / 2)
            }
            try? await Task.sleep(for: .seconds(1))

            var comp: UInt64 = 0
            model.edit { comp = $0.addComposition(name: "3D Check", width: 1280, height: 720, fps: 30, duration: 2) }
            model.openComposition(comp)
            // Three cards in depth (near orange, middle teal, far violet) and a 2D title on top.
            let colours: [(Double, Double, Double)] = [(0.95, 0.55, 0.15), (0.15, 0.7, 0.65), (0.5, 0.35, 0.9)]
            var cards: [UInt64] = []
            for (i, c) in colours.enumerated() {
                model.addShape(.rectangle)
                guard let id = model.selection else { continue }
                cards.append(id)
                model.edit { e in
                    _ = e.setLayer(id, name: ["Near", "Middle", "Far"][i])
                    _ = e.setPropertyValue(MFValue(x: 360, y: 240, z: 0, w: 0), prop: .size, layer: id, time: 0)
                    _ = e.setPropertyValue(MFValue(x: 26, y: 0, z: 0, w: 0), prop: .roundness, layer: id, time: 0)
                    _ = e.setPropertyValue(MFValue(x: c.0, y: c.1, z: c.2, w: 1), prop: .fillColor, layer: id, time: 0)
                    _ = e.setPropertyValue(MFValue(x: 640 + Double(i - 1) * 260, y: 360, z: 0, w: 0), prop: .position, layer: id, time: 0)
                }
            }
            model.selectLayers(cards)
            model.toggleThreeD()  // Layer ▸ 3D Layer
            check(cards.allSatisfy { id in model.layers.first { $0.layerID == id }?.threeD == true }, "Layer ▸ 3D Layer switches the cards to 3D")
            let flat = centre(cards[2])
            for (i, id) in cards.enumerated() {
                model.edit { e in
                    _ = e.setPropertyValue(MFValue(x: Double(i) * 600, y: 0, z: 0, w: 0), prop: .positionZ, layer: id, time: 0)
                    _ = e.setPropertyValue(MFValue(x: [-25.0, 0, 25][i], y: 0, z: 0, w: 0), prop: .rotationY, layer: id, time: 0)
                }
            }
            let far = model.engine.quad(forLayer: cards[2], time: 0)
            check(far.bottomRight.y - far.topRight.y < 240 * 0.75, "the far card looks smaller", "\(Int(far.bottomRight.y - far.topRight.y)) px high")
            model.addText(at: CGPoint(x: 640, y: 110))  // 2D title
            model.edit { e in if let t = model.selection { _ = e.setLayer(t, text: "MotionForge 3D", font: "AvenirNext-Heavy", align: .center) } }
            let title = model.selection ?? 0
            // A camera that dollies in and swings round over 2 s.
            model.addCamera()
            guard let cam = model.layers.first(where: { $0.kind == .camera }) else { check(false, "Layer ▸ New Camera"); finish() }
            check(cam.threeD && cam.icon == "video" && cam.editableProps.contains(.cameraZoom), "Layer ▸ New Camera adds a camera")
            check(abs(centre(cards[2]).x - flat.x - 0) < 400, "a new camera keeps the view")  // (the far card already moved in z)
            let zoom = model.engine.value(of: .cameraZoom, layer: cam.layerID, time: 0).x
            model.edit { e in
                _ = e.set(animated: true, prop: .positionZ, layer: cam.layerID, time: 0)
                _ = e.setPropertyValue(MFValue(x: -zoom + 700, y: 0, z: 0, w: 0), prop: .positionZ, layer: cam.layerID, time: 2)
                _ = e.set(animated: true, prop: .rotationY, layer: cam.layerID, time: 0)
                _ = e.setPropertyValue(MFValue(x: -14, y: 0, z: 0, w: 0), prop: .rotationY, layer: cam.layerID, time: 2)
                _ = e.set(animated: true, prop: .position, layer: cam.layerID, time: 0)
                _ = e.setPropertyValue(MFValue(x: 900, y: 360, z: 0, w: 0), prop: .position, layer: cam.layerID, time: 2)
            }
            model.time.time = 0
            let titleAt0 = centre(title), nearAt0 = centre(cards[0])
            render("3d-01-camera-at-0s", 0)
            model.time.time = 1.9  // the last frames (2 s is the comp's end, where nothing is active)
            let titleAt2 = centre(title), nearAt2 = centre(cards[0])
            render("3d-02-camera-at-1.9s", 1.9)
            check(hypot(titleAt2.x - titleAt0.x, titleAt2.y - titleAt0.y) < 0.5, "the 2D title ignores the camera")
            check(hypot(nearAt2.x - nearAt0.x, nearAt2.y - nearAt0.y) > 50, "the 3D cards move with the camera",
                  "\(Int(nearAt0.x)) → \(Int(nearAt2.x))")

            // Custom View: look from the side; the timeline's C key picks the Orbit Camera tool.
            model.time.time = 0
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) { window.makeFirstResponder(nil) }
            model.selectTool(.orbit)
            model.customView = OrbitView(yaw: -40, pitch: 15, distance: 2.2)
            let side = (centre(cards[0]), centre(cards[2]))
            model.customView = nil
            let front = (centre(cards[0]), centre(cards[2]))
            check(hypot(side.1.x - front.1.x, side.1.y - front.1.y) > 80 && hypot(side.0.x - front.0.x, side.0.y - front.0.y) > 20,
                  "a Custom View sees the cards from the side", "far card \(Int(front.1.x)) → \(Int(side.1.x)) px")
            // Dragging with the Orbit tool turns the view.
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let viewer = findViewer3D(in: window.contentView) {
                func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: viewer.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let a = CGPoint(x: viewer.bounds.midX, y: viewer.bounds.midY)
                viewer.mouseDown(with: ev(.leftMouseDown, a))
                for i in 1...10 { viewer.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x - 12 * Double(i), y: a.y + 4 * Double(i)))) }
                viewer.mouseUp(with: ev(.leftMouseUp, CGPoint(x: a.x - 120, y: a.y + 40)))
                try? await Task.sleep(for: .seconds(0.5))
                check((model.customView?.yaw ?? 0) > 30, "the Orbit tool turns the view", model.customView.map { "yaw \(Int($0.yaw)), pitch \(Int($0.pitch))" })
                try? await Task.sleep(for: .seconds(0.5))
                // The real window (the viewer's Metal picture included), drawn now even if it's behind others.
                model.time.time = 1.0
                for _ in 0..<4 {
                    viewer.draw()
                    try? await Task.sleep(for: .seconds(0.15))
                }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(window.windowNumber), out.appendingPathComponent("3d-03-custom-view-window.png").path]
                try? task.run()
                task.waitUntilExit()
            }
            model.customView = nil
            model.tool = .select

            // Export the camera move (always through the camera, never the Custom View).
            let exportURL = out.appendingPathComponent("camera-move.mp4")
            let settings = MFExportSettings()
            settings.format = .h264
            settings.scale = 0.5
            model.startExport(settings, to: exportURL, summary: "check")
            for _ in 0..<900 where model.exporter != nil { try? await Task.sleep(for: .seconds(0.1)) }
            check(model.exportStatus?.finished == true && model.exportStatus?.error == nil, "the camera move exports", model.exportStatus?.error)
            let size = (try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int) ?? 0
            check(size > 20_000, "the video has the frames", "\(size / 1024) KB")
            finish()
        }
    }

    @MainActor private static func findViewer3D(in view: NSView?) -> ViewerMTKView? {
        guard let view else { return nil }
        if let v = view as? ViewerMTKView { return v }
        for sub in view.subviews { if let v = findViewer3D(in: sub) { return v } }
        return nil
    }
}
