import AppKit
import SwiftUI

// MARK: - Account badge (Home header, editor toolbar)

/// Signed out: a "Sign in with Google" pill. Signed in: a round avatar (with a gold ring for Pro) — in
/// the Home header with your name and plan — that opens the account card.
struct AccountBadge: View {
    @ObservedObject var account: AccountModel
    var compact = false
    let showPaywall: () -> Void
    @State private var showCard = false

    var body: some View {
        if let user = account.user {
            Button { showCard.toggle() } label: {
                if compact {
                    Avatar(user: user, size: 22, pro: account.entitlement.pro)
                        .padding(2)
                        .contentShape(Circle())
                } else {
                    HStack(spacing: 8) {
                        Avatar(user: user, size: 26, pro: account.entitlement.pro)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(account.entitlement.pro ? "MotionForge Pro" : "Free plan")
                                .font(.system(size: 10)).foregroundStyle(account.entitlement.pro ? Color(red: 0.98, green: 0.78, blue: 0.35) : .secondary)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .help("\(user.name) — \(user.email)")
            .popover(isPresented: $showCard, arrowEdge: .bottom) {
                AccountCard(account: account, user: user) {
                    showCard = false
                    showPaywall()
                }
            }
        } else {
            Button { Task { await account.signInWithGoogle() } } label: {
                HStack(spacing: 7) {
                    if account.busy { ProgressView().controlSize(.small) } else { GoogleMark().frame(width: 13, height: 13) }
                    Text(compact ? "Sign in" : "Sign in with Google").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, compact ? 9 : 12).padding(.vertical, compact ? 3 : 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(account.busy)
            .help(account.isConfigured ? "Sign in with your Google account" : "Accounts aren't set up in this build yet")
        }
    }
}

/// The popover behind the avatar: who you are, your plan, and what you can do about it.
struct AccountCard: View {
    @ObservedObject var account: AccountModel
    let user: AccountModel.User
    let showPaywall: () -> Void

    var body: some View {
        let e = account.entitlement
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(user: user, size: 44, pro: e.pro)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(user.email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: e.pro ? "checkmark.seal.fill" : "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(e.pro ? AnyShapeStyle(ForgeGlyph.gradient) : AnyShapeStyle(Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.pro ? planName(e.planID) : "Free plan").font(.system(size: 12, weight: .semibold))
                    Text(planDetail(e)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            if e.pro {
                Button("Manage Subscription…") { showPaywall() }.frame(maxWidth: .infinity)
            } else {
                Button { showPaywall() } label: {
                    Text("Get MotionForge Pro — from ₹199/month")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(ForgeGlyph.gradient))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Check Subscription") { Task { await account.refreshEntitlement() } }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
                Button("Sign Out") { Task { await account.signOut() } }
                    .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private func planName(_ id: String?) -> String {
        ProPlan.all.first { $0.id == id }.map { "MotionForge Pro · \($0.title)" } ?? "MotionForge Pro"
    }

    private func planDetail(_ e: AccountModel.Entitlement) -> String {
        guard e.pro else { return "Editing and saving are free. Exporting needs Pro." }
        guard let end = e.currentEnd else { return "Active" }
        let date = end.formatted(date: .abbreviated, time: .omitted)
        return e.cancelAtPeriodEnd ? "Ends \(date)" : "Renews \(date)"
    }
}

struct ProTag: View {
    let pro: Bool
    var body: some View {
        Text(pro ? "PRO" : "FREE")
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(pro ? Color.black : Color.secondary)
            .background(Capsule().fill(pro ? AnyShapeStyle(ForgeGlyph.gradient) : AnyShapeStyle(Color.white.opacity(0.1))))
    }
}

/// The Google profile picture in a circle (initial while it loads), ringed in gold for Pro.
private struct Avatar: View {
    let user: AccountModel.User
    let size: CGFloat
    var pro = false
    var body: some View {
        AsyncImage(url: user.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(user.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.accent.opacity(0.35))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(pro ? AnyShapeStyle(ForgeGlyph.gradient) : AnyShapeStyle(Color.white.opacity(0.22)),
                                       lineWidth: pro ? max(1.5, size * 0.07) : 1))
        .frame(width: size, height: size)
    }
}

/// Google's four-colour "G", drawn so no image asset is needed.
struct GoogleMark: View {
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2, c = CGPoint(x: size.width / 2, y: size.height / 2), w = r * 0.38
            func arc(_ from: Double, _ to: Double, _ color: Color) {
                var p = Path()
                p.addArc(center: c, radius: r - w / 2, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                ctx.stroke(p, with: .color(color), lineWidth: w)
            }
            arc(-40, 45, Color(red: 0.26, green: 0.52, blue: 0.96))   // blue
            arc(45, 135, Color(red: 0.20, green: 0.66, blue: 0.33))   // green
            arc(135, 200, Color(red: 0.98, green: 0.74, blue: 0.02))  // yellow
            arc(200, 320, Color(red: 0.92, green: 0.26, blue: 0.21))  // red
            ctx.fill(Path(CGRect(x: c.x, y: c.y - w / 2, width: r, height: w)), with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
        }
    }
}

// MARK: - Paywall / subscription sheet

/// MotionForge Pro: ₹199 a month or ₹399 a year, paid through Razorpay (UPI autopay or card). Exporting needs it.
struct PaywallSheet: View {
    @ObservedObject var account: AccountModel
    /// Called when Pro becomes active while the sheet is open (e.g. to carry on to the export).
    var onPro: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var plan = ProPlan.yearly

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ForgeGlyph().frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MotionForge Pro").font(.system(size: 20, weight: .bold))
                    Text("Exporting is part of Pro").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                AccountBadge(account: account, compact: true) {}
            }
            if account.entitlement.pro {
                activePlan
            } else {
                choosePlan
            }
            if let m = account.message {
                Label(m, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack {
                Text("Payments by Razorpay · UPI autopay or card · cancel any time")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if !account.entitlement.pro { subscribeButton }
            }
        }
        .padding(22)
        .frame(width: 520)
        .onChange(of: account.entitlement.pro) { _, pro in
            if pro {
                dismiss()
                onPro()
            }
        }
        .task { await account.refreshEntitlement() }
    }

    private var choosePlan: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                feature("Export H.264, HEVC, ProRes 422 / 4444 and PNG sequences")
                feature("Up to the composition's full size, with motion blur")
                feature("Add a soundtrack to exported videos")
                feature("Editing, previewing and saving stay free")
            }
            HStack(spacing: 12) {
                ForEach(ProPlan.all) { p in planCard(p) }
            }
            if account.awaitingPayment {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish paying in your browser. Pro unlocks here as soon as Razorpay confirms it.")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Check now") { Task { await account.refreshEntitlement() } }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            }
        }
    }

    private var activePlan: some View {
        let e = account.entitlement
        let planName = ProPlan.all.first { $0.id == e.planID }.map { "\($0.title) · \($0.price)\($0.period)" } ?? "Pro"
        return VStack(alignment: .leading, spacing: 8) {
            Label("You have MotionForge Pro", systemImage: "checkmark.seal.fill").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text(planName).font(.system(size: 12))
            if let end = e.currentEnd {
                Text(e.cancelAtPeriodEnd ? "Cancelled — Pro stays until \(end.formatted(date: .long, time: .omitted))."
                                         : "Renews \(end.formatted(date: .long, time: .omitted)).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !e.cancelAtPeriodEnd {
                Button("Cancel at the end of this period") { Task { await account.cancelSubscription() } }
                    .controlSize(.small)
                    .disabled(account.busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func feature(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.system(size: 12))
    }

    private func planCard(_ p: ProPlan) -> some View {
        let selected = plan == p
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.accent : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(p.price).font(.system(size: 26, weight: .bold))
                Text(p.period).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(p.note ?? "Billed every month").font(.system(size: 11)).foregroundStyle(p.note != nil ? Theme.accent : .secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(selected ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { plan = p }
    }

    private var subscribeButton: some View {
        Button {
            Task { await account.subscribe(plan) }
        } label: {
            HStack(spacing: 6) {
                if !account.isSignedIn { GoogleMark().frame(width: 12, height: 12) }
                Text(account.isSignedIn ? "Subscribe — \(plan.price)\(plan.period)" : "Sign in with Google & subscribe")
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(account.busy || !account.isConfigured)
    }
}
