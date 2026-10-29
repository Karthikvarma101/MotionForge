import MFRender
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: model.selectedLayer == nil ? "Composition"
                        : model.selectedLayers.count > 1 ? "Properties — \(model.selectedLayers.count) layers selected, editing “\(model.selectedLayer!.name)”"
                        : "Properties")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let layer = model.selectedLayer {
                        LayerSection(model: model, layer: layer)
                        if layer.kind == .audio {
                            AudioSection(model: model, time: time, layer: layer)
                        } else {
                            PropertySection(title: layer.kind == .camera ? "Camera" : "Transform", model: model, time: time, layer: layer,
                                            specs: layer.transformProps.map(ParamSpec.init))
                        }
                        if layer.kind == .shape {
                            ShapeSection(model: model, time: time, layer: layer)
                        }
                        if layer.kind == .text {
                            TextSection(model: model, time: time, layer: layer)
                            AnimatorsSection(model: model, time: time, layer: layer)
                        }
                        if layer.kind == .precomp {
                            PrecompSection(model: model, time: time, layer: layer)
                        }
                        if layer.kind != .null && layer.kind != .audio {
                            MasksSection(model: model, time: time, layer: layer)
                            EffectsSection(model: model, time: time, layer: layer)
                        }
                    } else {
                        CompositionSection(model: model)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.panel)
    }
}

struct PanelHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Theme.panelDark)
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Composition

private struct CompositionSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        SectionBox(title: model.comp.name) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("Size").foregroundStyle(.secondary); Text("\(model.comp.width) × \(model.comp.height)") }
                GridRow { Text("Frame rate").foregroundStyle(.secondary); Text("\(fpsString(model.comp.fps)) fps") }
                GridRow { Text("Duration").foregroundStyle(.secondary); Text(Timecode.string(model.comp.duration, fps: model.comp.fps)) }
                GridRow { Text("Layers").foregroundStyle(.secondary); Text("\(model.layers.count)") }
            }
            .font(.system(size: 11))
            Button("Composition Settings…") { model.showCompSettings = true }
            Text("Select a layer in the viewer or timeline to edit its properties.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Layer

private struct LayerSection: View {
    @ObservedObject var model: EditorModel
    let layer: MFLayerInfo
    @State private var name = ""

    var body: some View {
        SectionBox(title: "Layer") {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.edit { _ = $0.setLayer(layer.layerID, name: name) } }
                .onAppear { name = layer.name }
                .onChange(of: layer.layerID) { _, _ in name = layer.name }
                .onChange(of: layer.name) { _, n in name = n }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                if layer.kind != .audio && layer.kind != .precomp && layer.kind != .camera {
                GridRow {
                    Text("3D").foregroundStyle(.secondary)
                    Toggle("3D Layer", isOn: Binding(get: { layer.threeD },
                                                     set: { v in model.edit { _ = $0.setLayer(layer.layerID, threeD: v) } }))
                        .help("Z Position and X / Y Rotation, seen through the camera (Layer ▸ New Camera)")
                }
                }
                if layer.kind != .audio && layer.kind != .camera {
                GridRow {
                    Text("Blend").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { layer.blend },
                                                  set: { m in model.edit { _ = $0.setLayer(layer.layerID, blendMode: m) } })) {
                        Text("Normal").tag(MFBlendMode.normal)
                        Text("Add").tag(MFBlendMode.add)
                        Text("Multiply").tag(MFBlendMode.multiply)
                        Text("Screen").tag(MFBlendMode.screen)
                        Text("Overlay").tag(MFBlendMode.overlay)
                        Text("Darken").tag(MFBlendMode.darken)
                        Text("Lighten").tag(MFBlendMode.lighten)
                    }
                    .labelsHidden()
                    .disabled(layer.kind == .null)
                }
                GridRow {
                    Text("Parent").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { layer.parentID },
                                                  set: { p in
                                                      model.edit { e in
                                                          if !e.setLayer(layer.layerID, parent: p) && p != layer.parentID {
                                                              model.alertMessage = "That parent would create a loop."
                                                          }
                                                      }
                                                  })) {
                        Text("None").tag(UInt64(0))
                        ForEach(model.layers.filter { $0.layerID != layer.layerID }, id: \.layerID) { l in
                            Text(l.name).tag(l.layerID)
                        }
                    }
                    .labelsHidden()
                }
                if layer.kind != .null {
                    GridRow {
                        Text("Matte").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Picker("", selection: Binding(get: { layer.matteLayerID },
                                                          set: { m in setMatte(m, mode: layer.matteMode == .none ? .alpha : layer.matteMode) })) {
                                Text("None").tag(UInt64(0))
                                ForEach(model.layers.filter { $0.layerID != layer.layerID && $0.kind != .null }, id: \.layerID) { l in
                                    Text(l.name).tag(l.layerID)
                                }
                            }
                            .labelsHidden()
                            if layer.matteLayerID != 0 {
                                Picker("", selection: Binding(get: { layer.matteMode },
                                                              set: { m in setMatte(layer.matteLayerID, mode: m) })) {
                                    ForEach([MFMatteMode.alpha, .alphaInverted, .luma, .lumaInverted], id: \.rawValue) { m in
                                        Text(m.label).tag(m)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                        .help("Track matte: show this layer only where the chosen layer has alpha (or brightness). The matte layer is hidden automatically.")
                    }
                }
                }
                GridRow {
                    Text("In / Out").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        timeField(layer.inPoint) { v in (v, layer.outPoint) }
                        Text("→").foregroundStyle(.secondary)
                        timeField(layer.outPoint) { v in (layer.inPoint, v) }
                    }
                }
            }
            .font(.system(size: 11))
        }
    }

    private func setMatte(_ matte: UInt64, mode: MFMatteMode) {
        model.edit { _ = $0.setLayer(layer.layerID, matte: matte, mode: matte == 0 ? .none : mode) }
    }

    private func timeField(_ value: Double, _ make: @escaping (Double) -> (Double, Double)) -> some View {
        ScrubField(value: value, step: 1 / model.comp.fps, precision: 2, suffix: "s", width: 60,
                   onBegin: { model.engine.beginUndoGroup("Layer Timing") },
                   onChange: { v in
                       let (i, o) = make(model.snap(v))
                       model.edit { _ = $0.setLayer(layer.layerID, inPoint: i, outPoint: o) }
                   },
                   onEnd: { model.engine.endUndoGroup(); model.refresh() })
    }
}

