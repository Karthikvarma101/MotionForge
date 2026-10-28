import AppKit
import MFRender
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.33, green: 0.62, blue: 1.0)
    static let keyframe = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let panel = Color(white: 0.135)
    static let panelDark = Color(white: 0.105)
    static let row = Color(white: 0.155)
    static let rowSelected = Color(red: 0.20, green: 0.30, blue: 0.46)
    static let bar = Color(red: 0.36, green: 0.42, blue: 0.55)
    static let barSelected = Color(red: 0.42, green: 0.55, blue: 0.80)
    static let value = Color(red: 0.45, green: 0.72, blue: 1.0)
    static let audio = Color(red: 0.36, green: 0.82, blue: 0.68)
    static let audioBar = Color(red: 0.16, green: 0.40, blue: 0.36)
    static let audioBarSelected = Color(red: 0.20, green: 0.52, blue: 0.47)
}

/// Number display you can drag left/right to scrub (Shift = ×10, Option = ×0.1) or click to type.
struct ScrubField: View {
    let value: Double
    var step: Double = 1
    var precision: Int = 1
    var suffix: String = ""
    var width: CGFloat = 58
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var editing = false
    @State private var text = ""
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onAppear { focused = true }
            } else {
                Text(formatted)
                    .foregroundStyle(Theme.value)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                if dragStart == nil {
                                    dragStart = value
                                    onBegin()
                                }
                                let flags = NSEvent.modifierFlags
                                let k = flags.contains(.shift) ? 10.0 : flags.contains(.option) ? 0.1 : 1.0
                                onChange((dragStart ?? value) + Double(g.translation.width) * step * k)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                onEnd()
                            }
                    )
                    .onTapGesture {
                        text = String(format: "%.\(precision)f", value)
                        editing = true
                    }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(width: width, alignment: .leading)
    }

    private var formatted: String { String(format: "%.\(precision)f", value) + suffix }

    private func commit() {
        guard editing else { return }
        editing = false
        let cleaned = text.replacingOccurrences(of: suffix, with: "").trimmingCharacters(in: .whitespaces)
        if let v = Double(cleaned) {
            onBegin()
            onChange(v)
            onEnd()
        }
    }
}

struct StopwatchButton: View {
    let animated: Bool
    var baked = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: baked ? "waveform.path" : animated ? "stopwatch.fill" : "stopwatch")
                .foregroundStyle(baked ? Theme.accent : animated ? Theme.keyframe : .secondary)
        }
        .buttonStyle(.plain)
        .help(baked ? "Baked animation (one value per frame, e.g. imported from After Effects). Editing the value shifts the whole animation; click to replace it with a keyframe at the playhead."
              : animated ? "Remove all keyframes" : "Animate this property (adds a keyframe at the playhead)")
    }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }
}

/// Keyframe glyph: diamond for linear, hourglass-ish for eased, square for hold.
struct KeyframeGlyph: View {
    let interp: MFInterp
    let selected: Bool
    var body: some View {
        let fill = selected ? Theme.accent : Theme.keyframe
        Group {
            switch interp {
            case .hold: Rectangle().fill(fill).frame(width: 8, height: 8)
            case .bezier: Circle().fill(fill).frame(width: 9, height: 9)
            default: Diamond().fill(fill).frame(width: 10, height: 10)
            }
        }
        .overlay(selected ? AnyView(Diamond().stroke(.white, lineWidth: 1).frame(width: 13, height: 13)) : AnyView(EmptyView()))
    }
}

extension MFValue {
    var color: Color { Color(.sRGB, red: x, green: y, blue: z, opacity: w) }
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(x: Double(ns.redComponent), y: Double(ns.greenComponent), z: Double(ns.blueComponent),
                  w: Double(ns.alphaComponent))
    }
    subscript(i: Int) -> Double {
        get { [x, y, z, w][i] }
        set {
            switch i {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            default: w = newValue
            }
        }
    }
}

extension MFLayerInfo {
    var icon: String {
        switch kind {
        case .image: return "photo"
        case .text: return "textformat"
        case .null: return "square.dashed"
        case .precomp: return "square.stack.3d.up"
        case .audio: return "waveform"
        default:
            switch shape {
            case .ellipse: return "circle"
            case .polygon: return "hexagon"
            case .star: return "star"
            case .path: return "scribble"
            default: return "rectangle"
            }
        }
    }

