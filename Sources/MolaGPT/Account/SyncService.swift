import Foundation
import Observation
import MolaCore
import MolaStorage

/// 云同步（对应安卓 SyncEngine）：推墓碑 → 推 dirty → full_sync 合并元数据（不拉正文）→ 打开占位会话时懒加载。
@MainActor
@Observable
final class SyncService {
    @ObservationIgnored unowned let app: AppModel
    private(set) var syncing = false
    private(set) var lastSyncAt: Date?
    var lastError: String?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private let cursorKey = "molagpt.sync_cursor"

    init(app: AppModel) { self.app = app }

    private var store: MolaStore { app.store }
    private var enabled: Bool { app.settings.cloudSyncEnabled && app.account.isLoggedIn }

    func register() {
        app.account.onLoginChanged.append { [unowned self] loggedIn in
            if loggedIn { self.syncNow() } else { UserDefaults.standard.removeObject(forKey: self.cursorKey) }
        }
        app.foregroundHooks.append { [unowned self] in self.syncNow() }
        app.turnPlanner.afterTurnHooks.append { [unowned self] c in self.schedulePush(c.conversation.sessionId) }
    }

    /// 对话完成、重命名、删除后 2 秒防抖推送（仅官方会话）。
    func schedulePush(_ sessionId: String? = nil) {
        guard enabled else { return }
        if let id = sessionId, store.conversation(id)?.providerKind != .molagpt { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    func syncNow(force: Bool = false) {
        guard force ? app.account.isLoggedIn : enabled else { return }
        Task { await run() }
    }

    func run() async {
        guard !syncing, app.account.isLoggedIn else { return }
        syncing = true
        defer { syncing = false }
        let session = app.account.session
        do {
            // 1. 墓碑：云端确认后才物理删除
            let dead = store.tombstones()
            if !dead.isEmpty {
                let r = try await session.authedPost(MolaEndpoints.sync, ["action": "delete", "conversation_ids": .array(dead.map { .string(MolaChatAPI.conversationId($0)) })])
                if MolaJSON.bool(r["success"]) == true { try? store.deleteConversations(dead) }
            }
            // 2. dirty
            let cursor = UserDefaults.standard.string(forKey: cursorKey) ?? SyncMapper.epoch
            let dirty = store.syncCandidates(all: cursor == SyncMapper.epoch)
            let payload: [JSONValue] = dirty.map { c in
                ["metadata": SyncMapper.metadata(c), "messages": .array(SyncMapper.messages(store.messages(c.sessionId)))]
            }
            let r = try await session.authedPost(MolaEndpoints.sync, ["action": "full_sync", "last_sync_timestamp": .string(cursor),
                                                                      "dirty_conversations": .array(payload)], timeout: 120)
            guard MolaJSON.bool(r["success"]) != false else { throw MolaSession.SessionError.http(0, r["message"]?.stringValue ?? "同步失败") }
            try? store.markClean(dirty.map(\.sessionId))
            // 3. 合并元数据
            for m in r["full_metadata_list"]?.arrayValue ?? [] {
                guard let cid = m["id"]?.stringValue else { continue }
                let sid = MolaChatAPI.sessionId(cid)
                let created = SyncMapper.ms(m["time"]?.stringValue) ?? IDs.nowMs()
                let updated = SyncMapper.ms(m["updated_at"]?.stringValue) ?? created
                try? store.mergeCloud(sessionId: sid, title: m["title"]?.stringValue ?? Conversation.defaultTitle,
                                      model: m["model"]?.stringValue, createdAt: created, updatedAt: updated)
            }
            if let next = r["new_sync_timestamp"]?.stringValue { UserDefaults.standard.set(next, forKey: cursorKey) }
            lastSyncAt = Date()
            lastError = nil
            app.reloadConversations()
        } catch MolaSession.SessionError.expired {
            app.account.handleExpired()
        } catch {
            lastError = "同步失败：\(error.localizedDescription)"
        }
    }

    /// 打开占位会话时拉取全部消息。
    func loadIfPlaceholder(_ sessionId: String) async -> [ChatMessage]? {
        guard store.isPlaceholder(sessionId), app.account.isLoggedIn else { return nil }
        do {
            let r = try await app.account.session.authedPost(MolaEndpoints.sync, ["action": "fetch_conversation", "conversation_id": .string(MolaChatAPI.conversationId(sessionId))])
            let msgs = SyncMapper.fromCloud(r["conversation"]?["messages"]?.arrayValue ?? [], sessionId: sessionId)
            try store.markLoaded(sessionId, messages: msgs)
            return msgs
        } catch {
            lastError = "加载云端对话失败：\(error.localizedDescription)"
            return nil
        }
    }
}
