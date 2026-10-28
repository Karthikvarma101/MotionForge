import AppKit
import MFRender
import SwiftUI

// MARK: - Viewport (zoom + scroll of the time axis)

/// What part of the composition's duration the timeline shows. Kept outside `EditorModel` so a
/// stream of scroll / pinch events only redraws the timeline, not the whole editor.
@MainActor
final class TimelineViewport: ObservableObject {
    @Published var zoom: Double = 1   // 1 = the whole composition fits
    @Published var start: Double = 0  // seconds at the left edge of the track area
    // Set by the timeline on layout.
    var trackWidth: CGFloat = 600
    var duration: Double = 10
    var fps: Double = 30
    /// Set while returning to a composition: its restored scroll position wins over following
    /// the playhead for that one time change.
    var skipNextReveal = false

    var visible: Double { duration / zoom }
    /// Deep enough for ~40 px per frame, however long the composition is.
    var maxZoom: Double { max(1, duration * fps * 40 / Double(max(trackWidth, 50))) }

    func clamp() {
        zoom = min(max(zoom, 1), maxZoom)
        start = min(max(0, start), max(0, duration - visible))
    }

    /// Zooms by `factor`, keeping the time under `anchorX` (x in the track area) where it is.
    func zoom(by factor: Double, anchorX: CGFloat) {
        let w = Double(max(trackWidth, 1))
        let frac = min(max(Double(anchorX) / w, 0), 1)
        let anchorTime = start + frac * visible
        zoom = min(max(zoom * factor, 1), maxZoom)
        start = anchorTime - frac * visible
        clamp()
    }

    /// Scrolls by a distance in track pixels (positive = content moves right, earlier time).
    func pan(pixels dx: CGFloat) {
        start -= Double(dx) / Double(max(trackWidth, 1)) * visible
        clamp()
    }

    func fit() {
        zoom = 1
        start = 0
    }

    /// Scrolls just enough to bring `t` into view (playback, jumping between keys).
    func reveal(_ t: Double) {
        if skipNextReveal {
            skipNextReveal = false
            return
        }
        guard zoom > 1, t < start || t > start + visible else { return }
        start = t - visible * 0.1
        clamp()
    }

    func x(of t: Double) -> CGFloat { CGFloat((t - start) / visible) * trackWidth }
}

// MARK: - Composition stack: tabs + breadcrumb

