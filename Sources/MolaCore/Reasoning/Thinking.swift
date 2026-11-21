import Foundation

// 对应安卓 ThinkingParamKind.kt / ReasoningDialect.kt

public enum ThinkingParamKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// 非推理模型，不发送任何推理参数。
    case none = "NONE"
    /// `reasoning_effort`；OpenRouter 走 `reasoning:{effort}`。
    case openAIReasoningEffort = "OPENAI_REASONING_EFFORT"
    /// Anthropic：`thinking:{type:"adaptive", effort}`。
    case claudeAdaptive = "CLAUDE_ADAPTIVE"
    /// Anthropic 预算式：`thinking:{type:"enabled", budget_tokens}`。
    case claudeBudget = "CLAUDE_BUDGET"
    /// DeepSeek：`thinking:{type}` + `reasoning_effort`。
    case deepseekThinking = "DEEPSEEK_THINKING"
    /// Gemini 2.5：`thinkingConfig.thinkingBudget`。
    case gemini = "GEMINI"
    /// Gemini 3/4：`thinkingConfig.thinkingLevel`。
    case geminiLevel = "GEMINI_LEVEL"
    /// Qwen3 / QwQ：`enable_thinking` + `thinking_budget`。
    case qwenThinkingBudget = "QWEN_THINKING_BUDGET"
    /// Kimi K2.x：`thinking:{type}`（仅开关）。
    case kimi = "KIMI"

    public var label: String {
        switch self {
        case .none: return "不推理"
        case .openAIReasoningEffort: return "推理强度 (reasoning_effort)"
        case .claudeAdaptive: return "Claude 自适应"
        case .claudeBudget: return "Claude 预算"
        case .deepseekThinking: return "DeepSeek 混合推理"
        case .gemini: return "Gemini 预算"
        case .geminiLevel: return "Gemini 档位"
        case .qwenThinkingBudget: return "Qwen 思考预算"
        case .kimi: return "仅开关"
        }
    }
}

public enum ThinkingDetectSource: String, Codable, Sendable, Hashable {
    case capability = "CAPABILITY", host = "HOST", heuristic = "HEURISTIC", override = "OVERRIDE"
}

public struct ThinkingConfig: Codable, Sendable, Hashable {
    public var kind: ThinkingParamKind
    public var effortLevels: [String]
    public var defaultEffort: String
    public var alwaysOn: Bool
    public var detectSource: ThinkingDetectSource?
    public var manualOverride: Bool

    public init(kind: ThinkingParamKind = .none, effortLevels: [String] = [], defaultEffort: String = "medium",
                alwaysOn: Bool = false, detectSource: ThinkingDetectSource? = nil, manualOverride: Bool = false) {
        self.kind = kind; self.effortLevels = effortLevels; self.defaultEffort = defaultEffort
        self.alwaysOn = alwaysOn; self.detectSource = detectSource; self.manualOverride = manualOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(ThinkingParamKind.self, forKey: .kind)) ?? .none
        effortLevels = try c.decodeIfPresent([String].self, forKey: .effortLevels) ?? []
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort) ?? "medium"
        alwaysOn = try c.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? false
        detectSource = try? c.decodeIfPresent(ThinkingDetectSource.self, forKey: .detectSource)
        manualOverride = try c.decodeIfPresent(Bool.self, forKey: .manualOverride) ?? false
    }
}

public enum ReasoningOff: Sendable, Hashable {
    /// 不发推理参数即为关闭。
    case omit
    /// `reasoning:{enabled:false}`（聚合网关）。
    case reasoningDisabled
    /// `thinking:{type:"disabled"}`。
    case thinkingDisabled
    /// `enable_thinking:false`。
    case enableThinkingFalse
    /// 服务商没有关闭手段。
    case unsupported
}

public struct ProviderDialect: Sendable {
    public let hosts: [String]
    public let forceKind: ThinkingParamKind?
    public let off: ReasoningOff
    public let effortLevels: [String]?
    public let capabilityTable: Bool

