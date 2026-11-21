import XCTest
@testable import MolaCore

final class DesktopRemoteTests: XCTestCase {
    func testFrameSigning() {
        let secret = Array(repeating: UInt8(7), count: 32)
        let f = DesktopProtocol.frame(to: "m1", id: "id1", op: "open", args: ["conversationId": "c"], pairId: "p1", secret: secret, ts: 1000)
        let j = JSONValue.parse(f)!
        XCTAssertEqual(j["to"]?.stringValue, "m1")
        let a = j["body"]?["a"]?.stringValue ?? ""
        XCTAssertEqual(j["body"]?["sig"]?.stringValue, DesktopProtocol.sign(secret: secret, id: "id1", op: "open", ts: 1000, pairId: "p1", args: a))
        XCTAssertFalse(j["body"]?["sig"]?.stringValue?.contains("=") ?? true)
        let unsigned = JSONValue.parse(DesktopProtocol.frame(to: "m1", id: "x", op: "pair_account", args: [:], pairId: nil, secret: nil))!
        XCTAssertEqual(unsigned["body"]?["sig"]?.stringValue, "")
        XCTAssertTrue(DesktopProtocol.newConversationId().hasPrefix("chat_"))
    }

    func testMessageMappingUTF16() {
        // "😀ab" 的 UTF-16 长度是 4，工具卡插在 offset 2（emoji 之后）
        let j: JSONValue = ["id": "m", "role": "assistant", "createdAtMs": 1, "content": "😀ab",
                            "meta": ["thinking": "想", "tool_calls": [["id": "t1", "name": "web_search", "status": "completed", "content_offset": 2]]]]
        let m = DesktopMessageMapper.map(j, conversationId: "c")!
        let kinds = m.fragments.map { f -> String in
            switch f { case .thinking: return "think"; case .text(_, let t): return "text:\(t)"; case .tool: return "tool"; default: return "?" }
        }
        XCTAssertEqual(kinds, ["think", "text:😀", "tool", "text:ab"])
    }
}
