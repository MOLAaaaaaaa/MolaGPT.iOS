import XCTest
@testable import MolaCore

final class MolaProtocolTests: XCTestCase {
    func testAltcha() {
        let salt = "abc?expires=1&"
        let challenge = SHA256.hexHash(salt + "1234")
        let c = AltchaChallenge(algorithm: "SHA-256", challenge: challenge, maxnumber: 5000, salt: salt, signature: "sig")
        XCTAssertEqual(Altcha.solve(c), 1234)
        let payload = Data(base64Encoded: Altcha.payload(c, number: 1234)).flatMap(JSONValue.parse)
        XCTAssertEqual(payload?["number"]?.intValue, 1234)
        XCTAssertEqual(payload?["salt"]?.stringValue, salt)
    }

    func testPKCECallback() throws {
        let (url, a) = PKCE.begin(.google)
        XCTAssertTrue(url.absoluteString.contains("code_challenge_method=S256"))
        XCTAssertEqual(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let ok = URL(string: "molagpt://oauth_callback?code=xyz&state=\(a.state)")!
        XCTAssertEqual(try PKCE.validate(ok, attempt: a), "xyz")
        XCTAssertThrowsError(try PKCE.validate(URL(string: "molagpt://oauth_callback?code=x&state=bad")!, attempt: a))
        XCTAssertThrowsError(try PKCE.validate(URL(string: "molagpt://oauth_callback?code=x&state=\(a.state)&token=t")!, attempt: a))
        var expired = a; expired.expiresAt = 0
        XCTAssertThrowsError(try PKCE.validate(ok, attempt: expired))
    }

    func testServerStreamMarkers() {
        var d = MolaStreamDecoder()
        var acc = StreamAccumulator()
        func feed(_ s: String) {
            let frame: JSONValue = ["choices": [["delta": ["content": .string(s)]]]]
            for e in d.decode(SSEEvent(data: frame.jsonString())) { acc.apply(e) }
        }
        feed("先搜索<block")
        feed("quote class=\"tool-status completed\" data-tool-name=\"web_search\" data-tool-call=\"c1\">已搜索</blockquote>")
        feed("<think>想想</think>结论")
        for e in d.decode(SSEEvent(data: #"{"molagpt_sources":[{"title":"A","url":"https://a"}]}"#)) { acc.apply(e) }
        for e in d.decode(SSEEvent(data: "[DONE]")) { acc.apply(e) }
        let kinds = acc.fragments.map { f -> String in
            switch f { case .text: return "text"; case .tool: return "tool"; case .thinking: return "think"; case .search: return "search"; default: return "x" }
        }
        XCTAssertEqual(kinds, ["text", "tool", "think", "text", "search"])
        XCTAssertEqual(d.dataFrames, 4)
    }

    func testSyncRoundTrip() {
        let m = ChatMessage(sessionId: "sess_1", role: .assistant, createdAt: 1000,
                            fragments: [.thinking(id: "t", text: "思考", collapsed: true, durationMs: 1), .text(id: "x", markdown: "答案")])
        let cloud = SyncMapper.messages([m])
        XCTAssertEqual(cloud[0]["content"]?.stringValue, "<think>思考</think>\n\n答案")
        let back = SyncMapper.fromCloud(cloud, sessionId: "sess_1")
        XCTAssertEqual(back.first?.thinkingText, "思考")
        XCTAssertEqual(back.first?.text, "答案")
        XCTAssertEqual(MolaChatAPI.conversationId("sess_abc"), "chat_abc")
        XCTAssertEqual(MolaChatAPI.sessionId("chat_abc"), "sess_abc")
        XCTAssertEqual(SyncMapper.ms(SyncMapper.isoString(1_700_000_000_123)), 1_700_000_000_123)
    }

    func testAgentTranscript() {
        var t = AgentTranscript()
        t.apply([["seq": 1, "event": ["kind": "userPrompt", "text": "hi"]],
                 ["seq": 2, "event": ["kind": "answerSnapshot", "text": "he", "segmentId": "s1"]],
                 ["seq": 3, "event": ["kind": "answer_snapshot", "text": "hello", "segment_id": "s1"]],
                 ["seq": 4, "event": ["kind": "permissionPrompt", "permission": ["id": "p1", "toolName": "Bash"]]]])
        XCTAssertEqual(t.blocks.count, 3)
        if case .answer(_, let text) = t.blocks[1] { XCTAssertEqual(text, "hello") } else { XCTFail() }
        t.apply([["seq": 5, "event": ["kind": "turnDone", "usage": ["inputTokens": 3]]]])
        if case .permission(_, _, _, _, let resolved) = t.blocks[2] { XCTAssertTrue(resolved) } else { XCTFail() }
        XCTAssertEqual(t.latestSeq, 5)
    }

    func testModelConfigFiltering() {
        let cfg = #"{"models":{"auto":{"modelName":"auto","tipText":"自动"},"m1":{"modelName":"gpt-x","showImageUpload":true},"m2":{"modelName":"hidden","show_in_frontend":false},"m3":{"modelName":"donor"}}}"#
        let status = AccountStatus.parse(Data(#"{"user":{"logged_in":true},"model_status":{"m3":{"available":false,"reason":"donor_only"},"m1":{"available":false,"reason":"limit_exceeded"}}}"#.utf8))
        let models = MolaModel.parse(Data(cfg.utf8), status: status)
        XCTAssertEqual(models.map(\.id), ["auto", "gpt-x"])
        XCTAssertEqual(models[1].disabledReason, "今日额度已用完")
        XCTAssertTrue(models[0].isAuto)
    }
}
