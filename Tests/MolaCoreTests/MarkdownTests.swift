import XCTest
@testable import MolaCore

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let md = """
        # 标题

        段落一
        第二行

        ```swift
        let x = 1
        ```

        | A | B |
        |:--|--:|
        | 1 | 2 |

        - a
        - [x] b
          - c
        1. one
        2. two

        > 引用

        $$
        E=mc^2
        $$

        ---
        ```py
        unclosed
        """
        let b = MarkdownParser.parse(md)
        guard b.count == 10 else { return XCTFail("\(b.count): \(b)") }
        XCTAssertEqual(b[0], .heading(level: 1, text: "标题"))
        XCTAssertEqual(b[1], .paragraph("段落一\n第二行"))
        XCTAssertEqual(b[2], .code(language: "swift", code: "let x = 1", closed: true))
        XCTAssertEqual(b[3], .table(header: ["A", "B"], alignments: [.leading, .trailing], rows: [["1", "2"]]))
        guard case .list(false, _, let items) = b[4] else { return XCTFail("\(b[4])") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].checked, true)
        XCTAssertEqual(items[1].blocks.count, 2) // 段落 + 子列表
        guard case .list(true, 1, let o) = b[5] else { return XCTFail("\(b[5])") }
        XCTAssertEqual(o.count, 2)
        XCTAssertEqual(b[6], .quote([.paragraph("引用")]))
        XCTAssertEqual(b[7], .math("E=mc^2"))
        XCTAssertEqual(b[8], .rule)
        XCTAssertEqual(b[9], .code(language: "py", code: "unclosed", closed: false))
    }
}

final class InlineMathTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(InlineMath.split("能量 $E=mc^2$ 守恒"), [.text("能量 "), .math("E=mc^2"), .text(" 守恒")])
        XCTAssertEqual(InlineMath.split("价格 $5 和 $10"), [.text("价格 $5 和 $10")])
        XCTAssertEqual(InlineMath.split("用 \\(a+b\\) 表示"), [.text("用 "), .math("a+b"), .text(" 表示")])
        XCTAssertEqual(InlineMath.split("代码 `$x$` 不动"), [.text("代码 `$x$` 不动")])
        XCTAssertEqual(InlineMath.split("转义 \\$x\\$"), [.text("转义 \\$x\\$")])
        XCTAssertEqual(InlineMath.split("$$x^2$$"), [.math("x^2")])
    }

    func testHighlight() {
        let code = "let x = \"hi\" // note\nfunc f() { return 42 }"
        let kinds = CodeHighlighter.tokenize(code, language: "swift").map(\.kind)
        XCTAssertEqual(kinds, [.keyword, .string, .comment, .keyword, .function, .keyword, .number])
        XCTAssertTrue(CodeHighlighter.tokenize("SELECT * FROM t", language: "sql").allSatisfy { $0.kind == .keyword })
        XCTAssertTrue(CodeHighlighter.tokenize("hello", language: "text").isEmpty)
    }
}
