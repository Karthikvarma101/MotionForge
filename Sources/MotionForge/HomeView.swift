import AppKit
import MFRender
import SwiftUI

// MARK: - The logo, drawn as shapes so its parts can animate

/// MotionForge's glyph: a rounded trapezoid outline over two bars, in the brand's orange
/// gradient. `outline` (0–1) draws the trapezoid; `bars` (0–1) slides the bars in.
struct ForgeGlyph: View {
    var outline: CGFloat = 1
    var bars: CGFloat = 1
    var glow: CGFloat = 0

    static let gradient = LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.24), Color(red: 1, green: 0.42, blue: 0.1)],
                                         startPoint: .topTrailing, endPoint: .bottomLeading)

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                Trapezoid()
                    .trim(from: 0, to: outline)
                    .stroke(Self.gradient, style: StrokeStyle(lineWidth: w * 0.1, lineCap: .round, lineJoin: .round))
                bar(w, y: 0.486, from: 0.065, to: 0.938, delay: 0.0, direction: 1)
                bar(w, y: 0.679, from: 0.097, to: 0.906, delay: 0.25, direction: -1)
            }
            .shadow(color: Color(red: 1, green: 0.5, blue: 0.1).opacity(0.75 * glow), radius: w * 0.12 * glow)
        }
        .aspectRatio(1 / 0.787, contentMode: .fit)
    }

    private func bar(_ w: CGFloat, y: CGFloat, from x0: CGFloat, to x1: CGFloat, delay: CGFloat, direction: CGFloat) -> some View {
        let p = min(max((bars - delay) / (1 - delay), 0), 1)
        return Capsule()
            .fill(Self.gradient)
            .frame(width: w * (x1 - x0), height: w * 0.108)
            .offset(x: w * x0 + (1 - p) * w * 0.35 * direction, y: w * y)
            .opacity(Double(p))
    }

    private struct Trapezoid: Shape {
        func path(in r: CGRect) -> Path {
            let w = r.width
            var p = Path()
            p.move(to: CGPoint(x: w * 0.25, y: w * 0.05))
            p.addLine(to: CGPoint(x: w * 0.75, y: w * 0.05))
            p.addLine(to: CGPoint(x: w * 0.95, y: w * 0.348))
            p.addLine(to: CGPoint(x: w * 0.05, y: w * 0.348))
            p.closeSubpath()
            return p
        }
    }
}

/// "Motion" in white and "Forge" in orange, revealed letter by letter.
struct ForgeWordmark: View {
    var reveal: CGFloat = 1  // 0–1
    var size: CGFloat = 44

    var body: some View {
        let letters = Array("MotionForge")
        HStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { i in
                let p = min(max(reveal * CGFloat(letters.count) - CGFloat(i), 0), 1)
                Text(String(letters[i]))
                    .foregroundStyle(i < 6 ? AnyShapeStyle(Color.white) : AnyShapeStyle(ForgeGlyph.gradient))
                    .opacity(Double(p))
                    .offset(y: (1 - p) * size * 0.35)
            }
        }
        .font(.system(size: size, weight: .bold, design: .default))
        .kerning(-size * 0.02)
    }
}

// MARK: - Home window

/// What the app opens to: a short launch animation of the logo being forged, then recent projects
/// with thumbnails, and New / Open. Choosing one shows the workspace.
struct HomeView: View {
    @ObservedObject var model: EditorModel
    @Namespace private var logo
    @State private var phase: Phase = .splash
    @State private var bars: CGFloat = 0
    @State private var outline: CGFloat = 0
    @State private var glow: CGFloat = 0
    @State private var word: CGFloat = 0
    @State private var contentShown = false
    @State private var recents: [RecentProject] = []
    @State private var hovered: String?

