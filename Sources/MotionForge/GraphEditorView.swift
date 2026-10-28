import MFRender
import SwiftUI

/// Value-curve graph editor. Curves of the properties whose keyframes are selected (or, with
/// none selected, the selected layer's animated properties) over the timeline's visible time
/// range. Drag a key to change its time and value; drag a handle to set that side's ease
/// influence (horizontal) and speed (vertical: flatter = slower, past the next value = overshoot).
struct GraphEditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let mapper: TimeMapper

    private struct Target: Identifiable {
        let layer: MFLayerInfo
        let spec: ParamSpec
        var id: String { "\(layer.layerID)-\(spec.id)" }
    }

    private enum Hit {
        case key(Target, index: Int, component: Int)
        case handle(Target, index: Int, outgoing: Bool, component: Int)
    }

    private struct DragState {
        let hit: Hit
        let range: ClosedRange<Double>
        var address: MFKeyAddress
        let startTime: Double
        let startValue: MFValue
    }

    @State private var drag: DragState?
    private let pad: CGFloat = 18
    private static let colours: [Color] = [Color(red: 1, green: 0.42, blue: 0.42), Color(red: 0.45, green: 0.9, blue: 0.5),
                                           Color(red: 0.45, green: 0.65, blue: 1), Color(white: 0.75)]

    var body: some View {
        let targets = graphTargets()
        GeometryReader { geo in
            let height = geo.size.height
            let range = drag?.range ?? valueRange(targets)
            HStack(spacing: 0) {
                legend(targets)
                    .frame(width: TimelineView.nameWidth, alignment: .topLeading)
                Canvas { ctx, size in
                    draw(ctx, size: size, targets: targets, range: range)
                }
                .frame(width: mapper.width, height: height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in dragChanged(g, targets: targets, height: height, range: range) }
                    .onEnded { g in dragEnded(g) })
                Spacer(minLength: 0)
            }
        }
        .background(Theme.panel)
    }

    // MARK: Data

    private func graphTargets() -> [Target] {
        var out: [Target] = []
        var seen = Set<String>()
        func add(_ layer: MFLayerInfo, _ spec: ParamSpec) {
            guard spec.dims <= 4, out.count < 6, seen.insert("\(layer.layerID)-\(spec.id)").inserted else { return }
            out.append(Target(layer: layer, spec: spec))
        }
        let specsByRef: (MFLayerInfo) -> [ParamSpec] = { l in
            l.editableProps.map(ParamSpec.init) + l.animatedEffectAndMaskParams.map(ParamSpec.init)
        }
        if !model.selectedKeyframes.isEmpty {
            for k in model.selectedKeyframes {
                guard let l = model.layers.first(where: { $0.layerID == k.layer }),
                      let spec = specsByRef(l).first(where: { $0.ref == k.ref }) else { continue }
                add(l, spec)
            }
        } else if let l = model.selectedLayer {
            for spec in specsByRef(l) where l.isAnimatedRef(spec.ref) && !spec.isColor { add(l, spec) }
        }
        return out
    }

    private func value(_ t: Target, at time: Double) -> MFValue { model.engine.value(of: t.spec.ref, layer: t.layer.layerID, time: time) }

    private func valueRange(_ targets: [Target]) -> ClosedRange<Double> {
        var lo = Double.infinity, hi = -Double.infinity
        for t in targets {
            for k in t.layer.keyframes(for: t.spec.ref) {
                for c in 0..<t.spec.dims {
                    lo = min(lo, k.value[c])
                    hi = max(hi, k.value[c])
                }
            }
            for i in stride(from: 0, through: 1, by: 0.05) {  // overshoot between keys too
                let v = value(t, at: mapper.start + (mapper.end - mapper.start) * i)
                for c in 0..<t.spec.dims {
                    lo = min(lo, v[c])
                    hi = max(hi, v[c])
                }
            }
        }
        if !lo.isFinite { return 0...1 }
        if hi - lo < 1e-6 { return (lo - 1)...(hi + 1) }
        let m = (hi - lo) * 0.08
        return (lo - m)...(hi + m)
    }

    private func y(_ v: Double, _ h: CGFloat, _ r: ClosedRange<Double>) -> CGFloat {
        h - pad - CGFloat((v - r.lowerBound) / (r.upperBound - r.lowerBound)) * (h - 2 * pad)
    }

    private func v(_ y: CGFloat, _ h: CGFloat, _ r: ClosedRange<Double>) -> Double {
        r.lowerBound + Double((h - pad - y) / (h - 2 * pad)) * (r.upperBound - r.lowerBound)
    }

    /// The component that changes most over a segment carries its handles.
    private func dominant(_ a: MFKeyframeInfo, _ b: MFKeyframeInfo, dims: Int) -> Int {
        (0..<dims).max { abs(b.value[$0] - a.value[$0]) < abs(b.value[$1] - a.value[$1]) } ?? 0
    }

    /// Handle positions (time, value) of the segment a -> b, from the normalised timing curve.
    private func handles(_ a: MFKeyframeInfo, _ b: MFKeyframeInfo, c: Int) -> (out: (Double, Double)?, inn: (Double, Double)?) {
        let span = b.time - a.time, dv = b.value[c] - a.value[c]
        var out: (Double, Double)?, inn: (Double, Double)?
        if a.outInterp == .bezier { out = (a.time + a.easeOut * span, a.value[c] + a.easeOut * a.outSlope * dv) }
        if b.inInterp == .bezier { inn = (b.time - b.easeIn * span, a.value[c] + (1 - b.easeIn * b.inSlope) * dv) }
        return (out, inn)
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, targets: [Target], range: ClosedRange<Double>) {
        let h = size.height
        // Horizontal value grid.
        for i in 0...4 {
            let val = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / 4
            let yy = y(val, h, range)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: yy)); $0.addLine(to: CGPoint(x: size.width, y: yy)) },
                       with: .color(.white.opacity(0.06)), lineWidth: 1)
            ctx.draw(Text(String(format: "%.1f", val)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                     at: CGPoint(x: 4, y: yy - 6), anchor: .leading)
        }
        let px = mapper.x(time.time)
        ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: h)) }, with: .color(Theme.accent), lineWidth: 1)

        for (ti, t) in targets.enumerated() {
            // Curves, sampled every 2 px.
            for c in 0..<t.spec.dims {
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    let p = CGPoint(x: x, y: y(value(t, at: mapper.t(x))[c], h, range))
                    if x == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    x += 2
                }
                let colour = t.spec.dims == 1 ? Self.colours[(ti + 2) % Self.colours.count] : Self.colours[c]
                ctx.stroke(path, with: .color(colour.opacity(0.9)), lineWidth: 1.5)
            }
            let keys = t.layer.keyframes(for: t.spec.ref)
            // Handles.
            for i in 0..<max(0, keys.count - 1) {
                let a = keys[i], b = keys[i + 1]
                let c = dominant(a, b, dims: t.spec.dims)
                let hs = handles(a, b, c: c)
                for (h0, anchor) in [(hs.out, a), (hs.inn, b)] {
                    guard let h0 else { continue }
                    let kp = CGPoint(x: mapper.x(anchor.time), y: y(anchor.value[c], h, range))
                    let hp = CGPoint(x: mapper.x(h0.0), y: y(h0.1, h, range))
                    ctx.stroke(Path { $0.move(to: kp); $0.addLine(to: hp) }, with: .color(Theme.keyframe.opacity(0.8)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: hp.x - 3.5, y: hp.y - 3.5, width: 7, height: 7)), with: .color(Theme.keyframe))
                }
            }
            // Keys.
            for k in keys {
                let selected = model.selectedKeyframes.contains(KeyframeRef(layer: t.layer.layerID, ref: t.spec.ref, index: k.index))
                for c in 0..<t.spec.dims {
                    let p = CGPoint(x: mapper.x(k.time), y: y(k.value[c], h, range))
                    let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                    ctx.fill(Path(r), with: .color(selected ? Theme.accent : .white))
                    ctx.stroke(Path(r), with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
        }
    }

    private func legend(_ targets: [Target]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("GRAPH EDITOR").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Ease") { setInterp(.bezier, .bezier) }.help("Easy ease the selected keys")
                Button("Linear") { setInterp(.linear, .linear) }
            }
            .controlSize(.small)
            if targets.isEmpty {
                Text("Select keyframes (or a layer with animation) to see its curves.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(targets.enumerated()), id: \.element.id) { ti, t in
                HStack(spacing: 6) {
                    if t.spec.dims == 1 {
                        Circle().fill(Self.colours[(ti + 2) % Self.colours.count]).frame(width: 8, height: 8)
                    } else {
                        HStack(spacing: 2) { ForEach(0..<t.spec.dims, id: \.self) { c in Circle().fill(Self.colours[c]).frame(width: 6, height: 6) } }
                    }
                    Text("\(t.layer.name) · \(t.spec.label)").font(.system(size: 11)).lineLimit(1)
                }
            }
            Text("Drag keys to retime or change values; drag handles to shape the ease (up past the next value overshoots).")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
    }

    // MARK: Interaction

    private func hitTest(_ p: CGPoint, targets: [Target], height: CGFloat, range: ClosedRange<Double>) -> Hit? {
        func near(_ q: CGPoint) -> Bool { hypot(q.x - p.x, q.y - p.y) <= 6 }
        for t in targets {
            let keys = t.layer.keyframes(for: t.spec.ref)
            for i in 0..<max(0, keys.count - 1) {
                let a = keys[i], b = keys[i + 1]
                let c = dominant(a, b, dims: t.spec.dims)
                let hs = handles(a, b, c: c)
                if let o = hs.out, near(CGPoint(x: mapper.x(o.0), y: y(o.1, height, range))) { return .handle(t, index: a.index, outgoing: true, component: c) }
                if let n = hs.inn, near(CGPoint(x: mapper.x(n.0), y: y(n.1, height, range))) { return .handle(t, index: b.index, outgoing: false, component: c) }
            }
            for k in keys {
                for c in 0..<t.spec.dims where near(CGPoint(x: mapper.x(k.time), y: y(k.value[c], height, range))) {
                    return .key(t, index: k.index, component: c)
                }
            }
        }
        return nil
    }

    private func dragChanged(_ g: DragGesture.Value, targets: [Target], height: CGFloat, range: ClosedRange<Double>) {
        if drag == nil {
            guard let hit = hitTest(g.startLocation, targets: targets, height: height, range: range) else { return }
            let (t, index): (Target, Int) = {
                switch hit {
                case .key(let t, let i, _), .handle(let t, let i, _, _): return (t, i)
                }
            }()
            guard let k = t.layer.keyframes(for: t.spec.ref).first(where: { $0.index == index }) else { return }
            let ref = KeyframeRef(layer: t.layer.layerID, ref: t.spec.ref, index: index)
            if !model.selectedKeyframes.contains(ref) { model.selectKeyframe(ref, mode: SelectMode.current) }
            drag = DragState(hit: hit, range: range, address: ref.address, startTime: k.time, startValue: k.value)
            model.engine.beginUndoGroup("Graph Edit")
        }
        guard var d = drag else { return }
        switch d.hit {
        case .key(let t, _, let c):
            let newTime = model.snap(d.startTime + Double(g.translation.width / mapper.pxPerSecond))
            var val = d.startValue
            val[c] = v(g.location.y, height, d.range)
            model.edit { e in
                _ = e.setKeyframeValue(at: d.address.index, ref: t.spec.ref, layer: t.layer.layerID, value: val)
                let now = currentTime(of: d.address)
                if abs(newTime - now) > 1e-9, let moved = e.moveKeyframes([d.address], by: newTime - now).first { d.address = moved }
            }
            model.selectedKeyframes = [KeyframeRef(d.address)]
        case .handle(let t, _, let outgoing, let c):
            let keys = model.engine.layer(withID: t.layer.layerID)?.keyframes(for: t.spec.ref) ?? []
            let i = d.address.index
            guard i < keys.count else { break }
            let (a, b) = outgoing ? (keys[i], i + 1 < keys.count ? keys[i + 1] : nil) : (i > 0 ? keys[i - 1] : nil, keys[i])
            guard let a, let b else { break }
            let span = b.time - a.time, dv = b.value[c] - a.value[c]
            let tm = mapper.t(g.location.x), val = v(g.location.y, height, d.range)
            if outgoing {
                let inf = min(max((tm - a.time) / span, 0.01), 1)
                let slope = abs(dv) > 1e-9 ? ((val - a.value[c]) / dv) / inf : a.outSlope
                model.edit { _ = $0.setKeyframeEase(at: i, ref: t.spec.ref, layer: t.layer.layerID, outgoing: true, influence: inf, slope: slope) }
            } else {
                let inf = min(max((b.time - tm) / span, 0.01), 1)
                let slope = abs(dv) > 1e-9 ? (1 - (val - a.value[c]) / dv) / inf : b.inSlope
                model.edit { _ = $0.setKeyframeEase(at: i, ref: t.spec.ref, layer: t.layer.layerID, outgoing: false, influence: inf, slope: slope) }
            }
        }
        drag = d
    }

    private func currentTime(of a: MFKeyAddress) -> Double {
        model.engine.layer(withID: a.layerID)?.keyframes(for: a.ref).first { $0.index == a.index }?.time ?? 0
    }

    private func dragEnded(_ g: DragGesture.Value) {
        if drag != nil {
            model.engine.endUndoGroup()
            if abs(g.translation.width) < 2 && abs(g.translation.height) < 2, let t = drag?.startTime { model.time.time = t }
            model.refresh()
        }
        drag = nil
    }

    private func setInterp(_ i: MFInterp, _ o: MFInterp) {
        let keys = model.selectedKeyframes.map(\.address)
        guard !keys.isEmpty else { return }
        model.edit { _ = $0.setInterpolation(of: keys, in: i, out: o, setIn: true, setOut: true) }
    }
}
