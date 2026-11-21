import Foundation

// 官方聊天（对应安卓 MolaGptChatService / StreamParser(serverTurn=true) / WebToolArtifactSplitter）。

public struct MolaChatOptions: Sendable {
    public var sessionId: String
    public var conversationId: String
    public var streamSessionId: String
    public var model: MolaModel
    public var temperature: Double
    public var useThinking: Bool
    public var reasoningEffort: String?
    public var network: Bool
    public var code: Bool
    public var privacyMode: Bool

    public init(sessionId: String, conversationId: String, streamSessionId: String, model: MolaModel, temperature: Double, useThinking: Bool,
                reasoningEffort: String?, network: Bool, code: Bool, privacyMode: Bool = false) {
        self.sessionId = sessionId; self.conversationId = conversationId; self.streamSessionId = streamSessionId; self.model = model
        self.temperature = temperature; self.useThinking = useThinking; self.reasoningEffort = reasoningEffort
        self.network = network; self.code = code; self.privacyMode = privacyMode
    }
}

public enum MolaChatAPI {
    /// 本地 `sess_X` ↔ 服务端 `chat_X`。
    public static func conversationId(_ sessionId: String) -> String {
        sessionId.hasPrefix("sess_") ? "chat_" + sessionId.dropFirst(5) : sessionId.hasPrefix("chat_") ? sessionId : "chat_" + sessionId
    }

    public static func sessionId(_ conversationId: String) -> String {
        conversationId.hasPrefix("chat_") ? "sess_" + conversationId.dropFirst(5) : conversationId
    }

    public static func messages(_ wire: [WireMessage], system: String?) -> [JSONValue] {
        var out: [JSONValue] = []
        if let s = system?.nonBlank { out.append(["role": "system", "content": .string(s)]) }
        for m in wire {
            let role = m.role == .assistant ? "assistant" : m.role == .system ? "system" : "user"
            if m.hasImages {
                out.append(["role": .string(role), "content": .array(m.parts.map { p in
                    switch p {
                    case .text(let t): return ["type": "text", "text": .string(t)]
                    case .image: return ["type": "image_url", "image_url": ["url": .string(p.imageURLString ?? "")]]
                    }
                })])
            } else {
                out.append(["role": .string(role), "content": .string(m.text)])
            }
        }
        return out
    }

    public static func body(_ o: MolaChatOptions, messages: [JSONValue], routes: JSONValue? = nil, modelOverride: String? = nil) -> JSONValue {
        var b: [String: JSONValue] = [
            "session_id": .string(o.streamSessionId), "conversation_id": .string(o.conversationId),
            "model": .string(modelOverride ?? o.model.id), "temperature": .number(o.temperature), "messages": .array(messages),
            "stream": true, "use_thinking": .bool(o.useThinking),
            "enabled_tools": ["network": .bool(o.network), "steelBrowser": .bool(o.network), "code": .bool(o.code), "deepResearch": false],
            "privacy_mode": .bool(o.privacyMode), "client_features": ["subagents": 1],
        ]
        if let e = o.reasoningEffort { b["reasoning_effort"] = .string(e) }
        if let routes { b["molagpt_routes"] = routes }
        return .object(b)
    }

    public static func request(url: URL, body: JSONValue, shortToken: String?, idempotencyKey: String, stream: Bool = true) -> HTTPRequestSpec {
        var h = MolaHeaders.base()
        if stream { h["Accept"] = "text/event-stream" }
        if let t = shortToken { h["Authorization"] = "Bearer \(t)" }
        h["Idempotency-Key"] = idempotencyKey
        var s = HTTPRequestSpec(url: url, headers: h, body: body.data())
        s.timeout = stream ? 600 : 60
        return s
    }

    /// 自动路由结果：真实模型、地址与对工具开关的覆盖。
    public struct Route: Sendable {
        public var modelName: String
        public var apiUrl: String
        public var displayName: String?
        public var thinking: Bool?
        public var reasoningEffort: String?
        public var network: Bool?
        public var raw: JSONValue
    }

