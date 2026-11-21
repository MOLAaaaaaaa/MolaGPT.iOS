import Foundation
import Observation
import MolaCore
import MolaStorage

/// 上下文压缩（对应安卓 ContextCompactor）：阈值自动压缩、超长重试、手动压缩、精简、仪表数据。
@MainActor
@Observable
final class CompactionService {
    @ObservationIgnored unowned let app: AppModel
    private(set) var compacting: Set<String> = []
    var lastError: String?
    /// 每个会话最近一次实测的输入 token 与当时的估算值（用于校准）。
    private var measured: [String: (measured: Int, estimated: Int)] = [:]
    private(set) var revision = 0

    init(app: AppModel) { self.app = app }

    func register(on planner: TurnPlanner) {
        planner.chatHistoryTransformers.append { [unowned self] c, _, history in self.applyCheckpoint(c, history) }
        planner.historyTransformers.append { [unowned self] _, _, wire in
            self.app.settings.contextSlimmingEnabled ? ContextSlimmer.slim(wire) : wire
        }
        planner.afterTurnHooks.append { [unowned self] c in self.recordMeasured(c) }
    }

    private var store: MolaStore { app.store }

    // MARK: - 检查点应用

    func applyCheckpoint(_ c: ChatController, _ history: [ChatMessage]) -> [ChatMessage] {
        let cps = store.checkpoints(c.conversation.sessionId)
        guard !cps.isEmpty, let (cp, idx) = ContextPlanner.activeCheckpoint(cps, history: history) else { return history }
        return ContextPlanner.apply(cp, anchor: idx, history: history)
    }

    /// 压缩位置（消息 id），消息列表在其后插入「已压缩」标记。
    func markers(_ sessionId: String) -> [String: ContextCheckpoint] {
        _ = revision
        var out: [String: ContextCheckpoint] = [:]
        for c in store.checkpoints(sessionId) where !c.stale { out[c.anchorMessageId] = c }
        return out
    }

    // MARK: - 仪表

    struct Gauge { var used: Int; var window: Int; var estimated: Bool; var pressure: ContextEstimator.Pressure; var hasAnswer: Bool }

    func gauge(_ c: ChatController) -> Gauge? {
        guard let (_, model) = c.selection else { return nil }
        let window = ModelContextWindows.window(for: model)
        let history = applyCheckpoint(c, c.messages.filter { $0.status != .streaming })
        let est = ContextEstimator.tokens(history, system: c.persona?.systemPrompt, withTools: false)
        let m = measured[c.conversation.sessionId]
        let lastPrompt = c.messages.last { $0.role == .assistant && $0.stats?.usage.promptTokens != nil }?.stats?.usage.promptTokens
        let used = ContextEstimator.calibrated(est, measured: m?.measured ?? lastPrompt, estimatedAtMeasure: m?.estimated ?? (lastPrompt != nil ? est : nil))
        return Gauge(used: used, window: window, estimated: m == nil && lastPrompt == nil, pressure: ContextEstimator.pressure(used, window: window),
                     hasAnswer: c.messages.contains { $0.role == .assistant })
    }

    func shouldAutoCompact(_ c: ChatController, history: [ChatMessage], model: ProviderModel) -> Bool {
        guard app.settings.contextCompactionEnabled, history.count > 4 else { return false }
        let window = ModelContextWindows.window(for: model)
        let effective = applyCheckpoint(c, history)
        let est = ContextEstimator.tokens(effective, system: c.persona?.systemPrompt, withTools: true)
        let m = measured[c.conversation.sessionId]
        let used = ContextEstimator.calibrated(est, measured: m?.measured, estimatedAtMeasure: m?.estimated)
        return Double(used) >= Double(window) * ContextEstimator.triggerRatio
    }

    func recordMeasured(_ c: ChatController) {
        guard let last = c.messages.last(where: { $0.role == .assistant }), let p = last.stats?.usage.promptTokens, p > 0 else { return }
        let history = applyCheckpoint(c, Array(c.messages.dropLast()))
        measured[c.conversation.sessionId] = (p, max(1, ContextEstimator.tokens(history, system: c.persona?.systemPrompt, withTools: false)))
        revision += 1
    }

