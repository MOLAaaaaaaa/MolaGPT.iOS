import Foundation

/// 观察同一条 SSE 流，累积本轮的工具调用和「可原样回放的助手消息」。
/// 与显示用的 StreamDecoder 并行运行，互不干扰。
/// - OpenAI：`delta.tool_calls[index]` 归位，id/name 取首次，arguments 拼接。
/// - Anthropic：按 index 重建完整 content 块（thinking + signature、redacted_thinking、text、tool_use）。
/// - Gemini：parts 原样保留（含 thoughtSignature），只合并相邻的纯文本。
/// - Responses：收集 output_item.done；completed/incomplete 带非空 output 时以其为准。
public struct ToolRoundAccumulator: Sendable {
    public let type: ByokProviderType
    public var replayReasoning = false

    // OpenAI compat
    private struct Slot: Sendable { var id: String?; var name: String?; var args = "" }
    private var slots: [Int: Slot] = [:]
    private var slotOrder: [Int] = []
    private var text = ""
    private var reasoning = ""

    // Anthropic
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var blockOrder: [Int] = []

    // Gemini
    private var parts: [JSONValue] = []

    // Responses
    private var items: [JSONValue] = []

    public init(type: ByokProviderType) { self.type = type }

    public mutating func observe(_ event: SSEEvent) {
        guard let root = JSONValue.parse(event.data) else { return }
        switch type {
        case .openAICompat: observeOpenAI(root)
        case .anthropic: observeAnthropic(root, event: event.event)
        case .gemini:
            if let arr = root.arrayValue { arr.forEach { observeGemini($0) } } else { observeGemini(root) }
        case .openAIResponse: observeResponses(root, event: event.event)
        }
    }

    // MARK: OpenAI

    private mutating func observeOpenAI(_ root: JSONValue) {
        guard let delta = root["choices"]?[0]?["delta"] ?? root["choices"]?[0]?["message"] else { return }
        if let c = delta["content"]?.stringValue { text += c }
        if let r = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue { reasoning += r }
        for tc in delta["tool_calls"]?.arrayValue ?? [] {
            let idx = tc["index"]?.intValue ?? 0
            if slots[idx] == nil { slots[idx] = Slot(); slotOrder.append(idx) }
            if slots[idx]!.id == nil, let id = tc["id"]?.stringValue, !id.isEmpty { slots[idx]!.id = id }
            if slots[idx]!.name == nil, let n = tc["function"]?["name"]?.stringValue, !n.isEmpty { slots[idx]!.name = n }
            if let a = tc["function"]?["arguments"]?.stringValue { slots[idx]!.args += a }
            else if let o = tc["function"]?["arguments"], o.objectValue != nil { slots[idx]!.args += o.jsonString() }
        }
    }

    // MARK: Anthropic

    private mutating func observeAnthropic(_ root: JSONValue, event: String?) {
        let kind = root["type"]?.stringValue ?? event ?? ""
        let idx = root["index"]?.intValue ?? 0
        switch kind {
        case "content_block_start":
            guard let b = root["content_block"]?.objectValue else { return }
            if blocks[idx] == nil { blockOrder.append(idx) }
            blocks[idx] = b
        case "content_block_delta":
            guard var b = blocks[idx], let d = root["delta"] else { return }
            if let t = d["text"]?.stringValue { b["text"] = .string((b["text"]?.stringValue ?? "") + t) }
            if let t = d["thinking"]?.stringValue { b["thinking"] = .string((b["thinking"]?.stringValue ?? "") + t) }
            if let s = d["signature"]?.stringValue { b["signature"] = .string(s) }
            if let p = d["partial_json"]?.stringValue { partialJSON[idx, default: ""] += p }
            blocks[idx] = b
        default: break
        }
    }

    // MARK: Gemini

    private mutating func observeGemini(_ root: JSONValue) {
        for p in root["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? [] {
            guard let po = p.objectValue else { continue }
            let plain = po["text"] != nil && po["thoughtSignature"] == nil && po["functionCall"] == nil
            if plain, let last = parts.last?.objectValue, last["text"] != nil, last["thoughtSignature"] == nil,
               last["functionCall"] == nil, (last["thought"]?.boolValue ?? false) == (po["thought"]?.boolValue ?? false) {
                var merged = last
                merged["text"] = .string((last["text"]?.stringValue ?? "") + (po["text"]?.stringValue ?? ""))
                parts[parts.count - 1] = .object(merged)
            } else {
                parts.append(p)
            }
        }
    }

    // MARK: Responses

    private mutating func observeResponses(_ root: JSONValue, event: String?) {
        let kind = root["type"]?.stringValue ?? event ?? ""
        switch kind {
        case "response.output_item.done":
            if let item = root["item"] { items.append(item) }
        case "response.completed", "response.incomplete":
            if let out = root["response"]?["output"]?.arrayValue, !out.isEmpty { items = out }
        case "response.output_text.delta":
            if let d = root["delta"]?.stringValue { text += d }
        default: break
        }
    }

    // MARK: 结果

