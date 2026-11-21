import SwiftUI
import Observation
import MolaCore
import MolaStorage

/// 应用级状态容器（对应安卓 Hilt 注入的各 Repository + MainActivity 状态）。
@MainActor
@Observable
final class AppModel {
    let store: MolaStore
    let client = ChatClient()
    let mcp = McpClient()
    let account = AccountManager()
    @ObservationIgnored private(set) lazy var turnPlanner = TurnPlanner(app: self)
    @ObservationIgnored private(set) lazy var roleEngine = RoleEngine(app: self)
    @ObservationIgnored private(set) lazy var memory = MemoryService(app: self)
    @ObservationIgnored private(set) lazy var compaction = CompactionService(app: self)
    @ObservationIgnored private(set) lazy var skills = SkillService(app: self)
    @ObservationIgnored private(set) lazy var sync = SyncService(app: self)
    @ObservationIgnored private(set) lazy var notifier = CompletionNotifier(app: self)
    @ObservationIgnored private(set) lazy var images = ImageTaskManager(app: self)
    @ObservationIgnored private(set) lazy var agents = AgentControlModel(app: self)
    @ObservationIgnored private(set) lazy var desktops = DesktopRemoteService(app: self)
    /// 待展示的运营消息。
    var pendingNotice: OpsMessage?
    /// 画图工作台（通知点按、顶栏入口打开）。
    var showImageWorkbench = false
    var imageTaskToOpen: String?
    /// 自增即让 iPhone 切到聊天栏（分享导入、通知等）。
    var chatFocusToken = 0
    var startupError: String?
    /// 回到前台时执行的钩子（同步、远程等子系统注册）。
    @ObservationIgnored var foregroundHooks: [@MainActor () -> Void] = []

    var settings: AppSettings {
        didSet { if settings != oldValue { SettingsStore.save(settings) } }
    }

    private(set) var providers: [ByokProvider] = []
    private(set) var personas: [Persona] = []
    private(set) var conversations: [Conversation] = []
    var searchText = "" { didSet { reloadConversations() } }

    /// 设置 sheet 与其内部导航路径。
    var showSettings = false
    var settingsPath: [SettingsRoute] = []

    func openSettings(_ route: SettingsRoute? = nil) {
        settingsPath = route.map { [$0] } ?? []
        showSettings = true
    }

    /// 当前显示的会话控制器。
    private(set) var current: ChatController!
    /// 仍在流式输出的会话控制器（切换会话不中断）。
    private var controllers: [String: ChatController] = [:]

    init(store: MolaStore, startupError: String? = nil) {
        self.store = store
        self.startupError = startupError
        self.settings = SettingsStore.load()
        reloadProviders()
        reloadPersonas()
        reloadConversations()
        current = ChatController(app: self, conversation: makeConversation())
        memory.register(on: turnPlanner)
        Task { await account.refresh() }
        compaction.register(on: turnPlanner)
        skills.register(on: turnPlanner)
        roleEngine.register(on: turnPlanner)
        sync.register()
        notifier.register(on: turnPlanner)
        // 通知权限改为启动时申请（LaunchPermissions）
    }

    static func bootstrap() -> AppModel {
        do {
            return AppModel(store: try MolaStore.makeDefault())
        } catch {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MolaGPT-fallback-\(IDs.random(6))")
            // 退回临时目录（数据不会保留），并在界面上提示。
            let store = try! MolaStore(directory: tmp)
            return AppModel(store: store, startupError: "数据库打开失败，本次数据不会保存：\(error.localizedDescription)")
        }
    }

