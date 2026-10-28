import MFRender
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: model.selectedLayer == nil ? "Composition" : "Properties")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let layer = model.selectedLayer {
                        LayerSection(model: model, layer: layer)
                        PropertySection(title: "Transform", model: model, time: time, layer: layer,
                                        specs: [MFProp.anchorPoint, .position, .scale, .rotation, .opacity].map(ParamSpec.init))
                        if layer.kind == .shape {
                            ShapeSection(model: model, time: time, layer: layer)
                        }
                        if layer.kind != .null {
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
                Picker("", selection: Binding(get: { layer.shape },
                                              set: { s in model.edit { _ = $0.setLayer(layer.layerID, shapeType: s) } })) {
                    Image(systemName: "rectangle").tag(MFShapeType.rectangle)
                    Image(systemName: "circle").tag(MFShapeType.ellipse)
                    Image(systemName: "hexagon").tag(MFShapeType.polygon)
                    Image(systemName: "star").tag(MFShapeType.star)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 14) {
                    Toggle("Fill", isOn: Binding(get: { layer.fillEnabled },
                                                 set: { v in model.edit { _ = $0.setLayer(layer.layerID, fillEnabled: v, strokeEnabled: layer.strokeEnabled) } }))
                    Toggle("Stroke", isOn: Binding(get: { layer.strokeEnabled },
                                                   set: { v in model.edit { _ = $0.setLayer(layer.layerID, fillEnabled: layer.fillEnabled, strokeEnabled: v) } }))
                }
                .font(.system(size: 11))
            }
            PropertySection(title: "Shape Properties", model: model, time: time, layer: layer,
                            specs: layer.editableProps.filter { ![.anchorPoint, .position, .scale, .rotation, .opacity].contains($0) }
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
                Menu {
                    Button("Rectangle Mask") { model.addMask(.rectangle) }
                    Button("Ellipse Mask") { model.addMask(.ellipse) }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add a mask (cuts the layer before effects)")
            }
            ForEach(layer.masks, id: \.maskID) { m in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { m.enabled },
                                                 set: { v in model.edit { _ = $0.setMask(m.maskID, layer: layer.layerID, enabled: v) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: m.shape == .ellipse ? "circle.dashed" : "rectangle.dashed").foregroundStyle(Theme.keyframe)
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
        let keys = layer.keyframes(for: ref)
        let onKey = keys.contains { abs($0.time - t) < 0.5 / model.comp.fps }
        HStack(spacing: 6) {
            StopwatchButton(animated: animated) {
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
