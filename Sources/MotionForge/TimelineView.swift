import MFRender
import SwiftUI

/// Maps composition time to x positions in the track area.
struct TimeMapper {
    var start: Double
    var end: Double
    var width: CGFloat
    var pxPerSecond: CGFloat { width / CGFloat(max(1e-6, end - start)) }
    func x(_ t: Double) -> CGFloat { CGFloat(t - start) * pxPerSecond }
    func t(_ x: CGFloat) -> Double { start + Double(x / pxPerSecond) }
}

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    @State private var zoom: Double = 1        // 1 = whole composition visible
    @State private var viewStart: Double = 0

    static let nameWidth: CGFloat = 270
    static let rowHeight: CGFloat = 24
    static let propRowHeight: CGFloat = 21

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, time: time, zoom: $zoom)
            GeometryReader { geo in
                let trackWidth = max(50, geo.size.width - Self.nameWidth - 12)
                let visible = model.comp.duration / zoom
                let start = min(max(0, viewStart), max(0, model.comp.duration - visible))
                let mapper = TimeMapper(start: start, end: start + visible, width: trackWidth)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Layer").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .frame(width: Self.nameWidth, alignment: .leading)
                        RulerView(model: model, time: time, perf: model.perf, mapper: mapper)
                            .frame(width: trackWidth)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 26)
                    .background(Theme.panelDark)
                    if zoom > 1 {
                        NavigatorBar(duration: model.comp.duration, start: start, visible: visible, width: trackWidth) { s in
                            viewStart = s
                        }
                        .padding(.leading, Self.nameWidth)
                    }
                    Divider()
                    ZStack(alignment: .topLeading) {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(model.layers, id: \.layerID) { layer in
                                    LayerRows(model: model, time: time, layer: layer, mapper: mapper)
                                }
                            }
                        }
                        .background(Theme.panel.onTapGesture {
                            model.selection = nil
                            model.selectedKeyframe = nil
                        })
                        if model.layers.isEmpty {
                            Text("Add a shape from the Layer menu or toolbar, or drop images on the viewer.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        PlayheadLine(time: time, mapper: mapper)
                            .offset(x: Self.nameWidth)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: time.time) { _, t in
                    // Keep the playhead in view while zoomed.
                    if zoom > 1, t < mapper.start || t > mapper.end { viewStart = max(0, t - visible * 0.1) }
                }
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    @Binding var zoom: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(Timecode.string(time.time, fps: model.comp.fps))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.value)
                .frame(width: 96, alignment: .leading)
            Text("frame \(Int((time.time * model.comp.fps).rounded()))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            HStack(spacing: 6) {
                iconButton("backward.end.fill", "Go to start (Home)") { model.goToStart() }
                iconButton("backward.frame.fill", "Previous frame (Page Up)") { model.stepFrames(-1) }
                iconButton(time.isPlaying ? "pause.fill" : "play.fill", "Play / Pause (Space)") { model.togglePlayback() }
                iconButton("forward.frame.fill", "Next frame (Page Down)") { model.stepFrames(1) }
                iconButton("forward.end.fill", "Go to end (End)") { model.goToEnd() }
                Toggle(isOn: $time.loop) { Image(systemName: "repeat") }
                    .toggleStyle(.button).help("Loop playback")
            }
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...32).frame(width: 120).help("Timeline zoom")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.panelDark)
    }

    private func iconButton(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 18) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

// MARK: - Ruler & playhead

private struct RulerView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    @ObservedObject var perf: PerfModel
    let mapper: TimeMapper

    var body: some View {
        Canvas { ctx, size in
            let fps = model.comp.fps
            let frameW = mapper.pxPerSecond / CGFloat(fps)
            // Pick a tick step (in frames) at least ~8 px apart; label every 5th-ish step.
            let candidates: [Double] = [1, 2, 5, 10, 15, fps, fps * 2, fps * 5, fps * 10, fps * 30, fps * 60]
            let step = candidates.first { CGFloat($0) * frameW >= 8 } ?? fps * 60
            let labelStep = candidates.first { CGFloat($0) * frameW >= 70 } ?? fps * 60
            var f = (mapper.start * fps / step).rounded(.down) * step
            while Double(f) / fps <= mapper.end + 1e-9 {
                let x = mapper.x(f / fps)
                let major = f.truncatingRemainder(dividingBy: labelStep) == 0
                ctx.fill(Path(CGRect(x: x, y: major ? 12 : 19, width: 1, height: major ? 14 : 7)),
                         with: .color(.white.opacity(major ? 0.45 : 0.22)))
                if major {
                    ctx.draw(Text(Timecode.string(f / fps, fps: fps)).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary), at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                }
                f += step
            }
            // Frames in the frame cache (current state, current preview resolution)
            let cached = perf.cachedFrames
            if !cached.isEmpty {
                for range in cached.rangeView {
                    let x0 = mapper.x(Double(range.lowerBound) / fps), x1 = mapper.x(Double(range.upperBound) / fps)
                    if x1 < 0 || x0 > size.width { continue }
                    ctx.fill(Path(CGRect(x: x0, y: size.height - 3, width: max(1, x1 - x0), height: 3)),
                             with: .color(Color(red: 0.30, green: 0.80, blue: 0.45)))
                }
            }
            // Playhead handle
            let px = mapper.x(time.time)
            var head = Path()
            head.move(to: CGPoint(x: px - 6, y: size.height - 10))
            head.addLine(to: CGPoint(x: px + 6, y: size.height - 10))
            head.addLine(to: CGPoint(x: px, y: size.height))
            head.closeSubpath()
            ctx.fill(head, with: .color(Theme.accent))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            time.isPlaying = false
            time.time = model.snap(mapper.t(g.location.x))
        })
        .help("Drag to scrub")
    }
}

