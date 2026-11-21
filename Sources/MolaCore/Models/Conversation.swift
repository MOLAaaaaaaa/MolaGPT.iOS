import Foundation

// 对应安卓 Conversation.kt / Persona.kt

public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public var sessionId: String
    public var title: String
    public var model: String?
    public var providerId: String?
    public var providerKind: ProviderKind
    public var createdAt: Int64
    public var updatedAt: Int64
    public var pinned: Bool
    public var lastMessagePreview: String?
    public var personaId: String?
    public var systemPrompt: String?
    public var messageCount: Int

    public var id: String { sessionId }

    public init(sessionId: String = IDs.session(), title: String = Conversation.defaultTitle, model: String? = nil,
                providerId: String? = nil, providerKind: ProviderKind = .byok, createdAt: Int64 = IDs.nowMs(),
                updatedAt: Int64? = nil, pinned: Bool = false, lastMessagePreview: String? = nil,
                personaId: String? = nil, systemPrompt: String? = nil, messageCount: Int = 0) {
        self.sessionId = sessionId; self.title = title; self.model = model; self.providerId = providerId
        self.providerKind = providerKind; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.pinned = pinned; self.lastMessagePreview = lastMessagePreview; self.personaId = personaId
        self.systemPrompt = systemPrompt; self.messageCount = messageCount
    }

    public static let defaultTitle = "新对话"

    public var modelKey: ModelKey? {
        guard let providerId, let model else { return nil }
        return ModelKey(providerId: providerId, modelId: model)
    }
}

public struct Persona: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var icon: String?
    public var systemPrompt: String
    public var defaultEnableThinking: Bool?
    public var defaultReasoningEffort: String?
    public var sortOrder: Int
    public var pinned: Bool
    public var isBuiltin: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    /// SillyTavern 角色卡等扩展资料（PersonaProfile JSON）。
    public var profileJson: String?
    /// 头像：相对 Documents/persona_avatars 的文件名。
    public var avatarPath: String?

    public init(id: String = IDs.generic("persona"), name: String, icon: String? = nil, systemPrompt: String,
                defaultEnableThinking: Bool? = nil, defaultReasoningEffort: String? = nil, sortOrder: Int = 0,
                pinned: Bool = false, isBuiltin: Bool = false, createdAt: Int64 = IDs.nowMs(), updatedAt: Int64? = nil,
                profileJson: String? = nil, avatarPath: String? = nil) {
        self.avatarPath = avatarPath
        self.id = id; self.name = name; self.icon = icon; self.systemPrompt = systemPrompt
        self.defaultEnableThinking = defaultEnableThinking; self.defaultReasoningEffort = defaultReasoningEffort
        self.sortOrder = sortOrder; self.pinned = pinned; self.isBuiltin = isBuiltin
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.profileJson = profileJson
    }

    public static let builtinDefaultId = "builtin-default"

    /// 与安卓 PersonaRepository.builtinSeeds 一致。
    public static func builtins(now: Int64 = IDs.nowMs()) -> [Persona] {
        [
            Persona(id: builtinDefaultId, name: "通用助手", icon: "assistant", systemPrompt:
                "你是 MolaGPT 的默认助手。请用简洁、准确、友好的中文回答用户。\n\n当前背景：\n- 日期：{{date}}\n- 用户：{{username}}\n- 当前模型：{{model}}\n- 服务商：{{provider}}\n\n如果问题信息不足，先提出必要的澄清问题；如果可以直接解决，就给出清晰可执行的答案。",
                sortOrder: 0, pinned: true, isBuiltin: true, createdAt: now),
            Persona(id: "builtin-writer", name: "写作助手", icon: "write", systemPrompt:
                "你是一位资深的中文写作助手，擅长结构化表达、精准用词与节奏控制。\n\n请遵循以下原则：\n- 主动询问写作目的、读者与篇幅约束；\n- 修改建议给出具体替换文本，不止于评论；\n- 避免空话和套话，倾向用具体例子说明观点；\n- 输出时使用 Markdown，长文加分级标题。",
                sortOrder: 1, isBuiltin: true, createdAt: now),
            Persona(id: "builtin-coder", name: "代码助手", icon: "code", systemPrompt:
                "你是一位经验丰富的软件工程师，回答需具备工程师的严谨与坦诚。\n\n请遵循：\n- 先理解需求与现状，再给方案；如信息不足，先反问；\n- 给代码必给可运行的最小示例，并标注语言；\n- 指出潜在边界条件、错误处理与性能注意点；\n- 拒绝臆造 API；不确定的部分明确标注；\n- 中文回答，但代码、命令、API 名保留英文原文。",
                sortOrder: 2, isBuiltin: true, createdAt: now),
            Persona(id: "builtin-translator", name: "翻译助手", icon: "translate", systemPrompt:
                "你是一位专业译者。除非用户另行指定，默认按以下规则工作：\n- 中译英时追求自然流畅，避免直译腔；\n- 英译中时保留专业术语原文（首次出现给括注），整体行文符合中文表达习惯；\n- 保留原文格式：列表、代码块、链接、Markdown 结构原样保留；\n- 仅输出译文，不解释翻译过程；除非用户要求对比，否则不附原文。",
                sortOrder: 3, isBuiltin: true, createdAt: now),
            Persona(id: "builtin-scholar", name: "严谨学者", icon: "learn", systemPrompt:
                "你是一位治学严谨的研究者，回答应当：\n- 区分事实、推断与个人观点，必要时标注置信度；\n- 对不确定的内容明确说\"我不确定\"，不要编造引用；\n- 引用数据 / 研究时尽量给出年份与作者，但若来源不可考则诚实声明；\n- 鼓励用户基于一手资料独立验证；\n- 回答结构清晰，复杂论点先给结论再展开。",
                sortOrder: 4, isBuiltin: true, createdAt: now),
        ]
    }

    /// SF Symbol 名称。
    public var symbolName: String {
        switch icon {
        case "assistant": return "sparkles"
        case "write": return "pencil.line"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "translate": return "character.bubble"
        case "learn": return "graduationcap"
        default: return "person.crop.circle"
        }
    }
}

/// 系统提示词变量替换：`{{date}}` `{{time}}` `{{username}}` / `{{user}}` `{{model}}` `{{provider}}`。
public enum PromptVariables {
    public static func apply(_ template: String, username: String, model: String, provider: String,
                             now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN"); df.timeZone = timeZone
        df.dateFormat = "yyyy年M月d日 EEEE"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "zh_CN"); tf.timeZone = timeZone; tf.dateFormat = "HH:mm"
        let map: [String: String] = [
            "date": df.string(from: now), "time": tf.string(from: now), "username": username, "user": username,
            "model": model, "provider": provider,
        ]
        var out = template
        for (k, v) in map {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return out
    }
}
