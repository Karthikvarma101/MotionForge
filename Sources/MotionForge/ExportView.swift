import AppKit
import MFRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export state

/// A running or finished export, shown in the export window and the status bar.
struct ExportStatus {
    let url: URL
    var settings: String = ""   // "H.264 · 1920×1080 · 35 Mb/s"
    var done = 0
    var total = 0
    var fps = 0.0               // average since the start
    var elapsed = 0.0
    var finished = false
    var error: String?

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var remaining: Double? { fps > 0 && done < total ? Double(total - done) / fps : nil }
    var cancelled: Bool { error?.localizedCaseInsensitiveContains("cancel") == true }
}

extension MFExportFormat {
    var label: String {
        switch self {
        case .h264: return "H.264 (.mp4)"
        case .hevc: return "HEVC / H.265 (.mp4)"
        case .proRes422: return "ProRes 422 (.mov)"
        case .proRes4444: return "ProRes 4444 with alpha (.mov)"
        case .pngSequence: return "PNG sequence (folder)"
        @unknown default: return "?"
        }
    }
    var shortLabel: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .proRes422: return "ProRes 422"
        case .proRes4444: return "ProRes 4444"
        case .pngSequence: return "PNG sequence"
        @unknown default: return "?"
        }
    }
    var fileExtension: String? {
        switch self {
        case .h264, .hevc: return "mp4"
        case .proRes422, .proRes4444: return "mov"
        default: return nil
        }
    }
    var hasBitrate: Bool { self == .h264 || self == .hevc }
}

extension EditorModel {
    /// Where exports go by default: the shared export drive when it is mounted, else ~/Movies.
    static var defaultExportFolder: URL {
        let drive = URL(fileURLWithPath: "/Volumes/Extreme SSD/YOGA/eXPORTED", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDir), isDir.boolValue { return drive }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    /// The export window: settings, then the running export's progress and load.
    func showExportWindow() {
        ExportWindowController.shared.show(model: self)
    }

    /// Asks where to write, then renders in the background from a snapshot of the project.
    func chooseDestinationAndExport(_ settings: MFExportSettings, summary: String) {
        let base = comp.name.isEmpty ? displayName : comp.name
        let url: URL
        if let ext = settings.format.fileExtension {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [ext == "mp4" ? .mpeg4Movie : .quickTimeMovie]
            panel.directoryURL = Self.defaultExportFolder
            panel.nameFieldStringValue = "\(base).\(ext)"
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Frames go into a new folder “\(base) frames” here."
            panel.directoryURL = Self.defaultExportFolder
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            url = dir.appendingPathComponent("\(base) frames", isDirectory: true)
        }
        startExport(settings, to: url, summary: summary)
    }

    func startExport(_ settings: MFExportSettings, to url: URL, summary: String = "") {
        guard exporter == nil else { return }
        closeCoalescedEdit()
        let x: MFVideoExporter
        do {
            x = try MFVideoExporter(engine: engine, settings: settings, outputPath: url.path)
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
            return
        }
        exporter = x
        exportStatus = ExportStatus(url: url, settings: summary)
        // Both callbacks arrive on the main queue.
        x.start(progress: { [weak self] p in
            MainActor.assumeIsolated {
                guard let self, var s = self.exportStatus, !s.finished else { return }
                s.done = p.framesDone
                s.total = p.framesTotal
                s.fps = p.framesPerSecond
                s.elapsed = p.elapsed
                self.exportStatus = s
            }
        }, completion: { [weak self] error in
            let message = error?.localizedDescription
            MainActor.assumeIsolated {
                guard let self else { return }
                var s = self.exportStatus ?? ExportStatus(url: url)
                s.finished = true
                s.error = message
                self.exportStatus = s
                self.exporter = nil
                if message == nil { NSSound(named: "Glass")?.play() }
            }
        })
    }

    func cancelExport() {
        exporter?.cancel()
    }
}

// MARK: - Window

/// A floating panel above the editor; it stays open while the export runs so you can keep watching.
@MainActor
final class ExportWindowController {
    static let shared = ExportWindowController()
    private var panel: NSPanel?