private struct PlayheadLine: View {
    @ObservedObject var time: TimeModel
    let mapper: TimeMapper
    var body: some View {
        let x = mapper.x(time.time)
        Rectangle().fill(Theme.accent).frame(width: 1)
            .frame(maxHeight: .infinity)
            .offset(x: x)
            .opacity(x >= 0 && x <= mapper.width ? 1 : 0)
    }
}

private struct NavigatorBar: View {
    let duration: Double
    let start: Double
    let visible: Double
    let width: CGFloat
    let onScroll: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        let k = width / CGFloat(duration)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.06)).frame(width: width, height: 6)
            Capsule().fill(Color.white.opacity(0.35))
                .frame(width: max(12, CGFloat(visible) * k), height: 6)
                .offset(x: CGFloat(start) * k)
                .gesture(DragGesture().onChanged { g in
                    if dragStart == nil { dragStart = start }
                    onScroll(max(0, min(duration - visible, (dragStart ?? start) + Double(g.translation.width / k))))
                }.onEnded { _ in dragStart = nil })
        }
        .frame(width: width, height: 12, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Layer rows

private struct LayerRows: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    let mapper: TimeMapper

    var body: some View {
        let expanded = model.expandedLayers.contains(layer.layerID)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LayerNameCell(model: model, layer: layer, expanded: expanded)
                    .frame(width: TimelineView.nameWidth, height: TimelineView.rowHeight)
                LayerBar(model: model, layer: layer, mapper: mapper)
                    .frame(width: mapper.width, height: TimelineView.rowHeight)
                Spacer(minLength: 0)
            }
            .background(model.selection == layer.layerID ? Theme.rowSelected.opacity(0.45) : Theme.row)
            if expanded {
                ForEach(trackSpecs) { spec in
                    PropertyTrackRow(model: model, time: time, layer: layer, spec: spec, mapper: mapper)
                }
            }
            Divider().opacity(0.4)
        }
    }

    private func isCoreTransform(_ p: MFProp) -> Bool {
        [.anchorPoint, .position, .scale, .rotation, .opacity].contains(p)
    }

    /// Transform rows always; other layer properties, mask and effect parameters once animated.
    private var trackSpecs: [ParamSpec] {
        layer.editableProps.filter { layer.isAnimated($0) || isCoreTransform($0) }.map(ParamSpec.init)
            + layer.animatedEffectAndMaskParams.map(ParamSpec.init)
    }
}

