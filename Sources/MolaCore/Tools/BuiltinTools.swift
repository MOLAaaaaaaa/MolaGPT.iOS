import Foundation

/// 本轮实际挂载哪些工具（对应安卓 EnabledTools + ChatViewModel.resolveRequestTools）。
public struct ToolAvailability: Sendable, Hashable {
    public var webSearch = false
    public var webSearchProvider: WebSearchProvider = .duckduckgo
    public var fetchURL = false
    public var viewImage = false
    public var imageGeneration = false
    public var mcp = false
    public var memory = false
    public var recall = false
    public var skills: [String] = []

    public init() {}

    public var any: Bool { webSearch || fetchURL || viewImage || imageGeneration || mcp || memory || recall || !skills.isEmpty }
}

public enum MemorySection: String, CaseIterable, Codable, Sendable {
    case identity = "身份与背景"
    case preferences = "长期偏好与表达风格"
    case projects = "进行中的项目"
    case recent = "近期上下文"
    case prohibitions = "明确的禁止项"

    /// 半衰期（天）；nil = 不衰减。
    public var halfLifeDays: Double? {
        switch self {
        case .identity, .prohibitions: return nil
        case .preferences: return 180
        case .projects: return 60
        case .recent: return 21
        }
    }

    public static func from(_ s: String?) -> MemorySection { MemorySection(rawValue: s ?? "") ?? .recent }
}

public enum MemoryGroup: String, CaseIterable, Codable, Sendable {
    case aboutYou = "关于你", interests = "兴趣与话题", projects = "项目与领域"
}

public enum MemoryProfileKey: String, CaseIterable, Codable, Sendable {
    case preferredName = "preferred_name", occupation, location
    public var label: String {
        switch self { case .preferredName: return "称呼"; case .occupation: return "职业"; case .location: return "所在地" }
    }
}

public enum BuiltinTools {
    public static func specs(_ a: ToolAvailability) -> [ToolSpec] {
        var out: [ToolSpec] = []
        if !a.skills.isEmpty {
            out.append(ToolSpec(name: "read_skill",
                                description: "读取已安装技能的文件。先读 SKILL.md 获取完整说明，再按说明读取引用文件。长文件分页返回，按 next_offset 继续读取。",
                                properties: [("skill", ToolProperty("技能名", enumValues: a.skills)),
                                             ("path", ToolProperty("相对技能根目录的文件路径，默认 SKILL.md")),
                                             ("offset", ToolProperty("起始字符偏移，默认 0", type: .integer))],
                                required: ["skill"]))
        }
        if a.webSearch {
            if a.webSearchProvider == .molagpt {
                out.append(ToolSpec(name: "search_web",
                                    description: "联网搜索最新信息。需要时效性信息、具体事实、数据或来源时使用；一次可并行发出至多 5 条互补的查询。查询词用最可能命中的语言书写，topic 选最贴近的类别。",
                                    properties: [("queries", ToolProperty("搜索查询列表（1-5 条）", type: .array, itemProperties: [
                                        ("query", ToolProperty("搜索词")),
                                        ("topic", ToolProperty("类别", enumValues: ["general", "news", "finance", "paper", "technology"])),
                                        ("time_range", ToolProperty("时间范围", enumValues: ["day", "week", "month", "year"])),
                                        ("country", ToolProperty("小写英文国名，仅 general 生效")),
                                        ("include_images", ToolProperty("是否返回图片", type: .boolean)),
                                    ], itemRequired: ["query", "topic"]))],
                                    required: ["queries"]))
            } else {
                out.append(ToolSpec(name: "search_web",
                                    description: "联网搜索最新信息。需要时效性信息、具体事实、数据或来源时使用。",
                                    properties: [("query", ToolProperty("搜索词")),
                                                 ("max_results", ToolProperty("返回条数", type: .integer))],
                                    required: ["query"]))
            }
        }
        if a.fetchURL {
            out.append(ToolSpec(name: "fetch_url", description: "读取指定网页的正文文本（去除标签，最多约 12000 字）。用户给出链接或需要查看搜索结果原文时使用。",
                                properties: [("url", ToolProperty("完整网址（http/https）"))], required: ["url"]))
        }
        if a.viewImage {
            out.append(ToolSpec(name: "view_image",
                                description: "当前模型看不到图片。用户消息中的图片以 [图片#N] 占位，需要了解图片内容时调用本工具，由视觉模型回答你的问题。",
                                properties: [("image_index", ToolProperty("图片序号 N（对应 [图片#N]）")),
                                             ("query", ToolProperty("想了解的问题，默认「请分析这张图片。」"))],
                                required: ["image_index"]))
        }
        if a.imageGeneration {
            out.append(ToolSpec(name: "generate_image",
                                description: "根据文字描述生成一张图片并直接展示给用户。prompt 应详细描述主体、风格、构图、光线与色彩。生成后不要再输出图片链接。",
                                properties: [("prompt", ToolProperty("图像描述"))], required: ["prompt"]))
        }
        if a.mcp {
            out.append(ToolSpec(name: "mcp_list_tools", description: "列出已连接的 MCP 服务器及其工具（名称与说明）。调用 mcp_call 前先用它发现可用工具。",
                                properties: [("server", ToolProperty("服务器名（可选，不填则列出全部）"))]))
            out.append(ToolSpec(name: "mcp_call", description: "调用 MCP 服务器上的工具。arguments 为该工具 inputSchema 对应的 JSON 对象（字符串形式）。",
                                properties: [("server", ToolProperty("服务器名")), ("tool", ToolProperty("工具名")),
                                             ("arguments", ToolProperty("JSON 字符串参数"))],
                                required: ["server", "tool"]))
        }
        if a.memory {
            out.append(ToolSpec(name: "save_memory",
                                description: "把对今后独立对话有长期帮助的用户背景写入本机记忆。text 用完整第三人称陈述句（≤300 字）；source_quote 必须逐字摘自用户本轮的话。",
                                properties: [("text", ToolProperty("记忆内容（≤300 字）")),
                                             ("section", ToolProperty("分类", enumValues: MemorySection.allCases.map(\.rawValue))),
                                             ("source_quote", ToolProperty("用户本轮原话（逐字）")),
                                             ("profile_key", ToolProperty("个人资料字段（仅称呼/职业/所在地）", enumValues: MemoryProfileKey.allCases.map(\.rawValue))),
                                             ("topic", ToolProperty("主题名（短名词，优先沿用已有主题）")),
                                             ("group", ToolProperty("主题分组", enumValues: MemoryGroup.allCases.map(\.rawValue))),
                                             ("summary", ToolProperty("主题摘要"))],
                                required: ["text", "section", "source_quote"]))
            out.append(ToolSpec(name: "forget_memory", description: "用户明确否认或要求删除某条记忆时调用。source_quote 必须逐字摘自用户本轮的话。",
                                properties: [("query", ToolProperty("要删除的记忆关键词")), ("source_quote", ToolProperty("用户本轮原话（逐字）"))],
                                required: ["query", "source_quote"]))
        }
        if a.recall {
            out.append(ToolSpec(name: "recall_conversations",
                                description: "检索本机的历史对话。用户提到「上次」「之前说过」「我们聊过」时使用，不要凭印象作答。",
                                properties: [("queries", ToolProperty("1-4 个短关键词，用 | 分隔")),
                                             ("limit", ToolProperty("返回条数（1-3）", type: .integer)),
                                             ("conversation_id", ToolProperty("只搜指定对话（可选）"))],
                                required: ["queries"]))
        }
        return out
    }
}
