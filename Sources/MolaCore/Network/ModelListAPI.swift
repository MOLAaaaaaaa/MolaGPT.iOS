import Foundation

// 模型列表（对应安卓 ByokModelApi.fetchModels 及 looksLikeByok* 启发式）

public enum ModelListAPI {
    public static func buildRequest(_ provider: ByokProvider) throws -> HTTPRequestSpec {
        var urlString = provider.endpoint(provider.modelsPath)
        if provider.type == .gemini, let key = provider.apiKey?.nonBlank {
            let enc = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
            urlString += (urlString.contains("?") ? "&" : "?") + "key=\(enc)&pageSize=1000"
        }
        var headers = ProviderHeaders.build(provider, stream: false)
        headers["Content-Type"] = nil
        return HTTPRequestSpec(url: try ProviderAdapters.url(urlString), method: "GET", headers: headers)
    }

    /// 解析 /models 响应 → ProviderModel（带能力推断与 OpenRouter 价格/上下文）。
    public static func parse(_ type: ByokProviderType, baseUrl: String, body: Data) throws -> [ProviderModel] {
        guard let root = JSONValue.parse(body) else { throw ProviderError.decoding("模型列表不是 JSON") }
        if let e = root["error"], !e.isNull {
            throw ProviderError.decoding(e["message"]?.stringValue ?? e.stringValue ?? "模型列表返回错误")
        }
        var out: [ProviderModel] = []
        switch type {
        case .openAICompat, .openAIResponse, .anthropic:
            let items = root["data"]?.arrayValue ?? root.arrayValue ?? root["models"]?.arrayValue ?? []
            for item in items {
                guard let id = item["id"]?.stringValue ?? item["name"]?.stringValue else { continue }
                let name = item["display_name"]?.stringValue ?? item["name"]?.stringValue ?? id
                var m = inferredModel(id: id, displayName: name, baseUrl: baseUrl)
                if let ctx = item["context_length"]?.intValue ?? item["context_window"]?.intValue { m.contextWindow = ctx }
                if let p = item["pricing"], let inp = p["prompt"]?.doubleValue, let outp = p["completion"]?.doubleValue {
                    m.pricing = ModelPricing(input: inp * 1_000_000, output: outp * 1_000_000,
                                             cacheRead: p["input_cache_read"]?.doubleValue.map { $0 * 1_000_000 },
                                             cacheWrite: p["input_cache_write"]?.doubleValue.map { $0 * 1_000_000 },
                                             source: "openrouter")
                }
                if let modalities = item["architecture"]?["input_modalities"]?.arrayValue?.compactMap(\.stringValue) {
                    m.supportsVision = modalities.contains("image")
                }
                if let params = item["supported_parameters"]?.arrayValue?.compactMap(\.stringValue) {
                    let lower = Set(params.map { $0.lowercased() })
                    m.supportsToolCalling = lower.contains("tools")
                    let reasoning = lower.contains("reasoning") || lower.contains("include_reasoning") || lower.contains("reasoning_effort")
                    m.supportsThinking = reasoning
                    if reasoning, Thinking.isAggregatingGateway(baseUrl) {
                        var cfg = Thinking.isKimiK3(id) ? Thinking.kimiK3Config : Thinking.config(for: .openAIReasoningEffort, source: .capability)
                        cfg.detectSource = .capability
                        if let r = item["reasoning"] {
                            if r["mandatory"]?.boolValue == true { cfg.alwaysOn = true }
                            let efforts = Thinking.normalize(r["supported_efforts"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                            if !efforts.isEmpty { cfg.effortLevels = efforts }
                            if let d = r["default_effort"]?.stringValue { cfg.defaultEffort = d }
                        }
                        m.thinkingConfig = cfg
                    } else if !reasoning {
                        m.thinkingConfig = nil
                    }
                }
                out.append(m)
            }
        case .gemini:
            for item in root["models"]?.arrayValue ?? [] {
                guard var id = item["name"]?.stringValue else { continue }
                if id.hasPrefix("models/") { id.removeFirst("models/".count) }
                let methods = item["supportedGenerationMethods"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !methods.isEmpty && !methods.contains("generateContent") { continue }
                if id.lowercased().contains("imagen") { continue }
                var m = inferredModel(id: id, displayName: item["displayName"]?.stringValue ?? id, baseUrl: baseUrl)
                m.contextWindow = item["inputTokenLimit"]?.intValue
                if item["thinking"]?.boolValue == true, m.thinkingConfig == nil {
                    m.supportsThinking = true
                    m.thinkingConfig = Thinking.config(for: .gemini, source: .capability)
                }
                out.append(m)
            }
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// 按 ID 启发式填充能力。
    public static func inferredModel(id: String, displayName: String? = nil, baseUrl: String) -> ProviderModel {
        let thinking = Thinking.autoConfig(modelId: id, baseUrl: baseUrl)
        return ProviderModel(id: id, displayName: displayName ?? id,
                             supportsVision: looksLikeVision(id),
                             supportsThinking: thinking != nil,
                             supportsToolCalling: true,
                             thinkingConfig: thinking)
    }

    public static func looksLikeChat(_ id: String) -> Bool {
        let lower = id.lowercased()
        let excluded = ["embedding", "moderation", "tts", "transcribe", "whisper", "audio", "realtime",
                        "computer-use", "deep-research", "live", "veo", "lyria", "imagen"]
        if excluded.contains(where: lower.contains) || looksLikeImage(id) { return false }
        let leaf = lower.substringAfterLast("/")
        let prefixes = ["gpt-", "gpt5", "o1", "o3", "o4", "deepseek", "moonshot", "kimi", "qwen", "qwq", "gemini",
                        "claude", "llama", "mistral", "mixtral", "grok", "glm", "yi-", "ernie"]
        let contained = ["/gpt-", "/deepseek", "/moonshot", "/kimi", "/qwen", "/gemini", "/claude", "/llama",
                         "/mistral", "/grok", "/glm"]
        return prefixes.contains(where: leaf.hasPrefix) || contained.contains(where: lower.contains)
            || lower.contains("chat") || lower.contains("instruct")
    }

    public static func looksLikeImage(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("gpt-image") || lower.matches("gpt-\\d+(\\.\\d+)?-image") || lower.contains("dall-e")
            || lower.contains("imagen") || lower.matches("gemini-.*-image") || lower.contains("flux")
            || lower.contains("stable-diffusion") || lower.contains("sdxl") || lower.contains("seedream")
            || lower.contains("recraft") || lower.contains("grok-imagine") || lower.contains("midjourney")
    }

    public static func looksLikeVision(_ id: String) -> Bool {
        let lower = id.lowercased()
        return ["vision", "gpt-4o", "gpt-4.1", "gpt-5", "gemini", "claude-3", "sonnet-4", "opus-4", "haiku-4",
                "deepseek-chat", "qwen-vl", "-vl", "vl-", "pixtral", "llava", "glm-4v", "4.5v"].contains(where: lower.contains)
    }
}

// MARK: - 标题生成（对应安卓 TitleText.kt / ConversationTitler.kt）

public enum Titler {
    public static let promptTemplate = """
    我会在 <content> 块里给你一段对话内容。
    请把这段用户与助手的对话总结成一个简短标题。
    1. 标题语言与用户的主要语言保持一致
    2. 不要使用标点符号或其他特殊符号
    3. 直接回复标题本身，不要任何前缀、引号或解释
    4. 使用 {locale} 语言总结
    5. 标题不超过 12 个字

    <content>
    {content}
    </content>
    """

    /// 取尾部最多 6 条消息（单条 500 字、合计 3000 字）。
    public static func window(_ messages: [(role: Role, text: String)]) -> [(role: Role, text: String)] {
        var out: [(Role, String)] = []
        var total = 0
        for m in messages.filter({ $0.role == .user || $0.role == .assistant }).suffix(6).reversed() {
            let t = String(m.text.prefix(500))
            if total + t.count > 3000 { break }
            total += t.count
            out.insert((m.role, t), at: 0)
        }
        return out
    }

    public static func prompt(_ messages: [(role: Role, text: String)], locale: String = "zh-CN") -> String {
        let content = window(messages).map { "\($0.role == .assistant ? "Assistant" : "User"): \($0.text)" }
            .joined(separator: "\n\n")
        return promptTemplate.replacingOccurrences(of: "{locale}", with: locale)
            .replacingOccurrences(of: "{content}", with: content)
    }

    /// 非流式标题请求：单条 user 消息、temperature 0.3、显式关思考。
    public static func buildRequest(provider: ByokProvider, model: ProviderModel,
                                    messages: [(role: Role, text: String)]) throws -> HTTPRequestSpec {
        var req = ChatRequest(provider: provider, model: model, messages: [.text(.user, prompt(messages))],
                              temperature: 0.3, useThinking: false, stream: false)
        switch provider.type {
        case .anthropic: req.maxTokens = 2048
        default: break
        }
        return try ProviderAdapters.buildRequest(req)
    }

    /// 清洗：剥思考标签 → 首个非空行 → 去引号/前缀 → 去首尾标点 → 限 30 字。nil 表示不可用。
    public static func clean(_ raw: String?) -> String? {
        guard var t = raw else { return nil }
        t = t.replacingOccurrences(of: "(?s)<think(ing)?>.*?</think(ing)?>", with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "(?s)<think(ing)?>.*", with: " ", options: [.regularExpression, .caseInsensitive])
        guard var line = t.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        if line.hasPrefix("{") || line.hasPrefix("[") || line.hasPrefix("<") || line.matches("HTTP\\s*[45]\\d\\d") { return nil }
        let punct = CharacterSet(charactersIn: "。，,.:：;；!！?？ ")
        let quotes = "^[\"'“”‘’「」『』《》*#\\s]+|[\"'“”‘’「」『』《》*\\s]+$"
        line = line.replacingOccurrences(of: quotes, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "^(标题|title)\\s*[:：]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        line = line.trimmingCharacters(in: punct)
        line = line.replacingOccurrences(of: quotes, with: "", options: .regularExpression).trimmingCharacters(in: punct)
        if line.count > 30 { line = String(line.prefix(30)).trimmingCharacters(in: .whitespaces) }
        return line.isEmpty ? nil : line
    }

    /// 回退标题：首条用户消息截断。
    public static func fallback(firstUserText: String) -> String {
        let line = firstUserText.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return Conversation.defaultTitle }
        return line.count > 20 ? String(line.prefix(20)) + "…" : line
    }
}
