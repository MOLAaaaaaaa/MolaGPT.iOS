import Foundation

// BYOK 工具定义（对应安卓 ByokChatService.ToolSpec / ToolProperty / toolSpecs）。
// 一份 spec 渲染成四家协议的外壳；Gemini 的类型名大写。

public enum ToolParamType: String, Sendable, Hashable {
    case string, integer, boolean, array, object
}

public struct ToolProperty: Sendable, Hashable {
    public var description: String
    public var type: ToolParamType
    public var enumValues: [String]?
    /// 数组元素为 object 时的字段（有序）。
    public var itemProperties: [(String, ToolProperty)]?
    public var itemRequired: [String]

    public init(_ description: String, type: ToolParamType = .string, enumValues: [String]? = nil,
                itemProperties: [(String, ToolProperty)]? = nil, itemRequired: [String] = []) {
        self.description = description; self.type = type; self.enumValues = enumValues
        self.itemProperties = itemProperties; self.itemRequired = itemRequired
    }

    public static func == (l: ToolProperty, r: ToolProperty) -> Bool {
        l.description == r.description && l.type == r.type && l.enumValues == r.enumValues && l.itemRequired == r.itemRequired
            && l.itemProperties?.map(\.0) == r.itemProperties?.map(\.0)
    }
    public func hash(into h: inout Hasher) { h.combine(description); h.combine(type) }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var properties: [(String, ToolProperty)]
    public var required: [String]
    /// MCP 等外部工具可直接给出完整 JSON Schema（优先于 properties）。
    public var rawSchema: JSONValue?

    public init(name: String, description: String, properties: [(String, ToolProperty)] = [], required: [String] = [], rawSchema: JSONValue? = nil) {
        self.name = name; self.description = description; self.properties = properties; self.required = required; self.rawSchema = rawSchema
    }

    public static func == (l: ToolSpec, r: ToolSpec) -> Bool { l.name == r.name && l.description == r.description }
    public func hash(into h: inout Hasher) { h.combine(name) }

    /// 参数 JSON Schema。
    public func parameters(gemini: Bool) -> JSONValue {
        if let rawSchema { return gemini ? Self.geminiSanitize(rawSchema) : rawSchema }
        var props: [String: JSONValue] = [:]
        for (k, p) in properties { props[k] = Self.render(p, gemini: gemini) }
        var obj: [String: JSONValue] = ["type": .string(gemini ? "OBJECT" : "object"), "properties": .object(props)]
        if !required.isEmpty { obj["required"] = .array(required.map { .string($0) }) }
        return .object(obj)
    }

    static func typeName(_ t: ToolParamType, gemini: Bool) -> String { gemini ? t.rawValue.uppercased() : t.rawValue }

    static func render(_ p: ToolProperty, gemini: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string(typeName(p.type, gemini: gemini)), "description": .string(p.description)]
        if let e = p.enumValues, !e.isEmpty { o["enum"] = .array(e.map { .string($0) }) }
        if p.type == .array {
            if let items = p.itemProperties {
                var ip: [String: JSONValue] = [:]
                for (k, v) in items { ip[k] = render(v, gemini: gemini) }
                var item: [String: JSONValue] = ["type": .string(gemini ? "OBJECT" : "object"), "properties": .object(ip)]
                if !p.itemRequired.isEmpty { item["required"] = .array(p.itemRequired.map { .string($0) }) }
                o["items"] = .object(item)
            } else {
                o["items"] = ["type": .string(gemini ? "STRING" : "string")]
            }
        }
        return .object(o)
    }

    /// Gemini 只接受 OpenAPI 子集：去掉 `$schema`、`additionalProperties` 等，类型名大写。
    static func geminiSanitize(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, val) in o {
                if ["$schema", "additionalProperties", "$ref", "$defs", "definitions", "default", "examples", "title", "const"].contains(k) { continue }
                if k == "type", let s = val.stringValue { out[k] = .string(s.uppercased()); continue }
                if k == "type", case .array(let arr) = val, let first = arr.first(where: { $0.stringValue != "null" })?.stringValue {
                    out[k] = .string(first.uppercased()); continue
                }
                out[k] = geminiSanitize(val)
            }
            return .object(out)
        case .array(let a): return .array(a.map(geminiSanitize))
        default: return v
        }
    }

    /// 四家协议的工具声明。
    public static func render(_ specs: [ToolSpec], for type: ByokProviderType) -> JSONValue {
        switch type {
        case .openAICompat:
            return .array(specs.map { s in
                ["type": "function", "function": ["name": .string(s.name), "description": .string(s.description), "parameters": s.parameters(gemini: false)]]
            })
        case .openAIResponse:
            return .array(specs.map { s in
                ["type": "function", "name": .string(s.name), "description": .string(s.description), "parameters": s.parameters(gemini: false)]
            })
        case .anthropic:
            return .array(specs.map { s in
                ["name": .string(s.name), "description": .string(s.description), "input_schema": s.parameters(gemini: false)]
            })
        case .gemini:
            return [["functionDeclarations": .array(specs.map { s in
                ["name": .string(s.name), "description": .string(s.description), "parameters": s.parameters(gemini: true)]
            })]]
        }
    }
}

