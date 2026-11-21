import Foundation
import MolaCore

public enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
    public var label: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
}

/// 界面风格：
/// - iOS 原生：信息 App 式输入栏、卡片式工具、上标引用
/// - Claude 风格：输入框 + 工具行、轻量工具行、来源标签
/// - 安卓风格：与安卓版一致的 chip 行输入栏、常驻操作栏、[1] 引用
public enum UIStyle: String, Codable, Sendable, CaseIterable {
    case native, claude, android
    public var label: String {
        switch self { case .native: return "iOS 原生"; case .claude: return "Claude 风格"; case .android: return "安卓风格" }
    }
}

/// 应用设置（对应安卓 SettingsStore / DataStore `mola_settings`；key 名保持一致）。
/// 解码时每个字段独立容错：缺失或类型不对都回落到默认值，新增字段不会让旧数据失效。
public struct AppSettings: Codable, Sendable, Equatable {
    public var themeMode: ThemeMode = .system
    public var uiStyle: UIStyle = .claude
    /// `<providerId>::<modelId>`
    public var defaultModel: String?
    public var enterToSend: Bool = false
    public var temperature: Double = 0.7
    public var useThinking: Bool = true
    public var reasoningEffort: String = Thinking.high
    public var autoTitleEnabled: Bool = true
    public var titleModelKey: String?
    public var username: String = ""
    /// 新对话默认角色；空 = 不使用角色（与安卓一致：会话不绑定角色，BYOK 回退到内置「通用助手」提示词）。
    public var defaultPersonaId: String = ""

    // MARK: 工具（BYOK）
    /// 输入栏的「联网」开关（搜索 + 网页阅读）。
    public var byokWebEnabled: Bool = false
    /// 用户选择的搜索服务；nil = 跟随默认（与安卓一致：登录 MolaGPT 账户时用 MolaGPT 搜索，否则 DuckDuckGo）。
    /// 生效值用 `effectiveSearchProvider(loggedIn:)`。
    public var webSearchProviderChoice: WebSearchProvider?
    public var webSearchMaxResults: Int = 6
    public var webFetchEnabled: Bool = true
    public var visionProxyEnabled: Bool = false
    public var visionProxyModelKey: String?
    public var imageGenEnabled: Bool = false
    public var imageGenModelKey: String?
    public var imageGenConfig = ImageGenConfig()
    public var mcpEnabled: Bool = false
    public var mcpServers: [McpServer] = []
    public var skillsEnabled: Bool = true
    public var disabledSkillIds: [String] = []
    public var visualAnswersEnabled: Bool = true
    public var htmlAsCard: Bool = true
    /// 点链接的打开方式：App 内 Safari（类似 Telegram）或系统默认浏览器。
    public var linkOpenMode: LinkOpenMode = .inApp
    public var responsePostProcessingEnabled: Bool = false
    public var responseRegexRules: [ResponseRegexRule] = ResponseRegexRule.builtins

    // MARK: 本地记忆
    public var byokMemoryMasterEnabled: Bool = false
    public var byokMemoryUse: Bool = true
    public var byokConversationRecall: Bool = true
    public var byokMemoryAutoLearn: Bool = true
    public var byokMemoryAllowSensitive: Bool = false
    public var byokMemoryModelKey: String?
    public var byokMemoryBudget: Int = 2000
    public var byokMemoryFullScan: Bool = false
    public var byokMemoryLastRunAt: Int64 = 0
    public var byokMemoryResetAt: Int64 = 0

    // MARK: 上下文
    public var contextCompactionEnabled: Bool = true
    public var contextSlimmingEnabled: Bool = true
    public var compactionModelKey: String?