    enum Phase { case splash, home }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.06), Color(red: 0.09, green: 0.07, blue: 0.06)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if phase == .splash {
                VStack(spacing: 26) {
                    ForgeGlyph(outline: outline, bars: bars, glow: glow)
                        .matchedGeometryEffect(id: "glyph", in: logo)
                        .frame(width: 170)
                    ForgeWordmark(reveal: word, size: 46)
                        .matchedGeometryEffect(id: "word", in: logo)
                }
                .contentShape(Rectangle())
                .onTapGesture { finishSplash() }
            } else {
                home
            }
        }
        .onAppear {
            recents = RecentProjects.all()
            if model.skipLaunchAnimation || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                bars = 1; outline = 1; word = 1
                phase = .home
                withAnimation(.easeOut(duration: 0.3)) { contentShown = true }
            } else {
                runSplash()
            }
        }
        .onChange(of: model.showHome) { _, shown in if shown { recents = RecentProjects.all() } }
    }

    // MARK: launch animation

    private func runSplash() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { bars = 1 }
        withAnimation(.easeInOut(duration: 0.6).delay(0.3)) { outline = 1 }
        withAnimation(.easeOut(duration: 0.35).delay(0.75)) { glow = 1 }
        withAnimation(.easeIn(duration: 0.5).delay(1.1)) { glow = 0.25 }
        withAnimation(.easeOut(duration: 0.55).delay(0.75)) { word = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) { finishSplash() }
    }

    private func finishSplash() {
        guard phase == .splash else { return }
        bars = 1; outline = 1; word = 1
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { phase = .home; glow = 0 }
        withAnimation(.easeOut(duration: 0.45).delay(0.2)) { contentShown = true }
    }

    // MARK: home

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForgeGlyph(glow: 0)
                    .matchedGeometryEffect(id: "glyph", in: logo)
                    .frame(width: 38)
                ForgeWordmark(size: 22)
                    .matchedGeometryEffect(id: "word", in: logo)
                Spacer()
                AccountBadge(account: model.account) { model.showPaywall = true }
                    .padding(.trailing, 8)
                if model.hasOpenWork {
                    Button {
                        model.showHome = false
                    } label: {
                        Label("Back to \(model.displayName)", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 22)

            AnnouncementSlot(account: model.account)

            HStack(alignment: .top, spacing: 34) {
                actions
                    .frame(width: 220, alignment: .topLeading)
                recentGrid
            }
            .padding(.horizontal, 36)
            .opacity(contentShown ? 1 : 0)
            .offset(y: contentShown ? 0 : 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.newProject() } label: {
                Label("New Project", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HomeButtonStyle(primary: true))
            .keyboardShortcut("n")
            Button { model.openProjectPanel() } label: {
                Label("Open Project…", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HomeButtonStyle(primary: false))
            .keyboardShortcut("o")
            Button { model.showStarterScene() } label: {
                Label("Starter Scene", systemImage: "sparkles").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HomeButtonStyle(primary: false))
            .help("A small animated scene to play with")
            Spacer().frame(height: 18)
            Text("Tips").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                tip("Double-click a precomp to open it", "square.stack.3d.up")
                tip("Pinch or ⌥-scroll the timeline to zoom", "arrow.left.and.right")
                tip("⌘M exports video", "square.and.arrow.up")
                tip("File → Home (⇧⌘H) comes back here", "house")
            }
        }
    }

    private func tip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var recentGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent Projects").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(recents.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if recents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Projects you open or save will show up here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 18)], spacing: 18) {
                        ForEach(Array(recents.enumerated()), id: \.element.id) { i, r in
                            card(r)
                                .opacity(contentShown ? 1 : 0)
                                .offset(y: contentShown ? 0 : 14)
                                .animation(.easeOut(duration: 0.4).delay(0.25 + Double(min(i, 8)) * 0.05), value: contentShown)
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func card(_ r: RecentProject) -> some View {
        let exists = r.exists
        let hot = hovered == r.id
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.45))
                if let img = NSImage(contentsOf: r.thumbnailURL) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                } else {
                    ForgeGlyph().frame(width: 46).opacity(0.35)
                }
                if !exists {
                    Label("File not found", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .foregroundStyle(Theme.warning)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hot && exists ? Theme.accent : Color.white.opacity(0.07), lineWidth: hot ? 2 : 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(details(r)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Text(r.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .opacity(exists ? 1 : 0.55)
        .scaleEffect(hot && exists ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hot)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? r.id : (hovered == r.id ? nil : hovered) }
        .onTapGesture { if exists { model.openRecent(r) } }
        .contextMenu {
            Button("Open") { model.openRecent(r) }.disabled(!exists)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }.disabled(!exists)
            Divider()
            Button("Remove from Recents") {
                RecentProjects.remove(r.path)
                recents = RecentProjects.all()
            }
        }
        .help(exists ? r.path : "Missing: \(r.path)")
    }

    private func details(_ r: RecentProject) -> String {
        var parts: [String] = []
        if r.width > 0 { parts.append("\(r.width)×\(r.height)") }
        if r.duration > 0 { parts.append(Timecode.string(r.duration, fps: r.fps > 0 ? r.fps : 30)) }
        if r.compositions > 1 { parts.append("\(r.compositions) comps") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        parts.append("opened " + f.localizedString(for: r.opened, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }
}

private struct HomeButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(primary ? AnyShapeStyle(ForgeGlyph.gradient) : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            )
            .opacity(configuration.isPressed && primary ? 0.85 : 1)
    }
}

/// The admin console's announcement, when there is one (watches the account model for changes).
private struct AnnouncementSlot: View {
    @ObservedObject var account: AccountModel
    var body: some View {
        if !account.settings.announcement.isEmpty {
            AnnouncementBanner(text: account.settings.announcement, style: account.settings.announcementStyle)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)
        }
    }
}

/// The message set in the admin console (Settings → Announcement), shown on Home.
struct AnnouncementBanner: View {
    let text: String
    let style: String
    private var tint: Color {
        switch style {
        case "success": return .green
        case "warning": return Theme.warning
        default: return Theme.accent
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style == "warning" ? "exclamationmark.triangle.fill" : style == "success" ? "checkmark.seal.fill" : "megaphone.fill")
                .foregroundStyle(tint)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
    }
}
