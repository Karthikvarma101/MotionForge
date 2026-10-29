import MetalKit
import MFRender
import SwiftUI

/// Maps between composition pixels and viewer points (top-left origin, y down).
struct ViewerGeometry {
    let viewSize: CGSize
    let compSize: CGSize
    let fitScale: Double
    let scale: Double      // points per composition pixel
    let origin: CGPoint    // composition top-left in view points

    init(viewSize: CGSize, compSize: CGSize, zoom: Double?, pan: CGSize) {
        let margin = 28.0
        let fw = max(1, viewSize.width - margin * 2) / max(1, compSize.width)
        let fh = max(1, viewSize.height - margin * 2) / max(1, compSize.height)
        self.viewSize = viewSize
        self.compSize = compSize
        fitScale = max(0.01, min(fw, fh))
        scale = zoom ?? fitScale
        origin = CGPoint(x: (viewSize.width - compSize.width * scale) / 2 + pan.width,
                         y: (viewSize.height - compSize.height * scale) / 2 + pan.height)
    }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    func toComp(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }

    /// Pan that keeps `compPoint` under `viewPoint` at `newScale`.
    func pan(keeping compPoint: CGPoint, at viewPoint: CGPoint, newScale: Double) -> CGSize {
        let ox = viewPoint.x - compPoint.x * newScale
        let oy = viewPoint.y - compPoint.y * newScale
        return CGSize(width: ox - (viewSize.width - compSize.width * newScale) / 2,
                      height: oy - (viewSize.height - compSize.height * newScale) / 2)
    }
}

extension EditorModel {
    func viewerGeometry(_ size: CGSize) -> ViewerGeometry {
        ViewerGeometry(viewSize: size, compSize: CGSize(width: comp.width, height: comp.height), zoom: zoom, pan: pan)
    }

    func setZoom(_ newScale: Double?, viewSize: CGSize) {
        guard let newScale else {
            zoom = nil
            pan = .zero
            return
        }
        let g = viewerGeometry(viewSize)
        let centre = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let clamped = min(max(newScale, 0.02), 32)
        pan = g.pan(keeping: g.toComp(centre), at: centre, newScale: clamped)
        zoom = clamped
    }
}

struct ViewerView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    @ObservedObject var perf: PerfModel
    @State private var viewSize = CGSize(width: 800, height: 450)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let g = model.viewerGeometry(geo.size)
                ZStack(alignment: .topLeading) {
                    MetalViewer(model: model, time: time, geometry: g)
                    SelectionOverlay(model: model, time: time, geometry: g)
                        .allowsHitTesting(false)
                }
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, s in viewSize = s }
            }
            .background(Color(white: 0.105))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDroppedFiles(providers)
                return true
            }
            ViewerFooter(model: model, perf: perf, viewSize: viewSize)
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if url.pathExtension.lowercased() == "mfproj" {
                        if model.confirmDiscardChanges() { model.open(url: url) }
                    } else {
                        model.importMedia(urls: [url], addToComposition: true)
                    }
                }
            }
        }
    }
}

