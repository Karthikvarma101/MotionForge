import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// The Supabase project behind accounts and MotionForge Pro. The publishable key is meant to ship inside apps
/// (Row Level Security and the Edge Functions decide what it can do). MOTIONFORGE_SUPABASE_URL / _KEY override
/// both for testing against another project.
enum AccountConfig {
    static let url: URL? = URL(string: ProcessInfo.processInfo.environment["MOTIONFORGE_SUPABASE_URL"]
                                       ?? "https://hknpofgdsqqsnztriguy.supabase.co")  // "MotionForge", Mumbai
    static let publishableKey: String = ProcessInfo.processInfo.environment["MOTIONFORGE_SUPABASE_KEY"]
        ?? "sb_publishable_TJ1my7LWwC18zgnKHEXMZA_lKdBmSBC"
    static let callbackScheme = "motionforge"
    static let redirect = "motionforge://auth-callback"
    static var isConfigured: Bool { url != nil && !publishableKey.isEmpty }

    /// An iOS-type OAuth client in the "MotionForge" Google Cloud project. With it, the app signs in with Google
    /// directly and hands Google's ID token to Supabase, so Google's account chooser names the app from that project's
    /// branding. Without it, sign-in goes through Supabase's web flow, where Google names the supabase.co address.
    static let googleClientID = ProcessInfo.processInfo.environment["MOTIONFORGE_GOOGLE_CLIENT_ID"]
        ?? "142670089612-0minolebtsj6srnbrs3lg0o44nn8t5jb.apps.googleusercontent.com"  // "MotionForge Mac" (iOS type)
    /// iOS clients redirect to their own ID reversed: com.googleusercontent.apps.<id>:/oauth2redirect.
    static var googleScheme: String? {
        let suffix = ".apps.googleusercontent.com"
        guard googleClientID.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps." + googleClientID.dropLast(suffix.count)
    }
}

/// A MotionForge Pro plan as sold through Razorpay Subscriptions. Prices come from the server (`plans`, set in
/// the admin console); these built-in ones are used until it has answered.
struct ProPlan: Identifiable, Hashable, Codable {
    let id: String      // plans.id in Supabase
    let title: String
    let amountPaise: Int
    let yearly: Bool
    var note: String?

    var price: String { "₹" + (amountPaise % 100 == 0 ? "\(amountPaise / 100)" : String(format: "%.2f", Double(amountPaise) / 100)) }
    var period: String { yearly ? "/year" : "/month" }

    static let monthly = ProPlan(id: "pro_monthly", title: "Monthly", amountPaise: 19900, yearly: false)
    static let yearly = ProPlan(id: "pro_yearly", title: "Yearly", amountPaise: 49900, yearly: true)
    static let builtIn = withSavings([monthly, yearly])

    /// "Save 83% vs monthly" on yearly plans, against the cheapest monthly one.
    static func withSavings(_ plans: [ProPlan]) -> [ProPlan] {
        guard let monthly = plans.filter({ !$0.yearly }).map(\.amountPaise).min(), monthly > 0 else { return plans }
        return plans.map { p in
            var p = p
            let saving = 1 - Double(p.amountPaise) / Double(monthly * 12)
            if p.yearly && saving >= 0.05 { p.note = "Save \(Int((saving * 100).rounded()))% vs monthly" }
            return p
        }
    }
}

/// App-wide settings from the admin console (`app_config`).
struct AppSettings: Codable, Equatable {
    var exportRequiresPro = true
    var announcement = ""
    var announcementStyle = "info"   // info | success | warning
    var trialDays = 7                // Pro for this long after signing up; 0 = no trial
    var offer = FreeAccessOffer()
}

/// "Free access for creators": promote MotionForge, get Pro free (granted from the admin console).
struct FreeAccessOffer: Codable, Equatable {
    var enabled = true
    var email = "karthikvarmaedu@gmail.com"
    var text = "Post one reel promoting MotionForge and get 1 month of Pro free. You need at least 5,000 followers — "
        + "the bigger your audience, the longer the free access, up to 1 year."

    /// A ready-to-send email asking for free access.
    var mailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: "MotionForge free access for creators"),
                        URLQueryItem(name: "body", value: "Hi! I'd like free MotionForge Pro for a promotion reel.\n\n"
                                     + "My profile: \nFollowers: \nMotionForge account email: \n")]
        return c.url
    }
}

