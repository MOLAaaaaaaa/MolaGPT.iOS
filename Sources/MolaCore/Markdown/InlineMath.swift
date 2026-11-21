import Foundation

/// 段落内的行内公式切分：`$...$` 与 `\(...\)`，跳过反引号代码与转义 `\$`。
/// 为避免把货币（"$5 和 $10"）当公式：`$` 后不能是空白，闭合 `$` 前不能是空白、后面不能紧跟数字。
public enum InlineSegment: Sendable, Equatable {
    case text(String)
    case math(String)
}

public enum InlineMath {
    public static func split(_ s: String) -> [InlineSegment] {
        guard s.contains("$") || s.contains("\\(") else { return [.text(s)] }
        let c = Array(s)
        var out: [InlineSegment] = []
        var buf = ""
        var i = 0
        func flush() { if !buf.isEmpty { out.append(.text(buf)); buf = "" } }

        while i < c.count {
            let ch = c[i]
            // 行内代码原样保留
            if ch == "`" {
                var ticks = 0
                while i + ticks < c.count, c[i + ticks] == "`" { ticks += 1 }
                if let end = findTicks(c, from: i + ticks, count: ticks) {
                    buf += String(c[i..<(end + ticks)]); i = end + ticks; continue
                }
                buf += String(repeating: "`", count: ticks); i += ticks; continue
            }
            if ch == "\\", i + 1 < c.count {
                if c[i + 1] == "$" { buf += "\\$"; i += 2; continue }
                if c[i + 1] == "(" , let end = find(c, "\\)", from: i + 2) {
                    let body = String(c[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty { flush(); out.append(.math(body)); i = end + 2; continue }
                }
                buf.append(ch); i += 1; continue
            }
            if ch == "$" {
                // $$...$$ 出现在段落中间时也按行内处理
                let double = i + 1 < c.count && c[i + 1] == "$"
                let open = double ? 2 : 1
                let start = i + open
                if start < c.count, !c[start].isWhitespace,
                   let end = closingDollar(c, from: start, double: double) {
                    let body = String(c[start..<end])
                    flush(); out.append(.math(body.trimmingCharacters(in: .whitespaces)))
                    i = end + open; continue
                }
                buf.append(ch); i += 1; continue
            }
            buf.append(ch); i += 1
        }
        flush()
        return out
    }

    private static func findTicks(_ c: [Character], from: Int, count: Int) -> Int? {
        var j = from
        while j < c.count {
            if c[j] == "`" {
                var n = 0
                while j + n < c.count, c[j + n] == "`" { n += 1 }
                if n == count { return j }
                j += n
            } else { j += 1 }
        }
        return nil
    }

    private static func find(_ c: [Character], _ needle: String, from: Int) -> Int? {
        let n = Array(needle)
        guard c.count >= n.count else { return nil }
        var j = from
        while j + n.count <= c.count {
            if Array(c[j..<(j + n.count)]) == n { return j }
            j += 1
        }
        return nil
    }

    private static func closingDollar(_ c: [Character], from: Int, double: Bool) -> Int? {
        var j = from
        while j < c.count {
            let ch = c[j]
            if ch == "\n" && !double { return nil }
            if ch == "\\" { j += 2; continue }
            if ch == "$" {
                if double {
                    if j + 1 < c.count, c[j + 1] == "$" { return j > from ? j : nil }
                } else {
                    let prevSpace = c[j - 1].isWhitespace
                    let nextDigit = j + 1 < c.count && c[j + 1].isNumber
                    if !prevSpace && !nextDigit && j > from { return j }
                    if nextDigit { return nil }
                }
            }
            j += 1
        }
        return nil
    }
}
