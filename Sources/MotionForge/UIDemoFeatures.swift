import AppKit
import MFRender

/// Scripted check of the workspace features (scripts/ui-demo-features.sh): hiding panels, the Claude
/// panel, a project bundle exported and imported again, and auto save writing the file every 2 s.
/// Screenshots and `features.json` go to the output folder; the panel layout is put back afterwards.
extension UIDemo {
    @MainActor static func runFeatures(model: EditorModel, outputDirectory: String) {
        ignoresKeys = true
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log: [[String: Any]] = []
            var failures: [String] = []
            func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                print("ui-demo-features: no window"); exit(4)
            }
            window.makeKeyAndOrderFront(nil)
            @MainActor func capture(_ name: String) {
                if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
                }
            }
            @MainActor func record(_ name: String, _ extra: [String: Any] = [:]) async {
                try? await Task.sleep(for: .seconds(0.8))
                capture(name)
                var e: [String: Any] = ["step": name]
                e.merge(extra) { a, _ in a }
                log.append(e)
                print("ui-demo-features \(name): \(e)")
            }
            let saved = [model.showProjectPanel, model.showTimeline, model.showInspector, model.showStatusBar, model.showClaudePanel]
            try? await Task.sleep(for: .seconds(1.5))

            // Panels.
            model.showProjectPanel = true; model.showTimeline = true; model.showInspector = true; model.showStatusBar = true
            model.showClaudePanel = false
            await record("features-01-all-panels")
            model.toggleFocusViewer()
            check(!model.anyPanelShown, "focus viewer hides every panel")
            await record("features-02-focus-viewer", ["anyPanelShown": model.anyPanelShown])
            model.toggleFocusViewer()
            check(model.showProjectPanel && model.showTimeline && model.showInspector, "focus viewer restores the panels")
            model.showInspector = false
            model.showClaudePanel = true
            await record("features-03-claude-panel", ["inspector": model.showInspector, "claude": model.showClaudePanel])
            model.showInspector = true
            model.showClaudePanel = false

            // A project with an image, exported as a bundle and imported again.
            let png = out.appendingPathComponent("logo.png")
            let img = NSImage(size: NSSize(width: 256, height: 128), flipped: false) { r in
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 24, yRadius: 24).fill()
                return true
            }
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: png)
            }
            model.importMedia(urls: [png], addToComposition: true)
            let layersBefore = model.layers.count
            let bundle = out.appendingPathComponent("Feature Test.mfbundle")
            var exported: ProjectBundle.Exported?
            do { exported = try await ProjectBundle.export(engine: model.engine, to: bundle) } catch { failures.append("export: \(error.localizedDescription)") }
            check(exported?.mediaFiles == 1, "the bundle holds the image")
            try? FileManager.default.removeItem(at: png)  // the copy in the bundle must be enough
            let unpacked = out.appendingPathComponent("Imported \(Int(Date().timeIntervalSince1970))")
            var projectFile: URL?
            do { projectFile = try await ProjectBundle.unpack(bundle, into: unpacked) } catch { failures.append("import: \(error.localizedDescription)") }
            if let projectFile {
                model.engine.markCleanForNewDocument()  // no save prompt in a scripted run
                model.open(url: projectFile)
                RecentProjects.remove(projectFile.path)  // keep the person's Home list as it was
            }
            check(model.assets.count == 1 && model.assets.allSatisfy { !$0.missing }, "imported media is found")
            check(model.layers.count == layersBefore, "imported layers match")
            await record("features-04-bundle-imported", ["bundleBytes": (try? FileManager.default.attributesOfItem(atPath: bundle.path)[.size]) ?? 0,
                                                        "media": exported?.mediaFiles ?? -1, "layers": model.layers.count,
                                                        "missing": model.assets.filter(\.missing).map(\.name),
                                                        "project": projectFile?.lastPathComponent ?? ""])

            // Auto save: an edit lands in the file within a couple of seconds, without a save.
            if let file = projectFile {
                let before = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
                model.autoSaveToFile = true
                model.addShape(.star)
                check(model.engine.dirty, "an edit marks the project unsaved")
                try? await Task.sleep(for: .seconds(3.5))
                let after = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
                check(after > before, "auto save rewrote the file")
                check(!model.engine.dirty, "auto save marked it saved")
                var reopened = -1
                if let probe = try? MFEngine(device: model.engine.device), (try? probe.openProject(atPath: file.path)) != nil {
                    reopened = probe.layers().count
                }
                check(reopened == model.layers.count, "the saved file has the new layer")
                await record("features-05-autosaved", ["fileUpdated": after > before, "dirty": model.engine.dirty,
                                                        "layersInFile": reopened, "layers": model.layers.count])
            }

            if let projectFile { RecentProjects.remove(projectFile.path) }  // again, after auto save: Home stays as it was
            model.showProjectPanel = saved[0]; model.showTimeline = saved[1]; model.showInspector = saved[2]
            model.showStatusBar = saved[3]; model.showClaudePanel = saved[4]
            log.append(["failures": failures])
            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted]) {
                try? data.write(to: out.appendingPathComponent("features.json"))
            }
            print(failures.isEmpty ? "ui-demo-features: all checks passed" : "ui-demo-features: FAILED \(failures)")
            model.applicationWillTerminate()
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}
