import Foundation

/// MolaGPT 官方服务端点（对应安卓 MolaEndpoints.kt）。只允许 HTTPS + 固定 host。
public enum MolaEndpoints {
    public static let host = "chatgpt.wljay.cn"
    public static let origin = "https://chatgpt.wljay.cn"
    public static let base = "https://chatgpt.wljay.cn/v2/"
    public static let clientHeader = "MolaGPT-Android"

    public static let login = "api/auth/login.php"
    public static let logout = "api/auth/logout.php"
    public static let sessionRefresh = "api/auth/session_refresh.php"
    public static let oauthExchange = "api/auth/oauth_exchange.php"
    public static let googleInit = "api/auth/google_init.php"
    public static let microsoftInit = "api/auth/ms_init.php"
    public static let linuxDoInit = "api/auth/oauth_init.php"
    public static let challenge = "api/auth/challenge.php"
    public static let auth = "api/auth/auth.php"
    public static let status = "api/auth/status.php"
    public static let modelConfig = "api/auth/model_config_public.php"
    public static let chatAuto = "api/auth/chatAuto.php"
    public static let stopStream = "api/auth/stop_stream.php"
    public static let checkStreamStatus = "api/auth/check_stream_status.php"
    public static let fetchCompletedStream = "api/auth/fetch_completed_stream.php"
    public static let generateTitle = "api/auth/generateTitle.php"
    public static let imageUpload = "api/=imgtemp/batchUpload.php"
    public static let sandboxUpload = "api/auth/sandboxUploader.php"
    public static let sync = "api/auth/sync.php"
    public static let userData = "api/auth/user_data_manager.php"
    public static let membershipPortal = "api/auth/membership_portal.php"
    public static let membershipProducts = "api/auth/membership_products.php"
    public static let accountSearch = "api/auth/account_search.php"
    public static let sponsors = "api/sponsors.php?page=1"
    public static let versionFeed = "android-version.json"
    public static let messagesFeed = "android-messages.json"
    public static let agentSessions = "api/auth/agent_sessions.php"
    public static let agentRealtime = "api/auth/agent_realtime.php"
    public static let agentEventHistory = "api/auth/agent_event_history.php"
    public static let agentCommand = "api/auth/agent_command.php"
    public static let agentDesktops = "api/auth/agent_desktops.php"
    public static let realtimeSocket = "wss://chatgpt.wljay.cn/v2/agent-realtime"

    public static func url(_ path: String) -> URL { URL(string: base + path)! }

    /// 只放行官方 host 的 https 地址（模型配置里的 apiUrl 可能是相对路径）。
    public static func resolve(_ apiUrl: String) -> URL? {
        if apiUrl.hasPrefix("http") {
            guard let u = URL(string: apiUrl), u.scheme == "https", u.host == host, u.port == nil || u.port == 443 else { return nil }
            return u
        }
        var p = apiUrl
        while p.hasPrefix("/") { p.removeFirst() }
        if p.hasPrefix("v2/") { p.removeFirst(3) }
        return URL(string: base + p)
    }
}
