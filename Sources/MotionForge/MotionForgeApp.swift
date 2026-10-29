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
                    DispatchQueue.main.async {
                        model.offerRecoveryIfNeeded()
                        appDelegate.openPending()  // files double-clicked to launch the app
                    }
                }
        }
        .defaultSize(width: 1560, height: 940)
        .commands { AppCommands(model: model) }
        Settings { PreferencesView(model: model).preferredColorScheme(.dark) }
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
        // Panels, Claude panel, bundles, auto save (scripts/ui-demo-features.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_FEATURES"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.runFeatures(model: model, outputDirectory: dir) } }
            }
        }
        // Finding and installing an update from a local fake release (scripts/ui-demo-update.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_UPDATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.runUpdate(model: model, outputDirectory: dir) } }
            }
        }
        // Footage, image formats, Roto Brush, hand rotoscoping and export (scripts/ui-demo-media.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_MEDIA"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.runMedia(model: model, outputDirectory: dir) } }
            }
        }
        // 3D layers, cameras, the Custom View and Orbit tool, and a 3D export (scripts/ui-demo-3d.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_3D"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.run3D(model: model, outputDirectory: dir) } }
            }
        }
        // After Effects shortcuts, tools and commands (scripts/ui-demo-shortcuts.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_SHORTCUTS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.runShortcuts(model: model, outputDirectory: dir) } }
            }
        }
        // Live collaboration against the real server, signed in (scripts/ui-demo-collab.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_COLLAB"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { if let model = self.model { UIDemo.runCollab(model: model, outputDirectory: dir) } }
            }
        }
        // Launch animation + Home window frames (scripts/ui-demo-home.sh).
        if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_HOME"] {
            UIDemo.runHome(outputDirectory: dir) { [weak self] in self?.model }
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
                    // Audio layers, playback sync, account card, export window (scripts/ui-demo-audio.sh).
                    if let dir = ProcessInfo.processInfo.environment["MOTIONFORGE_UIDEMO_AUDIO"] {
                        UIDemo.runAudio(model: model, outputDirectory: dir)
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

    @MainActor func openPending() {
        let urls = pendingOpen
        pendingOpen = []
        if !urls.isEmpty { application(NSApp, open: urls) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // At a cold launch the window (and the model) isn't up yet: open them once it is.
            guard let model else { pendingOpen.append(contentsOf: urls); return }
            if let bundle = urls.first(where: { $0.pathExtension == "mfbundle" }) {
                model.importBundle(bundle)
            } else if let url = urls.first(where: { $0.pathExtension == "mfproj" }), model.confirmDiscardChanges() {
                model.open(url: url)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if model?.updater.quittingForUpdate == true { return .terminateNow }  // already asked about unsaved work
            if let model, model.exporter != nil {
                let alert = NSAlert()
                alert.messageText = "An export is still running."
                alert.informativeText = "Quitting stops it and deletes the unfinished file."
                alert.addButton(withTitle: "Keep Exporting")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
                guard model.confirmDiscardChanges() else { return .terminateCancel }
                // The exporter deletes its unfinished file on its own queue: quit once it has.
                model.cancelExport(thenQuit: true)
                return .terminateLater
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
        ZStack {
            workspace
            if model.showHome {
                HomeView(model: model)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HSplitView {
                if model.showProjectPanel {
                    LeftPanel(model: model)
                        .frame(minWidth: 210, idealWidth: 250, maxWidth: 380)
                }
                VSplitView {
                    Group {
                        if model.workspace == .viewer {
                            ViewerView(model: model, time: model.time, perf: model.perf)
                        } else {
                            NodeGraphView(model: model)
                        }
                    }
                    .frame(minHeight: 260, idealHeight: 560)
                    if model.showTimeline {
                        TimelineView(model: model, time: model.time, viewport: model.viewport)
                            .frame(minHeight: 170, idealHeight: 300)
                    }
                }
                .frame(minWidth: 560)
                if model.showInspector {
                    InspectorView(model: model, time: model.time)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
                }
                if model.showClaudePanel {
                    ClaudePanel(model: model, chat: model.claudeChat)
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 520)
                }
            }
            if model.showStatusBar {
                StatusBar(model: model, perf: model.perf, time: model.time)
            }
        }
        .navigationTitle(model.showHome ? "MotionForge"
                         : model.collab.map { "\($0.project.name) — Shared" } ?? model.displayName + (model.engine.dirty ? " — Edited" : ""))
        .toolbar { EditorToolbar(model: model) }
        .sheet(isPresented: $model.showCompSettings) { CompSettingsSheet(model: model) }
        .sheet(isPresented: $model.showShortcuts) { KeyboardShortcutsView() }
        .sheet(isPresented: $model.showShareSheet) { ShareSheet(model: model, social: model.social, account: model.account) }
        .sheet(isPresented: $model.showFriends) { FriendsSheet(model: model, social: model.social) }
        .sheet(isPresented: $model.showPaywall) {
            // Subscribing from here carries on to the export it was opened for.
            PaywallSheet(account: model.account) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showExportWindow() }
            }
        }
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
        // Home keeps the title bar (window buttons, dragging) but none of the editing tools.
        if !model.showHome {
            editingTools
        }
    }

    @ToolbarContentBuilder private var editingTools: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showHome = true } label: { Label("Home", systemImage: "house") }
                .help("Home — recent projects (⇧⌘H)")
        }
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
            Button { model.presentImportPanel() } label: { Label("Import", systemImage: "photo.badge.plus") }
                .help("Import images or audio as layers (⌘I)")
        }
        ToolbarItem(placement: .navigation) {
            ToolPicker(model: model)
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
            PanelToggles(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help(model.canUndo ? model.undoTitle : "Nothing to undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help(model.canRedo ? model.redoTitle : "Nothing to redo")
            Button { model.showCompSettings = true } label: { Label("Composition", systemImage: "aspectratio") }
                .help("Composition settings (size, aspect ratio, frame rate)")
            Button { model.requestExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help(model.exporter != nil ? "Show the running export" : "Export the composition as a video or image sequence (⌘M)")
            CollabToolbarItem(model: model)
            AccountBadge(account: model.account, compact: true) { model.showPaywall = true }
        }
    }
}

/// Show / hide the panels around the viewer, like Xcode's sidebar and inspector buttons.
struct PanelToggles: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ControlGroup {
            Toggle(isOn: $model.showProjectPanel) { Label("Project Panel", systemImage: "sidebar.left") }
                .help("Show or hide the project panel (⌥⌘1)")
            Toggle(isOn: $model.showTimeline) { Label("Timeline", systemImage: "rectangle.bottomthird.inset.filled") }
                .help("Show or hide the timeline (⌥⌘2)")
            Toggle(isOn: $model.showInspector) { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector (⌥⌘3) · ⌥⌘0 hides every panel")
            Toggle(isOn: $model.showClaudePanel) { Label("Claude", systemImage: "sparkles") }
                .help("Ask Claude to edit this project (⇧⌘L)")
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: EditorModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.checkForUpdatesFromMenu() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Home") { model.showHome = true }.keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("New Project") { model.newProject() }.keyboardShortcut("n", modifiers: [.command, .option])
            // On Home there's no composition to add to, so ⌘N starts a project there.
            Button("New Composition") { if model.showHome { model.newProject() } else { model.newComposition() } }
                .keyboardShortcut("n")
            Button("Open Project…") { model.openProjectPanel() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }.keyboardShortcut("s")
            Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Toggle("Auto Save Every 2 Seconds", isOn: $model.autoSaveToFile)
            Divider()
            Button("Export Project Bundle…") { model.exportBundlePanel() }.disabled(model.bundleActivity != nil)
            Button("Import Project Bundle…") { model.importBundlePanel() }.disabled(model.bundleActivity != nil)
            Divider()
            Button("Import Media…") { model.presentImportPanel() }.keyboardShortcut("i")
            Button(model.exporter != nil ? "Show Export Progress" : "Export Video…") { model.requestExport() }.keyboardShortcut("m")
            Button("Export with Last Settings…") { model.exportWithLastSettings() }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("MotionForge Pro…") { model.showPaywall = true }
            Button("Export Frame as PNG…") { model.exportFramePanel() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle) { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button(model.redoTitle) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            Button("Step Backward") { model.undo() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!model.canUndo)
            Button("Step Forward") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(!model.canRedo)
        }
        CommandGroup(replacing: .sidebar) {
            Toggle("Project Panel", isOn: $model.showProjectPanel).keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("Timeline", isOn: $model.showTimeline).keyboardShortcut("2", modifiers: [.command, .option])
            Toggle("Inspector", isOn: $model.showInspector).keyboardShortcut("3", modifiers: [.command, .option])
            Toggle("Status Bar", isOn: $model.showStatusBar).keyboardShortcut("4", modifiers: [.command, .option])
            Toggle("Claude", isOn: $model.showClaudePanel).keyboardShortcut("l", modifiers: [.command, .shift])
            Button(model.anyPanelShown ? "Hide All Panels" : "Show Panels") { model.toggleFocusViewer() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Claude") {
            Button(model.showClaudePanel ? "Hide Claude Panel" : "Ask Claude…") { model.showClaudePanel.toggle() }
            Divider()
            Button("Connect Claude Desktop…") { model.connectClaudeDesktop() }
            Button("Copy Claude Code Command") { model.copyClaudeCodeCommand() }
        }
        CommandMenu("Layer") {
            Button("New Rectangle") { model.addShape(.rectangle) }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("New Ellipse") { model.addShape(.ellipse) }.keyboardShortcut("e", modifiers: [.command, .option])
            Button("New Polygon") { model.addShape(.polygon) }
            Button("New Star") { model.addShape(.star) }
            Button("New Null") { model.addNull() }.keyboardShortcut("y", modifiers: [.command, .option, .shift])
            Button("New Text") { model.addText() }.keyboardShortcut("t", modifiers: [.command, .option, .shift])
            Button("New Camera") { model.addCamera() }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button("3D Layer") { model.toggleThreeD() }.disabled(model.selectedLayers.isEmpty)
            Divider()
            Button("Duplicate") { model.duplicateSelection() }.keyboardShortcut("d").disabled(model.selection == nil)
            Button("Split Layer") { model.splitLayers() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.layers.isEmpty)
            Button("Pre-compose…") { model.precomposeSelection() }.keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedLayers.isEmpty)
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
            Menu("Show in Timeline") {
                Button("Position (P)") { model.revealProperties([.position], adding: false) }
                Button("Rotation (R)") { model.revealProperties([.rotation], adding: false) }
                Button("Scale (S)") { model.revealProperties([.scale], adding: false) }
                Button("Opacity (T)") { model.revealProperties([.opacity], adding: false) }
                Button("Anchor Point (A)") { model.revealProperties([.anchorPoint], adding: false) }
                Divider()
                Button("Animated Properties (U)") { model.propertyReveal = Dictionary(uniqueKeysWithValues: model.layers.map { ($0.layerID, PropertyReveal.animated) }) }
                Button("Modified Properties (UU)") { model.propertyReveal = Dictionary(uniqueKeysWithValues: model.layers.map { ($0.layerID, PropertyReveal.modified) }) }
                Divider()
                Button("Collapse All") { model.hideRevealedProperties() }
            }
            Divider()
            Button("Save Animation Preset…") { model.saveSelectionAsPreset() }.disabled(model.selection == nil)
        }
        CommandMenu("Tools") {
            ForEach(EditorTool.allCases, id: \.self) { t in
                if t == .type {
                    Button(t.name) { model.selectTool(t) }.keyboardShortcut("t")
                } else {
                    Button("\(t.name) (\(t.shortcut))") { model.selectTool(t) }
                }
            }
            Divider()
            Picker("Shape Tool Draws", selection: $model.shapeTool) {
                ForEach([MFShapeType.rectangle, .ellipse, .polygon, .star], id: \.self) { s in Text(s.toolName).tag(s) }
            }
        }
        CommandMenu("Effect") {
            ForEach(MFEngine.effectCatalog(), id: \.type.rawValue) { e in
                Button(e.name) { model.applyEffect(e.type) }
            }
        }
        CommandMenu("Composition") {
            Button("Composition Settings…") { model.showCompSettings = true }.keyboardShortcut("k")
            Divider()
            Button("Set Work Area Start (B)") { model.setWorkAreaStart() }
            Button("Set Work Area End (N)") { model.setWorkAreaEnd() }
            Button("Reset Work Area") { model.clearWorkArea() }.disabled(!model.comp.hasWorkArea)
            Button("Trim Comp to Work Area") { model.trimCompToWorkArea() }.keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(!model.comp.hasWorkArea)
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
            Button(model.time.isPlaying ? "Stop (Space)" : "Play (Space)") { model.togglePlayback() }
            Button(model.ramPreview ? "Stop RAM Preview (0)" : "RAM Preview (0)") { model.startRAMPreview() }
            Button("Go to Start (Home)") { model.goToStart() }
            Button("Go to End (End)") { model.goToEnd() }
            Button("Next Frame (Page Down)") { model.stepFrames(1) }.keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous Frame (Page Up)") { model.stepFrames(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command])
            Text("Playback loops over the work area (B / N) when there is one")
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { model.showShortcuts = true }.keyboardShortcut("/")
        }
    }
}
