import Foundation
import Observation
import MolaCore
import MolaStorage

/// 本地记忆（对应安卓 buildMemoryContext / ByokLocalToolExecutor / ByokMemoryConsolidator）。
/// 在 TurnPlanner 上注册：工具可用性、system 记忆块、save/forget/recall 处理器、回答后自动整理。
@MainActor
@Observable
final class MemoryService {
    @ObservationIgnored unowned let app: AppModel
    private(set) var lastProjection: MemoryProjection?
    private(set) var consolidating = false
    var lastError: String?
    /// 让记忆页在数据变化后刷新。
    private(set) var revision = 0

    init(app: AppModel) { self.app = app }

    private var store: MolaStore { app.store }
    private var settings: AppSettings { app.settings }

    func register(on planner: TurnPlanner) {
        planner.availabilityContributors.append { [unowned self] c, _, a in
            let e = self.effective(c)
            a.memory = e.memory
            a.recall = e.recall
        }
        planner.systemContributors.append(("memory", { [unowned self] c, _ in self.context(for: c) }))
        planner.localHandlers["save_memory"] = { [weak self] call, ctx in await self?.save(call, ctx) }
        planner.localHandlers["forget_memory"] = { [weak self] call, ctx in await self?.forget(call, ctx) }
        planner.localHandlers["recall_conversations"] = { [weak self] call, ctx in await self?.recall(call, ctx) }
        planner.afterTurnHooks.append { [unowned self] c in self.scheduleConsolidation(c) }
    }

    // MARK: - 开关

    func isRolePlay(_ c: ChatController) -> Bool { c.persona?.isRolePlay ?? false }

    /// 有效开关 = 总开关 AND（会话覆盖 ?? 全局子开关）；角色扮演角色不用记忆。
    func effective(_ c: ChatController) -> (memory: Bool, recall: Bool) {
        guard settings.byokMemoryMasterEnabled, !isRolePlay(c) else { return (false, false) }
        let f = store.memoryFlags(c.conversation.sessionId)
        return (f.memory ?? settings.byokMemoryUse, f.recall ?? settings.byokConversationRecall)
    }

    func setConversation(_ c: ChatController, memory: Bool?, recall: Bool?) {
        try? store.setMemoryFlags(c.conversation.sessionId, memory: memory, recall: recall)
        revision += 1
    }

    // MARK: - 注入

    var profile: [MemoryProfileKey: String] {
        var out: [MemoryProfileKey: String] = [:]
        for e in store.memoryEntries() { if let k = e.profileKey { out[k] = e.text } }
        return out
    }

    func projection() -> MemoryProjection {
        MemoryProjector.project(entries: store.memoryEntries(), profile: profile,
                                language: Locale.preferredLanguages.first ?? "zh-Hans", timezone: TimeZone.current.identifier,
                                budget: settings.byokMemoryBudget)
    }