/// Selection outline + corner handles, drawn in SwiftUI over the Metal layer.
struct SelectionOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var time: TimeModel
    let geometry: ViewerGeometry

    var body: some View {
        Canvas { ctx, _ in
            // Composition frame
            let frame = CGRect(origin: geometry.origin,
                               size: CGSize(width: geometry.compSize.width * geometry.scale,
                                            height: geometry.compSize.height * geometry.scale))
            ctx.stroke(Path(frame), with: .color(.white.opacity(0.12)), lineWidth: 1)

            // Pen tool: the path being drawn.
            let draft = model.penDraft
            if !draft.isEmpty {
                ctx.stroke(bezier(draft.map { (geometry.toView($0.point), $0.inTangent, $0.outTangent) }, closed: false),
                           with: .color(Theme.keyframe), lineWidth: 1.5)
                for (i, v) in draft.enumerated() {
                    let c = geometry.toView(v.point)
                    drawHandles(ctx, c, v.inTangent, v.outTangent)
                    let r = CGRect(x: c.x - (i == 0 ? 5 : 4), y: c.y - (i == 0 ? 5 : 4), width: i == 0 ? 10 : 8, height: i == 0 ? 10 : 8)
                    ctx.fill(Path(r), with: .color(i == 0 ? Theme.keyframe : .white))
                }
            }

            // Shape tool: the shape being dragged out.
            if let r = model.shapeDraft {
                let a = geometry.toView(r.origin), b = geometry.toView(CGPoint(x: r.maxX, y: r.maxY))
                let vr = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                ctx.stroke(model.shapeTool == .ellipse ? Path(ellipseIn: vr) : Path(vr), with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
            }

            guard let sel = model.selection else { return }
            // The primary layer's anchor point (what Rotation turns around and Pan Behind moves).
            do {
                let a = model.engine.value(of: .anchorPoint, layer: sel, time: time.time)
                let c = geometry.toView(model.engine.layerToComp(CGPoint(x: a.x, y: a.y), layer: sel, time: time.time))
                let big = model.tool == .rotate || model.tool == .panBehind
                let r = big ? 6.0 : 4.0, arm = big ? 11.0 : 7.0
                var cross = Path()
                cross.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                cross.move(to: CGPoint(x: c.x - arm, y: c.y)); cross.addLine(to: CGPoint(x: c.x + arm, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - arm)); cross.addLine(to: CGPoint(x: c.x, y: c.y + arm))
                ctx.stroke(cross, with: .color(.black.opacity(0.6)), lineWidth: 3)
                ctx.stroke(cross, with: .color(.white), lineWidth: 1.25)
            }
            // Points and handles of the selected bezier-path layer.
            if model.tool == .select, let pl = model.selectedLayer, pl.kind == .shape, pl.shape == .path {
                for v in pl.pathVertices {
                    let c = geometry.toView(model.engine.layerToComp(v.point, layer: sel, time: time.time))
                    let i = geometry.toView(model.engine.layerToComp(CGPoint(x: v.point.x + v.inTangent.x, y: v.point.y + v.inTangent.y), layer: sel, time: time.time))
                    let o = geometry.toView(model.engine.layerToComp(CGPoint(x: v.point.x + v.outTangent.x, y: v.point.y + v.outTangent.y), layer: sel, time: time.time))
                    drawHandles(ctx, c, CGPoint(x: (i.x - c.x) / geometry.scale, y: (i.y - c.y) / geometry.scale),
                                CGPoint(x: (o.x - c.x) / geometry.scale, y: (o.y - c.y) / geometry.scale))
                    let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                    ctx.fill(Path(r), with: .color(.white))
                    ctx.stroke(Path(r), with: .color(Theme.accent), lineWidth: 1)
                }
            }
            // Every selected layer gets an outline; the primary one also gets corner handles.
            for id in model.selectedLayers where id != sel {
                let q = model.engine.quad(forLayer: id, time: time.time)
                var outline = Path()
                outline.addLines([q.topLeft, q.topRight, q.bottomRight, q.bottomLeft].map(geometry.toView))
                outline.closeSubpath()
                ctx.stroke(outline, with: .color(Theme.accent.opacity(0.75)), lineWidth: 1)
            }
            let q = model.engine.quad(forLayer: sel, time: time.time)
            let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft].map(geometry.toView)
            var path = Path()
            path.addLines(pts)
            path.closeSubpath()
            ctx.stroke(path, with: .color(Theme.accent), lineWidth: 1.25)
            for p in pts {
                let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                ctx.fill(Path(r), with: .color(.white))
                ctx.stroke(Path(r), with: .color(Theme.accent), lineWidth: 1)
            }
            // Motion paths: dotted path, a square per keyframe; bezier handles on the primary layer.
            for id in model.selectedLayers {
                guard let mp = model.engine.motionPath(layer: id, time: time.time) else { continue }
                var line = Path()
                line.addLines(mp.points.map { geometry.toView($0.pointValue) })
                ctx.stroke(line, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                for k in mp.keys {
                    let c = geometry.toView(k.point)
                    if id == sel {
                        for h in [k.inHandle, k.outHandle] {
                            let hv = geometry.toView(h)
                            guard hypot(hv.x - c.x, hv.y - c.y) > 1 else { continue }
                            var stem = Path()
                            stem.move(to: c)
                            stem.addLine(to: hv)
                            ctx.stroke(stem, with: .color(Theme.keyframe.opacity(0.9)), lineWidth: 1)
                            let dot = CGRect(x: hv.x - 3.5, y: hv.y - 3.5, width: 7, height: 7)
                            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.keyframe))
                        }
                    }
                    let atPlayhead = abs(k.time - time.time) < 0.5 / model.comp.fps
                    let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                    ctx.fill(Path(r), with: .color(atPlayhead ? Theme.keyframe : Color(white: 0.15)))
                    ctx.stroke(Path(r), with: .color(Theme.keyframe), lineWidth: 1)
                }
            }
            // Masks of the selected layer, dashed; path masks (rotoscoping) with their points.
            for m in model.selectedLayer?.masks ?? [] where m.enabled && m.shape == .path {
                let verts = model.engine.maskPath(m.maskID, layer: sel, time: time.time)
                @MainActor func v(_ q: CGPoint) -> CGPoint { geometry.toView(model.engine.layerToComp(q, layer: sel, time: time.time)) }
                let pts = verts.map { x -> (CGPoint, CGPoint, CGPoint) in
                    let c = v(x.point)
                    let i = v(CGPoint(x: x.point.x + x.inTangent.x, y: x.point.y + x.inTangent.y))
                    let o = v(CGPoint(x: x.point.x + x.outTangent.x, y: x.point.y + x.outTangent.y))
                    return (c, CGPoint(x: (i.x - c.x) / geometry.scale, y: (i.y - c.y) / geometry.scale),
                            CGPoint(x: (o.x - c.x) / geometry.scale, y: (o.y - c.y) / geometry.scale))
                }
                ctx.stroke(bezier(pts, closed: true), with: .color(Theme.keyframe), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                if model.tool == .select && verts.count <= 400 {
                    for (c, _, _) in pts {
                        let r = CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)
                        ctx.fill(Path(r), with: .color(m.pathAnimated ? Theme.keyframe : .white))
                    }
                }
            }
            for m in model.selectedLayer?.masks ?? [] where m.enabled && m.shape != .path {
                let mq = model.engine.quad(forMask: m.maskID, layer: sel, time: time.time)
                let a = geometry.toView(mq.topLeft), b = geometry.toView(mq.topRight), d = geometry.toView(mq.bottomLeft)
                // Affine map from the unit square onto the (possibly rotated) mask rectangle.
                let t = CGAffineTransform(a: b.x - a.x, b: b.y - a.y, c: d.x - a.x, d: d.y - a.y, tx: a.x, ty: a.y)
                let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                let shape = m.shape == .ellipse ? Path(ellipseIn: unit) : Path(unit)
                ctx.stroke(shape.applying(t), with: .color(Theme.keyframe),
                           style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
            }
        }
        .id(model.revision)
    }

    /// A cubic path through view-space points with composition-space handle offsets.
    private func bezier(_ pts: [(CGPoint, CGPoint, CGPoint)], closed: Bool) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first.0)
        let k = geometry.scale
        for i in 1..<max(1, pts.count) {
            let a = pts[i - 1], b = pts[i]
            p.addCurve(to: b.0, control1: CGPoint(x: a.0.x + a.2.x * k, y: a.0.y + a.2.y * k),
                       control2: CGPoint(x: b.0.x + b.1.x * k, y: b.0.y + b.1.y * k))
        }
        if closed { p.closeSubpath() }
        return p
    }

    private func drawHandles(_ ctx: GraphicsContext, _ c: CGPoint, _ tin: CGPoint, _ tout: CGPoint) {
        for t in [tin, tout] where hypot(t.x, t.y) * geometry.scale > 1 {
            let h = CGPoint(x: c.x + t.x * geometry.scale, y: c.y + t.y * geometry.scale)
            var stem = Path()
            stem.move(to: c)
            stem.addLine(to: h)
            ctx.stroke(stem, with: .color(Theme.keyframe.opacity(0.9)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7)), with: .color(Theme.keyframe))
        }
    }
}

