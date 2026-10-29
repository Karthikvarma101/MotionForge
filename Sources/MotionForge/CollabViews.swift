import AppKit
import Combine
import SwiftUI

// MARK: - Friends and shared projects (data for Home, the Friends sheet and the Share sheet)

@MainActor
final class SocialModel: ObservableObject {
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var projects: [SharedProject] = []
    @Published private(set) var loading = false
    @Published var message: String?
    private let account: AccountModel
    private var lastLoad = Date.distantPast

    init(account: AccountModel) { self.account = account }

    var accepted: [Friend] { friends.filter(\.accepted) }
    var incomingRequests: [Friend] { friends.filter { !$0.accepted && $0.incoming } }
    var sentRequests: [Friend] { friends.filter { !$0.accepted && !$0.incoming } }
    var invitations: [SharedProject] { projects.filter { !$0.joined } }
    var joinedProjects: [SharedProject] { projects.filter(\.joined) }

    func load(force: Bool = false) async {
        guard account.isSignedIn, force || Date().timeIntervalSince(lastLoad) > 20 else { return }
        lastLoad = Date()
        loading = true
        defer { loading = false }
        do {
            async let f = CollabAPI.friends(account)
            async let p = CollabAPI.projects(account)
            friends = try await f
            projects = try await p
        } catch {
            message = error.localizedDescription
        }
    }

    func addFriend(email: String) async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.contains("@") else { message = "Enter the email address they sign in to MotionForge with."; return }
        do {
            let result = try await CollabAPI.rpc(account, "send_friend_request", ["friend_email": e]) as? String
            message = result == "accepted" ? "You’re now friends." : result == "already_friends" ? "You’re already friends."
                : result == "already_requested" ? "Request already sent." : "Request sent to \(e)."
            await load(force: true)
        } catch {
            message = error.localizedDescription
        }
    }

    func respond(_ f: Friend, accept: Bool) async {
        do {
            _ = try await CollabAPI.rpc(account, "respond_friend_request", ["request_id": f.friendshipID, "accept": accept])
        } catch { message = error.localizedDescription }
        await load(force: true)
    }

    func remove(_ f: Friend) async {
        do { _ = try await CollabAPI.rpc(account, "remove_friend", ["friend_id": f.id]) } catch { message = error.localizedDescription }
        await load(force: true)
    }

    func invite(_ f: Friend, to project: SharedProject) async -> Bool {
        do {
            _ = try await CollabAPI.rpc(account, "invite_to_project", ["pid": project.id, "friend_id": f.id])
            await load(force: true)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func decline(_ p: SharedProject) async {
        do { _ = try await CollabAPI.rpc(account, "respond_project_invite", ["pid": p.id, "accept": false]) } catch { message = error.localizedDescription }
        await load(force: true)
    }

    func project(_ id: String) -> SharedProject? { projects.first { $0.id == id } }
}

// MARK: - Starting, joining, leaving

extension EditorModel {
    /// Shares the open project (Pro): it becomes a shared project others can join live.
    func startSharing() async {
        guard account.isSignedIn else { alertMessage = "Sign in (top right) to collaborate."; return }
        guard account.isPro else { showPaywall = true; return }
        guard collab == nil else { return }
        do {
            closeCoalescedEdit()
            let id = try await CollabAPI.rpc(account, "create_shared_project", ["project_name": displayName, "pieces": []]) as? String ?? ""
            await social.load(force: true)
            guard let project = social.project(id) else { throw CollabError("The shared project didn’t appear on the server.") }
            let session = CollabSession(project: project, editor: self)
            try await session.startSharing()
            collab = session
        } catch {
            alertMessage = "Couldn’t share: \(error.localizedDescription)"
        }
    }

    /// Opens a shared project (accepting the invitation first if needed).
    func joinSharedProject(_ p: SharedProject) async {
        guard account.isPro else { showPaywall = true; return }
        if collab?.project.id == p.id { showHome = false; return }
        guard confirmDiscardChanges() else { return }
        do {
            var project = p
            if !p.joined {
                _ = try await CollabAPI.rpc(account, "respond_project_invite", ["pid": p.id, "accept": true])
                await social.load(force: true)
                guard let fresh = social.project(p.id) else { throw CollabError("The invitation is no longer open.") }
                project = fresh
            }
            let session = CollabSession(project: project, editor: self)
            try await session.join()
            collab = session
            showSharedProject()
        } catch {
            alertMessage = "Couldn’t open “\(p.name)”: \(error.localizedDescription)"
        }
    }

    func leaveSharedProject() {
        collab?.leave()
        collab = nil
        refresh()
    }

    /// The owner ends sharing for everyone; an editor leaves.
    func stopSharing() async {
        guard let session = collab else { return }
        let id = session.project.id
        leaveSharedProject()
        do { _ = try await CollabAPI.rpc(account, "leave_project", ["pid": id]) } catch { alertMessage = error.localizedDescription }
        await social.load(force: true)
    }
}

// MARK: - People

struct PersonAvatar: View {
    let name: String
    let url: URL?
    var size: CGFloat = 26
    var ring: Color? = nil
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.accent.opacity(0.35))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring ?? Color.white.opacity(0.2), lineWidth: ring == nil ? 1 : 2))
    }
}

