import Foundation

/// 一个 SSE 事件。`data` 为多行 `data:` 以 `\n` 拼接后的内容。
public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: String
    public init(event: String? = nil, data: String) { self.event = event; self.data = data }
    public var isDone: Bool { data.trimmingCharacters(in: .whitespaces) == "[DONE]" }
}

/// 增量 SSE 解析器（对应安卓 sse/SseParser.kt）。按行喂入：
/// - `data:` 行累积，`event:` 记录事件名，`:` 开头为心跳注释，空行分隔事件。
/// - 兼容不规范服务：若没有空行分隔、但每行都是完整 JSON 的 `data:`，下一条 `data:` 到来时也能逐条产出（见 `feed`）。
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// 喂入一行（不含行尾换行符）。返回此行触发完成的事件（若有）。
    public mutating func feed(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line; value = ""
        }

        switch field {
        case "data":
            // 非规范服务端：上一条 data 已是完整 JSON 且没有空行分隔 → 先产出上一条。
            var pending: SSEEvent?
            if let last = dataLines.last, dataLines.count == 1, Self.looksCompleteJSON(last), Self.looksJSONStart(value) {
                pending = dispatch()
            }
            dataLines.append(value)
            return pending
        case "event":
            eventName = value
            return nil
        default:
            return nil
        }
    }

    /// 流结束时冲刷尚未以空行结尾的事件。
    public mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer { dataLines.removeAll(); eventName = nil }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    private static func looksJSONStart(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("{") || t.hasPrefix("[") || t == "[DONE]"
    }

    private static func looksCompleteJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{") && t.hasSuffix("}") else { return false }
        return JSONValue.parse(t) != nil
    }

    /// 便捷：把整段文本拆成事件（测试 / 非流式回退用）。
    public static func parseAll(_ text: String) -> [SSEEvent] {
        var p = SSEParser()
        var out: [SSEEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let e = p.feed(line: String(line)) { out.append(e) }
        }
        if let e = p.finish() { out.append(e) }
        return out
    }
}

/// 把内联 `<think>...</think>` 从正文拆出来（跨 chunk 保留半个标签）。对应安卓 InlineThinkSplitter.kt。
public struct InlineThinkSplitter: Sendable {
    private let open = "<think>"
    private let close = "</think>"
    private var inThink = false
    private var carry = ""

    public init() {}

    public mutating func feed(_ text: String) -> (visible: String, thinking: String) {
        carry += text
        var vis = "", think = ""
        while true {
            let tag = inThink ? close : open
            if let r = carry.range(of: tag) {
                let before = String(carry[..<r.lowerBound])
                if inThink { think += before } else { vis += before }
                carry = String(carry[r.upperBound...])
                inThink.toggle()
            } else {
                let keep = Self.longestSuffixPrefix(carry, tag)
                let flush = String(carry.dropLast(keep))
                if inThink { think += flush } else { vis += flush }
                carry = String(carry.suffix(keep))
                break
            }
        }
        return (vis, think)
    }

    public mutating func flush() -> (visible: String, thinking: String) {
        defer { carry = "" }
        return inThink ? ("", carry) : (carry, "")
    }

    private static func longestSuffixPrefix(_ s: String, _ tag: String) -> Int {
        let maxLen = min(s.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) where s.hasSuffix(String(tag.prefix(len))) {
            return len
        }
        return 0
    }
}
