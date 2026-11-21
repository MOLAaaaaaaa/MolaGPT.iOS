import Foundation

// 云同步消息映射（对应安卓 SyncMapper）。会话 id：本地 sess_X ↔ 云端 chat_X；时间为 UTC ISO 毫秒。

public enum SyncMapper {
    public static let epoch = "1970-01-01T00:00:00.000Z"

    static var iso: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }

    public static func isoString(_ ms: Int64) -> String { iso.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
    public static func ms(_ s: String?) -> Int64? {
        guard let s, let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    public static func metadata(_ c: Conversation) -> JSONValue {
        ["id": .string(MolaChatAPI.conversationId(c.sessionId)), "title": .string(c.title), "time": .string(isoString(c.createdAt)),
         "updated_at": .string(isoString(c.updatedAt)), "model": .string(c.model ?? "auto")]
    }

    /// 助手正文：思考包回 `<think>`，工具卡序列化为 tool-status 引用块，便于网页端与安卓端显示。
    public static func content(_ m: ChatMessage) -> String {
        guard m.role == .assistant else { return m.text }
        var parts: [String] = []
        for f in m.fragments {
            switch f {
            case .thinking(_, let t, _, _): parts.append("<think>\(t)</think>")
            case .tool(let t):
                let cls = t.status == .failed ? "error" : t.status == .cancelled ? "cancelled" : t.status == .running ? "running" : "completed"
                parts.append("<blockquote class=\"tool-status \(cls)\" data-tool-name=\"\(t.name)\">\(t.label ?? t.name)</blockquote>")
            default:
                let p = f.plainText
                if !p.isEmpty { parts.append(p) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    public static func messages(_ list: [ChatMessage]) -> [JSONValue] {
        list.filter { $0.role == .user || $0.role == .assistant }.map { m in
            var meta: [String: JSONValue] = [:]
            if !m.attachments.isEmpty {
                meta["attachments"] = .array(m.attachments.map { ["name": .string($0.name), "mime": .string($0.mimeType), "url": .string($0.remoteUrl ?? "")] })
            }
            for f in m.fragments {
                if case .search(_, _, let refs, _) = f {
                    meta["sources"] = .array(refs.map { ["title": .string($0.title), "url": .string($0.url), "index": .number(Double($0.index ?? 0))] })
                }
            }
            if let extra = m.metadata["cloud_meta_extra"].flatMap(JSONValue.parse)?.objectValue { meta.merge(extra) { a, _ in a } }
            return ["role": .string(m.role == .user ? "user" : "assistant"), "content": .string(content(m)),
                    "timestamp": .number(Double(m.createdAt)), "model": .string(m.model ?? ""), "meta": .object(meta)]
        }
    }

    /// 云端消息 → 本地：解析 `<think>` 与工具标记（复用官方流解码器的切分）。
    public static func fromCloud(_ arr: [JSONValue], sessionId: String) -> [ChatMessage] {
        arr.enumerated().compactMap { i, j in
            let roleStr = j["role"]?.stringValue ?? "user"
            guard roleStr == "user" || roleStr == "assistant" else { return nil }
            let role: Role = roleStr == "user" ? .user : .assistant
            let ts = Int64(j["timestamp"]?.doubleValue ?? 0)
            let created = ts > 0 ? ts : (ms(j["timestamp"]?.stringValue) ?? IDs.nowMs())
            let raw = j["content"]?.stringValue ?? j["meta"]?["displayContent"]?.stringValue ?? ""
            var fragments: [MessageFragment] = []
            if role == .assistant {
                var acc = StreamAccumulator()
                var dec = MolaStreamDecoder()
                let frame: JSONValue = ["choices": [["delta": ["content": .string(raw)]]]]
                for e in dec.decode(SSEEvent(event: nil, data: frame.jsonString())) { acc.apply(e) }
                for e in dec.finish() { acc.apply(e) }
                fragments = acc.fragments.compactMap { f in
                    guard case .text(let id, let md) = f else { return f }
                    let t = md.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : .text(id: id, markdown: t)
                }
                if let srcs = j["meta"]?["sources"]?.arrayValue, !srcs.isEmpty {
                    let refs = srcs.compactMap { s -> SourceReference? in
                        guard let u = s["url"]?.stringValue else { return nil }
                        return SourceReference(title: s["title"]?.stringValue ?? u, url: u, snippet: nil, index: MolaJSON.int(s["index"]))
                    }
                    fragments.append(.search(id: IDs.fragment(), query: "", refs: refs, status: .done))
                }
            } else if !raw.isEmpty {
                fragments = [.text(id: IDs.fragment(), markdown: raw)]
            }
            var extra = j["meta"]?.objectValue ?? [:]
            for k in ["attachments", "sources", "displayContent"] { extra.removeValue(forKey: k) }
            var md: [String: String] = [:]
            if !extra.isEmpty { md["cloud_meta_extra"] = JSONValue.object(extra).jsonString() }
            return ChatMessage(messageId: "\(sessionId)_\(created)_\(i)_\(role.rawValue)", sessionId: sessionId, role: role, status: .complete,
                               createdAt: created, fragments: fragments, model: j["model"]?.stringValue?.nonBlank, metadata: md)
        }
    }
}
