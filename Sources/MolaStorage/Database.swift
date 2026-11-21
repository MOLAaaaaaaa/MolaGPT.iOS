import Foundation
import MolaCore

/// 数据库 schema 与迁移（对应安卓 MolaDatabase.kt；iOS 从 v1 重新编号）。
public enum MolaSchema {
    public static let version = 2

    static let migrations: [Int: [String]] = [
        1: [
            """
            CREATE TABLE IF NOT EXISTS conversations (
              session_id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              model TEXT,
              provider_id TEXT,
              provider_kind TEXT NOT NULL DEFAULT 'BYOK',
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              pinned INTEGER NOT NULL DEFAULT 0,
              last_preview TEXT,
              persona_id TEXT,
              system_prompt TEXT,
              message_count INTEGER NOT NULL DEFAULT 0
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_conv_updated ON conversations(pinned DESC, updated_at DESC);",
            """
            CREATE TABLE IF NOT EXISTS messages (
              message_id TEXT PRIMARY KEY NOT NULL,
              session_id TEXT NOT NULL REFERENCES conversations(session_id) ON DELETE CASCADE,
              role TEXT NOT NULL,
              status TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              fragments_json TEXT NOT NULL,
              plain_text TEXT NOT NULL DEFAULT '',
              model TEXT,
              attachments_json TEXT,
              stats_json TEXT,
              extra_json TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_msg_session ON messages(session_id, created_at);",
            """
            CREATE TABLE IF NOT EXISTS byok_providers (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              base_url TEXT NOT NULL,
              chat_path TEXT NOT NULL,
              models_path TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1,
              models_json TEXT NOT NULL DEFAULT '[]',
              headers_json TEXT NOT NULL DEFAULT '[]',
              sort_order INTEGER NOT NULL DEFAULT 0,
              updated_at INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS personas (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              icon TEXT,
              system_prompt TEXT NOT NULL,
              default_thinking INTEGER,
              default_effort TEXT,
              sort_order INTEGER NOT NULL DEFAULT 0,
              pinned INTEGER NOT NULL DEFAULT 0,
              is_builtin INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              profile_json TEXT,
              deleted_at INTEGER
            );
            """,
        ],
    ]

    static var allMigrations: [Int: [String]] { migrations.merging([2: v2]) { a, _ in a } }

    static func migrate(_ db: SQLiteDB) throws {
        let current = db.userVersion
        guard current < version else { return }
        try db.transaction {
            for v in (current + 1)...version {
                for sql in allMigrations[v] ?? [] { try db.exec(sql) }
            }
        }
        try db.setUserVersion(version)
    }
}

/// 应用的数据仓库：会话 / 消息 / Provider / 角色。线程安全（内部串行锁），查询量小，可在主线程直接调用。
public final class MolaStore: @unchecked Sendable {
    public let db: SQLiteDB
    public let attachmentsDir: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDB(path: directory.appendingPathComponent("mola.db").path)
        attachmentsDir = directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try MolaSchema.migrate(db)
        try seedBuiltinPersonas()
    }