    public var usesReasoningObject: Bool { off == .reasoningDisabled }
}

public enum Thinking {
    public static let minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh", max = "max"
    public static let fullOrder = [minimal, low, medium, high, xhigh, max]

    // MARK: 方言表

    public static let dialects: [ProviderDialect] = [
        ProviderDialect(hosts: ["openrouter.ai"], forceKind: .openAIReasoningEffort, off: .reasoningDisabled,
                        effortLevels: fullOrder, capabilityTable: true),
        ProviderDialect(hosts: ["api.deepseek.com"], forceKind: .deepseekThinking, off: .thinkingDisabled,
                        effortLevels: nil, capabilityTable: false),
        ProviderDialect(hosts: ["api.moonshot.cn", "api.moonshot.ai"], forceKind: .kimi, off: .thinkingDisabled,
                        effortLevels: nil, capabilityTable: false),
        ProviderDialect(hosts: ["dashscope.aliyuncs.com"], forceKind: .qwenThinkingBudget, off: .enableThinkingFalse,
                        effortLevels: nil, capabilityTable: false),
        ProviderDialect(hosts: ["api.stepfun.com"], forceKind: .openAIReasoningEffort, off: .unsupported,
                        effortLevels: [low, medium, high], capabilityTable: false),
        ProviderDialect(hosts: ["api.anthropic.com"], forceKind: nil, off: .omit, effortLevels: nil, capabilityTable: false),
        ProviderDialect(hosts: ["generativelanguage.googleapis.com"], forceKind: nil, off: .omit, effortLevels: nil, capabilityTable: false),
    ]

    static let fallbackDialect = ProviderDialect(hosts: [], forceKind: nil, off: .omit, effortLevels: nil, capabilityTable: false)

    static func host(of baseUrl: String) -> String {
        URL(string: baseUrl.trimmingCharacters(in: .whitespaces))?.host?.lowercased() ?? ""
    }

    public static func dialect(for baseUrl: String) -> ProviderDialect {
        let h = host(of: baseUrl)
        if h.isEmpty { return fallbackDialect }
        return dialects.first { $0.hosts.contains { h == $0 || h.hasSuffix("." + $0) } } ?? fallbackDialect
    }

    public static func isAggregatingGateway(_ baseUrl: String) -> Bool { dialect(for: baseUrl).usesReasoningObject }
    public static func hostInferredKind(_ baseUrl: String) -> ThinkingParamKind? { dialect(for: baseUrl).forceKind }

    public static func offFor(baseUrl: String, kind: ThinkingParamKind) -> ReasoningOff {
        let d = dialect(for: baseUrl)
        if !d.hosts.isEmpty { return d.off }
        switch wireKind(kind, baseUrl: baseUrl) {
        case .deepseekThinking, .kimi: return .thinkingDisabled
        case .qwenThinkingBudget: return .enableThinkingFalse
        default: return .omit
        }
    }

    /// 聚合网关统一折算为 effort。
    public static func wireKind(_ kind: ThinkingParamKind, baseUrl: String) -> ThinkingParamKind {
        if kind == .none { return kind }
        return isAggregatingGateway(baseUrl) ? .openAIReasoningEffort : kind
    }

    // MARK: 档位

    public static func effortLevels(for kind: ThinkingParamKind) -> [String] {
        switch kind {
        case .none, .kimi: return []
        case .openAIReasoningEffort: return fullOrder
        case .claudeAdaptive: return [low, medium, high, xhigh, max]
        case .deepseekThinking: return [high, max]
        case .gemini, .geminiLevel: return [minimal, low, medium, high]
        case .claudeBudget, .qwenThinkingBudget: return [low, medium, high]
        }
    }

