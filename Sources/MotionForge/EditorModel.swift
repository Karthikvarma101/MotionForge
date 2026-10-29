import AppKit
import AVFoundation
import ImageIO
import Combine
import MFRender
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let motionForgeProject = UTType(exportedAs: "com.motionforge.project", conformingTo: .json)
}

/// Preview resolution. `.auto` follows the viewer zoom; the active choice is always shown in the
/// viewer so a reduced preview is never mistaken for final quality (exports always render full size).
enum PreviewQuality: Int, CaseIterable, Identifiable {
    case auto = 0, full = 1, half = 2, quarter = 4
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .full: return "Full"
        case .half: return "Half"
        case .quarter: return "Quarter"
        }
    }
}

/// Viewer tools, on After Effects' keys (see `EditorTool.key`).
enum EditorTool: CaseIterable { case select, hand, zoom, rotate, orbit, panBehind, pen, shape, type }
enum Workspace { case viewer, nodes }

struct KeyframeRef: Hashable {
    var layer: UInt64
    var ref: MFPropRef
    var index: Int
    var address: MFKeyAddress { MFKeyAddress(layer: layer, ref: ref, index: index) }
    init(layer: UInt64, ref: MFPropRef, index: Int) {
        self.layer = layer
        self.ref = ref
        self.index = index
    }
    init(_ a: MFKeyAddress) { self.init(layer: a.layerID, ref: a.ref, index: a.index) }
}

/// How a click changes the selection: replace it, toggle one item (⌘), or extend a range (⇧).
enum SelectMode {
    case replace, toggle, extend
    static var current: SelectMode {
        let f = NSEvent.modifierFlags
        return f.contains(.command) ? .toggle : f.contains(.shift) ? .extend : .replace
    }
}

/// Playhead state is kept apart from the document model so that playback only re-renders the
/// few views that show time, not the whole editor.
@MainActor
final class TimeModel: ObservableObject {
    @Published var time: Double = 0
    @Published var isPlaying = false
    @Published var loop = true
}

@MainActor
final class PerfModel: ObservableObject {
    @Published var presentedFPS = 0.0
    @Published var droppedFrames = 0
    @Published var evalMs = 0.0
    @Published var encodeMs = 0.0
    @Published var renderSize = CGSize.zero
    @Published var lastFrameIncomplete = false
    @Published var lastFrameCached = false
    @Published var stats: MFRenderStats?
    @Published var cachedFrames = IndexSet()
    var currentDivisor = 1                     // preview resolution the viewer last rendered at
    @Published var autoQualityNote: String?   // why Auto lowered the preview resolution, if it did
    @Published var ramPreviewFill: Double?    // RAM Preview's first pass: share of the work area rendered
}

@MainActor
final class EditorModel: ObservableObject {
    let engine: MFEngine
    let time = TimeModel()
    let perf = PerfModel()

    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var layers: [MFLayerInfo] = []
    @Published private(set) var comp: MFCompositionInfo
    @Published private(set) var assets: [MFAssetInfo] = []
    @Published private(set) var compositions: [MFCompositionInfo] = []
    /// Timeline tabs: every composition opened this session, in the order they were opened.
    @Published private(set) var compTabs: [UInt64] = []
    /// How the current composition was reached, outermost first (it is the last entry).
    @Published private(set) var compTrail: [UInt64] = []
    /// Playhead and timeline zoom per composition, restored when you come back to it.
    private var compMemory: [UInt64: (time: Double, zoom: Double, start: Double)] = [:]
    let viewport = TimelineViewport()
    /// The Home window (launch animation, recent projects) covers the workspace until a project is
    /// chosen. Scripted runs and file opens go straight to the workspace.
    @Published var showHome: Bool { didSet { if showHome { stopPlayback() } } }
    let skipLaunchAnimation: Bool
    /// Whether the workspace has been shown (Home then offers to go back to it).
    private(set) var hasOpenWork = false
    /// Google account and MotionForge Pro (exporting needs Pro).
    let account = AccountModel()
    let updater = Updater()
    let roto = RotoBrush()
    private(set) var isScriptedRun = false  // a check script drives this run (no update checks)
    /// The active composition's audio layers, played with the viewer.
    let audio = AudioPlayback()
    @Published var showPaywall = false
    /// Video export (see ExportView.swift).
    @Published var exportStatus: ExportStatus?
    var exporter: MFVideoExporter?
    var quitAfterExportStops = false
    /// The primary selected layer (shown in the inspector); `selectedLayers` holds all of them.
    @Published var selection: UInt64? {
        didSet {
            if let s = selection {
                if !selectedLayers.contains(s) { selectedLayers = [s] }
            } else if !selectedLayers.isEmpty {
                selectedLayers = []
            }
        }
    }
    @Published var selectedLayers: Set<UInt64> = [] { didSet { if selectedLayers != oldValue { collab?.trackPresence() } } }
    /// The live shared editing session, when this project is shared (Collab.swift).
    @Published var collab: CollabSession?
    @Published var showShareSheet = false
    @Published var showFriends = false
    lazy var social = SocialModel(account: account)
    @Published var selectedKeyframes: Set<KeyframeRef> = []
    @Published var expandedLayers: Set<UInt64> = []
    @Published private(set) var projectURL: URL?
    @Published var alertMessage: String?
    @Published var showCompSettings = false
    @Published var showShortcuts = false

    // Frame cache (persisted)
    @Published var cachePolicy: MFCachePolicy = .smart {
        didSet {
            engine.cachePolicy = cachePolicy
            UserDefaults.standard.set(cachePolicy.rawValue, forKey: "cachePolicy")
        }
    }
    @Published var cacheBudgetMB: Int = 0 {
        didSet {
            engine.cacheBudgetBytes = UInt64(cacheBudgetMB) << 20
            UserDefaults.standard.set(cacheBudgetMB, forKey: "cacheBudgetMB")
        }
    }

