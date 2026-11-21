import XCTest
@testable import MolaCore

final class ShareInboxTests: XCTestCase {
    func testGroupCandidates() {
        XCTAssertEqual(ShareInbox.groupCandidates(bundleID: "com.molagpt.app", isExtension: false), ["group.com.molagpt.app"])
        XCTAssertEqual(ShareInbox.groupCandidates(bundleID: "XTL-AB12.com.molagpt.app.MolaShare", isExtension: true),
                       ["group.XTL-AB12.com.molagpt.app", "group.com.molagpt.app"])
        XCTAssertEqual(ShareInbox.groupCandidates(bundleID: nil, isExtension: false), ["group.com.molagpt.app"])
    }

    func testComposeDraft() {
        let a = SharedItem(prompt: "总结一下", texts: ["页面标题"], urls: ["https://a.com/x"])
        let b = SharedItem(texts: ["页面标题", "看看 https://b.com"], urls: ["https://b.com"])
        XCTAssertEqual(ShareInbox.composeDraft([a, b]), "总结一下\n\n页面标题\n\nhttps://a.com/x\n\n看看 https://b.com")
        XCTAssertTrue(SharedItem(prompt: "  ").isEmpty)
    }

    func testWriteAndPending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let first = SharedItem(createdAt: 2, texts: ["b"])
        try ShareInbox.write(first, copying: [(SharedFile(name: "a/b.txt", isImage: false), src),
                                              (SharedFile(name: "a/b.txt", isImage: false), src)], to: root)
        try ShareInbox.write(SharedItem(createdAt: 1, texts: ["a"]), copying: [], to: root)
        // 没有 item.json 的半成品目录应被忽略
        try FileManager.default.createDirectory(at: root.appendingPathComponent("partial"), withIntermediateDirectories: true)

        let pending = ShareInbox.pending(in: root)
        XCTAssertEqual(pending.map(\.item.texts), [["a"], ["b"]])
        XCTAssertEqual(pending[1].item.files.map(\.name), ["a_b.txt", "1_a_b.txt"])
        XCTAssertEqual(try String(contentsOf: pending[1].dir.appendingPathComponent("a_b.txt"), encoding: .utf8), "hi")
        ShareInbox.remove(pending[0].dir)
        XCTAssertEqual(ShareInbox.pending(in: root).count, 1)
    }
}

final class LiveSummaryTests: XCTestCase {
    func testPhases() {
        XCTAssertEqual(LiveSummary.summarize([]).phase, .thinking)
        let thinking: [MessageFragment] = [.thinking(id: "t", text: "先想想", collapsed: false, durationMs: nil)]
        XCTAssertEqual(LiveSummary.summarize(thinking).phase, .thinking)
        XCTAssertEqual(LiveSummary.summarize(thinking).snippet, "先想想")

        let tool: [MessageFragment] = [.text(id: "a", markdown: "好的"),
                                       .tool(ToolCallFragment(id: "x", name: "web_fetch", status: .running))]
        let r = LiveSummary.summarize(tool, toolLabel: { $0 == "web_fetch" ? "读取网页" : $0 })
        XCTAssertEqual(r.phase, .tool)
        XCTAssertEqual(r.snippet, "读取网页")

        let text: [MessageFragment] = [.text(id: "a", markdown: "# 标题\n- **要点** 见 [文档](https://x.com)\n`code`")]
        let w = LiveSummary.summarize(text)
        XCTAssertEqual(w.phase, .writing)
        XCTAssertEqual(w.snippet, "标题 要点 见 文档 code")
        XCTAssertEqual(LiveSummary.summarize([.text(id: "a", markdown: String(repeating: "字", count: 100))], maxChars: 10).snippet,
                       "…" + String(repeating: "字", count: 10))
    }
}
