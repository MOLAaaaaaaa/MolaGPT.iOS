import UIKit
import BackgroundTasks

/// 一项需要在后台继续跑的工作（对话流式 / 图像任务）。
///
/// iOS 不允许靠反复调用 `beginBackgroundTask` 续期：后台剩余时间是全应用共享的一份（约 30 秒），
/// 再申请只会拿到同一份余量。能合法延长的只有 iOS 26 的 `BGContinuedProcessingTask`（系统显示进度，用户可随时停止），
/// 由 `ContinuedWork` 统一管理；iOS 17–25 或系统拒绝时退回这 30 秒。
/// - 30 秒断言到期时，若持续任务正在运行则只释放断言、不打断工作；否则执行 `onExpire`。
/// - `end()` 幂等，可在工作完成和到期两处都调用。
@MainActor
final class BackgroundGuard {
    let title: String
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let onExpire: @MainActor (BackgroundGuard) -> Void
    private(set) var expired = false
    private var ended = false

    init(name: String, title: String, onExpire: @escaping @MainActor (BackgroundGuard) -> Void) {
        self.title = title
        self.onExpire = onExpire
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.releaseAssertion()
                if !ContinuedWork.shared.isRunning { self.expire() }
            }
        }
        ContinuedWork.shared.add(self)
    }

    /// 后台时间真正用完（30 秒断言到期且没有持续任务，或持续任务被系统/用户终止）。
    func expire() {
        guard !expired, !ended else { return }
        expired = true
        onExpire(self)
    }

    func end() {
        guard !ended else { return }
        ended = true
        releaseAssertion()
        ContinuedWork.shared.remove(self)
    }

    private func releaseAssertion() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// iOS 26+：应用即将离开前台且仍有工作时，提交一个 `BGContinuedProcessingTask`，
/// 系统以实时活动显示进度，工作全部结束后完成任务。
@MainActor
final class ContinuedWork {
    static let shared = ContinuedWork()

    private var guards: [ObjectIdentifier: BackgroundGuard] = [:]
    private var total = 0
    private var finished = 0
    private var task: AnyObject?
    private var submitting = false
    private var ticker: Task<Void, Never>?
    /// 持续任务正在运行（此时 30 秒断言到期不打断工作）。
    private(set) var isRunning = false
    /// 只在灵动岛机型上使用：进度显示在灵动岛里；无灵动岛机型上系统会把状态栏时间变成蓝色胶囊（用户不要），只用约 30 秒。
    var enabled: Bool { DeviceTraits.hasDynamicIsland }

    /// Info.plist `BGTaskSchedulerPermittedIdentifiers` 里登记的前缀（`<前缀>.*`）。
    nonisolated static let declaredPrefix = "com.molagpt.app.work"

    func add(_ g: BackgroundGuard) {
        guards[ObjectIdentifier(g)] = g
        if isRunning { total += 1; refresh() }
    }

    func remove(_ g: BackgroundGuard) {
        guard guards.removeValue(forKey: ObjectIdentifier(g)) != nil else { return }
        if isRunning { finished += 1; refresh() }
        if guards.isEmpty { complete(success: true) }
    }

    /// 场景进入 inactive / background 时调用（提交必须发生在应用仍在前台时，所以 inactive 就提交）。
    func appWillLeaveForeground() {
        guard enabled, !guards.isEmpty, task == nil, !submitting else { return }
        if #available(iOS 26.0, *) { submit() }
    }

    @available(iOS 26.0, *)
    private func submit() {
        submitting = true
        defer { submitting = false }
        // xtool 个人签名会把 bundle ID 改成 XTL-xxxx.com.molagpt.app，前缀以实际 bundle ID 为准，再试登记的固定前缀。
        var prefixes = [Self.declaredPrefix]
        if let bid = Bundle.main.bundleIdentifier, bid != "com.molagpt.app" { prefixes.insert(bid + ".work", at: 0) }
        for prefix in prefixes {
            let identifier = "\(prefix).\(UUID().uuidString.prefix(8))"
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, let t = t as? BGContinuedProcessingTask else { t.setTaskCompleted(success: false); return }
                    self.start(t)
                }
            }
            guard ok else { continue }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: headline, subtitle: subline)
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                return
            } catch {
                continue
            }
        }
    }

    @available(iOS 26.0, *)
    private func start(_ t: BGContinuedProcessingTask) {
        guard !guards.isEmpty else { t.setTaskCompleted(success: true); return }
        task = t
        isRunning = true
        total = guards.count
        finished = 0
        t.progress.totalUnitCount = 1000
        t.progress.completedUnitCount = 0
        t.expirationHandler = { [weak self] in
            MainActor.assumeIsolated { self?.expireAll() }
        }
        refresh()
        // 流式没有确定进度：按已完成项计实进度，其余部分缓慢推进，避免被系统判定为停滞。
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning, let t = self.task as? BGContinuedProcessingTask else { return }
                let floor = Int64(Double(self.finished) / Double(max(self.total, 1)) * 1000)
                let current = max(t.progress.completedUnitCount, floor)
                t.progress.completedUnitCount = min(990, current + max(1, (990 - current) / 60))
            }
        }
    }

    private var headline: String {
        let chats = guards.values.filter { $0.title == Self.chatTitle }.count
        let images = guards.count - chats
        if images == 0 { return "MolaGPT 正在生成回答" }
        if chats == 0 { return "MolaGPT 正在生成图片" }
        return "MolaGPT 正在处理"
    }

    private var subline: String {
        let n = max(guards.count, 1)
        return n == 1 ? "完成后会通知你" : "还有 \(n) 项任务"
    }

    nonisolated static let chatTitle = "chat"
    nonisolated static let imageTitle = "image"

    private func refresh() {
        guard #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask else { return }
        t.updateTitle(headline, subtitle: subline)
        let floor = Int64(Double(finished) / Double(max(total, 1)) * 1000)
        if t.progress.completedUnitCount < floor { t.progress.completedUnitCount = min(floor, 990) }
    }

    /// 系统或用户终止了持续任务：剩余工作按「后台时间用完」处理。
    private func expireAll() {
        let pending = Array(guards.values)
        complete(success: false)
        for g in pending { g.expire() }
    }

    private func complete(success: Bool) {
        ticker?.cancel(); ticker = nil
        isRunning = false
        if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask {
            if success { t.progress.completedUnitCount = t.progress.totalUnitCount }
            t.setTaskCompleted(success: success)
        }
        task = nil
    }
}

/// 设备特征。iOS 没有「是否有灵动岛」的公开接口，按安全区判断：
/// 灵动岛机型竖屏顶部安全区 ≥59pt（横屏为左右），刘海机型 44–50pt，Home 键机型 20pt；iPad 一律视为没有。
@MainActor
enum DeviceTraits {
    static var hasDynamicIsland: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let w = windows.first(where: \.isKeyWindow) ?? windows.first else { return false }
        let i = w.safeAreaInsets
        return max(i.top, i.left, i.right) >= 55
    }
}
