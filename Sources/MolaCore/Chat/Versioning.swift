import Foundation

/// 重新生成版本 & 编辑分支的纯逻辑（对应安卓 RetryAttempts.kt / EditSnapshots.kt / ChatRepository.navigateEditSnapshot）。
public enum Versioning {
    // MARK: 重新生成（助手消息内的版本列表）

    /// 开始重新生成：把当前内容存进当前槽位，追加一个新槽位并切过去，清空内容。
    public static func beginRegenerate(_ msg: ChatMessage, model: String?) -> ChatMessage {
        var m = msg
        var slots = m.retryAttempts
        if slots.isEmpty { slots = [m.asRetryAttempt] } else { slots[clamp(m.retryCurrent, slots.count)] = m.asRetryAttempt }
        m.fragments = []
        m.stats = nil
        m.status = .streaming
        m.model = model
        m.updatedAt = IDs.nowMs()
        slots.append(m.asRetryAttempt)
        m.retryAttempts = slots
        m.retryCurrent = slots.count - 1
        return m
    }

    /// 生成结束：把最终内容写回当前槽位。
    public static func commitCurrent(_ msg: ChatMessage) -> ChatMessage {
        var m = msg
        guard !m.retryAttempts.isEmpty else { return m }
        m.retryAttempts[clamp(m.retryCurrent, m.retryAttempts.count)] = m.asRetryAttempt
        return m
    }

    /// 切换到第 index 个版本（0-based）。
    public static func selectVersion(_ msg: ChatMessage, _ index: Int) -> ChatMessage {
        var m = commitCurrent(msg)
        guard m.retryAttempts.indices.contains(index) else { return m }
        let a = m.retryAttempts[index]
        m.fragments = a.fragments; m.model = a.model; m.status = a.status; m.stats = a.stats
        m.retryCurrent = index
        return m
    }

    // MARK: 编辑分支（用户消息上的整段尾部快照）

    static func stripBranches(_ m: ChatMessage) -> ChatMessage {
        var c = m; c.editBranches = nil; return c
    }

    /// 编辑重发：保留 `[0, idx)`，用 `newHead` 替换 `idx` 起的尾部。
    /// 返回新时间线（尾部只剩 newHead，助手回答随后流式生成）。
    public static func applyEdit(_ messages: [ChatMessage], at idx: Int, newText: String,
                                 attachments: [Attachment]? = nil) -> [ChatMessage] {
        guard messages.indices.contains(idx) else { return messages }
        let oldHead = messages[idx]
        let oldTail = Array(messages[idx...]).enumerated().map { $0.offset == 0 ? stripBranches($0.element) : $0.element }
        var branches = oldHead.editBranches?.value
            ?? EditBranches(currentIndex: 0, versions: [EditSnapshot(label: "原始", conversationHistory: oldTail)])
        branches.versions[clamp(branches.currentIndex, branches.versions.count)].conversationHistory = oldTail

        var head = ChatMessage(sessionId: oldHead.sessionId, role: .user, status: .complete,
                               fragments: [.text(id: IDs.fragment(), markdown: newText)],
                               attachments: attachments ?? oldHead.attachments)
        head.createdAt = max(oldHead.createdAt, (messages[..<idx].last?.createdAt ?? 0) + 1)
        head.updatedAt = IDs.nowMs()
        branches.versions.append(EditSnapshot(label: "编辑 \(branches.versions.count)", conversationHistory: [head]))
        branches.currentIndex = branches.versions.count - 1
        head.editBranches = Box(branches)
        return Array(messages[..<idx]) + [head]
    }

    /// 切换编辑分支：把当前尾部存回槽位，载入目标槽位的尾部。
    public static func selectBranch(_ messages: [ChatMessage], at idx: Int, to target: Int) -> [ChatMessage] {
        guard messages.indices.contains(idx), var branches = messages[idx].editBranches?.value,
              branches.versions.indices.contains(target) else { return messages }
        let currentTail = Array(messages[idx...]).enumerated().map { $0.offset == 0 ? stripBranches($0.element) : $0.element }
        branches.versions[clamp(branches.currentIndex, branches.versions.count)].conversationHistory = currentTail
        branches.currentIndex = target
        var tail = branches.versions[target].conversationHistory
        guard !tail.isEmpty else { return messages }
        tail[0].editBranches = Box(branches)
        return Array(messages[..<idx]) + tail
    }

    /// 尾部消息写回分支槽位（流式结束后调用，保证槽位内容最新）。
    public static func syncBranchSlot(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let idx = messages.lastIndex(where: { $0.role == .user && $0.editBranches != nil }),
              var branches = messages[idx].editBranches?.value else { return messages }
        let tail = Array(messages[idx...]).enumerated().map { $0.offset == 0 ? stripBranches($0.element) : $0.element }
        branches.versions[clamp(branches.currentIndex, branches.versions.count)].conversationHistory = tail
        var out = messages
        out[idx].editBranches = Box(branches)
        return out
    }

    static func clamp(_ i: Int, _ count: Int) -> Int { min(max(i, 0), max(count - 1, 0)) }
}