/// The signed-in user (Google, through Supabase Auth) and whether they have MotionForge Pro, which exporting needs.
@MainActor
final class AccountModel: NSObject, ObservableObject {
    struct User: Codable, Equatable {
        var id: String
        var email: String
        var name: String
        var avatarURL: URL?
    }
    private struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var user: User
    }
    /// Last known Pro state, kept across launches so exporting works offline until the paid period ends.
    struct Entitlement: Codable, Equatable {
        var pro = false
        var planID: String?
        var status: String?
        var currentEnd: Date?
        var cancelAtPeriodEnd = false
        var checked = Date.distantPast
    }

    @Published private(set) var user: User?
    @Published private(set) var entitlement = Entitlement()
    /// Plans on sale (server prices), monthly first.
    @Published private(set) var plans = ProPlan.builtIn
    @Published private(set) var settings = AppSettings()
    private var lastServerCheck = Date.distantPast
    @Published private(set) var busy = false
    @Published var message: String?
    /// A Razorpay checkout was opened and hasn't been confirmed yet.
    @Published private(set) var awaitingPayment = false

    private var session: Session?
    private var authSession: ASWebAuthenticationSession?
    private var pollTask: Task<Void, Never>?
    /// Debug builds only: MOTIONFORGE_PRO=1 unlocks export for scripts and demos. Release builds always ask the server.
    #if DEBUG
    private let developerPro = ProcessInfo.processInfo.environment["MOTIONFORGE_PRO"] == "1"
    #else
    private let developerPro = false
    #endif

    var isConfigured: Bool { AccountConfig.isConfigured }
    var isSignedIn: Bool { user != nil }
    /// Exporting is a Pro feature (unless the admin console has switched that off). Offline, the cached state
    /// counts until its period ends.
    var canExport: Bool {
        if developerPro || !settings.exportRequiresPro { return true }
        guard entitlement.pro else { return false }
        if let end = entitlement.currentEnd, end < Date(), Date().timeIntervalSince(entitlement.checked) > 3600 { return false }
        return true
    }

    override init() {
        super.init()
        session = Keychain.read(Session.self)
        user = session?.user
        if let data = UserDefaults.standard.data(forKey: "proEntitlement"),
           let e = try? JSONDecoder().decode(Entitlement.self, from: data), session != nil {
            entitlement = e
        }
        if let data = UserDefaults.standard.data(forKey: "serverPlans"), let p = try? JSONDecoder().decode([ProPlan].self, from: data), !p.isEmpty {
            plans = p
        }
        if let data = UserDefaults.standard.data(forKey: "appSettings"), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        }
        Task { await refreshFromServer(force: true) }
        // Changes made in the admin console reach a running app when it comes back to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshFromServer() } }
        }
    }

    /// Prices, app settings and (signed in) Pro status; at most every five minutes unless forced.
    func refreshFromServer(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastServerCheck) > 300 else { return }
        lastServerCheck = Date()
        await loadPublicSettings()
        if isSignedIn { await refreshEntitlement() }
    }

    private func loadPublicSettings() async {
        guard let base = AccountConfig.url, isConfigured else { return }
        func get(_ path: String) async -> [[String: Any]]? {
            var r = URLRequest(url: URL(string: path, relativeTo: base.appendingPathComponent("rest/v1/"))!)
            r.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
            guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        }
        if let rows = await get("plans?select=id,name,amount_paise,period&active=eq.true&order=amount_paise") {
            let p = ProPlan.withSavings(rows.compactMap { r -> ProPlan? in
                guard let id = r["id"] as? String, let amount = r["amount_paise"] as? Int, let period = r["period"] as? String else { return nil }
                return ProPlan(id: id, title: period == "yearly" ? "Yearly" : "Monthly", amountPaise: amount, yearly: period == "yearly")
            }.sorted { !$0.yearly && $1.yearly })
            plans = p
            if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: "serverPlans") }
        }
        if let rows = await get("app_config?select=key,value") {
            var s = AppSettings()
            for r in rows {
                switch r["key"] as? String {
                case "export_requires_pro": s.exportRequiresPro = r["value"] as? Bool ?? true
                case "trial_days": s.trialDays = r["value"] as? Int ?? 7
                case "free_access_offer":
                    if let v = r["value"] as? [String: Any] {
                        s.offer.enabled = v["enabled"] as? Bool ?? true
                        if let e = v["email"] as? String, !e.isEmpty { s.offer.email = e }
                        if let t = v["text"] as? String, !t.isEmpty { s.offer.text = t }
                    }
                case "announcement":
                    let v = r["value"] as? [String: Any]
                    s.announcement = v?["text"] as? String ?? ""
                    s.announcementStyle = v?["style"] as? String ?? "info"
                default: break
                }
            }
            settings = s
            if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "appSettings") }
        }
    }

    /// Pro given from the admin console rather than bought.
    var isGrantedPro: Bool { entitlement.status == "granted" }
    /// Pro from the free trial every new account starts with.
    var isTrial: Bool { entitlement.status == "trial" }

    // MARK: - Google sign-in (Supabase Auth, PKCE, in a system browser sheet)

    func signInWithGoogle() async {
        guard let base = AccountConfig.url, isConfigured else {
            message = "Accounts aren't set up in this build yet (no Supabase project)."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let s: Session
            if let scheme = AccountConfig.googleScheme {
                s = try await googleSignIn(scheme: scheme)
            } else {
                s = try await supabaseWebSignIn(base)
            }
            store(s)
            message = nil
            await refreshEntitlement()
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // closed the sheet
        } catch {
            message = Self.readable(error)
        }
    }

    /// Google directly (PKCE; iOS clients have no secret), then Google's ID token is exchanged for a Supabase session.
    /// Google gets the SHA-256 of a nonce and Supabase the nonce itself, so the token can't be replayed.
    private func googleSignIn(scheme: String) async throws -> Session {
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let nonce = Self.randomURLSafe(32)
        let hashedNonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let redirect = "\(scheme):/oauth2redirect"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [URLQueryItem(name: "client_id", value: AccountConfig.googleClientID),
                        URLQueryItem(name: "redirect_uri", value: redirect),
                        URLQueryItem(name: "response_type", value: "code"),
                        URLQueryItem(name: "scope", value: "openid email profile"),
                        URLQueryItem(name: "code_challenge", value: challenge),
                        URLQueryItem(name: "code_challenge_method", value: "S256"),
                        URLQueryItem(name: "nonce", value: hashedNonce),
                        URLQueryItem(name: "prompt", value: "select_account")]
        let code = try Self.authCode(from: try await webAuthenticate(c.url!, scheme: scheme))

        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.formEncoded(["client_id": AccountConfig.googleClientID, "code": code, "code_verifier": verifier,
                                       "grant_type": "authorization_code", "redirect_uri": redirect])
        let (data, _) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let idToken = obj["id_token"] as? String else {
            throw AccountError.server((obj["error_description"] ?? obj["error"]) as? String ?? "Google refused the sign-in.")
        }
        var body = ["provider": "google", "id_token": idToken, "nonce": nonce]
        if let access = obj["access_token"] as? String { body["access_token"] = access }
        return try await tokenRequest(grant: "id_token", body: body)
    }

    /// Supabase's hosted flow (PKCE): Supabase talks to Google and redirects back to motionforge://auth-callback.
    private func supabaseWebSignIn(_ base: URL) async throws -> Session {
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(url: base.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "provider", value: "google"),
                        URLQueryItem(name: "redirect_to", value: AccountConfig.redirect),
                        URLQueryItem(name: "code_challenge", value: challenge),
                        URLQueryItem(name: "code_challenge_method", value: "s256")]
        let code = try Self.authCode(from: try await webAuthenticate(c.url!))
        return try await tokenRequest(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
    }

    private static func authCode(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error_description" })?.value ?? items.first(where: { $0.name == "error" })?.value {
            throw AccountError.server(err)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AccountError.server("No sign-in code came back.") }
        return code
    }

    private static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    func signOut() async {
        if let base = AccountConfig.url, let s = session {
            var r = URLRequest(url: base.appendingPathComponent("auth/v1/logout"))
            r.httpMethod = "POST"
            r.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
            r.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: r)
        }
        pollTask?.cancel()
        awaitingPayment = false
        session = nil
        user = nil
        entitlement = Entitlement()
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: "proEntitlement")
    }

    private func webAuthenticate(_ url: URL, scheme: String = AccountConfig.callbackScheme) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? AccountError.server("Sign-in failed.")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false  // reuse the browser's Google login
            authSession = s
            if !s.start() { cont.resume(throwing: AccountError.server("Couldn't open the sign-in window.")) }
        }
    }

    // MARK: - Tokens

    private func tokenRequest(grant: String, body: [String: String]) async throws -> Session {
        guard let base = AccountConfig.url else { throw AccountError.notConfigured }
        var c = URLComponents(url: base.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String, let u = obj["user"] as? [String: Any] else {
            throw AccountError.server((obj["error_description"] ?? obj["msg"] ?? obj["error"]) as? String ?? "Sign-in was refused.")
        }
        let meta = u["user_metadata"] as? [String: Any] ?? [:]
        let email = u["email"] as? String ?? ""
        let user = User(id: u["id"] as? String ?? "", email: email,
                        name: (meta["full_name"] ?? meta["name"]) as? String ?? email,
                        avatarURL: ((meta["avatar_url"] ?? meta["picture"]) as? String).flatMap(URL.init(string:)))
        let expiresIn = obj["expires_in"] as? Double ?? 3600
        return Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn - 60), user: user)
    }

    private func store(_ s: Session) {
        session = s
        user = s.user
        Keychain.write(s)
    }

    /// A current access token, refreshed when it is about to expire; nil when signed out (or the refresh was refused).
    private func accessToken() async -> String? {
        guard let s = session else { return nil }
        if s.expiresAt > Date() { return s.accessToken }
        do {
            let fresh = try await tokenRequest(grant: "refresh_token", body: ["refresh_token": s.refreshToken])
            store(fresh)
            return fresh.accessToken
        } catch AccountError.server {
            await signOut()  // revoked or expired refresh token
            message = "Please sign in again."
            return nil
        } catch {
            return nil  // offline: keep the session
        }
    }

    // MARK: - Pro

    private func callFunction(_ name: String, _ body: [String: String] = [:]) async throws -> [String: Any] {
        guard let base = AccountConfig.url else { throw AccountError.notConfigured }
        guard let token = await accessToken() else { throw AccountError.notSignedIn }
        var r = URLRequest(url: base.appendingPathComponent("functions/v1/\(name)"))
        r.httpMethod = "POST"
        // The user's token goes in x-user-jwt, not Authorization: the gateway's "Verify JWT with legacy secret" would
        // reject this project's ES256 user tokens, while the publishable apikey alone passes it. The function checks
        // the token itself.
        r.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue(token, forHTTPHeaderField: "x-user-jwt")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw AccountError.function(obj["error"] as? String ?? "HTTP \(code)") }
        return obj
    }

    @discardableResult
    func refreshEntitlement(action: String? = nil) async -> Bool {
        guard isSignedIn else { return false }
        do {
            let o = try await callFunction("subscription-status", action.map { ["action": $0] } ?? [:])
            var e = Entitlement()
            e.pro = o["pro"] as? Bool ?? false
            e.planID = o["plan_id"] as? String
            e.status = o["status"] as? String
            e.currentEnd = (o["current_end"] as? String).flatMap(Self.parseDate)
            e.cancelAtPeriodEnd = o["cancel_at_period_end"] as? Bool ?? false
            e.checked = Date()
            entitlement = e
            if let data = try? JSONEncoder().encode(e) { UserDefaults.standard.set(data, forKey: "proEntitlement") }
            if e.pro {
                awaitingPayment = false
                pollTask?.cancel()
            }
            return e.pro
        } catch {
            if case AccountError.notSignedIn = error { return false }
            message = Self.readable(error)
            return entitlement.pro
        }
    }

    /// Opens Razorpay's page for `plan` in the browser, then checks every few seconds until Pro is active.
    func subscribe(_ plan: ProPlan) async {
        if !isSignedIn { await signInWithGoogle() }
        guard isSignedIn else { return }
        busy = true
        defer { busy = false }
        do {
            let o = try await callFunction("subscription-checkout", ["plan_id": plan.id])
            guard let s = o["short_url"] as? String, let url = URL(string: s) else { throw AccountError.server("No payment page came back.") }
            NSWorkspace.shared.open(url)
            awaitingPayment = true
            message = nil
            pollForPayment()
        } catch AccountError.function("already_pro") {
            await refreshEntitlement()
        } catch {
            message = Self.readable(error)
        }
    }

    func cancelSubscription() async {
        busy = true
        defer { busy = false }
        await refreshEntitlement(action: "cancel")
    }

    private func pollForPayment() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<120 {  // ten minutes
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if await self.refreshEntitlement() { return }
            }
            self?.awaitingPayment = false
        }
    }

    // MARK: - Helpers

    enum AccountError: Error {
        case notConfigured, notSignedIn
        case server(String)
        case function(String)
    }

    static func readable(_ error: Error) -> String {
        switch error {
        case AccountError.notConfigured: return "Accounts aren't set up in this build yet."
        case AccountError.notSignedIn: return "Sign in with Google first."
        case AccountError.server(let m): return m
        case AccountError.function("payments_not_configured"): return "Payments aren't switched on yet (Razorpay keys missing on the server)."
        case AccountError.function(let m): return m
        default: return error.localizedDescription
        }
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

extension AccountModel: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The session (refresh token included) in the login keychain.
private enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "com.motionforge.account",
                                               kSecAttrAccount as String: "session"]

    static func write<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func read<T: Decodable>(_ type: T.Type) -> T? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
