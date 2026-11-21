import Foundation

// 对应安卓 ByokProvider.kt / ProviderModel.kt / ModelPricing.kt

public enum ByokProviderType: String, Codable, Sendable, Hashable, CaseIterable {
    case openAICompat = "OPENAI_COMPAT"
    case openAIResponse = "OPENAI_RESPONSE"
    case anthropic = "ANTHROPIC"
    case gemini = "GEMINI"

    public var label: String {
        switch self {
        case .openAICompat: return "OpenAI 兼容"
        case .openAIResponse: return "OpenAI Responses"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }

    public var defaultChatPath: String {
        switch self {
        case .openAICompat: return "v1/chat/completions"
        case .openAIResponse: return "v1/responses"
        case .anthropic: return "v1/messages"
        case .gemini: return "models/{model}:streamGenerateContent"
        }
    }

    public var defaultModelsPath: String { self == .gemini ? "models" : "v1/models" }
}

public enum ProviderKind: String, Codable, Sendable, Hashable {
    case molagpt = "MOLAGPT", byok = "BYOK"
}

public struct CustomHeader: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
    public init(name: String = "", value: String = "") { self.name = name; self.value = value }
}

/// USD / 1,000,000 tokens。
public struct ModelPricing: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var source: String?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, source: String? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.source = source
    }

    public var isManual: Bool { source?.lowercased() == "manual" }
    public var isValid: Bool {
        [input, output, cacheRead, cacheWrite].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    /// 与安卓 `calculateCostUsd` 一致：缓存命中按 cacheRead 计，缓存写入无价时不出整单费用。
    public func cost(_ usage: Usage?) -> Double? {
        guard isValid, let usage, let prompt = usage.promptTokens, prompt >= 0,
              let completion = usage.completionTokens, completion >= 0 else { return nil }
        let cached = min(max(usage.cachedTokens ?? 0, 0), prompt)
        let written = min(max(usage.cacheWriteTokens ?? 0, 0), prompt - cached)
        var writePrice = 0.0
        if written > 0 {
            guard let w = cacheWrite else { return nil }
            writePrice = w
        }
        let total = Double(prompt - cached - written) * input + Double(cached) * (cacheRead ?? input)
            + Double(written) * writePrice + Double(completion) * output
        return total / 1_000_000
    }

    public static func format(_ usd: Double) -> String {
        if usd >= 1000 { return String(format: "$%.0f", usd) }
        if usd == 0 || usd >= 0.01 { return String(format: "$%.2f", usd) }
        return String(format: "$%.4f", usd)
    }
}

/// 每模型请求体覆写（安卓 customBody）：key + 类型 + 值。
public struct CustomBodyParam: Codable, Sendable, Hashable {
    public enum ValueType: String, Codable, Sendable { case string, number, boolean, json }
    public var key: String
    public var type: ValueType
    public var value: String

    public init(key: String, type: ValueType, value: String) { self.key = key; self.type = type; self.value = value }

    public var jsonValue: JSONValue? {
        switch type {
        case .string: return .string(value)
        case .number: return Double(value).map(JSONValue.number)
        case .boolean: return .bool(value.lowercased() == "true")
        case .json: return JSONValue.parse(value)
        }
    }
}

public enum ProviderPurpose: String, Codable, Sendable, Hashable, CaseIterable {
    case chat = "CHAT", image = "IMAGE"
}

/// 图像接口形状：OpenAI Images（/v1/images/generations）或 chat/completions 返回图片。
public enum ImageFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case openAIImages = "OPENAI_IMAGES", openAIChatImage = "OPENAI_CHAT_IMAGE"
    public var label: String { self == .openAIImages ? "Images API" : "Chat 返回图片" }
}

