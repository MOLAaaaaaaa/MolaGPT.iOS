import Foundation

// Anthropic Messages API（对应安卓 streamAnthropic / buildAnthropicBody / ByokMessageContentBuilder）

enum AnthropicAdapter {
    static let ephemeral: JSONValue = ["type": "ephemeral"]

    static func messages(_ req: ChatRequest) -> [JSONValue] {
        var out: [[String: JSONValue]] = []
        for m in req.messages {
            if let n = m.nativeItems(for: .anthropic) { out.append(contentsOf: n.compactMap(\.objectValue)); continue }
            guard m.role == .user || m.role == .assistant else { continue }
            var blocks: [JSONValue] = []
            for part in m.parts {
                switch part {
                case .text(let t):
                    if !t.isEmpty { blocks.append(["type": "text", "text": .string(t)]) }
                case .image(let mime, let b64, let url):
                    if let b64 {
                        blocks.append(["type": "image", "source": ["type": "base64", "media_type": .string(mime), "data": .string(b64)]])
                    } else if let url {
                        blocks.append(["type": "image", "source": ["type": "url", "url": .string(url)]])
                    }
                }
            }
            if blocks.isEmpty { blocks.append(["type": "text", "text": " "]) }
            out.append(["role": .string(m.role == .user ? "user" : "assistant"), "content": .array(blocks)])
        }
        // 缓存断点：最后一条消息的最后一个块。
        if var last = out.last, case .array(var blocks)? = last["content"], var lastBlock = blocks.last?.objectValue {
            lastBlock["cache_control"] = ephemeral
            blocks[blocks.count - 1] = .object(lastBlock)
            last["content"] = .array(blocks)
            out[out.count - 1] = last
        }
        return out.map { .object($0) }
    }

    static func body(_ req: ChatRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(req.modelId),
            "max_tokens": .number(Double(req.maxTokens ?? 4096)),
            "stream": .bool(req.stream),
            "messages": .array(messages(req)),
        ]
        if let t = req.temperature { body["temperature"] = .number(t) }
        if !req.tools.isEmpty { body["tools"] = ToolSpec.render(req.tools, for: .anthropic) }
        if let sys = req.system?.nonBlank {
            body["system"] = [["type": "text", "text": .string(sys), "cache_control": ephemeral]]
        }
        let kind = req.wireThinkingKind
        if req.thinkingRequested && kind != .none {
            let effort = req.requestedEffort.isEmpty ? Thinking.medium : req.requestedEffort
            if kind == .claudeBudget {
                let budget = Thinking.budget(for: kind, effort: effort)
                if budget >= 4096 { body["max_tokens"] = .number(Double(budget + 1024)) }
                body["thinking"] = ["type": "enabled", "budget_tokens": .number(Double(budget))]
            } else {
                body["thinking"] = ["type": "adaptive", "effort": .string(effort)]
            }
            // 开启 thinking 时 Anthropic 要求 temperature 为 1（或省略）。
            body["temperature"] = nil
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

/// Anthropic usage：输入 = input + cache_read + cache_creation。
func parseAnthropicUsage(_ u: JSONValue?) -> Usage? {
    guard let u, case .object = u else { return nil }
    let input = u["input_tokens"]?.intValue
    let read = u["cache_read_input_tokens"]?.intValue
    let write = u["cache_creation_input_tokens"]?.intValue
    let prompt: Int? = input.map { $0 + (read ?? 0) + (write ?? 0) }
    return Usage(promptTokens: prompt, completionTokens: u["output_tokens"]?.intValue,
                 cachedTokens: read, cacheWriteTokens: write)
}

struct AnthropicDecoder: StreamDecoder {
    var usage = Usage()
    var finished = false

    mutating func decode(_ event: SSEEvent) -> [StreamEvent] {
        guard let root = JSONValue.parse(event.data) else { return [] }
        switch root["type"]?.stringValue ?? event.event ?? "" {
        case "message_start":
            if let u = parseAnthropicUsage(root["message"]?["usage"]) { usage = usage.merged(with: u); return [.usage(usage)] }
            return []
        case "content_block_delta":
            let d = root["delta"]
            if let t = d?["thinking"]?.stringValue, !t.isEmpty { return [.delta(text: nil, thinking: t)] }
            if let t = d?["text"]?.stringValue, !t.isEmpty { return [.delta(text: t, thinking: nil)] }
            return []
        case "message_delta":
            // message_delta.usage 只有输出侧；不能用它覆盖输入侧。
            if let out = root["usage"]?["output_tokens"]?.intValue {
                usage.completionTokens = out
                usage.totalTokens = (usage.promptTokens ?? 0) + out
                return [.usage(usage)]
            }
            return []
        case "message_stop":
            finished = true
            return [.finish(reason: "stop")]
        case "error":
            return [.failed(root["error"]?["message"]?.stringValue ?? "Anthropic 请求失败")]
        default:
            return []
        }
    }

    mutating func finish() -> [StreamEvent] { finished ? [] : [.finish(reason: nil)] }
}