    func show(model: EditorModel) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "Export"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.becomesKeyOnlyIfNeeded = false
            let host = NSHostingController(rootView: ExportPanel(model: model) { [weak self] in self?.close() })
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            panel = p
        }
        guard let panel else { return }
        if !panel.isVisible, let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title.hasPrefix("MotionForge") || $0.isMainWindow }) {
            let f = main.frame, s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2 + 40))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }
    var isVisible: Bool { panel?.isVisible ?? false }
}

struct ExportPanel: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = model.exportStatus {
                ExportProgressView(model: model, status: s, close: close)
            } else {
                ExportSettingsForm(model: model, close: close)
            }
        }
        .frame(width: 600)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings

struct ExportSettingsForm: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    @State private var format: MFExportFormat = .h264
    @State private var scale = 1.0
    @State private var wholeComp = true
    @State private var from = 0.0
    @State private var to = 0.0
    @State private var rate = 0      // 0 automatic, 10 / 35 presets, -1 custom
    @State private var customMbps = 20.0
    @State private var motionBlur = true
    @State private var includeAudio = true
    @State private var audio: URL?

    private var c: MFCompositionInfo { model.comp }
    private var mbps: Double { rate == -1 ? customMbps : Double(rate) }
    private var duration: Double { wholeComp ? c.duration : max(0, to - from) }
    private var audioLayers: Int { model.audio.isAudible ? model.engine.audioClips().count : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExportHeader(title: "Export “\(c.name)”",
                         subtitle: "\(c.width)×\(c.height) · \(fpsString(c.fps)) fps · \(Timecode.string(c.duration, fps: c.fps))")
            Form {
                Picker("Format", selection: $format) {
                    ForEach([MFExportFormat.h264, .hevc, .proRes422, .proRes4444, .pngSequence], id: \.rawValue) { f in
                        Text(f.label).tag(f)
                    }
                }
                Picker("Size", selection: $scale) {
                    Text("Full — \(c.width)×\(c.height)").tag(1.0)
                    Text("Half — \(c.width / 2)×\(c.height / 2)").tag(0.5)
                    Text("Quarter — \(c.width / 4)×\(c.height / 4)").tag(0.25)
                }
                Picker("Range", selection: $wholeComp) {
                    Text("Whole composition — \(Timecode.string(c.duration, fps: c.fps))").tag(true)
                    Text("Custom").tag(false)
                }
                if !wholeComp {
                    HStack {
                        Text("From").foregroundStyle(.secondary)
                        ScrubField(value: from, step: 1 / c.fps, precision: 2, suffix: " s",
                                   onBegin: {}, onChange: { from = min(max(0, $0), c.duration) }, onEnd: {})
                        Text("to").foregroundStyle(.secondary)
                        ScrubField(value: to, step: 1 / c.fps, precision: 2, suffix: " s",
                                   onBegin: {}, onChange: { to = min(max(0, $0), c.duration) }, onEnd: {})
                        Button("Playhead → end") { from = model.time.time; to = c.duration }
                            .controlSize(.small)
                    }
                }
                if format.hasBitrate {
                    Picker("Bitrate", selection: $rate) {
                        Text("Automatic").tag(0)
                        Text("Reels — 10 Mb/s").tag(10)
                        Text("YouTube — 35 Mb/s").tag(35)
                        Text("Custom").tag(-1)
                    }
                    if rate == -1 {
                        HStack {
                            ScrubField(value: customMbps, step: 0.5, precision: 1, suffix: " Mb/s",
                                       onBegin: {}, onChange: { customMbps = min(max(1, $0), 400) }, onEnd: {})
                            Spacer()
                        }
                    }
                }
                Toggle("Motion blur", isOn: $motionBlur)
                    .help("Uses the composition's shutter angle and samples for layers with motion blur on")
                if format != .pngSequence {
                    Toggle(audioLayers > 0 ? "Audio layers (\(audioLayers) clip\(audioLayers == 1 ? "" : "s"))" : "Audio layers (none in this composition)",
                           isOn: $includeAudio)
                        .disabled(audioLayers == 0)
                        .help("Mixes the composition's audio layers (including those in precomps) at their levels")
                    HStack {
                        Text("Extra soundtrack")
                        Spacer()
                        Text(audio?.lastPathComponent ?? "None").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseAudio() }
                        if audio != nil { Button("Clear") { audio = nil } }
                    }
                    .help("Mixed in with the audio layers. Its time 0 is the composition's time 0.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(duration <= 0)
            }
        }
        .padding(20)
        .onAppear {
            // The usual delivery targets: portrait = reels, landscape = YouTube.
            rate = c.height > c.width ? 10 : 35
            to = c.duration
        }
    }

    private var outputSize: String { "\(Int(Double(c.width) * scale))×\(Int(Double(c.height) * scale))" }

    private var summary: String {
        let frames = Int((duration * c.fps).rounded())
        var s = "\(frames) frames at \(fpsString(c.fps)) fps, \(outputSize)"
        if format.hasBitrate && mbps > 0 { s += String(format: ", at most ~%.0f MB", mbps * duration / 8) }
        s += ". Renders in the background — you can keep working."
        return s
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { audio = panel.url }
    }

    private func export() {
        let s = MFExportSettings()
        s.format = format
        s.scale = scale
        s.startTime = wholeComp ? 0 : from
        s.endTime = wholeComp ? 0 : to
        s.motionBlur = motionBlur
        s.bitsPerSecond = format.hasBitrate && mbps > 0 ? Int(mbps * 1_000_000) : 0
        s.includeAudioLayers = includeAudio
        s.audioPath = format == .pngSequence ? nil : audio?.path
        var parts = [format.shortLabel, outputSize]
        if format.hasBitrate { parts.append(mbps > 0 ? String(format: "%.0f Mb/s", mbps) : "automatic bitrate") }
        if format != .pngSequence && ((includeAudio && audioLayers > 0) || audio != nil) { parts.append("with audio") }
        let summary = parts.joined(separator: " · ")
        DispatchQueue.main.async { model.chooseDestinationAndExport(s, summary: summary) }
    }
}

