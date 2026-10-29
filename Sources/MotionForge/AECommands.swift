import AppKit
import MFRender

/// Commands and keys After Effects users expect: tools, the work area (B / N), RAM Preview,
/// property reveal (P R S T A U UU), Split Layer, Pre-compose and Trim Comp to Work Area.

/// Timeline rows a property key shows for a layer.
enum PropertyReveal: Equatable {
    case props([MFProp])  // P, R, S, T, A; ⇧ adds to what's shown
    case animated         // U
    case modified         // UU: animated or changed from a new layer's values
}

extension EditorTool {
    /// The key that picks the tool (Type is ⌘T, so it has none here).
    var key: String? {
        switch self {
        case .select: return "v"
        case .hand: return "h"
        case .zoom: return "z"
        case .rotate: return "w"
        case .orbit: return "c"
        case .panBehind: return "y"
        case .pen: return "g"
        case .shape: return "q"
        case .type: return nil
        }
    }

    var name: String {
        switch self {
        case .select: return "Selection"
        case .hand: return "Hand"
        case .zoom: return "Zoom"
        case .rotate: return "Rotation"
        case .orbit: return "Orbit Camera (3D View)"
        case .panBehind: return "Pan Behind (Anchor Point)"
        case .pen: return "Pen"
        case .shape: return "Shape"
        case .type: return "Type"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .zoom: return "plus.magnifyingglass"
        case .rotate: return "arrow.clockwise"
        case .orbit: return "rotate.3d"
        case .panBehind: return "scope"
        case .pen: return "pencil.and.outline"
        case .shape: return "square.on.circle"
        case .type: return "character.cursor.ibeam"
        }
    }

    var shortcut: String { key.map { $0.uppercased() } ?? "⌘T" }

    var help: String {
        switch self {
        case .select: return "Select and move layers"
        case .hand: return "Drag to pan the viewer"
        case .zoom: return "Click to zoom in, ⌥-click to zoom out"
        case .rotate: return "Drag to rotate the selected layers (⇧ snaps to 45°)"
        case .orbit: return "Drag to look around the 3D scene (a Custom View): ⌥-drag to move closer, ⇧-drag to pan. Export uses the camera"
        case .panBehind: return "Drag to move a layer's anchor point without moving the layer"
        case .pen: return "Click for corners, drag for curves, click the first point to close, Return for an open line"
        case .shape: return "Drag to draw a shape (⇧ for a square); press Q again for the next shape"
        case .type: return "Click to add a text layer there"
        }
    }
}

extension MFShapeType {
    var toolName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .polygon: return "Polygon"
        case .star: return "Star"
        default: return "Shape"
        }
    }

    var toolSymbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .polygon: return "hexagon"
        case .star: return "star"
        default: return "square.on.circle"
        }
    }
}

/// The viewer's look at the 3D scene: orbiting the composition's centre.
struct OrbitView: Equatable {
    var yaw = 0.0, pitch = 0.0
    var distance = 1.0  // 1 = where the default camera is
    var pan = CGPoint.zero
}

extension EditorModel {
    // MARK: Tools

    func selectTool(_ t: EditorTool) {
        if t == .shape && tool == .shape {  // Q again: the next shape, as in After Effects
            let order: [MFShapeType] = [.rectangle, .ellipse, .polygon, .star]
            shapeTool = order[((order.firstIndex(of: shapeTool) ?? -1) + 1) % order.count]
        }
        tool = t
    }

    /// Shape tool: a new shape filling `rect` (composition space), one undo step.
    func addShape(_ shape: MFShapeType, in rect: CGRect) {
        closeCoalescedEdit()
        var id: UInt64 = 0
        engine.beginUndoGroup("New \(shape.toolName)")
        edit { e in
            id = e.addShapeLayer(shape)
            guard id != 0 else { return }
            _ = e.setPropertyValue(MFValue(x: rect.midX, y: rect.midY, z: 0, w: 0), prop: .position, layer: id, time: time.time)
            if rect.width >= 1 && rect.height >= 1 {
                _ = e.setPropertyValue(MFValue(x: rect.width, y: rect.height, z: 0, w: 0), prop: .size, layer: id, time: time.time)
            }
        }
        engine.endUndoGroup()
        refresh()
        if id != 0 { selectLayer(id, mode: .replace) }
    }