public struct ProviderModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var supportsVision: Bool
    public var supportsThinking: Bool
    public var supportsToolCalling: Bool
    public var thinkingConfig: ThinkingConfig?
    public var contextWindow: Int?
    public var pricing: ModelPricing?
    public var customBody: [CustomBodyParam]
    public var enabled: Bool
    /// 图像生成模型（generate_image 工具 / 画图工作台）。
    public var supportsImageGeneration: Bool
    /// 模型级覆盖图像接口形状（nil = 跟随服务）。
    public var imageFormat: ImageFormat?
    /// 支持图像编辑（参考图 / 局部重绘）。
    public var supportsImageEdit: Bool

    public init(id: String, displayName: String? = nil, supportsVision: Bool = false, supportsThinking: Bool = false,
                supportsToolCalling: Bool = true, thinkingConfig: ThinkingConfig? = nil, contextWindow: Int? = nil,
                pricing: ModelPricing? = nil, customBody: [CustomBodyParam] = [], enabled: Bool = true,
                supportsImageGeneration: Bool = false, imageFormat: ImageFormat? = nil, supportsImageEdit: Bool = false) {
        self.supportsImageGeneration = supportsImageGeneration; self.imageFormat = imageFormat; self.supportsImageEdit = supportsImageEdit
        self.id = id; self.displayName = displayName ?? id; self.supportsVision = supportsVision
        self.supportsThinking = supportsThinking; self.supportsToolCalling = supportsToolCalling
        self.thinkingConfig = thinkingConfig; self.contextWindow = contextWindow; self.pricing = pricing
        self.customBody = customBody; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, supportsVision, supportsThinking, supportsToolCalling, thinkingConfig, contextWindow, pricing, customBody, enabled
        case supportsImageGeneration, imageFormat, supportsImageEdit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        supportsVision = try c.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
        supportsThinking = try c.decodeIfPresent(Bool.self, forKey: .supportsThinking) ?? false
        supportsToolCalling = try c.decodeIfPresent(Bool.self, forKey: .supportsToolCalling) ?? true
        thinkingConfig = try c.decodeIfPresent(ThinkingConfig.self, forKey: .thinkingConfig)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        pricing = try c.decodeIfPresent(ModelPricing.self, forKey: .pricing)
        customBody = try c.decodeIfPresent([CustomBodyParam].self, forKey: .customBody) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        supportsImageGeneration = try c.decodeIfPresent(Bool.self, forKey: .supportsImageGeneration) ?? false
        imageFormat = try? c.decodeIfPresent(ImageFormat.self, forKey: .imageFormat)
        supportsImageEdit = try c.decodeIfPresent(Bool.self, forKey: .supportsImageEdit) ?? false
    }
}

public struct ByokProvider: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var type: ByokProviderType
    public var baseUrl: String
    /// 不入库：运行时从 Keychain 注入。
    public var apiKey: String?
    public var chatPath: String
    public var modelsPath: String
    public var enabled: Bool
    public var models: [ProviderModel]
    public var customHeaders: [CustomHeader]
    public var sortOrder: Int
    /// 用途：聊天 / 图像（画图工作台的服务列表只显示图像服务）。
    public var purpose: ProviderPurpose = .chat
    public var imagePath: String = "v1/images/generations"
    public var imageEditPath: String = "v1/images/edits"
    public var imageFormat: ImageFormat = .openAIImages

    public init(id: String = IDs.generic("prov"), name: String, type: ByokProviderType = .openAICompat, baseUrl: String,
                apiKey: String? = nil, chatPath: String? = nil, modelsPath: String? = nil, enabled: Bool = true,
                models: [ProviderModel] = [], customHeaders: [CustomHeader] = [], sortOrder: Int = 0) {
        self.id = id; self.name = name; self.type = type; self.baseUrl = baseUrl; self.apiKey = apiKey
        self.chatPath = chatPath ?? type.defaultChatPath; self.modelsPath = modelsPath ?? type.defaultModelsPath
        self.enabled = enabled; self.models = models; self.customHeaders = customHeaders; self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, baseUrl, chatPath, modelsPath, enabled, models, customHeaders, sortOrder
        case purpose, imagePath, imageEditPath, imageFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(ByokProviderType.self, forKey: .type)
        baseUrl = try c.decode(String.self, forKey: .baseUrl)
        apiKey = nil
        chatPath = try c.decodeIfPresent(String.self, forKey: .chatPath) ?? type.defaultChatPath
        modelsPath = try c.decodeIfPresent(String.self, forKey: .modelsPath) ?? type.defaultModelsPath
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        models = try c.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        customHeaders = try c.decodeIfPresent([CustomHeader].self, forKey: .customHeaders) ?? []
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        purpose = (try? c.decodeIfPresent(ProviderPurpose.self, forKey: .purpose)) ?? .chat
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? "v1/images/generations"
        imageEditPath = try c.decodeIfPresent(String.self, forKey: .imageEditPath) ?? "v1/images/edits"
        imageFormat = (try? c.decodeIfPresent(ImageFormat.self, forKey: .imageFormat)) ?? .openAIImages
    }

    public func imageFormatFor(_ modelId: String) -> ImageFormat { model(modelId)?.imageFormat ?? imageFormat }

    public var host: String { URL(string: baseUrl.trimmingCharacters(in: .whitespaces))?.host?.lowercased() ?? "" }
    public var isOpenRouter: Bool { host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") }

    /// `baseUrl.trimEnd('/') + "/" + path.trimStart('/')`
    public func endpoint(_ path: String) -> String {
        var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        return p.isEmpty ? base : base + "/" + p
    }

    public func model(_ id: String) -> ProviderModel? { models.first { $0.id == id } }
}

