import Foundation
import MolaCore

extension MolaSchema {
    /// v2：本地记忆 5 张表、上下文检查点、共享世界书、画图工作台、会话级开关与云同步字段、角色头像。
    static let v2: [String] = [
        "ALTER TABLE conversations ADD COLUMN byok_memory_enabled INTEGER;",
        "ALTER TABLE conversations ADD COLUMN byok_recall_enabled INTEGER;",
        "ALTER TABLE conversations ADD COLUMN memory_watermark_at INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE conversations ADD COLUMN memory_failures INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE conversations ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE conversations ADD COLUMN deleted_at INTEGER;",
        "ALTER TABLE conversations ADD COLUMN placeholder INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE conversations ADD COLUMN kind TEXT NOT NULL DEFAULT 'chat';",
        "ALTER TABLE personas ADD COLUMN avatar_path TEXT;",
        """
        CREATE TABLE IF NOT EXISTS byok_memory_entries (
          id TEXT PRIMARY KEY NOT NULL, scope TEXT NOT NULL DEFAULT 'global', text TEXT NOT NULL, normalized_key TEXT NOT NULL,
          section TEXT NOT NULL, profile_key TEXT, topic_id TEXT, confidence REAL NOT NULL, expires_at INTEGER,
          permanent INTEGER NOT NULL DEFAULT 0, origin TEXT NOT NULL, recurrence INTEGER NOT NULL DEFAULT 1,
          first_observed_at INTEGER NOT NULL, last_reinforced_at INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
        );
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_mem_key ON byok_memory_entries(scope, normalized_key);",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_mem_profile ON byok_memory_entries(scope, profile_key) WHERE profile_key IS NOT NULL;",
        """
        CREATE TABLE IF NOT EXISTS byok_memory_topics (
          id TEXT PRIMARY KEY NOT NULL, scope TEXT NOT NULL DEFAULT 'global', normalized_key TEXT NOT NULL, group_name TEXT NOT NULL,
          title TEXT NOT NULL, summary TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS byok_memory_evidence (
          id TEXT PRIMARY KEY NOT NULL, entry_id TEXT NOT NULL REFERENCES byok_memory_entries(id) ON DELETE CASCADE,
          session_id TEXT, message_id TEXT, quote TEXT NOT NULL, observed_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS byok_memory_candidates (
          id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, section TEXT NOT NULL, profile_key TEXT, topic_title TEXT, group_name TEXT,
          confidence REAL NOT NULL, quote TEXT, source_session_id TEXT, created_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS byok_memory_suppressions (
          scope TEXT NOT NULL DEFAULT 'global', normalized_key TEXT NOT NULL, text TEXT NOT NULL, reason TEXT NOT NULL, created_at INTEGER NOT NULL,
          PRIMARY KEY (scope, normalized_key)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS context_checkpoints (
          id TEXT PRIMARY KEY NOT NULL, session_id TEXT NOT NULL, anchor_message_id TEXT NOT NULL, summary TEXT NOT NULL,
          covered_digest TEXT NOT NULL, tokens_before INTEGER NOT NULL, tokens_after INTEGER NOT NULL, reason TEXT NOT NULL,
          provider_id TEXT, model_id TEXT, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, stale INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_ckpt_session ON context_checkpoints(session_id, created_at);",
        """
        CREATE TABLE IF NOT EXISTS lorebooks (
          id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, json TEXT NOT NULL, updated_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS image_tasks (
          task_id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, provider_id TEXT, model_id TEXT, mode TEXT NOT NULL DEFAULT 'chat',
          pinned INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS image_runs (
          id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL, prompt TEXT NOT NULL, kind TEXT NOT NULL, provider_id TEXT, model_id TEXT,
          size TEXT, count INTEGER NOT NULL DEFAULT 1, params_json TEXT, refs_json TEXT, active_version_id TEXT, created_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS image_versions (
          id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL, task_id TEXT NOT NULL, status TEXT NOT NULL, started_at INTEGER NOT NULL,
          ended_at INTEGER, outputs_json TEXT, error TEXT, created_at INTEGER NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_img_runs ON image_runs(task_id, created_at);",
        "CREATE INDEX IF NOT EXISTS idx_img_versions ON image_versions(run_id, created_at);",
    ]
}

/// 本地记忆仓库（对应安卓 ByokMemoryRepository / ConversationRecallRepository）。
extension MolaStore {
    private static let entryCols = "id,text,normalized_key,section,profile_key,topic_id,confidence,expires_at,permanent,origin,recurrence,first_observed_at,last_reinforced_at,created_at,updated_at"

    private static func entry(_ r: SQLiteDB.Row) -> MemoryEntry {
        var e = MemoryEntry(id: r.string(0), text: r.string(1), section: MemorySection.from(r.string(3)),
                            profileKey: r.stringOrNil(4).flatMap(MemoryProfileKey.init(rawValue:)), topicId: r.stringOrNil(5),
                            confidence: r.double(6), origin: MemoryOrigin(rawValue: r.string(9)) ?? .automatic, permanent: r.bool(8))
        e.normalizedKey = r.string(2)
        e.expiresAt = r.isNull(7) ? nil : r.int64(7)
        e.recurrence = r.int(10)
        e.firstObservedAt = r.int64(11); e.lastReinforcedAt = r.int64(12); e.createdAt = r.int64(13); e.updatedAt = r.int64(14)
        return e
    }

    public func memoryEntries() -> [MemoryEntry] {
        (try? db.query("SELECT \(Self.entryCols) FROM byok_memory_entries ORDER BY updated_at DESC", map: Self.entry)) ?? []
    }

    public func memoryEntry(key: String) -> MemoryEntry? {
        (try? db.query("SELECT \(Self.entryCols) FROM byok_memory_entries WHERE normalized_key = ?", [.text(key)], map: Self.entry))?.first
    }

    public func memoryEntry(profile: MemoryProfileKey) -> MemoryEntry? {
        (try? db.query("SELECT \(Self.entryCols) FROM byok_memory_entries WHERE profile_key = ?", [.text(profile.rawValue)], map: Self.entry))?.first
    }

    public func memoryEntry(id: String) -> MemoryEntry? {
        (try? db.query("SELECT \(Self.entryCols) FROM byok_memory_entries WHERE id = ?", [.text(id)], map: Self.entry))?.first
    }

    public func upsert(_ e: MemoryEntry) throws {
        try db.run("""
            INSERT INTO byok_memory_entries (\(Self.entryCols)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, normalized_key=excluded.normalized_key, section=excluded.section,
              profile_key=excluded.profile_key, topic_id=excluded.topic_id, confidence=excluded.confidence, expires_at=excluded.expires_at,
              permanent=excluded.permanent, origin=excluded.origin, recurrence=excluded.recurrence, last_reinforced_at=excluded.last_reinforced_at,
              updated_at=excluded.updated_at
            """, [.text(e.id), .text(e.text), .text(e.normalizedKey), .text(e.section.rawValue), .of(e.profileKey?.rawValue), .of(e.topicId),
                  .double(e.confidence), e.expiresAt.map { .of($0) } ?? .null, .of(e.permanent), .text(e.origin.rawValue), .of(e.recurrence),
                  .of(e.firstObservedAt), .of(e.lastReinforcedAt), .of(e.createdAt), .of(e.updatedAt)])
    }

    public func deleteMemory(_ id: String, suppress: Bool, reason: String = "deleted") throws {
        if suppress, let e = memoryEntry(id: id) { try addSuppression(e.text, reason: reason) }
        try db.run("DELETE FROM byok_memory_evidence WHERE entry_id = ?", [.text(id)])
        try db.run("DELETE FROM byok_memory_entries WHERE id = ?", [.text(id)])
    }

    public func addEvidence(entryId: String, sessionId: String?, messageId: String?, quote: String) throws {
        try db.run("INSERT INTO byok_memory_evidence (id,entry_id,session_id,message_id,quote,observed_at) VALUES (?,?,?,?,?,?)",
                   [.text(IDs.generic("evd")), .text(entryId), .of(sessionId), .of(messageId), .text(String(quote.prefix(180))), .of(IDs.nowMs())])
    }

    public func evidenceCount(_ entryId: String) -> Int {
        (try? db.query("SELECT COUNT(*) FROM byok_memory_evidence WHERE entry_id = ?", [.text(entryId)]) { $0.int(0) })?.first ?? 0
    }

    // 主题
    public func memoryTopics() -> [MemoryTopic] {
        (try? db.query("SELECT id,group_name,title,summary,updated_at FROM byok_memory_topics ORDER BY updated_at DESC") { r in
            MemoryTopic(id: r.string(0), group: MemoryGroup(rawValue: r.string(1)) ?? .interests, title: r.string(2), summary: r.stringOrNil(3), updatedAt: r.int64(4))
        }) ?? []
    }

    public func upsert(_ t: MemoryTopic) throws {
        try db.run("""
            INSERT INTO byok_memory_topics (id,normalized_key,group_name,title,summary,created_at,updated_at) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET normalized_key=excluded.normalized_key, group_name=excluded.group_name, title=excluded.title,
              summary=excluded.summary, updated_at=excluded.updated_at
            """, [.text(t.id), .text(MemoryMath.normalizeKey(t.title)), .text(t.group.rawValue), .text(t.title), .of(t.summary), .of(t.updatedAt), .of(t.updatedAt)])
    }

    public func deleteTopic(_ id: String) throws {
        try db.run("UPDATE byok_memory_entries SET topic_id = NULL WHERE topic_id = ?", [.text(id)])
        try db.run("DELETE FROM byok_memory_topics WHERE id = ?", [.text(id)])
    }

    /// 按标题找主题，没有就新建。
    public func resolveTopic(title: String?, group: MemoryGroup?, summary: String?) -> String? {
        guard let title = title?.nonBlank else { return nil }
        let key = MemoryMath.normalizeKey(title)
        if let id = (try? db.query("SELECT id FROM byok_memory_topics WHERE normalized_key = ?", [.text(key)]) { $0.string(0) })?.first { return id }
        let t = MemoryTopic(group: group ?? .interests, title: String(title.prefix(60)), summary: summary.map { String($0.prefix(240)) })
        try? upsert(t)
        return t.id
    }

    // 候选
    public func memoryCandidates() -> [MemoryCandidate] {
        (try? db.query("SELECT id,text,section,profile_key,topic_title,group_name,confidence,quote,source_session_id,created_at FROM byok_memory_candidates ORDER BY created_at DESC") { r in
            var c = MemoryCandidate(id: r.string(0), text: r.string(1), section: MemorySection.from(r.string(2)),
                                    profileKey: r.stringOrNil(3).flatMap(MemoryProfileKey.init(rawValue:)), topicTitle: r.stringOrNil(4),
                                    group: r.stringOrNil(5).flatMap(MemoryGroup.init(rawValue:)), confidence: r.double(6),
                                    quote: r.stringOrNil(7), sourceSessionId: r.stringOrNil(8))
            c.createdAt = r.int64(9)
            return c
        }) ?? []
    }

    public func insert(_ c: MemoryCandidate) throws {
        try db.run("INSERT OR REPLACE INTO byok_memory_candidates (id,text,section,profile_key,topic_title,group_name,confidence,quote,source_session_id,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                   [.text(c.id), .text(c.text), .text(c.section.rawValue), .of(c.profileKey?.rawValue), .of(c.topicTitle), .of(c.group?.rawValue),
                    .double(c.confidence), .of(c.quote), .of(c.sourceSessionId), .of(c.createdAt)])
    }

    public func deleteCandidate(_ id: String) throws { try db.run("DELETE FROM byok_memory_candidates WHERE id = ?", [.text(id)]) }

    // 屏蔽
    public func suppressions() -> [String] {
        (try? db.query("SELECT text FROM byok_memory_suppressions ORDER BY created_at DESC") { $0.string(0) }) ?? []
    }

    public func isSuppressed(_ text: String) -> Bool {
        ((try? db.query("SELECT 1 FROM byok_memory_suppressions WHERE normalized_key = ?", [.text(MemoryMath.normalizeKey(text))]) { $0.int(0) }) ?? []).isEmpty == false
    }

    public func addSuppression(_ text: String, reason: String) throws {
        try db.run("INSERT OR REPLACE INTO byok_memory_suppressions (normalized_key,text,reason,created_at) VALUES (?,?,?,?)",
                   [.text(MemoryMath.normalizeKey(text)), .text(text), .text(reason), .of(IDs.nowMs())])
    }

    public func clearSuppression(_ text: String) throws {
        try db.run("DELETE FROM byok_memory_suppressions WHERE normalized_key = ?", [.text(MemoryMath.normalizeKey(text))])
    }

    public func clearAllMemory() throws {
        try db.transaction {
            for t in ["byok_memory_evidence", "byok_memory_entries", "byok_memory_candidates", "byok_memory_topics"] { try db.exec("DELETE FROM \(t);") }
            try db.run("UPDATE conversations SET memory_watermark_at = ?", [.of(IDs.nowMs())])
        }
    }

    // 会话级开关与水位线
    public func memoryFlags(_ sessionId: String) -> (memory: Bool?, recall: Bool?, watermark: Int64, failures: Int) {
        (try? db.query("SELECT byok_memory_enabled, byok_recall_enabled, memory_watermark_at, memory_failures FROM conversations WHERE session_id = ?", [.text(sessionId)]) { r in
            (r.isNull(0) ? nil : r.bool(0), r.isNull(1) ? nil : r.bool(1), r.int64(2), r.int(3))
        })?.first ?? (nil, nil, 0, 0)
    }

    public func setMemoryFlags(_ sessionId: String, memory: Bool?, recall: Bool?) throws {
        try db.run("UPDATE conversations SET byok_memory_enabled = ?, byok_recall_enabled = ? WHERE session_id = ?",
                   [memory.map { .of($0) } ?? .null, recall.map { .of($0) } ?? .null, .text(sessionId)])
    }

    public func setWatermark(_ sessionId: String, _ at: Int64, failures: Int = 0) throws {
        try db.run("UPDATE conversations SET memory_watermark_at = ?, memory_failures = ? WHERE session_id = ?", [.of(at), .of(failures), .text(sessionId)])
    }

    public func setMemoryFailures(_ sessionId: String, _ n: Int) throws {
        try db.run("UPDATE conversations SET memory_failures = ? WHERE session_id = ?", [.of(n), .text(sessionId)])
    }

    /// 回忆对话：instr 关键词检索（不用 FTS），每个短语单独查，按命中短语数与时间排序。
    public func recall(queries: [String], limit: Int, excludeSession: String?, onlySession: String?) -> [RecallHit] {
        struct Raw { var id: String; var session: String; var title: String; var createdAt: Int64; var role: String; var text: String; var matched: Set<String> }
        var map: [String: Raw] = [:]
        for q in queries {
            var sql = """
                SELECT m.message_id, m.session_id, c.title, m.created_at, m.role, m.fragments_json
                FROM messages m JOIN conversations c ON c.session_id = m.session_id
                WHERE c.deleted_at IS NULL AND c.placeholder = 0 AND c.provider_kind = 'BYOK' AND m.role IN ('USER','ASSISTANT')
                  AND instr(lower(m.fragments_json), lower(?)) > 0
                """
            var args: [SQLiteDB.Value] = [.text(q)]
            if let only = onlySession { sql += " AND m.session_id = ?"; args.append(.text(only)) }
            else if let ex = excludeSession { sql += " AND m.session_id <> ?"; args.append(.text(ex)) }
            sql += " ORDER BY m.created_at DESC LIMIT \(limit * 4)"
            let rows = (try? db.query(sql, args) { r in
                Raw(id: r.string(0), session: r.string(1), title: r.string(2), createdAt: r.int64(3), role: r.string(4),
                    text: Self.plainText(r.string(5)), matched: [])
            }) ?? []
            for var row in rows where row.text.lowercased().contains(q.lowercased()) {
                row.matched = (map[row.id]?.matched ?? []).union([q])
                map[row.id] = row
            }
        }
        let top = map.values.sorted { a, b in a.matched.count != b.matched.count ? a.matched.count > b.matched.count : a.createdAt > b.createdAt }.prefix(limit)
        return top.map { raw in
            let all = (try? db.query("SELECT message_id, role, fragments_json, created_at FROM messages WHERE session_id = ? AND role IN ('USER','ASSISTANT') ORDER BY created_at", [.text(raw.session)]) { r in
                (r.string(0), r.string(1), r.string(2), r.int64(3))
            }) ?? []
            let idx = all.firstIndex { $0.0 == raw.id } ?? 0
            let ctx = all[max(0, idx - 2)...min(all.count - 1, idx + 2)].map { m in
                (role: Role(rawValue: m.1) ?? .user, text: Self.plainText(m.2), createdAt: m.3, isHit: m.0 == raw.id)
            }
            let lower = raw.text.lowercased()
            var snippet = String(raw.text.prefix(160))
            if let q = raw.matched.first, let r = lower.range(of: q.lowercased()) {
                let pos = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let start = raw.text.index(raw.text.startIndex, offsetBy: max(0, pos - 40))
                snippet = String(raw.text[start...].prefix(160))
            }
            return RecallHit(sessionId: raw.session, title: raw.title, messageId: raw.id, createdAt: raw.createdAt,
                             matched: raw.matched.count, snippet: snippet, context: Array(ctx))
        }
    }

    static func plainText(_ fragmentsJSON: String) -> String {
        guard let frags = decodeJSON([MessageFragment].self, fragmentsJSON) else { return "" }
        return frags.compactMap { f -> String? in
            switch f {
            case .text(_, let md): return md
            case .code(_, _, let c): return c
            default: return nil
            }
        }.joined(separator: "\n")
    }
}
