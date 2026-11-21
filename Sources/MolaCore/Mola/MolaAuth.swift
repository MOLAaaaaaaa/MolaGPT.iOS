import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MolaGPT 官方账户协议（对应安卓 AuthApi / AltchaSolver / ShortTokenManager / MolaGptAuthService / AccountStatusMapper / ModelApi）。

public enum MolaHeaders {
    /// 官方请求公共头（固定 UA；登录类请求另加 Origin 与客户端标识）。
    public static func base(json: Bool = true) -> [String: String] {
        var h = ["User-Agent": MolaUA.fixed, "Accept": "application/json"]
        if json { h["Content-Type"] = "application/json" }
        return h
    }

    public static func auth(json: Bool = true) -> [String: String] {
        var h = base(json: json)
        h["Origin"] = MolaEndpoints.origin
        h["X-MolaGPT-Client"] = MolaEndpoints.clientHeader
        return h
    }

    public static var uaHash: String { SHA256.hexHash(MolaUA.fixed) }
}

// MARK: - ALTCHA

public struct AltchaChallenge: Codable, Sendable, Hashable {
    public var algorithm: String
    public var challenge: String
    public var maxnumber: Int?
    public var salt: String
    public var signature: String
}

public enum Altcha {
    /// 对 n = 0…maxnumber 求 sha256(salt + n)，等于 challenge 即命中。
    /// 热循环里只比较字节（不转 hex、不重复分配），Apple 平台用 CryptoKit 硬件加速。
    public static func solve(_ c: AltchaChallenge) -> Int? {
        guard let target = SHA256.bytes(hex: c.challenge), target.count == 32 else { return nil }
        let saltCount = c.salt.utf8.count
        var buf = Array(c.salt.utf8)
        buf.reserveCapacity(saltCount + 20)
        for n in 0...max(0, c.maxnumber ?? 100_000) {
            buf.removeSubrange(saltCount...)
            buf.append(contentsOf: String(n).utf8)
            if digestEquals(buf, target) { return n }
        }
        return nil
    }

    @inline(__always) private static func digestEquals(_ data: [UInt8], _ target: [UInt8]) -> Bool {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).elementsEqual(target)
        #else
        return SHA256.hash(data) == target
        #endif
    }

    /// `X-Altcha-Payload`：JSON 后标准 base64（有 padding）。
    public static func payload(_ c: AltchaChallenge, number: Int) -> String {
        let obj: JSONValue = ["algorithm": .string(c.algorithm), "challenge": .string(c.challenge), "number": .number(Double(number)),
                              "salt": .string(c.salt), "signature": .string(c.signature)]
        return obj.data().base64EncodedString()
    }
}

public struct ShortTokenResponse: Sendable {
    public var token: String?
    public var userType: String?
    public var username: String?
    public var uaMismatch: Bool
    public var renewedLoginToken: String?
    public var guestChatEnabled: Bool
    public var error: String?

    public static func parse(_ data: Data) -> ShortTokenResponse {
        let j = JSONValue.parse(data)
        return ShortTokenResponse(token: j?["token"]?.stringValue, userType: j?["user_type"]?.stringValue, username: j?["username"]?.stringValue,
                                  uaMismatch: MolaJSON.bool(j?["ua_mismatch"]) ?? false, renewedLoginToken: j?["renewed_login_token"]?.stringValue?.nonBlank,
                                  guestChatEnabled: MolaJSON.bool(j?["guest_chat_enabled"]) ?? true,
                                  error: j?["error"]?.stringValue ?? j?["error"]?["message"]?.stringValue)
    }
}

public enum MolaJSON {
    /// 后端布尔可能是 true / "true" / 1 / "1"。
    public static func bool(_ v: JSONValue?) -> Bool? {
        guard let v else { return nil }
        if let b = v.boolValue { return b }
        if let s = v.stringValue?.lowercased() { return s == "true" || s == "1" || s == "yes" }
        if let d = v.doubleValue { return d != 0 }
        return nil
    }

