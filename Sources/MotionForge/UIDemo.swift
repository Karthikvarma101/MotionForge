import AppKit
import MFRender

/// Scripted end-to-end check of the real editor UI, used by `scripts/ui-demo.sh`.
///
/// Mouse events are synthesised *inside* the app (sent to its own window, so the user's cursor
/// is never moved) and go through the same viewer hit-testing and drag code as real clicks.
/// Inspector-style edits use the same model calls as the inspector controls. After every step
/// the window is captured with `screencapture -l` and the engine's values are logged.
@MainActor
enum UIDemo {
    static func run(model: EditorModel, outputDirectory: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log: [[String: Any]] = []
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let viewer = findViewer(in: window.contentView) else {
                print("ui-demo: no window"); exit(4)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try? await Task.sleep(for: .seconds(1.0))

            @MainActor func record(_ name: String) async {
                try? await Task.sleep(for: .seconds(0.7))
                let png = out.appendingPathComponent("\(name).png").path
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", png]
                try? p.run()
                p.waitUntilExit()
                try? model.engine.writePNG(atTime: model.time.time, scale: 0.5, transparent: false,
                                           toPath: out.appendingPathComponent("\(name)-render.png").path)
                var entry: [String: Any] = ["step": name, "time": model.time.time,
                                            "selection": model.selectedLayer?.name ?? "none"]
                if let s = model.selection {
                    let pos = model.engine.value(of: .position, layer: s, time: model.time.time)
                    let scl = model.engine.value(of: .scale, layer: s, time: model.time.time)
                    let op = model.engine.value(of: .opacity, layer: s, time: model.time.time)
                    entry["position"] = [pos.x, pos.y]
                    entry["scale"] = [scl.x, scl.y]
                    entry["opacity"] = op.x
                    entry["hitAtPosition"] = model.engine.hitTest(at: CGPoint(x: pos.x, y: pos.y), time: model.time.time) == s
                }
                entry["undo"] = model.engine.canUndo ? model.engine.undoLabel : ""
                log.append(entry)
                print("ui-demo step \(name): \(entry)")
            }

            // 1. Launch state, playhead at 1 s so every starter layer is on screen.
            model.time.time = 1.0
            await record("01-launch")

            // 2. Click the star in the viewer (composition centre) -> selects it.
            let geometry = viewer.coordinator!.geometry
            let star = geometry.toView(CGPoint(x: 960, y: 540))
            click(viewer, at: star)
            await record("02-click-select")

            // 3. Drag it +260 px right, -140 px up in composition space.
            let target = geometry.toView(CGPoint(x: 960 + 260, y: 540 - 140))
            drag(viewer, from: star, to: target)
            await record("03-drag-position")

            // 4. Scale 160% and 5. opacity 40%, through the inspector's edit path.
            if let s = model.selection {
                model.edit { _ = $0.setPropertyValue(MFValue(x: 160, y: 160, z: 0, w: 0), prop: .scale, layer: s, time: model.time.time) }
                await record("04-scale-160")
                model.edit { _ = $0.setPropertyValue(MFValue(x: 40, y: 0, z: 0, w: 0), prop: .opacity, layer: s, time: model.time.time) }
                await record("05-opacity-40")

                // Autosave the unsaved edits and read the recovery file back with a second engine.
                model.autosaveIfNeeded()
                var recovered = -1.0
                if let probe = try? MFEngine(device: model.engine.device),
                   (try? probe.recover(fromPath: RecoveryStore.autosaveURL.path)) != nil,
                   let star = probe.layers().first(where: { $0.name == "Star" }) {
                    recovered = probe.value(of: .opacity, layer: star.layerID, time: model.time.time).x
                }
                let pending = RecoveryStore.pendingRecovery() != nil  // what a relaunch after a crash would see
                log.append(["step": "autosave", "recoveredOpacity": recovered, "recoveryOfferedAfterCrash": pending])
                print("ui-demo autosave: recovered opacity \(recovered), recovery offered after crash: \(pending)")
            }

            // 6. Undo all three edits.
            model.undo(); model.undo(); model.undo()
            await record("06-undo-x3")

            // 7. Expand the layer in the timeline to show its keyframed properties.
            if let s = model.selection { model.expandedLayers.insert(s) }
            await record("07-timeline-expanded")

            // Phase 3: apply an effect from the catalogue, add a mask, set a track matte.
            if let card = model.layers.first(where: { $0.name == "Card" }) {
                model.selection = card.layerID
                model.applyEffect(.gaussianBlur)
                if let blur = model.selectedLayer?.effects.last {
                    model.edit { _ = $0.setRefValue(MFValue(x: 12, y: 0, z: 0, w: 0), ref: blur.params[0].ref, layer: card.layerID, time: model.time.time) }
                }
                await record("08-effect-blur-on-card")
            }
            if let star = model.layers.first(where: { $0.name == "Star" }) {
                model.selection = star.layerID
                model.addMask(.ellipse)
                await record("09-ellipse-mask-on-star")
            }
            if let ring = model.layers.first(where: { $0.name == "Ring" }) {
                model.addShape(.rectangle)
                if let fill = model.selection {
                    model.edit { e in
                        _ = e.setPropertyValue(MFValue(x: 1920, y: 1080, z: 0, w: 0), prop: .size, layer: fill, time: 0)
                        _ = e.setPropertyValue(MFValue(x: 1.0, y: 0.55, z: 0.15, w: 1), prop: .fillColor, layer: fill, time: 0)
                        _ = e.setLayer(fill, name: "Orange (matted by Ring)")
                        _ = e.setLayer(fill, matte: ring.layerID, mode: .alpha)
                    }
                }
                await record("10-track-matte")
                log.append(["step": "phase3-structure", "offscreenLayersLastFrame": model.engine.stats().offscreenLayers,
                            "ringHiddenByMatte": !(model.layers.first { $0.layerID == ring.layerID }?.visible ?? true)])
            }

            // 8. Real-time playback for 4 s: measured presented fps and dropped frames.
            model.time.time = 0
            model.time.isPlaying = true
            try? await Task.sleep(for: .seconds(4))
            let fps = model.perf.presentedFPS, dropped = model.perf.droppedFrames
            let cachedDuringPlayback = model.engine.cachedFrames(forQualityDivisor: model.perf.currentDivisor).count
            await record("11-playing")
            model.time.isPlaying = false
            let stats = model.engine.stats()
            log.append(["step": "playback", "presentedFPS": fps, "droppedFrames": dropped,
                        "cachedFramesOfCurrentState": cachedDuringPlayback, "previewDivisor": model.perf.currentDivisor,
                        "cacheAdmitted": stats.cacheAdmitted, "cacheSkippedCheap": stats.cacheSkippedCheap,
                        "autoQualityNote": model.perf.autoQualityNote ?? "",
                        "compFPS": model.comp.fps, "gpuMsLast": stats.lastGPUMs,
                        "cacheFrames": stats.cacheFrames, "cacheMB": Double(stats.cacheBytes) / 1_048_576,
                        "gpuAllocatedMB": Double(stats.gpuAllocatedBytes) / 1_048_576])
            print("ui-demo playback: \(fps) fps presented (comp \(model.comp.fps)), \(dropped) dropped, \(cachedDuringPlayback) frames cached, cache \(stats.cacheFrames) frames / \(Int(Double(stats.cacheBytes) / 1_048_576)) MB")

            // 9. Save, reopen and compare the serialized document.
            let project = out.appendingPathComponent("ui-demo.mfproj")
            let before = model.engine.serializedProjectRelative(to: out.path)
            try? model.engine.saveProject(toPath: project.path)
            model.open(url: project)
            let after = model.engine.serializedProjectRelative(to: out.path)
            log.append(["step": "save-reopen", "identical": before == after])
            print("ui-demo save/reopen identical: \(before == after)")

            // 10. Stress: 4K comp with 24 animated, heavily blurred full-frame layers. Auto quality
            // should lower the preview resolution during playback and say why.
            model.engine.newProject(withWidth: 3840, height: 2160, fps: 30, duration: 4)
            for i in 0..<24 {
                let l = model.engine.addShapeLayer(i % 2 == 0 ? .ellipse : .rectangle)
                _ = model.engine.setPropertyValue(MFValue(x: 3000, y: 1800, z: 0, w: 0), prop: .size, layer: l, time: 0)
                _ = model.engine.setPropertyValue(MFValue(x: Double(i) / 24, y: 0.5, z: 1 - Double(i) / 24, w: 1), prop: .fillColor, layer: l, time: 0)
                _ = model.engine.setPropertyValue(MFValue(x: 30, y: 0, z: 0, w: 0), prop: .opacity, layer: l, time: 0)
                _ = model.engine.set(animated: true, prop: .rotation, layer: l, time: 0)
                _ = model.engine.setPropertyValue(MFValue(x: Double(90 + i * 10), y: 0, z: 0, w: 0), prop: .rotation, layer: l, time: 3.9)
                let fx = model.engine.add(.gaussianBlur, layer: l)
                _ = model.engine.setRefValue(MFValue(x: 120, y: 0, z: 0, w: 0), ref: MFPropRef(owner: .effect, ownerID: fx, index: 0), layer: l, time: 0)
            }
            model.engine.markCleanForNewDocument()
            model.refresh()
            model.quality = .auto
            let backing = Double(window.backingScaleFactor)
            model.zoom = 1.0 / backing  // 100%: one composition pixel per screen pixel, so Auto starts at full 4K
            model.pan = .zero
            model.time.time = 0
            try? await Task.sleep(for: .seconds(0.5))
            model.time.isPlaying = true
            try? await Task.sleep(for: .seconds(5))
            let stressNote = model.perf.autoQualityNote ?? "", stressDivisor = model.perf.currentDivisor
            let stressFPS = model.perf.presentedFPS, stressDropped = model.perf.droppedFrames
            await record("12-adaptive-resolution")
            model.time.isPlaying = false
            log.append(["step": "adaptive-resolution", "note": stressNote, "previewDivisor": stressDivisor,
                        "presentedFPS": stressFPS, "droppedFrames": stressDropped,
                        "gpuMsLast": model.engine.stats().lastGPUMs])
            print("ui-demo adaptive: divisor \(stressDivisor), \(stressFPS) fps, \(stressDropped) dropped, note: \(stressNote)")

            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("ui-demo.json"))
            }
            model.applicationWillTerminate()
            exit(0)
        }
    }

    private static func findViewer(in view: NSView?) -> ViewerMTKView? {
        guard let view else { return nil }
        if let v = view as? ViewerMTKView { return v }
        for sub in view.subviews { if let v = findViewer(in: sub) { return v } }
        return nil
    }

    private static func event(_ type: NSEvent.EventType, _ view: NSView, _ p: CGPoint) -> NSEvent {
        let w = view.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private static func click(_ view: NSView, at p: CGPoint) {
        view.window?.sendEvent(event(.leftMouseDown, view, p))
        view.window?.sendEvent(event(.leftMouseUp, view, p))
    }

    private static func drag(_ view: NSView, from a: CGPoint, to b: CGPoint) {
        view.window?.sendEvent(event(.leftMouseDown, view, a))
        for i in 1...12 {
            let t = Double(i) / 12
            view.window?.sendEvent(event(.leftMouseDragged, view, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        view.window?.sendEvent(event(.leftMouseUp, view, b))
    }
}
