import Foundation

// 可视化回答协议（对应安卓 MolaUiParser / VisualSpecs / HtmlFence）。
// 围栏语言 `mola-ui`，内容为 `{component, id, props}`；每条限制与提示词一致。

public enum MolaUIComponent: String, Sendable {
    case functionPlot = "function-plot", chart, dataTable = "data-table", statGrid = "stat-grid", cardGrid = "card-grid"

    static func resolve(_ s: String?) -> MolaUIComponent? {
        switch (s ?? "").lowercased() {
        case "function-plot", "plot", "function", "functionplot": return .functionPlot
        case "chart": return .chart
        case "data-table", "table", "datatable": return .dataTable
        case "stat-grid", "stats", "metrics", "statgrid": return .statGrid
        case "card-grid", "cards", "cardgrid": return .cardGrid
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .functionPlot: return "函数图像"
        case .chart: return "图表"
        case .dataTable: return "表格"
        case .statGrid: return "指标"
        case .cardGrid: return "卡片"
        }
    }
}

public enum MolaUIResult: Sendable {
    /// 流式未配平：保持占位。
    case incomplete(MolaUIComponent?)
    case invalid(String)
    case ready(MolaUISpec)
}

public enum MolaUISpec: Sendable {
    case functionPlot(FunctionPlotSpec)
    case chart(ChartSpec)
    case dataTable(DataTableSpec)
    case statGrid(StatGridSpec)
    case cardGrid(CardGridSpec)
}

public struct FunctionPlotSpec: Sendable {
    public enum Curve: Sendable {
        case explicitY(MathExpression)       // y = f(x)
        case explicitX(MathExpression)       // x = f(y)
        case polar(MathExpression)           // r = f(theta)
        case implicit(MathExpression)        // F(x,y) = 0
        case parametric(x: MathExpression, y: MathExpression, t: ClosedRange<Double>)
    }
    public struct Function: Sendable { public var label: String; public var curve: Curve }
    public struct Param: Sendable { public var name: String; public var min: Double; public var max: Double; public var value: Double; public var step: Double? }
    public var title: String?
    public var functions: [Function]
    public var params: [Param]
    public var x: ClosedRange<Double>?
    public var y: ClosedRange<Double>?
}

public struct ChartSpec: Sendable {
    public enum Kind: String, Sendable { case line, bar, area, scatter, pie }
    public struct Series: Sendable { public var name: String; public var values: [Double?]; public var points: [(Double, Double)] }
    public var title: String?
    public var kind: Kind
    public var x: [String]
    public var series: [Series]
    public var unit: String?
    public var stacked: Bool
}

public struct DataTableSpec: Sendable {
    public struct Column: Sendable { public var key: String; public var label: String; public var type: String; public var alignEnd: Bool }
    public var title: String?
    public var columns: [Column]
    public var rows: [[String: JSONValue]]
    public var pageSize: Int
}

public struct StatGridSpec: Sendable {
    public struct Item: Sendable {
        public var label: String; public var value: String; public var unit: String?; public var delta: String?
        public var trend: String?; public var tone: String?; public var note: String?; public var history: [Double]
    }
    public var title: String?
    public var items: [Item]
}

public struct CardGridSpec: Sendable {
    public struct Item: Sendable { public var title: String; public var summary: String?; public var tag: String?; public var source: String?; public var url: String? }
    public var title: String?
    public var items: [Item]
}

public enum MolaUIParser {
    nonisolated(unsafe) private static var cache: [String: MolaUIResult] = [:]
    private static let lock = NSLock()

    public static func parse(_ source: String, closed: Bool) -> MolaUIResult {
        lock.lock(); if let hit = cache[source] { lock.unlock(); return hit }; lock.unlock()
        let r = parseUncached(source, closed: closed)
        if case .incomplete = r { return r }
        lock.lock()
        if cache.count > 48 { cache.removeAll() }
        cache[source] = r
        lock.unlock()
        return r
    }

