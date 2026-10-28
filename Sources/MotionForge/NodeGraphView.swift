import MFRender
import SwiftUI

/// Node workspace: the composition drawn as a graph you can edit. Each layer is a chain
/// Source → Masks → Effects that merges into the Composite node in stacking order (top input =
/// top layer). Track mattes and parenting are wires into a layer's matte / parent sockets.
/// It edits the same document as the timeline — it is a view of the layer stack, not a second
/// compositing engine.
struct NodeGraphView: View {
    @ObservedObject var model: EditorModel
    @State private var offsets: [String: CGSize] = [:]  // user-dragged node positions
    @State private var nodeDrag: (id: String, start: CGSize)?
    @State private var wire: (from: UInt64, to: CGPoint)?

    private struct Node: Identifiable {
        enum Kind { case source, mask, effect }
        let id: String
        let kind: Kind
        let layer: MFLayerInfo
        let title: String
        let subtitle: String
        let enabled: Bool
        let objectID: UInt64  // mask / effect id
        var frame: CGRect
    }

    private static let nodeSize = CGSize(width: 150, height: 54)
    private static let rowHeight: CGFloat = 92

    var body: some View {
        let (nodes, composite) = layout()
        let size = CGSize(width: composite.maxX + 80, height: max(composite.maxY, CGFloat(model.layers.count) * Self.rowHeight) + 80)
        // The header keeps the scroll view off the window's top edge; a scroll view touching it
        // extends under the toolbar.
        VStack(spacing: 0) {
            HStack {
                Text("NODES · drag a layer's ● output onto another layer's matte or parent socket, or onto a Composite slot to restack")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.panelDark)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in drawWires(ctx, nodes: nodes, composite: composite) }
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                    ForEach(nodes) { n in nodeView(n) }
                    compositeView(composite)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .coordinateSpace(name: "nodes")
            }
            .background(Color(white: 0.09))
        }
        .clipped()
    }

    // MARK: Layout

    private func layout() -> ([Node], CGRect) {
        var nodes: [Node] = []
        var maxX: CGFloat = 0
        for (row, l) in model.layers.enumerated() {
            let y = 50 + CGFloat(row) * Self.rowHeight
            var x: CGFloat = 60
            func place(_ id: String) -> CGRect {
                let o = offsets[id] ?? .zero
                return CGRect(origin: CGPoint(x: x + o.width, y: y + o.height), size: Self.nodeSize)
            }
            let kind = l.kind == .text ? "Text" : l.kind == .image ? "Image" : l.kind == .null ? "Null" : "Shape"
            var sub = kind
            if l.matteLayerID != 0, let m = model.layers.first(where: { $0.layerID == l.matteLayerID }) { sub += " · matte: \(m.name)" }
            nodes.append(Node(id: "s\(l.layerID)", kind: .source, layer: l, title: l.name, subtitle: sub, enabled: l.visible,
                              objectID: 0, frame: place("s\(l.layerID)")))
            x += 180
            for m in l.masks {
                nodes.append(Node(id: "m\(m.maskID)", kind: .mask, layer: l, title: m.name, subtitle: "Mask · \(m.mode.label)\(m.inverted ? " · inv" : "")",
                                  enabled: m.enabled, objectID: m.maskID, frame: place("m\(m.maskID)")))
                x += 170
            }
            for e in l.effects {
                nodes.append(Node(id: "e\(e.effectID)", kind: .effect, layer: l, title: e.name, subtitle: "Effect",
                                  enabled: e.enabled, objectID: e.effectID, frame: place("e\(e.effectID)")))
                x += 170
            }
            maxX = max(maxX, x)
        }
        let o = offsets["composite"] ?? .zero
        let height = 44 + CGFloat(max(1, model.layers.count)) * 26
        let composite = CGRect(x: maxX + 80 + o.width, y: 50 + o.height, width: 170, height: height)
        return (nodes, composite)
    }

    private func compositeSlot(_ composite: CGRect, _ index: Int) -> CGPoint {
        CGPoint(x: composite.minX, y: composite.minY + 36 + CGFloat(index) * 26)
    }
    private func outSocket(_ f: CGRect) -> CGPoint { CGPoint(x: f.maxX, y: f.midY) }
    private func parentSocket(_ f: CGRect) -> CGPoint { CGPoint(x: f.minX, y: f.minY + 16) }
    private func matteSocket(_ f: CGRect) -> CGPoint { CGPoint(x: f.minX, y: f.maxY - 14) }

    // MARK: Drawing

    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        let dx = max(40, abs(b.x - a.x) * 0.5)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }

    private func drawWires(_ ctx: GraphicsContext, nodes: [Node], composite: CGRect) {
        let byLayer = Dictionary(grouping: nodes, by: { $0.layer.layerID })
        for (row, l) in model.layers.enumerated() {
            guard let chain = byLayer[l.layerID] else { continue }
            for (a, b) in zip(chain, chain.dropFirst()) {
                ctx.stroke(curve(outSocket(a.frame), CGPoint(x: b.frame.minX, y: b.frame.midY)), with: .color(.white.opacity(0.55)), lineWidth: 1.5)
            }
            if let last = chain.last {
                ctx.stroke(curve(outSocket(last.frame), compositeSlot(composite, row)),
                           with: .color(Theme.accent.opacity(l.visible ? 0.9 : 0.3)), lineWidth: 2)
            }
            // Mattes (dashed yellow) and parents (dotted grey) come from the other layer's source output.
            if let src = byLayer[l.matteLayerID]?.first, let dst = chain.first {
                ctx.stroke(curve(outSocket(src.frame), matteSocket(dst.frame)), with: .color(Theme.keyframe),
                           style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            if let src = byLayer[l.parentID]?.first, let dst = chain.first {
                ctx.stroke(curve(outSocket(src.frame), parentSocket(dst.frame)), with: .color(.gray),
                           style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            }
        }
        if let w = wire, let src = byLayer[w.from]?.first {
            ctx.stroke(curve(outSocket(src.frame), w.to), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ n: Node) -> some View {
        let selected = model.selectedLayers.contains(n.layer.layerID)
        let tint: Color = n.kind == .source ? Theme.accent : n.kind == .effect ? Color(red: 0.62, green: 0.45, blue: 1) : Theme.keyframe
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.16))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
            Rectangle().fill(tint.opacity(n.enabled ? 0.9 : 0.3)).frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 6).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(n.subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 14).padding(.top, 9).padding(.trailing, 14)
            .opacity(n.enabled ? 1 : 0.5)
            if n.kind == .source {
                socket(color: .gray).position(x: 0, y: 16).help("Parent: drop another layer's output here")
                socket(color: Theme.keyframe).position(x: 0, y: Self.nodeSize.height - 14).help("Track matte: drop another layer's output here")
                outputSocket(n.layer.layerID).position(x: Self.nodeSize.width, y: Self.nodeSize.height / 2)
            }
        }
        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
        .position(x: n.frame.midX, y: n.frame.midY)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("nodes"))
            .onChanged { g in
                if nodeDrag?.id != n.id { nodeDrag = (n.id, offsets[n.id] ?? .zero) }
                if let s = nodeDrag { offsets[n.id] = CGSize(width: s.start.width + g.translation.width, height: s.start.height + g.translation.height) }
            }
            .onEnded { _ in nodeDrag = nil })
        .onTapGesture { model.selectLayer(n.layer.layerID, mode: SelectMode.current) }
        .contextMenu { menu(n) }
    }

    private func socket(color: Color) -> some View {
        Circle().fill(Color(white: 0.1)).overlay(Circle().stroke(color, lineWidth: 2)).frame(width: 11, height: 11)
    }

    private func outputSocket(_ layer: UInt64) -> some View {
        Circle().fill(Theme.accent).frame(width: 12, height: 12)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("nodes"))
                .onChanged { g in wire = (layer, g.location) }
                .onEnded { g in
                    connect(from: layer, at: g.location)
                    wire = nil
                })
            .help("Drag to connect this layer as a matte, a parent, or to a Composite slot")
    }

    private func compositeView(_ r: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Composite").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).frame(height: 30)
            ForEach(Array(model.layers.enumerated()), id: \.element.layerID) { _, l in
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent.opacity(l.visible ? 1 : 0.3)).frame(width: 8, height: 8)
                    Text(l.name).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    if l.blend != .normal { Text(blendName(l.blend)).font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                .padding(.leading, 6).padding(.trailing, 10).frame(height: 26)
            }
            Spacer(minLength: 0)
            Text("→ \(model.comp.width)×\(model.comp.height)").font(.system(size: 9)).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: r.width, height: r.height + 30, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
        .position(x: r.midX, y: r.minY + (r.height + 30) / 2)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("nodes"))
            .onChanged { g in
                if nodeDrag?.id != "composite" { nodeDrag = ("composite", offsets["composite"] ?? .zero) }
                if let s = nodeDrag { offsets["composite"] = CGSize(width: s.start.width + g.translation.width, height: s.start.height + g.translation.height) }
            }
            .onEnded { _ in nodeDrag = nil })
    }

    // MARK: Editing

    private func connect(from layer: UInt64, at p: CGPoint) {
        let (nodes, composite) = layout()
        func near(_ q: CGPoint) -> Bool { hypot(q.x - p.x, q.y - p.y) <= 14 }
        for n in nodes where n.kind == .source && n.layer.layerID != layer {
            if near(matteSocket(n.frame)) {
                model.edit { e in
                    if !e.setLayer(n.layer.layerID, matte: layer, mode: n.layer.matteMode == .none ? .alpha : n.layer.matteMode) {
                        model.alertMessage = "Couldn't use that layer as a matte."
                    }
                }
                return
            }
            if near(parentSocket(n.frame)) {
                model.edit { e in
                    if !e.setLayer(n.layer.layerID, parent: layer) { model.alertMessage = "That parent would create a loop." }
                }
                return
            }
        }
        for i in model.layers.indices where near(compositeSlot(composite, i)) || (p.x >= composite.minX - 14 && p.x <= composite.maxX && abs(p.y - compositeSlot(composite, i).y) <= 13) {
            model.edit { _ = $0.moveLayer(layer, to: i) }
            return
        }
    }

    @ViewBuilder
    private func menu(_ n: Node) -> some View {
        let lid = n.layer.layerID
        switch n.kind {
        case .source:
            Menu("Add Effect") {
                ForEach(MFEngine.effectCatalog(), id: \.type.rawValue) { e in
                    Button(e.name) { model.selectLayer(lid, mode: .replace); model.applyEffect(e.type) }
                }
            }
            Button("Add Rectangle Mask") { model.selectLayer(lid, mode: .replace); model.addMask(.rectangle) }
            Button("Add Ellipse Mask") { model.selectLayer(lid, mode: .replace); model.addMask(.ellipse) }
            Divider()
            Button("Remove Track Matte") { model.edit { _ = $0.setLayer(lid, matte: 0, mode: .none) } }.disabled(n.layer.matteLayerID == 0)
            Button("Remove Parent") { model.edit { _ = $0.setLayer(lid, parent: 0) } }.disabled(n.layer.parentID == 0)
            Button(n.layer.visible ? "Hide Layer" : "Show Layer") { model.edit { _ = $0.setLayer(lid, visible: !n.layer.visible) } }
        case .effect:
            let effects = n.layer.effects
            let idx = effects.firstIndex { $0.effectID == n.objectID } ?? 0
            Button(n.enabled ? "Bypass" : "Enable") { model.edit { _ = $0.setEffect(n.objectID, layer: lid, enabled: !n.enabled) } }
            Button("Move Earlier") { model.edit { _ = $0.moveEffect(n.objectID, layer: lid, to: idx - 1) } }.disabled(idx == 0)
            Button("Move Later") { model.edit { _ = $0.moveEffect(n.objectID, layer: lid, to: idx + 1) } }.disabled(idx >= effects.count - 1)
            Divider()
            Button("Remove Effect") { model.edit { _ = $0.removeEffect(n.objectID, layer: lid) } }
        case .mask:
            let m = n.layer.masks.first { $0.maskID == n.objectID }
            ForEach([MFMaskMode.add, .subtract, .intersect, .difference], id: \.rawValue) { mode in
                Button(mode.label) { model.edit { _ = $0.setMask(n.objectID, layer: lid, mode: mode, inverted: m?.inverted ?? false) } }
            }
            Button(m?.inverted == true ? "Un-invert" : "Invert") {
                model.edit { _ = $0.setMask(n.objectID, layer: lid, mode: m?.mode ?? .add, inverted: !(m?.inverted ?? false)) }
            }
            Divider()
            Button("Remove Mask") { model.edit { _ = $0.removeMask(n.objectID, layer: lid) } }
        }
    }
}
