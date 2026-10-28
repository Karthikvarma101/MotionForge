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

            guard let sel = model.selection else { return }
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
            // Masks of the selected layer, dashed.
            for m in model.selectedLayer?.masks ?? [] where m.enabled {
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

            if let note = perf.autoQualityNote {
                Label(note, systemImage: "gauge.with.dots.needle.33percent").foregroundStyle(Theme.warning).lineLimit(1)
            }
            Spacer()
            if perf.lastFrameIncomplete {
                Label("Loading media…", systemImage: "hourglass").foregroundStyle(Theme.warning)
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
}

struct MetalViewer: NSViewRepresentable {
    let model: EditorModel
    @ObservedObject var time: TimeModel
    let geometry: ViewerGeometry

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

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
        return v
    }

    func updateNSView(_ v: ViewerMTKView, context: Context) {
        context.coordinator.geometry = geometry
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
        private var playStartWall: CFTimeInterval = 0
        private var playStartTime = 0.0
        private var lastFrameIndex = -1
        // perf
        private var presentTimes: [CFTimeInterval] = []
        private var dropped = 0
        private var lastPerfPublish: CFTimeInterval = 0
        // interaction
        private var dragLayer: UInt64 = 0
        private var dragStartComp = CGPoint.zero
        private var dragStartPos = MFValue()
        private var panStartView: CGPoint?
        private var panStart = CGSize.zero
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

            if clock.isPlaying {
                if !wasPlaying {
                    wasPlaying = true
                    playStartWall = now
                    playStartTime = t
                    lastFrameIndex = -1
                    dropped = 0
                }
                var elapsed = playStartTime + (now - playStartWall)
                let lastFrameTime = max(0, model.comp.duration - 1 / fps)
                if elapsed > lastFrameTime + 1 / fps - 1e-9 {
                    if clock.loop {
                        playStartWall = now
                        playStartTime = 0
                        elapsed = 0
                        lastFrameIndex = -1
                    } else {
                        clock.isPlaying = false
                        elapsed = lastFrameTime
                    }
                }
                let frameIndex = Int((elapsed * fps + 1e-6).rounded(.down))
                if frameIndex == lastFrameIndex { return }  // display refresh between comp frames
                if lastFrameIndex >= 0 && frameIndex > lastFrameIndex + 1 { dropped += frameIndex - lastFrameIndex - 1 }
                lastFrameIndex = frameIndex
                t = Double(frameIndex) / fps
                clock.time = t
            } else {
                wasPlaying = false
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
                if model.quality == .auto { adaptResolution(fps: fps, divisor: divisor) }
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
            let hit = model.engine.hitTest(at: cp, time: t)
            model.selectedKeyframe = nil
            if hit != 0 && !event.modifierFlags.contains(.option) {
                model.selection = hit
                dragLayer = hit
                dragStartComp = cp
                dragStartPos = model.engine.value(of: .position, layer: hit, time: t)
                model.engine.beginUndoGroup("Move Layer")
            } else {
                if hit == 0 { model.selection = nil }
                panStartView = p
                panStart = model.pan
            }
        }

        func mouseDragged(_ p: CGPoint, event: NSEvent) {
            if dragLayer != 0 {
                let cp = geometry.toComp(p)
                var d = CGPoint(x: cp.x - dragStartComp.x, y: cp.y - dragStartComp.y)
                if event.modifierFlags.contains(.shift) {  // constrain to the dominant axis
                    if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 }
                }
                let t = model.time.time
                let v = model.engine.parentSpaceVector(d, layer: dragLayer, time: t)
                var pos = dragStartPos
                pos.x += v.x
                pos.y += v.y
                model.edit { _ = $0.setPropertyValue(pos, prop: .position, layer: dragLayer, time: t) }
            } else if let start = panStartView {
                if model.zoom == nil { model.zoom = geometry.scale }
                model.pan = CGSize(width: panStart.width + p.x - start.x, height: panStart.height + p.y - start.y)
            }
        }

        func mouseUp(_ p: CGPoint, event: NSEvent) {
            if dragLayer != 0 {
                model.engine.endUndoGroup()
                model.refresh()
            }
            dragLayer = 0
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