    static func parseUncached(_ source: String, closed: Bool) -> MolaUIResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = JSONValue.parse(repair(trimmed)) else {
            if !closed {
                let hint = trimmed.range(of: #""component"\s*:\s*"([^"]+)""#, options: .regularExpression).map { String(trimmed[$0]) }
                let comp = hint.flatMap { h in h.split(separator: "\"").dropFirst(2).first.map(String.init) }
                return .incomplete(MolaUIComponent.resolve(comp))
            }
            return .invalid("JSON 格式不正确")
        }
        guard let comp = MolaUIComponent.resolve(root["component"]?.stringValue ?? root["type"]?.stringValue) else {
            return .invalid("未知组件：\(root["component"]?.stringValue ?? "缺少 component")")
        }
        let props = root["props"] ?? root
        do {
            switch comp {
            case .functionPlot: return .ready(.functionPlot(try functionPlot(props)))
            case .chart: return .ready(.chart(try chart(props)))
            case .dataTable: return .ready(.dataTable(try table(props)))
            case .statGrid: return .ready(.statGrid(try stats(props)))
            case .cardGrid: return .ready(.cardGrid(try cards(props)))
            }
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    struct SpecError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// 宽松 JSON：去注释、尾逗号；LaTeX 非法反斜杠按字面保留；中文里未转义的英文引号修复。
    static func repair(_ s: String) -> String {
        var out = ""
        let c = Array(s)
        var i = 0
        var inString = false
        while i < c.count {
            let ch = c[i]
            if inString {
                if ch == "\\" {
                    if i + 1 < c.count, "\"\\/bfnrtu".contains(c[i + 1]) {
                        // \u 需后跟 4 位十六进制，否则当字面反斜杠
                        if c[i + 1] == "u", !(i + 5 < c.count && c[(i + 2)...(i + 5)].allSatisfy(\.isHexDigit)) { out += "\\\\"; i += 1; continue }
                        // \b \f \n \r \t 后紧跟字母时多半是 LaTeX（\frac、\theta、\nabla…）
                        if "bfnrt".contains(c[i + 1]), i + 2 < c.count, c[i + 2].isLetter { out += "\\\\"; i += 1; continue }
                        out.append(ch); out.append(c[i + 1]); i += 2; continue
                    }
                    out += "\\\\"; i += 1; continue
                }
                if ch == "\"" {
                    // 只有后面（跳过空白）紧跟 , } ] : 或结尾才算字符串结束
                    var j = i + 1
                    while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
                    if j >= c.count || ",}]:\n\r".contains(c[j]) { inString = false; out.append(ch) }
                    else { out += "\\\"" }
                    i += 1; continue
                }
                if ch == "\n" { out += "\\n"; i += 1; continue }
                out.append(ch); i += 1; continue
            }
            if ch == "\"" { inString = true; out.append(ch); i += 1; continue }
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2; continue
            }
            if ch == "," {
                var j = i + 1
                while j < c.count, c[j].isWhitespace { j += 1 }
                if j < c.count, c[j] == "}" || c[j] == "]" { i += 1; continue }
            }
            out.append(ch); i += 1
        }
        return out
    }

    static func range(_ v: JSONValue?) -> ClosedRange<Double>? {
        guard let a = v?.arrayValue, a.count == 2, let lo = number(a[0]), let hi = number(a[1]), lo < hi else { return nil }
        return lo...hi
    }

    static func number(_ v: JSONValue?) -> Double? {
        if let d = v?.doubleValue { return d }
        if let s = v?.stringValue, let e = try? MathExpression(s) { let r = e.evaluate([:]); return r.isFinite ? r : nil }
        return nil
    }

    static func text(_ v: JSONValue?) -> String? {
        if let s = v?.stringValue { return s }
        if let d = v?.doubleValue { return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }
        if let b = v?.boolValue { return b ? "是" : "否" }
        return nil
    }

    static let reservedParams: Set<String> = ["x", "y", "t", "theta", "e", "pi"]

    static func functionPlot(_ p: JSONValue) throws -> FunctionPlotSpec {
        var fns: [FunctionPlotSpec.Function] = []
        for (i, f) in (p["functions"]?.arrayValue ?? []).prefix(6).enumerated() {
            let label = f["label"]?.stringValue
            if let xs = f["x"]?.stringValue, let ys = f["y"]?.stringValue {
                let t = range(f["t"]) ?? 0...(2 * .pi)
                fns.append(.init(label: label ?? "曲线 \(i + 1)", curve: .parametric(x: try MathExpression(xs), y: try MathExpression(ys), t: t)))
                continue
            }
            guard var expr = (f["expr"] ?? f["fn"] ?? f["expression"])?.stringValue?.trimmingCharacters(in: .whitespaces) else { continue }
            let lower = expr.lowercased().replacingOccurrences(of: " ", with: "")
            let curve: FunctionPlotSpec.Curve
            if lower.hasPrefix("y=") {
                expr = String(expr[expr.index(after: expr.firstIndex(of: "=")!)...])
                curve = .explicitY(try MathExpression(expr))
            } else if lower.hasPrefix("x=") {
                expr = String(expr[expr.index(after: expr.firstIndex(of: "=")!)...])
                curve = .explicitX(try MathExpression(expr))
            } else if lower.hasPrefix("r=") {
                expr = String(expr[expr.index(after: expr.firstIndex(of: "=")!)...])
                curve = .polar(try MathExpression(expr))
            } else if let eq = expr.firstIndex(of: "=") {
                let lhs = String(expr[..<eq]), rhs = String(expr[expr.index(after: eq)...])
                curve = .implicit(try MathExpression("(\(lhs))-(\(rhs))"))
            } else {
                curve = .explicitY(try MathExpression(expr))
            }
            fns.append(.init(label: label ?? expr, curve: curve))
        }
        guard !fns.isEmpty else { throw SpecError(message: "functions 为空") }
        let params = (p["params"]?.arrayValue ?? []).prefix(4).compactMap { q -> FunctionPlotSpec.Param? in
            guard let n = q["name"]?.stringValue, !reservedParams.contains(n), let lo = number(q["min"]), let hi = number(q["max"]), lo < hi else { return nil }
            let v = number(q["default"]) ?? (lo + hi) / 2
            return .init(name: n, min: lo, max: hi, value: min(max(v, lo), hi), step: number(q["step"]))
        }
        return FunctionPlotSpec(title: p["title"]?.stringValue, functions: fns, params: params, x: range(p["x"]), y: range(p["y"]))
    }

    static func chart(_ p: JSONValue) throws -> ChartSpec {
        let kind = ChartSpec.Kind(rawValue: (p["type"]?.stringValue ?? "line").lowercased()) ?? .line
        let x = (p["x"]?.arrayValue ?? p["labels"]?.arrayValue ?? []).compactMap { text($0) }
        var series: [ChartSpec.Series] = []
        for (i, s) in (p["series"]?.arrayValue ?? []).prefix(kind == .pie ? 1 : 8).enumerated() {
            let data = Array((s["data"]?.arrayValue ?? []).prefix(400))
            var values: [Double?] = [], points: [(Double, Double)] = []
            for d in data {
                if let a = d.arrayValue, a.count >= 2, let px = number(a[0]), let py = number(a[1]) { points.append((px, py)) }
                else if let o = d.objectValue, let px = number(o["x"]), let py = number(o["y"]) { points.append((px, py)) }
                else { values.append(number(d)) }
            }
            series.append(.init(name: s["name"]?.stringValue ?? "系列 \(i + 1)", values: values, points: points))
        }
        guard !series.isEmpty else { throw SpecError(message: "series 为空") }
        return ChartSpec(title: p["title"]?.stringValue, kind: kind, x: x, series: series, unit: p["unit"]?.stringValue,
                         stacked: p["stacked"]?.boolValue ?? false)
    }

    static func table(_ p: JSONValue) throws -> DataTableSpec {
        var cols = (p["columns"]?.arrayValue ?? []).prefix(16).compactMap { c -> DataTableSpec.Column? in
            if let s = c.stringValue { return .init(key: s, label: s, type: "text", alignEnd: false) }
            guard let k = c["key"]?.stringValue else { return nil }
            let type = c["type"]?.stringValue ?? "text"
            let align = c["align"]?.stringValue
            return .init(key: k, label: c["label"]?.stringValue ?? k, type: type, alignEnd: align == "end" || (align == nil && type == "number"))
        }
        let rows = (p["rows"]?.arrayValue ?? []).prefix(1000).compactMap { r -> [String: JSONValue]? in
            if let o = r.objectValue { return o }
            if let a = r.arrayValue { return Dictionary(uniqueKeysWithValues: zip(cols.map(\.key), a)) }
            return nil
        }
        if cols.isEmpty, let first = rows.first { cols = first.keys.sorted().map { .init(key: $0, label: $0, type: "text", alignEnd: false) } }
        guard !cols.isEmpty else { throw SpecError(message: "columns 为空") }
        let page = min(max(p["pageSize"]?.intValue ?? 10, 5), 50)
        return DataTableSpec(title: p["title"]?.stringValue, columns: Array(cols), rows: Array(rows), pageSize: page)
    }

    static func stats(_ p: JSONValue) throws -> StatGridSpec {
        let items = (p["items"]?.arrayValue ?? []).prefix(12).compactMap { i -> StatGridSpec.Item? in
            guard let l = i["label"]?.stringValue, let v = text(i["value"]) else { return nil }
            return .init(label: l, value: v, unit: i["unit"]?.stringValue, delta: text(i["delta"]), trend: i["trend"]?.stringValue,
                         tone: i["tone"]?.stringValue, note: i["note"]?.stringValue,
                         history: Array((i["history"]?.arrayValue ?? []).prefix(120).compactMap { number($0) }))
        }
        guard !items.isEmpty else { throw SpecError(message: "items 为空") }
        return StatGridSpec(title: p["title"]?.stringValue, items: items)
    }

    static func cards(_ p: JSONValue) throws -> CardGridSpec {
        let items = (p["items"]?.arrayValue ?? []).prefix(24).compactMap { i -> CardGridSpec.Item? in
            guard let t = i["title"]?.stringValue else { return nil }
            var url = i["url"]?.stringValue
            if let u = url, !(u.hasPrefix("http://") || u.hasPrefix("https://")) { url = nil }
            return .init(title: t, summary: i["summary"]?.stringValue, tag: i["tag"]?.stringValue, source: i["source"]?.stringValue, url: url)
        }
        guard !items.isEmpty else { throw SpecError(message: "items 为空") }
        return CardGridSpec(title: p["title"]?.stringValue, items: items)
    }
}

/// HTML 围栏判定（对应安卓 HtmlFence）。
public enum HtmlFence {
    public static func isHTML(language: String?, code: String) -> Bool {
        let l = (language ?? "").lowercased()
        if ["html", "htm", "xhtml"].contains(l) { return true }
        guard l.isEmpty else { return false }
        let head = code.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    /// 是否「一页」：首行文件名注释、完整文档、≥1500 字节或 ≥30 行。
    public static func isPage(_ code: String, closed: Bool) -> Bool {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).count
        if fileName(code) != nil { return true }
        let lower = code.lowercased()
        if lower.contains("<!doctype html") || lower.contains("<html") { return true }
        if lines >= 30 { return true }
        return closed && code.utf8.count >= 1500
    }

    /// 首行 `<!-- foo.html -->`。
    public static func fileName(_ code: String) -> String? {
        let first = code.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard first.hasPrefix("<!--"), first.hasSuffix("-->") else { return nil }
        let name = first.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard name.count <= 64, let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 9, !name.contains(" ") else { return nil }
        return name
    }

    public static func title(_ code: String) -> String {
        if let f = fileName(code) { return f }
        if let t = HTMLText.title(code) { return t }
        return "网页"
    }
}
