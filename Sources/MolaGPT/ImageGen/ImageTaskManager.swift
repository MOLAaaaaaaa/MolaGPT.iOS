import Foundation
import Observation
import UIKit
import MolaCore
import MolaStorage

/// 画图后台任务（对应安卓 ImageTaskManager）：先落库 running 版本，再在应用级 Task 里请求，结果按版本 id 回写；
/// 离开页面、切换任务不影响在途生成，删除任务才取消。
@MainActor
@Observable
final class ImageTaskManager {
    @ObservationIgnored unowned let app: AppModel
    private(set) var running: [String: Task<Void, Never>] = [:]   // versionId → task
    private(set) var revision = 0

    init(app: AppModel) {
        self.app = app
        try? app.store.failStaleImageVersions()
    }

    var runningTaskIds: Set<String> { Set(app.store.imageTasks().filter { t in app.store.imageVersions(task: t.id).contains { $0.status == .running } }.map(\.id)) }

    /// 可用于画图的服务与模型（图像用途的服务 + 标了「图像生成」的模型）。
    var targets: [(ByokProvider, ProviderModel)] {
        app.providers.filter(\.enabled).flatMap { p in
            p.models.filter { $0.enabled && ($0.supportsImageGeneration || p.purpose == .image) }.map { (p, $0) }
        }
    }

    func target(_ task: ImageTask) -> (ByokProvider, ProviderModel)? {
        if let pid = task.providerId, let mid = task.modelId, let p = app.provider(pid), let m = p.model(mid) { return (p, m) }
        return targets.first
    }

    func newTask() -> ImageTask {
        var t = ImageTask()
        if let (p, m) = targets.first { t.providerId = p.id; t.modelId = m.id }
        try? app.store.upsert(t)
        revision += 1
        return t
    }

    func delete(_ task: ImageTask) {
        for v in app.store.imageVersions(task: task.id) { running[v.id]?.cancel(); running[v.id] = nil }
        try? app.store.deleteImageTask(task.id)
        revision += 1
    }

    /// 提交一轮：生成新图或编辑参考图。
    func submit(task: ImageTask, prompt: String, refs: [ImageRef], size: String, count: Int, params: ImageParams, perImage: Bool) {
        guard let (p, m) = target(task) else { return }
        let runs = app.store.imageRuns(task.id)
        let versions = app.store.imageVersions(task: task.id)
        var effectiveRefs = refs
        let previous = runs.last.flatMap { r in versions.first { $0.id == r.activeVersionId && $0.status == .success } }
        let kind = WorkbenchPlan.kind(mode: task.mode, supportsEdit: m.supportsImageEdit, refs: refs.count, perImage: perImage, hasPrevious: previous != nil)
        if kind == .chain, let prev = previous?.outputs.first { effectiveRefs = [ImageRef(src: prev.src, fromOutput: true)] }
        let run = ImageRun(taskId: task.id, prompt: prompt, kind: kind, providerId: p.id, modelId: m.id, size: size,
                           count: (kind == .new || task.mode == .gen) ? count : 1, params: params, refs: effectiveRefs)
        try? app.store.upsert(run)
        var t = task
        if t.title == "新的画图" { t.title = String(prompt.prefix(20)) }
        t.updatedAt = IDs.nowMs()
        try? app.store.upsert(t)
        start(run: run)
    }

    /// 再次生成：同一轮追加版本；重试失败版本：原地重跑。
    func regenerate(_ run: ImageRun) { start(run: run) }

    func retry(_ version: ImageVersion, run: ImageRun) { start(run: run, reuse: version) }

    /// 任务属性在视图里直接写库后，用它通知刷新。
    func objectWillChangeHack() { revision += 1 }

    func cancel(_ versionId: String) {
        running[versionId]?.cancel()
    }