extension Color {
    init(hex: Int) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// Toolbar: who else is here, and the Share button.
struct CollabToolbarItem: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: -6) {
            if let collab = model.collab { Presence(collab: collab) }
            Button { model.showShareSheet = true } label: {
                Label("Share", systemImage: model.collab == nil ? "person.crop.circle.badge.plus" : "person.2.fill")
            }
            .help(model.collab == nil ? "Edit this project together with friends (Pro)" : "Shared project: people and invitations")
            .padding(.leading, 10)
        }
    }

    private struct Presence: View {
        @ObservedObject var collab: CollabSession
        var body: some View {
            ForEach(collab.participants.prefix(4)) { p in
                PersonAvatar(name: p.name, url: p.avatarURL, size: 22, ring: Color(hex: p.color))
                    .help("\(p.name) is editing")
            }
            if !collab.connected {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.warning)
                    .help(collab.problem ?? "Connecting…")
                    .padding(.leading, 8)
            }
        }
    }
}

/// Coloured dots on timeline rows: who else has this layer selected.
struct LayerPresenceDots: View {
    @ObservedObject var collab: CollabSession
    let layer: UInt64
    var body: some View {
        let others = collab.others(on: layer)
        if !others.isEmpty {
            HStack(spacing: 2) {
                ForEach(others.prefix(3)) { p in
                    Circle().fill(Color(hex: p.color)).frame(width: 7, height: 7)
                }
            }
            .help(others.map(\.name).joined(separator: ", ") + " selected this layer")
        }
    }
}

// MARK: - Friends sheet