    // Tools
    @Published var tool: EditorTool = .select { didSet { if tool != .pen { penDraft = [] } } }
    @Published var penDraft: [MFPathVertex] = []   // composition space, while drawing
    @Published var penDrawsMask = false             // pen draws a mask on the selected layer
    @Published var shapeTool: MFShapeType = .rectangle  // what the shape tool (Q) draws; Q again picks the next
    @Published var shapeDraft: CGRect?                 // composition space, while the shape tool drags
    @Published var focusTextOf: UInt64?               // the inspector puts the cursor in this layer's text (Type tool)
    // The viewer's Custom View of the 3D scene (Orbit Camera tool, C); nil = through the active camera.
    @Published var customView: OrbitView? {
        didSet {
            if let v = customView { engine.setViewOrbit(yaw: v.yaw, pitch: v.pitch, distance: v.distance, pan: v.pan) } else { engine.clearViewOrbit() }
        }
    }
    // Timeline rows shown by a property key (P, R, S, T, A, U, UU), per layer. The layer's
    // disclosure arrow goes back to the usual rows.
    @Published var propertyReveal: [UInt64: PropertyReveal] = [:]
    var lastRevealKey: (key: String, at: CFTimeInterval)?
    // RAM Preview (0): renders every frame of the work area once, then plays it in real time.
    @Published var ramPreview = false
    var policyBeforeRAMPreview: MFCachePolicy?
    var lastExport: (settings: MFExportSettings, summary: String)?  // for Export with Last Settings (⌥⌘M)
    @Published var workspace: Workspace = .viewer { didSet { if workspace != oldValue { stopPlayback() } } }

    /// Only the viewer's render loop drives playback, so leaving it (Home, the node workspace) stops it.
    func stopPlayback() {
        guard time.isPlaying else { return }
        time.isPlaying = false
        audio.stop()
        endRAMPreview()
    }
    @Published var showGraphEditor = false
    @Published private(set) var userPresets: [MFPresetInfo] = []

    // Viewer
    @Published var quality: PreviewQuality = .auto
    @Published var checkerboard = false
    @Published var zoom: Double?  // nil = fit
    @Published var pan = CGSize.zero
    @Published var fitScale: Double = 1  // reported by the viewer
    var memoryPressureUntil: CFTimeInterval = 0  // Auto quality stays at half resolution until then

    // Workspace panels (View menu, toolbar). Remembered between launches.
    @Published var showProjectPanel = EditorModel.panelDefault("project") { didSet { savePanels() } }
    @Published var showTimeline = EditorModel.panelDefault("timeline") { didSet { savePanels() } }
    @Published var showInspector = EditorModel.panelDefault("inspector") { didSet { savePanels() } }
    @Published var showStatusBar = EditorModel.panelDefault("statusBar") { didSet { savePanels() } }
    private var panelsBeforeFocus: [Bool]?

    private static func panelDefault(_ name: String) -> Bool {
        UserDefaults.standard.object(forKey: "panel." + name) as? Bool ?? true
    }
    private func savePanels() {
        let d = UserDefaults.standard
        d.set(showProjectPanel, forKey: "panel.project")
        d.set(showTimeline, forKey: "panel.timeline")
        d.set(showInspector, forKey: "panel.inspector")
        d.set(showStatusBar, forKey: "panel.statusBar")
    }
    var anyPanelShown: Bool { showProjectPanel || showTimeline || showInspector || showStatusBar }

    /// Hides every panel around the viewer, or brings back the ones that were open.
    func toggleFocusViewer() {
        if anyPanelShown {
            panelsBeforeFocus = [showProjectPanel, showTimeline, showInspector, showStatusBar]
            showProjectPanel = false; showTimeline = false; showInspector = false; showStatusBar = false
        } else {
            let p = panelsBeforeFocus ?? [true, true, true, true]
            showProjectPanel = p[0]; showTimeline = p[1]; showInspector = p[2]; showStatusBar = p[3]
            panelsBeforeFocus = nil
        }
    }

    @Published var bundleActivity: String?  // "Exporting bundle…" while a bundle is written or unpacked
    private var autosaveTimer: Timer?
    private var lastAutosavedRevision: UInt64 = 0
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var keyMonitor: Any?
    private var coalesceKey: String?
    private var coalesceTimer: Timer?

