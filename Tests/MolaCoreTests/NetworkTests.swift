import XCTest
@testable import MolaCore

final class SSETests: XCTestCase {
    func testParsesMultilineAndHeartbeat() {
        let text = ": ping\nevent: message\ndata: {\"a\":1}\n\ndata: line1\ndata: line2\n\ndata: [DONE]\n\n"
        let evs = SSEParser.parseAll(text)
        XCTAssertEqual(evs.count, 3)
        XCTAssertEqual(evs[0].event, "message")
        XCTAssertEqual(evs[1].data, "line1\nline2")
        XCTAssertTrue(evs[2].isDone)
    }

    func testCRLFAndNoTrailingBlank() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: "data: {\"x\":1}\r"))
        XCTAssertEqual(p.feed(line: "\r")?.data, "{\"x\":1}")
        XCTAssertNil(p.feed(line: "data: tail"))
        XCTAssertEqual(p.finish()?.data, "tail")
    }

    func testNonStandardMissingBlankLines() {
        let evs = SSEParser.parseAll("data: {\"a\":1}\ndata: {\"a\":2}\ndata: [DONE]")
        XCTAssertEqual(evs.map(\.data), ["{\"a\":1}", "{\"a\":2}", "[DONE]"])
    }

    func testInlineThinkSplitterAcrossChunks() {
        var s = InlineThinkSplitter()
        var vis = "", think = ""
        for chunk in ["Hi <thi", "nk>reason", "ing</th", "ink> answer"] {
            let r = s.feed(chunk); vis += r.visible; think += r.thinking
        }
        let f = s.flush(); vis += f.visible; think += f.thinking
        XCTAssertEqual(vis, "Hi  answer")
        XCTAssertEqual(think, "reasoning")
    }
}

final class RequestBuilderTests: XCTestCase {
    func provider(_ type: ByokProviderType, _ base: String, key: String = "sk-test") -> ByokProvider {
        ByokProvider(id: "p", name: "P", type: type, baseUrl: base, apiKey: key)
    }

    func req(_ p: ByokProvider, _ model: String, thinking: Bool = false, effort: String? = nil, cfg: ThinkingConfig? = nil) -> ChatRequest {
        ChatRequest(provider: p, model: ProviderModel(id: model, thinkingConfig: cfg), system: "SYS",
                    messages: [.text(.user, "hello")], temperature: 0.7, useThinking: thinking, reasoningEffort: effort)
    }

