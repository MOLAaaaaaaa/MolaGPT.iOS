import Foundation

// OpenAI 兼容 chat/completions（对应安卓 streamOpenAiCompatible / buildOpenAiBody / StreamParser / OpenAiMessageContentBuilder）

enum OpenAICompatAdapter {
    static func messages(_ req: ChatRequest) -> [JSONValue] {
        var out: [JSONValue] = []
        if let sys = req.system?.nonBlank { out.append(["role": "system", "content": .string(sys)]) }
        let replayReasoning = req.wireThinkingKind == .deepseekThinking
        for m in req.messages {
            if let n = m.nativeItems(for: .openAICompat) { out.append(contentsOf: n); continue }
            var obj: [String: JSONValue] = ["role": .string(roleName(m.role))]
            if m.hasImages {
                obj["content"] = .array(m.parts.map { part in
                    switch part {
                    case .text(let t): return ["type": "text", "text": .string(t)]
                    case .image:
                        return ["type": "image_url", "image_url": ["url": .string(part.imageURLString ?? "")]]
                    }
                })
            } else {
                obj["content"] = .string(m.text)
            }
            if replayReasoning, m.role == .assistant, let r = m.reasoning?.nonBlank {
                obj["reasoning_content"] = .string(r)
            }
            out.append(.object(obj))
        }
        return out
    }

    static func roleName(_ r: Role) -> String {
        switch r {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        case .tool: return "tool"
        }
    }

    static func body(_ req: ChatRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["model": .string(req.modelId), "stream": .bool(req.stream)]
        if !req.usesGeminiDefaultSampling, let t = req.temperature { body["temperature"] = .number(t) }
        if req.stream && !req.baseUrl.lowercased().contains("api.mistral.ai") {
            body["stream_options"] = ["include_usage": true]
        }
        if let mt = req.maxTokens { body["max_tokens"] = .number(Double(mt)) }
        body["messages"] = .array(messages(req))
        if !req.tools.isEmpty { body["tools"] = ToolSpec.render(req.tools, for: .openAICompat) }
        req.applyOpenAIThinking(&body)
        req.applyCustomBody(&body)
        return body
    }

    static func buildRequest(_ req: ChatRequest) throws -> HTTPRequestSpec {
        HTTPRequestSpec(url: try ProviderAdapters.url(req.provider.endpoint(req.provider.chatPath)),
                        headers: ProviderHeaders.build(req.provider, stream: req.stream),
                        body: encodeBody(body(req)))
    }
}

/// OpenAI usage：prompt/completion/total + details（reasoning、cached）。
func parseOpenAIUsage(_ u: JSONValue?) -> Usage? {
    guard let u, case .object = u else { return nil }
    let cached = u["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? u["prompt_cache_hit_tokens"]?.intValue
    let usage = Usage(promptTokens: u["prompt_tokens"]?.intValue,
                      completionTokens: u["completion_tokens"]?.intValue,
                      totalTokens: u["total_tokens"]?.intValue,
                      reasoningTokens: u["completion_tokens_details"]?["reasoning_tokens"]?.intValue,
                      cachedTokens: cached)
    return usage.promptTokens == nil && usage.completionTokens == nil ? nil : usage
}

struct OpenAICompatDecoder: StreamDecoder {
    var text = ThinkAwareText()
    var finished = false

    mutating func decode(_ event: SSEEvent) -> [StreamEvent] {
        if event.isDone {
            var out: [StreamEvent] = []
            if let f = text.flush() { out.append(f) }
            out.append(.finish(reason: "stop"))
            finished = true
            return out
        }
        guard let root = JSONValue.parse(event.data) else { return [] }
        if let err = root["error"], !err.isNull {
            return [.failed(err["message"]?.stringValue ?? err.stringValue ?? "请求失败")]
        }
        var out: [StreamEvent] = []
        if let choice = root["choices"]?[0] {
            let delta = choice["delta"] ?? choice["message"]
            if let r = delta?["reasoning_content"]?.stringValue ?? delta?["reasoning"]?.stringValue, !r.isEmpty {
                out.append(.delta(text: nil, thinking: r))
            }
            if let content = delta?["content"] {
                if let s = content.stringValue, !s.isEmpty {
                    if let e = text.text(s) { out.append(e) }
                } else if let parts = content.arrayValue {
                    // 部分网关以数组下发：{type:text,text} / {type:thinking,thinking}
                    for p in parts {
                        if let t = p["thinking"]?.stringValue, !t.isEmpty { out.append(.delta(text: nil, thinking: t)) }
                        else if let t = p["text"]?.stringValue, !t.isEmpty, let e = text.text(t) { out.append(e) }
                    }
                }
            }
            if let fr = choice["finish_reason"]?.stringValue {
                if let f = text.flush() { out.append(f) }
                out.append(.finish(reason: fr))
            }
        }
        if let u = parseOpenAIUsage(root["usage"]) { out.append(.usage(u)) }
        return out
    }

    mutating func finish() -> [StreamEvent] {
        var out: [StreamEvent] = []
        if let f = text.flush() { out.append(f) }
        if !finished { out.append(.finish(reason: nil)) }
        return out
    }
}
