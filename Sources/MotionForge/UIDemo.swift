import AppKit
import MFRender
import SwiftUI

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
            model.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.motionforge.uidemo"))  // never the user's clipboard
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

            // Phase 2: multi-selection, copy/paste, motion paths.
            if let star = model.layers.first(where: { $0.name == "Star" }), let card = model.layers.first(where: { $0.name == "Card" }) {
                // The full-frame matted layer from step 10 is on top and would catch every click.
                let orange = model.layers.first { $0.name.hasPrefix("Orange") }?.layerID
                if let orange { model.edit { _ = $0.setLayer(orange, visible: false) } }
                let t = model.time.time
                let g = viewer.coordinator!.geometry
                let sp = model.engine.value(of: .position, layer: star.layerID, time: t)
                let cp = model.engine.value(of: .position, layer: card.layerID, time: t)
                click(viewer, at: g.toView(CGPoint(x: sp.x, y: sp.y)))                          // select star
                click(viewer, at: g.toView(CGPoint(x: cp.x + 200, y: cp.y)), flags: .command)   // ⌘-click adds card
                let selectedBoth = model.selectedLayers == [star.layerID, card.layerID]
                drag(viewer, from: g.toView(CGPoint(x: sp.x, y: sp.y)), to: g.toView(CGPoint(x: sp.x - 120, y: sp.y + 60)))
                let sp2 = model.engine.value(of: .position, layer: star.layerID, time: t)
                let cp2 = model.engine.value(of: .position, layer: card.layerID, time: t)
                log.append(["step": "multi-select-drag", "bothSelected": selectedBoth,
                            "starMoved": [sp2.x - sp.x, sp2.y - sp.y], "cardMoved": [cp2.x - cp.x, cp2.y - cp.y],
                            "undo": model.engine.undoLabel])
                await record("13-multi-select-drag")
                model.undo()

                // Copy both layers and paste them back (private pasteboard).
                let before = model.layers.count
                model.copySelection()
                model.paste()
                log.append(["step": "copy-paste-layers", "layersBefore": before, "layersAfter": model.layers.count,
                            "pastedSelected": model.selectedLayers.count, "names": model.layers.prefix(2).map(\.name)])
                await record("14-copy-paste-layers")
                model.undo()

                // Motion path: a third Card position key makes a smooth (auto-bezier) curve.
                model.time.time = 2
                model.edit { _ = $0.setPropertyValue(MFValue(x: 1500, y: 650, z: 0, w: 0), prop: .position, layer: card.layerID, time: 2) }
                model.time.time = 1
                model.selectLayer(card.layerID, mode: .replace)
                await record("15-motion-path-auto")
                // Drag the middle key's out-handle: it becomes a bezier key with mirrored handles.
                if let mp = model.engine.motionPath(layer: card.layerID, time: 1), mp.keys.count == 3 {
                    let k = mp.keys[1]
                    let g2 = viewer.coordinator!.geometry
                    let from = g2.toView(k.outHandle)
                    drag(viewer, from: from, to: CGPoint(x: from.x + 60, y: from.y + 90))
                    let info = model.engine.layer(withID: card.layerID)!.keyframes(for: .layer(.position))[1]
                    let cross = info.tangentIn.x * info.tangentOut.y - info.tangentIn.y * info.tangentOut.x
                    let dot = info.tangentIn.x * info.tangentOut.x + info.tangentIn.y * info.tangentOut.y
                    log.append(["step": "motion-path-handle", "spatial": info.spatial.rawValue, "handlesOpposite": abs(cross) < 1e-6 && dot < 0,
                                "tangentOut": [info.tangentOut.x, info.tangentOut.y], "undo": model.engine.undoLabel])
                    await record("16-motion-path-handle-dragged")
                }

                // Copy Card's position keys and paste them onto Star at 3 s.
                let keys = model.engine.layer(withID: card.layerID)!.keyframes(for: .layer(.position))
                model.selectedKeyframes = Set(keys.map { KeyframeRef(layer: card.layerID, ref: .layer(.position), index: $0.index) })
                model.copySelection()
                model.selectLayer(star.layerID, mode: .replace)
                model.time.time = 3
                model.paste()
                let starKeys = model.engine.layer(withID: star.layerID)!.keyframes(for: .layer(.position)).map(\.time)
                log.append(["step": "copy-paste-keyframes", "copied": keys.map(\.time), "starPositionKeyTimes": starKeys])
                print("ui-demo phase2: \(log.suffix(4))")
                model.expandedLayers.insert(star.layerID)
                model.time.time = 3.5
                await record("17-pasted-keyframes")
                if let orange { model.edit { _ = $0.setLayer(orange, visible: true) } }
            }

            // Phase 4: text + preset, pen tool, graph editor, node workspace.
            do {
                model.time.time = 0
                model.addText()
                if let t = model.selectedLayer {
                    model.edit { _ = $0.setLayer(t.layerID, text: "MotionForge", font: "AvenirNext-Heavy", align: .center) }
                    model.edit { _ = $0.setPropertyValue(MFValue(x: 960, y: 230, z: 0, w: 0), prop: .position, layer: t.layerID, time: 0) }
                    if let tw = MFEngine.builtInPresets().first(where: { $0.name == "Typewriter" }) { model.applyPreset(tw) }
                    model.time.time = 0.9
                    let info = model.engine.layer(withID: t.layerID)!
                    log.append(["step": "text-typewriter", "animators": info.animators.count,
                                "startKeys": info.animators.first?.params.first?.keyframes.count ?? 0])
                    await record("18-text-typewriter")
                }
                // Pen: two corner clicks, two dragged (smooth) points, then click the first point to close.
                model.selection = nil
                model.tool = .pen
                let g = viewer.coordinator!.geometry
                let pts = [CGPoint(x: 300, y: 300), CGPoint(x: 700, y: 260), CGPoint(x: 760, y: 720), CGPoint(x: 330, y: 760)]
                let before = model.layers.count
                click(viewer, at: g.toView(pts[0]))
                click(viewer, at: g.toView(pts[1]))
                drag(viewer, from: g.toView(pts[2]), to: g.toView(CGPoint(x: 860, y: 820)))
                drag(viewer, from: g.toView(pts[3]), to: g.toView(CGPoint(x: 230, y: 700)))
                click(viewer, at: g.toView(pts[0]))
                let made = model.layers.count == before + 1 ? model.layers.first : nil
                log.append(["step": "pen-shape", "layerAdded": made != nil, "isPath": made?.shape == .path,
                            "vertices": made?.pathVertices.count ?? 0, "closed": made?.pathClosed ?? false,
                            "smoothPoints": made?.pathVertices.filter { hypot($0.outTangent.x, $0.outTangent.y) > 1 }.count ?? 0])
                model.tool = .select
                if let made { model.selectLayer(made.layerID, mode: .replace) }
                await record("19-pen-shape")

                // Graph editor on the Card's position keys.
                if let card = model.layers.first(where: { $0.name == "Card" }) {
                    model.selectedKeyframes = Set(card.keyframes(for: .layer(.position)).map { KeyframeRef(layer: card.layerID, ref: .layer(.position), index: $0.index) })
                    model.selection = card.layerID
                    model.showGraphEditor = true
                    await record("20-graph-editor")
                    model.showGraphEditor = false
                }
                model.workspace = .nodes
                await record("21-node-workspace")
                model.workspace = .viewer
                try? await Task.sleep(for: .seconds(0.5))
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

    /// Composition tabs / breadcrumb and timeline zoom + scroll on a real nested project
    /// (`scripts/ui-demo-nav.sh`). Precomps are opened through the same call as double-clicking one;
    /// scroll events go through the app's own event dispatch, so the cursor never moves.
    static func runNavigation(model: EditorModel, outputDirectory: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log: [[String: Any]] = []
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                print("ui-demo-nav: no window"); exit(4)
            }
            window.makeKeyAndOrderFront(nil)
            let vp = model.viewport
            @MainActor func names(_ ids: [UInt64]) -> [String] { ids.map { id in model.compositions.first { $0.compID == id }?.name ?? "?" } }
            @MainActor func record(_ name: String, _ extra: [String: Any] = [:]) async {
                try? await Task.sleep(for: .seconds(0.8))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                let file = out.appendingPathComponent("\(name).png").path
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file]
                try? p.run()
                p.waitUntilExit()
                var e: [String: Any] = ["step": name, "comp": model.comp.name, "tabs": names(model.compTabs),
                                        "trail": names(model.compTrail), "time": model.time.time,
                                        "zoom": vp.zoom, "start": vp.start, "visible": vp.visible]
                e.merge(extra) { a, _ in a }
                log.append(e)
                print("ui-demo-nav \(name): \(e)")
            }

            model.time.time = 50  // inside the Mountain Pose scene
            await record("nav-01-master")

            // Down one level: the scene precomp under the playhead.
            let t = model.time.time
            if let scene = model.layers.first(where: { $0.kind == .precomp && $0.inPoint <= t && t < $0.outPoint && $0.name.hasPrefix("YB") }) {
                model.openComposition(scene.sourceCompID, fromLayer: scene)
                await record("nav-02-scene", ["expectedTime": t - scene.startTime])
            }
            // And again: the teacher's rig inside the scene.
            if let rig = model.layers.first(where: { $0.kind == .precomp && $0.name.contains("TEACHER") }) {
                model.openComposition(rig.sourceCompID, fromLayer: rig)
                await record("nav-03-rig")
            }

            // Timeline gestures over the track area: ⌥-scroll zooms around the pointer, a
            // horizontal trackpad swipe scrolls through time, plain vertical scrolling is left alone.
            if let gestures = findGestureView(in: window.contentView) {
                let p = CGPoint(x: gestures.trackOffset + 200, y: gestures.bounds.midY)
                let anchor = vp.start + Double(200 / vp.trackWidth) * vp.visible
                for _ in 0..<12 { scroll(gestures, at: p, dx: 0, dy: 20, flags: .option) }
                let anchorAfter = vp.start + Double(200 / vp.trackWidth) * vp.visible
                await record("nav-04-option-scroll-zoom", ["timeUnderPointerBefore": anchor, "timeUnderPointerAfter": anchorAfter])
                let before = vp.start
                for _ in 0..<10 { scroll(gestures, at: p, dx: -40, dy: 0) }
                await record("nav-05-swipe-scroll", ["startBefore": before])
                let zoomBefore = vp.zoom, startBefore = vp.start
                for _ in 0..<5 { scroll(gestures, at: p, dx: 0, dy: -30) }
                await record("nav-06-vertical-left-to-list", ["zoomUnchanged": vp.zoom == zoomBefore, "startUnchanged": vp.start == startBefore])
            } else {
                print("ui-demo-nav: no timeline gesture view")
            }

            // Breadcrumb: jump straight back to the master; its playhead and zoom come back.
            if let root = model.compTrail.first {
                model.openComposition(root)
                await record("nav-07-breadcrumb-to-master")
            }
            // Tabs: switch to the rig's tab, then close the scene's tab.
            if model.compTabs.count >= 3 {
                model.openComposition(model.compTabs[2])
                await record("nav-08-tab-switch")
                model.closeCompositionTab(model.compTabs[1])
                await record("nav-09-tab-closed")
            }

            // Export: the sheet, then a short background export through the same call the sheet's
            // Export button makes after the save panel (which needs a person to answer).
            // A window with a sheet attached can't be captured by id, so the sheet's view is shown in
            // a window of its own for the screenshot.
            let sheetWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 560),
                                       styleMask: [.titled], backing: .buffered, defer: false)
            sheetWindow.contentView = NSHostingView(rootView: ExportSheet(model: model).preferredColorScheme(.dark))
            sheetWindow.setContentSize(sheetWindow.contentView!.fittingSize)
            sheetWindow.orderFront(nil)
            try? await Task.sleep(for: .seconds(0.8))
            let cap = Process()
            cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            cap.arguments = ["-x", "-o", "-l", "\(sheetWindow.windowNumber)", out.appendingPathComponent("nav-10-export-sheet.png").path]
            try? cap.run()
            cap.waitUntilExit()
            sheetWindow.orderOut(nil)
            let settings = MFExportSettings()
            settings.format = .h264
            settings.scale = 0.5
            settings.startTime = 4
            settings.endTime = 10
            settings.bitsPerSecond = 10_000_000
            let movie = out.appendingPathComponent("export-test.mp4")
            model.startExport(settings, to: movie)
            try? await Task.sleep(for: .seconds(0.6))
            await record("nav-11-exporting", ["exportDone": model.exportStatus?.done ?? -1, "exportTotal": model.exportStatus?.total ?? -1])
            for _ in 0..<120 where model.exporter != nil { try? await Task.sleep(for: .seconds(0.25)) }
            let size = (try? FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? Int) ?? 0
            await record("nav-12-exported", ["exportFinished": model.exportStatus?.finished ?? false,
                                             "exportError": model.exportStatus?.error ?? "", "exportBytes": size,
                                             "exportSeconds": model.exportStatus?.elapsed ?? 0])

            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("ui-demo-nav.json"))
            }
            model.applicationWillTerminate()
            exit(0)
        }
    }

    private static func findGestureView(in view: NSView?) -> TimelineGestureView? {
        guard let view else { return nil }
        if let v = view as? TimelineGestureView { return v }
        for sub in view.subviews { if let v = findGestureView(in: sub) { return v } }
        return nil
    }

    /// A continuous (trackpad-style, pixel) scroll event at `p` in `view`, dispatched in-app.
    private static func scroll(_ view: NSView, at p: CGPoint, dx: Int32, dy: Int32, flags: NSEvent.ModifierFlags = []) {
        guard let window = view.window,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let screen = window.convertPoint(toScreen: view.convert(p, to: nil))
        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        var f: CGEventFlags = []
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.shift) { f.insert(.maskShift) }
        cg.flags = f
        if let e = NSEvent(cgEvent: cg) { NSApp.sendEvent(e) }
    }

    private static func findViewer(in view: NSView?) -> ViewerMTKView? {
        guard let view else { return nil }
        if let v = view as? ViewerMTKView { return v }
        for sub in view.subviews { if let v = findViewer(in: sub) { return v } }
        return nil
    }

    private static func event(_ type: NSEvent.EventType, _ view: NSView, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let w = view.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private static func click(_ view: NSView, at p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        view.window?.sendEvent(event(.leftMouseDown, view, p, flags))
        view.window?.sendEvent(event(.leftMouseUp, view, p, flags))
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
