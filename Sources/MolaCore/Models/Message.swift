import Foundation

// 对应安卓 core/model：ChatMessage.kt / MessageFragment.kt / FileInfo.kt / SourceReference.kt
// JSON 结构（type 判别字段、字段名）与安卓一致，以便将来导入导出与云同步。

public enum Role: String, Codable, Sendable, Hashable {
    case user = "USER", assistant = "ASSISTANT", system = "SYSTEM", tool = "TOOL"
}

public enum MessageStatus: String, Codable, Sendable, Hashable {
    case pending = "PENDING", streaming = "STREAMING", complete = "COMPLETE", stopped = "STOPPED", error = "ERROR"
}

public enum ToolStatus: String, Codable, Sendable, Hashable {
    case running = "RUNNING", success = "SUCCESS", failed = "FAILED", cancelled = "CANCELLED"
}

public enum SearchStatus: String, Codable, Sendable, Hashable {
    case searching = "SEARCHING", done = "DONE", failed = "FAILED"
}

public struct SourceReference: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String?
    public var index: Int?
    public var faviconUrl: String?

    public init(title: String, url: String, snippet: String? = nil, index: Int? = nil, faviconUrl: String? = nil) {
        self.title = title; self.url = url; self.snippet = snippet; self.index = index; self.faviconUrl = faviconUrl
    }

    public var site: String { URL(string: url)?.host ?? url }
}

public struct FileInfo: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var mimeType: String?
    public var sizeBytes: Int64?
    public var url: String?
    public var localPath: String?

    public init(id: String, name: String, mimeType: String? = nil, sizeBytes: Int64? = nil, url: String? = nil, localPath: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.sizeBytes = sizeBytes; self.url = url; self.localPath = localPath
    }
}

/// 消息附件。`localPath` 为 App 沙盒 Documents/attachments 下的相对路径。
public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var localPath: String?
    public var remoteUrl: String?
    public var sizeBytes: Int64?
    /// 文档类附件在本机抽取出的文字（PDF/Word/文本），发送时拼入用户消息。
    public var extractedText: String?
    public var unavailable: Bool

    public init(id: String = IDs.generic("att"), name: String, mimeType: String, localPath: String? = nil,
                remoteUrl: String? = nil, sizeBytes: Int64? = nil, extractedText: String? = nil, unavailable: Bool = false) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.localPath = localPath
        self.remoteUrl = remoteUrl; self.sizeBytes = sizeBytes; self.extractedText = extractedText; self.unavailable = unavailable
    }

    public var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

/// 单条消息的内容片段。流式期间同一片段 id 保持不变，SwiftUI 以 id 做 diff。
public enum MessageFragment: Sendable, Hashable, Identifiable {
    case text(id: String, markdown: String)
    case thinking(id: String, text: String, collapsed: Bool, durationMs: Int64?)
    case code(id: String, language: String?, code: String)
    case latex(id: String, expr: String, display: Bool)
    case mermaid(id: String, source: String)
    case search(id: String, query: String, refs: [SourceReference], status: SearchStatus)
    case tool(ToolCallFragment)
    case file(id: String, file: FileInfo)
    case image(id: String, url: String, prompt: String?, width: Int?, height: Int?)
    case tip(id: String, text: String)
    case error(id: String, message: String)

    public var id: String {
        switch self {
        case .text(let id, _), .thinking(let id, _, _, _), .code(let id, _, _), .latex(let id, _, _),
             .mermaid(let id, _), .search(let id, _, _, _), .file(let id, _), .image(let id, _, _, _, _),
             .tip(let id, _), .error(let id, _):
            return id
        case .tool(let t): return t.id
        }
    }

    /// 片段的纯文本（复制、搜索、标题生成、上下文回放用）。
    public var plainText: String {
        switch self {
        case .text(_, let md): return md
        case .code(_, let lang, let code): return "```\(lang ?? "")\n\(code)\n```"
        case .latex(_, let expr, let display): return display ? "$$\(expr)$$" : "$\(expr)$"
        case .mermaid(_, let src): return "```mermaid\n\(src)\n```"
        case .tip(_, let t): return t
        default: return ""
        }
    }
}

public struct ToolCallFragment: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var status: ToolStatus
    public var label: String?
    public var argsJson: String?
    public var resultPreview: String?
    public var provider: String?
    public var statusLabel: String?

    public init(id: String, name: String, status: ToolStatus, label: String? = nil, argsJson: String? = nil,
                resultPreview: String? = nil, provider: String? = nil, statusLabel: String? = nil) {
        self.id = id; self.name = name; self.status = status; self.label = label; self.argsJson = argsJson
        self.resultPreview = resultPreview; self.provider = provider; self.statusLabel = statusLabel
    }
}

