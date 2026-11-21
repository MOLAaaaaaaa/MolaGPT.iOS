import Foundation
import MolaCore
import MolaStorage

/// 官方模型在界面里表现为一个虚拟服务「MolaGPT」，选择、思考开关等沿用 BYOK 的界面逻辑；
/// 发送时由 `MolaChatService` 走官方协议（自动路由、ALTCHA 短 token、断线续传、停止）。
enum MolaVirtualProvider {
    static let id = "molagpt"

    static func provider(_ models: [MolaModel]) -> ByokProvider {
        ByokProvider(id: id, name: "MolaGPT", type: .openAICompat, baseUrl: MolaEndpoints.base, apiKey: nil, chatPath: MolaEndpoints.chatAuto,
                     models: models.map { m in
                         ProviderModel(id: m.id, displayName: m.disabledReason.map { "\(m.displayName)（\($0)）" } ?? m.displayName,
                                       supportsVision: m.supportsVision, supportsThinking: m.supportsThinking, supportsToolCalling: false,
                                       thinkingConfig: m.supportsThinking
                                           ? ThinkingConfig(kind: .openAIReasoningEffort, effortLevels: m.supportsReasoningEffort ? ["low", "medium", "high"] : [], defaultEffort: "medium")
                                           : ThinkingConfig(kind: .none),
                                       enabled: m.disabledReason == nil)
                     })
    }
}

struct MolaChatService {
    let session: MolaSession
    let account: AccountManager

    enum ChatError: LocalizedError {
        case disabled(String), routeFailed
        var errorDescription: String? {
            switch self { case .disabled(let r): return r; case .routeFailed: return "自动路由失败，请换一个模型重试" }
        }
    }

    /// 流式对话；断流时按 offset 续传（3–30 秒指数退避，最多 8 次）。
    func stream(options: MolaChatOptions, messages: [WireMessage]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if let r = options.model.disabledReason { throw ChatError.disabled(r) }
                    var opts = options
                    let wire = MolaChatAPI.messages(messages, system: nil)
                    var apiURL = MolaEndpoints.resolve(options.model.apiUrl) ?? MolaEndpoints.url(MolaEndpoints.chatAuto)
                    var routes: JSONValue?
                    var modelName: String?
                    if options.model.isAuto {
                        let token = try await session.chatToken()
                        var body = MolaChatAPI.body(opts, messages: wire)
                        body["stream"] = false
                        let (s, data) = try await session.send(MolaChatAPI.request(url: apiURL, body: body, shortToken: token,
                                                                                    idempotencyKey: opts.streamSessionId + "-route", stream: false))
                        guard (200..<300).contains(s), let route = MolaChatAPI.parseRoute(data), let url = MolaEndpoints.resolve(route.apiUrl) else {
                            throw ChatError.routeFailed
                        }
                        apiURL = url
                        routes = route.raw
                        modelName = route.modelName
                        if let t = route.thinking { opts.useThinking = t }
                        if let e = route.reasoningEffort { opts.reasoningEffort = e }
                        if let n = route.network { opts.network = n }
                    }
                    let body = MolaChatAPI.body(opts, messages: wire, routes: routes, modelOverride: modelName)
                    var decoder = MolaStreamDecoder()
                    var attempt = 0
                    var resuming = false
                    var done = false
                    while !done {
                        try Task.checkCancellation()
                        let token = try await session.chatToken()
                        let spec = resuming
                            ? MolaChatAPI.request(url: apiURL, body: MolaChatAPI.resumeBody(streamSessionId: opts.streamSessionId, offset: decoder.dataFrames),
                                                  shortToken: token, idempotencyKey: opts.streamSessionId + "-resume-\(attempt)")
                            : MolaChatAPI.request(url: apiURL, body: body, shortToken: token, idempotencyKey: opts.streamSessionId)
                        do {
                            let lines = try await ChatClient.lines(session: session.urlSession, spec: spec)
                            var parser = SSEParser()
                            for try await line in lines {
                                try Task.checkCancellation()
                                guard let ev = parser.feed(line: line) else { continue }
                                for e in decoder.decode(ev) {
                                    cont.yield(e)
                                    if case .finish = e { done = true }
                                    if case .failed = e { done = true }
                                }
                            }
                            if let ev = parser.finish() { for e in decoder.decode(ev) { cont.yield(e) } }
                            if !done { throw URLError(.networkConnectionLost) }
                        } catch let e as ProviderError {
                            if case .http(401, _) = e { await session.invalidateShortToken(); throw MolaSession.SessionError.expired }
                            throw e
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let e as URLError where e.code != .cancelled && attempt < 8 {
                            attempt += 1
                            resuming = true
                            try await Task.sleep(for: .seconds(min(30, 3 * pow(2, Double(attempt - 1)))))
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func stop(_ streamSessionId: String) async {
        guard let token = try? await session.chatToken() else { return }
        _ = try? await session.send(MolaChatAPI.request(url: MolaEndpoints.url(MolaEndpoints.stopStream), body: MolaChatAPI.stopBody(streamSessionId),
                                                        shortToken: token, idempotencyKey: UUID().uuidString, stream: false))
    }

    func title(user: String, answer: String) async -> String? {
        guard let token = try? await session.chatToken(),
              let (s, data) = try? await session.send(MolaChatAPI.request(url: MolaEndpoints.url(MolaEndpoints.generateTitle),
                                                                          body: MolaChatAPI.titleBody(user: user, answer: answer),
                                                                          shortToken: token, idempotencyKey: UUID().uuidString, stream: false)),
              (200..<300).contains(s) else { return nil }
        return MolaChatAPI.parseTitle(data)
    }
}
