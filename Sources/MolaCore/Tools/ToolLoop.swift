import Foundation

/// 多轮工具调用驱动（对应安卓 runToolRound / streamAnthropicToolRound / runResponseToolRound / Gemini 工具轮）。
/// - 每轮：发请求 → 流式显示 → 累积工具调用 → 串行执行 → 原生形状回放 → 下一轮。
/// - 是否继续只看本轮有没有工具调用（不看 finish_reason）。
/// - 安卓没有轮数上限；这里设上限，超过后告诉模型直接作答，再给一轮收尾。
/// 传输层由调用方注入（Darwin 用 URLSession.bytes；单测用假数据），因此本文件可在 Linux 上测试。
public enum ToolLoop {
    /// 发出请求并返回响应行（保留空行）。HTTP 非 2xx 时应抛 `ProviderError.http`。
    public typealias Transport = @Sendable (HTTPRequestSpec) async throws -> AsyncThrowingStream<String, Error>

    public static func run(_ request: ChatRequest, executor: (any ToolExecutor)?, maxRounds: Int = 16,
                           transport: @escaping Transport) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await loop(request, executor: executor, maxRounds: maxRounds, transport: transport, cont: cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func loop(_ request: ChatRequest, executor: (any ToolExecutor)?, maxRounds: Int,
                             transport: Transport, cont: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        let type = request.provider.type
        var req = request
        if executor == nil { req.tools = [] }
        let toolNames = Set(req.tools.map(\.name))
        var baseUsage = Usage()
        var turnItems: [JSONValue] = []
        var round = 0

        while true {
            try Task.checkCancellation()
            round += 1
            let spec = try ProviderAdapters.buildRequest(req)
            let lines = try await transport(spec)

            var parser = SSEParser()
            var decoder = ProviderAdapters.decoder(for: type)
            var acc = ToolRoundAccumulator(type: type)
            acc.replayReasoning = req.wireThinkingKind == .deepseekThinking
            var roundUsage = Usage()
            var finishReason: String?
            var failure: String?
            var nonSSE = ""
            var sawSSE = false

            func handle(_ ev: SSEEvent) {
                acc.observe(ev)
                for e in decoder.decode(ev) { route(e) }
            }
            func route(_ e: StreamEvent) {
                switch e {
                case .usage(let u):
                    roundUsage = roundUsage.merged(with: u)
                    cont.yield(.usage(baseUsage.adding(roundUsage)))
                case .finish(let r): finishReason = r ?? finishReason
                case .failed(let m): failure = m
                case .tool: break // 解析器的半截工具事件不显示，由本循环统一发生命周期
                default: cont.yield(e)
                }
            }

            for try await line in lines {
                try Task.checkCancellation()
                if !sawSSE {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("data:") || t.hasPrefix("event:") || t.hasPrefix(":") { sawSSE = true }
                    else if !t.isEmpty { nonSSE += line + "\n"; continue }
                }
                if let ev = parser.feed(line: line) { handle(ev) }
            }
            if let ev = parser.finish() { handle(ev) }
            if !sawSSE, !nonSSE.isEmpty {
                // 服务端忽略 stream=true，直接回了整段 JSON。
                if let text = ProviderAdapters.parseNonStreamText(type, body: Data(nonSSE.utf8)) {
                    cont.yield(.delta(text: text, thinking: nil))
                } else {
                    throw ProviderError.decoding(ProviderError.summarize(nonSSE))
                }
            }
            for e in decoder.finish() { route(e) }

            if let failure { cont.yield(.failed(failure)); return }
            baseUsage = baseUsage.adding(roundUsage)

            let calls = req.tools.isEmpty ? [] : acc.calls
            if calls.isEmpty || round > maxRounds + 1 {
                if !turnItems.isEmpty {
                    turnItems += acc.assistantReplay(calls: [])
                    cont.yield(.wireHistory(WireHistory(providerType: type, modelId: req.model.id, items: turnItems)))
                }
                cont.yield(.finish(reason: finishReason ?? "stop"))
                return
            }

            let assistantItems = acc.assistantReplay(calls: calls)
            var results: [ToolResult] = []
            for call in calls {
                try Task.checkCancellation()
                let fid = "tool_" + call.id
                let label = ToolLabels.label(call.name)
                cont.yield(.tool(ToolCallFragment(id: fid, name: call.name, status: .running, label: label, argsJson: call.arguments)))
                var result: ToolResult
                if round > maxRounds {
                    result = .failure("Tool call limit reached. 工具调用次数已达上限，请直接根据已有信息回答用户。")
                } else if !toolNames.contains(call.name) {
                    result = .failure("Tool \(call.name) is not enabled for this conversation.")
                } else if let executor {
                    result = await executor.execute(call, emit: { cont.yield($0) })
                    if !result.failed && ToolLabels.looksFailed(result.output) { result.failed = true }
                } else {
                    result = .failure("Unsupported tool: \(call.name)")
                }
                let status: ToolStatus = Task.isCancelled ? .cancelled : (result.failed ? .failed : .success)
                cont.yield(.tool(ToolCallFragment(id: fid, name: call.name, status: status, label: label, argsJson: call.arguments,
                                                  resultPreview: ToolLabels.preview(call: call, result: result))))
                results.append(result)
            }
            let resultItems = ToolRoundAccumulator.resultsReplay(type, calls: calls, results: results)
            turnItems += assistantItems + resultItems
            req.messages.append(WireMessage(role: .assistant, parts: [.text(" ")], native: assistantItems + resultItems, nativeType: type))
        }
    }
}
