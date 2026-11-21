import Foundation

// 联网搜索 / 网页抓取（对应安卓 ByokChatService.searchWeb / fetchUrl、WebSearchCitations、ByokToolConfig）。
// 只做请求构造与解析，发请求由 App 层负责。

/// 所有官方与工具请求统一的 UA（安卓 UserAgentProvider.FIXED_UA；后端校验 JWT 依赖它，不能带版本号）。
public enum MolaUA {
    public static let fixed = "MolaGPT-Android (Android)"
    public static let browser = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
}

public enum WebSearchProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case molagpt = "MOLAGPT", duckduckgo = "DUCKDUCKGO", tavily = "TAVILY", exa = "EXA"

    public var label: String {
        switch self {
        case .molagpt: return "MolaGPT（需登录）"
        case .duckduckgo: return "DuckDuckGo"
        case .tavily: return "Tavily"
        case .exa: return "Exa"
        }
    }
    public var needsKey: Bool { self == .tavily || self == .exa }
    public var maxLimit: Int { self == .molagpt ? 6 : 10 }
}

public struct SearchHit: Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String?
    public var publishedDate: String?
    public init(title: String, url: String, snippet: String? = nil, publishedDate: String? = nil) {
        self.title = title; self.url = url; self.snippet = snippet; self.publishedDate = publishedDate
    }
}

public enum WebSearchAPI {
    public static func resultCount(requested: Int?, setting: Int, provider: WebSearchProvider) -> Int {
        let cap = min(max(setting, 1), provider.maxLimit)
        return min(max(requested ?? setting, 1), cap)
    }

    public static func duckDuckGo(_ query: String) -> HTTPRequestSpec {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? query
        return HTTPRequestSpec(url: URL(string: "https://duckduckgo.com/html/?q=\(q)")!, method: "GET",
                               headers: ["Accept": "text/html", "User-Agent": MolaUA.fixed])
    }

    public static func parseDuckDuckGo(_ html: String, limit: Int) -> [SearchHit] {
        let pattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var out: [SearchHit] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard out.count < limit else { break }
            var href = HTMLText.decodeEntities(ns.substring(with: m.range(at: 1)))
            if let r = href.range(of: "uddg=") {
                var enc = String(href[r.upperBound...])
                if let amp = enc.firstIndex(of: "&") { enc = String(enc[..<amp]) }
                href = enc.removingPercentEncoding ?? enc
            } else if href.hasPrefix("//") {
                href = "https:" + href
            }
            let title = HTMLText.strip(HTMLText.decodeEntities(ns.substring(with: m.range(at: 2))))
            out.append(SearchHit(title: title.isEmpty ? href : title, url: href))
        }
        return out
    }

    public static func tavily(_ query: String, key: String, limit: Int) -> HTTPRequestSpec {
        let body: JSONValue = ["api_key": .string(key), "query": .string(query), "max_results": .number(Double(limit)), "search_depth": "basic"]
        return HTTPRequestSpec(url: URL(string: "https://api.tavily.com/search")!,
                               headers: ["Content-Type": "application/json", "Accept": "application/json", "User-Agent": MolaUA.fixed],
                               body: body.data())
    }

    public static func parseTavily(_ data: Data) -> (hits: [SearchHit], answer: String?) {
        guard let root = JSONValue.parse(data) else { return ([], nil) }
        let hits = (root["results"]?.arrayValue ?? []).compactMap { r -> SearchHit? in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            return SearchHit(title: r["title"]?.stringValue ?? url, url: url,
                             snippet: r["content"]?.stringValue.map { String($0.prefix(500)) },
                             publishedDate: r["published_date"]?.stringValue)
        }
        return (hits, root["answer"]?.stringValue?.nonBlank)
    }

    public static func exa(_ query: String, key: String, limit: Int) -> HTTPRequestSpec {
        let body: JSONValue = ["query": .string(query), "numResults": .number(Double(limit)), "contents": ["text": ["maxCharacters": 500]]]
        return HTTPRequestSpec(url: URL(string: "https://api.exa.ai/search")!,
                               headers: ["Content-Type": "application/json", "x-api-key": key, "User-Agent": MolaUA.fixed],
                               body: body.data())
    }

    public static func parseExa(_ data: Data) -> [SearchHit] {
        guard let root = JSONValue.parse(data) else { return [] }
        return (root["results"]?.arrayValue ?? []).compactMap { r in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            return SearchHit(title: r["title"]?.stringValue ?? url, url: url,
                             snippet: r["text"]?.stringValue.map { String($0.prefix(500)) },
                             publishedDate: r["publishedDate"]?.stringValue)
        }
    }

    /// MolaGPT 账户内置搜索（account_search.php）。
    public static func molagpt(baseURL: String, jwt: String, queries: [JSONValue], limit: Int) -> HTTPRequestSpec {
        let body: JSONValue = ["queries": .array(queries), "max_results": .number(Double(min(limit, 6))), "snippet_max_chars": 800]
        var spec = HTTPRequestSpec(url: URL(string: baseURL + "api/auth/account_search.php")!,
                                   headers: ["Content-Type": "application/json", "Accept": "application/json",
                                             "Authorization": "Bearer \(jwt)", "Idempotency-Key": UUID().uuidString,
                                             "User-Agent": MolaUA.fixed],
                                   body: body.data())
        spec.timeout = 30
        return spec
    }

    public static func parseMolaGPT(_ data: Data) -> (hits: [SearchHit], failedQueries: [String]) {
        guard let root = JSONValue.parse(data) else { return ([], []) }
        var hits: [SearchHit] = [], failed: [String] = []
        for q in root["queries"]?.arrayValue ?? [] {
            if let e = q["error"]?.stringValue, !e.isEmpty { failed.append(q["query"]?.stringValue ?? ""); continue }
            for r in q["results"]?.arrayValue ?? [] {
                guard let url = r["url"]?.stringValue, !url.isEmpty else { continue }
                hits.append(SearchHit(title: r["title"]?.stringValue ?? url, url: url, snippet: r["snippet"]?.stringValue,
                                      publishedDate: r["published_date"]?.stringValue))
            }
        }
        return (hits, failed)
    }
}

