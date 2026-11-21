import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 统一的请求/事件抽象（对应安卓 model/StreamEvent.kt、ChatRequest）。

/// 发给模型的一条消息（已从本地 ChatMessage 展平）。
public struct WireMessage: Sendable, Hashable {
    public enum Part: Sendable, Hashable {
        case text(String)
        /// 图片：`data` 为原始字节的 base64（无 data: 前缀）；或远程 URL。
        case image(mimeType: String, base64: String?, url: String?)
    }

    public var role: Role
    public var parts: [Part]
    /// 历史助手消息的思考（DeepSeek 推理模型回放 `reasoning_content` 用）。
    public var reasoning: String?
    /// 原生协议回放项（工具轮次的 assistant/tool 消息）；仅当 `nativeType` 与当前 provider 一致时原样发送。
    public var native: [JSONValue]?
    public var nativeType: ByokProviderType?

    public init(role: Role, parts: [Part], reasoning: String? = nil, native: [JSONValue]? = nil, nativeType: ByokProviderType? = nil) {
        self.role = role; self.parts = parts; self.reasoning = reasoning; self.native = native; self.nativeType = nativeType
    }

    func nativeItems(for type: ByokProviderType) -> [JSONValue]? {
        guard let native, !native.isEmpty, nativeType == type else { return nil }
        return native
    }

    public static func text(_ role: Role, _ text: String) -> WireMessage { WireMessage(role: role, parts: [.text(text)]) }

    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }

    public var hasImages: Bool { parts.contains { if case .image = $0 { return true }; return false } }
}

public struct ChatRequest: Sendable {
    public var provider: ByokProvider
    public var model: ProviderModel
    /// 系统提示词（已做变量替换）；nil/空表示不发。
    public var system: String?
    /// 不含 system 的对话历史，最后一条为当前用户消息。
    public var messages: [WireMessage]
    public var temperature: Double?
    public var useThinking: Bool
    public var reasoningEffort: String?
    public var maxTokens: Int?
    public var stream: Bool
    /// 本轮可用工具（空 = 不下发 tools）。
    public var tools: [ToolSpec] = []

    public init(provider: ByokProvider, model: ProviderModel, system: String? = nil, messages: [WireMessage],
                temperature: Double? = nil, useThinking: Bool = false, reasoningEffort: String? = nil,
                maxTokens: Int? = nil, stream: Bool = true) {
        self.provider = provider; self.model = model; self.system = system; self.messages = messages
        self.temperature = temperature; self.useThinking = useThinking; self.reasoningEffort = reasoningEffort
        self.maxTokens = maxTokens; self.stream = stream
    }

    /// 实际生效的推理配置（nil = 不发推理参数）。
    public var thinking: ThinkingConfig? { model.effectiveThinking(baseUrl: provider.baseUrl) }

    /// 实际是否开启推理（常开模型强制为 true）。
    public var thinkingOn: Bool {
        guard let t = thinking else { return false }
        return useThinking || Thinking.isAlwaysOn(t, baseUrl: provider.baseUrl)
    }

    /// 校正后的档位：不在可选档内时回退到默认档。
    public var effectiveEffort: String {
        guard let t = thinking else { return Thinking.high }
        let levels = Thinking.resolveEffortLevels(t, baseUrl: provider.baseUrl)
        if let e = reasoningEffort?.lowercased(), levels.isEmpty || levels.contains(e) { return e }
        return Thinking.resolveDefaultEffort(t, baseUrl: provider.baseUrl)
    }
}

public enum StreamEvent: Sendable, Hashable {
    /// 正文 / 思考增量。
    case delta(text: String?, thinking: String?)
    /// 用量更新（可能多次，后到覆盖先到）。
    case usage(Usage)
    /// 工具调用状态（P4 工具循环使用）。
    case tool(ToolCallFragment)
    /// 模型返回 / 工具生成的图片。
    case image(url: String)
    /// 联网搜索来源（整条回答的全量列表，整体替换）。
    case sources(refs: [SourceReference], query: String)
    /// 含工具往返的原生协议历史（回答结束时发出一次）。
    case wireHistory(WireHistory)
    /// 结束；可能出现两次（OpenAI usage 在 finish_reason 之后单独一帧），以最后一次为准。
    case finish(reason: String?)
    case failed(String)
}

/// 平台无关的 HTTP 请求描述，便于在 Linux 上单测请求构造。
public struct HTTPRequestSpec: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// 请求超时（秒）。流式请求保持较长。
    public var timeout: TimeInterval = 300

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }

    public var bodyJSON: JSONValue? { body.flatMap(JSONValue.parse) }

    #if canImport(FoundationNetworking) || canImport(Darwin)
    public var urlRequest: URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        r.timeoutInterval = timeout
        return r
    }
    #endif
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "无效的地址：\(u)"
        case .missingAPIKey: return "未设置 API Key"
        case .http(let s, let b): return "HTTP \(s)：\(ProviderError.summarize(b))"
        case .decoding(let m): return "解析失败：\(m)"
        }
    }

    /// 从错误响应体里提取可读信息（`error.message` / `error` / `message`）。
    public static func summarize(_ body: String) -> String {
        if let j = JSONValue.parse(body) {
            if let m = j["error"]?["message"]?.stringValue { return m }
            if let m = j["error"]?.stringValue { return m }
            if let m = j["message"]?.stringValue { return m }
            if let m = j[0]?["error"]?["message"]?.stringValue { return m }
        }
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }
}
