import Foundation
import MolaCore
import MolaStorage

/// 官方账户会话（对应安卓 AccountSessionManager / ShortTokenManager / AuthApi）。actor 保证刷新与换取短 token 并发只做一次。
actor MolaSession {
    static let shared = MolaSession()

    enum SessionError: LocalizedError {
        case expired, http(Int, String), altcha, guestDisabled
        var errorDescription: String? {
            switch self {
            case .expired: return "登录已过期，请重新登录"
            case .http(let c, let m): return "请求失败（\(c)）：\(m)"
            case .altcha: return "人机验证失败，请稍后重试"
            case .guestDisabled: return "游客模式已关闭，请先登录"
            }
        }
    }

    private let session: URLSession
    private var shortToken: (token: String, expires: Date)?
    private var generation = 0
    private var inflightToken: Task<String, Error>?

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared   // mola_did 设备 cookie 由系统按 host 保存并自动携带
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    nonisolated var urlSession: URLSession { session }

    // MARK: 凭据

    var jwt: String? { Keychain.get(AccountKeys.jwt)?.nonBlank }
    var refreshToken: String? { Keychain.get(AccountKeys.refreshToken)?.nonBlank }
    var expiresAt: Int64 { Int64(Keychain.get(AccountKeys.expiresAt) ?? "") ?? 0 }

    private func store(_ r: LoginResult) {
        Keychain.set(AccountKeys.jwt, r.token)
        if let u = r.username { Keychain.set(AccountKeys.username, u) }
        Keychain.set(AccountKeys.refreshToken, r.refreshToken)
        Keychain.set(AccountKeys.expiresAt, String(r.expiresAt))
        Keychain.set(AccountKeys.uaHash, MolaHeaders.uaHash)
        generation += 1
        shortToken = nil
        inflightToken = nil
    }

    func clear() {
        for k in [AccountKeys.jwt, AccountKeys.username, AccountKeys.refreshToken, AccountKeys.expiresAt, AccountKeys.uaHash] { Keychain.delete(k) }
        generation += 1
        shortToken = nil
        inflightToken = nil
    }

    // MARK: 请求

    func send(_ spec: HTTPRequestSpec) async throws -> (Int, Data) {
        let (data, resp) = try await session.data(for: spec.urlRequest)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func post(_ path: String, _ body: JSONValue, headers: [String: String] = MolaHeaders.auth(), bearer: String? = nil, timeout: TimeInterval = 30) async throws -> (Int, Data) {
        var h = headers
        if let bearer { h["Authorization"] = "Bearer \(bearer)" }
        var spec = HTTPRequestSpec(url: MolaEndpoints.url(path), headers: h, body: body.data())
        spec.timeout = timeout
        return try await send(spec)
    }

    private func get(_ path: String, headers: [String: String] = MolaHeaders.base(json: false), bearer: String? = nil) async throws -> (Int, Data) {
        var h = headers
        if let bearer { h["Authorization"] = "Bearer \(bearer)" }
        var spec = HTTPRequestSpec(url: MolaEndpoints.url(path), method: "GET", headers: h)
        spec.timeout = 15
        return try await send(spec)
    }

    // MARK: 登录

    func login(username: String, password: String) async throws -> String? {
        var h = MolaHeaders.auth()
        h["Referer"] = MolaEndpoints.base
        let (status, data) = try await post(MolaEndpoints.login, ["username": .string(username), "password": .string(SHA256.hexHash(password)), "session_protocol": 2], headers: h)
        guard (200..<300).contains(status) || status == 401 || status == 400 else { throw SessionError.http(status, ProviderError.summarize(String(decoding: data, as: UTF8.self))) }
        let r = try LoginResult.parse(data)
        store(r)
        return r.username
    }

    func exchange(code: String, verifier: String) async throws -> String? {
        let (status, data) = try await post(MolaEndpoints.oauthExchange, ["code": .string(code), "code_verifier": .string(verifier), "session_protocol": 2])
        guard (200..<300).contains(status) else { throw SessionError.http(status, ProviderError.summarize(String(decoding: data, as: UTF8.self))) }
        let r = try LoginResult.parse(data)
        store(r)
        return r.username
    }

    func logout() async {
        if let t = jwt { _ = try? await post(MolaEndpoints.logout, [:], bearer: t, timeout: 5) }
        clear()
    }

    // MARK: 长 token（自动刷新）

    /// 有效的账号 JWT：剩余超过 60 秒直接用，否则刷新（refresh_token 轮换，sid 必须一致）。
    func validJWT() async throws -> String? {
        guard let token = jwt else { return nil }
        let now = IDs.nowMs()
        let payload = JWT.payload(token)
        // 只处理带 sid 的 access token；旧会话（无 refresh_token）校验 ua_hash。
        guard refreshToken != nil else {
            if Keychain.get(AccountKeys.uaHash) != MolaHeaders.uaHash { clear(); throw SessionError.expired }
            return token
        }
        if expiresAt > now + 60_000 { return token }
        let gen = generation
        let (status, data) = try await post(MolaEndpoints.sessionRefresh, ["refresh_token": .string(refreshToken ?? "")])
        if status == 401 || status == 403 { clear(); throw SessionError.expired }
        guard (200..<300).contains(status), let j = JSONValue.parse(data), let newToken = j["token"]?.stringValue else {
            throw SessionError.http(status, ProviderError.summarize(String(decoding: data, as: UTF8.self)))
        }
        if let oldSid = payload?["sid"]?.stringValue, let newSid = JWT.payload(newToken)?["sid"]?.stringValue, oldSid != newSid {
            clear(); throw SessionError.expired
        }
        guard gen == generation else { return jwt } // 期间凭据已变：丢弃旧刷新结果
        Keychain.set(AccountKeys.jwt, newToken)
        if let r = j["refresh_token"]?.stringValue?.nonBlank { Keychain.set(AccountKeys.refreshToken, r) }
        if let e = MolaJSON.int(j["expires_at"]) { Keychain.set(AccountKeys.expiresAt, String(Int64(e) * 1000)) }
        return newToken
    }

    // MARK: 短 token（ALTCHA）

    /// 聊天用短 token：TTL 60 秒，剩余不足 15 秒重新换取。并发调用共用同一次换取（预取与发送同时到达时不重复解题）。
    func chatToken() async throws -> String {
        if let s = shortToken, s.expires.timeIntervalSinceNow > 15 { return s.token }
        if let t = inflightToken { return try await t.value }
        let t = Task { try await fetchShortToken() }
        inflightToken = t
        defer { if inflightToken == t { inflightToken = nil } }
        return try await t.value
    }

    /// 预取短 token（输入框聚焦 / 开始输入 / 回到前台时调用），让发送时不必再走 challenge → 解题 → auth。失败静默。
    func prewarm() async {
        if let s = shortToken, s.expires.timeIntervalSinceNow > 25 { return }
        _ = try? await chatToken()
    }

    private func fetchShortToken() async throws -> String {
        let gen = generation
        let (cs, cdata) = try await get(MolaEndpoints.challenge, headers: ["User-Agent": MolaUA.fixed, "Cache-Control": "no-cache", "Accept": "application/json"])
        guard (200..<300).contains(cs), let ch = try? JSONDecoder().decode(AltchaChallenge.self, from: cdata) else { throw SessionError.altcha }
        let number = await Task.detached(priority: .userInitiated) { Altcha.solve(ch) }.value
        guard let number else { throw SessionError.altcha }
        var h = MolaHeaders.base(json: false)
        h["X-Altcha-Payload"] = Altcha.payload(ch, number: number)
        let long = try await validJWT()
        if let long { h["Authorization"] = "Bearer \(long)" }
        var spec = HTTPRequestSpec(url: MolaEndpoints.url(MolaEndpoints.auth), method: "GET", headers: h)
        spec.timeout = 15
        let (status, data) = try await send(spec)
        if status == 403 { throw SessionError.altcha }
        if status == 429 { throw SessionError.http(429, "请求过于频繁，请稍后再试") }
        let r = ShortTokenResponse.parse(data)
        if let e = r.error { throw SessionError.http(status, e) }
        if long != nil && (r.uaMismatch || r.userType != "registered") { clear(); throw SessionError.expired }
        if long == nil && !r.guestChatEnabled { throw SessionError.guestDisabled }
        if let renewed = r.renewedLoginToken, jwt == long { Keychain.set(AccountKeys.jwt, renewed) }
        guard let token = r.token else { throw SessionError.altcha }
        if gen == generation { shortToken = (token, Date().addingTimeInterval(60)) }
        return token
    }

    func invalidateShortToken() { shortToken = nil; inflightToken = nil }

    // MARK: 状态与模型

    func status() async throws -> AccountStatus? {
        let (s, data) = try await get(MolaEndpoints.status, bearer: try await validJWT())
        if s == 401 { clear(); throw SessionError.expired }
        return AccountStatus.parse(data)
    }

    func modelConfig() async throws -> Data {
        let (s, data) = try await get(MolaEndpoints.modelConfig)
        guard (200..<300).contains(s) else { throw SessionError.http(s, "模型配置获取失败") }
        return data
    }

    /// 需要长 JWT 的 JSON POST（sync / user_data_manager / membership 等）。
    func authedPost(_ path: String, _ body: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let t = try await validJWT() else { throw SessionError.expired }
        let (s, data) = try await post(path, body, headers: MolaHeaders.base(), bearer: t, timeout: timeout)
        if s == 401 { clear(); throw SessionError.expired }
        let j = JSONValue.parse(data)
        guard (200..<300).contains(s) else { throw SessionError.http(s, j?["message"]?.stringValue ?? j?["error"]?.stringValue ?? ProviderError.summarize(String(decoding: data, as: UTF8.self))) }
        return j ?? .null
    }

    func authedGet(_ path: String) async throws -> JSONValue {
        guard let t = try await validJWT() else { throw SessionError.expired }
        let (s, data) = try await get(path, bearer: t)
        if s == 401 { clear(); throw SessionError.expired }
        guard (200..<300).contains(s) else { throw SessionError.http(s, ProviderError.summarize(String(decoding: data, as: UTF8.self))) }
        return JSONValue.parse(data) ?? .null
    }
}
