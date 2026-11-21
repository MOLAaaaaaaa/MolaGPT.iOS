import Foundation
import MolaCore
import MolaStorage

/// 一轮请求的全部输入。
struct TurnPlan {
    var system: String?
    var messages: [WireMessage]
    var tools: [ToolSpec]
    var executor: (any ToolExecutor)?
}

/// 组装每轮请求（对应安卓 ChatViewModel.send：角色提示 → 记忆 → 技能目录 → 可视化协议；工具开关 resolveRequestTools）。
/// 记忆、技能、角色卡、上下文压缩都从这里接入，ChatController 只管流式与持久化。
@MainActor
final class TurnPlanner {
    unowned let app: AppModel
    /// 本地工具（记忆 / 回忆 / 技能）的处理器，由各子系统注册。
    var localHandlers: [String: LocalToolHandler] = [:]
    /// 额外 system 段（记忆块、技能目录等），按注册顺序拼接。
    var systemContributors: [(String, @MainActor (ChatController, ProviderModel) -> String?)] = []
    /// 额外工具可用性（记忆 / 回忆 / 技能）。
    var availabilityContributors: [@MainActor (ChatController, ProviderModel, inout ToolAvailability) -> Void] = []
    /// 本地历史改写（上下文压缩检查点）。在转成 WireMessage 之前执行。
    var chatHistoryTransformers: [@MainActor (ChatController, ProviderModel, [ChatMessage]) -> [ChatMessage]] = []
    /// 请求历史改写（精简 / 角色深度插入）。
    var historyTransformers: [@MainActor (ChatController, ProviderModel, [WireMessage]) -> [WireMessage]] = []
    /// 回答完成后的钩子（记忆整理、云同步、通知）。
    var afterTurnHooks: [@MainActor (ChatController) -> Void] = []

    init(app: AppModel) { self.app = app }

    func availability(for c: ChatController, model: ProviderModel, history: [ChatMessage]) -> ToolAvailability {
        let s = app.settings
        var a = ToolAvailability()
        guard model.supportsToolCalling else { return a }
        a.webSearch = c.webEnabled
        a.webSearchProvider = s.effectiveSearchProvider(loggedIn: app.account.isLoggedIn)
        a.fetchURL = c.webEnabled && s.webFetchEnabled
        let hasImages = history.contains { $0.role == .user && $0.attachments.contains(where: \.isImage) }
        a.viewImage = s.visionProxyEnabled && !model.supportsVision && hasImages
        a.imageGeneration = s.imageGenEnabled && c.imageGenEnabled
        a.mcp = s.mcpEnabled && s.mcpServers.contains(where: \.enabled)
        for f in availabilityContributors { f(c, model, &a) }
        return a
    }

    func plan(controller c: ChatController, history: [ChatMessage], provider: ByokProvider, model: ProviderModel) -> TurnPlan {
        let s = app.settings
        let store = app.store
        let avail = availability(for: c, model: model, history: history)
        let options = ContextBuilder.Options(username: s.username.nonBlank ?? "用户", replayModelId: model.id,
                                             imagesAsPlaceholders: avail.viewImage)
        var systemParts: [String] = []
        if let base = c.rolePrompt(provider: provider, model: model, history: history) ?? ContextBuilder.systemPrompt(
            persona: c.persona, conversation: c.conversation, provider: provider, model: model, options: options) {
            systemParts.append(base)
        }
        for (_, f) in systemContributors { if let t = f(c, model)?.nonBlank { systemParts.append(t) } }
        if s.visualAnswersEnabled { systemParts.append(VisualAnswerPrompt.text) }

        var effectiveHistory = history
        for t in chatHistoryTransformers { effectiveHistory = t(c, model, effectiveHistory) }
        var messages = ContextBuilder.wireMessages(effectiveHistory, options: options, loader: { store.loadAttachment($0) })
        for t in historyTransformers { messages = t(c, model, messages) }

        let tools = BuiltinTools.specs(avail)
        var executor: (any ToolExecutor)?
        if !tools.isEmpty {
            // view_image 的图片按用户消息上传顺序全局编号（含已失效的）。
            let images: [(name: String, part: WireMessage.Part?)] = history.filter { $0.role == .user }.flatMap { m in
                m.attachments.filter(\.isImage).map { a -> (name: String, part: WireMessage.Part?) in
                    if a.unavailable { return (a.name, nil) }
                    if let url = a.remoteUrl, a.localPath == nil { return (a.name, .image(mimeType: a.mimeType, base64: nil, url: url)) }
                    guard let data = store.loadAttachment(a) else { return (a.name, nil) }
                    return (a.name, .image(mimeType: a.mimeType, base64: data.base64EncodedString(), url: nil))
                }
            }
            let lastUser = history.last { $0.role == .user }
            let ctx = ToolContext(sessionId: c.conversation.sessionId, lastUserText: lastUser?.text ?? "", lastUserMessageId: lastUser?.messageId)
            executor = AppToolExecutor(
                session: .shared, settings: s, currentProvider: provider, providers: app.providers,
                mcpServers: app.mcpServersWithTokens, mcp: app.mcp, images: images,
                imageDirectory: AppPaths.generatedImages, molaBaseURL: MolaEndpoints.base, molaJWT: app.account.jwt,
                local: localHandlers, context: ctx)
        }
        return TurnPlan(system: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
                        messages: messages, tools: tools, executor: executor)
    }

    /// 回答后处理：只改正文片段，代码 / 公式区间不动。
    func postProcess(_ fragments: [MessageFragment], banner: (String) -> Void) -> [MessageFragment] {
        let s = app.settings
        guard s.responsePostProcessingEnabled, s.responseRegexRules.contains(where: \.enabled) else { return fragments }
        var failures: Set<String> = []
        let out = fragments.map { f -> MessageFragment in
            guard case .text(let id, let md) = f else { return f }
            let r = ResponsePostProcessor.apply(md, rules: s.responseRegexRules)
            failures.formUnion(r.failures)
            return .text(id: id, markdown: r.text)
        }
        if let first = failures.first { banner("后处理规则「\(first)」未生效：表达式无效") }
        return out
    }

    func afterTurn(controller c: ChatController) {
        app.settings.completedTurns += 1
        for h in afterTurnHooks { h(c) }
    }
}

enum AppPaths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var generatedImages: URL { documents.appendingPathComponent("gen_images", isDirectory: true) }
    static var skills: URL { documents.appendingPathComponent("skills", isDirectory: true) }
    static var personaAvatars: URL { documents.appendingPathComponent("persona_avatars", isDirectory: true) }
    static var imageWorkbench: URL { documents.appendingPathComponent("image_workbench", isDirectory: true) }
}