// MARK: - Shape

private struct ShapeSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Shape") {
                if layer.shape == .path {
                    Label("Bezier path · \(layer.pathVertices.count) points\(layer.pathClosed ? "" : " · open")", systemImage: "scribble")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Drag its points and handles in the viewer. Trim Start/End animate a line drawing itself.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                Picker("", selection: Binding(get: { layer.shape },
                                              set: { s in model.edit { _ = $0.setLayer(layer.layerID, shapeType: s) } })) {
                    Image(systemName: "rectangle").tag(MFShapeType.rectangle)
                    Image(systemName: "circle").tag(MFShapeType.ellipse)
                    Image(systemName: "hexagon").tag(MFShapeType.polygon)
                    Image(systemName: "star").tag(MFShapeType.star)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                }
                HStack(spacing: 14) {
                    Toggle("Fill", isOn: Binding(get: { layer.fillEnabled },
                                                 set: { v in model.edit { _ = $0.setLayer(layer.layerID, fillEnabled: v, strokeEnabled: layer.strokeEnabled) } }))
                    Toggle("Stroke", isOn: Binding(get: { layer.strokeEnabled },
                                                   set: { v in model.edit { _ = $0.setLayer(layer.layerID, fillEnabled: layer.fillEnabled, strokeEnabled: v) } }))
                }
                .font(.system(size: 11))
            }
            PropertySection(title: "Shape Properties", model: model, time: time, layer: layer,
                            specs: layer.editableProps.filter { !layer.transformProps.contains($0) }
                                .map(ParamSpec.init))
        }
    }
}

// MARK: - Animatable properties

struct PropertySection: View {
    let title: String
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    let specs: [ParamSpec]

    var body: some View {
        SectionBox(title: title) {
            PropertyRows(model: model, time: time, layer: layer, specs: specs)
        }
    }
}