    func testOpenAIBodyAndHeaders() throws {
        let spec = try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://api.openai.com/"), "gpt-5", thinking: true, effort: "low"))
        XCTAssertEqual(spec.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(spec.headers["Authorization"], "Bearer sk-test")
        let b = try XCTUnwrap(spec.bodyJSON)
        XCTAssertEqual(b["messages"]?[0]?["role"]?.stringValue, "system")
        XCTAssertEqual(b["messages"]?[1]?["content"]?.stringValue, "hello")
        XCTAssertEqual(b["reasoning_effort"]?.stringValue, "low")
        XCTAssertEqual(b["stream_options"]?["include_usage"]?.boolValue, true)
    }

    func testOpenRouterUsesReasoningObjectAndDisables() throws {
        let p = provider(.openAICompat, "https://openrouter.ai/api/")
        let on = try XCTUnwrap(try ProviderAdapters.buildRequest(req(p, "anthropic/claude-sonnet-4", thinking: true, effort: "high")).bodyJSON)
        XCTAssertEqual(on["reasoning"]?["effort"]?.stringValue, "high")
        XCTAssertNil(on["thinking"])
        let off = try XCTUnwrap(try ProviderAdapters.buildRequest(req(p, "deepseek/deepseek-r1")).bodyJSON)
        XCTAssertEqual(off["reasoning"]?["enabled"]?.boolValue, false)
        let spec = try ProviderAdapters.buildRequest(req(p, "x"))
        XCTAssertEqual(spec.headers["X-Title"], "MolaGPT")
    }

    func testDeepSeekKimiQwenDialects() throws {
        let ds = try XCTUnwrap(try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://api.deepseek.com/"), "deepseek-chat", thinking: true, effort: "high")).bodyJSON)
        XCTAssertEqual(ds["thinking"]?["type"]?.stringValue, "enabled")
        XCTAssertEqual(ds["reasoning_effort"]?.stringValue, "high")
        let dsOff = try XCTUnwrap(try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://api.deepseek.com/"), "deepseek-chat")).bodyJSON)
        XCTAssertEqual(dsOff["thinking"]?["type"]?.stringValue, "disabled")
        let kimi = try XCTUnwrap(try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://api.moonshot.cn/"), "kimi-k2.5", thinking: true)).bodyJSON)
        XCTAssertEqual(kimi["thinking"]?["type"]?.stringValue, "enabled")
        let qwen = try XCTUnwrap(try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://dashscope.aliyuncs.com/compatible-mode/"), "qwen3-max", thinking: true, effort: "high")).bodyJSON)
        XCTAssertEqual(qwen["enable_thinking"]?.boolValue, true)
        XCTAssertEqual(qwen["thinking_budget"]?.intValue, 16384)
        let qwenOff = try XCTUnwrap(try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://dashscope.aliyuncs.com/compatible-mode/"), "qwen3-max")).bodyJSON)
        XCTAssertEqual(qwenOff["enable_thinking"]?.boolValue, false)
    }

    func testNonReasoningModelSendsNothing() throws {
        let b = try XCTUnwrap(try ProviderAdapters.buildRequest(req(provider(.openAICompat, "https://example.com/"), "llama-3-70b", thinking: true)).bodyJSON)
        XCTAssertNil(b["reasoning_effort"]); XCTAssertNil(b["reasoning"]); XCTAssertNil(b["thinking"])
    }

    func testAnthropicBody() throws {
        let p = provider(.anthropic, "https://api.anthropic.com/", key: "ak")
        let spec = try ProviderAdapters.buildRequest(req(p, "claude-opus-4", thinking: true, effort: "high"))
        XCTAssertEqual(spec.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(spec.headers["x-api-key"], "ak")
        XCTAssertEqual(spec.headers["anthropic-version"], "2023-06-01")
        let b = try XCTUnwrap(spec.bodyJSON)
        XCTAssertEqual(b["system"]?[0]?["text"]?.stringValue, "SYS")
        XCTAssertEqual(b["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(b["messages"]?[0]?["content"]?[0]?["cache_control"]?["type"]?.stringValue, "ephemeral")

        let budget = try XCTUnwrap(try ProviderAdapters.buildRequest(req(p, "claude-3-7-sonnet", thinking: true, effort: "high",
            cfg: ThinkingConfig(kind: .claudeBudget))).bodyJSON)
        XCTAssertEqual(budget["thinking"]?["budget_tokens"]?.intValue, 28000)
        XCTAssertEqual(budget["max_tokens"]?.intValue, 29024)
    }

    func testGeminiEndpointAndThinking() throws {
        let p = provider(.gemini, "https://generativelanguage.googleapis.com/v1beta/", key: "g k")
        let spec = try ProviderAdapters.buildRequest(req(p, "gemini-2.5-flash", thinking: true, effort: "low"))
        XCTAssertEqual(spec.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse&key=g%20k")
        XCTAssertNil(spec.headers["Authorization"])
        let b = try XCTUnwrap(spec.bodyJSON)
        XCTAssertEqual(b["generationConfig"]?["thinkingConfig"]?["thinkingBudget"]?.intValue, 2048)
        XCTAssertEqual(b["systemInstruction"]?["parts"]?[0]?["text"]?.stringValue, "SYS")
        let lvl = try XCTUnwrap(try ProviderAdapters.buildRequest(req(p, "gemini-3-pro-preview")).bodyJSON)
        // 3 Pro 常开：未开开关也发 thinkingLevel，且不发 temperature
        XCTAssertEqual(lvl["generationConfig"]?["thinkingConfig"]?["thinkingLevel"]?.stringValue, "high")
        XCTAssertNil(lvl["generationConfig"]?["temperature"])
    }

    func testResponsesBody() throws {
        let p = provider(.openAIResponse, "https://api.openai.com/")
        var r = req(p, "o3", thinking: true)
        r.messages.append(.text(.assistant, "prev"))
        let b = try XCTUnwrap(try ProviderAdapters.buildRequest(r).bodyJSON)
        XCTAssertEqual(b["instructions"]?.stringValue, "SYS")
        XCTAssertEqual(b["input"]?[0]?["content"]?[0]?["type"]?.stringValue, "input_text")
        XCTAssertEqual(b["input"]?[1]?["content"]?[0]?["type"]?.stringValue, "output_text")
        XCTAssertEqual(b["reasoning"]?["effort"]?.stringValue, "high")
    }

    func testImagePartsPerProvider() throws {
        var r = req(provider(.openAICompat, "https://api.openai.com/"), "gpt-4o")
        r.messages = [WireMessage(role: .user, parts: [.text("看图"), .image(mimeType: "image/png", base64: "AAAA", url: nil)])]
        let oa = try XCTUnwrap(try ProviderAdapters.buildRequest(r).bodyJSON)
        XCTAssertEqual(oa["messages"]?[1]?["content"]?[1]?["image_url"]?["url"]?.stringValue, "data:image/png;base64,AAAA")
        r.provider = provider(.anthropic, "https://api.anthropic.com/")
        let an = try XCTUnwrap(try ProviderAdapters.buildRequest(r).bodyJSON)
        XCTAssertEqual(an["messages"]?[0]?["content"]?[1]?["source"]?["data"]?.stringValue, "AAAA")
        r.provider = provider(.gemini, "https://generativelanguage.googleapis.com/v1beta/")
        let ge = try XCTUnwrap(try ProviderAdapters.buildRequest(r).bodyJSON)
        XCTAssertEqual(ge["contents"]?[0]?["parts"]?[1]?["inlineData"]?["mimeType"]?.stringValue, "image/png")
    }

    func testCustomBodyOverridesButProtectsKeys() throws {
        var r = req(provider(.openAICompat, "https://api.openai.com/"), "gpt-4o")
        r.model.customBody = [CustomBodyParam(key: "top_p", type: .number, value: "0.5"),
                              CustomBodyParam(key: "messages", type: .string, value: "x")]
        let b = try XCTUnwrap(try ProviderAdapters.buildRequest(r).bodyJSON)
        XCTAssertEqual(b["top_p"]?.doubleValue, 0.5)
        XCTAssertNotNil(b["messages"]?.arrayValue)
    }
}

final class DecoderTests: XCTestCase {
    func run(_ type: ByokProviderType, _ sse: String) -> StreamAccumulator {
        var d = ProviderAdapters.decoder(for: type)
        var acc = StreamAccumulator()
        for ev in SSEParser.parseAll(sse) { for e in d.decode(ev) { acc.apply(e) } }
        for e in d.finish() { acc.apply(e) }
        return acc
    }

    func text(_ acc: StreamAccumulator) -> String {
        acc.fragments.compactMap { if case .text(_, let t) = $0 { return t }; return nil }.joined()
    }

    func thinking(_ acc: StreamAccumulator) -> String {
        acc.fragments.compactMap { if case .thinking(_, let t, _, _) = $0 { return t }; return nil }.joined()
    }

    func testOpenAIStream() {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"想"}}]}

        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":4}}}

        data: [DONE]

        """
        let acc = run(.openAICompat, sse)
        XCTAssertEqual(text(acc), "你好")
        XCTAssertEqual(thinking(acc), "想")
        XCTAssertEqual(acc.usage.promptTokens, 10)
        XCTAssertEqual(acc.usage.cachedTokens, 4)
        XCTAssertEqual(acc.finishReason, "stop")
    }

    func testOpenAIError() {
        let acc = run(.openAICompat, "data: {\"error\":{\"message\":\"bad key\"}}\n\n")
        XCTAssertEqual(acc.error, "bad key")
    }

    func testAnthropicStream() {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":7,"output_tokens":1}}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        event: message_delta
        data: {"type":"message_delta","usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let acc = run(.anthropic, sse)
        XCTAssertEqual(text(acc), "Hi"); XCTAssertEqual(thinking(acc), "hmm")
        XCTAssertEqual(acc.usage.promptTokens, 10)
        XCTAssertEqual(acc.usage.cachedTokens, 7)
        XCTAssertEqual(acc.usage.completionTokens, 12)
    }

    func testGeminiStream() {
        let sse = """
        data: {"candidates":[{"content":{"parts":[{"text":"t","thought":true},{"text":"A"}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"B"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2,"thoughtsTokenCount":3,"totalTokenCount":9}}

        """
        let acc = run(.gemini, sse)
        XCTAssertEqual(text(acc), "AB"); XCTAssertEqual(thinking(acc), "t")
        XCTAssertEqual(acc.usage.completionTokens, 5)
        XCTAssertEqual(acc.finishReason, "stop")
    }

    func testResponsesStream() {
        let sse = """
        data: {"type":"response.reasoning_summary_text.delta","delta":"r"}

        data: {"type":"response.output_text.delta","delta":"OK"}

        data: {"type":"response.completed","response":{"usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}

        """
        let acc = run(.openAIResponse, sse)
        XCTAssertEqual(text(acc), "OK"); XCTAssertEqual(thinking(acc), "r")
        XCTAssertEqual(acc.usage.totalTokens, 10)
    }

    func testThinkingDurationClosesOnText() {
        var acc = StreamAccumulator(startedAt: Date(timeIntervalSince1970: 0))
        acc.apply(.delta(text: nil, thinking: "a"), now: Date(timeIntervalSince1970: 1))
        acc.apply(.delta(text: "b", thinking: nil), now: Date(timeIntervalSince1970: 3.5))
        guard case .thinking(_, _, _, let dur) = acc.fragments[0] else { return XCTFail() }
        XCTAssertEqual(dur, 2500)
        XCTAssertEqual(acc.stats(pricing: nil, modelId: "m", now: Date(timeIntervalSince1970: 4)).ttftMs, 1000)
    }
}

final class ModelTests: XCTestCase {
    func testPricing() {
        let p = ModelPricing(input: 3, output: 15, cacheRead: 0.3)
        let c = p.cost(Usage(promptTokens: 1_000_000, completionTokens: 100_000, cachedTokens: 500_000))
        XCTAssertEqual(c!, 0.5 * 3 + 0.5 * 0.3 + 0.1 * 15, accuracy: 1e-9)
        XCTAssertNil(p.cost(Usage(promptTokens: 10, completionTokens: 1, cacheWriteTokens: 5)))
        XCTAssertEqual(ModelPricing.format(0.001234), "$0.0012")
    }

    func testThinkingInference() {
        XCTAssertEqual(Thinking.inferFromModelId("claude-sonnet-4-5"), .claudeAdaptive)
        XCTAssertEqual(Thinking.inferFromModelId("moonshot/kimi-k3"), .openAIReasoningEffort)
        XCTAssertEqual(Thinking.inferFromModelId("kimi-k2.5"), .kimi)
        XCTAssertEqual(Thinking.inferFromModelId("gemini-3-pro"), .geminiLevel)
        XCTAssertEqual(Thinking.inferFromModelId("gpt-4o"), .none)
        XCTAssertEqual(Thinking.inferFromModelId("glm-4.6"), .openAIReasoningEffort)
        XCTAssertNil(Thinking.autoConfig(modelId: "gpt-4o", baseUrl: "https://api.openai.com"))
        XCTAssertEqual(Thinking.autoConfig(modelId: "deepseek-v4", baseUrl: "https://api.deepseek.com")?.effortLevels, ["high", "max"])
        XCTAssertEqual(Thinking.resolveEffortLevels(Thinking.config(for: .openAIReasoningEffort), baseUrl: "https://api.stepfun.com").count, 6)
    }

    func testFragmentJSONRoundTrip() throws {
        let frags: [MessageFragment] = [
            .text(id: "a", markdown: "hi"), .thinking(id: "b", text: "t", collapsed: true, durationMs: 5),
            .tool(ToolCallFragment(id: "c", name: "web_search", status: .success)),
            .error(id: "d", message: "x"),
        ]
        let data = try JSONEncoder().encode(frags)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\":\"tool\""))
        XCTAssertEqual(try JSONDecoder().decode([MessageFragment].self, from: data), frags)
    }

    func testModelListParsing() throws {
        let body = Data(#"{"data":[{"id":"gpt-4o"},{"id":"o3-mini"}]}"#.utf8)
        let models = try ModelListAPI.parse(.openAICompat, baseUrl: "https://api.openai.com", body: body)
        XCTAssertEqual(models.map(\.id), ["gpt-4o", "o3-mini"])
        XCTAssertTrue(models[0].supportsVision)
        XCTAssertTrue(models[1].supportsThinking)
        let or = Data(#"{"data":[{"id":"x/y","context_length":1000,"pricing":{"prompt":"0.000001","completion":"0.000002"},"supported_parameters":["tools","reasoning"],"reasoning":{"mandatory":true,"supported_efforts":["low","high"]}}]}"#.utf8)
        let m = try XCTUnwrap(try ModelListAPI.parse(.openAICompat, baseUrl: "https://openrouter.ai/api/", body: or).first)
        XCTAssertEqual(m.pricing!.input, 1, accuracy: 1e-9)
        XCTAssertEqual(m.thinkingConfig?.alwaysOn, true)
        XCTAssertEqual(m.thinkingConfig?.effortLevels, ["low", "high"])
        let gem = Data(#"{"models":[{"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}]}"#.utf8)
        XCTAssertEqual(try ModelListAPI.parse(.gemini, baseUrl: "", body: gem).map(\.id), ["gemini-2.5-pro"])
    }

    func testTitleClean() {
        XCTAssertEqual(Titler.clean("<think>x</think>\n标题：「Swift 并发入门」。"), "Swift 并发入门")
        XCTAssertNil(Titler.clean("HTTP 401 unauthorized"))
        XCTAssertNil(Titler.clean("{\"error\":1}"))
        XCTAssertEqual(Titler.fallback(firstUserText: "  你好\n世界"), "你好")
    }

    func testPromptVariables() {
        let s = PromptVariables.apply("{{user}}/{{model}}/{{provider}}", username: "u", model: "m", provider: "p")
        XCTAssertEqual(s, "u/m/p")
    }

    func testContextBuilderMergesAndAttachesDocs() {
        let sid = "s"
        let hist = [
            ChatMessage(sessionId: sid, role: .user, fragments: [.text(id: "1", markdown: "a")],
                        attachments: [Attachment(name: "f.txt", mimeType: "text/plain", extractedText: "DOC")]),
            ChatMessage(sessionId: sid, role: .user, fragments: [.text(id: "2", markdown: "b")]),
            ChatMessage(sessionId: sid, role: .assistant, fragments: [.thinking(id: "3", text: "t", collapsed: true, durationMs: nil), .text(id: "4", markdown: "c")]),
        ]
        let wire = ContextBuilder.wireMessages(hist, options: .init(), loader: { _ in nil })
        XCTAssertEqual(wire.count, 2)
        XCTAssertTrue(wire[0].text.contains("<file name=\"f.txt\">"))
        XCTAssertTrue(wire[0].text.hasSuffix("b"))
        XCTAssertEqual(wire[1].reasoning, "t")
        XCTAssertEqual(wire[1].text, "c")
    }
}
