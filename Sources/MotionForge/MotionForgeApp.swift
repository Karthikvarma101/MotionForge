import AppKit
import MFRender
import SwiftUI

@main
struct MotionForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("MotionForge", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.model = model
                    DispatchQueue.main.async { model.offerRecoveryIfNeeded() }
                }
        }
        .defaultSize(width: 1560, height: 940)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Headless self-check used by scripts/verify.sh: launch, render a frame, quit.
        if let out = ProcessInfo.processInfo.environment["MOTIONFORGE_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.snapshotAndQuit(out) } }
        }
        // Scripted end-to-end UI check (scripts/ui-demo.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.run(model: model, outputDirectory: dir) } }
            }
        }
        // Open a project at launch (scripts, or launching the binary directly).
        if let path = ProcessInfo.processInfo.environment["MOTIONFORGE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let model = self.model else { return }
                    model.open(url: URL(fileURLWithPath: path))
                    // Composition navigation and timeline-gesture check (scripts/ui-demo-nav.sh).
                    if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_NAV"] {
                        UIDemo.runNavigation(model: model, outputDirectory: dir)
                    }
                }
            }
        }
    }

    @MainActor private func snapshotAndQuit(_ path: String) {
        guard let model else { exit(3) }
        do {
            try model.engine.writePNG(atTime: 1.0, scale: 0.5, transparent: false, toPath: path)
            print("snapshot written: \(path)")
        } catch {
            print("snapshot failed: \(error.localizedDescription)")
        }
        model.applicationWillTerminate()
        exit(0)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let model, let url = urls.first(where: { $0.pathExtension == "mfproj" }) else { return }
            if model.confirmDiscardChanges() { model.open(url: url) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if let model, model.exporter != nil {
                let alert = NSAlert()
                alert.messageText = "An export is still running."
                alert.informativeText = "Quitting stops it and deletes the unfinished file."
                alert.addButton(withTitle: "Keep Exporting")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
                model.cancelExport()
            }
            return (model?.confirmDiscardChanges() ?? true) ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.applicationWillTerminate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                LeftPanel(model: model)
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 380)
                VSplitView {
                    Group {
                        if model.workspace == .viewer {
                            ViewerView(model: model, time: model.time, perf: model.perf)
                        } else {
                            NodeGraphView(model: model)
                        }
                    }
                    .frame(minHeight: 260, idealHeight: 560)
                    TimelineView(model: model, time: model.time, viewport: model.viewport)
                        .frame(minHeight: 170, idealHeight: 300)
                }
                .frame(minWidth: 560)
                InspectorView(model: model, time: model.time)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
            }
            StatusBar(model: model, perf: model.perf, time: model.time)
        }
        .navigationTitle(model.displayName + (model.engine.dirty ? " — Edited" : ""))
        .toolbar { EditorToolbar(model: model) }
        .sheet(isPresented: $model.showCompSettings) { CompSettingsSheet(model: model) }
        .sheet(isPresented: $model.showExportSheet) { ExportSheet(model: model) }
        .alert("MotionForge", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @ObservedObject var model: EditorModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.addShape(.rectangle) } label: { Label("Rectangle", systemImage: "rectangle") }
                .help("New rectangle layer")
            Button { model.addShape(.ellipse) } label: { Label("Ellipse", systemImage: "circle") }
                .help("New ellipse layer")
            Button { model.addShape(.polygon) } label: { Label("Polygon", systemImage: "hexagon") }
                .help("New polygon layer")
            Button { model.addShape(.star) } label: { Label("Star", systemImage: "star") }
                .help("New star layer")
            Button { model.addNull() } label: { Label("Null", systemImage: "square.dashed") }
                .help("New null (controller) layer for parenting")
            Button { model.addText() } label: { Label("Text", systemImage: "textformat") }
                .help("New text layer")
            Toggle(isOn: Binding(get: { model.tool == .pen }, set: { model.tool = $0 ? .pen : .select })) {
                Label("Pen", systemImage: "pencil.and.outline")
            }
            .help("Pen tool (P): click for corners, drag for curves, click the first point to close, Return for an open line. V returns to selection.")
            if model.tool == .pen {
                Picker("", selection: $model.penDrawsMask) {
                    Text("New Shape").tag(false)
                    Text("Mask on Layer").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Draw a new shape layer, or a bezier mask on the selected layer")
            }
            Button { model.presentImportPanel() } label: { Label("Import", systemImage: "photo.badge.plus") }
                .help("Import images as layers")
        }
        ToolbarItem(placement: .principal) {
            Picker("", selection: $model.workspace) {
                Label("Viewer", systemImage: "play.rectangle").tag(Workspace.viewer)
                Label("Nodes", systemImage: "point.3.connected.trianglepath.dotted").tag(Workspace.nodes)
            }
            .pickerStyle(.segmented)
            .help("Viewer or node workspace")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.engine.canUndo)
                .help(model.engine.canUndo ? "Undo \(model.engine.undoLabel)" : "Nothing to undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.engine.canRedo)
                .help(model.engine.canRedo ? "Redo \(model.engine.redoLabel)" : "Nothing to redo")
            Button { model.showCompSettings = true } label: { Label("Composition", systemImage: "aspectratio") }
                .help("Composition settings (size, aspect ratio, frame rate)")
            Button { model.showExportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.exporter != nil)
                .help(model.exporter != nil ? "An export is running (see the status bar)" : "Export the composition as a video or image sequence (⌘M)")
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: EditorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }.keyboardShortcut("n")
            Button("Open Project…") { model.openProjectPanel() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }.keyboardShortcut("s")
            Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Import Media…") { model.presentImportPanel() }.keyboardShortcut("i")
            Button("Export Video…") { model.showExportSheet = true }.keyboardShortcut("m").disabled(model.exporter != nil)
            Button("Export Frame as PNG…") { model.exportFramePanel() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.engine.canUndo ? "Undo \(model.engine.undoLabel)" : "Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.engine.canUndo)
            Button(model.engine.canRedo ? "Redo \(model.engine.redoLabel)" : "Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.engine.canRedo)
        }
        CommandMenu("Layer") {
            Button("New Rectangle") { model.addShape(.rectangle) }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("New Ellipse") { model.addShape(.ellipse) }.keyboardShortcut("e", modifiers: [.command, .option])
            Button("New Polygon") { model.addShape(.polygon) }
            Button("New Star") { model.addShape(.star) }
            Button("New Null") { model.addNull() }.keyboardShortcut("y", modifiers: [.command, .option, .shift])
            Button("New Text") { model.addText() }.keyboardShortcut("t", modifiers: [.command, .option, .shift])
            Button("Pen Tool (P)") { model.tool = .pen }
            Divider()
            Button("Duplicate") { model.duplicateSelection() }.keyboardShortcut("d").disabled(model.selection == nil)
            Button("Delete") { model.deleteSelection() }.disabled(model.selection == nil && model.selectedKeyframes.isEmpty)
            Divider()
            Button("Copy (⌘C)") { model.copySelection() }.disabled(model.selection == nil && model.selectedKeyframes.isEmpty)
            Button("Paste (⌘V)") { model.paste() }
            Button("Select All Layers (⌘A)") { model.selectAll() }
            Divider()
            Button("Bring Forward") { model.moveSelection(by: -1) }.keyboardShortcut("]").disabled(model.selection == nil)
            Button("Send Backward") { model.moveSelection(by: 1) }.keyboardShortcut("[").disabled(model.selection == nil)
            Divider()
            Button("New Rectangle Mask") { model.addMask(.rectangle) }.disabled(model.selection == nil)
            Button("New Ellipse Mask") { model.addMask(.ellipse) }.disabled(model.selection == nil)
            Divider()
            Button("Save Animation Preset…") { model.saveSelectionAsPreset() }.disabled(model.selection == nil)
        }
        CommandMenu("Effect") {
            ForEach(MFEngine.effectCatalog(), id: \.type.rawValue) { e in
                Button(e.name) { model.applyEffect(e.type) }
            }
        }
        CommandMenu("Composition") {
            Button("Composition Settings…") { model.showCompSettings = true }.keyboardShortcut("k")
            Divider()
            Picker("Preview Quality", selection: $model.quality) {
                ForEach(PreviewQuality.allCases) { q in Text(q.label).tag(q) }
            }
            Toggle("Transparency Grid", isOn: $model.checkerboard)
            Divider()
            Picker("Frame Cache", selection: $model.cachePolicy) {
                Text("Smart (cache frames that are slow to redraw)").tag(MFCachePolicy.smart)
                Text("Cache Every Frame").tag(MFCachePolicy.all)
                Text("Off").tag(MFCachePolicy.off)
            }
            Picker("Frame Cache Size", selection: $model.cacheBudgetMB) {
                ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { mb in
                    Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                }
                if ![512, 1024, 2048, 4096, 8192].contains(model.cacheBudgetMB) {
                    Text("\(model.cacheBudgetMB) MB (default)").tag(model.cacheBudgetMB)
                }
            }
            Button("Purge Frame Cache") { model.engine.purgeFrameCache() }
        }
        CommandMenu("Playback") {
            Button(model.time.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
            Button("Go to Start") { model.goToStart() }
            Button("Go to End") { model.goToEnd() }
            Button("Next Frame") { model.stepFrames(1) }.keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous Frame") { model.stepFrames(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command])
            Text("Space plays/pauses · ←/→ nudge or step · Home/End")
        }
    }
}