/// 一次完整的工具调用（流结束后累积而成）。
public struct PendingToolCall: Sendable, Hashable {
    public var id: String
    /// Responses API 的 call_id（回放 function_call_output 用）；Gemini 原始 id（无则为 nil）。
    public var callId: String?
    public var name: String
    public var arguments: String

    public init(id: String, callId: String? = nil, name: String, arguments: String) {
        self.id = id; self.callId = callId; self.name = name; self.arguments = arguments
    }

    public var args: JSONValue { JSONValue.parse(arguments) ?? .object([:]) }

    public func string(_ key: String) -> String? {
        let v = args[key]
        if let s = v?.stringValue { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let d = v?.doubleValue { return d == d.rounded() ? String(Int(d)) : String(d) }
        return nil
    }

    public func int(_ key: String) -> Int? {
        args[key]?.intValue ?? args[key]?.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

public struct ToolResult: Sendable, Hashable {
    public var output: String
    public var failed: Bool
    public init(_ output: String, failed: Bool = false) { self.output = output; self.failed = failed }
    public static func failure(_ s: String) -> ToolResult { ToolResult(s, failed: true) }
}

/// 工具执行器：由 App 层注入（联网、MCP、记忆等依赖 App 状态）。`emit` 用来向 UI 推送来源、图片等附带事件。
public protocol ToolExecutor: Sendable {
    func execute(_ call: PendingToolCall, emit: @escaping @Sendable (StreamEvent) -> Void) async -> ToolResult
}

public enum ToolLabels {
    public static func label(_ name: String) -> String {
        switch name {
        case "search_web", "web_search": return "联网搜索"
        case "fetch_url": return "阅读网页"
        case "read_skill": return "读取技能"
        case "view_image": return "视觉理解"
        case "generate_image": return "图像生成"
        case "mcp_list_tools": return "MCP 工具列表"
        case "mcp_call": return "MCP 服务器"
        case "save_memory": return "记住"
        case "forget_memory": return "忘记"
        case "recall_conversations": return "回忆对话"
        default: return "工具调用"
        }
    }

    public static func icon(_ name: String) -> String {
        switch name {
        case "search_web", "web_search": return "magnifyingglass"
        case "fetch_url": return "doc.text.magnifyingglass"
        case "read_skill": return "book.closed"
        case "view_image": return "eye"
        case "generate_image": return "paintbrush"
        case "mcp_list_tools", "mcp_call": return "puzzlepiece.extension"
        case "save_memory": return "brain"
        case "forget_memory": return "brain.filled.head.profile"
        case "recall_conversations": return "clock.arrow.circlepath"
        default: return "wrench.and.screwdriver"
        }
    }

    /// 失败前缀分类（对应安卓 classifyByokToolResult）。
    public static func looksFailed(_ output: String) -> Bool {
        let prefixes = ["Missing ", "Unsupported tool:", "Search failed:", "Fetch failed:", "Skill failed:", "Vision failed:",
                        "Image generation failed:", "MCP failed:", "memory failed:", "recall failed:", "Tool ", "MCP tool disabled:"]
        if prefixes.contains(where: { output.hasPrefix($0) }) { return true }
        if let j = JSONValue.parse(output), j["success"]?.boolValue == false { return true }
        return false
    }

    /// UI 卡片预览（对应安卓 toolPreviewOf）。
    public static func preview(call: PendingToolCall, result: ToolResult) -> String? {
        if call.name == "view_image" && !result.failed { return nil }
        if result.failed { return result.output }
        switch call.name {
        case "search_web":
            if let q = call.string("query"), !q.isEmpty { return String(q.prefix(200)) }
            let qs = call.args["queries"]?.arrayValue?.compactMap { $0["query"]?.stringValue } ?? []
            return qs.isEmpty ? nil : String(qs.joined(separator: " / ").prefix(200))
        case "read_skill":
            return "\(call.string("skill") ?? "")/\(call.string("path") ?? "SKILL.md")"
        case "fetch_url", "recall_conversations":
            let head = result.output.components(separatedBy: "\n\n").first ?? result.output
            return String(head.prefix(400))
        default:
            return String(result.output.prefix(1200))
        }
    }
}
