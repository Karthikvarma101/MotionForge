import AppKit
import MFRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export state

/// A running or finished export, shown in the status bar.
struct ExportStatus {
    let url: URL
    var done = 0
    var total = 0
    var fps = 0.0
    var elapsed = 0.0
    var finished = false
    var error: String?

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var remaining: Double? { fps > 0 && done < total ? Double(total - done) / fps : nil }
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

    /// Asks where to write, then renders in the background from a snapshot of the project.
    func chooseDestinationAndExport(_ settings: MFExportSettings) {
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
        startExport(settings, to: url)
    }

    func startExport(_ settings: MFExportSettings, to url: URL) {
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
        exportStatus = ExportStatus(url: url)
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
            }
        })
    }

    func cancelExport() {
        exporter?.cancel()
    }
}

// MARK: - Settings sheet

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: MFExportFormat = .h264
    @State private var scale = 1.0
    @State private var wholeComp = true
    @State private var from = 0.0
    @State private var to = 0.0
    @State private var rate = 0      // 0 automatic, 10 / 35 presets, -1 custom
    @State private var customMbps = 20.0
    @State private var motionBlur = true
    @State private var audio: URL?

    private var c: MFCompositionInfo { model.comp }
    private var mbps: Double { rate == -1 ? customMbps : Double(rate) }
    private var duration: Double { wholeComp ? c.duration : max(0, to - from) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export “\(c.name)”").font(.headline)
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
                    HStack {
                        Text("Soundtrack")
                        Spacer()
                        Text(audio?.lastPathComponent ?? "None").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseAudio() }
                        if audio != nil { Button("Clear") { audio = nil } }
                    }
                    .help("MotionForge has no audio layers yet: add the mix here. Its time 0 is the composition's time 0.")
                }
            }
            .formStyle(.grouped)
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(duration <= 0)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // The usual delivery targets: portrait = reels, landscape = YouTube.
            rate = c.height > c.width ? 10 : 35
            to = c.duration
            motionBlur = true
        }
    }

    private var summary: String {
        let frames = Int((duration * c.fps).rounded())
        var s = "\(frames) frames at \(fpsString(c.fps)) fps, \(Int(Double(c.width) * scale))×\(Int(Double(c.height) * scale))"
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
        s.audioPath = audio?.path
        dismiss()
        DispatchQueue.main.async { model.chooseDestinationAndExport(s) }
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
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t) s"
    }
}
