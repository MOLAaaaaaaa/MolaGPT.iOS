import Foundation

/// ID 与时间工具，格式与安卓端保持一致（便于以后云端同步/导入导出）。
public enum IDs {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func random(_ length: Int) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// 会话 id：`sess_<ms>_<rand9>`
    public static func session() -> String { "sess_\(nowMs())_\(random(9))" }
    /// 消息 id：`msg_<ms>_<rand9>`
    public static func message() -> String { "msg_\(nowMs())_\(random(9))" }
    /// 片段 id
    public static func fragment() -> String { "frag_\(random(10))" }
    public static func generic(_ prefix: String) -> String { "\(prefix)_\(nowMs())_\(random(6))" }

    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

extension String {
    /// 去掉首尾空白后为空则返回 nil。
    public var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Kotlin `substringAfterLast('/')` 等价。
    public func substringAfterLast(_ ch: Character) -> String {
        if let i = lastIndex(of: ch) { return String(self[index(after: i)...]) }
        return self
    }

    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
