import Foundation

/// 把 SSE 事件解码为统一 StreamEvent 的有状态解码器（每个流 new 一个）。
public protocol StreamDecoder: Sendable {
    mutating func decode(_ event: SSEEvent) -> [StreamEvent]
    /// 流自然结束（连接关闭）时调用，冲刷缓冲。
    mutating func finish() -> [StreamEvent]
}

/// 各 provider 的请求构造 + 解码器工厂。
public enum ProviderAdapters {
    public static func buildRequest(_ req: ChatRequest) throws -> HTTPRequestSpec {
        switch req.provider.type {
        case .openAICompat: return try OpenAICompatAdapter.buildRequest(req)
        case .openAIResponse: return try OpenAIResponsesAdapter.buildRequest(req)
        case .anthropic: return try AnthropicAdapter.buildRequest(req)
        case .gemini: return try GeminiAdapter.buildRequest(req)
        }
    }

    public static func decoder(for type: ByokProviderType) -> any StreamDecoder {
        switch type {
        case .openAICompat: return OpenAICompatDecoder()
        case .openAIResponse: return OpenAIResponsesDecoder()
        case .anthropic: return AnthropicDecoder()
        case .gemini: return GeminiDecoder()
        }
    }

    /// 非流式响应正文提取（标题生成 / 测试连接用）。只认成功形状。
    public static func parseNonStreamText(_ type: ByokProviderType, body: Data) -> String? {
        guard let root = JSONValue.parse(body) else { return nil }
        if let e = root["error"], !e.isNull { return nil }
        switch type {
        case .openAICompat:
            let content = root["choices"]?[0]?["message"]?["content"]
            if let s = content?.stringValue { return s }
            return content?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined()
        case .openAIResponse:
            return root["output"]?.arrayValue?
                .filter { $0["type"]?.stringValue == "message" }
                .flatMap { $0["content"]?.arrayValue ?? [] }
                .filter { $0["type"]?.stringValue == "output_text" }
                .compactMap { $0["text"]?.stringValue }.joined()
        case .anthropic:
            return root["content"]?.arrayValue?
                .filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }.joined()
        case .gemini:
            return root["candidates"]?[0]?["content"]?["parts"]?.arrayValue?
                .filter { $0["thought"]?.boolValue != true }
                .compactMap { $0["text"]?.stringValue }.joined()
        }
    }

    /// 非流式响应的用量。
    public static func parseNonStreamUsage(_ type: ByokProviderType, body: Data) -> Usage? {
        guard let root = JSONValue.parse(body) else { return nil }
        switch type {
        case .openAICompat:
            guard let u = root["usage"] else { return nil }
            return Usage(promptTokens: u["prompt_tokens"]?.intValue, completionTokens: u["completion_tokens"]?.intValue, totalTokens: u["total_tokens"]?.intValue)
        case .openAIResponse: return parseResponsesUsage(root["usage"])
        case .anthropic: return parseAnthropicUsage(root["usage"])
        case .gemini: return parseGeminiUsage(root["usageMetadata"])
        }
    }

    static func url(_ s: String) throws -> URL {
        guard let u = URL(string: s), u.scheme != nil else { throw ProviderError.invalidURL(s) }
        return u
    }
}

/// 从 OpenAI 风格 delta 中拆出的正文/思考（统一处理内联 <think>）。
struct ThinkAwareText: Sendable {
    var splitter = InlineThinkSplitter()

    mutating func text(_ s: String) -> StreamEvent? {
        let r = splitter.feed(s)
        return Self.event(r.visible, r.thinking)
    }

    mutating func flush() -> StreamEvent? {
        let r = splitter.flush()
        return Self.event(r.visible, r.thinking)
    }

    static func event(_ vis: String, _ think: String) -> StreamEvent? {
        if vis.isEmpty && think.isEmpty { return nil }
        return .delta(text: vis.isEmpty ? nil : vis, thinking: think.isEmpty ? nil : think)
    }
}