    public static func config(for kind: ThinkingParamKind, alwaysOn: Bool = false,
                              source: ThinkingDetectSource? = nil) -> ThinkingConfig {
        if alwaysOn && kind == .openAIReasoningEffort {
            return ThinkingConfig(kind: kind, effortLevels: [low, high, max], defaultEffort: max, alwaysOn: true, detectSource: source)
        }
        return ThinkingConfig(kind: kind, effortLevels: effortLevels(for: kind), defaultEffort: high,
                              alwaysOn: alwaysOn, detectSource: source)
    }

    public static func isKimiK3(_ id: String) -> Bool {
        let leaf = id.lowercased().substringAfterLast("/")
        return leaf.matches("kimi-k3([.\\-]|$)") || leaf.matches("kimi-k[4-9]([.\\-]|$)")
    }

    static let kimiK3Config = ThinkingConfig(kind: .openAIReasoningEffort, effortLevels: [low, high, max],
                                             defaultEffort: max, alwaysOn: true, detectSource: .heuristic)

    public static func geminiConfig(for modelId: String) -> ThinkingConfig? {
        let m = modelId.lowercased().substringAfterLast("/")
        if m.contains("-non-reasoning") { return nil }
        func level(_ levels: [String], _ def: String) -> ThinkingConfig {
            ThinkingConfig(kind: .geminiLevel, effortLevels: levels, defaultEffort: def, alwaysOn: true, detectSource: .heuristic)
        }
        if m.hasPrefix("gemini-4-argon") || m.hasPrefix("gemini-3.8-flash") { return level([low, medium, high], medium) }
        if m.hasPrefix("gemini-3.6-flash") { return level([minimal, low, medium, high], medium) }
        if m.hasPrefix("gemini-3.1-flash-lite-image") { return level([minimal, high], minimal) }
        if m.hasPrefix("gemini-3.5-flash-lite") || m.hasPrefix("gemini-3.1-flash-lite") { return level([minimal, low, medium, high], minimal) }
        if m.hasPrefix("gemini-3.1-pro") { return level([low, medium, high], high) }
        if m.hasPrefix("gemini-3-pro") { return level([low, high], high) }
        if m.hasPrefix("gemini-3-flash") { return level([minimal, low, medium, high], high) }
        if m.hasPrefix("gemini-2.5-pro") || m.hasPrefix("gemini-2.5-flash") { return config(for: .gemini, source: .heuristic) }
        if m.hasPrefix("gemini-4") { return level([low, medium, high], medium) }
        if m.hasPrefix("gemini-3") { return level([minimal, low, medium, high], high) }
        return nil
    }

    /// 按模型 ID 推断 kind（纯名称匹配）。
    public static func inferFromModelId(_ id: String) -> ThinkingParamKind {
        let lower = id.lowercased()
        if lower.contains("-non-reasoning") { return .none }
        let leaf = lower.substringAfterLast("/")
        if ["claude", "sonnet", "opus", "haiku"].contains(where: lower.contains) { return .claudeAdaptive }
        if lower.contains("deepseek") { return .deepseekThinking }
        if isKimiK3(id) { return .openAIReasoningEffort }
        if lower.contains("kimi") || lower.contains("moonshot") { return .kimi }
        if lower.contains("qwen3") || lower.contains("qwq") { return .qwenThinkingBudget }
        if lower.contains("gemini") { return geminiConfig(for: id)?.kind ?? .gemini }
        let prefixHit = ["o1", "o3", "o4", "gpt-5"].contains(where: leaf.hasPrefix)
        let containsHit = ["gpt-oss", "reasoning", "reasoner", "thinking", "think", "grok-4", "grok-3-mini",
                           "hunyuan-t1", "glm-zero-preview", "glm-5", "mimo-v2-flash", "magistral", "seed-oss",
                           "gemma-4", "pangu-pro-moe"].contains(where: lower.contains)
        if prefixHit || containsHit || leaf.matches("-(r|R)\\d+") || lower.matches("glm-4\\.\\d")
            || lower.matches("minimax-m[23]") {
            return .openAIReasoningEffort
        }
        return .none
    }

