import Foundation

/// 把本地会话组装成请求（对应安卓 ChatViewModel.send 中的上下文组装 + SystemPromptComposer）。
/// P3 范围：角色系统提示词（变量替换）+ 会话覆盖提示词 + 全部历史；P4 再接记忆/技能/压缩检查点。
public enum ContextBuilder {
    public struct Options: Sendable {
        public var username: String
        public var includeImages: Bool
        /// 单条附件文字上限（字符）。
        public var maxAttachmentChars: Int
        /// 当前模型：只有同一模型产生的工具轮次原生历史才原样回放（签名/思考块跨模型无效）。
        public var replayModelId: String?
        /// 图片改用 `[图片#N]` 文字占位（当前模型不支持视觉、交给 view_image 外挂视觉时）。
        public var imagesAsPlaceholders: Bool

        public init(username: String = "用户", includeImages: Bool = true, maxAttachmentChars: Int = 60_000,
                    replayModelId: String? = nil, imagesAsPlaceholders: Bool = false) {
            self.username = username; self.includeImages = includeImages; self.maxAttachmentChars = maxAttachmentChars
            self.replayModelId = replayModelId; self.imagesAsPlaceholders = imagesAsPlaceholders
        }
    }

    /// 读取附件字节的回调（App 层从沙盒读取）。
    public typealias AttachmentLoader = @Sendable (Attachment) -> Data?

    public static func systemPrompt(persona: Persona?, conversation: Conversation, provider: ByokProvider,
                                    model: ProviderModel, options: Options) -> String? {
        var parts: [String] = []
        let base = persona?.systemPrompt.nonBlank
        let override = conversation.systemPrompt?.nonBlank
        if let override { parts.append(override) } else if let base { parts.append(base) }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\n\n")
        return PromptVariables.apply(joined, username: options.username, model: model.displayName, provider: provider.name)
    }

    /// 历史 → WireMessage。跳过 system / 错误 / 空消息；失败的助手回答不回放。
    public static func wireMessages(_ history: [ChatMessage], options: Options, loader: AttachmentLoader) -> [WireMessage] {
        var out: [WireMessage] = []
        var imageCounter = 0
        for m in history {
            switch m.role {
            case .system, .tool: continue
            case .assistant:
                guard m.status != .error || !m.text.isEmpty else { continue }
                let text = m.text
                if text.isEmpty { continue }
                let reasoning = m.thinkingText.nonBlank
                if let h = WireHistory.decode(m.metadata[WireHistory.metadataKey]), !h.items.isEmpty,
                   h.modelId == nil || h.modelId == options.replayModelId,
                   let t = ByokProviderType(rawValue: h.providerType) {
                    out.append(WireMessage(role: .assistant, parts: [.text(text)], reasoning: reasoning, native: h.items, nativeType: t))
                } else {
                    out.append(WireMessage(role: .assistant, parts: [.text(text)], reasoning: reasoning))
                }
            case .user:
                var parts: [WireMessage.Part] = []
                var docs: [String] = []
                for a in m.attachments {
                    if a.isImage { imageCounter += 1 }
                    if a.isImage && options.imagesAsPlaceholders {
                        docs.append("[图片#\(imageCounter)]")
                        continue
                    }
                    if a.unavailable { continue }
                    if a.isImage {
                        guard options.includeImages else { continue }
                        if let url = a.remoteUrl, a.localPath == nil {
                            parts.append(.image(mimeType: a.mimeType, base64: nil, url: url))
                        } else if let data = loader(a) {
                            parts.append(.image(mimeType: a.mimeType, base64: data.base64EncodedString(), url: nil))
                        }
                    } else if let text = a.extractedText?.nonBlank {
                        let clipped = text.count > options.maxAttachmentChars ? String(text.prefix(options.maxAttachmentChars)) + "\n…（已截断）" : text
                        docs.append("<file name=\"\(a.name)\">\n\(clipped)\n</file>")
                    }
                }
                var body = m.text
                if !docs.isEmpty { body = docs.joined(separator: "\n\n") + (body.isEmpty ? "" : "\n\n" + body) }
                parts.insert(.text(body.isEmpty ? " " : body), at: 0)
                out.append(WireMessage(role: .user, parts: parts))
            }
        }
        // 多数服务要求 user/assistant 交替：合并连续同角色消息。
        var merged: [WireMessage] = []
        for m in out {
            if var last = merged.last, last.role == m.role, last.native == nil, m.native == nil {
                last.parts.append(contentsOf: m.parts)
                merged[merged.count - 1] = last
            } else {
                merged.append(m)
            }
        }
        return merged
    }
}