struct PropertyRows: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    let specs: [ParamSpec]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(specs) { spec in
                PropertyEditorRow(model: model, time: time, layer: layer, spec: spec)
            }
        }
    }
}

// MARK: - Text

private struct TextSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    @State private var text = ""
    @FocusState private var editing: Bool

    static let fonts = ["Helvetica-Bold", "HelveticaNeue-Medium", "AvenirNext-Heavy", "AvenirNext-Regular", "Futura-Bold",
                        "GillSans-Bold", "DINAlternate-Bold", "Georgia-Bold", "Didot-Bold", "Menlo-Bold",
                        "AmericanTypewriter-Bold", "MarkerFelt-Wide", "Copperplate-Bold", "Baskerville-SemiBold"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Text") {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .frame(minHeight: 48, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
                    .focused($editing)
                    .onAppear { text = layer.text; takeFocusIfAsked() }
                    .onChange(of: layer.layerID) { _, _ in text = layer.text }
                    .onChange(of: model.focusTextOf) { _, _ in takeFocusIfAsked() }
                    // Undo (or a collaborator) changed the text: show it, so the next keystroke builds on it.
                    .onChange(of: layer.text) { _, new in if new != text { text = new } }
                    .onChange(of: text) { _, new in
                        guard new != layer.text else { return }
                        model.coalescedEdit("Edit Text") { _ = $0.setLayer(layer.layerID, text: new, font: layer.fontName, align: layer.textAlign) }
                    }
                HStack(spacing: 8) {
                    Menu {
                        ForEach(Self.fonts, id: \.self) { f in
                            Button { setFont(f) } label: { Text(f) }
                        }
                    } label: {
                        Text(layer.fontName).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Font (PostScript name)")
                    Picker("", selection: Binding(get: { layer.textAlign },
                                                  set: { a in model.edit { _ = $0.setLayer(layer.layerID, text: layer.text, font: layer.fontName, align: a) } })) {
                        Image(systemName: "text.alignleft").tag(MFTextAlign.left)
                        Image(systemName: "text.aligncenter").tag(MFTextAlign.center)
                        Image(systemName: "text.alignright").tag(MFTextAlign.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                }
                .font(.system(size: 11))
            }
            PropertySection(title: "Character", model: model, time: time, layer: layer,
                            specs: [MFProp.fontSize, .tracking, .lineHeight, .fillColor].map(ParamSpec.init))
            HStack(spacing: 12) {
                Toggle("Fill", isOn: Binding(get: { layer.fillEnabled },
                                             set: { v in model.edit { _ = $0.setLayer(layer.layerID, fillEnabled: v, strokeEnabled: layer.strokeEnabled) } }))
                Toggle("Stroke", isOn: Binding(get: { layer.strokeEnabled },
                                               set: { v in model.edit { _ = $0.setLayer(layer.layerID, fillEnabled: layer.fillEnabled, strokeEnabled: v) } }))
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            if layer.strokeEnabled {
                PropertySection(title: "Stroke", model: model, time: time, layer: layer,
                                specs: [MFProp.strokeColor, .strokeWidth].map(ParamSpec.init))
            }
        }
    }

    /// The Type tool just placed this layer: put the cursor in its text with "Text" selected, so typing replaces it.
    private func takeFocusIfAsked() {
        guard model.focusTextOf == layer.layerID else { return }
        DispatchQueue.main.async {
            model.focusTextOf = nil
            editing = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    private func setFont(_ f: String) {
        model.edit { _ = $0.setLayer(layer.layerID, text: layer.text, font: f, align: layer.textAlign) }
    }
}

private struct AudioSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo

    var body: some View {
        let asset = model.assets.first { $0.assetID == layer.assetID }
        let fps = max(model.comp.fps, 1)
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Audio") {
                HStack {
                    Image(systemName: asset?.missing == false ? "waveform" : "exclamationmark.triangle.fill")
                        .foregroundStyle(asset?.missing == false ? Theme.audio : Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset?.name ?? "Missing file").lineLimit(1)
                        if let a = asset {
                            Text(a.missing ? "Missing — \(a.path)" : Timecode.string(a.duration, fps: fps))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button {
                        model.edit { _ = $0.setLayer(layer.layerID, visible: !layer.visible) }
                    } label: {
                        Image(systemName: layer.visible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(layer.visible ? "Mute" : "Unmute")
                }
                .font(.system(size: 11))
                HStack {
                    Text("File starts at").foregroundStyle(.secondary)
                    ScrubField(value: layer.startTime, step: 1 / fps, precision: 2, suffix: " s",
                               onBegin: { model.closeCoalescedEdit() },
                               onChange: { v in model.edit { _ = $0.setLayer(layer.layerID, startTime: v) } },
                               onEnd: {})
                }
                .font(.system(size: 11))
                .help("Where the file's first sample sits on the timeline. Dragging the layer in the timeline moves it too; trimming its ends doesn't.")
            }
            PropertySection(title: "Levels", model: model, time: time, layer: layer, specs: [ParamSpec(.audioLevel)])
            Text("0 dB plays the file as recorded; −48 dB is silent. Keyframe the level to fade or duck.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct PrecompSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo

    var body: some View {
        let source = model.compositions.first { $0.compID == layer.sourceCompID }
        VStack(alignment: .leading, spacing: 10) {
            SectionBox(title: "Precomp") {
                HStack {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accent)
                    Text(source?.name ?? "Missing composition").lineLimit(1)
                    Spacer()
                    Button("Open") { model.openComposition(layer.sourceCompID, fromLayer: layer) }
                        .disabled(source == nil)
                        .help("Edit the source composition (double-click the layer in the timeline does the same)")
                }
                .font(.system(size: 11))
                Toggle("Collapse transformations", isOn: Binding(get: { layer.collapse },
                                                                 set: { v in model.edit { _ = $0.setPrecomp(layer.layerID, collapse: v, timeRemap: layer.timeRemapEnabled, startTime: layer.startTime) } }))
                    .help("Draw the source's layers straight into this composition (vector-sharp, not clipped to its frame)")
                Toggle("Time remapping", isOn: Binding(get: { layer.timeRemapEnabled },
                                                       set: { v in model.edit { _ = $0.setPrecomp(layer.layerID, collapse: layer.collapse, timeRemap: v, startTime: layer.startTime) } }))
                HStack {
                    Text("Starts at").foregroundStyle(.secondary)
                    ScrubField(value: layer.startTime, step: 1 / max(model.comp.fps, 1), precision: 2, suffix: " s",
                               onBegin: { model.closeCoalescedEdit() },
                               onChange: { v in model.edit { _ = $0.setPrecomp(layer.layerID, collapse: layer.collapse, timeRemap: layer.timeRemapEnabled, startTime: v) } },
                               onEnd: {})
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            if layer.timeRemapEnabled {
                PropertySection(title: "Time", model: model, time: time, layer: layer, specs: [ParamSpec(MFProp.timeRemap)])
            }
        }
    }
}

private struct AnimatorsSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text Animators").font(.system(size: 11, weight: .semibold))
                Spacer()
                Menu {
                    Button("Opacity") { add(.opacity) }
                    Button("Position") { add(.position) }
                    Button("Scale") { add(.scale) }
                    Button("Rotation") { add(.rotation) }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add an animator: animate Range Start / End / Offset to sweep it across the text")
            }
            if layer.animators.isEmpty {
                Text("Animate characters, words or lines: add an animator, then keyframe its Range Start, End or Offset. The Text presets in the Effects tab are ready-made examples.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(layer.animators, id: \.animatorID) { a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { a.enabled }, set: { v in set(a, enabled: v) }))
                            .labelsHidden().toggleStyle(.checkbox)
                        Text(a.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Button { model.edit { _ = $0.removeTextAnimator(a.animatorID, layer: layer.layerID) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove animator")
                    }
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { a.shape }, set: { v in set(a, shape: v) })) {
                            Text("Square").tag(MFSelectorShape.square)
                            Text("Ramp Up").tag(MFSelectorShape.rampUp)
                            Text("Ramp Down").tag(MFSelectorShape.rampDown)
                            Text("Triangle").tag(MFSelectorShape.triangle)
                            Text("Round").tag(MFSelectorShape.round)
                            Text("Smooth").tag(MFSelectorShape.smooth)
                        }
                        .labelsHidden()
                        Picker("", selection: Binding(get: { a.unit }, set: { v in set(a, unit: v) })) {
                            Text("Characters").tag(MFSelectorUnit.characters)
                            Text("Words").tag(MFSelectorUnit.words)
                            Text("Lines").tag(MFSelectorUnit.lines)
                        }
                        .labelsHidden()
                    }
                    .font(.system(size: 11))
                    PropertyRows(model: model, time: time, layer: layer, specs: a.params.map(ParamSpec.init))
                        .padding(.leading, 6)
                        .opacity(a.enabled ? 1 : 0.5)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
            }
        }
    }

    private func add(_ p: MFAnimatorPreset) { model.edit { _ = $0.addTextAnimator(p, layer: layer.layerID) } }
    private func set(_ a: MFAnimatorInfo, enabled: Bool? = nil, shape: MFSelectorShape? = nil, unit: MFSelectorUnit? = nil) {
        model.edit { _ = $0.setTextAnimator(a.animatorID, layer: layer.layerID, enabled: enabled ?? a.enabled,
                                             shape: shape ?? a.shape, unit: unit ?? a.unit) }
    }
}

// MARK: - Masks

private struct MasksSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Masks").font(.system(size: 11, weight: .semibold))
                Spacer()
                if layer.kind == .image { RotoBrushMenu(model: model, roto: model.roto, layer: layer) }
                Menu {
                    Button("Rectangle Mask") { model.addMask(.rectangle) }
                    Button("Ellipse Mask") { model.addMask(.ellipse) }
                    Button("Draw a Mask with the Pen (G)") { model.penDrawsMask = true; model.selectTool(.pen) }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add a mask (cuts the layer before effects)")
            }
            RotoBrushStatus(roto: model.roto)
            ForEach(layer.masks, id: \.maskID) { m in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { m.enabled },
                                                 set: { v in model.edit { _ = $0.setMask(m.maskID, layer: layer.layerID, enabled: v) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: m.tracked ? "figure.walk.motion" : m.shape == .path ? "scribble" : m.shape == .ellipse ? "circle.dashed" : "rectangle.dashed")
                            .foregroundStyle(Theme.keyframe)
                        Text(m.name).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(get: { m.mode },
                                                      set: { v in model.edit { _ = $0.setMask(m.maskID, layer: layer.layerID, mode: v, inverted: m.inverted) } })) {
                            ForEach([MFMaskMode.add, .subtract, .intersect, .difference], id: \.rawValue) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden().frame(width: 92)
                        Toggle("Inv", isOn: Binding(get: { m.inverted },
                                                    set: { v in model.edit { _ = $0.setMask(m.maskID, layer: layer.layerID, mode: m.mode, inverted: v) } }))
                            .toggleStyle(.button).help("Invert")
                        Button { model.edit { _ = $0.removeMask(m.maskID, layer: layer.layerID) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete mask")
                    }
                    .font(.system(size: 11))
                    MaskPathKeys(model: model, time: time, layer: layer, mask: m)
                    PropertyRows(model: model, time: time, layer: layer,
                                 specs: m.params.filter { m.shape == .rectangle || $0.key != "roundness" }.map(ParamSpec.init))
                        .padding(.leading, 6)
                        .opacity(m.enabled ? 1 : 0.5)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
            }
        }
    }
}

/// Rotoscoping a mask by hand: animate its outline, step between its keys, add or remove one. Moving
/// a point in the viewer at another time adds a key there.
private struct MaskPathKeys: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    let mask: MFMaskInfo

    var body: some View {
        let keys = mask.pathKeyTimes.map(\.doubleValue)
        let now = time.time
        let onKey = keys.contains { abs($0 - now) < 0.5 / model.comp.fps }
        HStack(spacing: 6) {
            Button {
                model.edit { _ = $0.setMaskPathAnimated(mask.maskID, layer: layer.layerID, animated: !mask.pathAnimated, time: now) }
            } label: {
                Image(systemName: "stopwatch").foregroundStyle(mask.pathAnimated ? Theme.keyframe : .secondary)
            }
            .buttonStyle(.borderless)
            .help(mask.pathAnimated ? "Stop animating the outline (keeps the shape at the playhead)"
                                    : "Animate the outline (rotoscope): then move its points at other frames")
            Text(mask.tracked ? "Mask Path · Roto Brush, frame by frame" : mask.pathAnimated ? "Mask Path · \(keys.count) key\(keys.count == 1 ? "" : "s")" : "Mask Path")
                .foregroundStyle(.secondary)
            Spacer()
            if !keys.isEmpty {
                Button { if let t = keys.last(where: { $0 < now - 1e-6 }) { model.time.isPlaying = false; model.time.time = t } } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless).help("Previous mask key")
                Button { if let t = keys.first(where: { $0 > now + 1e-6 }) { model.time.isPlaying = false; model.time.time = t } } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless).help("Next mask key")
            }
            if mask.pathAnimated && !mask.tracked {
                if onKey {
                    Button { model.edit { _ = $0.removeMaskPathKey(at: now, mask: mask.maskID, layer: layer.layerID) } } label: {
                        Image(systemName: "diamond.fill").foregroundStyle(Theme.keyframe)
                    }
                    .buttonStyle(.borderless).help("Delete the key at the playhead")
                } else {
                    Button {
                        let shape = model.engine.maskPath(mask.maskID, layer: layer.layerID, time: now)
                        model.edit { _ = $0.setMaskPath(mask.maskID, layer: layer.layerID, vertices: shape, time: now) }
                    } label: { Image(systemName: "diamond") }
                        .buttonStyle(.borderless).help("Add a key here with the current outline")
                }
            }
        }
        .font(.system(size: 11))
    }
}

