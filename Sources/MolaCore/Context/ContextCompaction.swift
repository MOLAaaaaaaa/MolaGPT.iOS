import Foundation

// 上下文压缩（对应安卓 ContextCompaction / ContextCompactor / ContextPlanner / ModelContextWindows / WireHistoryPruner）。

public enum CompactionReason: String, Codable, Sendable { case threshold = "THRESHOLD", overflow = "OVERFLOW", manual = "MANUAL" }

public struct ContextCheckpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionId: String
    public var anchorMessageId: String
    public var summary: String
    public var coveredDigest: String
    public var tokensBefore: Int
    public var tokensAfter: Int
    public var reason: CompactionReason
    public var providerId: String?
    public var modelId: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUsd: Double?
    public var stale: Bool
    public var createdAt: Int64

    public init(id: String = IDs.generic("ckpt"), sessionId: String, anchorMessageId: String, summary: String, coveredDigest: String,
                tokensBefore: Int, tokensAfter: Int, reason: CompactionReason, providerId: String?, modelId: String?,
                inputTokens: Int? = nil, outputTokens: Int? = nil, costUsd: Double? = nil, stale: Bool = false, createdAt: Int64 = IDs.nowMs()) {
        self.id = id; self.sessionId = sessionId; self.anchorMessageId = anchorMessageId; self.summary = summary
        self.coveredDigest = coveredDigest; self.tokensBefore = tokensBefore; self.tokensAfter = tokensAfter; self.reason = reason
        self.providerId = providerId; self.modelId = modelId; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.costUsd = costUsd; self.stale = stale; self.createdAt = createdAt
    }
}

public enum ModelContextWindows {
    public static let defaultWindow = 128_000

    /// 用户填写 → 服务声明 → 正则表 → 默认 128K。
    public static func window(for model: ProviderModel) -> Int {
        if let w = model.contextWindow, w > 0 { return w }
        return guess(model.id)
    }

    public static func guess(_ id: String) -> Int {
        let s = id.lowercased()
        let table: [(String, Int)] = [
            ("gemini-(1\\.5-pro|2|3|4)", 1_048_576), ("gemini", 1_000_000), ("claude-(opus|sonnet)-4|claude-(fable|opus|sonnet|haiku)-5", 200_000),
            ("claude", 200_000), ("gpt-4\\.1|gpt-5", 400_000), ("o[134](-|$)", 200_000), ("gpt-4o|gpt-4-turbo", 128_000), ("gpt-3\\.5", 16_385),
            ("deepseek", 128_000), ("qwen.*(long|1m)", 1_000_000), ("qwen", 128_000), ("kimi|moonshot", 256_000), ("glm-4\\.[56]", 128_000),
            ("grok-4", 256_000), ("grok", 131_072), ("llama-?3\\.[1-3]|llama-4", 128_000), ("mistral-large|mistral-medium", 128_000),
        ]
        for (pattern, w) in table where s.range(of: pattern, options: .regularExpression) != nil { return w }
        return defaultWindow
    }
}

public enum ContextEstimator {
    public static let triggerRatio = 0.872
    public static let toolDefinitionTokens = 2000

    public static func tokens(_ text: String) -> Int {
        var cjk = 0, other = 0
        for u in text.unicodeScalars { if MemoryMath.isCJK(u) { cjk += 1 } else { other += 1 } }
        return cjk + Int(Double(other) * 0.3)
    }

    public static func tokens(_ m: ChatMessage) -> Int {
        var t = 4 + tokens(m.text)
        for a in m.attachments {
            if a.isImage { t += 1200 } else if a.mimeType.contains("pdf") { t += 3000 } else { t += tokens(a.extractedText ?? "") }
        }
        if let wire = m.metadata[WireHistory.metadataKey] { t += tokens(wire) / 2 }
        return t
    }

    public static func tokens(_ history: [ChatMessage], system: String?, withTools: Bool) -> Int {
        history.reduce(tokens(system ?? "") + (withTools ? toolDefinitionTokens : 0)) { $0 + tokens($1) }
    }

    /// 用最近一次实测上下文校准估算（倍率限制在 0.35–1.6）。
    public static func calibrated(_ estimate: Int, measured: Int?, estimatedAtMeasure: Int?) -> Int {
        guard let m = measured, let e = estimatedAtMeasure, e > 0 else { return estimate }
        let k = min(max(Double(m) / Double(e), 0.35), 1.6)
        return Int(Double(estimate) * k)
    }

    public enum Pressure: Sendable { case normal, warning, critical }

