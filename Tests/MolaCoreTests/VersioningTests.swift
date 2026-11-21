import XCTest
@testable import MolaCore

final class VersioningTests: XCTestCase {
    func msg(_ role: Role, _ t: String, _ at: Int64) -> ChatMessage {
        ChatMessage(sessionId: "s", role: role, createdAt: at, fragments: [.text(id: IDs.fragment(), markdown: t)])
    }

    func testRegenerateAndSelect() {
        var a = msg(.assistant, "v1", 2)
        a = Versioning.beginRegenerate(a, model: "m2")
        XCTAssertEqual(a.versionCount, 2); XCTAssertEqual(a.retryCurrent, 1); XCTAssertTrue(a.fragments.isEmpty)
        a.fragments = [.text(id: "x", markdown: "v2")]; a.status = .complete
        a = Versioning.commitCurrent(a)
        let back = Versioning.selectVersion(a, 0)
        XCTAssertEqual(back.text, "v1")
        XCTAssertEqual(Versioning.selectVersion(back, 1).text, "v2")
    }

    func testEditBranchesRoundTrip() {
        let base = [msg(.user, "q1", 1), msg(.assistant, "a1", 2), msg(.user, "q2", 3), msg(.assistant, "a2", 4)]
        var edited = Versioning.applyEdit(base, at: 2, newText: "q2'")
        XCTAssertEqual(edited.count, 3)
        XCTAssertEqual(edited[2].branchCount, 2)
        edited.append(msg(.assistant, "a2'", 5))
        edited = Versioning.syncBranchSlot(edited)
        let orig = Versioning.selectBranch(edited, at: 2, to: 0)
        XCTAssertEqual(orig.map(\.text), ["q1", "a1", "q2", "a2"])
        XCTAssertEqual(orig[2].editBranches?.value.position, 1)
        let again = Versioning.selectBranch(orig, at: 2, to: 1)
        XCTAssertEqual(again.map(\.text), ["q1", "a1", "q2'", "a2'"])
        // 再编辑一次：分支数变 3
        XCTAssertEqual(Versioning.applyEdit(again, at: 2, newText: "q2''")[2].branchCount, 3)
    }
}
