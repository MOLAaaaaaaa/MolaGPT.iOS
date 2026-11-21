import Foundation

// 回答后处理（对应安卓 ResponseRegexRule / ResponsePostProcessor / MarkdownParser.protectedRanges）。
// 回答结束后按顺序应用已启用的正则规则；代码、公式区间内的匹配原样保留。

public struct ResponseRegexRule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var pattern: String
    public var replacement: String
    public var enabled: Bool
    public var description: String?

    public init(id: String = IDs.generic("rule"), name: String, pattern: String, replacement: String, enabled: Bool = true, description: String? = nil) {
        self.id = id; self.name = name; self.pattern = pattern; self.replacement = replacement; self.enabled = enabled; self.description = description
    }

    public static let cjk = #"[㐀-䶿一-鿿豈-﫿぀-ヿㇰ-ㇿᄀ-ᇿ㄰-㆏가-힯]"#

    public static let builtins: [ResponseRegexRule] = [
        ResponseRegexRule(id: "builtin-cjk-comma", name: "中文逗号", pattern: "(?<=\(cjk)),(?=\(cjk))", replacement: "，",
                          description: "中文之间的英文逗号改为全角逗号"),
        ResponseRegexRule(id: "builtin-cjk-quote", name: "中文引号", pattern: "\"(?=[^\"\\r\\n]*\(cjk))([^\"\\r\\n]*)\"", replacement: "“$1”",
                          description: "包含中文的英文双引号改为中文引号"),
    ]

    /// 校验：pattern 非空且可编译，替换串的 `${…}` 闭合。
    public func validate() -> String? {
        if pattern.isEmpty { return "表达式不能为空" }
        do { _ = try NSRegularExpression(pattern: pattern) } catch { return "表达式无效：\(error.localizedDescription)" }
        var depth = 0
        var prev: Character = " "
        for ch in replacement {
            if prev == "$" && ch == "{" { depth += 1 }
            if ch == "}" && depth > 0 { depth -= 1 }
            prev = ch
        }
        return depth == 0 ? nil : "替换串中的 ${…} 未闭合"
    }

    /// Java 风格替换串（`$1`、`${name}`、`\` 转义）→ NSRegularExpression 模板（`$1`、`\` 转义）。
    var template: String {
        var out = ""
        var it = Array(replacement)
        var i = 0
        while i < it.count {
            let ch = it[i]
            if ch == "\\", i + 1 < it.count { out += "\\" + String(it[i + 1]); i += 2; continue }
            if ch == "$", i + 1 < it.count, it[i + 1] == "{" , let close = it[(i + 2)...].firstIndex(of: "}") {
                out += "${" + String(it[(i + 2)..<close]) + "}"; i = close + 1; continue
            }
            out.append(ch); i += 1
        }
        it.removeAll()
        return out
    }
}

public enum ResponsePostProcessor {
    public struct Outcome: Sendable {
        public var text: String
        public var replacements: Int
        public var failures: [String]
    }

    /// 受保护区间：代码围栏（未闭合保护到文末）、行内代码、块级/行内公式。
    public static func protectedRanges(_ s: String) -> [NSRange] {
        let ns = s as NSString
        var ranges: [NSRange] = []
        let patterns = [#"(?s)```.*?(?:```|\z)"#, #"(?s)~~~.*?(?:~~~|\z)"#, #"`[^`\n]+`"#,
                        #"(?s)\$\$.+?\$\$"#, #"(?s)\\\[.+?\\\]"#, #"\\\(.+?\\\)"#, #"(?<![\\$])\$[^\s$][^$\n]*?\$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if !ranges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { ranges.append(m.range) }
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    public static func apply(_ text: String, rules: [ResponseRegexRule]) -> Outcome {
        var current = text
        var total = 0
        var failures: [String] = []
        for rule in rules where rule.enabled {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else { failures.append(rule.name); continue }
            let ns = current as NSString
            let protected = protectedRanges(current)
            var out = ""
            var cursor = 0
            var count = 0
            for m in re.matches(in: current, range: NSRange(location: 0, length: ns.length)) {
                if protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 || ($0.location <= m.range.location && m.range.location < $0.location + $0.length) }) { continue }
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                out += re.replacementString(for: m, in: current, offset: 0, template: rule.template)
                cursor = m.range.location + m.range.length
                count += 1
            }
            guard count > 0 else { continue }
            out += ns.substring(from: cursor)
            current = out
            total += count
        }
        return Outcome(text: current, replacements: total, failures: failures)
    }

    public static let previewSample = """
    你好,世界。他说"今天天气不错"。
    ```python
    print("a,b")
    ```
    行内代码 `x,y` 与公式 $f(x,y)$ 不受影响。
    """
}
