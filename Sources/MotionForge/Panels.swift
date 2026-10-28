import Combine
import MFRender
import SwiftUI

// MARK: - Project panel (composition + media)

struct LeftPanel: View {
    @ObservedObject var model: EditorModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Project").tag(0)
                Text("Effects").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.panelDark)
            if tab == 0 { ProjectPanel(model: model) } else { EffectsBrowser(model: model) }
        }
        .background(Theme.panel)
    }
}

/// Searchable list of effects; double-click (or Apply) adds one to the selected layer.
struct EffectsBrowser: View {
    @ObservedObject var model: EditorModel
    @State private var search = ""

    var body: some View {
        let catalog = MFEngine.effectCatalog().filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search)
        }
        VStack(spacing: 0) {
            TextField("Search effects", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                ForEach(Array(Set(catalog.map(\.category))).sorted(), id: \.self) { cat in
                    Section(cat) {
                        ForEach(catalog.filter { $0.category == cat }, id: \.type.rawValue) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: e.type.icon).foregroundStyle(Theme.accent).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.name)
                                    Text(e.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Button("Apply") { model.applyEffect(e.type) }
                                    .controlSize(.small)
                                    .disabled(model.selectedLayer == nil || model.selectedLayer?.kind == .null)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.applyEffect(e.type) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 160)
            Divider()
            PresetsList(model: model, search: search)
            Text(model.selectedLayer.map { "Applies to “\($0.name)”\(model.selectedLayers.count > 1 ? " + \(model.selectedLayers.count - 1) more" : "")" } ?? "Select a layer to apply effects or presets")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(8)
        }
    }
}

/// Built-in animation presets by category, then the user's saved presets.
struct PresetsList: View {
    @ObservedObject var model: EditorModel
    let search: String

    var body: some View {
        let all = MFEngine.builtInPresets() + model.userPresets
        let shown = all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
        let order = ["Entrances", "Exits", "Attention", "Styles", "Text", "My Presets"]
        let cats = Array(Set(shown.map(\.category))).sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        List {
            ForEach(cats, id: \.self) { cat in
                Section("Presets · " + cat) {
                    ForEach(shown.filter { $0.category == cat }, id: \.name) { p in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: cat == "Text" ? "character.cursor.ibeam" : cat == "My Presets" ? "person.crop.square" : "sparkles")
                                .foregroundStyle(Theme.keyframe).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                if !p.summary.isEmpty {
                                    Text(p.summary).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 4)
                            Button("Apply") { model.applyPreset(p) }
                                .controlSize(.small)
                                .disabled(model.selectedLayers.isEmpty)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.applyPreset(p) }
                        .help("Applies at the playhead to the selected layer(s)")
                    }
                }
            }
            if model.userPresets.isEmpty && search.isEmpty {
                Text("Save your own with Layer → Save Animation Preset…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

struct ProjectPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Composition") {
                    if model.compTrail.count > 1, let parent = model.compositions.first(where: { $0.compID == model.compTrail[model.compTrail.count - 2] }) {
                        Button { model.goToParentComposition() } label: {
                            Label("Back to \(parent.name)", systemImage: "chevron.left").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    Button { model.showCompSettings = true } label: {
                        HStack {
                            Image(systemName: "film").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.comp.name)
                                Text("\(model.comp.width)×\(model.comp.height) · \(fpsString(model.comp.fps)) fps · \(Timecode.string(model.comp.duration, fps: model.comp.fps))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Composition settings (⌘K)")
                }
                if model.compositions.count > 1 {
                    Section("Compositions") {
                        CompositionTree(model: model, folder: "", depth: 0)
                    }
                }
                Section("Media") {
                    if model.assets.isEmpty {
                        Text("Drop images here or use Import").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(model.assets, id: \.assetID) { a in
                        HStack(spacing: 8) {
                            Image(systemName: a.missing ? "exclamationmark.triangle.fill" : "photo")
                                .foregroundStyle(a.missing ? Theme.warning : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).lineLimit(1)
                                Text(a.missing ? "Missing — \(a.path)" : "\(a.width)×\(a.height)\(a.loaded ? "" : " · loading…")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.addImageLayer(asset: a.assetID) }
                        .contextMenu {
                            Button("Add to Composition") { model.addImageLayer(asset: a.assetID) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
                                .disabled(a.missing)
                        }
                        .help("Double-click to add as a layer")
                    }
                }
            }
            .listStyle(.sidebar)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.importMedia(urls: [url], addToComposition: false) } }
                    }
                }
                return true
            }
            HStack {
                Button { model.presentImportPanel() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Spacer()
                Button { model.newComposition() } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .help("New composition")
            }
            .padding(8)
        }
        .background(Theme.panel)
    }
}

/// Compositions grouped by folder (imported projects can have thousands: one per shape layer).
struct CompositionTree: View {
    @ObservedObject var model: EditorModel
    let folder: String
    let depth: Int