    public static func parseRoute(_ data: Data) -> Route? {
        guard let j = JSONValue.parse(data), let name = j["model_name"]?.stringValue, let api = j["api_url"]?.stringValue else { return nil }
        let c = j["controls"]
        func onOff(_ v: JSONValue?) -> Bool? { v?.stringValue == "on" ? true : v?.stringValue == "off" ? false : nil }
        var routes = j.objectValue ?? [:]
        routes.removeValue(forKey: "success")
        let effort = c?["reasoning_effort"]?.stringValue
        return Route(modelName: name, apiUrl: api, displayName: j["display_name"]?.stringValue, thinking: onOff(c?["thinking_mode"]),
                     reasoningEffort: effort == "inherit" ? nil : effort, network: onOff(c?["network_mode"]), raw: .object(routes))
    }

    public static func resumeBody(streamSessionId: String, offset: Int) -> JSONValue {
        ["action": "resume", "session_id": .string(streamSessionId), "offset": .number(Double(offset))]
    }

    public static func stopBody(_ streamSessionId: String) -> JSONValue { ["session_id": .string(streamSessionId)] }

    public static func titleBody(user: String, answer: String) -> JSONValue {
        ["messages": [["role": "system", "content": "根据对话生成一个不超过 14 个字的中文标题，不要标点符号，只输出标题。"],
                      ["role": "user", "content": .string("用户问题：\(user)\n\nAI回答：\(answer.prefix(1000))\n\n请为这段对话生成标题。")]],
         "temperature": 0.2, "max_tokens": 30]
    }

    public static func parseTitle(_ data: Data) -> String? {
        guard let j = JSONValue.parse(data) else { return nil }
        return Titler.clean(j["title"]?.stringValue ?? j["choices"]?[0]?["message"]?["content"]?.stringValue)
    }
}

/// 官方流解码：OpenAI 兼容 delta + molagpt_sources + error + 正文内工具标记（blockquote.tool-status / DSanalysis / steel-step）+ 内联 think。
/// serverTurn 模式下忽略 finish_reason，以 [DONE] 收尾。`dataFrames` 记录收到的 data 帧数（断线续传 offset）。
public struct MolaStreamDecoder: Sendable {
    public private(set) var dataFrames = 0
    private var think = InlineThinkSplitter()
    private var buffer = ""
    private var toolSeq = 0
    private var sources: [SourceReference] = []
    private var finished = false

    public init() {}

    public mutating func decode(_ ev: SSEEvent) -> [StreamEvent] {
        if ev.isDone { finished = true; return flushAll() + [.finish(reason: "stop")] }
        guard let j = JSONValue.parse(ev.data) else { return [] }
        if j["type"]?.stringValue == "session_init" || j["session_init"] != nil { return [] }
        dataFrames += 1
        var out: [StreamEvent] = []
        if let e = j["error"], !e.isNull {
            out.append(.failed(e.stringValue ?? e["message"]?.stringValue ?? "服务端错误"))
            return out
        }
        if let src = j["molagpt_sources"]?.arrayValue {
            for (i, s) in src.enumerated() {
                guard let url = s["url"]?.stringValue else { continue }
                let idx = MolaJSON.int(s["id"]) ?? MolaJSON.int(s["index"]) ?? (sources.count + i + 1)
                if !sources.contains(where: { $0.url == url }) {
                    sources.append(SourceReference(title: s["title"]?.stringValue ?? url, url: url,
                                                   snippet: s["snippet"]?.stringValue ?? s["content"]?.stringValue, index: idx))
                }
            }
            out.append(.sources(refs: sources, query: ""))
        }
        if let sub = j["molagpt_subagents"], let batch = sub["batch"]?.stringValue {
            let agents = sub["agents"]?.arrayValue ?? []
            let waiting = MolaJSON.bool(sub["waiting"]) ?? false
            out.append(.tool(ToolCallFragment(id: "subagents_\(batch)", name: "subagents", status: waiting ? .running : .success,
                                              label: "子代理 · \(agents.count) 个", resultPreview: agents.compactMap { $0["title"]?.stringValue ?? $0["task"]?.stringValue }.joined(separator: "\n"))))
        }
        let delta = j["choices"]?[0]?["delta"]
        if let r = delta?["reasoning_content"]?.stringValue ?? delta?["reasoning"]?.stringValue, !r.isEmpty {
            out.append(.delta(text: nil, thinking: r))
        }
        if let c = delta?["content"]?.stringValue, !c.isEmpty { out += feedText(c) }
        // Responses 事件兼容
        if j["type"]?.stringValue == "response.output_text.delta", let d = j["delta"]?.stringValue { out += feedText(d) }
        if let u = j["usage"], !u.isNull {
            out.append(.usage(Usage(promptTokens: MolaJSON.int(u["prompt_tokens"]), completionTokens: MolaJSON.int(u["completion_tokens"]),
                                    totalTokens: MolaJSON.int(u["total_tokens"]))))
        }
        return out
    }

