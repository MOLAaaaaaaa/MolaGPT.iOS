import SwiftUI
import Observation
import UniformTypeIdentifiers
import MolaCore
import MolaStorage

/// 单个会话的状态与动作（对应安卓 ChatViewModel + BackgroundStreamManager）。
@MainActor
@Observable
final class ChatController {
    @ObservationIgnored private weak var app: AppModel?

    var conversation: Conversation
    private(set) var messages: [ChatMessage]

    // Composer 状态
    var draft = ""
    var pendingAttachments: [Attachment] = []
    private(set) var editingMessageId: String?
    var useThinking: Bool
    /// 输入栏「联网」开关（本会话；默认取设置）。
    var webEnabled: Bool { didSet { app?.settings.byokWebEnabled = webEnabled } }
    /// 输入栏「生成图像」开关（本会话）。
    var imageGenEnabled = true
    var reasoningEffort: String
    var errorBanner: String?

    private(set) var streamingMessageId: String?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// 会话行是否已落库（首次发送时才写入，空白会话不进列表）。
    @ObservationIgnored private var persisted: Bool

    var isStreaming: Bool { streamingMessageId != nil }

    init(app: AppModel, conversation: Conversation, messages: [ChatMessage] = []) {
        self.app = app
        self.conversation = conversation
        self.messages = messages
        self.persisted = !messages.isEmpty || app.store.conversation(conversation.sessionId) != nil
        self.useThinking = app.settings.useThinking
        self.reasoningEffort = app.settings.reasoningEffort
        self.webEnabled = app.settings.byokWebEnabled
        // 冷启动时残留的 STREAMING 状态视为已停止。
        for i in self.messages.indices where self.messages[i].status == .streaming || self.messages[i].status == .pending {
            self.messages[i].status = .stopped
        }
    }

    func resetToDefaults(_ c: Conversation) {
        conversation = c
        draft = ""
        pendingAttachments = []
        editingMessageId = nil
        errorBanner = nil
    }

    // MARK: - 模型 / 角色

    var selection: (provider: ByokProvider, model: ProviderModel)? {
        guard let app else { return nil }
        if let r = app.resolve(conversation.modelKey) { return r }
        return app.defaultModel
    }

    var isOfficial: Bool { selection?.provider.id == MolaVirtualProvider.id }
    @ObservationIgnored private var streamSessionId: String?

    func selectModel(_ provider: ByokProvider, _ model: ProviderModel) {
        conversation.providerKind = provider.id == MolaVirtualProvider.id ? .molagpt : .byok
        conversation.providerId = provider.id
        conversation.model = model.id
        app?.settings.defaultModel = ModelKey(providerId: provider.id, modelId: model.id).description
        if let t = model.effectiveThinking(baseUrl: provider.baseUrl) {
            let levels = Thinking.resolveEffortLevels(t, baseUrl: provider.baseUrl)
            if !levels.isEmpty && !levels.contains(reasoningEffort) {
                reasoningEffort = Thinking.resolveDefaultEffort(t, baseUrl: provider.baseUrl)
            }
        }
        persistConversation()
    }

    /// 当前模型的推理配置（nil = 不支持推理）。
    var thinkingConfig: ThinkingConfig? {
        guard let (p, m) = selection else { return nil }
        return m.effectiveThinking(baseUrl: p.baseUrl)
    }

    var thinkingAlwaysOn: Bool {
        guard let (p, _) = selection, let t = thinkingConfig else { return false }
        return Thinking.isAlwaysOn(t, baseUrl: p.baseUrl)
    }

    var effortLevels: [String] {
        guard let (p, _) = selection, let t = thinkingConfig else { return [] }
        return Thinking.resolveEffortLevels(t, baseUrl: p.baseUrl)
    }

    /// 生效的角色（对应安卓 activePersona）：只用于 BYOK；未选择或所选角色已删除时回退到内置「通用助手」。
    /// 官方模型的系统提示词由服务端管理，不使用角色。
    var persona: Persona? {
        guard let app, !isOfficial else { return nil }
        return app.persona(conversation.personaId) ?? app.persona(Persona.builtinDefaultId)
    }

