import XCTest
@testable import MolaCore

final class MemoryContextTests: XCTestCase {
    func testQuoteAndDecay() {
        XCTAssertTrue(MemoryMath.quoteMatches("我是 iOS 开发者", in: "其实我是iOS开发者，平时写 Swift。"))
        XCTAssertFalse(MemoryMath.quoteMatches("我是安卓开发", in: "我是iOS开发者"))
        var e = MemoryEntry(text: "用户在做项目", section: .projects, confidence: 0.8, origin: .automatic, now: 0)
        e.lastReinforcedAt = 0
        XCTAssertEqual(MemoryMath.effectiveConfidence(e, now: 60 * 86_400_000), 0.4, accuracy: 1e-6)
        e.origin = .manual
        XCTAssertEqual(MemoryMath.effectiveConfidence(e, now: 600 * 86_400_000), 1)
    }

    func testProjectionBudget() {
        let entries = (0..<50).map { MemoryEntry(text: "用户喜欢第\($0)种很长很长很长很长的颜色组合与搭配", section: .preferences, confidence: 0.9, origin: .tool) }
        let p = MemoryProjector.project(entries: entries, profile: [.preferredName: "小明"], language: "zh", timezone: "Asia/Taipei", budget: 300)
        XCTAssertLessThanOrEqual(p.tokens, 300)
        XCTAssertGreaterThan(p.skipped, 0)
        XCTAssertTrue(p.block.contains("preferred_name: 小明"))
    }

    func testParseOps() {
        let xml = """
        <memory_ops>
        <op type="add" section="长期偏好与表达风格" confidence="0.9" topic="饮食"><text>用户不吃辣。</text><quote>我不吃辣</quote></op>
        <op type="forget" target="mem_1" /></memory_ops>
        """
        let ops = MemoryConsolidation.parseOps(xml)!
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0].section, .preferences)
        XCTAssertEqual(ops[0].quote, "我不吃辣")
        XCTAssertEqual(ops[1].target, "mem_1")
        XCTAssertEqual(MemoryConsolidation.parseGate("<user_memory>true</user_memory>"), true)
        XCTAssertNil(MemoryConsolidation.parseOps("随便"))
    }

    func testGuards() {
        XCTAssertTrue(MemoryGuards.looksSensitive("我的密码是 hunter2abc"))
        XCTAssertTrue(MemoryGuards.looksProtected("用户有抑郁病史"))
        XCTAssertTrue(MemoryGuards.looksLikeDenial("不对，我已经不在那家公司了"))
    }

    func testCompactionAnchorAndApply() {
        var history: [ChatMessage] = []
        for i in 0..<20 {
            history.append(ChatMessage(sessionId: "s", role: .user, fragments: [.text(id: "u\(i)", markdown: String(repeating: "问题", count: 2000))]))
            history.append(ChatMessage(sessionId: "s", role: .assistant, fragments: [.text(id: "a\(i)", markdown: String(repeating: "回答", count: 2000))]))
        }
        guard let anchor = ContextPlanner.anchorIndex(history, window: 64_000, reason: .threshold) else { return XCTFail() }
        XCTAssertEqual(history[anchor + 1].role, .user)
        let cp = ContextCheckpoint(sessionId: "s", anchorMessageId: history[anchor].messageId, summary: "摘要", coveredDigest: ContextPlanner.digest(history[...anchor]),
                                   tokensBefore: 0, tokensAfter: 0, reason: .threshold, providerId: nil, modelId: nil)
        guard let (found, idx) = ContextPlanner.activeCheckpoint([cp], history: history) else { return XCTFail() }
        XCTAssertEqual(found.id, cp.id); XCTAssertEqual(idx, anchor)
        let applied = ContextPlanner.apply(cp, anchor: anchor, history: history)
        XCTAssertTrue(applied[0].text.contains("<context-summary>"))
        XCTAssertEqual(ContextPlanner.anchorIndex(history, window: 64_000, reason: .overflow), history.count - 3)
        XCTAssertTrue(ContextOverflow.isOverflow("This model's maximum context length is 65536 tokens"))
        XCTAssertEqual(ContextOverflow.declaredWindow("maximum context length is 65,536 tokens"), 65536)
    }

    func testSkillFrontmatterAndPaging() throws {
        let md = "---\nname: pdf-tools\ndescription: |\n  处理 PDF\n  的技能\ncompatibility: \"需要 \\\"联网\\\"\"\n---\n# 正文"
        let f = try SkillFormat.frontmatter(md)
        XCTAssertEqual(f.name, "pdf-tools")
        XCTAssertEqual(f.description, "处理 PDF\n的技能")
        XCTAssertEqual(f.compatibility, "需要 \"联网\"")
        let page = SkillFormat.page(name: "x", path: "SKILL.md", text: String(repeating: "a", count: 20_000), offset: 0)
        XCTAssertTrue(page.hasPrefix("[x/SKILL.md; characters 0..16000/20000; next_offset=16000]"))
        XCTAssertFalse(SkillFormat.isSafeRelative("../etc/passwd"))
    }
}