/// Roto Brush ▸ Main Subject / People, for image and video layers.
private struct RotoBrushMenu: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var roto: RotoBrush
    let layer: MFLayerInfo

    var body: some View {
        Menu {
            ForEach(RotoBrush.Subject.allCases) { s in
                Button(s.rawValue) { Task { await roto.run(model: model, layerID: layer.layerID, subject: s) } }
            }
        } label: { Label("Roto Brush", systemImage: "wand.and.stars") }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(roto.progress != nil)
            .help(layer.isVideo ? "Find the subject in every frame of the work area (or the whole clip) and mask it"
                                : "Find the subject in this image and mask it")
    }
}

private struct RotoBrushStatus: View {
    @ObservedObject var roto: RotoBrush

    var body: some View {
        if let p = roto.progress {
            HStack(spacing: 8) {
                ProgressView(value: p).controlSize(.small)
                Text("Roto Brush \(Int(p * 100))%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Button("Stop") { roto.cancel() }.controlSize(.small)
            }
        } else if let m = roto.message {
            HStack {
                Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { roto.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Effects

private struct EffectsSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo

    var body: some View {
        let effects = layer.effects
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Effects").font(.system(size: 11, weight: .semibold))
                Spacer()
                EffectMenu(model: model)
            }
            if effects.isEmpty {
                Text("No effects. Add one here or double-click it in the Effects browser.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(effects.enumerated()), id: \.element.effectID) { index, fx in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { fx.enabled },
                                                 set: { v in model.edit { _ = $0.setEffect(fx.effectID, layer: layer.layerID, enabled: v) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                            .help("Enable / bypass")
                        Image(systemName: fx.type.icon).foregroundStyle(Theme.accent)
                        Text(fx.name).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button { model.edit { _ = $0.moveEffect(fx.effectID, layer: layer.layerID, to: index - 1) } } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0).help("Move up (runs earlier)")
                        Button { model.edit { _ = $0.moveEffect(fx.effectID, layer: layer.layerID, to: index + 1) } } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == effects.count - 1).help("Move down (runs later)")
                        Button { model.edit { _ = $0.removeEffect(fx.effectID, layer: layer.layerID) } } label: { Image(systemName: "trash") }
                            .help("Remove effect")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    PropertyRows(model: model, time: time, layer: layer, specs: fx.params.map(ParamSpec.init))
                        .padding(.leading, 6)
                        .opacity(fx.enabled ? 1 : 0.5)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
            }
        }
    }
}

struct EffectMenu: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Menu {
            let catalog = MFEngine.effectCatalog()
            ForEach(Array(Set(catalog.map(\.category))).sorted(), id: \.self) { cat in
                Section(cat) {
                    ForEach(catalog.filter { $0.category == cat }, id: \.type.rawValue) { e in
                        Button { model.applyEffect(e.type) } label: { Label(e.name, systemImage: e.type.icon) }
                    }
                }
            }
        } label: {
            Label("Add Effect", systemImage: "wand.and.stars")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.selectedLayer == nil || model.selectedLayer?.kind == .null)
    }
}

// MARK: - Property row (any animatable parameter)

struct PropertyEditorRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    let spec: ParamSpec

    var body: some View {
        let t = time.time
        let ref = spec.ref
        let animated = layer.isAnimatedRef(ref)
        let baked = layer.isBakedRef(ref)
        let keys = layer.keyframes(for: ref)
        let onKey = keys.contains { abs($0.time - t) < 0.5 / model.comp.fps }
        HStack(spacing: 6) {
            StopwatchButton(animated: animated, baked: baked) {
                model.closeCoalescedEdit()
                model.edit { _ = $0.set(animated: !animated, ref: ref, layer: layer.layerID, time: t) }
            }
            Text(spec.label)
                .font(.system(size: 11))
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
            if spec.isColor {
                ColorPicker("", selection: colorBinding(t), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 44)
            } else {
                let v = model.engine.value(of: ref, layer: layer.layerID, time: t)
                ForEach(0..<spec.dims, id: \.self) { i in
                    ScrubField(value: v[i], step: spec.step, precision: spec.precision, suffix: spec.unit,
                               onBegin: { model.closeCoalescedEdit(); model.engine.beginUndoGroup("Change \(spec.label)") },
                               onChange: { nv in set(component: i, to: nv, time: t) },
                               onEnd: { model.engine.endUndoGroup(); model.refresh() })
                }
            }
            Spacer(minLength: 0)
            if animated {
                keyNav(keys: keys, t: t, onKey: onKey)
            }
        }
    }

    private func set(component i: Int, to nv: Double, time t: Double) {
        let ref = spec.ref
        var v = model.engine.value(of: ref, layer: layer.layerID, time: t)
        v[i] = nv
        // Scale is linked by default (like most motion tools); hold Command to scale one axis.
        if spec.linkedScale, !NSEvent.modifierFlags.contains(.command) {
            let old = model.engine.value(of: ref, layer: layer.layerID, time: t)
            let other = 1 - i
            if old[i] != 0 { v[other] = old[other] * nv / old[i] } else { v[other] = nv }
        }
        model.edit { _ = $0.setRefValue(v, ref: ref, layer: layer.layerID, time: t) }
    }

    private func colorBinding(_ t: Double) -> Binding<Color> {
        let ref = spec.ref
        return Binding(get: { model.engine.value(of: ref, layer: layer.layerID, time: t).color },
                       set: { c in
                           model.coalescedEdit("Change \(spec.label)") {
                               _ = $0.setRefValue(MFValue(color: c), ref: ref, layer: layer.layerID, time: t)
                           }
                       })
    }

    @ViewBuilder
    private func keyNav(keys: [MFKeyframeInfo], t: Double, onKey: Bool) -> some View {
        let ref = spec.ref
        HStack(spacing: 2) {
            Button { if let k = keys.last(where: { $0.time < t - 1e-6 }) { model.time.time = k.time } } label: {
                Image(systemName: "chevron.left")
            }
            Button {
                if let k = keys.first(where: { abs($0.time - t) < 0.5 / model.comp.fps }) {
                    model.edit { _ = $0.removeKeyframe(at: k.index, ref: ref, layer: layer.layerID) }
                } else {
                    model.edit { _ = $0.addKeyframe(for: ref, layer: layer.layerID, time: t) }
                }
            } label: {
                Diamond().fill(onKey ? Theme.keyframe : Color.clear)
                    .overlay(Diamond().stroke(Theme.keyframe, lineWidth: 1))
                    .frame(width: 9, height: 9)
            }
            .help(onKey ? "Remove keyframe at playhead" : "Add keyframe at playhead")
            Button { if let k = keys.first(where: { $0.time > t + 1e-6 }) { model.time.time = k.time } } label: {
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }
}