/// 把 StreamEvent 累积成助手消息的 fragments（对应安卓 ChatRepository.streamAssistant 的片段合并逻辑）。
public struct StreamAccumulator: Sendable {
    public private(set) var fragments: [MessageFragment] = []
    public private(set) var usage = Usage()
    public private(set) var finishReason: String?
    public private(set) var error: String?
    /// 工具轮次的原生协议历史（无工具调用时为 nil）。
    public private(set) var wireHistory: WireHistory?
    public let startedAt: Date
    public private(set) var firstTokenAt: Date?
    private var thinkingStartedAt: Date?

    public init(startedAt: Date = Date()) { self.startedAt = startedAt }

    public var hasContent: Bool {
        fragments.contains {
            switch $0 {
            case .text(_, let t): return !t.isEmpty
            case .thinking(_, let t, _, _): return !t.isEmpty
            case .image, .tool: return true
            default: return false
            }
        }
    }

    public mutating func apply(_ event: StreamEvent, now: Date = Date()) {
        switch event {
        case .delta(let text, let thinking):
            if let thinking, !thinking.isEmpty {
                markFirstToken(now)
                appendThinking(thinking, now: now)
            }
            if let text, !text.isEmpty {
                markFirstToken(now)
                closeThinking(now: now)
                appendText(text)
            }
        case .usage(let u):
            usage = usage.merged(with: u)
        case .tool(let t):
            closeThinking(now: now)
            if let i = fragments.firstIndex(where: { $0.id == t.id }) { fragments[i] = .tool(t) } else { fragments.append(.tool(t)) }
        case .image(let url):
            markFirstToken(now)
            closeThinking(now: now)
            fragments.append(.image(id: IDs.fragment(), url: url, prompt: nil, width: nil, height: nil))
        case .sources(let refs, let query):
            if let i = fragments.firstIndex(where: { if case .search = $0 { return true }; return false }) {
                fragments[i] = .search(id: fragments[i].id, query: query, refs: refs, status: .done)
            } else {
                fragments.append(.search(id: IDs.fragment(), query: query, refs: refs, status: .done))
            }
        case .wireHistory(let h):
            wireHistory = h
        case .finish(let reason):
            closeThinking(now: now)
            finishReason = reason ?? finishReason ?? "stop"
        case .failed(let msg):
            closeThinking(now: now)
            error = msg
        }
    }

    /// 结束时的耗时统计。
    public func stats(pricing: ModelPricing?, modelId: String, now: Date = Date()) -> MessageStats {
        let duration = Int64(now.timeIntervalSince(startedAt) * 1000)
        let ttft = firstTokenAt.map { Int64($0.timeIntervalSince(startedAt) * 1000) }
        var u = usage
        if u.totalTokens == nil, let p = u.promptTokens, let c = u.completionTokens { u.totalTokens = p + c }
        let cost = pricing?.cost(u)
        return MessageStats(usage: u, durationMs: duration, ttftMs: ttft, costUsd: cost,
                            costModel: modelId, pricingMissing: pricing == nil)
    }

    /// 把错误作为片段追加（保留已生成内容）。
    public mutating func appendError(_ message: String) {
        error = message
        fragments.append(.error(id: IDs.fragment(), message: message))
    }

    private mutating func markFirstToken(_ now: Date) { if firstTokenAt == nil { firstTokenAt = now } }

    private mutating func appendText(_ s: String) {
        if case .text(let id, let md)? = fragments.last {
            fragments[fragments.count - 1] = .text(id: id, markdown: md + s)
        } else {
            fragments.append(.text(id: IDs.fragment(), markdown: s))
        }
    }

    private mutating func appendThinking(_ s: String, now: Date) {
        if case .thinking(let id, let t, let c, nil)? = fragments.last {
            fragments[fragments.count - 1] = .thinking(id: id, text: t + s, collapsed: c, durationMs: nil)
        } else {
            thinkingStartedAt = now
            fragments.append(.thinking(id: IDs.fragment(), text: s, collapsed: true, durationMs: nil))
        }
    }

    private mutating func closeThinking(now: Date) {
        guard let start = thinkingStartedAt else { return }
        for i in fragments.indices.reversed() {
            if case .thinking(let id, let t, let c, nil) = fragments[i] {
                fragments[i] = .thinking(id: id, text: t, collapsed: c, durationMs: Int64(now.timeIntervalSince(start) * 1000))
                break
            }
        }
        thinkingStartedAt = nil
    }
}