private struct ExportHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            ForgeGlyph().frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

// MARK: - Progress

/// Samples CPU / GPU load and the export's current speed once a second while the window shows an
/// export. Lives as long as the window, not the (frequently rebuilt) view.
@MainActor
final class ExportLoadMonitor: ObservableObject {
    static let historyLength = 60
    @Published private(set) var cpu: [Double] = []
    @Published private(set) var app: [Double] = []
    @Published private(set) var gpu: [Double] = []
    @Published private(set) var speed: [Double] = []
    @Published private(set) var smoothedFPS = 0.0
    private var sampler = SystemLoadSampler()
    private var timer: Timer?
    private var lastDone: (frames: Int, at: Date)?
    private weak var model: EditorModel?

    func start(model: EditorModel) {
        self.model = model
        guard timer == nil else { return }
        _ = sampler.sample()  // baseline for the first deltas
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let s = sampler.sample()
        push(&cpu, s.cpu)
        push(&app, s.app)
        push(&gpu, s.gpu)
        guard let st = model?.exportStatus, !st.finished else { return }
        let now = Date()
        if let l = lastDone, now.timeIntervalSince(l.at) > 0.2, st.done >= l.frames {
            let instant = Double(st.done - l.frames) / now.timeIntervalSince(l.at)
            smoothedFPS = smoothedFPS > 0 ? smoothedFPS * 0.6 + instant * 0.4 : instant
            push(&speed, instant)
        }
        lastDone = (st.done, now)
    }

    private func push(_ a: inout [Double], _ v: Double?) {
        guard let v else { return }
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }
}

struct ExportProgressView: View {
    @ObservedObject var model: EditorModel
    let status: ExportStatus
    let close: () -> Void
    @StateObject private var load = ExportLoadMonitor()

