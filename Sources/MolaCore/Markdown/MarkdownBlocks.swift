import Foundation

/// Markdown 块级解析（对应安卓 core/markdown 的块切分）。行内格式交给 SwiftUI `AttributedString(markdown:)`。
/// 流式安全：未闭合的代码块按代码块渲染，未完成的表格行按段落处理。
public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String, closed: Bool)
    case math(String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case rule

    public struct ListItem: Sendable, Hashable {
        public var checked: Bool?
        public var blocks: [MarkdownBlock]
    }
}

public enum TableAlignment: Sendable, Hashable { case leading, center, trailing }

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        return parseBlocks(lines, &i)
    }

    static func parseBlocks(_ lines: [String], _ i: inout Int) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []

        func flushPara() {
            if !para.isEmpty {
                out.append(.paragraph(para.joined(separator: "\n")))
                para.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块
            if let fence = fenceMarker(trimmed) {
                flushPara()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                var closed = false
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence) && t.trimmingCharacters(in: CharacterSet(charactersIn: String(fence.first!))).isEmpty {
                        closed = true; i += 1; break
                    }
                    code.append(lines[i]); i += 1
                }
                out.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n"), closed: closed))
                continue
            }

            // 块级公式 $$ ... $$ / \[ ... \]
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                flushPara()
                let closer = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                var body = String(trimmed.dropFirst(2))
                if body.hasSuffix(closer) && body.count >= 2 {
                    body = String(body.dropLast(2))
                    out.append(.math(body.trimmingCharacters(in: .whitespaces))); i += 1; continue
                }
                var acc: [String] = body.isEmpty ? [] : [body]
                i += 1
                while i < lines.count {
                    let t = lines[i]
                    if let r = t.range(of: closer) {
                        let before = String(t[..<r.lowerBound])
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { acc.append(before) }
                        i += 1; break
                    }
                    acc.append(t); i += 1
                }
                out.append(.math(acc.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            if trimmed.isEmpty { flushPara(); i += 1; continue }

            // 标题
            if let h = heading(trimmed) { flushPara(); out.append(h); i += 1; continue }

            // 分隔线
            if isRule(trimmed) && para.isEmpty { out.append(.rule); i += 1; continue }

            // 表格：当前行含 |，下一行是分隔行
            if trimmed.contains("|"), i + 1 < lines.count, let aligns = tableSeparator(lines[i + 1]) {
                flushPara()
                let header = splitRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    var r = splitRow(t)
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                let a = aligns.count >= header.count ? Array(aligns.prefix(header.count))
                    : aligns + Array(repeating: .leading, count: header.count - aligns.count)
                out.append(.table(header: header, alignments: a, rows: rows))
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushPara()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var s = String(t.dropFirst())
                    if s.hasPrefix(" ") { s.removeFirst() }
                    inner.append(s); i += 1
                }
                var j = 0
                out.append(.quote(parseBlocks(inner, &j)))
                continue
            }

            // 列表
            if let marker = listMarker(line) {
                flushPara()
                out.append(parseList(lines, &i, ordered: marker.ordered, start: marker.start, indent: marker.indent))
                continue
            }

            para.append(line)
            i += 1
        }
        flushPara()
        return out
    }

    // MARK: 列表

    struct Marker { let ordered: Bool; let start: Int; let indent: Int; let contentOffset: Int }

    static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        let ws = line.count - rest.count
        if let f = rest.first, "-*+".contains(f), rest.dropFirst().first == " " {
            return Marker(ordered: false, start: 1, indent: indent, contentOffset: ws + 2)
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                return Marker(ordered: true, start: Int(digits) ?? 1, indent: indent, contentOffset: ws + digits.count + 2)
            }
        }
        return nil
    }

    static func parseList(_ lines: [String], _ i: inout Int, ordered: Bool, start: Int, indent: Int) -> MarkdownBlock {
        var items: [MarkdownBlock.ListItem] = []
        while i < lines.count, let m = listMarker(lines[i]), m.indent <= indent + 1, m.ordered == ordered {
            var content = [String(lines[i].dropFirst(m.contentOffset))]
            i += 1
            // 续行 / 子列表：缩进大于当前标记，或非空且不是新标记的惰性续行
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 空行后若仍缩进则属于本项
                    if i + 1 < lines.count, leadingSpaces(lines[i + 1]) > indent, listMarker(lines[i + 1]).map({ $0.indent > indent }) ?? true {
                        content.append(""); i += 1; continue
                    }
                    break
                }
                if let sub = listMarker(l), sub.indent <= indent + 1 { _ = sub; break }
                if leadingSpaces(l) > indent || listMarker(l) == nil && !l.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                    content.append(String(l.drop(while: { $0 == " " }).prefix(l.count)).isEmpty ? "" : dedent(l, by: m.contentOffset))
                    i += 1
                } else { break }
            }
            var checked: Bool?
            if let first = content.first {
                if first.hasPrefix("[ ] ") { checked = false; content[0] = String(first.dropFirst(4)) }
                else if first.lowercased().hasPrefix("[x] ") { checked = true; content[0] = String(first.dropFirst(4)) }
            }
            var j = 0
            items.append(.init(checked: checked, blocks: parseBlocks(content, &j)))
        }
        return .list(ordered: ordered, start: start, items: items)
    }

    static func leadingSpaces(_ s: String) -> Int { s.prefix(while: { $0 == " " }).count }

    static func dedent(_ s: String, by n: Int) -> String {
        let k = min(leadingSpaces(s), n)
        return String(s.dropFirst(k))
    }

    // MARK: 其它块

    static func fenceMarker(_ t: String) -> String? {
        if t.hasPrefix("```") { return String(t.prefix(while: { $0 == "`" })) }
        if t.hasPrefix("~~~") { return String(t.prefix(while: { $0 == "~" })) }
        return nil
    }

    static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), t.count == hashes || t.dropFirst(hashes).first == " " else { return nil }
        var text = String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    static func tableSeparator(_ line: String) -> [TableAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let cells = splitRow(t)
        guard !cells.isEmpty, cells.allSatisfy({ $0.contains("-") }) else { return nil }
        return cells.map { c in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return l && r ? .center : r ? .trailing : .leading
        }
    }

    static func splitRow(_ t: String) -> [String] {
        var s = t
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        var prev: Character = " "
        var inCode = false
        for ch in s {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && prev != "\\" && !inCode { cells.append(cur); cur = "" } else { cur.append(ch) }
            prev = ch
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }
}