    private func start(run: ImageRun, reuse: ImageVersion? = nil) {
        var v = reuse ?? ImageVersion(runId: run.id, taskId: run.taskId)
        v.status = .running; v.error = nil; v.outputs = []; v.startedAt = IDs.nowMs(); v.endedAt = nil
        try? app.store.upsert(v)
        var r = run
        r.activeVersionId = v.id
        try? app.store.upsert(r)
        revision += 1
        let versionId = v.id
        guard let p = app.provider(run.providerId ?? ""), let m = p.model(run.modelId ?? "") else {
            finish(versionId, run: run, outputs: [], error: "图像服务已不可用"); return
        }
        let config = app.settings.imageGenConfig
        let session = URLSession.shared
        let refs = run.refs
        // 后台时间到期不主动取消：挂起期间连接若断开，回来后按错误结束并提示原因。
        let bg = BackgroundGuard(name: "mola.image", title: ContinuedWork.imageTitle) { _ in }
        LiveActivityCenter.shared.start(key: versionId, kind: .image, targetId: run.taskId, title: run.prompt,
                                        model: m.displayName, phase: .imaging, snippet: run.count > 1 ? "\(run.count) 张" : "")
        running[versionId] = Task { [weak self] in
            defer { bg.end() }
            var outputs: [ImageOutput] = []
            var errorText: String?
            do {
                if refs.isEmpty {
                    // 一次请求 n 张；不支持 n 的接口逐张请求
                    let spec = try ImageGenAPI.generate(provider: p, model: m.id, prompt: run.prompt, config: config, params: run.params, count: run.count, size: run.size)
                    var srcs = try await Self.fetch(spec, session: session)
                    while srcs.count < run.count && p.imageFormatFor(m.id) != .openAIImages {
                        try Task.checkCancellation()
                        srcs += try await Self.fetch(spec, session: session)
                    }
                    outputs = srcs.prefix(run.count).compactMap { Self.save($0) }
                } else {
                    var images: [(Data, String)] = []
                    for ref in refs { if let d = await LocalImages.data(ref.src) { images.append((Self.pngIfNeeded(d), "image/png")) } }
                    if run.kind == .perImage {
                        for img in images {
                            try Task.checkCancellation()
                            let spec = try ImageGenAPI.edit(provider: p, model: m.id, prompt: run.prompt, size: run.size, images: [img], mask: nil, params: run.params)
                            outputs += try await Self.fetch(spec, session: session).compactMap { Self.save($0) }
                        }
                    } else {
                        let spec = try ImageGenAPI.edit(provider: p, model: m.id, prompt: run.prompt, size: run.size, images: images, mask: nil, params: run.params)
                        outputs = try await Self.fetch(spec, session: session).compactMap { Self.save($0) }
                    }
                }
                if outputs.isEmpty { errorText = "没有返回图片" }
            } catch is CancellationError {
                errorText = "已取消"
            } catch {
                errorText = bg.expired && error is URLError
                    ? "应用在后台时请求被系统中断，请重试"
                    : error.localizedDescription
            }
            self?.finish(versionId, run: run, outputs: outputs, error: errorText, canceled: Task.isCancelled)
        }
    }

    private func finish(_ versionId: String, run: ImageRun, outputs: [ImageOutput], error: String?, canceled: Bool = false) {
        running[versionId] = nil
        LiveActivityCenter.shared.end(key: versionId, phase: canceled ? .stopped : (error == nil ? .done : .failed),
                                      snippet: error ?? (outputs.isEmpty ? nil : "\(outputs.count) 张图片"))
        guard var v = app.store.imageVersions(task: run.taskId).first(where: { $0.id == versionId }) else { return }
        v.outputs = outputs
        v.status = canceled ? .canceled : (error == nil ? .success : .failed)
        v.error = error
        v.endedAt = IDs.nowMs()
        try? app.store.upsert(v)
        revision += 1
        if !canceled, let task = app.store.imageTasks().first(where: { $0.id == run.taskId }) {
            app.notifier.notifyImage(taskId: task.id, title: task.title, count: outputs.count, failed: error != nil)
        }
    }

    nonisolated static func fetch(_ spec: HTTPRequestSpec, session: URLSession) async throws -> [String] {
        let (data, resp) = try await session.data(for: spec.urlRequest)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        let r = ImageGenAPI.extractImages(data)
        if r.images.isEmpty { throw ProviderError.decoding(r.text ?? "没有返回图片") }
        var out: [String] = []
        for src in r.images {
            if src.hasPrefix("http"), let u = URL(string: src) {
                var req = URLRequest(url: u)
                req.setValue(MolaUA.browser, forHTTPHeaderField: "User-Agent")
                if let (d, _) = try? await URLSession.shared.data(for: req) { out.append("data:image/png;base64,\(d.base64EncodedString())"); continue }
            }
            out.append(src)
        }
        return out
    }

    nonisolated static func save(_ src: String) -> ImageOutput? {
        guard let (data, ext) = ImageGenAPI.decodeDataURI(src) else { return ImageOutput(src: src) }
        let dir = AppPaths.imageWorkbench
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext)"
        guard (try? data.write(to: dir.appendingPathComponent(name))) != nil else { return nil }
        let size = UIImage(data: data)?.size
        return ImageOutput(src: "local:\(dir.lastPathComponent)/\(name)", width: size.map { Int($0.width) }, height: size.map { Int($0.height) })
    }

    nonisolated static func pngIfNeeded(_ d: Data) -> Data {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return d }
        return UIImage(data: d)?.pngData() ?? d
    }
}