    private var running: Bool { !status.finished }
    private var cpu: [Double] { load.cpu }
    private var app: [Double] { load.app }
    private var gpu: [Double] { load.gpu }
    private var speed: [Double] { load.speed }
    private var smoothedFPS: Double { load.smoothedFPS }
    private var remaining: Double? {
        let f = smoothedFPS > 0 ? smoothedFPS : status.fps
        return running && f > 0 && status.done < status.total ? Double(status.total - status.done) / f : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ExportHeader(title: headline, subtitle: [status.url.lastPathComponent, status.settings].filter { !$0.isEmpty }.joined(separator: " · "))
            progressBar
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                StatTile(title: "Frames", value: "\(status.done) / \(status.total)",
                         detail: String(format: "%.0f%%", status.fraction * 100))
                StatTile(title: "Speed", value: String(format: "%.0f fps", running ? (smoothedFPS > 0 ? smoothedFPS : status.fps) : status.fps),
                         detail: String(format: "average %.0f fps", status.fps), history: speed, scale: nil, tint: Theme.accent)
                StatTile(title: running ? "Time left" : "Took", value: running ? (remaining.map(clock) ?? "—") : clock(status.elapsed),
                         detail: running ? (remaining.map { "done at " + Date().addingTimeInterval($0).formatted(date: .omitted, time: .shortened) } ?? "estimating…")
                                         : "\(clock(status.elapsed)) for \(status.total) frames")
                StatTile(title: "Elapsed", value: clock(status.elapsed), detail: realTimeNote)
                StatTile(title: "CPU", value: cpu.last.map { String(format: "%.0f%%", $0) } ?? "—",
                         detail: app.last.map { String(format: "MotionForge %.0f%%", $0) } ?? "all cores", history: cpu, tint: Theme.keyframe)
                StatTile(title: "GPU", value: gpu.last.map { String(format: "%.0f%%", $0) } ?? "—",
                         detail: model.perf.stats?.deviceName ?? "Metal", history: gpu, tint: Theme.audio)
            }
            if let error = status.error, !status.cancelled {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 12))
            }
            buttons
        }
        .padding(20)
        .onAppear { load.start(model: model) }
        .onDisappear { load.stop() }
    }

    private var headline: String {
        if !status.finished { return "Exporting…" }
        if status.cancelled { return "Export cancelled" }
        return status.error == nil ? "Export finished" : "Export failed"
    }

    private var realTimeNote: String {
        let duration = Double(status.total) / max(model.comp.fps, 1)
        guard status.elapsed > 0.5, duration > 0 else { return "rendering in the background" }
        let x = Double(status.done) / max(model.comp.fps, 1) / status.elapsed
        return String(format: "%.1f× real time", x)
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressBar(fraction: status.finished && status.error == nil ? 1 : status.fraction,
                        failed: status.error != nil && !status.cancelled)
            HStack {
                Text(String(format: "%.1f%%", (status.finished && status.error == nil ? 1 : status.fraction) * 100))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                Spacer()
                if running { Text("You can keep editing — the export renders from a snapshot.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if running {
                Spacer()
                Button("Hide") { close() }.help("The export keeps running; the status bar shows its progress")
                Button("Cancel Export", role: .destructive) { model.cancelExport() }.keyboardShortcut(.cancelAction)
            } else {
                Button("New Export…") { model.exportStatus = nil }
                Spacer()
                if status.error == nil {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([status.url]) }
                    Button("Open") { NSWorkspace.shared.open(status.url) }
                }
                Button("Done") {
                    model.exportStatus = nil
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t) s"
    }
}

/// A rounded bar in the MotionForge gradient (amber when the export failed).
private struct ProgressBar: View {
    let fraction: Double
    var failed = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(failed ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(ForgeGlyph.gradient))
                    .frame(width: max(8, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 8)
    }
}

/// One figure with a caption and, optionally, its last minute as a sparkline.
private struct StatTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var history: [Double] = []
    var scale: Double? = 100   // sparkline top; nil = the largest value shown
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: history, top: scale, tint: tint).frame(height: 18).opacity(history.count > 1 ? 1 : 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

private struct Sparkline: View {
    let values: [Double]
    let top: Double?
    let tint: Color
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let maxV = max(top ?? (values.max() ?? 1) * 1.1, 1e-6)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(v / maxV)))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(tint.opacity(0.18)))
            ctx.stroke(line, with: .color(tint), lineWidth: 1.2)
        }
    }
}

// MARK: - Status bar pill

struct ExportStatusPill: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let s = model.exportStatus {
            HStack(spacing: 6) {
                if let error = s.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(error).lineLimit(1).foregroundStyle(Theme.warning)
                } else if s.finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Exported \(s.url.lastPathComponent) in \(clock(s.elapsed))").lineLimit(1)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                        .buttonStyle(.borderless)
                } else {
                    ProgressView(value: s.fraction).frame(width: 90)
                    Text("Exporting \(s.done)/\(s.total) · \(String(format: "%.0f", s.fps)) fps\(s.remaining.map { " · \(clock($0)) left" } ?? "")")
                        .lineLimit(1)
                    Button { model.cancelExport() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Cancel the export")
                }
                if s.finished {
                    Button { model.exportStatus = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
            .onTapGesture { model.showExportWindow() }
            .help("Show the export window")
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t) s"
    }
}