private struct LayerNameCell: View {
    @ObservedObject var model: EditorModel
    let layer: MFLayerInfo
    let expanded: Bool
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.edit { _ = $0.setLayer(layer.layerID, visible: !layer.visible) }
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.visible ? .primary : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("Show / hide")
            Button {
                if expanded { model.expandedLayers.remove(layer.layerID) } else { model.expandedLayers.insert(layer.layerID) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: layer.icon).foregroundStyle(.secondary).frame(width: 16)
            if renaming {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        model.edit { _ = $0.setLayer(layer.layerID, name: name) }
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
            } else {
                Text(layer.name).lineLimit(1)
                    .onTapGesture(count: 2) {
                        name = layer.name
                        renaming = true
                    }
            }
            Spacer(minLength: 4)
            if layer.parentID != 0, let p = model.layers.first(where: { $0.layerID == layer.parentID }) {
                Label(p.name, systemImage: "link").labelStyle(.titleAndIcon)
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            if layer.blend != .normal {
                Text(blendName(layer.blend)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if layer.matteLayerID != 0, let m = model.layers.first(where: { $0.layerID == layer.matteLayerID }) {
                Label(m.name, systemImage: "circle.lefthalf.striped.horizontal").labelStyle(.titleAndIcon)
                    .font(.system(size: 9)).foregroundStyle(Theme.keyframe).lineLimit(1)
                    .help("\(layer.matteMode.label) from “\(m.name)”")
            }
            if !layer.masks.isEmpty {
                Image(systemName: "rectangle.dashed").font(.system(size: 9)).foregroundStyle(Theme.keyframe)
                    .help("\(layer.masks.count) mask(s)")
            }
            if !layer.effects.isEmpty {
                Text("fx").font(.system(size: 9, weight: .bold, design: .serif)).foregroundStyle(Theme.accent)
                    .help(layer.effects.map(\.name).joined(separator: ", "))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = layer.layerID
            model.selectedKeyframe = nil
        }
        .contextMenu { LayerContextMenu(model: model, layer: layer) }
    }
}

struct LayerContextMenu: View {
    @ObservedObject var model: EditorModel
    let layer: MFLayerInfo
    var body: some View {
        Button("Duplicate") { model.selection = layer.layerID; model.duplicateSelection() }
        Button("Delete") { model.selection = layer.layerID; model.selectedKeyframe = nil; model.deleteSelection() }
        Divider()
        Button("Bring Forward") { model.selection = layer.layerID; model.moveSelection(by: -1) }
        Button("Send Backward") { model.selection = layer.layerID; model.moveSelection(by: 1) }
        Divider()
        Button("Trim In to Playhead") {
            model.edit { _ = $0.setLayer(layer.layerID, inPoint: model.time.time, outPoint: layer.outPoint) }
        }
        Button("Trim Out to Playhead") {
            model.edit { _ = $0.setLayer(layer.layerID, inPoint: layer.inPoint, outPoint: model.time.time) }
        }
    }
}

func blendName(_ m: MFBlendMode) -> String {
    switch m {
    case .add: return "Add"
    case .multiply: return "Multiply"
    case .screen: return "Screen"
    case .overlay: return "Overlay"
    case .darken: return "Darken"
    case .lighten: return "Lighten"
    default: return "Normal"
    }
}

/// In/out bar: drag the body to slide, drag either end to trim. Snaps to frames.
private struct LayerBar: View {
    @ObservedObject var model: EditorModel
    let layer: MFLayerInfo
    let mapper: TimeMapper
    @State private var drag: (inPoint: Double, outPoint: Double)?

    var body: some View {
        let x0 = max(0, mapper.x(layer.inPoint))
        let x1 = min(mapper.width, mapper.x(layer.outPoint))
        let selected = model.selection == layer.layerID
        ZStack(alignment: .leading) {
            if x1 > x0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill((selected ? Theme.barSelected : Theme.bar).opacity(layer.visible ? 1 : 0.4))
                    .frame(width: x1 - x0, height: TimelineView.rowHeight - 8)
                    .offset(x: x0)
                    .gesture(dragGesture(mode: .move))
                // trim handles
                handle.offset(x: x0).gesture(dragGesture(mode: .trimIn))
                handle.offset(x: x1 - 6).gesture(dragGesture(mode: .trimOut))
                // summary of keyframes across properties
                ForEach(layer.allKeyframeTimes.map(\.doubleValue), id: \.self) { t in
                    if t >= mapper.start && t <= mapper.end {
                        Diamond().fill(Theme.keyframe.opacity(0.85)).frame(width: 7, height: 7)
                            .offset(x: mapper.x(t) - 3.5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = layer.layerID
            model.selectedKeyframe = nil
        }
        .contextMenu { LayerContextMenu(model: model, layer: layer) }
    }

    private var handle: some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 6, height: TimelineView.rowHeight)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private enum Mode { case move, trimIn, trimOut }

    private func dragGesture(mode: Mode) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if drag == nil {
                    drag = (layer.inPoint, layer.outPoint)
                    model.selection = layer.layerID
                    model.engine.beginUndoGroup(mode == .move ? "Move Layer in Time" : "Trim Layer")
                }
                guard let d = drag else { return }
                let fps = model.comp.fps
                let dt = (Double(g.translation.width / mapper.pxPerSecond) * fps).rounded() / fps
                var i = d.inPoint, o = d.outPoint
                switch mode {
                case .move: i += dt; o += dt
                case .trimIn: i = min(d.inPoint + dt, d.outPoint - 1 / fps)
                case .trimOut: o = max(d.outPoint + dt, d.inPoint + 1 / fps)
                }
                model.edit { _ = $0.setLayer(layer.layerID, inPoint: i, outPoint: o) }
            }
            .onEnded { _ in
                drag = nil
                model.engine.endUndoGroup()
                model.refresh()
            }
    }
}

// MARK: - Property rows with keyframes

private struct PropertyTrackRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let layer: MFLayerInfo
    let spec: ParamSpec
    let mapper: TimeMapper

    var body: some View {
        let ref = spec.ref
        let animated = layer.isAnimatedRef(ref)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                StopwatchButton(animated: animated) {
                    model.edit { _ = $0.set(animated: !animated, ref: ref, layer: layer.layerID, time: time.time) }
                }
                Text(spec.label).lineLimit(1)
                Spacer(minLength: 4)
                Text(valueSummary).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.value).lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.leading, 44)
            .padding(.trailing, 8)
            .frame(width: TimelineView.nameWidth, height: TimelineView.propRowHeight)
            ZStack(alignment: .leading) {
                Color.clear
                ForEach(layer.keyframes(for: ref), id: \.index) { k in
                    if k.time >= mapper.start - 1e-9 && k.time <= mapper.end + 1e-9 {
                        KeyframeHandle(model: model, layer: layer, spec: spec, key: k, mapper: mapper)
                            .offset(x: mapper.x(k.time) - 7)
                    }
                }
            }
            .frame(width: mapper.width, height: TimelineView.propRowHeight)
            Spacer(minLength: 0)
        }
        .background(Theme.panel)
    }

    private var valueSummary: String {
        let v = model.engine.value(of: spec.ref, layer: layer.layerID, time: time.time)
        if spec.isColor { return String(format: "#%02X%02X%02X", Int(v.x * 255), Int(v.y * 255), Int(v.z * 255)) }
        let parts = (0..<spec.dims).map { String(format: "%.\(spec.precision)f", v[$0]) }
        return parts.joined(separator: ", ") + spec.unit
    }
}