    public mutating func finish() -> [StreamEvent] { finished ? [] : flushAll() + [.finish(reason: nil)] }

    private mutating func feedText(_ s: String) -> [StreamEvent] {
        buffer += s
        var out: [StreamEvent] = []
        while true {
            guard let open = buffer.range(of: "<", options: .literal) else { out += emitText(buffer); buffer = ""; break }
            let before = String(buffer[..<open.lowerBound])
            let rest = buffer[open.lowerBound...]
            let tags: [(String, String)] = [("<blockquote", "</blockquote>"), ("<DSanalysis", "</DSanalysis>"), ("<steel-step", "</steel-step>")]
            if let (o, c) = tags.first(where: { rest.hasPrefix($0.0) }) {
                guard let close = rest.range(of: c) else { out += emitText(before); buffer = String(rest); break } // 等后续数据
                out += emitText(before)
                let markup = String(rest[..<close.upperBound])
                out += tool(markup, kind: o)
                buffer = String(rest[close.upperBound...])
                continue
            }
            // 可能是半截标记：保留到下一块
            if tags.contains(where: { $0.0.hasPrefix(String(rest.prefix(min(rest.count, $0.0.count)))) }) && rest.count < 14 {
                out += emitText(before); buffer = String(rest); break
            }
            out += emitText(before + "<")
            buffer = String(rest.dropFirst())
        }
        return out
    }

    private mutating func emitText(_ s: String) -> [StreamEvent] {
        guard !s.isEmpty else { return [] }
        let r = think.feed(s)
        if r.visible.isEmpty && r.thinking.isEmpty { return [] }
        return [.delta(text: r.visible.isEmpty ? nil : r.visible, thinking: r.thinking.isEmpty ? nil : r.thinking)]
    }

    private mutating func flushAll() -> [StreamEvent] {
        var out = emitText(buffer)
        buffer = ""
        let r = think.flush()
        if !r.visible.isEmpty || !r.thinking.isEmpty { out.append(.delta(text: r.visible.nonBlank, thinking: r.thinking.nonBlank)) }
        return out
    }

    private func attr(_ name: String, _ s: String) -> String? {
        guard let r = s.range(of: "\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        return String(s[r]).components(separatedBy: "\"").dropFirst().first
    }

    private mutating func tool(_ markup: String, kind: String) -> [StreamEvent] {
        toolSeq += 1
        let inner = HTMLText.strip(markup)
        switch kind {
        case "<blockquote":
            let cls = attr("class", markup) ?? ""
            guard cls.contains("tool-status") else { return emitText(markup) }
            let status: ToolStatus = cls.contains("cancelled") ? .cancelled : cls.contains("error") ? .failed
                : (cls.contains("completed") || cls.contains("success")) ? .success : .running
            if let batch = attr("data-subagent-batch", markup) {
                return [.tool(ToolCallFragment(id: "subagents_\(batch)", name: "subagents", status: status, label: inner, provider: "server"))]
            }
            let id = attr("data-tool-call", markup) ?? "srv_\(toolSeq)"
            let name = attr("data-tool-name", markup) ?? "tool"
            return [.tool(ToolCallFragment(id: "tool_\(id)", name: name, status: status, label: inner.nonBlank ?? ToolLabels.label(name), provider: "server"))]
        case "<DSanalysis":
            let type = attr("data-tool-type", markup) ?? "analysis"
            let id = attr("data-tool-call", markup) ?? "ds_\(toolSeq)"
            let show = ["python", "mcp", "image-action", "code-search"].contains(type)
            let label = ["python": "代码执行", "mcp": "MCP", "image-action": "图像处理", "code-search": "代码搜索"][type] ?? "分析"
            return [.tool(ToolCallFragment(id: "tool_\(id)", name: type, status: .success, label: label, resultPreview: show ? String(inner.prefix(1200)) : nil, provider: "server"))]
        default:
            return [.tool(ToolCallFragment(id: "steel_\(toolSeq)", name: "fetch_url", status: .success, label: "浏览网页", resultPreview: String(inner.prefix(400)), provider: "server"))]
        }
    }
}