    /// Type tool: a text layer at `point` (composition space), one undo step.
    func addText(at point: CGPoint) {
        closeCoalescedEdit()
        var id: UInt64 = 0
        engine.beginUndoGroup("New Text")
        edit { e in
            id = e.addTextLayer("Text")
            if id != 0 {
                _ = e.setPropertyValue(MFValue(x: point.x, y: point.y, z: 0, w: 0), prop: .position, layer: id, time: time.time)
            }
        }
        engine.endUndoGroup()
        refresh()
        guard id != 0 else { return }
        selectLayer(id, mode: .replace)
        showInspector = true
        focusTextOf = id  // type the text straight away
    }

    // MARK: 3D

    /// Layer ▸ New Camera (⌥⇧⌘C): 3D layers are then seen through it; it starts at the 2D view.
    func addCamera() {
        closeCoalescedEdit()
        var id: UInt64 = 0
        edit { id = $0.addCameraLayer() }
        if id != 0 { selectLayer(id, mode: .replace) }
    }

    /// Layer ▸ 3D Layer: switches the selected layers (all to 3D unless they all are already).
    func toggleThreeD() {
        let picked = layers.filter { selectedLayers.contains($0.layerID) && $0.kind != .audio && $0.kind != .precomp && $0.kind != .camera }
        guard !picked.isEmpty else { return }
        let on = !picked.allSatisfy(\.threeD)
        engine.beginUndoGroup(on ? "3D Layers" : "2D Layers")
        edit { e in for l in picked { _ = e.setLayer(l.layerID, threeD: on) } }
        engine.endUndoGroup()
        refresh()
    }

    // MARK: Work area

    /// Where playback loops: the work area when there is one, else the whole composition.
    var playRange: (start: Double, end: Double) {
        comp.hasWorkArea ? (comp.workAreaStart, comp.workAreaEnd) : (0, comp.duration)
    }

    /// B: the work area starts at the playhead (its end moves to the comp's end if it was before).
    func setWorkAreaStart() {
        var end = comp.hasWorkArea ? comp.workAreaEnd : -1
        if end >= 0 && time.time > end - frameDuration + 1e-9 { end = -1 }
        edit { _ = $0.setWorkArea(start: time.time, end: end) }
    }

    /// N: the work area ends with the frame at the playhead.
    func setWorkAreaEnd() {
        var start = comp.workAreaStart
        if time.time < start - 1e-9 { start = 0 }
        edit { _ = $0.setWorkArea(start: start, end: time.time + frameDuration) }
    }

    func clearWorkArea() {
        edit { _ = $0.setWorkArea(start: 0, end: -1) }
    }

    /// ⇧⌘X: the work area becomes the whole composition.
    func trimCompToWorkArea() {
        guard comp.hasWorkArea else {
            alertMessage = "Set a work area first: B at its first frame, N at its last."
            return
        }
        closeCoalescedEdit()
        let start = comp.workAreaStart
        stopPlayback()
        edit { _ = $0.trimCompositionToWorkArea() }
        time.time = snap(min(max(0, time.time - start), comp.duration - frameDuration))
    }

    // MARK: RAM Preview

    /// 0: plays the work area from its start, rendering every frame into the frame cache on the
    /// first pass (slower than real time if it has to be), then in real time with sound, looping.
    func startRAMPreview() {
        if ramPreview {  // 0 again stops, like Space
            stopPlayback()
            return
        }
        guard workspace == .viewer else { return }
        stopPlayback()
        policyBeforeRAMPreview = engine.cachePolicy
        engine.cachePolicy = .all
        ramPreview = true
        time.time = playRange.start
        time.isPlaying = true
    }

    func endRAMPreview() {
        guard ramPreview else { return }
        ramPreview = false
        if let p = policyBeforeRAMPreview { engine.cachePolicy = p }
        policyBeforeRAMPreview = nil
        perf.ramPreviewFill = nil
    }

