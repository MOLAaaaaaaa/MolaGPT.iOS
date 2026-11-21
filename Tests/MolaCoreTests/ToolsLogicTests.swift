import XCTest
@testable import MolaCore

final class ToolsLogicTests: XCTestCase {
    func testDuckDuckGoParse() {
        let html = #"<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example <b>A</b></a>"#
        let hits = WebSearchAPI.parseDuckDuckGo(html, limit: 5)
        XCTAssertEqual(hits.first?.url, "https://example.com/a")
        XCTAssertEqual(hits.first?.title, "Example A")
    }

    func testCitationLedgerReusesNumbers() {
        var l = CitationLedger()
        let a = l.record([SearchHit(title: "A", url: "https://a"), SearchHit(title: "B", url: "https://b")], query: "q1")
        XCTAssertTrue(a.added)
        XCTAssertTrue(a.text.contains("### [来源 2]"))
        let b = l.record([SearchHit(title: "B", url: "https://b"), SearchHit(title: "C", url: "https://c")], query: "q2")
        XCTAssertTrue(b.text.contains("### [来源 2]") && b.text.contains("### [来源 3]"))
        XCTAssertEqual(l.refs.count, 3)
        XCTAssertEqual(l.queryLabel, "q1 / q2")
    }

    func testHTMLStripAndTitle() {
        let html = "<html><head><title> Hi &amp; there </title><style>x{}</style></head><body><script>bad()</script><p>Hello</p>  <b>World</b></body></html>"
        XCTAssertEqual(HTMLText.title(html), "Hi & there")
        XCTAssertTrue(HTMLText.fetchResult(url: "u", body: html, isHTML: true).hasSuffix("Hi & there Hello World"))
    }

    func testMcpResultFormatting() {
        let json = #"{"jsonrpc":"2.0","id":"1","result":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}"#
        XCTAssertEqual(McpRPC.formatResult(Data(json.utf8)), "a\nb")
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"boom\"}]}}\n\n"
        XCTAssertEqual(McpRPC.formatResult(Data(sse.utf8)), "MCP failed: boom")
        let tools = McpRPC.parseTools(McpRPC.parseResponse(Data(#"{"result":{"tools":[{"name":"t","description":"d"}]}}"#.utf8)))
        XCTAssertEqual(tools.map(\.name), ["t"])
    }

    func testImageExtraction() {
        let openai = #"{"data":[{"b64_json":"AAAA"}]}"#
        XCTAssertEqual(ImageGenAPI.extractImages(Data(openai.utf8)).images, ["data:image/png;base64,AAAA"])
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"hi"},{"inlineData":{"mimeType":"image/jpeg","data":"BBBB"}}]}}]}"#
        XCTAssertEqual(ImageGenAPI.extractImages(Data(gemini.utf8)).images, ["data:image/jpeg;base64,BBBB"])
        let chat = #"{"choices":[{"message":{"content":"![x](https://x.test/a.png)"}}]}"#
        XCTAssertEqual(ImageGenAPI.extractImages(Data(chat.utf8)).images, ["https://x.test/a.png"])
        var c = ImageGenConfig(); c.aspectRatio = "16:9"
        XCTAssertEqual(c.pixelSize, "1024x576")
    }

    func testPostProcessingSkipsCode() {
        let out = ResponsePostProcessor.apply(ResponsePostProcessor.previewSample, rules: ResponseRegexRule.builtins)
        XCTAssertTrue(out.text.contains("你好，世界"))
        XCTAssertTrue(out.text.contains("“今天天气不错”"))
        XCTAssertTrue(out.text.contains("print(\"a,b\")"))
        XCTAssertTrue(out.text.contains("`x,y`"))
        XCTAssertTrue(out.text.contains("$f(x,y)$"))
    }

    func testToolSchemasRender() {
        var a = ToolAvailability(); a.webSearch = true; a.memory = true; a.mcp = true
        let specs = BuiltinTools.specs(a)
        XCTAssertEqual(specs.map(\.name), ["search_web", "mcp_list_tools", "mcp_call", "save_memory", "forget_memory"])
        let gemini = ToolSpec.render(specs, for: .gemini)
        XCTAssertEqual(gemini[0]?["functionDeclarations"]?[0]?["parameters"]?["properties"]?["query"]?["type"]?.stringValue, "STRING")
    }
}