    /// 据模型 ID + baseUrl 构造自动配置；nil = 非推理模型。
    public static func autoConfig(modelId: String, baseUrl: String) -> ThinkingConfig? {
        if isKimiK3(modelId) {
            var c = kimiK3Config
            c.detectSource = hostInferredKind(baseUrl) != nil ? .host : .heuristic
            return c
        }
        if isAggregatingGateway(baseUrl) {
            if inferFromModelId(modelId) == .none { return nil }
            return config(for: .openAIReasoningEffort, source: .host)
        }
        let byId = inferFromModelId(modelId)
        if byId != .none {
            let native = (byId == .gemini || byId == .geminiLevel) ? geminiConfig(for: modelId) : nil
            var c = native ?? config(for: byId)
            c.detectSource = hostInferredKind(baseUrl) != nil ? .host : .heuristic
            return c
        }
        guard let byHost = hostInferredKind(baseUrl) else { return nil }
        return config(for: byHost, source: .host)
    }

    /// 实际可选档位（低→高）：模型配置 → 方言表 → 参数形状。
    public static func resolveEffortLevels(_ config: ThinkingConfig, baseUrl: String) -> [String] {
        let custom = normalize(config.effortLevels)
        let levels: [String]
        if !custom.isEmpty { levels = custom }
        else if let d = dialect(for: baseUrl).effortLevels { levels = d }
        else { levels = effortLevels(for: wireKind(config.kind, baseUrl: baseUrl)) }
        return levels.sorted { (fullOrder.firstIndex(of: $0) ?? 99) < (fullOrder.firstIndex(of: $1) ?? 99) }
    }

    public static func resolveDefaultEffort(_ config: ThinkingConfig, baseUrl: String) -> String {
        let levels = resolveEffortLevels(config, baseUrl: baseUrl)
        let pref = config.defaultEffort.lowercased()
        if levels.contains(pref) { return pref }
        if levels.contains(high) { return high }
        return levels.last ?? high
    }

    static func normalize(_ levels: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for raw in levels {
            let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if v.isEmpty || v == "none" || v == "off" || seen.contains(v) { continue }
            seen.insert(v); out.append(v)
        }
        return out
    }

    public static func isAlwaysOn(_ config: ThinkingConfig, baseUrl: String) -> Bool {
        config.alwaysOn || offFor(baseUrl: baseUrl, kind: config.kind) == .unsupported
    }

    public static func isBudgetKind(_ kind: ThinkingParamKind) -> Bool {
        kind == .claudeBudget || kind == .gemini || kind == .qwenThinkingBudget
    }

    /// 符号档位 → token 预算。
    public static func budget(for kind: ThinkingParamKind, effort: String) -> Int {
        switch kind {
        case .claudeBudget: return effort == low ? 4096 : effort == high ? 28000 : 12000
        case .gemini:
            switch effort { case minimal: return 1024; case low: return 2048; case high: return 24576; default: return 8192 }
        case .qwenThinkingBudget: return effort == low ? 4096 : effort == high ? 16384 : 8192
        default: return 0
        }
    }

    public static func effortLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case minimal: return "极低"
        case low: return "低"
        case medium: return "中"
        case high: return "高"
        case xhigh: return "超高"
        case max: return "最高"
        case "auto": return "自动"
        case "off", "none": return "关"
        default: return effort
        }
    }
}

extension ProviderModel {
    /// 该模型实际生效的推理配置：持久化配置优先，否则自动推断。
    public func effectiveThinking(baseUrl: String) -> ThinkingConfig? {
        if let c = thinkingConfig { return c.kind == .none ? nil : c }
        guard supportsThinking || Thinking.inferFromModelId(id) != .none else { return nil }
        return Thinking.autoConfig(modelId: id, baseUrl: baseUrl)
    }
}