    public static func int(_ v: JSONValue?) -> Int? { v?.intValue ?? v?.stringValue.flatMap { Int($0) } }
    public static func double(_ v: JSONValue?) -> Double? { v?.doubleValue }
}

// MARK: - 登录 / OAuth

public enum OAuthProvider: String, CaseIterable, Sendable {
    case google, microsoft, linuxdo
    public var label: String { switch self { case .google: return "Google"; case .microsoft: return "Microsoft"; case .linuxdo: return "LINUX DO" } }
    public var initPath: String {
        switch self { case .google: return MolaEndpoints.googleInit; case .microsoft: return MolaEndpoints.microsoftInit; case .linuxdo: return MolaEndpoints.linuxDoInit }
    }
}

public struct OAuthAttempt: Codable, Sendable {
    public var state: String
    public var verifier: String
    public var expiresAt: Int64
}

public enum PKCE {
    public static func random32() -> String {
        var g = SystemRandomNumberGenerator()
        return SHA256.base64url((0..<32).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    public static func challenge(_ verifier: String) -> String { SHA256.base64url(SHA256.hash(verifier)) }

    public static func begin(_ provider: OAuthProvider, now: Int64 = IDs.nowMs()) -> (url: URL, attempt: OAuthAttempt) {
        let a = OAuthAttempt(state: random32(), verifier: random32(), expiresAt: now + 10 * 60 * 1000)
        var c = URLComponents(string: MolaEndpoints.base + provider.initPath)!
        c.queryItems = [.init(name: "desktop", value: "1"), .init(name: "android", value: "1"),
                        .init(name: "code_challenge", value: challenge(a.verifier)), .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "client_state", value: a.state)]
        return (c.url!, a)
    }

    public enum CallbackError: Error, LocalizedError {
        case invalid, stateMismatch, expired
        public var errorDescription: String? {
            switch self { case .invalid: return "登录回调无效"; case .stateMismatch: return "登录状态不匹配，请重试"; case .expired: return "登录已超时，请重试" }
        }
    }

    /// 回调 `molagpt://oauth_callback?code=…&state=…`：无 path/fragment/port/userinfo、无 token、code 与 state 各一次、state 匹配且未过期。
    public static func validate(_ url: URL, attempt: OAuthAttempt?, now: Int64 = IDs.nowMs()) throws -> String {
        guard url.scheme == "molagpt", url.host == "oauth_callback", url.path.isEmpty || url.path == "/",
              url.fragment == nil, url.port == nil, url.user == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw CallbackError.invalid }
        guard !items.contains(where: { $0.name == "token" }) else { throw CallbackError.invalid }
        let codes = items.filter { $0.name == "code" }, states = items.filter { $0.name == "state" }
        guard codes.count == 1, states.count == 1, let code = codes[0].value?.nonBlank, let state = states[0].value else { throw CallbackError.invalid }
        guard let attempt else { throw CallbackError.stateMismatch }
        guard attempt.state == state else { throw CallbackError.stateMismatch }
        guard attempt.expiresAt > now else { throw CallbackError.expired }
        return code
    }
}

public struct LoginResult: Sendable {
    public var token: String
    public var username: String?
    public var refreshToken: String
    public var expiresAt: Int64

    /// 要求 session_protocol == 2、refresh_token 非空、expires_at 未过期。
    public static func parse(_ data: Data, now: Int64 = IDs.nowMs()) throws -> LoginResult {
        guard let j = JSONValue.parse(data) else { throw ProviderError.decoding("登录响应无法解析") }
        if MolaJSON.bool(j["success"]) == false || j["token"]?.stringValue == nil {
            throw ProviderError.decoding(j["message"]?.stringValue ?? j["error"]?.stringValue ?? "登录失败")
        }
        guard MolaJSON.int(j["session_protocol"]) == 2, let refresh = j["refresh_token"]?.stringValue?.nonBlank,
              let exp = MolaJSON.int(j["expires_at"]).map(Int64.init), exp * 1000 > now, let token = j["token"]?.stringValue else {
            throw ProviderError.decoding("服务端会话协议不兼容，请更新应用")
        }
        return LoginResult(token: token, username: j["userInfo"]?["username"]?.stringValue ?? j["username"]?.stringValue,
                           refreshToken: refresh, expiresAt: exp * 1000)
    }
}