    /// 默认位置：Application Support/MolaGPT
    public static func makeDefault() throws -> MolaStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return try MolaStore(directory: base.appendingPathComponent("MolaGPT", isDirectory: true))
    }

    // MARK: - 会话

    private static let convColumns = "session_id,title,model,provider_id,provider_kind,created_at,updated_at,pinned,last_preview,persona_id,system_prompt,message_count"

    private static func conversation(_ r: SQLiteDB.Row) -> Conversation {
        Conversation(sessionId: r.string(0), title: r.string(1), model: r.stringOrNil(2), providerId: r.stringOrNil(3),
                     providerKind: ProviderKind(rawValue: r.string(4)) ?? .byok, createdAt: r.int64(5), updatedAt: r.int64(6),
                     pinned: r.bool(7), lastMessagePreview: r.stringOrNil(8), personaId: r.stringOrNil(9),
                     systemPrompt: r.stringOrNil(10), messageCount: r.int(11))
    }

    public func conversations(search: String? = nil, limit: Int = 500) -> [Conversation] {
        let cols = Self.convColumns.split(separator: ",").map { "c.\($0)" }.joined(separator: ",")
        if let q = search?.nonBlank {
            let like = "%\(q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
            return (try? db.query("""
                SELECT \(cols) FROM conversations c
                WHERE c.deleted_at IS NULL AND (c.title LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM messages m WHERE m.session_id = c.session_id AND m.plain_text LIKE ? ESCAPE '\\'))
                ORDER BY c.pinned DESC, c.updated_at DESC LIMIT ?
                """, [.text(like), .text(like), .of(limit)], map: Self.conversation)) ?? []
        }
        return (try? db.query("SELECT \(cols) FROM conversations c WHERE c.deleted_at IS NULL ORDER BY c.pinned DESC, c.updated_at DESC LIMIT ?",
                              [.of(limit)], map: Self.conversation)) ?? []
    }

    public func conversation(_ id: String) -> Conversation? {
        try? db.query("SELECT \(Self.convColumns) FROM conversations WHERE session_id = ?", [.text(id)], map: Self.conversation).first
    }

    public func upsert(_ c: Conversation) throws {
        try db.run("""
            INSERT INTO conversations (\(Self.convColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET title=excluded.title, model=excluded.model, provider_id=excluded.provider_id,
              provider_kind=excluded.provider_kind, updated_at=excluded.updated_at, pinned=excluded.pinned,
              last_preview=excluded.last_preview, persona_id=excluded.persona_id, system_prompt=excluded.system_prompt,
              message_count=excluded.message_count, dirty=1
            """, [.text(c.sessionId), .text(c.title), .of(c.model), .of(c.providerId), .text(c.providerKind.rawValue),
                  .of(c.createdAt), .of(c.updatedAt), .of(c.pinned), .of(c.lastMessagePreview), .of(c.personaId),
                  .of(c.systemPrompt), .of(c.messageCount)])
    }

    public func rename(_ id: String, title: String) throws {
        try db.run("UPDATE conversations SET title = ?, dirty = 1, updated_at = \(IDs.nowMs()) WHERE session_id = ?", [.text(title), .text(id)])
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws {
        try db.run("UPDATE conversations SET pinned = ?, dirty = 1 WHERE session_id = ?", [.of(pinned), .text(id)])
    }

    public func deleteConversations(_ ids: [String]) throws {
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM messages WHERE session_id = ?", [.text(id)])
                try db.run("DELETE FROM context_checkpoints WHERE session_id = ?", [.text(id)])
                try db.run("DELETE FROM conversations WHERE session_id = ?", [.text(id)])
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(id, isDirectory: true))
            }
        }
    }

    /// 根据消息表刷新会话的计数 / 预览 / 更新时间。
    public func refreshSummary(_ sessionId: String) throws {
        let rows = try db.query("SELECT COUNT(*), MAX(updated_at) FROM messages WHERE session_id = ?", [.text(sessionId)]) {
            ($0.int(0), $0.isNull(1) ? nil : $0.int64(1))
        }
        let preview = try db.query("""
            SELECT plain_text FROM messages WHERE session_id = ? AND role IN ('USER','ASSISTANT') AND plain_text != ''
            ORDER BY created_at DESC LIMIT 1
            """, [.text(sessionId)]) { $0.string(0) }.first
        let (count, last) = rows.first ?? (0, nil)
        try db.run("UPDATE conversations SET message_count = ?, last_preview = ?, updated_at = MAX(updated_at, ?) WHERE session_id = ?",
                   [.of(count), .of(preview.map { String($0.prefix(120)) }), .of(last ?? 0), .text(sessionId)])
    }

    // MARK: - 消息

    struct MessageExtra: Codable {
        var retryAttempts: [RetryAttempt]?
        var retryCurrent: Int?
        var editBranches: EditBranches?
        var metadata: [String: String]?
    }

    private static let msgColumns = "message_id,session_id,role,status,created_at,updated_at,fragments_json,model,attachments_json,stats_json,extra_json"

    private static func message(_ r: SQLiteDB.Row) -> ChatMessage {
        let extra = decodeJSON(MessageExtra.self, r.stringOrNil(10))
        return ChatMessage(messageId: r.string(0), sessionId: r.string(1), role: Role(rawValue: r.string(2)) ?? .user,
                           status: MessageStatus(rawValue: r.string(3)) ?? .complete, createdAt: r.int64(4),
                           updatedAt: r.int64(5), fragments: decodeJSON([MessageFragment].self, r.string(6)) ?? [],
                           model: r.stringOrNil(7), attachments: decodeJSON([Attachment].self, r.stringOrNil(8)) ?? [],
                           stats: decodeJSON(MessageStats.self, r.stringOrNil(9)),
                           retryAttempts: extra?.retryAttempts ?? [], retryCurrent: extra?.retryCurrent ?? 0,
                           editBranches: extra?.editBranches, metadata: extra?.metadata ?? [:])
    }

    public func messages(_ sessionId: String) -> [ChatMessage] {
        (try? db.query("SELECT \(Self.msgColumns) FROM messages WHERE session_id = ? ORDER BY created_at ASC, rowid ASC",
                       [.text(sessionId)], map: Self.message)) ?? []
    }

    public func upsert(_ m: ChatMessage) throws {
        let extra = MessageExtra(retryAttempts: m.retryAttempts.isEmpty ? nil : m.retryAttempts,
                                 retryCurrent: m.retryAttempts.isEmpty ? nil : m.retryCurrent,
                                 editBranches: m.editBranches?.value, metadata: m.metadata.isEmpty ? nil : m.metadata)
        try db.run("""
            INSERT INTO messages (\(Self.msgColumns), plain_text) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(message_id) DO UPDATE SET status=excluded.status, updated_at=excluded.updated_at,
              fragments_json=excluded.fragments_json, plain_text=excluded.plain_text, model=excluded.model,
              attachments_json=excluded.attachments_json, stats_json=excluded.stats_json, extra_json=excluded.extra_json
            """, [.text(m.messageId), .text(m.sessionId), .text(m.role.rawValue), .text(m.status.rawValue),
                  .of(m.createdAt), .of(m.updatedAt), .json(m.fragments), .of(m.model),
                  m.attachments.isEmpty ? .null : .json(m.attachments), m.stats.map { .json($0) } ?? .null,
                  .json(extra), .text(m.text)])
    }

    public func deleteMessage(_ id: String) throws {
        try db.run("DELETE FROM messages WHERE message_id = ?", [.text(id)])
    }

    /// 删除 createdAt >= 指定时间的消息（编辑重发 / 重新生成截断）。
    public func deleteMessages(sessionId: String, fromCreatedAt: Int64) throws {
        try db.run("DELETE FROM messages WHERE session_id = ? AND created_at >= ?", [.text(sessionId), .of(fromCreatedAt)])
    }

    /// 整体替换会话消息（切换编辑分支）。
    public func replaceAll(sessionId: String, with messages: [ChatMessage]) throws {
        try db.transaction {
            try db.run("DELETE FROM messages WHERE session_id = ?", [.text(sessionId)])
            for m in messages { try upsert(m) }
        }
    }

    // MARK: - 附件文件

    /// 写入附件，返回相对路径 `<sessionId>/<file>`。
    public func saveAttachment(_ data: Data, sessionId: String, fileName: String) throws -> String {
        let dir = attachmentsDir.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = fileName.replacingOccurrences(of: "/", with: "_")
        let name = "\(IDs.random(6))_\(safe)"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return "\(sessionId)/\(name)"
    }

    public func attachmentURL(_ relative: String) -> URL { attachmentsDir.appendingPathComponent(relative) }

    public func loadAttachment(_ a: Attachment) -> Data? {
        guard let p = a.localPath else { return nil }
        return try? Data(contentsOf: attachmentURL(p))
    }

    // MARK: - Provider

    public func providers() -> [ByokProvider] {
        (try? db.query("SELECT id,name,type,base_url,chat_path,models_path,enabled,models_json,headers_json,sort_order FROM byok_providers ORDER BY sort_order, updated_at DESC") { r in
            ByokProvider(id: r.string(0), name: r.string(1), type: ByokProviderType(rawValue: r.string(2)) ?? .openAICompat,
                         baseUrl: r.string(3), chatPath: r.string(4), modelsPath: r.string(5), enabled: r.bool(6),
                         models: decodeJSON([ProviderModel].self, r.string(7)) ?? [],
                         customHeaders: decodeJSON([CustomHeader].self, r.string(8)) ?? [], sortOrder: r.int(9))
        }) ?? []
    }

    public func upsert(_ p: ByokProvider) throws {
        try db.run("""
            INSERT INTO byok_providers (id,name,type,base_url,chat_path,models_path,enabled,models_json,headers_json,sort_order,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, type=excluded.type, base_url=excluded.base_url,
              chat_path=excluded.chat_path, models_path=excluded.models_path, enabled=excluded.enabled,
              models_json=excluded.models_json, headers_json=excluded.headers_json, sort_order=excluded.sort_order,
              updated_at=excluded.updated_at
            """, [.text(p.id), .text(p.name), .text(p.type.rawValue), .text(p.baseUrl), .text(p.chatPath), .text(p.modelsPath),
                  .of(p.enabled), .json(p.models), .json(p.customHeaders), .of(p.sortOrder), .of(IDs.nowMs())])
    }

    public func deleteProvider(_ id: String) throws {
        try db.run("DELETE FROM byok_providers WHERE id = ?", [.text(id)])
    }

    // MARK: - 角色

    public func personas() -> [Persona] {
        (try? db.query("""
            SELECT id,name,icon,system_prompt,default_thinking,default_effort,sort_order,pinned,is_builtin,created_at,updated_at,profile_json,avatar_path
            FROM personas WHERE deleted_at IS NULL ORDER BY pinned DESC, sort_order, name
            """) { r in
            Persona(id: r.string(0), name: r.string(1), icon: r.stringOrNil(2), systemPrompt: r.string(3),
                    defaultEnableThinking: r.isNull(4) ? nil : r.bool(4), defaultReasoningEffort: r.stringOrNil(5),
                    sortOrder: r.int(6), pinned: r.bool(7), isBuiltin: r.bool(8), createdAt: r.int64(9),
                    updatedAt: r.int64(10), profileJson: r.stringOrNil(11), avatarPath: r.stringOrNil(12))
        }) ?? []
    }

    public func upsert(_ p: Persona) throws {
        try db.run("""
            INSERT INTO personas (id,name,icon,system_prompt,default_thinking,default_effort,sort_order,pinned,is_builtin,created_at,updated_at,profile_json,avatar_path,deleted_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, icon=excluded.icon, system_prompt=excluded.system_prompt,
              default_thinking=excluded.default_thinking, default_effort=excluded.default_effort, sort_order=excluded.sort_order,
              pinned=excluded.pinned, updated_at=excluded.updated_at, profile_json=excluded.profile_json, avatar_path=excluded.avatar_path, deleted_at=NULL
            """, [.text(p.id), .text(p.name), .of(p.icon), .text(p.systemPrompt),
                  p.defaultEnableThinking.map { .of($0) } ?? .null, .of(p.defaultReasoningEffort), .of(p.sortOrder),
                  .of(p.pinned), .of(p.isBuiltin), .of(p.createdAt), .of(p.updatedAt), .of(p.profileJson), .of(p.avatarPath)])
    }

    public func deletePersona(_ id: String) throws {
        try db.run("UPDATE personas SET deleted_at = ? WHERE id = ? AND is_builtin = 0", [.of(IDs.nowMs()), .text(id)])
    }

    private func seedBuiltinPersonas() throws {
        let existing = Set((try? db.query("SELECT id FROM personas") { $0.string(0) }) ?? [])
        for p in Persona.builtins() where !existing.contains(p.id) { try upsert(p) }
    }
}