    // MARK: - 压缩

    /// 生成并保存检查点；成功返回 true。
    @discardableResult
    func compact(_ c: ChatController, history: [ChatMessage], provider: ByokProvider, model: ProviderModel,
                 reason: CompactionReason, declaredWindow: Int? = nil) async -> Bool {
        let sid = c.conversation.sessionId
        guard !compacting.contains(sid) else { return false }
        let window = min(declaredWindow ?? .max, ModelContextWindows.window(for: model))
        guard let anchor = ContextPlanner.anchorIndex(history, window: window, reason: reason) else {
            if reason == .manual { lastError = "没有可以压缩的内容" }
            return false
        }
        compacting.insert(sid)
        defer { compacting.remove(sid); revision += 1 }
        let target = app.resolve(ModelKey(app.settings.compactionModelKey)) ?? (provider, model)
        let previous = ContextPlanner.activeCheckpoint(store.checkpoints(sid), history: history).flatMap { $0.1 < anchor ? $0 : nil }
        let start = previous.map { $0.1 + 1 } ?? 0
        guard start <= anchor else { return false }
        let covered = history[start...anchor]
        let before = ContextEstimator.tokens(history, system: nil, withTools: false)
        let targetChars = ContextPlanner.targetChars(tokens: ContextEstimator.tokens(Array(covered), system: nil, withTools: false))
        // 按摘要模型窗口的一半分段，滚动更新同一份摘要。
        let chunkBudget = max(4000, ModelContextWindows.window(for: target.1) / 2)
        var chunks: [ArraySlice<ChatMessage>] = []
        var cur = covered.startIndex, acc = 0
        for i in covered.indices {
            acc += ContextEstimator.tokens(covered[i])
            if acc > chunkBudget, i > cur { chunks.append(covered[cur..<i]); cur = i; acc = ContextEstimator.tokens(covered[i]) }
        }
        chunks.append(covered[cur...anchor])
        var summary = previous?.0.summary
        var inTok = 0, outTok = 0
        do {
            for chunk in chunks.prefix(24) {
                try Task.checkCancellation()
                let p = ContextPlanner.summaryPrompt(transcript: ContextPlanner.transcript(chunk), previous: summary,
                                                     rolePlay: c.persona?.isRolePlay ?? false, targetChars: targetChars)
                let r = try await app.client.complete(provider: target.0, model: target.1, system: p.system, user: p.user,
                                                      maxTokens: ContextPlanner.maxOutput(targetChars: targetChars), timeout: 300)
                summary = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                inTok += r.usage?.promptTokens ?? 0; outTok += r.usage?.completionTokens ?? 0
            }
        } catch {
            lastError = "压缩失败：\(error.localizedDescription)"
            return false
        }
        guard let summary = summary?.nonBlank else { lastError = "压缩失败：摘要为空"; return false }
        var cp = ContextCheckpoint(sessionId: sid, anchorMessageId: history[anchor].messageId, summary: summary,
                                   coveredDigest: ContextPlanner.digest(history[...anchor]), tokensBefore: before, tokensAfter: 0,
                                   reason: reason, providerId: target.0.id, modelId: target.1.id, inputTokens: inTok, outputTokens: outTok)
        cp.costUsd = target.1.pricing?.cost(Usage(promptTokens: inTok, completionTokens: outTok))
        cp.tokensAfter = ContextEstimator.tokens(ContextPlanner.apply(cp, anchor: anchor, history: history), system: nil, withTools: false)
        try? store.insert(cp)
        measured[sid] = nil
        lastError = nil
        return true
    }

    func compactNow(_ c: ChatController) {
        guard let (p, m) = c.selection, !c.isStreaming else { return }
        Task { await compact(c, history: c.messages, provider: p, model: m, reason: .manual) }
    }

    func stats(_ sessionId: String) -> (count: Int, saved: Int, cost: Double, latest: ContextCheckpoint?) {
        let cps = store.checkpoints(sessionId)
        return (cps.count, cps.last.map { max(0, $0.tokensBefore - $0.tokensAfter) } ?? 0, cps.compactMap(\.costUsd).reduce(0, +), cps.last)
    }
}
