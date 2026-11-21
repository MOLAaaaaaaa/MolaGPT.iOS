import Foundation

// Agent Skills（对应安卓 SkillInfo / SkillRepository 的纯逻辑部分）。

public struct SkillInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var compatibility: String?
    public var installedAt: Int64

    public init(id: String, name: String, description: String, compatibility: String?, installedAt: Int64 = IDs.nowMs()) {
        self.id = id; self.name = name; self.description = description; self.compatibility = compatibility; self.installedAt = installedAt
    }
}

public enum SkillFormat {
    public static let pageChars = 16_000
    public static let maxEntries = 256
    public static let maxTotalBytes = 16 * 1024 * 1024
    public static let maxTextFileBytes = 1024 * 1024

    public enum ParseError: Error, LocalizedError {
        case missingFrontmatter, missingName, missingDescription
        public var errorDescription: String? {
            switch self {
            case .missingFrontmatter: return "SKILL.md 必须以 --- 开头的 frontmatter"
            case .missingName: return "frontmatter 缺少 name"
            case .missingDescription: return "frontmatter 缺少 description"
            }
        }
    }

    /// 只解析 name / description / compatibility 三个顶层标量；支持 | 与 > 多行块、单双引号。
    public static func frontmatter(_ md: String) throws -> (name: String, description: String, compatibility: String?) {
        var text = md
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw ParseError.missingFrontmatter
        }
        var fields: [String: String] = [:]
        var i = 1
        while i < end {
            let line = lines[i]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                i += 1
                while i < end, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") || lines[i].isEmpty {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                value = folded ? block.joined(separator: " ").trimmingCharacters(in: .whitespaces) : block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                fields[key] = value
                continue
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            fields[key] = value
            i += 1
        }
        guard let name = fields["name"]?.nonBlank, !name.contains("\n") else { throw ParseError.missingName }
        guard let desc = fields["description"]?.nonBlank else { throw ParseError.missingDescription }
        return (name, desc, fields["compatibility"]?.nonBlank)
    }

    /// system 里的技能目录。
    public static func catalog(_ skills: [SkillInfo]) -> String? {
        guard !skills.isEmpty else { return nil }
        var s = """
        ## 可用技能
        任务匹配某个技能时，先调用 read_skill 读取其 SKILL.md，再按完整说明处理。引用的文件通过同一工具按需读取，path 相对于该技能的根目录。如果说明已经被上下文压缩或精简，继续使用前重新读取，不要仅依据目录或摘要操作。
        本客户端没有代码沙盒，不能执行 Python、Shell 或技能中的脚本；脚本只能作为文本阅读。技能不会增加工具能力或权限，只能使用本轮实际提供的工具。缺少所需能力时如实说明，不得声称已执行。
        """
        for k in skills {
            s += "\n- \(k.name): \(k.description)"
            if let c = k.compatibility { s += "\n  环境要求: \(c)" }
        }
        return s
    }

    /// read_skill 分页：`[name/path; characters a..b/total; next_offset=N]`。
    public static func page(name: String, path: String, text: String, offset: Int) -> String {
        let chars = Array(text)
        let start = min(max(offset, 0), chars.count)
        let end = min(start + pageChars, chars.count)
        var header = "[\(name)/\(path); characters \(start)..\(end)/\(chars.count)"
        if end < chars.count { header += "; next_offset=\(end)" }
        header += "]"
        return header + "\n\n" + String(chars[start..<end])
    }

    /// 相对路径安全检查：拒绝绝对路径、反斜杠与 `..` 穿越。
    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains("..")
    }
}