    func context(for c: ChatController) -> String? {
        let e = effective(c)
        guard e.memory || e.recall else { return nil }
        var parts: [String] = []
        if e.memory {
            let p = projection()
            lastProjection = p
            parts.append(p.block)
        }
        if let rules = MemoryProjector.usageRules(memoryTools: e.memory, recallTool: e.recall) { parts.append(rules) }
        if e.memory, let hint = MemoryProjector.topicsHint(store.memoryTopics()) { parts.append(hint) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 工具

    func save(_ call: PendingToolCall, _ ctx: ToolContext) async -> ToolResult {
        guard let text = call.string("text")?.nonBlank else { return .failure("memory failed: 缺少 text") }
        guard text.count <= MemoryMath.maxTextLength else { return .failure("memory failed: text 超过 300 字") }
        guard let quote = call.string("source_quote"), MemoryMath.quoteMatches(quote, in: ctx.lastUserText) else {
            return .failure("memory failed: source_quote 必须逐字出自用户本轮消息")
        }
        let allow = settings.byokMemoryAllowSensitive
        if !allow && MemoryGuards.looksSensitive(text) { return .failure("memory failed: 不能记录密钥、密码、证件或支付信息") }
        if store.isSuppressed(text) { return .failure("memory failed: 用户删除或忽略过这条记忆，不能自动写回") }
        let section = MemorySection.from(call.string("section"))
        let pk = call.string("profile_key").flatMap(MemoryProfileKey.init(rawValue:))
        if !allow && MemoryGuards.looksProtected(text) {
            try? store.insert(MemoryCandidate(text: text, section: section, profileKey: pk, topicTitle: call.string("topic"),
                                              group: call.string("group").flatMap(MemoryGroup.init(rawValue:)), confidence: 0.85,
                                              quote: quote, sourceSessionId: ctx.sessionId))
            revision += 1
            return ToolResult("这条涉及敏感个人信息，已排入待确认，用户在记忆页确认后才会生效。")
        }
        let result = upsertFromModel(text: text, section: section, profileKey: pk, topic: call.string("topic"),
                                     group: call.string("group").flatMap(MemoryGroup.init(rawValue:)), summary: call.string("summary"),
                                     confidence: 0.85, origin: .tool, quote: quote, sessionId: ctx.sessionId, messageId: ctx.lastUserMessageId)
        revision += 1
        return result
    }

    /// 写入或强化一条记忆（工具与自动整理共用）。
    @discardableResult
    func upsertFromModel(text: String, section: MemorySection, profileKey: MemoryProfileKey?, topic: String?, group: MemoryGroup?,
                         summary: String?, confidence: Double, origin: MemoryOrigin, quote: String, sessionId: String?, messageId: String?) -> ToolResult {
        let key = MemoryMath.normalizeKey(text)
        let now = IDs.nowMs()
        if let pk = profileKey, let existing = store.memoryEntry(profile: pk), existing.normalizedKey != key {
            if existing.isUserOwned { return .failure("memory failed: 该资料由用户填写，不能自动改写") }
            var e = existing
            e.text = text; e.normalizedKey = key; e.confidence = confidence; e.origin = origin; e.updatedAt = now; e.lastReinforcedAt = now
            try? store.upsert(e)
            try? store.addEvidence(entryId: e.id, sessionId: sessionId, messageId: messageId, quote: quote)
            return ToolResult("已记住：\(text)")
        }
        if var existing = store.memoryEntry(key: key) {
            existing.confidence = min(MemoryMath.confidenceCap, max(existing.confidence, confidence) + MemoryMath.reinforceDelta)
            existing.recurrence += 1
            existing.lastReinforcedAt = now; existing.updatedAt = now
            try? store.upsert(existing)
            try? store.addEvidence(entryId: existing.id, sessionId: sessionId, messageId: messageId, quote: quote)
            return ToolResult("已有相同记忆，已强化：\(existing.text)")
        }
        let topicId = store.resolveTopic(title: topic, group: group, summary: summary)
        let e = MemoryEntry(text: text, section: section, profileKey: profileKey, topicId: topicId, confidence: confidence, origin: origin)
        do {
            try store.upsert(e)
            try? store.addEvidence(entryId: e.id, sessionId: sessionId, messageId: messageId, quote: quote)
            return ToolResult("已记住：\(text)")
        } catch {
            return .failure("memory failed: \(error.localizedDescription)")
        }
    }

    func forget(_ call: PendingToolCall, _ ctx: ToolContext) async -> ToolResult {
        guard let query = call.string("query")?.nonBlank else { return .failure("memory failed: 缺少 query") }
        guard let quote = call.string("source_quote"), MemoryMath.quoteMatches(quote, in: ctx.lastUserText), MemoryGuards.looksLikeDenial(quote) else {
            return .failure("memory failed: 只有用户在本轮明确否认时才能删除记忆")
        }
        let key = MemoryMath.normalizeKey(query)
        let entries = store.memoryEntries()
        var matches = entries.filter { $0.normalizedKey == key }
        if matches.isEmpty, !key.isEmpty {
            matches = entries.filter { !$0.normalizedKey.isEmpty && ($0.normalizedKey.contains(key) || key.contains($0.normalizedKey)) }
        }
        switch matches.count {
        case 0: return ToolResult("没有找到匹配的记忆。")
        case 1:
            try? store.deleteMemory(matches[0].id, suppress: true)
            revision += 1
            return ToolResult("已忘记：\(matches[0].text)")
        default:
            return ToolResult("多条记忆匹配，未删除。请让用户在记忆页确认：\n" + matches.prefix(5).map { "- \($0.text)" }.joined(separator: "\n"))
        }
    }

    func recall(_ call: PendingToolCall, _ ctx: ToolContext) async -> ToolResult {
        let qs = RecallFormatter.queries(call.string("queries") ?? "")
        guard !qs.isEmpty else { return .failure("recall failed: 缺少关键词") }
        let limit = min(max(call.int("limit") ?? 3, 1), 3)
        let only = call.string("conversation_id")?.nonBlank
        let hits = store.recall(queries: qs, limit: limit, excludeSession: only == nil ? ctx.sessionId : nil, onlySession: only)
        return ToolResult(RecallFormatter.format(hits))
    }

    // MARK: - 自动整理

    private var modelTarget: (ByokProvider, ProviderModel)? { app.resolve(ModelKey(settings.byokMemoryModelKey)) }

    func scheduleConsolidation(_ c: ChatController) {
        guard settings.byokMemoryMasterEnabled, settings.byokMemoryAutoLearn, effective(c).memory, modelTarget != nil else { return }
        let sid = c.conversation.sessionId
        let flags = store.memoryFlags(sid)
        guard flags.failures < 3 else { return }
        let turns = c.messages.filter { $0.role == .assistant && $0.status == .complete && $0.createdAt > flags.watermark }.count
        guard turns >= MemoryConsolidation.assistantTurnThreshold else { return }
        Task { await consolidate(sessionId: sid, manual: false) }
    }

    /// 回到前台：距上次整理超过 6 小时则扫描最近 10 个会话。
    func foregroundScan() {
        guard settings.byokMemoryMasterEnabled, settings.byokMemoryAutoLearn, modelTarget != nil,
              IDs.nowMs() - settings.byokMemoryLastRunAt > MemoryConsolidation.foregroundInterval else { return }
        let ids = app.conversations.prefix(10).map(\.sessionId)
        Task { for id in ids { await consolidate(sessionId: id, manual: false) } }
    }

    /// 手动「开始整理」：扫描全部会话，再整理主题。
    func runManual() async {
        guard modelTarget != nil else { lastError = "请先选择整理模型"; return }
        lastError = nil
        for c in app.store.conversations(limit: 2000) { await consolidate(sessionId: c.sessionId, manual: true) }
        await organizeTopics()
    }

    func consolidate(sessionId: String, manual: Bool) async {
        guard let (provider, model) = modelTarget, !consolidating || manual else { return }
        consolidating = true
        defer { consolidating = false; revision += 1 }
        let flags = store.memoryFlags(sessionId)
        if flags.memory == false { return }
        if let conv = store.conversation(sessionId), let p = app.persona(conv.personaId), p.isRolePlay { return }
        let all = store.messages(sessionId).filter { ($0.role == .user || $0.role == .assistant) && $0.status == .complete }
        let fiveMin: Int64 = 5 * 60 * 1000
        var window = all.filter { $0.createdAt > flags.watermark && $0.createdAt > settings.byokMemoryResetAt && IDs.nowMs() - $0.updatedAt > 0 }
        if window.isEmpty { return }
        if flags.watermark == 0 && !settings.byokMemoryFullScan { window = Array(window.suffix(20)) } else { window = Array(window.suffix(40)) }
        let latest = window.map(\.createdAt).max() ?? IDs.nowMs()
        _ = fiveMin
        let lines = window.compactMap { m -> String? in
            guard let t = MemoryConsolidation.clean(m.text) else { return nil }
            return "\(m.role == .user ? "用户" : "助手"): \(t)"
        }
        let userTexts = window.filter { $0.role == .user }.map(\.text)
        guard !userTexts.isEmpty, !lines.isEmpty else { try? store.setWatermark(sessionId, latest); return }
        let convo = lines.joined(separator: "\n")
        let client = app.client
        do {
            let gate = MemoryConsolidation.gatePrompt(conversation: convo)
            let g = try await client.complete(provider: provider, model: model, system: gate.system, user: gate.user, maxTokens: 32, timeout: 120)
            guard let pass = MemoryConsolidation.parseGate(g.text) else { throw ProviderError.decoding("守门回答无法解析") }
            if !pass { try? store.setWatermark(sessionId, latest); finishRun(); return }
            let ex = MemoryConsolidation.extractPrompt(existing: store.memoryEntries(), suppressed: store.suppressions(),
                                                       topics: store.memoryTopics(), conversation: convo)
            let r = try await client.complete(provider: provider, model: model, system: ex.system, user: ex.user, maxTokens: 1600, timeout: 300)
            guard let ops = MemoryConsolidation.parseOps(r.text) else { throw ProviderError.decoding("提取结果无法解析") }
            apply(ops, userTexts: userTexts, sessionId: sessionId)
            try? store.setWatermark(sessionId, latest)
            finishRun()
        } catch {
            try? store.setMemoryFailures(sessionId, flags.failures + 1)
            lastError = error.localizedDescription
        }
    }

    private func finishRun() { app.settings.byokMemoryLastRunAt = IDs.nowMs() }

    func apply(_ ops: [MemoryOp], userTexts: [String], sessionId: String) {
        let allow = settings.byokMemoryAllowSensitive
        for op in ops {
            guard let quote = op.quote, userTexts.contains(where: { MemoryMath.quoteMatches(quote, in: $0) }) else { continue }
            switch op.kind {
            case .add, .candidate, .supersede:
                guard let text = op.text?.nonBlank, text.count <= MemoryMath.maxTextLength else { continue }
                if !allow && MemoryGuards.looksSensitive(text) { continue }
                if op.kind != .supersede && store.isSuppressed(text) { continue }
                let section = op.section ?? .recent
                let conf = op.confidence ?? 0.8
                let protected = !allow && MemoryGuards.looksProtected(text)
                if op.kind == .supersede {
                    guard let t = op.target, var e = store.memoryEntry(id: t), !e.isUserOwned else { continue }
                    e.text = text; e.normalizedKey = MemoryMath.normalizeKey(text); e.section = section
                    e.updatedAt = IDs.nowMs(); e.lastReinforcedAt = e.updatedAt
                    try? store.upsert(e)
                    try? store.addEvidence(entryId: e.id, sessionId: sessionId, messageId: nil, quote: quote)
                } else if op.kind == .candidate || conf < 0.75 || protected {
                    try? store.insert(MemoryCandidate(text: text, section: section, profileKey: op.profileKey, topicTitle: op.topic,
                                                      group: op.group, confidence: conf, quote: quote, sourceSessionId: sessionId))
                } else {
                    upsertFromModel(text: text, section: section, profileKey: op.profileKey, topic: op.topic, group: op.group,
                                    summary: op.summary, confidence: conf, origin: .automatic, quote: quote, sessionId: sessionId, messageId: nil)
                }
            case .reinforce:
                guard let t = op.target, var e = store.memoryEntry(id: t) else { continue }
                e.confidence = min(MemoryMath.confidenceCap, e.confidence + MemoryMath.reinforceDelta)
                e.recurrence += 1; e.lastReinforcedAt = IDs.nowMs(); e.updatedAt = e.lastReinforcedAt
                try? store.upsert(e)
                try? store.addEvidence(entryId: e.id, sessionId: sessionId, messageId: nil, quote: quote)
            case .forget:
                guard MemoryGuards.looksLikeDenial(quote), let t = op.target, let e = store.memoryEntry(id: t), !e.isUserOwned else { continue }
                try? store.deleteMemory(e.id, suppress: true)
            }
        }
    }

    func organizeTopics() async {
        guard let (provider, model) = modelTarget else { return }
        let loose = store.memoryEntries().filter { $0.topicId == nil && $0.profileKey == nil }
        guard !loose.isEmpty else { return }
        let p = MemoryConsolidation.organizePrompt(entries: loose, topics: store.memoryTopics())
        guard let r = try? await app.client.complete(provider: provider, model: model, system: p.system, user: p.user, maxTokens: 4096) else { return }
        for a in MemoryConsolidation.parseTopics(r.text) {
            guard let tid = store.resolveTopic(title: a.title, group: a.group, summary: a.summary) else { continue }
            for id in a.entryIds { if var e = store.memoryEntry(id: id) { e.topicId = tid; try? store.upsert(e) } }
        }
        revision += 1
    }

    // MARK: - 记忆页操作

    func addManual(_ text: String, section: MemorySection, profileKey: MemoryProfileKey? = nil) {
        guard let t = text.nonBlank else { return }
        try? store.clearSuppression(t)
        if let pk = profileKey, var existing = store.memoryEntry(profile: pk) {
            existing.text = t; existing.normalizedKey = MemoryMath.normalizeKey(t); existing.origin = .manual; existing.updatedAt = IDs.nowMs()
            try? store.upsert(existing)
        } else {
            try? store.upsert(MemoryEntry(text: t, section: section, profileKey: profileKey, confidence: 1, origin: .manual))
        }
        revision += 1
    }

    func update(_ e: MemoryEntry) {
        var e = e
        e.normalizedKey = MemoryMath.normalizeKey(e.text); e.updatedAt = IDs.nowMs(); e.origin = .manual
        try? store.upsert(e)
        revision += 1
    }

    func deleteTopic(_ id: String) { try? store.deleteTopic(id); revision += 1 }

    func delete(_ id: String) { try? store.deleteMemory(id, suppress: true); revision += 1 }

    func confirm(_ c: MemoryCandidate) {
        let topicId = store.resolveTopic(title: c.topicTitle, group: c.group, summary: nil)
        try? store.upsert(MemoryEntry(text: c.text, section: c.section, profileKey: c.profileKey, topicId: topicId, confidence: 0.95, origin: .confirmed))
        try? store.deleteCandidate(c.id)
        revision += 1
    }

    func dismiss(_ c: MemoryCandidate) {
        try? store.addSuppression(c.text, reason: "dismissed")
        try? store.deleteCandidate(c.id)
        revision += 1
    }

    func clearAll() {
        try? store.clearAllMemory()
        app.settings.byokMemoryResetAt = IDs.nowMs()
        revision += 1
    }
}