    /// 用户明确选择的角色；未选择、选的是「通用助手」或官方模型时为 nil，界面按「无角色」显示。
    var chosenRole: Persona? {
        guard let p = persona, p.id != Persona.builtinDefaultId, conversation.personaId != nil else { return nil }
        return p
    }

    /// 选择角色；传 nil（或「通用助手」）即不使用角色。
    func selectPersona(_ p: Persona?) {
        let newId = p.flatMap { $0.id == Persona.builtinDefaultId ? nil : $0.id }
        let changed = conversation.personaId != newId
        conversation.personaId = newId
        if let on = p?.defaultEnableThinking { useThinking = on }
        if let e = p?.defaultReasoningEffort { reasoningEffort = e }
        persistConversation()
        if changed { removeGreetingIfAlone() }
        app?.roleEngine.ensureGreeting(self)
    }

    /// 角色开场白：作为首条助手消息写入；多条开场白放进版本切换（‹ 1/3 ›）。
    func insertGreeting(_ texts: [String]) {
        guard messages.isEmpty, let first = texts.first, let app else { return }
        let now = IDs.nowMs()
        var m = ChatMessage(sessionId: conversation.sessionId, role: .assistant, status: .complete, createdAt: now,
                            fragments: [.text(id: IDs.fragment(), markdown: first)], metadata: ["role_greeting": "1"])
        if texts.count > 1 {
            m.retryAttempts = texts.map { RetryAttempt(fragments: [.text(id: IDs.fragment(), markdown: $0)], model: nil, status: .complete, stats: nil, createdAt: now) }
            m.retryCurrent = 0
        }
        messages.append(m)
        ensurePersisted()
        try? app.store.upsert(m)
        try? app.store.refreshSummary(conversation.sessionId)
    }

    /// 换角色时，若对话里只有上一个角色的开场白，就把它移除。
    private func removeGreetingIfAlone() {
        guard messages.count == 1, messages[0].metadata["role_greeting"] == "1" else { return }
        try? app?.store.deleteMessage(messages[0].messageId)
        messages.removeAll()
    }

    /// 导出为 Markdown（分享用）。
    /// 分享对话的纯文本（与安卓 ShareHelper.shareConversation 一致）：
    /// 「# 标题」后逐条「**我：**」/「**MolaGPT：**」+ 正文；不含思考、图片、模型名。
    func shareText() -> String {
        var out = "# \(conversation.title)\n\n"
        for m in messages where m.role == .user || m.role == .assistant {
            out += m.role == .user ? "**我：**\n" : "**MolaGPT：**\n"
            out += m.text + "\n\n"
        }
        return out
    }