    /// Properties shown for this layer, in display order.
    var editableProps: [MFProp] {
        if kind == .audio { return [.audioLevel] }
        var p: [MFProp] = [.anchorPoint, .position, .scale, .rotation, .opacity]
        if kind == .text { return p + [.fontSize, .tracking, .lineHeight, .fillColor, .strokeColor, .strokeWidth] }
        if kind == .precomp { return timeRemapEnabled ? p + [.timeRemap] : p }
        if kind == .shape && shape == .path { return p + [.fillColor, .strokeColor, .strokeWidth, .trimStart, .trimEnd, .trimOffset] }
        if kind == .shape {
            p += [.size]
            if shape != .ellipse { p += [.roundness] }
            if shape == .polygon || shape == .star { p += [.points] }
            if shape == .star { p += [.innerRatio] }
            p += [.fillColor, .strokeColor, .strokeWidth]
        }
        return p
    }
}

extension MFProp {
    var isColor: Bool { self == .fillColor || self == .strokeColor }
    var step: Double {
        switch self {
        case .scale, .opacity, .trimStart, .trimEnd, .trimOffset, .fontSize: return 0.5
        case .lineHeight: return 0.01
        case .rotation: return 0.5
        case .points, .audioLevel: return 0.1
        case .innerRatio: return 0.005
        default: return 1
        }
    }
    var precision: Int {
        switch self {
        case .points: return 0
        case .innerRatio, .lineHeight: return 2
        default: return 1
        }
    }
    var suffix: String {
        switch self {
        case .scale, .opacity, .trimStart, .trimEnd, .trimOffset: return "%"
        case .rotation: return "°"
        case .audioLevel: return " dB"
        default: return ""
        }
    }
}

// MARK: - Generic property addressing (layer, mask and effect parameters)

extension MFPropRef: @retroactive Equatable {
    public static func == (a: MFPropRef, b: MFPropRef) -> Bool {
        a.owner == b.owner && a.ownerID == b.ownerID && a.index == b.index
    }
}

extension MFPropRef: @retroactive Hashable {
    public func hash(into h: inout Hasher) {
        h.combine(owner.rawValue)
        h.combine(ownerID)
        h.combine(index)
    }
}

extension MFPropRef {
    static func layer(_ p: MFProp) -> MFPropRef { MFPropRefMake(p) }
    /// Position-like properties have motion paths (layer position / anchor point, mask position).
    var isSpatial: Bool {
        (owner == .layer && (index == MFProp.position.rawValue || index == MFProp.anchorPoint.rawValue))
            || (owner == .mask && index == 0)
    }
    var id: String { "\(owner.rawValue)-\(ownerID)-\(index)" }
}

/// Everything a property editor needs to show and edit one animatable parameter.
struct ParamSpec: Identifiable {
    let ref: MFPropRef
    let label: String
    let dims: Int
    let isColor: Bool
    let unit: String
    let step: Double
    let precision: Int
    let linkedScale: Bool
    var id: String { ref.id }

    init(_ p: MFProp) {
        ref = .layer(p)
        label = MFPropLabel(p)
        dims = MFPropDimensions(p)
        isColor = p.isColor
        unit = p.suffix
        step = p.step
        precision = p.precision
        linkedScale = p == .scale
    }

    init(_ info: MFParamInfo) {
        ref = info.ref
        label = info.label
        dims = info.dimensions
        isColor = info.isColor
        unit = info.unit == "px" ? "" : info.unit
        step = info.step
        precision = 1
        linkedScale = false
    }
}

extension MFEffectType {
    var icon: String {
        switch self {
        case .gaussianBlur: return "drop"
        case .dropShadow: return "shadow"
        case .glow: return "sun.max"
        case .brightnessContrast: return "circle.lefthalf.filled"
        case .hueSaturation: return "paintpalette"
        case .fill: return "paintbrush"
        case .gradientRamp: return "square.lefthalf.filled"
        @unknown default: return "wand.and.stars"
        }
    }
}

extension MFMatteMode {
    var label: String {
        switch self {
        case .alpha: return "Alpha Matte"
        case .alphaInverted: return "Alpha Inverted"
        case .luma: return "Luma Matte"
        case .lumaInverted: return "Luma Inverted"
        default: return "No Matte"
        }
    }
}

extension MFMaskMode {
    var label: String {
        switch self {
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        case .difference: return "Difference"
        default: return "Add"
        }
    }
}