    public var calls: [PendingToolCall] {
        switch type {
        case .openAICompat:
            return slotOrder.compactMap { i in
                guard let s = slots[i], let name = s.name else { return nil }
                return PendingToolCall(id: s.id ?? IDs.fragment(), name: name, arguments: s.args.isEmpty ? "{}" : s.args)
            }
        case .anthropic:
            return builtAnthropicBlocks().compactMap { b in
                guard b["type"]?.stringValue == "tool_use", let name = b["name"]?.stringValue else { return nil }
                return PendingToolCall(id: b["id"]?.stringValue ?? IDs.fragment(), name: name, arguments: (b["input"] ?? .object([:])).jsonString())
            }
        case .gemini:
            return parts.compactMap { p in
                guard let fc = p["functionCall"], let name = fc["name"]?.stringValue else { return nil }
                let rawId = fc["id"]?.stringValue
                return PendingToolCall(id: rawId ?? IDs.fragment(), callId: rawId, name: name, arguments: (fc["args"] ?? .object([:])).jsonString())
            }
        case .openAIResponse:
            return items.compactMap { it in
                guard it["type"]?.stringValue == "function_call", let name = it["name"]?.stringValue else { return nil }
                let callId = it["call_id"]?.stringValue
                return PendingToolCall(id: it["id"]?.stringValue ?? callId ?? IDs.fragment(), callId: callId, name: name,
                                       arguments: it["arguments"]?.stringValue ?? "{}")
            }
        }
    }

    private func builtAnthropicBlocks() -> [[String: JSONValue]] {
        blockOrder.compactMap { i in
            guard var b = blocks[i] else { return nil }
            if b["type"]?.stringValue == "tool_use" {
                let raw = partialJSON[i] ?? ""
                if let parsed = JSONValue.parse(raw), parsed.objectValue != nil { b["input"] = parsed }
                else if b["input"] == nil { b["input"] = .object([:]) }
            }
            if b["type"]?.stringValue == "text", (b["text"]?.stringValue ?? "").isEmpty { return nil }
            return b
        }
    }

    /// 本轮助手消息的原生回放形状（一个或多个 item）。
    public func assistantReplay(calls: [PendingToolCall]) -> [JSONValue] {
        switch type {
        case .openAICompat:
            var o: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
            if !calls.isEmpty {
                o["tool_calls"] = .array(calls.map { c in
                    ["id": .string(c.id), "type": "function", "function": ["name": .string(c.name), "arguments": .string(c.arguments)]]
                })
            }
            if replayReasoning, !reasoning.isEmpty { o["reasoning_content"] = .string(reasoning) }
            return [.object(o)]
        case .anthropic:
            let content = builtAnthropicBlocks().map { JSONValue.object($0) }
            return [["role": "assistant", "content": .array(content.isEmpty ? [["type": "text", "text": " "]] : content)]]
        case .gemini:
            return [["role": "model", "parts": .array(parts.isEmpty ? [["text": " "]] : parts)]]
        case .openAIResponse:
            var out = items
            if !out.contains(where: { $0["type"]?.stringValue == "message" }), !text.isEmpty {
                out.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": .string(text)]]])
            }
            return out
        }
    }

    /// 工具结果的原生回放形状。
    public static func resultsReplay(_ type: ByokProviderType, calls: [PendingToolCall], results: [ToolResult]) -> [JSONValue] {
        let pairs = Array(zip(calls, results))
        switch type {
        case .openAICompat:
            return pairs.map { c, r in ["role": "tool", "tool_call_id": .string(c.id), "content": .string(r.output)] }
        case .anthropic:
            let blocks: [JSONValue] = pairs.map { c, r in
                var b: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(c.id), "content": .string(r.output)]
                if r.failed { b["is_error"] = true }
                return .object(b)
            }
            return [["role": "user", "content": .array(blocks)]]
        case .gemini:
            let ps: [JSONValue] = pairs.map { c, r in
                var fr: [String: JSONValue] = ["name": .string(c.name), "response": [r.failed ? "error" : "result": .string(r.output)]]
                if let id = c.callId { fr["id"] = .string(id) }
                return ["functionResponse": .object(fr)]
            }
            return [["role": "user", "parts": .array(ps)]]
        case .openAIResponse:
            return pairs.map { c, r in ["type": "function_call_output", "call_id": .string(c.callId ?? c.id), "output": .string(r.output)] }
        }
    }
}

/// 一整轮（含工具往返）的原生协议历史，存在助手消息 metadata 里供下一轮原样回放。
public struct WireHistory: Codable, Sendable, Hashable {
    public var providerType: String
    public var modelId: String?
    public var items: [JSONValue]

    public init(providerType: ByokProviderType, modelId: String?, items: [JSONValue]) {
        self.providerType = providerType.rawValue; self.modelId = modelId; self.items = items
    }

    public static let metadataKey = "wire_history"

    public var encoded: String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "" }
    public static func decode(_ s: String?) -> WireHistory? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WireHistory.self, from: d)
    }
}

extension Usage {
    /// 多轮请求的用量相加（每轮都计费）。
    public func adding(_ o: Usage) -> Usage {
        func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        return Usage(promptTokens: add(promptTokens, o.promptTokens), completionTokens: add(completionTokens, o.completionTokens),
                     totalTokens: add(totalTokens, o.totalTokens), reasoningTokens: add(reasoningTokens, o.reasoningTokens),
                     cachedTokens: add(cachedTokens, o.cachedTokens), cacheWriteTokens: add(cacheWriteTokens, o.cacheWriteTokens))
    }
}