extension MessageFragment: Codable {
    private enum K: String, CodingKey {
        case type, id, markdown, text, collapsed, durationMs, language, code, expr, display, source
        case query, refs, status, file, url, prompt, width, height, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDs.fragment()
        switch type {
        case "text": self = .text(id: id, markdown: try c.decodeIfPresent(String.self, forKey: .markdown) ?? "")
        case "thinking":
            self = .thinking(id: id, text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                             collapsed: try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? true,
                             durationMs: try c.decodeIfPresent(Int64.self, forKey: .durationMs))
        case "code":
            self = .code(id: id, language: try c.decodeIfPresent(String.self, forKey: .language),
                         code: try c.decodeIfPresent(String.self, forKey: .code) ?? "")
        case "latex":
            self = .latex(id: id, expr: try c.decodeIfPresent(String.self, forKey: .expr) ?? "",
                          display: try c.decodeIfPresent(Bool.self, forKey: .display) ?? true)
        case "mermaid": self = .mermaid(id: id, source: try c.decodeIfPresent(String.self, forKey: .source) ?? "")
        case "search":
            self = .search(id: id, query: try c.decodeIfPresent(String.self, forKey: .query) ?? "",
                           refs: try c.decodeIfPresent([SourceReference].self, forKey: .refs) ?? [],
                           status: try c.decodeIfPresent(SearchStatus.self, forKey: .status) ?? .done)
        case "tool": self = .tool(try ToolCallFragment(from: decoder))
        case "file": self = .file(id: id, file: try c.decode(FileInfo.self, forKey: .file))
        case "image":
            self = .image(id: id, url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
                          prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
                          width: try c.decodeIfPresent(Int.self, forKey: .width),
                          height: try c.decodeIfPresent(Int.self, forKey: .height))
        case "tip": self = .tip(id: id, text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "error": self = .error(id: id, message: try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        default: self = .tip(id: id, text: "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .text(let id, let md):
            try c.encode("text", forKey: .type); try c.encode(id, forKey: .id); try c.encode(md, forKey: .markdown)
        case .thinking(let id, let text, let collapsed, let dur):
            try c.encode("thinking", forKey: .type); try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
            try c.encode(collapsed, forKey: .collapsed); try c.encodeIfPresent(dur, forKey: .durationMs)
        case .code(let id, let lang, let code):
            try c.encode("code", forKey: .type); try c.encode(id, forKey: .id)
            try c.encodeIfPresent(lang, forKey: .language); try c.encode(code, forKey: .code)
        case .latex(let id, let expr, let display):
            try c.encode("latex", forKey: .type); try c.encode(id, forKey: .id)
            try c.encode(expr, forKey: .expr); try c.encode(display, forKey: .display)
        case .mermaid(let id, let src):
            try c.encode("mermaid", forKey: .type); try c.encode(id, forKey: .id); try c.encode(src, forKey: .source)
        case .search(let id, let q, let refs, let st):
            try c.encode("search", forKey: .type); try c.encode(id, forKey: .id); try c.encode(q, forKey: .query)
            try c.encode(refs, forKey: .refs); try c.encode(st, forKey: .status)
        case .tool(let t):
            try t.encode(to: encoder)
            try c.encode("tool", forKey: .type)
        case .file(let id, let f):
            try c.encode("file", forKey: .type); try c.encode(id, forKey: .id); try c.encode(f, forKey: .file)
        case .image(let id, let url, let prompt, let w, let h):
            try c.encode("image", forKey: .type); try c.encode(id, forKey: .id); try c.encode(url, forKey: .url)
            try c.encodeIfPresent(prompt, forKey: .prompt); try c.encodeIfPresent(w, forKey: .width); try c.encodeIfPresent(h, forKey: .height)
        case .tip(let id, let t):
            try c.encode("tip", forKey: .type); try c.encode(id, forKey: .id); try c.encode(t, forKey: .text)
        case .error(let id, let m):
            try c.encode("error", forKey: .type); try c.encode(id, forKey: .id); try c.encode(m, forKey: .message)
        }
    }
}

/// 流式返回或本地估算的用量。
public struct Usage: Codable, Sendable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var reasoningTokens: Int?
    public var cachedTokens: Int?
    public var cacheWriteTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil,
                reasoningTokens: Int? = nil, cachedTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens; self.cachedTokens = cachedTokens; self.cacheWriteTokens = cacheWriteTokens
    }

    /// 合并：后到的非空字段覆盖先到的（各家 usage 可能分多帧下发）。
    public func merged(with other: Usage) -> Usage {
        Usage(promptTokens: other.promptTokens ?? promptTokens,
              completionTokens: other.completionTokens ?? completionTokens,
              totalTokens: other.totalTokens ?? totalTokens,
              reasoningTokens: other.reasoningTokens ?? reasoningTokens,
              cachedTokens: other.cachedTokens ?? cachedTokens,
              cacheWriteTokens: other.cacheWriteTokens ?? cacheWriteTokens)
    }
}

/// 每条助手回答的统计（Token、首字延迟、耗时、花费）。
public struct MessageStats: Codable, Sendable, Hashable {
    public var usage: Usage
    public var durationMs: Int64?
    public var ttftMs: Int64?
    public var costUsd: Double?
    public var costModel: String?
    public var pricingMissing: Bool

