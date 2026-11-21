import XCTest
@testable import MolaCore

final class VisualTests: XCTestCase {
    func testExpressions() throws {
        XCTAssertEqual(try MathExpression("2x^2-1").evaluate(["x": 3]), 17)
        XCTAssertEqual(try MathExpression("sin(pi/2)+3!").evaluate([:]), 7, accuracy: 1e-9)
        XCTAssertEqual(try MathExpression("sum(k=1,n,k)").evaluate(["n": 10]), 55)
        XCTAssertEqual(try MathExpression("(-8)^(1/3)").evaluate([:]), -2, accuracy: 1e-9)
        XCTAssertEqual(try MathExpression("\\frac{1}{2}x").evaluate(["x": 4]), 2)
        XCTAssertEqual(try MathExpression("a sin(x)").variables, ["a", "x"])
        XCTAssertThrowsError(try MathExpression("foo(1)"))
    }

    func testLenientJSONAndPlot() {
        let src = #"""
        {"component":"plot", // 注释
         "props":{"title":"抛物线","functions":[{"expr":"y=a x^2","label":"\alpha 曲线"},{"expr":"x^2+y^2=4"},],
         "params":[{"name":"a","min":-2,"max":2,"default":1}]}}
        """#
        guard case .ready(.functionPlot(let p)) = MolaUIParser.parse(src, closed: true) else { return XCTFail("not ready") }
        XCTAssertEqual(p.functions.count, 2)
        XCTAssertEqual(p.functions[0].label, "\\alpha 曲线")
        if case .implicit = p.functions[1].curve {} else { XCTFail("implicit expected") }
        XCTAssertEqual(p.params.first?.value, 1)
    }

    func testChineseQuotesRepaired() {
        let src = #"{"component":"cards","props":{"items":[{"title":"他说"你好"了","summary":"x"}]}}"#
        guard case .ready(.cardGrid(let c)) = MolaUIParser.parse(src, closed: true) else { return XCTFail("not ready") }
        XCTAssertEqual(c.items.first?.title, "他说\"你好\"了")
    }

    func testIncompleteWhileStreaming() {
        if case .incomplete(let comp) = MolaUIParser.parse(#"{"component":"chart","props":{"series":[{"#, closed: false) {
            XCTAssertEqual(comp, .chart)
        } else { XCTFail() }
    }

    func testHtmlFence() {
        XCTAssertTrue(HtmlFence.isHTML(language: nil, code: "<!DOCTYPE html><html></html>"))
        XCTAssertEqual(HtmlFence.fileName("<!-- game.html -->\n<div>"), "game.html")
        XCTAssertFalse(HtmlFence.isPage("<b>hi</b>", closed: true))
    }
}
