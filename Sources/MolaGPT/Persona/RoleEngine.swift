import Foundation
import UIKit
import MolaCore
import MolaStorage

/// 角色扮演：角色卡提示词、世界书匹配、深度插入、开场白、角色卡导入与头像（对应安卓 buildRolePrompt / applyRolePlan / PersonaRepository）。
@MainActor
final class RoleEngine {
    unowned let app: AppModel
    /// 本轮计划（systemPrompt 与历史改写在同一轮里共用）。
    private var currentPlan: (sessionId: String, plan: RolePlan)?

    init(app: AppModel) { self.app = app }

    func register(on planner: TurnPlanner) {
        planner.historyTransformers.append { [unowned self] c, _, wire in
            guard let cp = self.currentPlan, cp.sessionId == c.conversation.sessionId else { return wire }
            var out = RolePromptBuilder.apply(cp.plan, to: wire)
            // Anthropic / Gemini 要求首条为 user：开场白在最前时补一条起始消息。
            if out.first?.role == .assistant { out.insert(.text(.user, "（开始对话）"), at: 0) }
            self.currentPlan = nil
            return out
        }
    }

    /// 角色卡存在且有内容时返回组装后的 system；否则 nil（走普通系统提示）。
    func systemPrompt(for c: ChatController, provider: ByokProvider, model: ProviderModel, history: [ChatMessage]) -> String? {
        currentPlan = nil
        guard let persona = c.persona, let profile = persona.profile, !profile.isEmpty else { return nil }
        let scan = history.filter { $0.role != .system }.map(\.text).filter { !$0.isEmpty }
        let user = app.settings.username.nonBlank ?? app.memory.profile[.preferredName] ?? "用户"
        let plan = RolePromptBuilder.build(persona: persona, profile: profile, conversationPrompt: c.conversation.systemPrompt,
                                           appendMode: false, userName: user, model: model.displayName, provider: provider.name,
                                           history: scan, sharedBooks: app.store.lorebooks(), generationId: IDs.generic("gen"))
        currentPlan = (c.conversation.sessionId, plan)
        return plan.system
    }

    /// 选中角色且对话为空时写入开场白。
    func ensureGreeting(_ c: ChatController) {
        guard c.messages.isEmpty, let persona = c.persona, let profile = persona.profile else { return }
        let user = app.settings.username.nonBlank ?? app.memory.profile[.preferredName] ?? "用户"
        let texts = RolePromptBuilder.greetings(profile, persona: persona, userName: user)
        guard !texts.isEmpty else { return }
        c.insertGreeting(texts)
    }

    // MARK: - 角色管理

    func save(_ p: Persona) {
        var p = p
        p.updatedAt = IDs.nowMs()
        try? app.store.upsert(p)
        app.reloadPersonas()
    }

    func delete(_ p: Persona) {
        try? app.store.deletePersona(p.id)
        app.reloadPersonas()
        sweepAvatars()
    }

    func duplicate(_ p: Persona) -> Persona? {
        let copy = try? app.store.duplicate(p)
        app.reloadPersonas()
        return copy
    }

    enum ImportError: LocalizedError {
        case noCard
        var errorDescription: String? { "charX 压缩包里没有 card.json" }
    }

    /// 导入 PNG / JSON / charX 角色卡。
    @discardableResult
    func importCard(_ data: Data) throws -> Persona {
        var result: CharacterCardReader.Result
        if MiniZip.isZip(data) {
            let zip = try MiniZip(data)
            guard let card = zip.entry("card.json") else { throw ImportError.noCard }
            result = try CharacterCardReader.read(json: try zip.extract(card))
            // 头像：assets 里 type=icon，优先 name=main，只认 embeded:// 内嵌资源
            let assets = result.persona.profile?.assets?.arrayValue ?? []
            let icons = assets.filter { $0["type"]?.stringValue == "icon" }
            if let icon = icons.first(where: { $0["name"]?.stringValue == "main" }) ?? icons.first,
               let uri = icon["uri"]?.stringValue, uri.hasPrefix("embeded://") || uri.hasPrefix("embedded://") {
                let path = uri.replacingOccurrences(of: "embeded://", with: "").replacingOccurrences(of: "embedded://", with: "")
                if let e = zip.entry(path) { result.avatar = try? zip.extract(e, limit: 16 * 1024 * 1024) }
            }
        } else {
            result = try CharacterCardReader.read(data, inflate: { MiniZip.inflateZlib($0) })
        }
        var p = result.persona
        p.name = app.store.uniquePersonaName(p.name)
        p.sortOrder = (app.personas.map(\.sortOrder).max() ?? 0) + 1
        if let avatar = result.avatar { p.avatarPath = saveAvatar(avatar) }
        save(p)
        return p
    }

    func setAvatar(_ p: Persona, image: UIImage) -> Persona {
        var p = p
        if let data = image.preparingThumbnail(of: CGSize(width: 512, height: 512 * image.size.height / max(image.size.width, 1)))?.pngData() ?? image.pngData() {
            p.avatarPath = saveAvatar(data)
        }
        return p
    }

    /// 头像写入 Documents/persona_avatars/<16 位 hex>.png，库里存文件名。
    func saveAvatar(_ data: Data) -> String? {
        let dir = AppPaths.personaAvatars
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SHA256.hex(Array(SHA256.hash(data).prefix(8))) + ".png"
        do { try data.write(to: dir.appendingPathComponent(name)); return name } catch { return nil }
    }

    func avatar(_ p: Persona) -> UIImage? {
        guard let name = p.avatarPath, !name.contains("/"), !name.contains("\\") else { return nil }
        return UIImage(contentsOfFile: AppPaths.personaAvatars.appendingPathComponent(name).path)
    }

    /// 清理没有角色引用的头像文件。
    func sweepAvatars() {
        let referenced = Set(app.store.personas().compactMap(\.avatarPath))
        let dir = AppPaths.personaAvatars
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !referenced.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}
