import Foundation

// 推理参数解析：对应安卓 ByokChatService.effectiveThinkingKind / isAlwaysOnThinking / addOpenAiThinking / addReasoningOff。

extension ChatRequest {
    var modelId: String { model.id }
    var baseUrl: String { provider.baseUrl }

    /// Gemini 3/4 档位模型直连 Google 时，用服务端默认采样（不发 temperature）。
    var usesGeminiDefaultSampling: Bool {
        Thinking.inferFromModelId(modelId) == .geminiLevel
            && (provider.type == .gemini || Thinking.host(of: baseUrl) == "generativelanguage.googleapis.com")
    }

    /// 有效推理 kind：模型显式配置（含 NONE）→ host 方言 → 模型 ID；聚合网关折算为 effort。
    public var wireThinkingKind: ThinkingParamKind {
        var raw = model.thinkingConfig?.kind ?? Thinking.hostInferredKind(baseUrl) ?? Thinking.inferFromModelId(modelId)
        if raw == .gemini && usesGeminiDefaultSampling { raw = .geminiLevel }
        return Thinking.wireKind(raw, baseUrl: baseUrl)
    }

    /// 关不掉推理：服务商强制、方言表无关闭手段、Kimi K3、Gemini 档位模型。
    public var isAlwaysOnThinking: Bool {
        let cfg = model.thinkingConfig
        if usesGeminiDefaultSampling && cfg?.kind != ThinkingParamKind.none { return true }
        guard let cfg else { return Thinking.isKimiK3(modelId) }
        return Thinking.isAlwaysOn(cfg, baseUrl: baseUrl) || Thinking.isKimiK3(modelId)
    }

    var thinkingRequested: Bool { useThinking || isAlwaysOnThinking }

    var requestedEffort: String { reasoningEffort?.nonBlank?.lowercased() ?? "" }

    func geminiEffort() -> String {
        let config = Thinking.geminiConfig(for: modelId)
        let effort = requestedEffort.isEmpty ? (config?.defaultEffort ?? Thinking.medium) : requestedEffort
        guard let config, !config.effortLevels.contains(effort) else { return effort }
        if effort == Thinking.minimal && config.effortLevels.contains(Thinking.low) { return Thinking.low }
        return config.defaultEffort
    }

    /// 关闭推理：按方言表显式发禁用参数。
    func applyReasoningOff(_ body: inout [String: JSONValue]) {
        let kind = model.thinkingConfig?.kind ?? wireThinkingKind
        switch Thinking.offFor(baseUrl: baseUrl, kind: kind) {
        case .omit, .unsupported: break
        case .reasoningDisabled: body["reasoning"] = ["enabled": false]
        case .thinkingDisabled: body["thinking"] = ["type": "disabled"]
        case .enableThinkingFalse: body["enable_thinking"] = false
        }
    }

    /// OpenAI 兼容请求体的顶层推理字段。
    func applyOpenAIThinking(_ body: inout [String: JSONValue], requested: Bool? = nil, includeReasoningText: Bool = true) {
        let kind = wireThinkingKind
        if kind == .none { return }
        let on = (requested ?? useThinking) || isAlwaysOnThinking
        if !on { applyReasoningOff(&body); return }
        let effort: String
        if kind == .geminiLevel {
            effort = geminiEffort()
        } else if !requestedEffort.isEmpty {
            effort = requestedEffort
        } else if let cfg = model.thinkingConfig {
            effort = Thinking.resolveDefaultEffort(cfg, baseUrl: baseUrl)
        } else {
            effort = Thinking.medium
        }
        let gateway = Thinking.isAggregatingGateway(baseUrl)
        switch kind {
        case .openAIReasoningEffort, .gemini, .geminiLevel:
            if gateway {
                var r: [String: JSONValue] = ["effort": .string(effort)]
                if includeReasoningText && kind == .openAIReasoningEffort { r["exclude"] = false }
                body["reasoning"] = .object(r)
            } else {
                body["reasoning_effort"] = .string(effort)
            }
        case .deepseekThinking:
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = .string(effort)
        case .kimi:
            body["thinking"] = ["type": "enabled"]
        case .qwenThinkingBudget:
            body["enable_thinking"] = true
            body["thinking_budget"] = .number(Double(Thinking.budget(for: kind, effort: effort)))
        default: break
        }
        if includeReasoningText && Thinking.hostInferredKind(baseUrl) == .gemini {
            body["extra_body"] = ["google": ["thinking_config": ["include_thoughts": true]]]
        }
    }

    /// 叠加模型自定义 body（最后一步）；保护键不可覆盖。
    func applyCustomBody(_ body: inout [String: JSONValue]) {
        let protected: Set<String> = ["model", "messages", "input", "contents", "stream", "tools", "system", "instructions"]
        for p in model.customBody {
            let key = p.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !protected.contains(key), let v = p.jsonValue else { continue }
            body[key] = v
        }
    }
}

/// 鉴权与公共请求头（对应安卓 ByokModelApi.applyAuthHeaders）。
enum ProviderHeaders {
    static let openRouterReferer = "https://github.com/MOLAaaaaaaa/MolaGPT.Mobile"
    static let openRouterTitle = "MolaGPT"

    static func build(_ provider: ByokProvider, stream: Bool) -> [String: String] {
        var h: [String: String] = ["Content-Type": "application/json"]
        if stream { h["Accept"] = "text/event-stream" }
        let key = provider.apiKey?.nonBlank
        switch provider.type {
        case .openAICompat, .openAIResponse:
            if let key { h["Authorization"] = "Bearer \(key)" }
        case .anthropic:
            if let key { h["x-api-key"] = key }
            h["anthropic-version"] = "2023-06-01"
        case .gemini:
            break // key 走 URL 查询参数
        }
        if provider.isOpenRouter {
            h["HTTP-Referer"] = openRouterReferer
            h["X-Title"] = openRouterTitle
        }
        for c in provider.customHeaders {
            let n = c.name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { h[n] = c.value }
        }
        return h
    }
}

extension WireMessage.Part {
    /// `data:<mime>;base64,<...>` 或远程 URL。
    var imageURLString: String? {
        guard case .image(let mime, let b64, let url) = self else { return nil }
        if let b64 { return "data:\(mime);base64,\(b64)" }
        return url
    }
}

func encodeBody(_ body: [String: JSONValue]) -> Data { JSONValue.object(body).data() }
