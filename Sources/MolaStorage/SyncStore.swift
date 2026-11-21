import Foundation
import MolaCore

/// 云同步所需的会话标记（dirty / 墓碑 / 占位）。
extension MolaStore {
    private static let syncCols = "session_id,title,model,provider_id,provider_kind,created_at,updated_at,pinned,last_preview,persona_id,system_prompt,message_count"

    private static func row(_ r: SQLiteDB.Row) -> Conversation {
        Conversation(sessionId: r.string(0), title: r.string(1), model: r.stringOrNil(2), providerId: r.stringOrNil(3),
                     providerKind: ProviderKind(rawValue: r.string(4)) ?? .byok, createdAt: r.int64(5), updatedAt: r.int64(6),
                     pinned: r.bool(7), lastMessagePreview: r.stringOrNil(8), personaId: r.stringOrNil(9),
                     systemPrompt: r.stringOrNil(10), messageCount: r.int(11))
    }

    /// 待推送的官方会话（首次同步推全部活跃会话）。
    public func syncCandidates(all: Bool) -> [Conversation] {
        let cond = all ? "" : " AND dirty = 1"
        return (try? db.query("SELECT \(Self.syncCols) FROM conversations WHERE provider_kind = 'MOLAGPT' AND placeholder = 0 AND deleted_at IS NULL\(cond)",
                              map: Self.row)) ?? []
    }

    public func tombstones() -> [String] {
        (try? db.query("SELECT session_id FROM conversations WHERE deleted_at IS NOT NULL") { $0.string(0) }) ?? []
    }

    public func softDelete(_ ids: [String]) throws {
        for id in ids { try db.run("UPDATE conversations SET deleted_at = ?, dirty = 1 WHERE session_id = ?", [.of(IDs.nowMs()), .text(id)]) }
    }

    public func markClean(_ ids: [String]) throws {
        for id in ids { try db.run("UPDATE conversations SET dirty = 0 WHERE session_id = ?", [.text(id)]) }
    }

    public func isPlaceholder(_ id: String) -> Bool {
        ((try? db.query("SELECT placeholder FROM conversations WHERE session_id = ?", [.text(id)]) { $0.bool(0) })?.first) ?? false
    }

    public func isTombstoned(_ id: String) -> Bool {
        ((try? db.query("SELECT deleted_at IS NOT NULL FROM conversations WHERE session_id = ?", [.text(id)]) { $0.bool(0) })?.first) ?? false
    }

    /// 合并云端元数据：本地没有 → 占位行；云端更新 → 只改标题 / 模型 / 时间（不拉正文）。
    public func mergeCloud(sessionId: String, title: String, model: String?, createdAt: Int64, updatedAt: Int64) throws {
        if isTombstoned(sessionId) { return }
        if let local = conversation(sessionId) {
            guard updatedAt > local.updatedAt else { return }
            try db.run("UPDATE conversations SET title = ?, model = ?, updated_at = ? WHERE session_id = ?",
                       [.text(title), .of(model), .of(updatedAt), .text(sessionId)])
        } else {
            try db.run("""
                INSERT INTO conversations (session_id,title,model,provider_id,provider_kind,created_at,updated_at,pinned,message_count,placeholder,dirty)
                VALUES (?,?,?,'molagpt','MOLAGPT',?,?,0,0,1,0)
                """, [.text(sessionId), .text(title), .of(model), .of(createdAt), .of(updatedAt)])
        }
    }

    public func markLoaded(_ sessionId: String, messages: [ChatMessage]) throws {
        try replaceAll(sessionId: sessionId, with: messages)
        try db.run("UPDATE conversations SET placeholder = 0, dirty = 0 WHERE session_id = ?", [.text(sessionId)])
        try refreshSummary(sessionId)
    }
}