public enum JWT {
    public static func payload(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).flatMap(JSONValue.parse)
    }
}

// MARK: - 账户状态

public struct MembershipInfo: Sendable, Hashable {
    public var displayName: String?
    public var tier: String?
    public var expiresAt: Int64?
    public var isPermanent: Bool
    public var donorUntil: Int64?

    public var summary: String? {
        guard let n = displayName?.nonBlank else { return nil }
        if isPermanent { return "\(n) · 永久" }
        if let e = expiresAt, e > 0 {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return "\(n) · 至 \(f.string(from: Date(timeIntervalSince1970: Double(e))))"
        }
        return n
    }
}

public struct CreditsInfo: Sendable, Hashable {
    public var enforcing: Bool
    public var tier: String
    public var used: Double
    public var allowance: Double
    public var remaining: Double
    public var windowDays: Int
    public var nextRefreshAt: Int64?
    public var recoversAt: Int64?
    public var webSearchCalls: Int?

    /// 向上取整，只有真正耗尽才是 0。
    public var remainingPercent: Int {
        guard allowance > 0 else { return 0 }
        let p = remaining / allowance * 100
        return remaining <= 0 ? 0 : max(1, min(100, Int(p.rounded(.up))))
    }

    public var tierLabel: String {
        switch tier { case "guest": return "访客"; case "new": return "新账号"; case "donor": return "支持者"; case "premium": return "高级支持者"; default: return "注册用户" }
    }

    public var windowLabel: String { windowDays > 1 ? "近 \(windowDays) 天累计" : "明日 0 点重置" }
}

public struct ModelQuota: Sendable, Hashable { public var used: Int; public var limit: Int }

public struct AccountStatus: Sendable, Hashable {
    public var loggedIn: Bool
    public var type: String?
    public var username: String?
    public var isDonor: Bool
    public var membership: MembershipInfo?
    public var credits: CreditsInfo?
    public var perModel: [String: ModelQuota]
    public var modelStatus: [String: (available: Bool, reason: String?)]
    public var personalizedMemory: Bool?
    public var cloudSync: Bool?

    public static func == (l: AccountStatus, r: AccountStatus) -> Bool { l.username == r.username && l.loggedIn == r.loggedIn && l.credits == r.credits }
    public func hash(into h: inout Hasher) { h.combine(username) }

