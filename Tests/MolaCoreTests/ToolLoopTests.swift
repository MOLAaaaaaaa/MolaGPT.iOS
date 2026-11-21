import XCTest
@testable import MolaCore

private struct EchoExecutor: ToolExecutor {
    func execute(_ call: PendingToolCall, emit: @escaping @Sendable (StreamEvent) -> Void) async -> ToolResult {
        ToolResult("result for \(call.string("q") ?? "?")")
    }
}

/// 按轮次返回预置 SSE 行，并记录每轮请求体。
private final class FakeTransport: @unchecked Sendable {
    var rounds: [[String]]
    var bodies: [JSONValue] = []
    init(_ rounds: [[String]]) { self.rounds = rounds }
    func send(_ spec: HTTPRequestSpec) -> AsyncThrowingStream<String, Error> {
        bodies.append(spec.bodyJSON ?? .null)
        let lines = rounds.isEmpty ? [] : rounds.removeFirst()
        return AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() }
    }
}

final class ToolLoopTests: XCTestCase {
    let tool = ToolSpec(name: "lookup", description: "d", properties: [("q", ToolProperty("query"))], required: ["q"])

    func request(_ type: ByokProviderType) -> ChatRequest {
        var r = ChatRequest(provider: ByokProvider(id: "p", name: "P", type: type, baseUrl: "https://x.test/", apiKey: "k"),
                            model: ProviderModel(id: "m"), messages: [.text(.user, "hi")])
        r.tools = [tool]
        return r
    }

    func collect(_ s: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
        var out: [StreamEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    func testOpenAITwoRounds() async throws {
        let t = FakeTransport([
            [#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"lookup","arguments":"{\"q\":"}}]}}]}"#, "",
             #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"cats\"}"}}]}}]}"#, "",
             #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#, "", "data: [DONE]", ""],
            [#"data: {"choices":[{"delta":{"content":"Answer"}}]}"#, "",
             #"data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":3}}"#, "", "data: [DONE]", ""],
        ])
        let events = try await collect(ToolLoop.run(request(.openAICompat), executor: EchoExecutor(), transport: { t.send($0) }))
        // 工具卡：running → success
        let tools = events.compactMap { if case .tool(let f) = $0 { return f }; return nil }
        XCTAssertEqual(tools.map(\.status), [.running, .success])
        XCTAssertEqual(tools.last?.label, "工具调用")
        // 用量累加
        let lastUsage = events.compactMap { if case .usage(let u) = $0 { return u }; return nil }.last
        XCTAssertEqual(lastUsage?.promptTokens, 30)
        XCTAssertEqual(lastUsage?.completionTokens, 8)
        // 第二轮请求带上 assistant tool_calls + tool 结果
        let msgs = t.bodies[1]["messages"]?.arrayValue ?? []
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[1]["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue, #"{"q":"cats"}"#)
        XCTAssertEqual(msgs[2]["role"]?.stringValue, "tool")
        XCTAssertEqual(msgs[2]["content"]?.stringValue, "result for cats")
        XCTAssertNotNil(t.bodies[0]["tools"]?[0]?["function"]?["parameters"]?["properties"]?["q"])
        // 原生历史
        guard case .wireHistory(let h)? = events.first(where: { if case .wireHistory = $0 { return true }; return false }) else {
            return XCTFail("missing wire history")
        }
        XCTAssertEqual(h.items.count, 3)
        guard case .finish = events.last else { return XCTFail("missing finish") }
    }

    func testAnthropicKeepsThinkingSignature() async throws {
        let t = FakeTransport([
            [#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#, "",
             #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#, "",
             #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}"#, "",
             #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu1","name":"lookup","input":{}}}"#, "",
             #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":\"x\"}"}}"#, "",
             #"data: {"type":"message_stop"}"#, ""],
            [#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#, "",
             #"data: {"type":"message_stop"}"#, ""],
        ])
        _ = try await collect(ToolLoop.run(request(.anthropic), executor: EchoExecutor(), transport: { t.send($0) }))
        let msgs = t.bodies[1]["messages"]?.arrayValue ?? []
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[1]["content"]?[0]?["signature"]?.stringValue, "SIG")
        XCTAssertEqual(msgs[1]["content"]?[1]?["input"]?["q"]?.stringValue, "x")
        XCTAssertEqual(msgs[2]["content"]?[0]?["type"]?.stringValue, "tool_result")
        XCTAssertEqual(t.bodies[0]["tools"]?[0]?["input_schema"]?["required"]?[0]?.stringValue, "q")
    }

    func testGeminiFunctionResponse() async throws {
        let t = FakeTransport([
            [#"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"lookup","args":{"q":"g"}},"thoughtSignature":"TS"}]}}]}"#, ""],
            [#"data: {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#, ""],
        ])
        _ = try await collect(ToolLoop.run(request(.gemini), executor: EchoExecutor(), transport: { t.send($0) }))
        let contents = t.bodies[1]["contents"]?.arrayValue ?? []
        XCTAssertEqual(contents[1]["parts"]?[0]?["thoughtSignature"]?.stringValue, "TS")
        XCTAssertEqual(contents[2]["parts"]?[0]?["functionResponse"]?["response"]?["result"]?.stringValue, "result for g")
        XCTAssertEqual(t.bodies[0]["tools"]?[0]?["functionDeclarations"]?[0]?["parameters"]?["type"]?.stringValue, "OBJECT")
    }

    func testRejectsUndeclaredTool() async throws {
        let t = FakeTransport([
            [#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"evil","arguments":"{}"}}]}}]}"#, "", "data: [DONE]", ""],
            [#"data: {"choices":[{"delta":{"content":"ok"}}]}"#, "", "data: [DONE]", ""],
        ])
        let events = try await collect(ToolLoop.run(request(.openAICompat), executor: EchoExecutor(), transport: { t.send($0) }))
        let tools = events.compactMap { if case .tool(let f) = $0 { return f }; return nil }
        XCTAssertEqual(tools.last?.status, .failed)
        XCTAssertTrue(t.bodies[1]["messages"]?[2]?["content"]?.stringValue?.contains("not enabled") == true)
    }
}