    init() {
        do {
            engine = try MFEngine(device: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "MotionForge needs Metal"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
        comp = engine.composition
        let env = ProcessInfo.processInfo.environment
        let scripted = ["MOTIONFORGE_UIDEMO", "MOTIONFORGE_SNAPSHOT", "MOTIONFORGE_OPEN", "MOTIONFORGE_UIDEMO_FEATURES",
                        "MOTIONFORGE_UIDEMO_COLLAB", "MOTIONFORGE_UIDEMO_SHORTCUTS", "MOTIONFORGE_UIDEMO_MEDIA", "MOTIONFORGE_UIDEMO_3D"].contains { env[$0] != nil }
        showHome = !scripted
        isScriptedRun = scripted || env.keys.contains { $0.hasPrefix("MOTIONFORGE_UIDEMO") }
        skipLaunchAnimation = scripted || env["MOTIONFORGE_NO_SPLASH"] != nil
        RecentProjects.importSystemRecentsIfEmpty()
        let defaults = UserDefaults.standard
        cachePolicy = MFCachePolicy(rawValue: defaults.integer(forKey: "cachePolicy")) ?? .smart
        let savedBudget = defaults.integer(forKey: "cacheBudgetMB")
        cacheBudgetMB = savedBudget > 0 ? savedBudget : Int(engine.cacheBudgetBytes >> 20)
        engine.mediaDidLoad = { [weak self] _, error in
            guard let self else { return }
            if let error { self.alertMessage = error }
            self.refresh()
        }
        audio.playhead = { [weak self] in self?.time.time ?? 0 }
        seedStarterContent()
        reloadUserPresets()
        engine.markCleanForNewDocument()
        refresh()
        startAutosave()
        startMemoryPressureMonitoring()
        installKeyMonitor()
        // Scripted runs leave the bridge to the user's own editor unless given their own socket.
        if !scripted || env["MOTIONFORGE_CLAUDE_SOCKET"] != nil { startClaudeBridge() }
    }

    // MARK: - Claude

    lazy var claudeTools = ClaudeToolHost(model: self)
    lazy var claudeChat = ClaudeChat(editor: self)
    @Published var showClaudePanel = UserDefaults.standard.bool(forKey: "panel.claude") {
        didSet { UserDefaults.standard.set(showClaudePanel, forKey: "panel.claude") }
    }
    private var claudeBridge: ClaudeBridgeServer?

    func startClaudeBridge() {
        guard claudeBridge == nil else { return }
        let server = ClaudeBridgeServer(host: claudeTools)
        server.start()
        claudeBridge = server
    }

    // MARK: - Snapshot refresh

    func refresh() {
        defer { collab?.noteLocalEdit() }  // shared projects: send what changed
        revision = engine.revision
        layers = engine.layers()
        comp = engine.composition
        assets = engine.assets()
        compositions = engine.compositions
        audio.update(clips: engine.audioClips())
        syncCompNavigation()
        let ids = Set(layers.map(\.layerID))
        if !selectedLayers.isSubset(of: ids) { selectedLayers.formIntersection(ids) }
        if let s = selection, !ids.contains(s) { selection = selectedLayers.first }
        let validKeys = selectedKeyframes.filter { k in
            engine.layer(withID: k.layer).map { k.index < $0.keyframes(for: k.ref).count } ?? false
        }
        if validKeys.count != selectedKeyframes.count { selectedKeyframes = validKeys }
        // Only when it actually moves: every view that shows time re-renders on each assignment.
        let clamped = min(time.time, max(0, comp.duration - frameDuration))
        if clamped != time.time { time.time = clamped }
    }

    var frameDuration: Double { 1.0 / comp.fps }
    func snap(_ t: Double) -> Double {
        let f = (t * comp.fps).rounded()
        return min(max(0, f / comp.fps), max(0, comp.duration - frameDuration))
    }

    var selectedLayer: MFLayerInfo? { selection.flatMap { id in layers.first { $0.layerID == id } } }

    /// Selected layer ids in stacking order (top first).
    var selectedLayerIDs: [UInt64] { layers.map(\.layerID).filter { selectedLayers.contains($0) } }

    func selectLayer(_ id: UInt64, mode: SelectMode = .current) {
        switch mode {
        case .replace:
            selectedLayers = [id]
            selection = id
        case .toggle:
            if selectedLayers.contains(id) {
                selectedLayers.remove(id)
                selection = selection == id ? selectedLayerIDs.first : selection
            } else {
                selectedLayers.insert(id)
                selection = id
            }
        case .extend:
            let order = layers.map(\.layerID)
            guard let anchor = selection, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
                selectLayer(id, mode: .replace)
                return
            }
            selectedLayers.formUnion(order[min(a, b)...max(a, b)])
            selection = id
        }
    }

    func selectKeyframe(_ k: KeyframeRef, mode: SelectMode = .current) {
        switch mode {
        case .replace: selectedKeyframes = [k]
        case .toggle, .extend:
            if selectedKeyframes.contains(k) { selectedKeyframes.remove(k) } else { selectedKeyframes.insert(k) }
        }
        if selection != k.layer { selection = k.layer }
    }

    func clearSelection() {
        selection = nil
        selectedKeyframes = []
    }

    /// Runs an edit and refreshes the UI snapshot.
    func edit(_ body: (MFEngine) -> Void) {
        body(engine)
        refresh()
    }

    /// Groups rapid-fire edits (colour wells, steppers) into one undo step.
    func coalescedEdit(_ key: String, _ body: (MFEngine) -> Void) {
        if coalesceKey != key {
            if coalesceKey != nil { engine.endUndoGroup() }
            engine.beginUndoGroup(key)
            coalesceKey = key
        }
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCoalescedEdit() }
        }
        edit(body)
    }

    func closeCoalescedEdit() {
        guard coalesceKey != nil else { return }
        coalesceTimer?.invalidate()
        coalesceKey = nil
        engine.endUndoGroup()
    }

    // MARK: - Layers

    func addShape(_ shape: MFShapeType) {
        closeCoalescedEdit()
        var id: UInt64 = 0
        edit { id = $0.addShapeLayer(shape) }
        if id != 0 { selection = id }
    }

    func addNull() {
        var id: UInt64 = 0
        edit { id = $0.addNullLayer() }
        if id != 0 { selection = id }
    }

    // MARK: - Composition navigation

    /// Switches the viewer, timeline and inspector to another composition. With `fromLayer` (a
    /// precomp layer of the current composition showing it) the breadcrumb goes one level deeper
    /// and the playhead maps into the precomp's own time.
    func openComposition(_ id: UInt64, fromLayer layer: MFLayerInfo? = nil) {
        guard id != comp.compID, compositions.contains(where: { $0.compID == id }) else { return }
        closeCoalescedEdit()
        var mapped: Double?
        if let layer, layer.kind == .precomp, layer.sourceCompID == id {
            let t = time.time
            mapped = layer.timeRemapEnabled ? engine.value(of: .timeRemap, layer: layer.layerID, time: t).x : t - layer.startTime
        }
        compMemory[comp.compID] = (time.time, viewport.zoom, viewport.start)
        if let i = compTrail.firstIndex(of: id) {
            compTrail.removeSubrange((i + 1)...)        // back up the trail
        } else if mapped != nil {
            compTrail.append(id)                         // one level down
        } else {
            compTrail = pathToComposition(id)            // from a tab or the project panel
        }
        if !compTabs.contains(id) { compTabs.append(id) }
        clearSelection()
        selectedLayers = []
        time.isPlaying = false
        _ = engine.openComposition(id)
        refresh()
        let memory = compMemory[id]
        viewport.duration = comp.duration
        viewport.fps = comp.fps
        viewport.zoom = memory?.zoom ?? 1
        viewport.start = memory?.start ?? 0
        viewport.clamp()
        let newTime = min(max(0, mapped ?? memory?.time ?? 0), max(0, comp.duration - 1 / comp.fps))
        viewport.skipNextReveal = mapped == nil && newTime != time.time
        time.time = newTime
        if mapped != nil { viewport.reveal(newTime) }
    }

    /// Opens a precomp of the current composition (the first layer that shows `sourceID`).
    func openPrecomp(sourceID: UInt64) {
        openComposition(sourceID, fromLayer: layers.first { $0.kind == .precomp && $0.sourceCompID == sourceID })
    }

    func goToParentComposition() {
        guard compTrail.count > 1 else { return }
        openComposition(compTrail[compTrail.count - 2])
    }

    func closeCompositionTab(_ id: UInt64) {
        guard compTabs.count > 1, let i = compTabs.firstIndex(of: id) else { return }
        compTabs.remove(at: i)
        if id == comp.compID { openComposition(compTabs[min(i, compTabs.count - 1)]) }
    }

    /// Distinct compositions shown by precomp layers of the current one, top of the stack first.
    var precompsInCurrentComposition: [MFCompositionInfo] {
        var seen = Set<UInt64>()
        return layers.compactMap { l in
            guard l.kind == .precomp, seen.insert(l.sourceCompID).inserted else { return nil }
            return compositions.first { $0.compID == l.sourceCompID }
        }
    }

    var parentsOfCurrentComposition: [MFCompositionInfo] {
        compositions.filter { $0.precompSources.contains(NSNumber(value: comp.compID)) }
    }

    /// Outermost composition down to `id`, following the first parent at each level.
    private func pathToComposition(_ id: UInt64) -> [UInt64] {
        var path = [id]
        var current = id
        while path.count < 64,
              let parent = compositions.first(where: { $0.precompSources.contains(NSNumber(value: current)) && !path.contains($0.compID) }) {
            path.insert(parent.compID, at: 0)
            current = parent.compID
        }
        return path
    }

    /// Keeps tabs and trail valid after undo, open, new project or deleted compositions.
    private func syncCompNavigation() {
        let ids = Set(compositions.map(\.compID))
        compTabs.removeAll { !ids.contains($0) }
        compTrail.removeAll { !ids.contains($0) }
        let current = comp.compID
        if !compTabs.contains(current) { compTabs.append(current) }
        if compTrail.last != current { compTrail = pathToComposition(current) }
        viewport.duration = comp.duration
        viewport.fps = comp.fps
    }

    /// A different document: start again from its active composition.
    private func resetCompNavigation() {
        compTabs = [comp.compID]
        compTrail = pathToComposition(comp.compID)
        compMemory = [:]
        viewport.fit()
    }

    func addPrecompLayer(source: UInt64) {
        var id: UInt64 = 0
        edit { id = $0.addPrecompLayer(source: source) }
        if id != 0 { selection = id } else { alertMessage = "A composition can't contain itself." }
    }

    func newComposition() {
        var id: UInt64 = 0
        edit { id = $0.addComposition(name: "", width: comp.width, height: comp.height, fps: comp.fps, duration: comp.duration) }
        if id != 0 { openComposition(id) }
    }

    /// Export button / ⌘M: the export settings for Pro, the paywall otherwise.
    /// The export window (its progress while an export runs); the Pro sheet first if export isn't unlocked.
    func requestExport() {
        if exporter != nil || account.canExport { showExportWindow() } else { showPaywall = true }
    }

    func zoomTimeline(by factor: Double) {
        viewport.zoom(by: factor, anchorX: viewport.x(of: time.time))
    }

    func addImageLayer(asset: UInt64) {
        var id: UInt64 = 0
        edit { id = $0.addImageLayer(withAsset: asset) }
        if id != 0 { selection = id }
    }

    /// An image or audio layer for the asset, whichever it is.
    func addLayer(asset: UInt64) {
        guard assets.first(where: { $0.assetID == asset })?.isAudio == true else { return addImageLayer(asset: asset) }
        var id: UInt64 = 0
        edit { id = $0.addAudioLayer(withAsset: asset) }
        if id != 0 { selection = id }
    }

    func deleteSelection() {
        if !selectedKeyframes.isEmpty {
            let keys = selectedKeyframes.map(\.address)
            edit { _ = $0.removeKeyframes(keys) }
            selectedKeyframes = []
        } else if !selectedLayers.isEmpty {
            let ids = selectedLayerIDs.map { NSNumber(value: $0) }
            edit { _ = $0.removeLayers(ids) }
            selection = nil
        }
    }

    func duplicateSelection() {
        guard !selectedLayers.isEmpty else { return }
        let ids = selectedLayerIDs.map { NSNumber(value: $0) }
        var copies: [NSNumber] = []
        edit { copies = $0.duplicateLayers(ids) }
        selectLayers(copies.map(\.uint64Value))
    }

    func selectLayers(_ ids: [UInt64]) {
        guard let first = ids.first else { return }
        selectedLayers = Set(ids)
        selection = first
    }

    // MARK: - Clipboard (system pasteboard, so it works between projects)

    static let pasteboardType = NSPasteboard.PasteboardType("com.motionforge.clipboard")
    /// The system pasteboard normally; scripted checks use a private one so they never touch
    /// the user's clipboard.
    var pasteboard = NSPasteboard.general

    /// Copies the selected keyframes if any, otherwise the selected layers.
    func copySelection() {
        let text: String
        if !selectedKeyframes.isEmpty {
            text = engine.clipboard(forKeyframes: selectedKeyframes.map(\.address))
        } else if !selectedLayers.isEmpty {
            text = engine.clipboard(forLayers: selectedLayerIDs.map { NSNumber(value: $0) })
        } else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: Self.pasteboardType)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Layers paste above the topmost selected layer; keyframes paste at the playhead onto the
    /// selected layer(s).
    func paste() {
        guard let text = pasteboard.string(forType: Self.pasteboardType) else { return }
        closeCoalescedEdit()
        switch engine.clipboardKind(text) {
        case 1:
            let top = layers.firstIndex { selectedLayers.contains($0.layerID) } ?? 0
            do {
                var ids: [NSNumber] = []
                try tryEdit { ids = try $0.pasteLayers(text, at: top) }
                selectLayers(ids.map(\.uint64Value))
            } catch {
                alertMessage = error.localizedDescription
            }
        case 2:
            let targets = selectedLayerIDs
            guard !targets.isEmpty else {
                alertMessage = "Select the layer(s) to paste the keyframes onto."
                return
            }
            var message: NSString?
            var count = 0
            edit { count = $0.pasteKeyframes(text, layers: targets.map { NSNumber(value: $0) }, time: time.time, message: &message) }
            if count == 0 || message != nil {
                alertMessage = (count == 0 ? "No keyframes were pasted. " : "Pasted \(count) keyframes. ") + ((message as String?) ?? "")
            }
        default:
            break
        }
    }

    func selectAll() {
        selectLayers(layers.map(\.layerID))
    }

    func moveSelection(by delta: Int) {
        guard let s = selection, let idx = layers.firstIndex(where: { $0.layerID == s }) else { return }
        edit { _ = $0.moveLayer(s, to: idx + delta) }
    }

    func nudgeSelection(dx: Double, dy: Double) {
        let t = time.time
        coalescedEdit("Nudge") { e in
            for s in selectedLayerIDs {
                let v = e.parentSpaceVector(CGPoint(x: dx, y: dy), layer: s, time: t)
                var p = e.value(of: .position, layer: s, time: t)
                p.x += v.x
                p.y += v.y
                _ = e.setPropertyValue(p, prop: .position, layer: s, time: t)
            }
        }
    }

    // MARK: - Text, pen, presets

    func addText() {
        closeCoalescedEdit()
        var id: UInt64 = 0
        edit { id = $0.addTextLayer("Text") }
        if id != 0 { selectLayer(id, mode: .replace) }
    }

    /// Finishes the pen path: a new shape layer, or a mask on the selected layer.
    func commitPen(closed: Bool) {
        let draft = penDraft
        penDraft = []
        guard draft.count >= 2 else { return }
        if penDrawsMask, let target = selectedLayer, target.kind != .null {
            let t = time.time
            // Points and handles from composition space into the layer's own space.
            let local = draft.map { v -> MFPathVertex in
                let p = engine.compToLayer(v.point, layer: target.layerID, time: t)
                let i = engine.compToLayer(CGPoint(x: v.point.x + v.inTangent.x, y: v.point.y + v.inTangent.y), layer: target.layerID, time: t)
                let o = engine.compToLayer(CGPoint(x: v.point.x + v.outTangent.x, y: v.point.y + v.outTangent.y), layer: target.layerID, time: t)
                return MFPathVertex(point: p, inTangent: CGPoint(x: i.x - p.x, y: i.y - p.y), outTangent: CGPoint(x: o.x - p.x, y: o.y - p.y))
            }
            edit { _ = $0.addPathMask(vertices: local, layer: target.layerID) }
        } else {
            var id: UInt64 = 0
            edit { id = $0.addPathLayer(vertices: draft, closed: closed) }
            if id != 0 { selectLayer(id, mode: .replace) }
        }
    }

    static var presetsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionForge/Presets", isDirectory: true)
    }

    func reloadUserPresets() {
        let dir = Self.presetsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        userPresets = files.filter { $0.pathExtension == "mfpreset" }
            .compactMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap { MFPresetInfo.preset(withJSON: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func applyPreset(_ preset: MFPresetInfo) {
        let targets = selectedLayerIDs
        guard !targets.isEmpty else {
            alertMessage = "Select the layer(s) to apply “\(preset.name)” to."
            return
        }
        closeCoalescedEdit()
        var message: NSString?
        var count = 0
        edit { count = $0.applyPreset(preset.json, layers: targets.map { NSNumber(value: $0) }, time: time.time, message: &message) }
        if count == 0 || message != nil {
            alertMessage = (count == 0 ? "Nothing was applied. " : "") + ((message as String?) ?? "")
        }
    }

    /// Saves the primary layer's effects, text animators and keyframes as a reusable preset.
    func saveSelectionAsPreset() {
        guard let layer = selectedLayer else { return }
        let alert = NSAlert()
        alert.messageText = "Save Animation Preset"
        alert.informativeText = "Saves the effects, text animators and keyframes of “\(layer.name)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = layer.name + " Animation"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let json = engine.preset(fromLayer: layer.layerID, name: name, category: "My Presets")
        do {
            try FileManager.default.createDirectory(at: Self.presetsDirectory, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "-")
            try json.write(to: Self.presetsDirectory.appendingPathComponent(safe + ".mfpreset"), atomically: true, encoding: .utf8)
            reloadUserPresets()
        } catch {
            alertMessage = "Could not save the preset: \(error.localizedDescription)"
        }
    }

    // MARK: - Effects & masks

    func applyEffect(_ type: MFEffectType) {
        guard let s = selectedLayer, s.kind != .null else {
            alertMessage = "Select a shape or image layer first, then apply the effect."
            return
        }
        closeCoalescedEdit()
        edit { _ = $0.add(type, layer: s.layerID) }
    }

    func addMask(_ shape: MFMaskShape) {
        guard let s = selectedLayer, s.kind != .null else { return }
        closeCoalescedEdit()
        edit { _ = $0.addMask(shape, layer: s.layerID) }
    }

    // MARK: - Media

    func importMedia(urls: [URL], addToComposition: Bool) {
        for url in urls {
            do {
                let type = UTType(filenameExtension: url.pathExtension)
                let isMovie = type.map { $0.conforms(to: .movie) || $0.conforms(to: .video) } ?? false
                let isAudio = !isMovie && (type?.conforms(to: .audio) ?? false)
                var assetID: UInt64 = 0
                try tryEdit { engine in
                    if isMovie {
                        // A movie with no picture (sound only) comes in as audio.
                        do { assetID = try engine.importVideo(atPath: url.path).uint64Value } catch {
                            guard let sound = try? engine.importAudio(atPath: url.path) else { throw error }
                            assetID = sound.uint64Value
                        }
                    } else {
                        assetID = try (isAudio ? engine.importAudio(atPath: url.path) : engine.importImage(atPath: url.path)).uint64Value
                    }
                }
                if addToComposition && assetID != 0 { addLayer(asset: assetID) }
            } catch {
                alertMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func tryEdit(_ body: (MFEngine) throws -> Void) throws {
        defer { refresh() }
        try body(engine)
    }

    /// Everything that imports: whatever ImageIO and AVFoundation on this Mac read, plus vector artwork.
    static let importableTypes: [UTType] = {
        var types: [UTType] = [.image, .audio, .movie, .video, .audiovisualContent, .pdf, .svg]
        types += (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) }
        types += AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
        return types
    }()

    // MARK: - Updates

    /// MotionForge ▸ Check for Updates…: Home shows a new version, otherwise a short answer.
    func checkForUpdatesFromMenu() {
        Task {
            await updater.check(force: true)
            if updater.available != nil {
                UserDefaults.standard.removeObject(forKey: "updateSkipped")  // asked for: show it even if put off
                showHome = true
            } else if case .failed(let message) = updater.state {
                alertMessage = message
            } else {
                alertMessage = "MotionForge \(Updater.currentVersion) is the newest version."
            }
        }
    }

    /// Before quitting to install an update: not mid-export, and unsaved work saved or let go.
    func readyToQuitForUpdate() -> Bool {
        if exporter != nil {
            alertMessage = "Wait for the export to finish (or cancel it), then update."
            return false
        }
        return confirmDiscardChanges()
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.importableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Import video (MOV, MP4, M4V, MPG, MTS, …), images (PNG, JPEG, HEIC, WebP, AVIF, PSD, EXR, RAW, SVG, PDF, …) or audio"
        if panel.runModal() == .OK { importMedia(urls: panel.urls, addToComposition: true) }
    }

    // MARK: - Playback

    func togglePlayback() {
        time.isPlaying.toggle()
    }

    func stepFrames(_ n: Int) {
        time.isPlaying = false
        time.time = snap(time.time + Double(n) * frameDuration)
    }

    func goToStart() { time.isPlaying = false; time.time = 0 }
    func goToEnd() { time.isPlaying = false; time.time = snap(comp.duration) }

    // MARK: - Undo

    func undo() {
        closeCoalescedEdit()
        if let collab {  // shared projects undo your own steps only
            collab.flushNow()
            collab.undo()
            refresh()
            return
        }
        edit { _ = $0.undo() }
    }

    var canUndo: Bool { collab.map { $0.sync.canUndo } ?? engine.canUndo }
    var canRedo: Bool { collab.map { $0.sync.canRedo } ?? engine.canRedo }
    var undoTitle: String { collab != nil ? "Undo" : engine.canUndo ? "Undo \(engine.undoLabel)" : "Undo" }
    var redoTitle: String { collab != nil ? "Redo" : engine.canRedo ? "Redo \(engine.redoLabel)" : "Redo" }

    /// Other people's edits arrived (shared projects).
    func remoteDidChange() {
        refresh()
        selectedLayers = selectedLayers.filter { id in layers.contains { $0.layerID == id } }
        if let s = selection, !selectedLayers.contains(s) { selection = selectedLayers.first }
    }

    /// The editor now shows a shared project that lives on the server (no file of its own).
    func showSharedProject() {
        projectURL = nil
        selection = nil
        time.time = 0
        zoom = nil
        pan = .zero
        engine.markCleanForNewDocument()
        refresh()
        resetCompNavigation()
        RecoveryStore.clear()
        enterWorkspace()
    }

    func redo() {
        closeCoalescedEdit()
        if let collab {
            collab.flushNow()
            collab.redo()
            refresh()
            return
        }
        edit { _ = $0.redo() }
    }

    // MARK: - Project files

    var displayName: String { projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }

    /// Returns false if the user cancelled.
    func confirmDiscardChanges() -> Bool {
        if let collab {
            let alert = NSAlert()
            alert.messageText = "Leave “\(collab.project.name)”?"
            alert.informativeText = "Everything you changed is already saved in the shared project. You can open it again from Home."
            alert.addButton(withTitle: "Leave")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            leaveSharedProject()
            if projectURL == nil { return true }  // nothing local to save
        }
        guard engine.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return false
        default: return true
        }
    }

    func newProject() {
        guard confirmDiscardChanges() else { return }
        closeCoalescedEdit()
        engine.newProject(withWidth: 1920, height: 1080, fps: 30, duration: 10)
        projectURL = nil
        selection = nil
        time.time = 0
        zoom = nil
        pan = .zero
        refresh()
        resetCompNavigation()
        RecoveryStore.clear()
        enterWorkspace()
    }

    func openProjectPanel() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.motionForgeProject, .motionForgeBundle, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension == "mfbundle" { importBundle(url, askedToDiscard: true) } else { open(url: url) }
    }

    func open(url: URL) {
        do {
            try engine.openProject(atPath: url.path)
            projectURL = url
            selection = nil
            time.time = 0
            zoom = nil
            pan = .zero
            refresh()
            resetCompNavigation()
            RecoveryStore.clear()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            RecentProjects.note(url, engine: engine)
            enterWorkspace()
            let missing = assets.filter(\.missing).map(\.name)
            if !missing.isEmpty { alertMessage = "Missing media: " + missing.joined(separator: ", ") }
        } catch {
            alertMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = projectURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.motionForgeProject]
        panel.nameFieldStringValue = displayName + ".mfproj"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    @discardableResult
    func write(to url: URL) -> Bool {
        closeCoalescedEdit()
        do {
            try engine.saveProject(toPath: url.path)
            projectURL = url
            RecoveryStore.clear()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            RecentProjects.note(url, engine: engine, time: time.time)  // thumbnail of what you were looking at
            refresh()
            return true
        } catch {
            alertMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    func exportFramePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(displayName) \(Timecode.string(time.time, fps: comp.fps).replacingOccurrences(of: ":", with: "-")).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.writePNG(atTime: time.time, scale: 1, transparent: checkerboard, toPath: url.path)
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Autosave & crash recovery

    /// Every 2 s, unsaved changes are written: straight into the project file once it has one
    /// (File › Auto Save, on by default), otherwise to the crash-recovery copy. Nothing is written
    /// while an edit is still open (a drag, a burst of typing), so a save never lands mid-gesture.
    static let autosaveInterval: TimeInterval = 2

    @Published var autoSaveToFile = UserDefaults.standard.object(forKey: "autoSaveToFile") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSaveToFile, forKey: "autoSaveToFile") }
    }
    @Published private(set) var lastAutoSave: Date?
    private var autosaveFailed = false

    private func startAutosave() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveIfNeeded() }
        }
    }

    private var autosaveInFlight = false
    private var autosaveNotBefore = Date.distantPast
    private var fileAutosaveRetryAt = Date.distantPast  // after a failed write, recovery copies until then
    var autosaveBusy: Bool { autosaveInFlight }

    func autosaveIfNeeded() {
        closeLeakedUndoGroup()
        guard engine.dirty, engine.revision != lastAutosavedRevision, !engine.inUndoGroup, !autosaveInFlight,
              !time.isPlaying, Date() >= autosaveNotBefore else { return }
        let revision = engine.revision
        let fileURL = autoSaveToFile && Date() >= fileAutosaveRetryAt ? projectURL.flatMap { $0.pathExtension == "mfproj" ? $0 : nil } : nil
        let toFile = fileURL != nil
        let url = fileURL ?? RecoveryStore.autosaveURL
        if !toFile { RecoveryStore.prepare(originalURL: projectURL) }
        autosaveInFlight = true
        // Written off the main thread so a big project never stalls playback or editing.
        engine.saveProjectInBackground(toPath: url.path, markSaved: toFile) { [weak self] error, seconds in
            let message = error?.localizedDescription
            MainActor.assumeIsolated {  // the engine calls back on the main queue
                self?.autosaveFinished(revision: revision, toFile: toFile, url: url, error: message, seconds: seconds)
            }
        }
    }

    private func autosaveFinished(revision: UInt64, toFile: Bool, url: URL, error: String?, seconds: Double) {
        autosaveInFlight = false
        // Slow writes (very large projects) back off instead of saving back to back.
        autosaveNotBefore = Date().addingTimeInterval(max(0, seconds * 4 - Self.autosaveInterval))
        if let error {
            if toFile {
                fileAutosaveRetryAt = Date().addingTimeInterval(30)
                if !autosaveFailed {
                    autosaveFailed = true
                    alertMessage = "Auto Save couldn’t write “\(url.lastPathComponent)”: \(error). Unsaved changes go to a recovery copy until it works again."
                }
            }
            NSLog("MotionForge autosave failed: \(error)")
            return
        }
        lastAutosavedRevision = revision
        if toFile {
            autosaveFailed = false
            lastAutoSave = Date()
            RecoveryStore.clear()
        }
    }

    /// A drag whose view disappeared mid-gesture (scrolled away, slid past the end) never ends its
    /// undo group; later edits would all join it and autosave would stop. Close it once no mouse
    /// button is down and no keyboard edit is open.
    func closeLeakedUndoGroup() {
        guard engine.inUndoGroup, coalesceKey == nil, NSEvent.pressedMouseButtons == 0 else { return }
        var guardCount = 0
        while engine.inUndoGroup && guardCount < 16 { engine.endUndoGroup(); guardCount += 1 }
    }

    /// Called once the window is up: offers to restore work from a session that didn't quit cleanly.
    func offerRecoveryIfNeeded() {
        guard let pending = RecoveryStore.pendingRecovery() else {
            RecoveryStore.beginSession()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Recover unsaved work?"
        let when = pending.date.formatted(date: .abbreviated, time: .shortened)
        alert.informativeText = "MotionForge didn’t quit normally. An autosave of “\(pending.originalURL?.lastPathComponent ?? "Untitled")” from \(when) is available."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try engine.recover(fromPath: pending.projectURL.path)
                projectURL = pending.originalURL
                refresh()
                resetCompNavigation()
                enterWorkspace()  // straight to the recovered work, with Home's "Back to…" available
            } catch {
                alertMessage = "Recovery failed: \(error.localizedDescription)"
            }
        } else {
            RecoveryStore.clear()
        }
        RecoveryStore.beginSession()
    }

    /// Clean quit: the user has already answered the save prompt, so the autosave can go.
    func applicationWillTerminate() {
        claudeBridge?.stop()
        RecoveryStore.endSession(keepAutosave: false)
    }

    // MARK: - Memory pressure

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            MainActor.assumeIsolated {
                if event.contains(.critical) {
                    self.engine.handle(.critical)
                    self.memoryPressureUntil = CACurrentMediaTime() + 15
                } else if event.contains(.warning) {
                    self.engine.handle(.warning)
                    self.memoryPressureUntil = CACurrentMediaTime() + 15
                } else {
                    self.engine.handle(.normal)
                }
            }
        }
        source.resume()
        memoryPressure = source
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if UIDemo.ignoresKeys {  // scripted runs: typing elsewhere must not steer them
                print("ui-demo: ignored key \(event.keyCode)")
                return nil
            }
            nonisolated(unsafe) let e = event  // local monitors run on the main thread
            return MainActor.assumeIsolated { self.handleKey(e) } ? nil : event
        }
    }

    /// Editor shortcuts that must not fire while typing into a text field.
    private func handleKey(_ event: NSEvent) -> Bool {
        // ⌥⌘; is After Effects' Preferences: Settings, as ⌘, opens it (macOS names the menu item
        // Settings…, so a second item for it would read as a duplicate).
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option],
           event.charactersIgnoringModifiers == ";" {
            // The app menu's own Settings… item (⌘,): the only way into a SwiftUI Settings scene from AppKit.
            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) {
                menu.performActionForItem(at: i)
            }
            return true
        }
        if showHome { return false }  // the workspace is covered
        // Only the editor window: not the export window, a sheet, or anything above the editor.
        guard let window = event.window, !(window is NSPanel), window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if let responder = event.window?.firstResponder, responder is NSText || responder is NSTextView { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == [.command] && event.modifierFlags.contains(.shift) && event.keyCode == 126 {  // ⌘⇧↑
            goToParentComposition()
            return true
        }
        if mods == [.command] && !event.modifierFlags.contains(.shift) {
            switch event.keyCode {
            case 8: copySelection(); return true    // ⌘C
            case 9: paste(); return true            // ⌘V
            case 7: cutSelection(); return true     // ⌘X
            case 0: selectAll(); return true        // ⌘A
            default: return false
            }
        }
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // Letters by the character typed, so they follow the keyboard layout (Y and Z swap on QWERTZ).
        if event.keyCode != 82, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, key.first!.isLetter {
            if let t = EditorTool.allCases.first(where: { $0.key == key }) {
                selectTool(t)
                return true
            }
            switch key {
            case "b": setWorkAreaStart(); return true
            case "n": setWorkAreaEnd(); return true
            case "p": revealProperties([.position], adding: shift); return true
            case "r": revealProperties([.rotation], adding: shift); return true
            case "s": revealProperties([.scale], adding: shift); return true
            case "t": revealProperties([.opacity], adding: shift); return true
            case "a": revealProperties([.anchorPoint], adding: shift); return true
            case "u": revealAnimatedOrModified(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 49: togglePlayback(); return true                                   // space
        case 51, 117: deleteSelection(); return true                             // delete, fwd-delete
        case 123: if selection != nil { nudgeSelection(dx: shift ? -10 : -1, dy: 0) } else { stepFrames(shift ? -10 : -1) }; return true
        case 124: if selection != nil { nudgeSelection(dx: shift ? 10 : 1, dy: 0) } else { stepFrames(shift ? 10 : 1) }; return true
        case 126: nudgeSelection(dx: 0, dy: shift ? -10 : -1); return true       // up
        case 125: nudgeSelection(dx: 0, dy: shift ? 10 : 1); return true         // down
        case 116: stepFrames(-1); return true                                    // page up
        case 121: stepFrames(1); return true                                     // page down
        case 115: goToStart(); return true                                       // home
        case 119: goToEnd(); return true                                         // end
        case 53:                                                                 // escape
            if !penDraft.isEmpty { penDraft = [] } else if tool != .select { tool = .select } else { clearSelection() }
            return true
        case 82, 29: startRAMPreview(); return true                               // 0 (keypad or main row)
        case 36, 76:                                                             // return / enter
            if tool == .pen && penDraft.count >= 2 { commitPen(closed: false); return true }
            return false
        case 24: zoomTimeline(by: 1.5); return true                               // = zoom timeline in
        case 27: zoomTimeline(by: 1 / 1.5); return true                           // - zoom out
        case 42: viewport.fit(); return true                                      // \ whole composition
        default: return false
        }
    }

    // MARK: - Starter content

    /// A small animated scene so a fresh launch shows something to play with.
    // MARK: - Home

    func enterWorkspace() {
        hasOpenWork = true
        withAnimation(.easeInOut(duration: 0.3)) { showHome = false }
    }

    func openRecent(_ r: RecentProject) {
        guard r.exists else {
            alertMessage = "“\(r.name)” isn’t at \(r.path) any more."
            return
        }
        if projectURL?.path == r.path, hasOpenWork {  // already open: just go back to it
            enterWorkspace()
            return
        }
        guard confirmDiscardChanges() else { return }
        open(url: r.url)
    }

    /// The small animated scene a fresh launch starts with.
    func showStarterScene() {
        if projectURL != nil || engine.dirty {
            guard confirmDiscardChanges() else { return }
            seedStarterContent()
            engine.markCleanForNewDocument()
            projectURL = nil
            time.time = 1
            refresh()
            resetCompNavigation()
        }
        enterWorkspace()
    }

    private func seedStarterContent() {
        let e = engine
        e.newProject(withWidth: 1920, height: 1080, fps: 30, duration: 6)
        _ = e.setCompositionWidth(1920, height: 1080, fps: 30, duration: 6,
                                  background: MFValue(x: 0.07, y: 0.075, z: 0.09, w: 1), name: "Main")
        let ring = e.addShapeLayer(.ellipse)
        _ = e.setLayer(ring, name: "Ring")
        _ = e.setLayer(ring, fillEnabled: false, strokeEnabled: true)
        _ = e.setPropertyValue(MFValue(x: 520, y: 520, z: 0, w: 0), prop: .size, layer: ring, time: 0)
        _ = e.setPropertyValue(MFValue(x: 18, y: 0, z: 0, w: 0), prop: .strokeWidth, layer: ring, time: 0)
        _ = e.setPropertyValue(MFValue(x: 0.35, y: 0.55, z: 1, w: 1), prop: .strokeColor, layer: ring, time: 0)
        _ = e.set(animated: true, prop: .scale, layer: ring, time: 0)
        _ = e.setPropertyValue(MFValue(x: 60, y: 60, z: 0, w: 0), prop: .scale, layer: ring, time: 0)
        _ = e.setPropertyValue(MFValue(x: 110, y: 110, z: 0, w: 0), prop: .scale, layer: ring, time: 3)
        _ = e.setPropertyValue(MFValue(x: 60, y: 60, z: 0, w: 0), prop: .scale, layer: ring, time: 5.9)

        let star = e.addShapeLayer(.star)
        _ = e.setLayer(star, name: "Star")
        _ = e.setPropertyValue(MFValue(x: 320, y: 320, z: 0, w: 0), prop: .size, layer: star, time: 0)
        _ = e.setPropertyValue(MFValue(x: 0.98, y: 0.78, z: 0.2, w: 1), prop: .fillColor, layer: star, time: 0)
        _ = e.set(animated: true, prop: .rotation, layer: star, time: 0)
        _ = e.setPropertyValue(MFValue(x: 360, y: 0, z: 0, w: 0), prop: .rotation, layer: star, time: 5.9)
        for (i, layer) in [ring, star].enumerated() {
            for k in e.layer(withID: layer)?.keyframes(for: i == 0 ? .scale : .rotation) ?? [] {
                _ = e.setKeyframeInterpolationAt(k.index, prop: i == 0 ? .scale : .rotation, layer: layer, in: .bezier, out: .bezier)
            }
        }

        let card = e.addShapeLayer(.rectangle)
        _ = e.setLayer(card, name: "Card")
        _ = e.setPropertyValue(MFValue(x: 700, y: 160, z: 0, w: 0), prop: .size, layer: card, time: 0)
        _ = e.setPropertyValue(MFValue(x: 80, y: 0, z: 0, w: 0), prop: .roundness, layer: card, time: 0)
        _ = e.setPropertyValue(MFValue(x: 0.93, y: 0.27, z: 0.42, w: 1), prop: .fillColor, layer: card, time: 0)
        _ = e.set(animated: true, prop: .position, layer: card, time: 0)
        _ = e.setPropertyValue(MFValue(x: 960, y: 1240, z: 0, w: 0), prop: .position, layer: card, time: 0)
        _ = e.setPropertyValue(MFValue(x: 960, y: 900, z: 0, w: 0), prop: .position, layer: card, time: 1)
        for k in e.layer(withID: card)?.keyframes(for: .position) ?? [] {
            _ = e.setKeyframeInterpolationAt(k.index, prop: .position, layer: card, in: .bezier, out: .bezier)
        }
        // Phase 3: GPU effects on the starter layers.
        let glow = e.add(.glow, layer: star)
        _ = e.setRefValue(MFValue(x: 35, y: 0, z: 0, w: 0), ref: MFPropRef(owner: .effect, ownerID: glow, index: 0), layer: star, time: 0)
        _ = e.setRefValue(MFValue(x: 70, y: 0, z: 0, w: 0), ref: MFPropRef(owner: .effect, ownerID: glow, index: 1), layer: star, time: 0)
        let shadow = e.add(.dropShadow, layer: card)
        _ = e.setRefValue(MFValue(x: 28, y: 0, z: 0, w: 0), ref: MFPropRef(owner: .effect, ownerID: shadow, index: 3), layer: card, time: 0)
        _ = e.setRefValue(MFValue(x: 40, y: 0, z: 0, w: 0), ref: MFPropRef(owner: .effect, ownerID: shadow, index: 4), layer: card, time: 0)
    }
}

enum Timecode {
    static func string(_ t: Double, fps: Double) -> String {
        let totalFrames = Int((t * fps).rounded())
        let f = Int(fps.rounded())
        let frames = f > 0 ? totalFrames % f : 0
        let seconds = f > 0 ? totalFrames / f : 0
        return String(format: "%02d:%02d:%02d", seconds / 60, seconds % 60, frames)
    }
}