    public init(usage: Usage = Usage(), durationMs: Int64? = nil, ttftMs: Int64? = nil, costUsd: Double? = nil,
                costModel: String? = nil, pricingMissing: Bool = false) {
        self.usage = usage; self.durationMs = durationMs; self.ttftMs = ttftMs; self.costUsd = costUsd
        self.costModel = costModel; self.pricingMissing = pricingMissing
    }

    /// 输出速度（token/s），按首字后的生成时间计算。
    public var tokensPerSecond: Double? {
        guard let out = usage.completionTokens, out > 0, let d = durationMs else { return nil }
        let gen = Double(d - (ttftMs ?? 0)) / 1000
        return gen > 0.05 ? Double(out) / gen : nil
    }
}

/// 重新生成的一个历史版本（完整快照）。
public struct RetryAttempt: Codable, Sendable, Hashable {
    public var fragments: [MessageFragment]
    public var model: String?
    public var status: MessageStatus
    public var stats: MessageStats?
    public var createdAt: Int64

    public init(fragments: [MessageFragment], model: String?, status: MessageStatus, stats: MessageStats?, createdAt: Int64) {
        self.fragments = fragments; self.model = model; self.status = status; self.stats = stats; self.createdAt = createdAt
    }
}

/// 编辑分支的一个版本：从该用户消息开始的整段尾部时间线。
public struct EditSnapshot: Codable, Sendable, Hashable {
    public var timestamp: Int64
    public var label: String
    public var conversationHistory: [ChatMessage]

    public init(timestamp: Int64 = IDs.nowMs(), label: String, conversationHistory: [ChatMessage]) {
        self.timestamp = timestamp; self.label = label; self.conversationHistory = conversationHistory
    }
}

/// 用户消息上的编辑分支：`versions` 含全部版本（当前显示版本的槽位在离开时刷新），`currentIndex` 为显示中的版本。
/// （与安卓 editSnapshots 的 `-1 = 最新` 约定不同：iOS 统一为「全量版本 + 下标」，便于导航。）
public struct EditBranches: Codable, Sendable, Hashable {
    public var currentIndex: Int
    public var versions: [EditSnapshot]

    public init(currentIndex: Int = 0, versions: [EditSnapshot] = []) {
        self.currentIndex = currentIndex; self.versions = versions
    }

    public var count: Int { versions.count }
    /// 1-based 当前位置。
    public var position: Int { currentIndex + 1 }
}

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    public var messageId: String
    public var sessionId: String
    public var role: Role
    public var status: MessageStatus
    public var createdAt: Int64
    public var updatedAt: Int64
    public var fragments: [MessageFragment]
    public var model: String?
    public var attachments: [Attachment]
    public var stats: MessageStats?
    /// 助手消息：重新生成的全部版本（当前显示版本的槽位在离开/再生成时刷新）+ 当前下标。空 = 只有一个版本。
    public var retryAttempts: [RetryAttempt]
    public var retryCurrent: Int
    /// 用户消息：编辑分支（嵌套 ChatMessage，故用 indirect 包装）。
    public var editBranches: Box<EditBranches>?
    /// 其余扩展字段（与安卓 metadata 对应）。
    public var metadata: [String: String]

    public var id: String { messageId }

    public init(messageId: String = IDs.message(), sessionId: String, role: Role, status: MessageStatus = .complete,
                createdAt: Int64 = IDs.nowMs(), updatedAt: Int64? = nil, fragments: [MessageFragment] = [],
                model: String? = nil, attachments: [Attachment] = [], stats: MessageStats? = nil,
                retryAttempts: [RetryAttempt] = [], retryCurrent: Int = 0, editBranches: EditBranches? = nil,
                metadata: [String: String] = [:]) {
        self.messageId = messageId; self.sessionId = sessionId; self.role = role; self.status = status
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.fragments = fragments
        self.model = model; self.attachments = attachments; self.stats = stats
        self.retryAttempts = retryAttempts; self.retryCurrent = retryCurrent
        self.editBranches = editBranches.map(Box.init); self.metadata = metadata
    }

    /// 正文（不含思考），用于复制、上下文回放。
    public var text: String {
        fragments.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var thinkingText: String {
        fragments.compactMap { if case .thinking(_, let t, _, _) = $0 { return t }; return nil }.joined(separator: "\n")
    }

    /// 版本总数（重新生成）。
    public var versionCount: Int { max(retryAttempts.count, 1) }

    /// 当前内容的快照（用于存入版本槽位）。
    public var asRetryAttempt: RetryAttempt {
        RetryAttempt(fragments: fragments, model: model, status: status, stats: stats, createdAt: updatedAt)
    }

    public var branchCount: Int { editBranches?.value.count ?? 1 }
}

/// 引用盒，用于打断值类型递归（ChatMessage → EditBranches → ChatMessage）。
public final class Box<T: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public let value: T
    public init(_ value: T) { self.value = value }
    public required init(from decoder: Decoder) throws { value = try T(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    public static func == (l: Box<T>, r: Box<T>) -> Bool { l.value == r.value }
    public func hash(into h: inout Hasher) { h.combine(value) }
}