struct FriendsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var social: SocialModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Friends").font(.title3.bold())
                Spacer()
                if social.loading { ProgressView().controlSize(.small) }
            }
            Text("Add people by the email they sign in to MotionForge with. Friends can invite each other to edit a project together.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                TextField("friend@example.com", text: $email).textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add Friend", action: add).disabled(!email.contains("@"))
            }
            if let m = social.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary) }
            List {
                if !social.incomingRequests.isEmpty {
                    Section("Requests for you") {
                        ForEach(social.incomingRequests) { f in
                            row(f) {
                                Button("Accept") { Task { await social.respond(f, accept: true) } }
                                Button("Decline") { Task { await social.respond(f, accept: false) } }
                            }
                        }
                    }
                }
                Section("Friends") {
                    if social.accepted.isEmpty { Text("No friends yet.").foregroundStyle(.secondary) }
                    ForEach(social.accepted) { f in
                        row(f) {
                            Button("Remove") { Task { await social.remove(f) } }.buttonStyle(.borderless)
                        }
                    }
                }
                if !social.sentRequests.isEmpty {
                    Section("Waiting for them") {
                        ForEach(social.sentRequests) { f in
                            row(f) { Button("Cancel") { Task { await social.remove(f) } }.buttonStyle(.borderless) }
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .task { await social.load(force: true) }
    }

    private func add() {
        let e = email
        email = ""
        Task { await social.addFriend(email: e) }
    }

    private func row<Actions: View>(_ f: Friend, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            PersonAvatar(name: f.displayName, url: f.avatarURL, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.displayName).font(.system(size: 12, weight: .medium))
                Text(f.email + (f.isPro ? "" : " · not Pro")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var social: SocialModel
    @ObservedObject var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var invited: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill").foregroundStyle(ForgeGlyph.gradient)
                Text("Edit together").font(.title3.bold())
                Text("PRO").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(ForgeGlyph.gradient)).foregroundStyle(.black)
                Spacer()
            }
            if !account.isSignedIn {
                Text("Sign in with Google (top right) to collaborate.").foregroundStyle(.secondary)
            } else if !account.isPro {
                Text("Collaboration is part of MotionForge Pro: you and everyone you invite need Pro (the free trial counts).")
                    .foregroundStyle(.secondary)
                Button("See Pro Plans") { dismiss(); model.showPaywall = true }.buttonStyle(.borderedProminent)
            } else if let collab = model.collab {
                SharedStatus(collab: collab, model: model)
                inviteList(collab.project)
            } else {
                Text("Share “\(model.displayName)” and invite friends to edit it with you at the same time. Everyone’s changes appear live for everyone; each person’s Undo only undoes their own changes. Images and audio are uploaded so the others get them too.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    working = true
                    Task { await model.startSharing(); working = false }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Start Sharing") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
            if let m = social.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            HStack {
                Button("Friends…") { model.showFriends = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .task { await social.load(force: true) }
    }

    @ViewBuilder private func inviteList(_ project: SharedProject) -> some View {
        let current = social.project(project.id) ?? project
        let members = Set(current.members.map(\.userID))
        Text("People").font(.system(size: 12, weight: .semibold))
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(current.members, id: \.userID) { m in
                    HStack(spacing: 10) {
                        PersonAvatar(name: m.name, url: m.avatarURL, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.system(size: 12, weight: .medium))
                            Text(m.role == "owner" ? "Owner" : m.joined ? "Editor" : "Invited — hasn’t opened it yet")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !m.isPro { Text("needs Pro").font(.system(size: 10)).foregroundStyle(Theme.warning) }
                    }
                }
                let available = social.accepted.filter { !members.contains($0.id) }
                if !available.isEmpty {
                    Divider()
                    Text("Invite friends").font(.system(size: 12, weight: .semibold))
                    ForEach(available) { f in
                        HStack(spacing: 10) {
                            PersonAvatar(name: f.displayName, url: f.avatarURL, size: 26)
                            Text(f.displayName).font(.system(size: 12))
                            if !f.isPro { Text("needs Pro to join").font(.system(size: 10)).foregroundStyle(Theme.warning) }
                            Spacer()
                            Button(invited.contains(f.id) ? "Invited" : "Invite") {
                                Task { if await social.invite(f, to: current) { invited.insert(f.id) } }
                            }
                            .disabled(invited.contains(f.id))
                        }
                    }
                } else if social.accepted.isEmpty {
                    Text("Add friends first (Friends… below), then invite them here.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct SharedStatus: View {
        @ObservedObject var collab: CollabSession
        @ObservedObject var model: EditorModel
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(collab.connected ? Color.green : Theme.warning).frame(width: 8, height: 8)
                    Text(collab.connected ? "Live — \(collab.participants.count) other\(collab.participants.count == 1 ? "" : "s") here now"
                         : (collab.problem ?? "Connecting…"))
                        .font(.system(size: 12))
                    Spacer()
                    Button(collab.project.isOwner ? "Stop Sharing" : "Leave") {
                        Task { await model.stopSharing() }
                    }
                    .help(collab.project.isOwner ? "Ends the shared project for everyone. Your Mac keeps its copy." : "Leave this shared project")
                }
                if collab.pendingUploads > 0 || collab.pendingDownloads > 0 {
                    Text("Syncing media: \(collab.pendingUploads) up, \(collab.pendingDownloads) down")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Home: shared with you

struct SharedProjectsSection: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var social: SocialModel
    @ObservedObject var account: AccountModel
    private let poll = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        if account.isSignedIn && (!social.projects.isEmpty || !social.incomingRequests.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shared").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("Friends…") { model.showFriends = true }.buttonStyle(.borderless)
                }
                if !social.incomingRequests.isEmpty {
                    Label("\(social.incomingRequests.count) friend request\(social.incomingRequests.count == 1 ? "" : "s") waiting",
                          systemImage: "person.badge.plus")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning)
                        .onTapGesture { model.showFriends = true }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(social.invitations + social.joinedProjects) { p in card(p) }
                    }
                }
            }
            .padding(.bottom, 18)
            .onReceive(poll) { _ in Task { await social.load() } }
        } else {
            Color.clear.frame(height: 0)
                .task { await social.load() }
                .onReceive(poll) { _ in Task { await social.load() } }
        }
    }

    private func subtitle(_ p: SharedProject) -> String {
        if !p.joined { return "\(p.ownerName) invited you" }
        return p.isOwner ? "You shared this" : "Shared by \(p.ownerName)"
    }

    private func card(_ p: SharedProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: -5) {
                ForEach(p.members.prefix(4), id: \.userID) { m in PersonAvatar(name: m.name, url: m.avatarURL, size: 22) }
            }
            Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(subtitle(p)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Button(p.joined ? "Open" : "Join") { Task { await model.joinSharedProject(p) } }
                    .buttonStyle(HomeButtonStyle(primary: !p.joined))
                if !p.joined {
                    Button("Decline") { Task { await social.decline(p) } }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.joined ? Color.white.opacity(0.08) : Theme.warning.opacity(0.5)))
    }
}