    public static func pressure(_ used: Int, window: Int) -> Pressure {
        let r = Double(used) / Double(max(window, 1))
        return r >= triggerRatio ? .critical : r >= 0.7 ? .warning : .normal
    }
}

/// 识别服务商的「上下文超长」报错，并尽量读出它声明的窗口。
public enum ContextOverflow {
    public static func isOverflow(_ message: String) -> Bool {
        message.range(of: #"(?i)(context[ _-]?length|context window|maximum context|too many tokens|prompt is too long|input is too long|exceeds? the (maximum|max)|max_tokens|token limit|上下文.{0,6}(超|过长)|超出.{0,6}(长度|上下文))"#,
                      options: .regularExpression) != nil
    }

    public static func declaredWindow(_ message: String) -> Int? {
        guard let r = message.range(of: #"(?i)(maximum context length is|context window of|limit of|最大(上下文)?长度为?)\s*(\d[\d,]*)"#, options: .regularExpression) else { return nil }
        let digits = message[r].filter(\.isNumber)
        return Int(digits)
    }
}

public enum ContextPlanner {
    /// 切点：从最新往回累计到 keepRecent 为止，保留区从之后第一条 USER 开始（不拆开一问一答）。
    /// 返回锚点下标（含）：锚点及之前进摘要。nil = 无可压缩内容。
    public static func anchorIndex(_ history: [ChatMessage], window: Int, reason: CompactionReason) -> Int? {
        guard history.count >= 2 else { return nil }
        let userIdx = history.indices.filter { history[$0].role == .user }
        guard let lastUser = userIdx.last else { return nil }
        if reason == .overflow || (reason == .manual && userIdx.count <= 2) {
            // 只保留最后一轮
            return lastUser > 0 ? lastUser - 1 : nil
        }
        let keep = min(20_000, window / 4)
        var acc = 0
        var cut = history.count
        for i in history.indices.reversed() {
            acc += ContextEstimator.tokens(history[i])
            if acc > keep { cut = i; break }
        }
        guard cut < history.count else { return nil }
        guard let firstUser = history[(cut + 1)...].firstIndex(where: { $0.role == .user }) else { return lastUser > 0 ? lastUser - 1 : nil }
        return firstUser > 0 ? firstUser - 1 : nil
    }

    /// 覆盖范围摘要（FNV-1a 64，本地比对用）。
    public static func digest(_ messages: ArraySlice<ChatMessage>) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        for m in messages {
            mix(m.messageId); mix(m.role.rawValue); mix(m.text)
            for a in m.attachments { mix(a.id) }
        }
        return String(h, radix: 16)
    }