/// After Effects-style timeline tabs (every composition opened in this session) above a
/// breadcrumb of how the current one was reached (master › scene › rig). Opening a precomp maps
/// the playhead into its time; going back restores where you were in the parent.
struct CompositionStackBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            tabs
            breadcrumb
        }
        .background(Theme.panelDark)
    }

    private var tabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(model.compTabs, id: \.self) { id in
                        tab(id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 26)
            .onChange(of: model.comp.compID) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
    }

    private func tab(_ id: UInt64) -> some View {
        let info = model.compositions.first { $0.compID == id }
        let current = id == model.comp.compID
        return HStack(spacing: 5) {
            Image(systemName: "film").font(.system(size: 9)).foregroundStyle(current ? Theme.accent : .secondary)
            Text(info?.name ?? "?").lineLimit(1).font(.system(size: 11, weight: current ? .semibold : .regular))
            if model.compTabs.count > 1 {
                Button { model.closeCompositionTab(id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close this timeline")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(current ? Theme.panel : Color.white.opacity(0.03)))
        .overlay(alignment: .bottom) {
            if current { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openComposition(id) }
        .help(info.map { "\($0.name) — \($0.width)×\($0.height), \(Timecode.string($0.duration, fps: $0.fps))" } ?? "")
        .id(id)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { model.goToParentComposition() } label: { Image(systemName: "arrow.up.left") }
                .buttonStyle(.borderless)
                .disabled(model.compTrail.count < 2)
                .help("Back to the parent composition (⌘⇧↑)")
            ForEach(Array(model.compTrail.enumerated()), id: \.offset) { i, id in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                let name = model.compositions.first { $0.compID == id }?.name ?? "?"
                if id == model.comp.compID {
                    Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                } else {
                    Button(name) { model.openComposition(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            let children = model.precompsInCurrentComposition
            if !children.isEmpty {
                Menu {
                    ForEach(children, id: \.compID) { c in
                        Button(c.name) { model.openPrecomp(sourceID: c.compID) }
                    }
                } label: {
                    Label("\(children.count) precomp\(children.count == 1 ? "" : "s")", systemImage: "square.stack.3d.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 10))
                .help("Open a composition used in this one")
            }
            let parents = model.parentsOfCurrentComposition
            if !parents.isEmpty {
                Menu {
                    ForEach(parents, id: \.compID) { c in
                        Button(c.name) { model.openComposition(c.compID) }
                    }
                } label: {
                    Label("used in \(parents.count)", systemImage: "arrow.turn.left.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 10))
                .help("Compositions that contain this one")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }
}

// MARK: - Trackpad / mouse gestures over the timeline

/// Turns scroll-wheel and trackpad events over the timeline into zoom and scroll:
///   pinch, or ⌥ / ⌘ + scroll           zoom around the pointer
///   two-finger horizontal swipe, ⇧ + wheel   scroll through time
///   plain vertical scrolling           left alone (scrolls the layer list)
/// Events are read with a local monitor (by position), so the view never takes clicks and the
/// layer list's own scroll view keeps working.
struct TimelineGestureCatcher: NSViewRepresentable {
    /// x of the track area's left edge inside this view.
    let trackOffset: CGFloat
    let viewport: TimelineViewport

    func makeNSView(context: Context) -> TimelineGestureView {
        let v = TimelineGestureView()
        v.trackOffset = trackOffset
        v.viewport = viewport
        return v
    }

    func updateNSView(_ v: TimelineGestureView, context: Context) {
        v.trackOffset = trackOffset
        v.viewport = viewport
    }
}

final class TimelineGestureView: NSView {
    var trackOffset: CGFloat = 0
    weak var viewport: TimelineViewport?
    private var monitor: Any?
    private var lockedAxis: Int?  // per trackpad gesture: 0 = horizontal (ours), 1 = vertical (layer list)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never takes clicks

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let e = event  // local monitors run on the main thread
            return MainActor.assumeIsolated { self.handle(e) } ? nil : event
        }
    }

    /// Where the event is in this view, if it's over it (synthesized events may carry only a
    /// screen position).
    private func location(of event: NSEvent) -> CGPoint? {
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        let inWindow: CGPoint
        if let w = event.window {
            guard w === window else { return nil }
            inWindow = event.locationInWindow
        } else {
            inWindow = window.convertPoint(fromScreen: event.locationInWindow)
        }
        let p = convert(inWindow, from: nil)
        return bounds.contains(p) ? p : nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let viewport, let p = location(of: event) else { return false }
        let x = p.x - trackOffset
        if event.type == .magnify {
            viewport.zoom(by: 1 + Double(event.magnification), anchorX: x)
            return true
        }
        // Lines (wheel mice) to pixels; trackpads and Magic Mouse report pixels already.
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        var dx = event.scrollingDeltaX * k, dy = event.scrollingDeltaY * k
        let mods = event.modifierFlags.intersection([.command, .option, .shift])
        if mods.contains(.option) || mods.contains(.command) {
            // Device direction, so "scroll up" zooms in whatever the natural-scrolling setting.
            if event.isDirectionInvertedFromDevice { dy = -dy; dx = -dx }
            let amount = abs(dy) >= abs(dx) ? dy : dx
            viewport.zoom(by: exp(Double(amount) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.004)), anchorX: x)
            return true
        }
        if mods.contains(.shift) && dx == 0 { (dx, dy) = (dy, 0) }  // ⇧ + wheel on mice that don't swap
        // One axis per trackpad gesture, so a slightly diagonal swipe doesn't do both.
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) { lockedAxis = nil }
        if lockedAxis == nil, dx != 0 || dy != 0 { lockedAxis = abs(dx) > abs(dy) ? 0 : 1 }
        guard lockedAxis == 0 else { return false }
        viewport.pan(pixels: dx)
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