/// 预设服务（对话用途）。与安卓 `ByokProviderPresets.defaults` 一致。
public enum ByokProviderPresets {
    public struct Preset: Sendable, Hashable, Identifiable {
        public let id: String, name: String, baseUrl: String, chatPath: String, modelsPath: String
        public let type: ByokProviderType
    }

    private static func p(_ id: String, _ name: String, _ base: String, _ chat: String, _ models: String,
                          _ type: ByokProviderType = .openAICompat) -> Preset {
        Preset(id: id, name: name, baseUrl: base, chatPath: chat, modelsPath: models, type: type)
    }

    public static let all: [Preset] = [
        p("openrouter", "OpenRouter", "https://openrouter.ai/api/", "v1/chat/completions", "v1/models"),
        p("openai", "OpenAI", "https://api.openai.com/", "v1/chat/completions", "v1/models"),
        p("openai-response", "OpenAI (Response API)", "https://api.openai.com/", "v1/responses", "v1/models", .openAIResponse),
        p("deepseek", "DeepSeek", "https://api.deepseek.com/", "v1/chat/completions", "v1/models"),
        p("moonshot", "Moonshot (Kimi)", "https://api.moonshot.cn/", "v1/chat/completions", "v1/models"),
        p("siliconflow", "SiliconFlow", "https://api.siliconflow.cn/", "v1/chat/completions", "v1/models"),
        p("dashscope", "阿里云百炼", "https://dashscope.aliyuncs.com/compatible-mode/", "v1/chat/completions", "v1/models"),
        p("zhipu", "智谱 GLM", "https://open.bigmodel.cn/api/paas/", "v4/chat/completions", "v4/models"),
        p("groq", "Groq", "https://api.groq.com/openai/", "v1/chat/completions", "v1/models"),
        p("xai", "xAI", "https://api.x.ai/", "v1/chat/completions", "v1/models"),
        p("together", "Together AI", "https://api.together.xyz/", "v1/chat/completions", "v1/models"),
        p("anthropic", "Anthropic (Claude)", "https://api.anthropic.com/", "v1/messages", "v1/models", .anthropic),
        p("gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/",
          "models/{model}:streamGenerateContent", "models", .gemini),
    ]

    public static func make(_ preset: Preset, sortOrder: Int = 0) -> ByokProvider {
        ByokProvider(id: IDs.generic(preset.id), name: preset.name, type: preset.type, baseUrl: preset.baseUrl,
                     chatPath: preset.chatPath, modelsPath: preset.modelsPath, sortOrder: sortOrder)
    }
}

/// 模型选择键：`<providerId>::<modelId>`（与安卓设置值格式一致）。
public struct ModelKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var providerId: String
    public var modelId: String

    public init(providerId: String, modelId: String) { self.providerId = providerId; self.modelId = modelId }

    public init?(_ raw: String?) {
        guard let raw, let r = raw.range(of: "::") else { return nil }
        providerId = String(raw[..<r.lowerBound]); modelId = String(raw[r.upperBound...])
        if providerId.isEmpty || modelId.isEmpty { return nil }
    }

    public var description: String { "\(providerId)::\(modelId)" }
}
