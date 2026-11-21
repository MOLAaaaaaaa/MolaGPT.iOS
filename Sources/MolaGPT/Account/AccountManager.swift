import Foundation
import Observation
import AuthenticationServices
import UIKit
import MolaCore
import MolaStorage

/// MolaGPT 官方账户的界面状态（登录、额度、官方模型列表）。网络与令牌在 `MolaSession`。
@MainActor
@Observable
final class AccountManager {
    private(set) var username: String?
    private(set) var jwt: String?
    private(set) var status: AccountStatus?
    private(set) var models: [MolaModel] = []
    private(set) var loading = false
    var error: String?
    @ObservationIgnored private var statusFetchedAt: Date?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = AuthAnchor()
    /// 登录 / 登出后通知其它子系统（同步、短 token 缓存等）。
    @ObservationIgnored var onLoginChanged: [@MainActor (Bool) -> Void] = []

    /// 先用上次缓存的官方模型列表：冷启动（例如点按通知打开）时网络还没回来，
    /// 否则官方模型的对话会找不到模型，界面退回「添加模型服务」。
    init() {
        reload()
        models = Self.loadCachedModels()
    }

    var isLoggedIn: Bool { jwt != nil }
    var session: MolaSession { .shared }

    func reload() {
        jwt = Keychain.get(AccountKeys.jwt)?.nonBlank
        username = Keychain.get(AccountKeys.username)?.nonBlank
    }

    // MARK: 登录

    func login(username: String, password: String) async -> Bool {
        loading = true; error = nil
        defer { loading = false }
        do {
            _ = try await session.login(username: username, password: password)
            await didLogin()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func loginOAuth(_ provider: OAuthProvider) {
        error = nil
        let (url, attempt) = PKCE.begin(provider)
        if let data = try? JSONEncoder().encode(attempt) { Keychain.set(AccountKeys.oauthAttempt, String(decoding: data, as: UTF8.self)) }
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "molagpt") { [weak self] callback, err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    if (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self.error = err.localizedDescription }
                    return
                }
                if let callback { await self.handleCallback(callback) }
            }
        }
        s.presentationContextProvider = anchor
        s.prefersEphemeralWebBrowserSession = false
        authSession = s
        s.start()
    }

    /// 回调（也可能来自 onOpenURL）：校验后用 PKCE verifier 换取会话。
    func handleCallback(_ url: URL) async {
        let attempt = Keychain.get(AccountKeys.oauthAttempt).flatMap { try? JSONDecoder().decode(OAuthAttempt.self, from: Data($0.utf8)) }
        Keychain.delete(AccountKeys.oauthAttempt)
        loading = true
        defer { loading = false }
        do {
            let code = try PKCE.validate(url, attempt: attempt)
            _ = try await session.exchange(code: code, verifier: attempt?.verifier ?? "")
            await didLogin()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func didLogin() async {
        reload()
        statusFetchedAt = nil
        await refresh(force: true)
        for h in onLoginChanged { h(true) }
    }

    func logout() async {
        await session.logout()
        reload()
        status = nil
        statusFetchedAt = nil
        await refreshModels()
        for h in onLoginChanged { h(false) }
    }

    /// 令牌失效（401）时由各子系统调用。
    func handleExpired() {
        Task { await session.clear(); reload(); status = nil; for h in onLoginChanged { h(false) } }
        error = "登录已过期，请重新登录"
    }

    // MARK: 状态 / 模型

    /// 状态缓存 60 秒。
    func refresh(force: Bool = false) async {
        if !force, let t = statusFetchedAt, Date().timeIntervalSince(t) < 60 { return }
        do {
            status = try await session.status()
            statusFetchedAt = Date()
        } catch MolaSession.SessionError.expired {
            reload(); status = nil
        } catch {
            // 状态拿不到时不过滤模型
        }
        if let u = status?.username, isLoggedIn { username = u }
        await refreshModels()
    }

    func refreshModels() async {
        guard let data = try? await session.modelConfig() else { return }
        let parsed = MolaModel.parse(data, status: status)
        guard !parsed.isEmpty || models.isEmpty else { return }
        models = parsed
        Self.saveCachedModels(parsed)
    }

    private static var modelsCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mola-models.json")
    }

    private static func loadCachedModels() -> [MolaModel] {
        guard let data = try? Data(contentsOf: modelsCacheURL) else { return [] }
        return (try? JSONDecoder().decode([MolaModel].self, from: data)) ?? []
    }

    private static func saveCachedModels(_ models: [MolaModel]) {
        try? FileManager.default.createDirectory(at: modelsCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(models).write(to: modelsCacheURL, options: .atomic)
    }

    func model(_ idOrKey: String?) -> MolaModel? {
        guard let idOrKey else { return nil }
        return models.first { $0.id == idOrKey || $0.key == idOrKey }
    }
}

/// ASWebAuthenticationSession 的展示锚点。
final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

enum AccountKeys {
    static let jwt = "molagpt.jwt"
    static let username = "molagpt.username"
    static let uaHash = "molagpt.ua_hash"
    static let refreshToken = "molagpt.refresh_token"
    static let expiresAt = "molagpt.expires_at"
    static let deviceCookie = "molagpt.device_cookie"
    static let oauthAttempt = "molagpt.oauth_attempt"
}
