import Foundation

// OpenAI Responses API（对应安卓 streamOpenAiResponse / buildOpenAiResponseBody）

enum OpenAIResponsesAdapter {
    static func input(_ req: ChatRequest) -> [JSONValue] {
        req.messages.flatMap { m -> [JSONValue] in
            if let n = m.nativeItems(for: .openAIResponse) { return n }
            let isAssistant = m.role == .assistant
            let content: [JSONValue] = m.parts.map { part in
                switch part {
                case .text(let t):
                    return ["type": isAssistant ? "output_text" : "input_text", "text": .string(t)]
                case .image:
                    return ["type": "input_image", "image_url": .string(part.imageURLString ?? "")]
                }
            }
            return [["role": .string(OpenAICompatAdapter.roleName(m.role)), "content": .array(content)]]
        }
    }

    static func body(_ req: ChatRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["model": .string(req.modelId), "stream": .bool(req.stream)]
        if let sys = req.system?.nonBlank { body["instructions"] = .string(sys) }
        body["input"] = .array(input(req))
        if !req.tools.isEmpty { body["tools"] = ToolSpec.render(req.tools, for: .openAIResponse) }
        if let mt = req.maxTokens { body["max_output_tokens"] = .number(Double(mt)) }
        if req.wireThinkingKind != .none {
            if req.thinkingRequested {
                body["reasoning"] = ["effort": .string(req.requestedEffort.isEmpty ? Thinking.high : req.requestedEffort),
                                     "summary": "auto"]
            } else {
                req.applyReasoningOff(&body)
            }
        }
        req.applyCustomBody(&body)
        return body
    }

    static func buildRequest(_ req: ChatRequest) throws -> HTTPRequestSpec {
        HTTPRequestSpec(url: try ProviderAdapters.url(req.provider.endpoint(req.provider.chatPath)),
                        headers: ProviderHeaders.build(req.provider, stream: req.stream),
                        body: encodeBody(body(req)))
    }
}

func parseResponsesUsage(_ u: JSONValue?) -> Usage? {
    guard let u, case .object = u else { return nil }
    return Usage(promptTokens: u["input_tokens"]?.intValue,
                 completionTokens: u["output_tokens"]?.intValue,
                 totalTokens: u["total_tokens"]?.intValue,
                 reasoningTokens: u["output_tokens_details"]?["reasoning_tokens"]?.intValue,
                 cachedTokens: u["input_tokens_details"]?["cached_tokens"]?.intValue)
}

struct OpenAIResponsesDecoder: StreamDecoder {
    var finished = false

    mutating func decode(_ event: SSEEvent) -> [StreamEvent] {
        if event.isDone { return finished ? [] : [.finish(reason: "stop")] }
        guard let root = JSONValue.parse(event.data) else { return [] }
        let type = root["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            if let d = root["delta"]?.stringValue, !d.isEmpty { return [.delta(text: d, thinking: nil)] }
            return []
        case "response.completed", "response.incomplete":
            finished = true
            var out: [StreamEvent] = []
            if let u = parseResponsesUsage(root["response"]?["usage"]) { out.append(.usage(u)) }
            out.append(.finish(reason: type == "response.completed" ? "stop" : "length"))
            return out
        case "response.failed":
            finished = true
            return [.failed(root["response"]?["error"]?["message"]?.stringValue ?? "请求失败")]
        case "error":
            return [.failed(root["message"]?.stringValue ?? root["error"]?["message"]?.stringValue ?? "请求失败")]
        default:
            if type.contains("reasoning") && type.hasSuffix(".delta"), let d = root["delta"]?.stringValue, !d.isEmpty {
                return [.delta(text: nil, thinking: d)]
            }
            return []
        }
    }

    mutating func finish() -> [StreamEvent] { finished ? [] : [.finish(reason: nil)] }
}