    var colorScheme: ColorScheme? {
        switch settings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Provider

    func reloadProviders() {
        providers = store.providers().map { p in
            var p = p
            p.apiKey = Keychain.get(Keychain.Key.providerApiKey(p.id))
            return p
        }
    }

    func saveProvider(_ p: ByokProvider) {
        Keychain.set(Keychain.Key.providerApiKey(p.id), p.apiKey)
        try? store.upsert(p)
        if let i = providers.firstIndex(where: { $0.id == p.id }) { providers[i] = p } else { reloadProviders() }
    }

    func deleteProvider(_ id: String) {
        Keychain.delete(Keychain.Key.providerApiKey(id))
        try? store.deleteProvider(id)
        reloadProviders()
    }

    func addProvider(from preset: ByokProviderPresets.Preset?) -> ByokProvider {
        let order = (providers.map(\.sortOrder).max() ?? -1) + 1
        let p = preset.map { ByokProviderPresets.make($0, sortOrder: order) }
            ?? ByokProvider(name: "自定义服务", baseUrl: "https://", sortOrder: order)
        saveProvider(p)
        reloadProviders()
        return p
    }

    func provider(_ id: String) -> ByokProvider? {
        if id == MolaVirtualProvider.id { return account.models.isEmpty ? nil : MolaVirtualProvider.provider(account.models) }
        return providers.first { $0.id == id }
    }

    var molaChat: MolaChatService { MolaChatService(session: .shared, account: account) }

    // MARK: - MCP

    /// 注入 Keychain 中的 token。
    var mcpServersWithTokens: [McpServer] {
        settings.mcpServers.map { s in
            var s = s
            s.token = Keychain.get(Keychain.Key.mcpToken(s.id))
            return s
        }
    }

    func saveMcpServer(_ server: McpServer) {
        Keychain.set(Keychain.Key.mcpToken(server.id), server.token?.nonBlank)
        var stored = server
        stored.token = nil
        if let i = settings.mcpServers.firstIndex(where: { $0.id == server.id }) { settings.mcpServers[i] = stored }
        else { settings.mcpServers.append(stored) }
        Task { await mcp.reset(server.id) }
    }

    func deleteMcpServer(_ id: String) {
        Keychain.delete(Keychain.Key.mcpToken(id))
        settings.mcpServers.removeAll { $0.id == id }
    }

    /// 可选模型（启用的服务 + 启用的模型）。
    var modelGroups: [(provider: ByokProvider, models: [ProviderModel])] {
        let official: [(provider: ByokProvider, models: [ProviderModel])] = account.models.isEmpty ? [] : {
            let p = MolaVirtualProvider.provider(account.models)
            return [(p, p.models)]
        }()
        return official + providers.filter { $0.enabled && $0.purpose == .chat }.map { ($0, $0.models.filter(\.enabled)) }.filter { !$0.1.isEmpty }
    }

    func resolve(_ key: ModelKey?) -> (ByokProvider, ProviderModel)? {
        guard let key, let p = provider(key.providerId), p.enabled, let m = p.model(key.modelId) else { return nil }
        return (p, m)
    }

    /// 默认模型：设置 → 第一个可用模型。
    var defaultModel: (ByokProvider, ProviderModel)? {
        if let r = resolve(ModelKey(settings.defaultModel)) { return r }
        guard let g = modelGroups.first, let m = g.models.first else { return nil }
        return (g.provider, m)
    }

    // MARK: - 角色

    func reloadPersonas() { personas = store.personas() }

    func persona(_ id: String?) -> Persona? {
        guard let id else { return nil }
        return personas.first { $0.id == id }
    }

    // MARK: - 会话

    func reloadConversations() {
        conversations = store.conversations(search: searchText)
    }

    private func makeConversation() -> Conversation {
        // 默认不绑定角色；设置里指定了且角色仍存在时才绑定
        let pid = settings.defaultPersonaId.nonBlank.flatMap { persona($0)?.id }
        var c = Conversation(personaId: pid == Persona.builtinDefaultId ? nil : pid)
        if let (p, m) = defaultModel {
            c.providerId = p.id; c.model = m.id
            c.providerKind = p.id == MolaVirtualProvider.id ? .molagpt : .byok
        }
        return c
    }

    func newConversation() {
        if current.messages.isEmpty && !current.isStreaming {
            // 空白会话直接复用，但刷新默认模型。
            current.resetToDefaults(makeConversation())
            return
        }
        park(current)
        current = ChatController(app: self, conversation: makeConversation())
    }

    func open(_ sessionId: String) {
        guard sessionId != current.conversation.sessionId else { return }
        park(current)
        if let c = controllers.removeValue(forKey: sessionId) {
            current = c
        } else if let conv = store.conversation(sessionId) {
            let c = ChatController(app: self, conversation: conv, messages: store.messages(sessionId))
            current = c
            if store.isPlaceholder(sessionId) {
                Task { if let msgs = await sync.loadIfPlaceholder(sessionId) { c.replaceMessages(msgs) } }
            }
        }
    }

    /// 离开会话：仍在流式的保留在内存里继续跑。
    private func park(_ c: ChatController) {
        if c.isStreaming { controllers[c.conversation.sessionId] = c }
    }

    func streamFinished(_ c: ChatController) {
        if c !== current { controllers[c.conversation.sessionId] = nil }
        reloadConversations()
    }

    func isStreaming(_ sessionId: String) -> Bool {
        if current.conversation.sessionId == sessionId { return current.isStreaming }
        return controllers[sessionId]?.isStreaming ?? false
    }

    func delete(_ ids: [String]) {
        for id in ids { controllers[id]?.stop(); controllers[id] = nil }
        // 已同步过的官方会话先留墓碑，云端确认删除后再物理删除。
        let cloud = ids.filter { settings.cloudSyncEnabled && account.isLoggedIn && store.conversation($0)?.providerKind == .molagpt }
        try? store.softDelete(cloud)
        try? store.deleteConversations(ids.filter { !cloud.contains($0) })
        if !cloud.isEmpty { sync.schedulePush() }
        if ids.contains(current.conversation.sessionId) {
            current.stop()
            current = ChatController(app: self, conversation: makeConversation())
        }
        reloadConversations()
    }

    func rename(_ id: String, _ title: String) {
        guard let t = title.nonBlank else { return }
        try? store.rename(id, title: t)
        if current.conversation.sessionId == id { current.conversation.title = t }
        controllers[id]?.conversation.title = t
        reloadConversations()
    }

    func togglePin(_ id: String) {
        guard let c = conversations.first(where: { $0.sessionId == id }) else { return }
        try? store.setPinned(id, !c.pinned)
        if current.conversation.sessionId == id { current.conversation.pinned = !c.pinned }
        reloadConversations()
    }

    // MARK: - 生命周期

    /// 回到前台：记忆整理、云同步、启动提示等。
    func didBecomeActive() {
        notifier.isActive = true
        LiveActivityCenter.shared.enabled = settings.liveActivities
        LiveActivityCenter.shared.didBecomeActive()
        ShareImporter.consume(self)
        memory.foregroundScan()
        for h in foregroundHooks { h() }
        Task { await account.refresh() }
        Task {
            guard pendingNotice == nil, let list = await StartupNotices.fetch() else { return }
            let ids = Set(list.map(\.id))
            settings.seenNoticeIds = settings.seenNoticeIds.filter { ids.contains($0) }
            if let next = list.first(where: { !settings.seenNoticeIds.contains($0.id) }) {
                settings.seenNoticeIds.append(next.id)
                pendingNotice = next
            }
        }
    }

    func didEnterBackground() {
        notifier.isActive = false
        LiveActivityCenter.shared.didEnterBackground()
    }

    /// 实时活动 / 通知等的深链：molagpt://chat/<会话 id>、molagpt://image/<任务 id>。
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "molagpt" else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "chat" where !id.isEmpty:
            open(id)
            chatFocusToken += 1
        case "image" where !id.isEmpty:
            imageTaskToOpen = id
            showImageWorkbench = true
        default: break
        }
    }

    func openImageTask(_ id: String) {
        imageTaskToOpen = id
        showSettings = false
        showImageWorkbench = true
    }
}
