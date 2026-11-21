import Foundation

// Gemini 原生 generateContent（对应安卓 streamGemini / buildGeminiBody / geminiEndpoint）

enum GeminiAdapter {
    static func contents(_ req: ChatRequest) -> [JSONValue] {
        req.messages.filter { $0.role == .user || $0.role == .assistant || $0.nativeItems(for: .gemini) != nil }.flatMap { m -> [JSONValue] in
            if let n = m.nativeItems(for: .gemini) { return n }
            let parts: [JSONValue] = m.parts.compactMap { part in
                switch part {
                case .text(let t): return ["text": .string(t)]
                case .image(let mime, let b64, let url):
                    if let b64 { return ["inlineData": ["mimeType": .string(mime), "data": .string(b64)]] }
                    if let url { return ["fileData": ["mimeType": .string(mime), "fileUri": .string(url)]] }
                    return nil
                }
            }
            return [["role": .string(m.role == .assistant ? "model" : "user"), "parts": .array(parts)]]
        }
    }

    static func body(_ req: ChatRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["contents": .array(contents(req))]
        if let sys = req.system?.nonBlank { body["systemInstruction"] = ["parts": [["text": .string(sys)]]] }
        if !req.tools.isEmpty { body["tools"] = ToolSpec.render(req.tools, for: .gemini) }
        var gen: [String: JSONValue] = [:]
        if !req.usesGeminiDefaultSampling, let t = req.temperature { gen["temperature"] = .number(t) }
        if let mt = req.maxTokens { gen["maxOutputTokens"] = .number(Double(mt)) }
        let kind = req.wireThinkingKind
        if req.thinkingRequested && (kind == .gemini || kind == .geminiLevel) {
            var tc: [String: JSONValue] = ["includeThoughts": true]
            if kind == .geminiLevel {
                tc["thinkingLevel"] = .string(req.geminiEffort())
            } else {
                let effort = req.requestedEffort.isEmpty ? Thinking.medium : req.requestedEffort
                tc["thinkingBudget"] = .number(Double(Thinking.budget(for: kind, effort: effort)))
            }
            gen["thinkingConfig"] = .object(tc)
        }
        body["generationConfig"] = .object(gen)
        req.applyCustomBody(&body)
        return body
    }

    /// `baseUrl + chatPath`，`{model}` 替换；流式加 `alt=sse`；key 作为查询参数。
    static func endpoint(_ provider: ByokProvider, model: String, stream: Bool) -> String {
        var path = provider.chatPath.replacingOccurrences(of: "{model}", with: model)
        if !stream { path = path.replacingOccurrences(of: ":streamGenerateContent", with: ":generateContent") }
        var url = provider.endpoint(path)
        var query: [String] = []
        if stream { query.append("alt=sse") }
        if let key = provider.apiKey?.nonBlank {
            let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? key
            query.append("key=\(enc)")
        }
        if !query.isEmpty { url += (url.contains("?") ? "&" : "?") + query.joined(separator: "&") }
        return url
    }

    static func buildRequest(_ req: ChatRequest) throws -> HTTPRequestSpec {
        HTTPRequestSpec(url: try ProviderAdapters.url(endpoint(req.provider, model: req.modelId, stream: req.stream)),
                        headers: ProviderHeaders.build(req.provider, stream: req.stream),
                        body: encodeBody(body(req)))
    }
}

/// usageMetadata 为累计值：completion = candidates + thoughts。
func parseGeminiUsage(_ u: JSONValue?) -> Usage? {
    guard let u, case .object = u else { return nil }
    let cand = u["candidatesTokenCount"]?.intValue
    let thoughts = u["thoughtsTokenCount"]?.intValue
    let completion: Int? = (cand == nil && thoughts == nil) ? nil : (cand ?? 0) + (thoughts ?? 0)
    return Usage(promptTokens: u["promptTokenCount"]?.intValue, completionTokens: completion,
                 totalTokens: u["totalTokenCount"]?.intValue, reasoningTokens: thoughts,
                 cachedTokens: u["cachedContentTokenCount"]?.intValue)
}

struct GeminiDecoder: StreamDecoder {
    var finished = false

    mutating func decode(_ event: SSEEvent) -> [StreamEvent] {
        guard let root = JSONValue.parse(event.data) else { return [] }
        // 非流式回退时整个响应可能是数组
        if let arr = root.arrayValue {
            return arr.flatMap { decodeObject($0) }
        }
        return decodeObject(root)
    }

    private mutating func decodeObject(_ root: JSONValue) -> [StreamEvent] {
        if let msg = root["error"]?["message"]?.stringValue { return [.failed(msg)] }
        var out: [StreamEvent] = []
        var finishReason: String?
        for cand in root["candidates"]?.arrayValue ?? [] {
            for part in cand["content"]?["parts"]?.arrayValue ?? [] {
                if let t = part["text"]?.stringValue, !t.isEmpty {
                    out.append(part["thought"]?.boolValue == true ? .delta(text: nil, thinking: t) : .delta(text: t, thinking: nil))
                }
                if let mime = part["inlineData"]?["mimeType"]?.stringValue, let data = part["inlineData"]?["data"]?.stringValue {
                    out.append(.image(url: "data:\(mime);base64,\(data)"))
                }
            }
            if let fr = cand["finishReason"]?.stringValue { finishReason = fr }
        }
        if let u = parseGeminiUsage(root["usageMetadata"]) { out.append(.usage(u)) }
        if let block = root["promptFeedback"]?["blockReason"]?.stringValue {
            out.append(.failed("请求被拦截：\(block)"))
        }
        if let fr = finishReason {
            finished = true
            out.append(.finish(reason: fr.lowercased()))
        }
        return out
    }

    mutating func finish() -> [StreamEvent] { finished ? [] : [.finish(reason: nil)] }
}