    // MARK: 通知与账户
    public var completionNotifications: Bool = true
    /// 生成时在灵动岛 / 锁屏显示实时活动。
    public var liveActivities: Bool = true
    public var cloudSyncEnabled: Bool = false
    public var personalizedMemoryEnabled: Bool = false
    public var toolNetwork: Bool = true
    /// 官方账户模型的「代码执行」（enabled_tools.code），与安卓默认一致为开。
    public var toolCode: Bool = true
    /// 默认值修订号：老安装里未改动过的工具设置在升级时对齐到新默认值（见 init(from:)）。
    public var defaultsRevision: Int = 1
    public var seenNoticeIds: [String] = []
    public var completedTurns: Int = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case uiStyle = "ui_style"
        case linkOpenMode
        case themeMode = "theme_mode", defaultModel = "default_model", enterToSend = "enter_to_send"
        case temperature, useThinking = "use_thinking", reasoningEffort = "reasoning_effort"
        case autoTitleEnabled = "auto_title_enabled", titleModelKey = "title_model_key", username
        case defaultPersonaId = "default_persona_id"
        case byokWebEnabled, webSearchProviderChoice = "byokWebSearchProvider", webSearchMaxResults = "byokWebSearchMaxResults"
        case webFetchEnabled, visionProxyEnabled, visionProxyModelKey, imageGenEnabled, imageGenModelKey, imageGenConfig
        case mcpEnabled, mcpServers = "byokMcpServers", skillsEnabled, disabledSkillIds, visualAnswersEnabled, htmlAsCard
        case responsePostProcessingEnabled, responseRegexRules
        case byokMemoryMasterEnabled, byokMemoryUse, byokConversationRecall, byokMemoryAutoLearn, byokMemoryAllowSensitive
        case byokMemoryModelKey, byokMemoryBudget, byokMemoryFullScan, byokMemoryLastRunAt, byokMemoryResetAt
        case contextCompactionEnabled, contextSlimmingEnabled, compactionModelKey
        case completionNotifications, liveActivities, cloudSyncEnabled, personalizedMemoryEnabled, toolNetwork, toolCode, defaultsRevision
        case seenNoticeIds = "seenPromoIds", completedTurns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        func o<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        let d = AppSettings()
        themeMode = v(.themeMode, d.themeMode)
        uiStyle = v(.uiStyle, d.uiStyle)
        defaultModel = o(.defaultModel)
        enterToSend = v(.enterToSend, d.enterToSend)
        temperature = v(.temperature, d.temperature)
        useThinking = v(.useThinking, d.useThinking)
        reasoningEffort = v(.reasoningEffort, d.reasoningEffort)
        autoTitleEnabled = v(.autoTitleEnabled, d.autoTitleEnabled)
        titleModelKey = o(.titleModelKey)
        username = v(.username, d.username)
        defaultPersonaId = v(.defaultPersonaId, d.defaultPersonaId)
        if defaultPersonaId == Persona.builtinDefaultId { defaultPersonaId = "" }
        byokWebEnabled = v(.byokWebEnabled, d.byokWebEnabled)
        webSearchProviderChoice = o(.webSearchProviderChoice)
        webSearchMaxResults = v(.webSearchMaxResults, d.webSearchMaxResults)
        webFetchEnabled = v(.webFetchEnabled, d.webFetchEnabled)
        visionProxyEnabled = v(.visionProxyEnabled, d.visionProxyEnabled)
        visionProxyModelKey = o(.visionProxyModelKey)
        imageGenEnabled = v(.imageGenEnabled, d.imageGenEnabled)
        imageGenModelKey = o(.imageGenModelKey)
        imageGenConfig = v(.imageGenConfig, d.imageGenConfig)
        mcpEnabled = v(.mcpEnabled, d.mcpEnabled)
        mcpServers = v(.mcpServers, d.mcpServers)
        skillsEnabled = v(.skillsEnabled, d.skillsEnabled)
        disabledSkillIds = v(.disabledSkillIds, d.disabledSkillIds)
        visualAnswersEnabled = v(.visualAnswersEnabled, d.visualAnswersEnabled)
        htmlAsCard = v(.htmlAsCard, d.htmlAsCard)
        linkOpenMode = v(.linkOpenMode, d.linkOpenMode)
        responsePostProcessingEnabled = v(.responsePostProcessingEnabled, d.responsePostProcessingEnabled)
        responseRegexRules = v(.responseRegexRules, d.responseRegexRules)
        byokMemoryMasterEnabled = v(.byokMemoryMasterEnabled, d.byokMemoryMasterEnabled)
        byokMemoryUse = v(.byokMemoryUse, d.byokMemoryUse)
        byokConversationRecall = v(.byokConversationRecall, d.byokConversationRecall)
        byokMemoryAutoLearn = v(.byokMemoryAutoLearn, d.byokMemoryAutoLearn)
        byokMemoryAllowSensitive = v(.byokMemoryAllowSensitive, d.byokMemoryAllowSensitive)
        byokMemoryModelKey = o(.byokMemoryModelKey)
        byokMemoryBudget = v(.byokMemoryBudget, d.byokMemoryBudget)
        byokMemoryFullScan = v(.byokMemoryFullScan, d.byokMemoryFullScan)
        byokMemoryLastRunAt = v(.byokMemoryLastRunAt, d.byokMemoryLastRunAt)
        byokMemoryResetAt = v(.byokMemoryResetAt, d.byokMemoryResetAt)
        contextCompactionEnabled = v(.contextCompactionEnabled, d.contextCompactionEnabled)
        contextSlimmingEnabled = v(.contextSlimmingEnabled, d.contextSlimmingEnabled)
        compactionModelKey = o(.compactionModelKey)
        completionNotifications = v(.completionNotifications, d.completionNotifications)
        liveActivities = v(.liveActivities, d.liveActivities)
        cloudSyncEnabled = v(.cloudSyncEnabled, d.cloudSyncEnabled)
        personalizedMemoryEnabled = v(.personalizedMemoryEnabled, d.personalizedMemoryEnabled)
        toolNetwork = v(.toolNetwork, d.toolNetwork)
        toolCode = v(.toolCode, d.toolCode)
        seenNoticeIds = v(.seenNoticeIds, d.seenNoticeIds)
        completedTurns = v(.completedTurns, d.completedTurns)
        defaultsRevision = v(.defaultsRevision, 0)
        if defaultsRevision < 1 {
            // 修订 1：工具默认值对齐安卓。只改仍是旧默认值的项（视为用户没动过）。
            if webSearchProviderChoice == .duckduckgo { webSearchProviderChoice = nil }
            if !toolCode { toolCode = true }
            if visionProxyEnabled && visionProxyModelKey == nil { visionProxyEnabled = false }
            defaultsRevision = 1
        }
    }

    /// 生效的搜索服务：选了 MolaGPT 但未登录时退回 DuckDuckGo（不改写用户的选择，登录后自动恢复）。
    public func effectiveSearchProvider(loggedIn: Bool) -> WebSearchProvider {
        switch webSearchProviderChoice {
        case nil: return loggedIn ? .molagpt : .duckduckgo
        case .molagpt?: return loggedIn ? .molagpt : .duckduckgo
        case let p?: return p
        }
    }
}

public enum LinkOpenMode: String, Codable, Sendable, CaseIterable {
    case inApp, external
    public var label: String { self == .inApp ? "App 内浏览器" : "默认浏览器" }
}

public enum SettingsStore {
    static let key = "mola_settings"

    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public static func save(_ s: AppSettings, _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}