    public static func parse(_ data: Data) -> AccountStatus? {
        guard let j = JSONValue.parse(data) else { return nil }
        let u = j["user"]
        var credits: CreditsInfo?
        if let c = u?["credits"], MolaJSON.bool(c["enabled"]) == true {
            credits = CreditsInfo(enforcing: MolaJSON.bool(c["enforcing"]) ?? true, tier: c["tier"]?.stringValue ?? "registered",
                                  used: c["used"]?.doubleValue ?? 0, allowance: c["allowance"]?.doubleValue ?? 0,
                                  remaining: c["remaining"]?.doubleValue ?? 0, windowDays: MolaJSON.int(c["window_days"]) ?? 1,
                                  nextRefreshAt: MolaJSON.int(c["next_refresh_at"]).map(Int64.init), recoversAt: MolaJSON.int(c["recovers_at"]).map(Int64.init),
                                  webSearchCalls: MolaJSON.int(c["web_search"]?["calls"]))
        }
        var perModel: [String: ModelQuota] = [:]
        for (k, v) in u?["usage"]?.objectValue ?? [:] {
            perModel[k] = ModelQuota(used: MolaJSON.int(v) ?? 0, limit: MolaJSON.int(u?["limits"]?[k]?["daily_limit"]) ?? -1)
        }
        var status: [String: (Bool, String?)] = [:]
        for (k, v) in j["model_status"]?.objectValue ?? [:] {
            status[k] = (MolaJSON.bool(v["available"]) ?? true, v["reason"]?.stringValue)
        }
        var membership: MembershipInfo?
        if let m = u?["membership"], m.objectValue != nil {
            membership = MembershipInfo(displayName: m["display_name"]?.stringValue, tier: m["tier"]?.stringValue,
                                        expiresAt: MolaJSON.int(m["expires_at"]).map(Int64.init), isPermanent: MolaJSON.bool(m["is_permanent"]) ?? false,
                                        donorUntil: MolaJSON.int(m["donor_until"]).map(Int64.init))
        }
        return AccountStatus(loggedIn: MolaJSON.bool(u?["logged_in"]) ?? false, type: u?["type"]?.stringValue, username: u?["username"]?.stringValue,
                             isDonor: MolaJSON.bool(u?["is_donor"]) ?? false, membership: membership, credits: credits, perModel: perModel,
                             modelStatus: status, personalizedMemory: MolaJSON.bool(u?["settings"]?["personalized_memory_enabled"]),
                             cloudSync: MolaJSON.bool(u?["settings"]?["cloud_sync_enabled"]))
    }
}

// MARK: - 官方模型

public struct MolaModel: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var id: String
    public var displayName: String
    public var apiUrl: String
    public var supportsThinking: Bool
    public var supportsReasoningEffort: Bool
    public var supportsVision: Bool
    public var group: String?
    /// 置灰原因（额度用尽 / 需登录 / 风控）；nil = 可用。
    public var disabledReason: String?

    public var isAuto: Bool { id == "auto" || id == "autoLLM" || apiUrl.contains("chatAuto.php") }

    public static let greyReasons: [String: String] = [
        "limit_exceeded": "今日额度已用完", "tokens_limit_exceeded": "额度已用完", "risk_restricted": "暂不可用", "login_required": "需要登录",
    ]

    /// model_config_public.php + status.model_status 过滤与置灰。
    public static func parse(_ data: Data, status: AccountStatus?) -> [MolaModel] {
        guard let models = JSONValue.parse(data)?["models"]?.objectValue else { return [] }
        let loginRequired = status?.modelStatus.values.contains { $0.reason == "login_required" } ?? false
        let creditsMode = status?.credits != nil
        var out: [MolaModel] = []
        for (key, m) in models {
            guard MolaJSON.bool(m["show_in_frontend"]) != false, let name = m["modelName"]?.stringValue else { continue }
            var reason: String?
            if let st = status?.modelStatus[key] ?? status?.modelStatus[name], !st.available {
                let r = st.reason ?? ""
                if let grey = greyReasons[r] { reason = grey }
                else if creditsMode && !["model_not_found", "model_disabled", "donor_only", "premium_only"].contains(r) { reason = nil }
                else { continue }
            }
            if loginRequired { reason = greyReasons["login_required"] }
            out.append(MolaModel(key: key, id: name, displayName: m["tipText"]?.stringValue?.nonBlank ?? name,
                                 apiUrl: m["apiUrl"]?.stringValue?.nonBlank ?? MolaEndpoints.chatAuto,
                                 supportsThinking: MolaJSON.bool(m["supportsThinking"]) ?? false,
                                 supportsReasoningEffort: MolaJSON.bool(m["supportsReasoningEffort"]) ?? false,
                                 supportsVision: MolaJSON.bool(m["showImageUpload"]) ?? false, group: m["group"]?.stringValue, disabledReason: reason))
        }
        return out.sorted { a, b in a.isAuto != b.isAuto ? a.isAuto : a.key < b.key }
    }
}
