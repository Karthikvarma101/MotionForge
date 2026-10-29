import MFRender
import SwiftUI

/// Every keyboard shortcut, grouped; Help ▸ Keyboard Shortcuts (⌘/) shows it.
enum ShortcutCatalog {
    struct Item: Identifiable {
        let name: String
        let keys: String
        var id: String { name }
    }

    struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "File", items: [
            Item(name: "New Project", keys: "⌥⌘N"),
            Item(name: "New Composition", keys: "⌘N"),
            Item(name: "Open Project", keys: "⌘O"),
            Item(name: "Save", keys: "⌘S"),
            Item(name: "Save As", keys: "⇧⌘S"),
            Item(name: "Import", keys: "⌘I"),
            Item(name: "Export Video (Render Queue)", keys: "⌘M"),
            Item(name: "Export with Last Settings", keys: "⌥⌘M"),
            Item(name: "Composition Settings", keys: "⌘K"),
            Item(name: "Preferences", keys: "⌥⌘;  or  ⌘,"),
        ]),
        Section(title: "Edit", items: [
            Item(name: "Undo", keys: "⌘Z"),
            Item(name: "Redo / Step Forward", keys: "⇧⌘Z"),
            Item(name: "Step Backward", keys: "⌥⌘Z"),
            Item(name: "Cut", keys: "⌘X"),
            Item(name: "Copy", keys: "⌘C"),
            Item(name: "Paste", keys: "⌘V"),
            Item(name: "Duplicate", keys: "⌘D"),
            Item(name: "Select All", keys: "⌘A"),
            Item(name: "Split Layer", keys: "⇧⌘D"),
            Item(name: "Pre-compose", keys: "⇧⌘C"),
            Item(name: "Trim Comp to Work Area", keys: "⇧⌘X"),
            Item(name: "New Camera", keys: "⌥⇧⌘C"),
        ]),
        Section(title: "Tools", items: EditorTool.allCases.map { Item(name: $0.name, keys: $0.shortcut) }),
        Section(title: "Time", items: [
            Item(name: "Play / Stop", keys: "Space"),
            Item(name: "RAM Preview", keys: "0 (keypad)"),
            Item(name: "Next Frame", keys: "Page Down"),
            Item(name: "Previous Frame", keys: "Page Up"),
            Item(name: "Go to Start / End", keys: "Home / End"),
            Item(name: "Work Area Start (Mark In)", keys: "B"),
            Item(name: "Work Area End (Mark Out)", keys: "N"),
        ]),
        Section(title: "Show in the Timeline", items: [
            Item(name: "Position", keys: "P"),
            Item(name: "Rotation", keys: "R"),
            Item(name: "Scale", keys: "S"),
            Item(name: "Opacity", keys: "T"),
            Item(name: "Anchor Point", keys: "A"),
            Item(name: "Animated Properties", keys: "U"),
            Item(name: "Modified Properties", keys: "UU"),
            Item(name: "Add to What's Shown", keys: "⇧ + key"),
        ]),
        Section(title: "Panels", items: [
            Item(name: "Project / Timeline / Inspector / Status", keys: "⌥⌘1–4"),
            Item(name: "Hide All Panels", keys: "⌥⌘0"),
            Item(name: "Claude", keys: "⇧⌘L"),
            Item(name: "Home", keys: "⇧⌘H"),
            Item(name: "Keyboard Shortcuts", keys: "⌘/"),
        ]),
    ]
}

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), spacing: 28, alignment: .top),
                           GridItem(.flexible(), alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard Shortcuts").font(.system(size: 18, weight: .bold))
                Text("The After Effects keys. On a Mac, Ctrl is ⌘ and Alt is ⌥.").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(ShortcutCatalog.sections) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(section.items) { item in
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(item.keys).font(.system(size: 12, design: .rounded).weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 900, height: 560)
    }
}

/// Settings (⌘, or ⌥⌘;): the app-wide choices that otherwise live in the menus.
struct PreferencesView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        TabView {
            Form {
                Toggle("Auto save into the project file every 2 seconds", isOn: $model.autoSaveToFile)
                Text("Unsaved work is also kept for recovery after a crash, whichever you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Picker("Preview quality", selection: $model.quality) {
                    ForEach(PreviewQuality.allCases) { q in Text(q.label).tag(q) }
                }
                Toggle("Transparency grid", isOn: $model.checkerboard)
                Picker("Frame cache", selection: $model.cachePolicy) {
                    Text("Smart (frames that are slow to redraw)").tag(MFCachePolicy.smart)
                    Text("Every frame").tag(MFCachePolicy.all)
                    Text("Off").tag(MFCachePolicy.off)
                }
                Picker("Frame cache size", selection: $model.cacheBudgetMB) {
                    ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { mb in
                        Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                    }
                    if ![512, 1024, 2048, 4096, 8192].contains(model.cacheBudgetMB) {
                        Text("\(model.cacheBudgetMB) MB (default)").tag(model.cacheBudgetMB)
                    }
                }
                Button("Purge Frame Cache") { model.engine.purgeFrameCache() }
            }
            .tabItem { Label("Previews", systemImage: "play.rectangle") }
            Form {
                Button("Connect Claude Desktop…") { model.connectClaudeDesktop() }
                Button("Copy Claude Code Command") { model.copyClaudeCodeCommand() }
                Text("Claude can then build and edit animations in the open project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 330)
    }
}

/// The toolbar's tools, with the shape (Q) or pen options of the one in use.
struct ToolPicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            Picker("Tool", selection: Binding(get: { model.tool }, set: { model.selectTool($0) })) {
                ForEach(EditorTool.allCases, id: \.self) { t in
                    Label("\(t.name) (\(t.shortcut))", systemImage: t == .shape ? model.shapeTool.toolSymbol : t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("\(model.tool.name) tool (\(model.tool.shortcut)): \(model.tool.help)")
            if model.tool == .shape {
                Picker("", selection: $model.shapeTool) {
                    ForEach([MFShapeType.rectangle, .ellipse, .polygon, .star], id: \.self) { s in
                        Label(s.toolName, systemImage: s.toolSymbol).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("The shape the Shape tool draws (Q cycles through them)")
            }
            if model.tool == .pen {
                Picker("", selection: $model.penDrawsMask) {
                    Text("New Shape").tag(false)
                    Text("Mask on Layer").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Draw a new shape layer, or a bezier mask on the selected layer")
            }
        }
    }
}