struct ViewerFooter: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var perf: PerfModel
    let viewSize: CGSize

    var body: some View {
        let g = model.viewerGeometry(viewSize)
        HStack(spacing: 10) {
            Menu {
                Button("Fit") { model.setZoom(nil, viewSize: viewSize) }
                Divider()
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { z in
                    Button("\(Int(z * 100))%") { model.setZoom(z / backing, viewSize: viewSize) }
                }
            } label: {
                Text(model.zoom == nil ? "Fit (\(percent(g.scale)))" : percent(g.scale))
                    .frame(minWidth: 70, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Picker("", selection: $model.quality) {
                ForEach(PreviewQuality.allCases) { q in Text(q.label).tag(q) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Preview resolution. Exports always render at full resolution.")

            Text(previewLabel)
                .foregroundStyle(isReduced ? Theme.warning : .secondary)
                .help(isReduced ? "Reduced-resolution preview (final renders are full quality)" : "Full-resolution preview")

            Toggle(isOn: $model.checkerboard) { Image(systemName: "checkerboard.rectangle") }
                .toggleStyle(.button)
                .help("Transparency grid")

            if model.customView != nil || model.layers.contains(where: { $0.threeD && $0.kind != .camera }) {
                Picker("", selection: Binding(get: { model.customView != nil },
                                              set: { model.customView = $0 ? (model.customView ?? OrbitView(yaw: -30, pitch: 15, distance: 1.6)) : nil })) {
                    Text("Active Camera").tag(false)
                    Text("Custom View").tag(true)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Look at the 3D scene from anywhere (Orbit Camera tool, C). Exports always use the active camera.")
                if model.customView != nil {
                    Button("Reset View") { model.customView = OrbitView(yaw: -30, pitch: 15, distance: 1.6) }
                        .buttonStyle(.borderless)
                }
            }

            if let note = perf.autoQualityNote {
                Label(note, systemImage: "gauge.with.dots.needle.33percent").foregroundStyle(Theme.warning).lineLimit(1)
            }
            Spacer()
            if perf.lastFrameIncomplete {
                Label("Loading media…", systemImage: "hourglass").foregroundStyle(Theme.warning)
            }
            if let fill = perf.ramPreviewFill {
                Label("RAM Preview: rendering \(Int(fill * 100))%", systemImage: "memorychip").foregroundStyle(Theme.keyframe)
                    .help("Every frame of the work area is rendered once, then it plays in real time")
            }
            Text("\(model.comp.width)×\(model.comp.height) · \(fpsString(model.comp.fps)) fps")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.panel)
    }

    private var backing: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }

    private func percent(_ scale: Double) -> String { "\(Int((scale * backing * 100).rounded()))%" }

    private var isReduced: Bool {
        perf.renderSize.width > 0 && Int(perf.renderSize.width) < model.comp.width
    }

    private var previewLabel: String {
        guard perf.renderSize.width > 0 else { return "" }
        let ratio = Double(model.comp.width) / perf.renderSize.width
        let name = ratio <= 1.01 ? "Full" : ratio <= 2.01 ? "Half" : "Quarter"
        return "Preview: \(name) \(Int(perf.renderSize.width))×\(Int(perf.renderSize.height))"
    }
}

func fpsString(_ fps: Double) -> String {
    fps.rounded() == fps ? String(Int(fps)) : String(format: "%.3f", fps)
}

// MARK: - Metal view

final class ViewerMTKView: MTKView {
    weak var coordinator: MetalViewer.Coordinator?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { coordinator?.mouseDown(point(e), event: e) }
    override func mouseDragged(with e: NSEvent) { coordinator?.mouseDragged(point(e), event: e) }
    override func mouseUp(with e: NSEvent) { coordinator?.mouseUp(point(e), event: e) }
    override func scrollWheel(with e: NSEvent) { coordinator?.scroll(point(e), event: e) }
    override func magnify(with e: NSEvent) { coordinator?.magnify(point(e), event: e) }
    var tool: EditorTool = .select { didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } } }
    var grabbing = false { didSet { if grabbing != oldValue { window?.invalidateCursorRects(for: self) } } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.cursor(for: tool, grabbing: grabbing)) }

    private static let zoomCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let img = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom")?
            .withSymbolConfiguration(config) else { return .crosshair }
        return NSCursor(image: img, hotSpot: NSPoint(x: 6, y: 6))
    }()

    static func cursor(for tool: EditorTool, grabbing: Bool) -> NSCursor {
        switch tool {
        case .select: return .arrow
        case .hand: return grabbing ? .closedHand : .openHand
        case .zoom: return zoomCursor
        case .type: return .iBeam
        case .rotate, .panBehind, .pen, .shape: return .crosshair
        case .orbit: return grabbing ? .closedHand : .openHand
        }
    }
}

struct MetalViewer: NSViewRepresentable {
    let model: EditorModel
    @ObservedObject var time: TimeModel
    let geometry: ViewerGeometry

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    // Leaving the viewer (Nodes workspace) stops its idle-render timer; otherwise one leaks per switch.
    static func dismantleNSView(_ nsView: ViewerMTKView, coordinator: Coordinator) {
        coordinator.stopIdleRendering()
    }