private struct KeyframeHandle: View {
    @ObservedObject var model: EditorModel
    let layer: MFLayerInfo
    let spec: ParamSpec
    let key: MFKeyframeInfo
    let mapper: TimeMapper
    @State private var dragIndex: Int?
    @State private var dragStartTime = 0.0

    var body: some View {
        let prop = spec.ref
        let ref = KeyframeRef(layer: layer.layerID, ref: prop, index: key.index)
        let selected = model.selectedKeyframe == ref
        KeyframeGlyph(interp: key.outInterp == .hold ? .hold : (key.inInterp == .bezier || key.outInterp == .bezier ? .bezier : .linear),
                      selected: selected)
            .frame(width: 14, height: TimelineView.propRowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragIndex == nil {
                            dragIndex = key.index
                            dragStartTime = key.time
                            model.selection = layer.layerID
                            model.selectedKeyframe = ref
                            model.engine.beginUndoGroup("Move Keyframe")
                        }
                        guard let idx = dragIndex else { return }
                        let t = model.snap(dragStartTime + Double(g.translation.width / mapper.pxPerSecond))
                        let newIndex = model.engine.moveKeyframe(at: idx, ref: prop, layer: layer.layerID, toTime: t)
                        if newIndex >= 0 {
                            dragIndex = newIndex
                            model.selectedKeyframe = KeyframeRef(layer: layer.layerID, ref: prop, index: newIndex)
                        }
                        model.refresh()
                    }
                    .onEnded { g in
                        model.engine.endUndoGroup()
                        if abs(g.translation.width) < 2 { model.time.time = key.time }  // click jumps to the key
                        dragIndex = nil
                        model.refresh()
                    }
            )
            .contextMenu {
                Button("Linear") { setInterp(.linear, .linear) }
                Button("Easy Ease") { setInterp(.bezier, .bezier) }
                Button("Ease In") { setInterp(.bezier, key.outInterp == .hold ? .linear : key.outInterp) }
                Button("Ease Out") { setInterp(key.inInterp, .bezier) }
                Button("Hold") { setInterp(key.inInterp, .hold) }
                Divider()
                Button("Delete Keyframe") {
                    model.edit { _ = $0.removeKeyframe(at: key.index, ref: prop, layer: layer.layerID) }
                    model.selectedKeyframe = nil
                }
            }
            .help("\(spec.label) keyframe at \(Timecode.string(key.time, fps: model.comp.fps)) — drag to retime, right-click for easing")
    }

    private func setInterp(_ i: MFInterp, _ o: MFInterp) {
        model.edit { _ = $0.setKeyframeInterpolationAt(key.index, ref: spec.ref, layer: layer.layerID, in: i, out: o) }
    }
}