    // MARK: Property reveal

    /// Selected layers, or every layer when none is selected (as After Effects does).
    private var revealTargets: [UInt64] {
        let picked = layers.filter { selectedLayers.contains($0.layerID) }.map(\.layerID)
        return picked.isEmpty ? layers.map(\.layerID) : picked
    }

    /// P, R, S, T, A: show just this property; ⇧ adds it to (or takes it from) what's shown. The
    /// same key again hides it.
    func revealProperties(_ props: [MFProp], adding: Bool) {
        lastRevealKey = nil
        let targets = revealTargets
        guard !targets.isEmpty else { return }
        func shown(_ id: UInt64) -> [MFProp] {
            if case .props(let p)? = propertyReveal[id] { return p }
            return []
        }
        let alreadyShown = targets.allSatisfy { adding ? Set(props).isSubset(of: shown($0)) : shown($0) == props }
        for id in targets {
            var p = adding ? shown(id) : []
            if alreadyShown {
                p.removeAll { props.contains($0) }
            } else {
                for q in props where !p.contains(q) { p.append(q) }
            }
            p.sort { $0.rawValue < $1.rawValue }  // timeline order: anchor, position, scale, rotation, opacity
            propertyReveal[id] = p.isEmpty ? nil : .props(p)
        }
    }

    /// U: animated properties; UU (twice quickly): every property changed from a new layer's values.
    func revealAnimatedOrModified() {
        let now = CACurrentMediaTime()
        let twice = lastRevealKey.map { $0.key == "u" && now - $0.at < 0.45 } ?? false
        lastRevealKey = twice ? nil : ("u", now)
        let want: PropertyReveal = twice ? .modified : .animated
        let targets = revealTargets
        let toggleOff = !twice && targets.allSatisfy { propertyReveal[$0] == .animated }
        for id in targets { propertyReveal[id] = toggleOff ? nil : want }
    }

    func hideRevealedProperties() {
        propertyReveal = [:]
        expandedLayers = []
    }

    // MARK: Layer commands

    /// ⇧⌘D: the selected layers (all of them when none is selected) split at the playhead.
    func splitLayers() {
        closeCoalescedEdit()
        let ids = revealTargets.map { NSNumber(value: $0) }
        guard !ids.isEmpty else { return }
        var halves: [NSNumber] = []
        edit { halves = $0.splitLayers(ids, at: time.time) }
        if halves.isEmpty {
            alertMessage = "Move the playhead inside the layer to split it (at least a frame from either end)."
            return
        }
        selectLayers(halves.map(\.uint64Value))
    }

    /// ⇧⌘C: asks for a name, then moves the selected layers into a new composition.
    func precomposeSelection() {
        guard !selectedLayers.isEmpty else {
            alertMessage = "Select the layers to pre-compose first."
            return
        }
        let n = engine.compositions.filter { $0.name.hasPrefix("Pre-comp") }.count + 1
        let alert = NSAlert()
        alert.messageText = "Pre-compose"
        alert.informativeText = "The selected layers move into a new composition, shown here as one layer. Links to layers left behind (parent, track matte) are removed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Pre-comp \(n)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Pre-compose")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        precomposeSelection(named: field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func precomposeSelection(named name: String) {
        closeCoalescedEdit()
        let ids = layers.filter { selectedLayers.contains($0.layerID) }.map { NSNumber(value: $0.layerID) }
        guard !ids.isEmpty else { return }
        var inner: UInt64 = 0
        edit { inner = $0.precompose(ids, name: name) }
        guard inner != 0 else { return }
        if let pl = layers.first(where: { $0.kind == .precomp && $0.sourceCompID == inner }) { selectLayer(pl.layerID, mode: .replace) }
    }

    /// ⌥⌘M: export again with the settings used last time, straight to choosing where (the export
    /// window when nothing was exported yet).
    func exportWithLastSettings() {
        if exporter != nil { showExportWindow(); return }
        guard account.canExport else { showPaywall = true; return }
        guard let last = lastExport else { requestExport(); return }
        chooseDestinationAndExport(last.settings, summary: last.summary)
    }
}