/// 整条回答共用的来源账本：编号跨调用、跨轮连续；同一 URL 复用旧编号。
public struct CitationLedger: Sendable {
    public private(set) var refs: [SourceReference] = []
    public private(set) var queries: [String] = []

    public init() {}

    public var queryLabel: String { queries.joined(separator: " / ") }

    /// 登记命中，返回给模型的文本；`added` 表示有新来源（需要刷新 UI）。
    public mutating func record(_ hits: [SearchHit], query: String, prefix: String? = nil) -> (text: String, added: Bool) {
        if !query.isEmpty, !queries.contains(query) { queries.append(query) }
        var blocks: [String] = []
        var added = false
        for h in hits where !h.url.isEmpty {
            let n: Int
            if let existing = refs.first(where: { $0.url == h.url }), let idx = existing.index {
                n = idx
            } else {
                n = refs.count + 1
                refs.append(SourceReference(title: h.title, url: h.url, snippet: h.snippet, index: n))
                added = true
            }
            var b = "### [来源 \(n)]\n**标题:** \(h.title)\n**网址:** \(h.url)"
            if let d = h.publishedDate?.nonBlank { b += "\n**发布日期:** \(d)" }
            if let s = h.snippet?.nonBlank { b += "\n**内容:** \(s.replacingOccurrences(of: "\n", with: " "))" }
            blocks.append(b)
        }
        guard !blocks.isEmpty else { return ((prefix.map { $0 + "\n\n" } ?? "") + "未获取到搜索结果。", false) }
        let rule = "引用规则：直接用到某条来源的信息时，在该句**句末**写 <ref source=\"N\" />，N 取下面的来源编号；多条来源支持同一句可写 <ref source=\"1,3\" />。常识性、总结性、过渡性的句子不要加。可用编号 1-\(refs.count)。"
        var text = rule + "\n\n"
        if let prefix { text += prefix + "\n\n" }
        text += blocks.joined(separator: "\n\n")
        return (text, added)
    }
}

public enum HTMLText {
    public static func decodeEntities(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// 去标签：删 script/style，标签换空格，空白折叠（安卓原样：先 decode 再去标签）。
    public static func strip(_ html: String) -> String {
        var t = decodeEntities(html)
        t = t.replacingOccurrences(of: #"(?is)<script.*?</script>|<style.*?</style>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func title(_ html: String) -> String? {
        guard let r = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        var t = String(html[r])
        t = t.replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
        t = decodeEntities(t).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(200))
    }

    /// fetch_url 的返回文本。
    public static func fetchResult(url: String, body: String, isHTML: Bool) -> String {
        let title = isHTML ? self.title(body) : nil
        let text = isHTML ? strip(body) : body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "标题：\(title ?? url)\n链接：\(url)\n\n\(String(text.prefix(12_000)))"
    }

    public static func fetchRequest(_ url: URL) -> HTTPRequestSpec {
        var s = HTTPRequestSpec(url: url, method: "GET", headers: ["Accept": "text/html,text/plain", "User-Agent": MolaUA.fixed])
        s.timeout = 30
        return s
    }
}
