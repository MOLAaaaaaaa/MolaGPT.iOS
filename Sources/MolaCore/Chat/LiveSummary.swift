import Foundation

/// 从流式中的消息片段提炼实时活动要显示的状态与摘录（纯逻辑，便于测试）。
public enum LiveSummary {
    public enum Phase: String, Sendable { case thinking, writing, tool }

    public static func summarize(_ fragments: [MessageFragment], toolLabel: (String) -> String = { $0 },
                                 maxChars: Int = 90) -> (phase: Phase, snippet: String) {
        // 最后一个仍在进行的工具优先
        if let t = fragments.reversed().compactMap({ f -> ToolCallFragment? in
            if case .tool(let t) = f, t.status == .running { return t }; return nil
        }).first {
            return (.tool, t.statusLabel ?? t.label ?? toolLabel(t.name))
        }
        if case .search(_, let q, _, let status)? = fragments.last, status == .searching {
            return (.tool, "搜索：\(q)")
        }
        let text = fragments.compactMap { f -> String? in
            switch f {
            case .text(_, let md): md
            case .code(_, _, let code): code
            default: nil
            }
        }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .thinking(_, let t, _, nil)? = fragments.last { return (.thinking, tail(t, maxChars)) }
            return (.thinking, "")
        }
        return (.writing, tail(plain(text), maxChars))
    }

    /// 去掉常见 Markdown 记号并压缩空白，取末尾若干字。
    static func plain(_ md: String) -> String {
        var s = md
        let rules: [(String, String)] = [
            ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),   // 链接 / 图片 → 文字
            ("```[a-zA-Z0-9_-]*", ""), ("\\*\\*", ""), ("__", ""), ("`", ""),
            ("^#{1,6}\\s+", ""), ("^>\\s?", ""), ("^\\s*[-*+]\\s+", ""),
        ]
        for (p, template) in rules {
            guard let re = try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func tail(_ s: String, _ n: Int) -> String {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.count <= n ? t : "…" + t.suffix(n)
    }
}