    var body: some View {
        let here = model.compositions.filter { $0.folder == folder }
        let prefix = folder.isEmpty ? "" : folder + "/"
        let subfolders = Set(model.compositions.compactMap { c -> String? in
            guard c.folder.hasPrefix(prefix), c.folder != folder else { return nil }
            let rest = c.folder.dropFirst(prefix.count)
            return prefix + (rest.split(separator: "/").first.map(String.init) ?? "")
        }).sorted()
        ForEach(subfolders, id: \.self) { sub in
            DisclosureGroup {
                CompositionTree(model: model, folder: sub, depth: depth + 1)
            } label: {
                Label(String(sub.split(separator: "/").last ?? ""), systemImage: "folder").lineLimit(1)
            }
        }
        ForEach(here, id: \.compID) { c in
            let current = c.compID == model.comp.compID
            HStack(spacing: 6) {
                Image(systemName: "film").foregroundStyle(current ? Theme.accent : .secondary)
                Text(c.name).lineLimit(1).fontWeight(current ? .semibold : .regular)
                Spacer(minLength: 4)
                Text("\(c.layerCount)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openComposition(c.compID) }
            .contextMenu {
                Button("Open") { model.openComposition(c.compID) }
                Button("Add to \(model.comp.name)") { model.addPrecompLayer(source: c.compID) }
                    .disabled(current)
            }
            .help("Double-click to open; right-click to add it as a layer")
        }
    }
}

// MARK: - Composition settings

struct CompSettingsSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var width = 1920
    @State private var height = 1080
    @State private var fps = 30.0
    @State private var duration = 10.0
    @State private var background = Color.black

    private struct Preset: Hashable {
        let label: String
        let w: Int
        let h: Int
    }
    private let presets = [
        Preset(label: "16:9 HD 1920×1080", w: 1920, h: 1080),
        Preset(label: "16:9 4K 3840×2160", w: 3840, h: 2160),
        Preset(label: "9:16 Vertical 1080×1920", w: 1080, h: 1920),
        Preset(label: "1:1 Square 1080×1080", w: 1080, h: 1080),
        Preset(label: "4:5 Portrait 1080×1350", w: 1080, h: 1350),
        Preset(label: "21:9 Cinema 2560×1080", w: 2560, h: 1080),
    ]
    private let rates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Composition Settings").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Preset", selection: Binding(get: { presets.first { $0.w == width && $0.h == height } },
                                                    set: { p in if let p { width = p.w; height = p.h } })) {
                    Text("Custom").tag(Preset?.none)
                    ForEach(presets, id: \.self) { p in Text(p.label).tag(Preset?.some(p)) }
                }
                HStack {
                    TextField("Width", value: $width, format: .number).frame(width: 80)
                    Text("×")
                    TextField("Height", value: $height, format: .number).frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                    Button { swap(&width, &height) } label: { Image(systemName: "arrow.left.arrow.right") }
                        .help("Swap orientation")
                }
                Picker("Frame rate", selection: $fps) {
                    ForEach(rates, id: \.self) { r in Text("\(fpsString(r)) fps").tag(r) }
                }
                HStack {
                    TextField("Duration", value: $duration, format: .number.precision(.fractionLength(0...3))).frame(width: 80)
                    Text("seconds").foregroundStyle(.secondary)
                }
                ColorPicker("Background", selection: $background, supportsOpacity: false)
            }
            Text("The background colour is shown in the viewer and used for opaque exports; transparent exports leave it out.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    let ok = model.engine.setCompositionWidth(max(1, min(16384, width)), height: max(1, min(16384, height)),
                                                              fps: fps, duration: max(1 / fps, duration),
                                                              background: MFValue(color: background), name: name)
                    if !ok { model.alertMessage = "Invalid composition settings." }
                    model.refresh()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            let c = model.comp
            name = c.name
            width = c.width
            height = c.height
            fps = rates.min { abs($0 - c.fps) < abs($1 - c.fps) } ?? c.fps
            duration = c.duration
            background = c.background.color
        }
    }
}

// MARK: - Status / performance bar

struct StatusBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var perf: PerfModel
    @ObservedObject var time: TimeModel
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let s = perf.stats
        HStack(spacing: 14) {
            if time.isPlaying {
                metric("Playback", String(format: "%.0f / %@ fps", perf.presentedFPS, fpsString(model.comp.fps)),
                       warn: perf.presentedFPS + 1.5 < model.comp.fps && perf.presentedFPS > 0)
                metric("Dropped", "\(perf.droppedFrames)", warn: perf.droppedFrames > 0)
            }
            metric("Eval", String(format: "%.2f ms", perf.evalMs))
            metric("Encode", perf.lastFrameCached ? "cached" : String(format: "%.2f ms", perf.encodeMs))
            if let s {
                metric("GPU", String(format: "%.2f ms", s.lastGPUMs))
                metric("Frame cache", model.cachePolicy == .off ? "off" : "\(s.cacheFrames) frames · \(mb(s.cacheBytes)) / \(mb(s.cacheBudgetBytes))")
                if s.offscreenLayers > 0 { metric("Effect layers", "\(s.offscreenLayers)") }
                metric("Hit rate", s.cacheHits + s.cacheMisses > 0
                    ? String(format: "%.0f%%", 100 * Double(s.cacheHits) / Double(s.cacheHits + s.cacheMisses)) : "–")
                metric("GPU memory", "\(mb(s.gpuAllocatedBytes)) of \(gb(s.recommendedWorkingSetBytes)) working set")
                if s.pendingMedia > 0 { metric("Media", "\(s.pendingMedia) loading", warn: true) }
            }
            Spacer()
            ExportStatusPill(model: model)
            if let s { Text("\(s.deviceName) · Metal\(s.programmableBlending ? " · tile blending" : "")").foregroundStyle(.secondary) }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.panelDark)
        .onReceive(timer) { _ in
            perf.stats = model.engine.stats()
            let cached = model.engine.cachedFrames(forQualityDivisor: perf.currentDivisor)
            if cached != perf.cachedFrames { perf.cachedFrames = cached }
        }
        .onAppear { perf.stats = model.engine.stats() }
    }

    private func metric(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(warn ? Theme.warning : .primary)
        }
    }

    private func mb(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
    private func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
}