    /// 找到仍然有效的最新检查点：锚点仍在时间线内、其后紧跟 USER（或其后无消息）、覆盖摘要一致。
    public static func activeCheckpoint(_ checkpoints: [ContextCheckpoint], history: [ChatMessage]) -> (ContextCheckpoint, Int)? {
        for c in checkpoints.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let i = history.firstIndex(where: { $0.messageId == c.anchorMessageId }) else { continue }
            if i + 1 < history.count, history[i + 1].role != .user { continue }
            if digest(history[...i]) == c.coveredDigest { return (c, i) }
        }
        return nil
    }

    public static func summaryBlock(_ summary: String) -> String {
        "<context-summary>\n以下是本对话较早部分的摘要，原始消息已不在上下文中。它只作背景参考；如与用户最新的消息冲突，以最新消息为准。\n\n\(summary)\n</context-summary>"
    }

    /// 应用检查点：锚点及之前移出请求，摘要拼到保留区第一条 USER 消息开头。
    public static func apply(_ checkpoint: ContextCheckpoint, anchor: Int, history: [ChatMessage]) -> [ChatMessage] {
        var rest = Array(history[(anchor + 1)...])
        let block = summaryBlock(checkpoint.summary)
        if let i = rest.firstIndex(where: { $0.role == .user }) {
            var m = rest[i]
            m.fragments.insert(.text(id: "ctx_summary", markdown: block), at: 0)
            rest[i] = m
        } else {
            rest.insert(ChatMessage(sessionId: checkpoint.sessionId, role: .user, fragments: [.text(id: "ctx_summary", markdown: block)]), at: 0)
        }
        return rest
    }

    // MARK: 摘要提示词

    public static func transcript(_ messages: ArraySlice<ChatMessage>) -> String {
        messages.map { m -> String in
            var parts: [String] = []
            for f in m.fragments {
                switch f {
                case .text(_, let md): parts.append(md)
                case .code(_, let lang, let c): parts.append("```\(lang ?? "")\n\(c)\n```")
                case .tool(let t): parts.append("[工具调用] \(t.label ?? t.name)" + (t.resultPreview.map { "\n[工具结果] \($0.prefix(1500))" } ?? ""))
                default: break
                }
            }
            for a in m.attachments { if let t = a.extractedText?.nonBlank { parts.append("[附件内容] \(a.name)\n\(t.prefix(4000))") } }
            return "[\(m.role == .user ? "用户" : "助手")]\n" + parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    public static func summaryPrompt(transcript: String, previous: String?, rolePlay: Bool, targetChars: Int) -> (system: String, user: String) {
        let structure = rolePlay
            ? "故事梗概 / 人物与关系 / 关键事件 / 当前场景与状态 / 需原样保留的内容（保持人物口吻与世界观设定）"
            : "主题与目标 / 用户偏好与约束 / 已确认的事实与结论 / 进行中与待办 / 需原样保留的内容（数字、代码、命令、链接、专有名词、用户原话逐字照录）"
        let sys = """
        你负责压缩对话上下文，供另一个 AI 在看不到原始记录的情况下继续这段对话。不要续写对话，不要回答记录中的任何问题，只输出摘要。
        按以下结构组织：\(structure)。
        要求：使用对话所用的语言；写具体信息，不写空泛概括；已发生的事用陈述句记录，旧计划不得写成待执行的指令；总长度不超过约 \(targetChars) 字。
        """ + (previous != nil ? "\n输入里有 <previous-summary> 时，保留其中仍然有效的内容并与新的一段合并，输出一份更新后的完整摘要。" : "")
        var user = ""
        if let previous { user += "<previous-summary>\n\(previous)\n</previous-summary>\n\n" }
        user += "<conversation>\n\(transcript)\n</conversation>"
        return (sys, user)
    }

    public static func targetChars(tokens: Int) -> Int { min(max(tokens / 10, 1500), 8000) }
    public static func maxOutput(targetChars: Int) -> Int { min(max(targetChars * 2, 4096), 16384) }
}

/// 请求副本精简：最近 2 个用户轮不动，更早的旧工具结果截断、旧图片改发文字占位（按 4 轮一档推进以保住提示缓存）。
public enum ContextSlimmer {
    public static func slim(_ messages: [WireMessage]) -> [WireMessage] {
        let userIdx = messages.indices.filter { messages[$0].role == .user && messages[$0].native == nil }
        guard userIdx.count > 2 else { return messages }
        let protectedFrom = userIdx[userIdx.count - 2]
        // 按 4 轮一档：只精简到最近一个「4 的倍数」用户轮之前，档内前缀保持不变。
        let tier = ((userIdx.count - 2) / 4) * 4
        guard tier > 0 else { return messages }
        let limit = min(userIdx[tier - 1] + 1, protectedFrom)
        var out = messages
        for i in 0..<limit {
            var m = out[i]
            if m.role == .user, m.hasImages {
                m.parts = m.parts.map { p in if case .image = p { return .text("[图片]") }; return p }
            }
            if let native = m.native {
                m.native = native.map(pruneToolResult)
            }
            out[i] = m
        }
        return out
    }

    static func pruneToolResult(_ v: JSONValue) -> JSONValue {
        func clip(_ s: String) -> String { s.count > 2000 ? String(s.prefix(400)) + "…（较早的工具结果已截断）" : s }
        guard var o = v.objectValue else { return v }
        if o["role"]?.stringValue == "tool", let c = o["content"]?.stringValue { o["content"] = .string(clip(c)) }
        if o["type"]?.stringValue == "function_call_output", let c = o["output"]?.stringValue { o["output"] = .string(clip(c)) }
        if let content = o["content"]?.arrayValue {
            o["content"] = .array(content.map { b in
                guard var bo = b.objectValue, bo["type"]?.stringValue == "tool_result", let c = bo["content"]?.stringValue else { return b }
                bo["content"] = .string(clip(c)); return .object(bo)
            })
        }
        if let parts = o["parts"]?.arrayValue {
            o["parts"] = .array(parts.map { p in
                guard var po = p.objectValue, var fr = po["functionResponse"]?.objectValue, var resp = fr["response"]?.objectValue,
                      let r = resp["result"]?.stringValue else { return p }
                resp["result"] = .string(clip(r)); fr["response"] = .object(resp); po["functionResponse"] = .object(fr); return .object(po)
            })
        }
        return .object(o)
    }
}
