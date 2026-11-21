import Foundation
import ActivityKit
import MolaCore
import MolaActivity

/// 实时活动（灵动岛 / 锁屏）：生成回答或图片时发起，流式中节流更新，结束时显示结果。
/// - 只能在前台发起，所以在开始生成时就 request（前台时灵动岛不显示本 App 的活动，离开 App 才出现）。
/// - 结束时若 App 在前台直接移除；在后台则保留一段时间供用户查看，点按跳回对应对话。
/// - 没有推送通道：App 被挂起后不再更新，回到前台或任务结束时补上最终状态。
@MainActor
final class LiveActivityCenter {
    static let shared = LiveActivityCenter()

    private var activities: [String: Activity<MolaActivityAttributes>] = [:]
    private var lastUpdate: [String: Date] = [:]
    private var lastState: [String: MolaActivityAttributes.ContentState] = [:]
    /// 全局开关（设置里的「实时活动」），由 AppModel 同步。
    var enabled = true
    var appActive = true

    private var available: Bool { enabled && ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(key: String, kind: MolaActivityAttributes.Kind, targetId: String, title: String, model: String,
               phase: MolaActivityAttributes.Phase, snippet: String = "") {
        guard available, activities[key] == nil else { return }
        let attrs = MolaActivityAttributes(kind: kind, targetId: targetId, title: title.isEmpty ? "新对话" : title, model: model)
        let state = MolaActivityAttributes.ContentState(phase: phase, snippet: snippet, startedAt: Date())
        do {
            let activity = try Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil), pushType: nil)
            activities[key] = activity
            lastState[key] = state
        } catch {
            // 系统拒绝（关闭了实时活动、数量上限、不在前台）时静默降级为普通通知
        }
    }

    /// 流式中更新：同状态下至少间隔 1 秒，状态变化立即更新。
    func update(key: String, phase: MolaActivityAttributes.Phase, snippet: String) {
        guard let activity = activities[key], var state = lastState[key] else { return }
        let now = Date()
        if state.phase == phase, let last = lastUpdate[key], now.timeIntervalSince(last) < 1 { return }
        if state.phase == phase && state.snippet == snippet { return }
        state.phase = phase
        state.snippet = snippet
        lastState[key] = state
        lastUpdate[key] = now
        // Activity 本身线程安全但未标 Sendable
        nonisolated(unsafe) let a = activity
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    func updateChat(key: String, fragments: [MessageFragment]) {
        guard activities[key] != nil else { return }
        let s = LiveSummary.summarize(fragments, toolLabel: ToolLabels.label)
        let phase: MolaActivityAttributes.Phase = switch s.phase {
        case .thinking: .thinking
        case .writing: .writing
        case .tool: .tool
        }
        update(key: key, phase: phase, snippet: s.snippet)
    }

    func end(key: String, phase: MolaActivityAttributes.Phase, snippet: String? = nil) {
        guard let activity = activities.removeValue(forKey: key) else { return }
        var state = lastState.removeValue(forKey: key) ?? .init(phase: phase, snippet: "", startedAt: Date())
        lastUpdate[key] = nil
        state.phase = phase
        if let snippet { state.snippet = snippet }
        state.endedAt = Date()
        let policy: ActivityUIDismissalPolicy = appActive ? .immediate : .after(Date().addingTimeInterval(15 * 60))
        nonisolated(unsafe) let a = activity
        Task { await a.end(.init(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    func endChat(key: String, status: MessageStatus, fragments: [MessageFragment]) {
        let phase: MolaActivityAttributes.Phase = switch status {
        case .complete: .done
        case .error: .failed
        default: .stopped
        }
        let snippet: String? = phase == .done ? LiveSummary.summarize(fragments).snippet : nil
        end(key: key, phase: phase, snippet: snippet)
    }

    /// 回到前台：已结束但仍挂在锁屏上的活动（例如被系统挂起前没来得及结束的）一并清理。
    func didBecomeActive() {
        appActive = true
        Task {
            for activity in Activity<MolaActivityAttributes>.activities
            where !activities.values.contains(where: { $0.id == activity.id }) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func didEnterBackground() { appActive = false }
}