    /// 本会话累计花费。
    var totalCost: Double? {
        let costs = messages.compactMap { $0.stats?.costUsd }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    // MARK: - 发送

    var canSend: Bool {
        !isStreaming && (draft.nonBlank != nil || !pendingAttachments.isEmpty)
    }

    func send() {
        guard canSend, let app else { return }
        guard let (provider, model) = selection else {
            errorBanner = "请先在设置中添加模型服务并选择模型"
            return
        }
        if provider.apiKey?.nonBlank == nil && provider.type != .openAICompat {
            errorBanner = "「\(provider.name)」未设置 API Key"
            return
        }
        if pendingAttachments.contains(where: \.isImage) && !model.supportsVision {
            errorBanner = "当前模型未标注视觉能力，图片可能无法被理解（可在模型设置中开启「视觉」）"
        } else {
            errorBanner = nil
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []

        if let editId = editingMessageId, let idx = messages.firstIndex(where: { $0.messageId == editId }) {
            editingMessageId = nil
            let next = Versioning.applyEdit(messages, at: idx, newText: text, attachments: attachments.isEmpty ? nil : attachments)
            let removed = messages[idx...].map(\.messageId)
            messages = next
            for id in removed { try? app.store.deleteMessage(id) }
            ensurePersisted()
            try? app.store.upsert(messages[idx])
        } else {
            editingMessageId = nil
            ensurePersisted()
            let user = ChatMessage(sessionId: conversation.sessionId, role: .user, createdAt: nextTimestamp(),
                                   fragments: text.isEmpty ? [] : [.text(id: IDs.fragment(), markdown: text)],
                                   attachments: attachments)
            messages.append(user)
            try? app.store.upsert(user)
        }
        startAssistant(provider: provider, model: model)
    }

    private func nextTimestamp() -> Int64 { max(IDs.nowMs(), (messages.last?.createdAt ?? 0) + 1) }

    private func startAssistant(provider: ByokProvider, model: ProviderModel) {
        let assistant = ChatMessage(sessionId: conversation.sessionId, role: .assistant, status: .streaming,
                                    createdAt: nextTimestamp(), model: model.id)
        messages.append(assistant)
        let history = Array(messages.dropLast())
        runStream(assistantId: assistant.messageId, history: history, provider: provider, model: model)
    }

    // MARK: - 重新生成 / 版本

    func canRegenerate(_ m: ChatMessage) -> Bool {
        !isStreaming && m.role == .assistant && messages.last?.messageId == m.messageId && m.metadata["role_greeting"] != "1"
    }

    func regenerate(_ messageId: String, using override: (ByokProvider, ProviderModel)? = nil) {
        guard !isStreaming, let idx = messages.firstIndex(where: { $0.messageId == messageId }),
              let (provider, model) = override ?? selection else { return }
        if let override { selectModel(override.0, override.1) }
        messages[idx] = Versioning.beginRegenerate(messages[idx], model: model.id)
        // 删除其后的消息（理论上只有最后一条能重新生成）
        if idx + 1 < messages.count {
            for m in messages[(idx + 1)...] { try? app?.store.deleteMessage(m.messageId) }
            messages.removeSubrange((idx + 1)...)
        }
        runStream(assistantId: messageId, history: Array(messages[..<idx]), provider: provider, model: model)
    }

    func selectVersion(_ messageId: String, _ index: Int) {
        guard !isStreaming, let idx = messages.firstIndex(where: { $0.messageId == messageId }) else { return }
        messages[idx] = Versioning.selectVersion(messages[idx], index)
        try? app?.store.upsert(messages[idx])
        syncBranchSlotAndSave()
    }

    // MARK: - 编辑分支

    func startEdit(_ messageId: String) {
        guard !isStreaming, let m = messages.first(where: { $0.messageId == messageId }), m.role == .user else { return }
        editingMessageId = messageId
        draft = m.text
        pendingAttachments = m.attachments
    }

    func cancelEdit() {
        editingMessageId = nil
        draft = ""
        pendingAttachments = []
    }

    func selectBranch(_ messageId: String, _ index: Int) {
        guard !isStreaming, let app, let idx = messages.firstIndex(where: { $0.messageId == messageId }) else { return }
        messages = Versioning.selectBranch(messages, at: idx, to: index)
        try? app.store.replaceAll(sessionId: conversation.sessionId, with: messages)
        try? app.store.refreshSummary(conversation.sessionId)
        app.reloadConversations()
    }

    /// 直接修改助手回答（BYOK）。
    func editAssistant(_ messageId: String, newText: String) {
        guard let idx = messages.firstIndex(where: { $0.messageId == messageId }) else { return }
        var m = messages[idx]
        let thinking = m.fragments.filter { if case .thinking = $0 { return true }; return false }
        m.fragments = thinking + [.text(id: IDs.fragment(), markdown: newText)]
        m.updatedAt = IDs.nowMs()
        messages[idx] = Versioning.commitCurrent(m)
        try? app?.store.upsert(messages[idx])
        syncBranchSlotAndSave()
    }

    func deleteMessage(_ messageId: String) {
        guard !isStreaming, let idx = messages.firstIndex(where: { $0.messageId == messageId }) else { return }
        messages.remove(at: idx)
        try? app?.store.deleteMessage(messageId)
        try? app?.store.refreshSummary(conversation.sessionId)
        app?.reloadConversations()
    }

    private func syncBranchSlotAndSave() {
        let synced = Versioning.syncBranchSlot(messages)
        if let idx = synced.lastIndex(where: { $0.editBranches != nil }), synced[idx] != messages[idx] {
            messages = synced
            try? app?.store.upsert(messages[idx])
        }
    }

    // MARK: - 流式

    /// 懒加载云端消息后替换。
    func replaceMessages(_ list: [ChatMessage]) {
        guard !isStreaming else { return }
        messages = list
    }

    /// 官方模型：用户开始输入时预取短 token，发送时省掉 challenge → 解题 → auth 这几步。
    func prewarmToken() {
        guard isOfficial, !isStreaming else { return }
        Task { await MolaSession.shared.prewarm() }
    }

    func stop() {
        streamTask?.cancel()
        if isOfficial, let sid = streamSessionId, let app {
            let chat = app.molaChat
            Task { await chat.stop(sid) }
        }
    }

    private func runStream(assistantId: String, history: [ChatMessage], provider: ByokProvider, model: ProviderModel) {
        guard let app else { return }
        let client = app.client
        let isFirstRound = !history.contains { $0.role == .assistant && $0.status == .complete }
        streamingMessageId = assistantId
        LiveActivityCenter.shared.start(key: assistantId, kind: .chat, targetId: conversation.sessionId,
                                        title: conversation.title, model: model.displayName, phase: .thinking)
        // 切到后台时向系统申请额外运行时间（灵动岛机型上为持续后台任务，其余约 30 秒）。
        // 时间用完时不主动取消：先把已收内容落库，请求继续跑到系统真正挂起为止；
        // 很快回到前台时连接可能还在，可以接着生成完；连接断开才结束（官方模型会按 offset 续传）。
        let official = provider.id == MolaVirtualProvider.id
        let bg = BackgroundGuard(name: "mola.stream", title: ContinuedWork.chatTitle) { [weak self] _ in
            guard let self else { return }
            if let idx = self.messages.firstIndex(where: { $0.messageId == assistantId }) {
                try? self.app?.store.upsert(self.messages[idx])
            }
        }

        streamTask = Task { [weak self] in
            defer { bg.end() }
            var acc = StreamAccumulator()
            var lastUI = Date.distantPast
            var lastDB = Date()
            var status = MessageStatus.complete
            var retriedOverflow = false
            // 发送前：超过阈值先自动压缩（失败不阻塞对话；官方模型由服务端管理上下文）。
            if let self, !official, app.compaction.shouldAutoCompact(self, history: history, model: model) {
                await app.compaction.compact(self, history: history, provider: provider, model: model, reason: .threshold)
            }
            while true {
                guard let self else { return }
                let plan = app.turnPlanner.plan(controller: self, history: history, provider: provider, model: model)
                var request = ChatRequest(provider: provider, model: model, system: plan.system, messages: plan.messages,
                                          temperature: app.settings.temperature, useThinking: self.useThinking || self.thinkingAlwaysOn,
                                          reasoningEffort: self.reasoningEffort)
                request.tools = plan.tools
                do {
                    let events: AsyncThrowingStream<StreamEvent, Error>
                    if official, let mm = app.account.model(model.id) {
                        let sid = IDs.generic("stream")
                        self.streamSessionId = sid
                        let options = MolaChatOptions(sessionId: self.conversation.sessionId, conversationId: MolaChatAPI.conversationId(self.conversation.sessionId),
                                                      streamSessionId: sid, model: mm, temperature: app.settings.temperature,
                                                      useThinking: self.useThinking && model.supportsThinking,
                                                      reasoningEffort: model.thinkingConfig?.effortLevels.isEmpty == false ? self.reasoningEffort : nil,
                                                      network: app.settings.toolNetwork && self.webEnabled, code: app.settings.toolCode)
                        let wire = ContextBuilder.wireMessages(history, options: .init(username: app.settings.username.nonBlank ?? "用户"),
                                                               loader: { app.store.loadAttachment($0) })
                        events = app.molaChat.stream(options: options, messages: wire)
                    } else {
                        events = client.stream(request, executor: plan.executor)
                    }
                    for try await event in events {
                        acc.apply(event)
                        let now = Date()
                        if now.timeIntervalSince(lastUI) > 0.06 {
                            self.update(assistantId, acc, status: .streaming, persist: now.timeIntervalSince(lastDB) > 1.5)
                            if now.timeIntervalSince(lastDB) > 1.5 { lastDB = now }
                            lastUI = now
                        }
                    }
                    if Task.isCancelled { status = .stopped }
                    else if let err = acc.error {
                        acc.appendError(err); status = .error
                    } else if !acc.hasContent {
                        acc.appendError("模型没有返回内容"); status = .error
                    }
                } catch is CancellationError {
                    status = .stopped
                } catch let e as URLError where e.code == .cancelled {
                    status = .stopped
                } catch ProviderError.http(let code, let body) where !retriedOverflow && !acc.hasContent && ContextOverflow.isOverflow(body) {
                    // 服务商以超长拒绝：用最激进的切点压缩后重试一次。
                    retriedOverflow = true
                    _ = code
                    if await app.compaction.compact(self, history: history, provider: provider, model: model, reason: .overflow,
                                                    declaredWindow: ContextOverflow.declaredWindow(body)) {
                        continue
                    }
                    acc.appendError(ProviderError.http(status: code, body: body).localizedDescription)
                    status = .error
                } catch MolaSession.SessionError.expired {
                    app.account.handleExpired()
                    acc.appendError("登录已过期，请重新登录")
                    status = .error
                } catch {
                    acc.appendError(bg.expired && error is URLError
                                    ? "应用在后台被系统挂起，连接已断开。可以重新生成。"
                                    : error.localizedDescription)
                    status = .error
                }
                break
            }
            self?.finish(assistantId, acc, status: status, pricing: model.pricing, modelId: model.id,
                         titleContext: isFirstRound && status == .complete ? (provider, model) : nil)
        }
    }

    private func update(_ id: String, _ acc: StreamAccumulator, status: MessageStatus, persist: Bool) {
        guard let idx = messages.firstIndex(where: { $0.messageId == id }) else { return }
        messages[idx].fragments = acc.fragments
        messages[idx].status = status
        messages[idx].updatedAt = IDs.nowMs()
        if persist { try? app?.store.upsert(messages[idx]) }
        LiveActivityCenter.shared.updateChat(key: id, fragments: acc.fragments)
    }

    private func finish(_ id: String, _ acc: StreamAccumulator, status: MessageStatus, pricing: ModelPricing?,
                        modelId: String, titleContext: (ByokProvider, ProviderModel)?) {
        streamTask = nil
        streamingMessageId = nil
        LiveActivityCenter.shared.endChat(key: id, status: status, fragments: acc.fragments)
        guard let app, let idx = messages.firstIndex(where: { $0.messageId == id }) else { return }
        var m = messages[idx]
        m.fragments = acc.fragments
        m.status = status
        m.updatedAt = IDs.nowMs()
        m.stats = acc.stats(pricing: pricing, modelId: modelId)
        if let h = acc.wireHistory { m.metadata[WireHistory.metadataKey] = h.encoded } else { m.metadata[WireHistory.metadataKey] = nil }
        if status == .complete { m.fragments = app.turnPlanner.postProcess(m.fragments, banner: { [weak self] in self?.errorBanner = $0 }) }
        m = Versioning.commitCurrent(m)
        messages[idx] = m
        try? app.store.upsert(m)
        syncBranchSlotAndSave()
        try? app.store.refreshSummary(conversation.sessionId)
        if let (p, mdl) = titleContext, conversation.title == Conversation.defaultTitle {
            generateTitle(provider: p, model: mdl)
        }
        app.streamFinished(self)
        if status == .complete { app.turnPlanner.afterTurn(controller: self) }
    }

    private func generateTitle(provider: ByokProvider, model: ProviderModel) {
        guard let app else { return }
        let firstUser = messages.first { $0.role == .user }?.text ?? ""
        let fallback = Titler.fallback(firstUserText: firstUser)
        guard app.settings.autoTitleEnabled else { applyTitle(fallback); return }
        var target = (provider, model)
        if let r = app.resolve(ModelKey(app.settings.titleModelKey)) { target = r }
        let window = messages.map { (role: $0.role, text: $0.text) }
        let client = app.client
        applyTitle(fallback)
        if target.0.id == MolaVirtualProvider.id {
            let chat = app.molaChat
            let answer = messages.last { $0.role == .assistant }?.text ?? ""
            Task { [weak self] in if let t = await chat.title(user: firstUser, answer: answer) { self?.applyTitle(t) } }
            return
        }
        Task { [weak self] in
            if let t = await client.generateTitle(provider: target.0, model: target.1, messages: window) {
                self?.applyTitle(t)
            }
        }
    }

    private func applyTitle(_ t: String) {
        conversation.title = t
        try? app?.store.rename(conversation.sessionId, title: t)
        app?.reloadConversations()
    }

    // MARK: - 持久化

    private func ensurePersisted() {
        guard let app else { return }
        if conversation.providerId == nil, let (p, m) = selection {
            conversation.providerId = p.id; conversation.model = m.id
        }
        conversation.updatedAt = IDs.nowMs()
        try? app.store.upsert(conversation)
        persisted = true
        app.reloadConversations()
    }

    private func persistConversation() {
        guard persisted else { return }
        try? app?.store.upsert(conversation)
    }

    // MARK: - 附件

    func addAttachment(data: Data, name: String, mimeType: String, extractedText: String? = nil) {
        guard let app else { return }
        do {
            let path = try app.store.saveAttachment(data, sessionId: conversation.sessionId, fileName: name)
            pendingAttachments.append(Attachment(name: name, mimeType: mimeType, localPath: path,
                                                 sizeBytes: Int64(data.count), extractedText: extractedText))
        } catch {
            errorBanner = "保存附件失败：\(error.localizedDescription)"
        }
    }

    func removeAttachment(_ id: String) { pendingAttachments.removeAll { $0.id == id } }

    /// 本地文件 → 附件：图片压缩为 JPEG，其余抽取文字（PDF / docx / 文本）。文件选择器与分享收件箱共用。
    @discardableResult
    func importFile(_ url: URL, displayName: String? = nil) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let name = displayName ?? url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let img = UIImage(data: data), let (jpeg, mime) = ImageProcessing.prepare(img) {
            addAttachment(data: jpeg, name: (name as NSString).deletingPathExtension + ".jpg", mimeType: mime)
            return true
        }
        guard let text = DocumentText.extract(data: data, url: url) else {
            errorBanner = "无法读取「\(name)」的文字内容"
            return false
        }
        addAttachment(data: data, name: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream", extractedText: text)
        return true
    }

    func attachmentURL(_ a: Attachment) -> URL? { a.localPath.map { app?.store.attachmentURL($0) } ?? nil }
}

// MARK: - 角色卡提示词（角色扮演体系接入点）
extension ChatController {
    /// 角色卡（PersonaProfile）存在时返回组装后的角色提示；否则 nil，走普通系统提示。
    func rolePrompt(provider: ByokProvider, model: ProviderModel, history: [ChatMessage]) -> String? {
        app?.roleEngine.systemPrompt(for: self, provider: provider, model: model, history: history)
    }
}