    func makeNSView(context: Context) -> ViewerMTKView {
        let v = ViewerMTKView(frame: .zero, device: model.engine.device)
        v.coordinator = context.coordinator
        v.delegate = context.coordinator
        v.colorPixelFormat = .bgra8Unorm
        v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)  // values are display-referred sRGB
        v.framebufferOnly = true
        v.autoResizeDrawable = true
        v.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        context.coordinator.view = v
        // Drawing is skipped while the window is hidden; catch up when it shows again.
        context.coordinator.occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak v] note in
            MainActor.assumeIsolated {
                guard let v, let w = note.object as? NSWindow, w === v.window, w.occlusionState.contains(.visible) else { return }
                v.needsDisplay = true
            }
        }
        return v
    }

    func updateNSView(_ v: ViewerMTKView, context: Context) {
        context.coordinator.geometry = geometry
        v.tool = model.tool
        let playing = time.isPlaying
        if v.isPaused == playing {  // switch between on-demand and display-linked drawing
            v.isPaused = !playing
            v.enableSetNeedsDisplay = !playing
        }
        if !playing { v.needsDisplay = true }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: EditorModel
        weak var view: ViewerMTKView?
        var geometry = ViewerGeometry(viewSize: .init(width: 1, height: 1), compSize: .init(width: 1, height: 1), zoom: nil, pan: .zero)

        // playback clock
        private var wasPlaying = false
        private var lastWrittenTime = -1.0  // the playhead time playback last set
        private var playStartWall: CFTimeInterval = 0
        private var playStartTime = 0.0
        private var lastFrameIndex = -1
        // perf
        private var presentTimes: [CFTimeInterval] = []
        private var dropped = 0
        private var lastPerfPublish: CFTimeInterval = 0
        // interaction
        private enum Drag {
            case layers(start: CGPoint, positions: [UInt64: MFValue])
            case pathKey(layer: UInt64, index: Int, start: CGPoint, value: MFValue)
            case pathHandle(layer: UInt64, index: Int, isOut: Bool, start: CGPoint, tangentIn: MFValue, tangentOut: MFValue)
            case pen(index: Int)
            case shapePoint(layer: UInt64, index: Int, part: Int, start: CGPoint, original: [MFPathVertex], closed: Bool)  // part: 0 point, 1 in, 2 out
            case rotate(pivot: CGPoint, rotations: [UInt64: Double])
            case orbit(start: CGPoint, view: OrbitView)
            case maskPoint(layer: UInt64, mask: UInt64, index: Int, part: Int, start: CGPoint, original: [MFPathVertex])
            case anchor(layer: UInt64, start: CGPoint, anchor: MFValue, position: MFValue)
            case shape(start: CGPoint)
        }
        private var drag: Drag?
        private var panStartView: CGPoint?
        private var panStart = CGSize.zero
        // RAM Preview's first pass: one frame per finished render, no sound, until the range is cached
        private var filling = false
        private var fillFrameSince: CFTimeInterval = 0
        private var rotateLast = 0.0, rotateTotal = 0.0  // radians, so a drag can go round more than once
        // adaptive preview resolution (Auto quality, playback only)
        private var autoBoost = 1
        private var overBudget = 0, underBudget = 0
        // idle background rendering
        private var idleTimer: Timer?
        private var idleAnchor: (time: Double, revision: UInt64, divisor: Int) = (-1, 0, 0)
        private var idleCursor = 0.0

        init(model: EditorModel) {
            self.model = model
            super.init()
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.idleTick() }
            }
        }

        var occlusion: NSObjectProtocol?

        func stopIdleRendering() {
            idleTimer?.invalidate()
            idleTimer = nil
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            occlusion = nil
        }

        /// While paused, renders the next 2 s of frames into the cache a few at a time, so
        /// playback of effect-heavy comps starts from cache. Cheap frames are skipped by the engine.
        private func idleTick() {
            guard view != nil, !model.time.isPlaying, model.cachePolicy != .off else { return }
            let fps = model.comp.fps
            let anchor = (model.time.time, model.revision, model.perf.currentDivisor)
            if anchor != idleAnchor {
                idleAnchor = anchor
                idleCursor = anchor.0
            }
            guard idleCursor < anchor.0 + 2.0 else { return }
            _ = model.engine.prefetch(fromTime: idleCursor, frames: 3, qualityDivisor: anchor.2, loop: model.time.loop)
            idleCursor += 3 / fps
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { self.render(view) }
        }

        private func render(_ view: MTKView) {
            let clock = model.time
            let fps = model.comp.fps
            var t = clock.time
            let now = CACurrentMediaTime()

            let range = model.playRange
            if clock.isPlaying {
                if !wasPlaying {
                    wasPlaying = true
                    // Playback stays in the work area: starting outside it starts at its beginning.
                    if t < range.start - 1e-9 || t > range.end - 1 / fps + 1e-9 {
                        t = range.start
                        clock.time = t
                    }
                    playStartWall = now
                    playStartTime = t
                    lastFrameIndex = -1
                    dropped = 0
                    filling = model.ramPreview
                    fillFrameSince = now
                    lastWrittenTime = t
                    if filling { autoBoost = 1 } else { model.audio.play(from: t) }
                } else if !filling && abs(t - lastWrittenTime) > 1e-9 {
                    // Something else moved the playhead (a keyframe click, the inspector's key arrows):
                    // carry on playing from there instead of snapping back.
                    playStartWall = now
                    playStartTime = t
                    lastFrameIndex = -1
                    model.audio.play(from: t)
                }
                if !filling {
                    var elapsed = playStartTime + (now - playStartWall)
                    if let a = model.audio.clockTime {
                        // Sound leads: the picture follows the audio clock (and the wall clock is kept in
                        // line with it for when the sound ends).
                        elapsed = a
                        playStartWall = now - (a - playStartTime)
                    }
                    let lastFrameTime = max(range.start, range.end - 1 / fps)
                    if elapsed > lastFrameTime + 1 / fps - 1e-9 {
                        if clock.loop || model.ramPreview {
                            playStartWall = now
                            playStartTime = range.start
                            elapsed = range.start
                            lastFrameIndex = -1
                            model.audio.play(from: range.start)
                        } else {
                            clock.isPlaying = false
                            elapsed = lastFrameTime
                            model.audio.stop()
                        }
                    }
                    let frameIndex = Int((elapsed * fps + 1e-6).rounded(.down))
                    if frameIndex == lastFrameIndex { return }  // display refresh between comp frames
                    if lastFrameIndex >= 0 && frameIndex > lastFrameIndex + 1 { dropped += frameIndex - lastFrameIndex - 1 }
                    lastFrameIndex = frameIndex
                    t = Double(frameIndex) / fps
                    clock.time = t
                    lastWrittenTime = t
                }
            } else {
                if wasPlaying {
                    model.audio.stop()
                    model.endRAMPreview()
                }
                wasPlaying = false
                filling = false
            }

            let backing = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 2
            let drawableScale = geometry.scale * backing
            var divisor = model.quality.rawValue
            if model.quality == .auto {
                // Lowest resolution that still has at least one texel per screen pixel…
                divisor = drawableScale <= 0.25 ? 4 : drawableScale <= 0.5 ? 2 : 1
                // …lowered further while playback can't keep up, or under memory pressure.
                if clock.isPlaying { divisor = min(4, divisor * autoBoost) }
                if now < model.memoryPressureUntil { divisor = max(divisor, 2) }
            }
            if !clock.isPlaying && autoBoost != 1 {
                autoBoost = 1
                model.perf.autoQualityNote = nil
            }
            let info = model.engine.draw(in: view, time: t, qualityDivisor: divisor,
                                         origin: CGPoint(x: geometry.origin.x * backing, y: geometry.origin.y * backing),
                                         scale: drawableScale, checkerboard: model.checkerboard)
            if info.skipped {
                if !clock.isPlaying { DispatchQueue.main.async { view.needsDisplay = true } }
                return
            }
            presentTimes.append(now)
            presentTimes.removeAll { now - $0 > 1.0 }
            model.perf.currentDivisor = divisor
            if clock.isPlaying {
                // Keep the GPU a few frames ahead of the playhead (only frames worth caching).
                _ = model.engine.prefetch(fromTime: t, frames: 6, qualityDivisor: divisor, loop: clock.loop)
                if model.quality == .auto && !filling { adaptResolution(fps: fps, divisor: divisor) }
            }
            if filling && clock.isPlaying && (info.complete || now - fillFrameSince > 2) {
                // RAM Preview: this frame is in the cache now, so on to the next; after the last one
                // the whole range plays back in real time, with sound.
                let next = t + 1 / fps
                if next > range.end - 1 / fps + 1e-9 {
                    filling = false
                    model.perf.ramPreviewFill = nil
                    playStartWall = now
                    playStartTime = range.start
                    lastFrameIndex = -1
                    clock.time = range.start
                    lastWrittenTime = range.start
                    model.audio.play(from: range.start)
                } else {
                    clock.time = next
                    lastWrittenTime = next
                    fillFrameSince = now
                    if now - lastPerfPublish > 0.2 {
                        model.perf.ramPreviewFill = (next - range.start) / max(1e-9, range.end - range.start)
                    }
                }
            }
            if !info.complete && !clock.isPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { view.needsDisplay = true }
            }
            if now - lastPerfPublish > 0.25 || !clock.isPlaying {
                lastPerfPublish = now
                let perf = model.perf
                perf.presentedFPS = clock.isPlaying ? Double(presentTimes.count) : 0
                perf.droppedFrames = dropped
                perf.evalMs = info.evalMs
                perf.encodeMs = info.encodeMs
                perf.lastFrameIncomplete = !info.complete
                perf.lastFrameCached = info.cacheHit
                let size = CGSize(width: info.renderWidth, height: info.renderHeight)
                if perf.renderSize != size { perf.renderSize = size }
            }
        }

        /// Halves the preview resolution when the composite takes more than 85% of the frame
        /// budget for several frames, and restores it after sustained headroom. Always reported.
        private func adaptResolution(fps: Double, divisor: Int) {
            let budget = 1000 / fps
            let gpu = model.engine.stats().lastGPUMs
            if gpu > 0.85 * budget { overBudget += 1; underBudget = 0 } else if gpu < 0.3 * budget { underBudget += 1; overBudget = 0 }
            if overBudget >= 6 && divisor < 4 {
                autoBoost *= 2
                overBudget = 0
                model.perf.autoQualityNote = String(format: "Auto lowered preview: GPU %.1f ms > %.1f ms frame budget", gpu, budget)
            } else if underBudget >= 90 && autoBoost > 1 {
                autoBoost /= 2
                underBudget = 0
                model.perf.autoQualityNote = autoBoost > 1 ? model.perf.autoQualityNote : nil
            }
        }

        // MARK: mouse

        func mouseDown(_ p: CGPoint, event: NSEvent) {
            view?.window?.makeFirstResponder(view)
            model.closeCoalescedEdit()
            let t = model.time.time
            let cp = geometry.toComp(p)
            let flags = event.modifierFlags
            // 0. Pen tool: click adds a corner point, drag pulls out smooth handles, clicking the
            //    first point closes the shape.
            if model.tool == .pen {
                if model.penDraft.count >= 3, let first = model.penDraft.first {
                    let f = geometry.toView(first.point)
                    if hypot(f.x - p.x, f.y - p.y) <= 8 {
                        model.commitPen(closed: true)
                        return
                    }
                }
                model.penDraft.append(MFPathVertex(point: cp, inTangent: .zero, outTangent: .zero))
                drag = .pen(index: model.penDraft.count - 1)
                return
            }
            switch model.tool {
            case .hand:
                panStartView = p
                panStart = model.pan
                view?.grabbing = true
                return
            case .zoom:
                zoom(about: p, factor: flags.contains(.option) ? 0.5 : 2)
                return
            case .orbit:
                if model.customView == nil { model.customView = OrbitView() }
                drag = .orbit(start: p, view: model.customView ?? OrbitView())
                view?.grabbing = true
                return
            case .shape:
                drag = .shape(start: cp)
                model.shapeDraft = CGRect(origin: cp, size: .zero)
                return
            case .type:
                model.addText(at: cp)
                model.tool = .select
                return
            case .rotate:
                let hit = model.engine.hitTest(at: cp, time: t)
                if hit != 0 && !model.selectedLayers.contains(hit) { model.selectLayer(hit, mode: .replace) }
                guard let primary = model.selection else { return }
                var rotations: [UInt64: Double] = [:]
                for id in model.selectedLayers { rotations[id] = model.engine.value(of: .rotation, layer: id, time: t).x }
                let pivot = anchorInComp(primary, t)
                rotateLast = atan2(cp.y - pivot.y, cp.x - pivot.x)
                rotateTotal = 0
                drag = .rotate(pivot: pivot, rotations: rotations)
                model.engine.beginUndoGroup(rotations.count > 1 ? "Rotate Layers" : "Rotate Layer")
                return
            case .panBehind:
                let hit = model.engine.hitTest(at: cp, time: t)
                if hit != 0 && !model.selectedLayers.contains(hit) { model.selectLayer(hit, mode: .replace) }
                guard let id = hit != 0 ? hit : model.selection else { return }
                drag = .anchor(layer: id, start: cp, anchor: model.engine.value(of: .anchorPoint, layer: id, time: t),
                               position: model.engine.value(of: .position, layer: id, time: t))
                model.engine.beginUndoGroup("Move Anchor Point")
                return
            case .select, .pen:
                break
            }
            // 1. Points of the selected layer's path masks (rotoscoping), then of a bezier-path layer.
            if let sel = model.selectedLayer, beginMaskPointDrag(sel, p, t) { return }
            if let sel = model.selectedLayer, sel.kind == .shape, sel.shape == .path, beginShapePointDrag(sel, p, t) { return }
            // 2. Motion-path handles and key points of the primary layer take precedence.
            if let sel = model.selection, let mp = model.engine.motionPath(layer: sel, time: t), beginPathDrag(mp, sel, p, cp, t) {
                return
            }
            // 2. Layers: ⌘ toggles, ⇧ adds, a plain click on an unselected layer selects only it.
            let hit = model.engine.hitTest(at: cp, time: t)
            // Double-clicking a precomp opens it.
            if event.clickCount == 2, hit != 0, let l = model.engine.layer(withID: hit), l.kind == .precomp {
                model.openComposition(l.sourceCompID, fromLayer: l)
                return
            }
            if hit != 0 && !flags.contains(.option) {
                if flags.contains(.command) {
                    model.selectLayer(hit, mode: .toggle)
                    if !model.selectedLayers.contains(hit) { return }
                } else if flags.contains(.shift) {
                    if !model.selectedLayers.contains(hit) { model.selectLayer(hit, mode: .toggle) } else { model.selection = hit }
                } else if !model.selectedLayers.contains(hit) {
                    model.selectLayer(hit, mode: .replace)
                    model.selectedKeyframes = []
                } else {
                    model.selection = hit
                }
                var starts: [UInt64: MFValue] = [:]
                for id in model.selectedLayers { starts[id] = model.engine.value(of: .position, layer: id, time: t) }
                drag = .layers(start: cp, positions: starts)
                model.engine.beginUndoGroup(starts.count > 1 ? "Move Layers" : "Move Layer")
            } else {
                if hit == 0 && !flags.contains(.command) && !flags.contains(.shift) { model.clearSelection() }
                panStartView = p
                panStart = model.pan
            }
        }

        /// A layer's anchor point in composition space (what it rotates and scales around).
        private func anchorInComp(_ layer: UInt64, _ t: Double) -> CGPoint {
            let a = model.engine.value(of: .anchorPoint, layer: layer, time: t)
            return model.engine.layerToComp(CGPoint(x: a.x, y: a.y), layer: layer, time: t)
        }

        /// Starts moving a point (or handle) of one of `layer`'s path masks if `p` is on one.
        private func beginMaskPointDrag(_ layer: MFLayerInfo, _ p: CGPoint, _ t: Double) -> Bool {
            for m in layer.masks where m.enabled && m.shape == .path {
                let verts = model.engine.maskPath(m.maskID, layer: layer.layerID, time: t)
                func view(_ q: CGPoint) -> CGPoint { geometry.toView(model.engine.layerToComp(q, layer: layer.layerID, time: t)) }
                for (i, v) in verts.enumerated() {
                    let candidates: [(CGPoint, Int)] = [(v.point, 0),
                                                        (CGPoint(x: v.point.x + v.outTangent.x, y: v.point.y + v.outTangent.y), 2),
                                                        (CGPoint(x: v.point.x + v.inTangent.x, y: v.point.y + v.inTangent.y), 1)]
                    for (q, part) in candidates {
                        if part != 0 && (hypot(q.x - v.point.x, q.y - v.point.y) < 0.5 || verts.count > 60) { continue }  // traced outlines: points only
                        let vq = view(q)
                        if hypot(vq.x - p.x, vq.y - p.y) <= 6 {
                            drag = .maskPoint(layer: layer.layerID, mask: m.maskID, index: i, part: part,
                                              start: model.engine.compToLayer(geometry.toComp(p), layer: layer.layerID, time: t), original: verts)
                            model.engine.beginUndoGroup("Edit Mask Path")
                            return true
                        }
                    }
                }
            }
            return false
        }

        /// `original` with point `index` (part 0) or one of its handles (1 in, 2 out) moved by `d`;
        /// handles stay opposite each other unless `split`.
        private func moved(_ original: [MFPathVertex], _ index: Int, _ part: Int, _ d: CGPoint, split: Bool) -> [MFPathVertex] {
            var verts = original
            let v = original[index]
            switch part {
            case 0:
                verts[index] = MFPathVertex(point: CGPoint(x: v.point.x + d.x, y: v.point.y + d.y), inTangent: v.inTangent, outTangent: v.outTangent)
            default:
                let m = part == 2 ? CGPoint(x: v.outTangent.x + d.x, y: v.outTangent.y + d.y) : CGPoint(x: v.inTangent.x + d.x, y: v.inTangent.y + d.y)
                var other = part == 2 ? v.inTangent : v.outTangent
                if !split {
                    let len = hypot(other.x, other.y), ml = hypot(m.x, m.y)
                    if ml > 1e-6 { other = CGPoint(x: -m.x / ml * len, y: -m.y / ml * len) }
                }
                verts[index] = MFPathVertex(point: v.point, inTangent: part == 1 ? m : other, outTangent: part == 2 ? m : other)
            }
            return verts
        }

        private func beginShapePointDrag(_ layer: MFLayerInfo, _ p: CGPoint, _ t: Double) -> Bool {
            let verts = layer.pathVertices
            func view(_ q: CGPoint) -> CGPoint { geometry.toView(model.engine.layerToComp(q, layer: layer.layerID, time: t)) }
            for (i, v) in verts.enumerated() {
                let candidates: [(CGPoint, Int)] = [(CGPoint(x: v.point.x + v.outTangent.x, y: v.point.y + v.outTangent.y), 2),
                                                    (CGPoint(x: v.point.x + v.inTangent.x, y: v.point.y + v.inTangent.y), 1),
                                                    (v.point, 0)]
                for (q, part) in candidates {
                    if part != 0 && hypot(q.x - v.point.x, q.y - v.point.y) < 0.5 { continue }  // no handle there
                    let vq = view(q)
                    if hypot(vq.x - p.x, vq.y - p.y) <= 6 {
                        drag = .shapePoint(layer: layer.layerID, index: i, part: part,
                                           start: model.engine.compToLayer(geometry.toComp(p), layer: layer.layerID, time: t),
                                           original: verts, closed: layer.pathClosed)
                        model.engine.beginUndoGroup("Edit Path")
                        return true
                    }
                }
            }
            return false
        }

        /// Starts dragging a bezier handle or a key point if `p` is within reach of one.
        private func beginPathDrag(_ mp: MFMotionPath, _ layer: UInt64, _ p: CGPoint, _ cp: CGPoint, _ t: Double) -> Bool {
            let reach = 6.0
            func near(_ q: CGPoint) -> Bool { let v = geometry.toView(q); return hypot(v.x - p.x, v.y - p.y) <= reach }
            let position = MFPropRef.layer(.position)
            for k in mp.keys {  // handles first: they sit on top of the path
                for (h, isOut) in [(k.outHandle, true), (k.inHandle, false)] where near(h) && !near(k.point) {
                    let tin = model.engine.parentSpaceVector(CGPoint(x: k.inHandle.x - k.point.x, y: k.inHandle.y - k.point.y), layer: layer, time: t)
                    let tout = model.engine.parentSpaceVector(CGPoint(x: k.outHandle.x - k.point.x, y: k.outHandle.y - k.point.y), layer: layer, time: t)
                    drag = .pathHandle(layer: layer, index: k.index, isOut: isOut, start: cp,
                                       tangentIn: MFValue(x: tin.x, y: tin.y, z: 0, w: 0), tangentOut: MFValue(x: tout.x, y: tout.y, z: 0, w: 0))
                    model.engine.beginUndoGroup("Motion Path")
                    return true
                }
            }
            for k in mp.keys where near(k.point) {
                guard let info = model.selectedLayer?.keyframes(for: position).first(where: { $0.index == k.index }) else { continue }
                drag = .pathKey(layer: layer, index: k.index, start: cp, value: info.value)
                model.selectKeyframe(KeyframeRef(layer: layer, ref: position, index: k.index), mode: .replace)
                model.engine.beginUndoGroup("Move Keyframe Position")
                return true
            }
            return false
        }

        func mouseDragged(_ p: CGPoint, event: NSEvent) {
            let t = model.time.time
            let cp = geometry.toComp(p)
            switch drag {
            case .layers(let start, let positions):
                var d = CGPoint(x: cp.x - start.x, y: cp.y - start.y)
                if event.modifierFlags.contains(.shift) {  // constrain to the dominant axis
                    if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 }
                }
                model.edit { e in
                    for (id, start) in positions {  // each in its own parent's space
                        let v = e.parentSpaceVector(d, layer: id, time: t)
                        _ = e.setPropertyValue(MFValue(x: start.x + v.x, y: start.y + v.y, z: 0, w: 0), prop: .position, layer: id, time: t)
                    }
                }
            case .pathKey(let layer, let index, let start, let value):
                let v = model.engine.parentSpaceVector(CGPoint(x: cp.x - start.x, y: cp.y - start.y), layer: layer, time: t)
                model.edit { _ = $0.setKeyframeValue(at: index, ref: .layer(.position), layer: layer,
                                                      value: MFValue(x: value.x + v.x, y: value.y + v.y, z: 0, w: 0)) }
            case .pathHandle(let layer, let index, let isOut, let start, let tin, let tout):
                let v = model.engine.parentSpaceVector(CGPoint(x: cp.x - start.x, y: cp.y - start.y), layer: layer, time: t)
                let moved = isOut ? MFValue(x: tout.x + v.x, y: tout.y + v.y, z: 0, w: 0) : MFValue(x: tin.x + v.x, y: tin.y + v.y, z: 0, w: 0)
                var other = isOut ? tin : tout
                // Handles stay opposite each other (smooth curve) unless ⌥ splits them.
                if !event.modifierFlags.contains(.option) {
                    let len = hypot(other.x, other.y), m = hypot(moved.x, moved.y)
                    if m > 1e-6 { other = MFValue(x: -moved.x / m * len, y: -moved.y / m * len, z: 0, w: 0) }
                }
                model.edit { _ = $0.setKeyframeSpatial(at: index, ref: .layer(.position), layer: layer, mode: .bezier,
                                                        tangentIn: isOut ? other : moved, tangentOut: isOut ? moved : other) }
            case .pen(let index):
                guard index < model.penDraft.count else { break }
                let v = model.penDraft[index]
                let out = CGPoint(x: cp.x - v.point.x, y: cp.y - v.point.y)
                model.penDraft[index] = MFPathVertex(point: v.point, inTangent: CGPoint(x: -out.x, y: -out.y), outTangent: out)
            case .shapePoint(let layer, let index, let part, let start, let original, let closed):
                let lp = model.engine.compToLayer(cp, layer: layer, time: t)
                let d = CGPoint(x: lp.x - start.x, y: lp.y - start.y)
                var verts = original
                let v = original[index]
                switch part {
                case 0:
                    verts[index] = MFPathVertex(point: CGPoint(x: v.point.x + d.x, y: v.point.y + d.y), inTangent: v.inTangent, outTangent: v.outTangent)
                default:
                    let moved = part == 2 ? CGPoint(x: v.outTangent.x + d.x, y: v.outTangent.y + d.y) : CGPoint(x: v.inTangent.x + d.x, y: v.inTangent.y + d.y)
                    var other = part == 2 ? v.inTangent : v.outTangent
                    if !event.modifierFlags.contains(.option) {  // keep the point smooth: mirror the direction
                        let len = hypot(other.x, other.y), m = hypot(moved.x, moved.y)
                        if m > 1e-6 { other = CGPoint(x: -moved.x / m * len, y: -moved.y / m * len) }
                    }
                    verts[index] = MFPathVertex(point: v.point, inTangent: part == 1 ? moved : other, outTangent: part == 2 ? moved : other)
                }
                model.edit { _ = $0.setLayer(layer, pathVertices: verts, closed: closed) }
            case .rotate(let pivot, let rotations):
                let a = atan2(cp.y - pivot.y, cp.x - pivot.x)
                var d = a - rotateLast
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                rotateTotal += d
                rotateLast = a
                let degrees = rotateTotal * 180 / .pi  // clockwise on screen, like the Rotation value
                let snap = event.modifierFlags.contains(.shift)
                model.edit { e in
                    for (id, r0) in rotations {
                        let r = snap ? ((r0 + degrees) / 45).rounded() * 45 : r0 + degrees
                        _ = e.setPropertyValue(MFValue(x: r, y: 0, z: 0, w: 0), prop: .rotation, layer: id, time: t)
                    }
                }
            case .anchor(let id, let start, let anchor, let position):
                // Moving the anchor and the position together leaves the layer where it is on screen,
                // so the layer-to-composition mapping (and with it these conversions) holds all drag.
                let a0 = model.engine.compToLayer(start, layer: id, time: t)
                let a1 = model.engine.compToLayer(cp, layer: id, time: t)
                let v = model.engine.parentSpaceVector(CGPoint(x: cp.x - start.x, y: cp.y - start.y), layer: id, time: t)
                model.edit { e in
                    _ = e.setPropertyValue(MFValue(x: anchor.x + a1.x - a0.x, y: anchor.y + a1.y - a0.y, z: 0, w: 0),
                                           prop: .anchorPoint, layer: id, time: t)
                    _ = e.setPropertyValue(MFValue(x: position.x + v.x, y: position.y + v.y, z: 0, w: 0), prop: .position, layer: id, time: t)
                }
            case .orbit(let start, let v0):
                var v = v0
                let dx = p.x - start.x, dy = p.y - start.y
                if event.modifierFlags.contains(.option) {        // closer / farther
                    v.distance = min(max(v0.distance * exp(Double(dy) * 0.005), 0.05), 20)
                } else if event.modifierFlags.contains(.shift) {  // pan
                    let k = 1 / max(geometry.scale, 1e-3) * v0.distance
                    v.pan = CGPoint(x: v0.pan.x - dx * k, y: v0.pan.y - dy * k)
                } else {
                    v.yaw = v0.yaw - Double(dx) * 0.35
                    v.pitch = min(max(v0.pitch + Double(dy) * 0.35, -89), 89)
                }
                model.customView = v
                view?.needsDisplay = true
            case .maskPoint(let layer, let mask, let index, let part, let start, let original):
                let lp = model.engine.compToLayer(cp, layer: layer, time: t)
                let verts = moved(original, index, part, CGPoint(x: lp.x - start.x, y: lp.y - start.y),
                                  split: event.modifierFlags.contains(.option))
                model.edit { _ = $0.setMaskPath(mask, layer: layer, vertices: verts, time: t) }  // a key here when animated
            case .shape(let start):
                var w = cp.x - start.x, h = cp.y - start.y
                if event.modifierFlags.contains(.shift) {  // square / circle
                    let m = max(abs(w), abs(h))
                    w = w < 0 ? -m : m
                    h = h < 0 ? -m : m
                }
                model.shapeDraft = CGRect(x: min(start.x, start.x + w), y: min(start.y, start.y + h), width: abs(w), height: abs(h))
            case nil:
                if let start = panStartView {
                    if model.zoom == nil { model.zoom = geometry.scale }
                    model.pan = CGSize(width: panStart.width + p.x - start.x, height: panStart.height + p.y - start.y)
                }
            }
        }

        func mouseUp(_ p: CGPoint, event: NSEvent) {
            view?.grabbing = false
            if case .orbit = drag {  // a view, not an edit
                drag = nil
                return
            }
            if case .pen = drag {
                drag = nil
                return
            }
            if case .shape(let start) = drag {  // a click (no real drag) makes the default size there
                let r = model.shapeDraft ?? .zero
                model.shapeDraft = nil
                drag = nil
                let tiny = r.width * geometry.scale < 4 || r.height * geometry.scale < 4
                model.addShape(model.shapeTool, in: tiny ? CGRect(origin: start, size: .zero) : r)
                return
            }
            if drag != nil {
                model.engine.endUndoGroup()
                model.refresh()
            }
            drag = nil
            panStartView = nil
        }

        func scroll(_ p: CGPoint, event: NSEvent) {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                zoom(about: p, factor: pow(1.01, Double(event.scrollingDeltaY)))
            } else {
                if model.zoom == nil { model.zoom = geometry.scale }
                let k = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
                model.pan.width += event.scrollingDeltaX * k
                model.pan.height += event.scrollingDeltaY * k
            }
        }

        func magnify(_ p: CGPoint, event: NSEvent) { zoom(about: p, factor: 1 + Double(event.magnification)) }

        private func zoom(about p: CGPoint, factor: Double) {
            let newScale = min(max(geometry.scale * factor, 0.02), 32)
            model.pan = geometry.pan(keeping: geometry.toComp(p), at: p, newScale: newScale)
            model.zoom = newScale
        }
    }
}
