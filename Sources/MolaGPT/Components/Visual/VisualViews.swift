import SwiftUI
import Charts
import UIKit
import MolaCore

/// `mola-ui` 代码块：按解析结果渲染组件；流式中保持占位，无效时可展开源码与原因。
struct VisualBlockView: View {
    let source: String
    let closed: Bool

    var body: some View {
        switch MolaUIParser.parse(source, closed: closed) {
        case .incomplete(let comp):
            VisualCard(title: nil) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成\(comp?.label ?? "可视化内容")…").font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        case .invalid(let reason):
            DisclosureGroup {
                Text(source).font(.caption.monospaced()).textSelection(.enabled)
            } label: {
                Label("可视化内容无法显示：\(reason)", systemImage: "exclamationmark.triangle").font(.footnote)
            }
            .padding(12)
            .background(MolaColor.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .ready(let spec):
            switch spec {
            case .functionPlot(let s): FunctionPlotView(spec: s)
            case .chart(let s): ChartCardView(spec: s)
            case .dataTable(let s): DataTableView(spec: s)
            case .statGrid(let s): StatGridView(spec: s)
            case .cardGrid(let s): CardGridView(spec: s)
            }
        }
    }
}

struct VisualCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MolaColor.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

enum VisualPalette {
    static let colors: [Color] = [MolaColor.accent, .blue, .orange, .green, .purple, .teal, .pink, .indigo]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

// MARK: - 图表

struct ChartCardView: View {
    let spec: ChartSpec
    @State private var selectedX: String?
    @State private var hidden: Set<String> = []

    private struct Point: Identifiable { let id: String; let series: String; let x: String; let xv: Double; let y: Double }

    private var points: [Point] {
        spec.series.filter { !hidden.contains($0.name) }.flatMap { s -> [Point] in
            if !s.points.isEmpty {
                return s.points.enumerated().map { Point(id: "\(s.name)#\($0)", series: s.name, x: "", xv: $1.0, y: $1.1) }
            }
            return s.values.enumerated().compactMap { i, v in
                guard let v else { return nil }
                let label = spec.x.indices.contains(i) ? spec.x[i] : "\(i + 1)"
                return Point(id: "\(s.name)#\(i)", series: s.name, x: label, xv: Double(i), y: v)
            }
        }
    }

    var body: some View {
        VisualCard(title: spec.title) {
            if spec.kind == .pie { pie } else { cartesian }
            if spec.series.count > 1 && spec.kind != .pie { legend }
        }
    }

    @ViewBuilder private var cartesian: some View {
        let pts = points
        Chart {
            ForEach(pts) { p in
                switch spec.kind {
                case .bar:
                    BarMark(x: .value("X", p.x), y: .value(spec.unit ?? "值", p.y))
                        .foregroundStyle(by: .value("系列", p.series))
                        .position(by: .value("系列", spec.stacked ? "all" : p.series))
                case .area:
                    AreaMark(x: .value("X", p.x), y: .value(spec.unit ?? "值", p.y), stacking: spec.stacked ? .standard : .unstacked)
                        .foregroundStyle(by: .value("系列", p.series)).opacity(0.6)
                case .scatter:
                    PointMark(x: .value("X", p.xv), y: .value(spec.unit ?? "值", p.y))
                        .foregroundStyle(by: .value("系列", p.series))
                default:
                    LineMark(x: .value("X", p.x), y: .value(spec.unit ?? "值", p.y))
                        .foregroundStyle(by: .value("系列", p.series))
                        .interpolationMethod(.monotone)
                        .symbol(by: .value("系列", p.series))
                }
            }
            if let selectedX, spec.kind != .scatter {
                RuleMark(x: .value("X", selectedX))
                    .foregroundStyle(MolaColor.secondaryLabel.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        let rows = pts.filter { $0.x == selectedX }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedX).font(.caption2.weight(.semibold))
                            ForEach(rows) { r in Text("\(r.series)：\(fmt(r.y))\(spec.unit ?? "")").font(.caption2) }
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: spec.series.indices.map { VisualPalette.color($0) })
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedX)
        .frame(height: 220)
    }

    @ViewBuilder private var pie: some View {
        let s = spec.series[0]
        let slices = s.values.enumerated().compactMap { i, v -> (String, Double)? in
            guard let v, v > 0 else { return nil }
            return (spec.x.indices.contains(i) ? spec.x[i] : "\(i + 1)", v)
        }
        let total = slices.reduce(0) { $0 + $1.1 }
        Chart(slices, id: \.0) { item in
            SectorMark(angle: .value("值", item.1), innerRadius: .ratio(0.55), angularInset: 1.5)
                .foregroundStyle(by: .value("类别", item.0))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale(domain: slices.map(\.0), range: slices.indices.map { VisualPalette.color($0) })
        .frame(height: 220)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slices.enumerated()), id: \.offset) { i, item in
                HStack {
                    Circle().fill(VisualPalette.color(i)).frame(width: 8, height: 8)
                    Text(item.0).font(.caption)
                    Spacer()
                    Text("\(fmt(item.1))\(spec.unit ?? "") · \(Int((item.1 / max(total, 1e-9) * 100).rounded()))%").font(.caption.monospacedDigit())
                        .foregroundStyle(MolaColor.secondaryLabel)
                }
            }
        }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(spec.series.enumerated()), id: \.offset) { i, s in
                    Button {
                        if hidden.contains(s.name) { hidden.remove(s.name) } else if hidden.count < spec.series.count - 1 { hidden.insert(s.name) }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(VisualPalette.color(i)).frame(width: 8, height: 8)
                            Text(s.name).font(.caption)
                        }
                        .opacity(hidden.contains(s.name) ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String { v.formatted(.number.precision(.significantDigits(1...6))) }
}

// MARK: - 函数图像

struct FunctionPlotView: View {
    let spec: FunctionPlotSpec
    @State private var params: [String: Double] = [:]
    @State private var xRange: ClosedRange<Double> = -10...10
    @State private var yRange: ClosedRange<Double> = -6...6
    @State private var baseX: ClosedRange<Double>?
    @State private var baseY: ClosedRange<Double>?
    @State private var initialized = false

    var body: some View {
        VisualCard(title: spec.title) {
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size) }
                    .gesture(drag(size: geo.size))
                    .simultaneousGesture(zoom)
                    .onTapGesture(count: 2) { withAnimation { reset() } }
            }
            .frame(height: 260)
            .background(MolaColor.background, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            legend
            ForEach(spec.params, id: \.name) { p in
                HStack {
                    Text(p.name).font(.callout.italic().monospaced())
                    Slider(value: Binding(get: { params[p.name] ?? p.value }, set: { params[p.name] = $0 }), in: p.min...p.max,
                           step: p.step ?? ((p.max - p.min) / 200))
                    Text((params[p.name] ?? p.value).formatted(.number.precision(.fractionLength(2)))).font(.caption.monospacedDigit()).frame(width: 48)
                }
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            for p in spec.params { params[p.name] = p.value }
            reset()
        }
    }

    private func reset() {
        xRange = spec.x ?? -10...10
        yRange = spec.y ?? autoY(xRange)
    }

    private func autoY(_ xr: ClosedRange<Double>) -> ClosedRange<Double> {
        var ys: [Double] = []
        for f in spec.functions {
            guard case .explicitY(let e) = f.curve else { continue }
            for i in 0...120 {
                let x = xr.lowerBound + (xr.upperBound - xr.lowerBound) * Double(i) / 120
                let y = e.evaluate(vars(["x": x]))
                if y.isFinite { ys.append(y) }
            }
        }
        guard ys.count > 4 else { return -6...6 }
        ys.sort()
        let lo = ys[Int(Double(ys.count) * 0.05)], hi = ys[Int(Double(ys.count - 1) * 0.95)]
        let pad = max((hi - lo) * 0.15, 1)
        return (lo - pad)...(hi + pad)
    }

    private func vars(_ extra: [String: Double]) -> [String: Double] { params.merging(extra) { $1 } }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if baseX == nil { baseX = xRange; baseY = yRange }
                guard let bx = baseX, let by = baseY else { return }
                let k = 1 / max(v.magnification, 0.05)
                xRange = scaled(bx, k); yRange = scaled(by, k)
            }
            .onEnded { _ in baseX = nil; baseY = nil }
    }

    private func scaled(_ r: ClosedRange<Double>, _ k: Double) -> ClosedRange<Double> {
        let mid = (r.lowerBound + r.upperBound) / 2, half = (r.upperBound - r.lowerBound) / 2 * k
        return (mid - half)...(mid + half)
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if baseX == nil { baseX = xRange; baseY = yRange }
                guard let bx = baseX, let by = baseY else { return }
                let dx = -Double(v.translation.width / size.width) * (bx.upperBound - bx.lowerBound)
                let dy = Double(v.translation.height / size.height) * (by.upperBound - by.lowerBound)
                xRange = (bx.lowerBound + dx)...(bx.upperBound + dx)
                yRange = (by.lowerBound + dy)...(by.upperBound + dy)
            }
            .onEnded { _ in baseX = nil; baseY = nil }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let xr = xRange, yr = yRange
        func sx(_ x: Double) -> CGFloat { CGFloat((x - xr.lowerBound) / (xr.upperBound - xr.lowerBound)) * size.width }
        func sy(_ y: Double) -> CGFloat { size.height - CGFloat((y - yr.lowerBound) / (yr.upperBound - yr.lowerBound)) * size.height }
        // 网格与坐标轴
        let step = niceStep(xr.upperBound - xr.lowerBound)
        var grid = Path()
        var gx = (xr.lowerBound / step).rounded(.up) * step
        while gx <= xr.upperBound { grid.move(to: CGPoint(x: sx(gx), y: 0)); grid.addLine(to: CGPoint(x: sx(gx), y: size.height)); gx += step }
        let ystep = niceStep(yr.upperBound - yr.lowerBound)
        var gy = (yr.lowerBound / ystep).rounded(.up) * ystep
        while gy <= yr.upperBound { grid.move(to: CGPoint(x: 0, y: sy(gy))); grid.addLine(to: CGPoint(x: size.width, y: sy(gy))); gy += ystep }
        ctx.stroke(grid, with: .color(Color(uiColor: .separator).opacity(0.4)), lineWidth: 0.5)
        var axes = Path()
        if xr.contains(0) { axes.move(to: CGPoint(x: sx(0), y: 0)); axes.addLine(to: CGPoint(x: sx(0), y: size.height)) }
        if yr.contains(0) { axes.move(to: CGPoint(x: 0, y: sy(0))); axes.addLine(to: CGPoint(x: size.width, y: sy(0))) }
        ctx.stroke(axes, with: .color(Color(uiColor: .secondaryLabel)), lineWidth: 1)
        // 刻度文字
        var tx = (xr.lowerBound / step).rounded(.up) * step
        let labelY = min(max(sy(0) + 4, 2), size.height - 14)
        while tx <= xr.upperBound {
            if abs(tx) > step / 2 {
                ctx.draw(Text(tick(tx)).font(.system(size: 9)).foregroundColor(Color(uiColor: .secondaryLabel)), at: CGPoint(x: sx(tx), y: labelY), anchor: .top)
            }
            tx += step
        }
        var ty = (yr.lowerBound / ystep).rounded(.up) * ystep
        let labelX = min(max(sx(0) + 4, 2), size.width - 24)
        while ty <= yr.upperBound {
            if abs(ty) > ystep / 2 {
                ctx.draw(Text(tick(ty)).font(.system(size: 9)).foregroundColor(Color(uiColor: .secondaryLabel)), at: CGPoint(x: labelX, y: sy(ty)), anchor: .leading)
            }
            ty += ystep
        }
        // 曲线
        for (i, f) in spec.functions.enumerated() {
            let color = VisualPalette.color(i)
            var path = Path()
            var pen = false
            func plot(_ p: CGPoint?) {
                guard let p, p.x.isFinite, p.y.isFinite, abs(p.y) < size.height * 20, abs(p.x) < size.width * 20 else { pen = false; return }
                if pen { path.addLine(to: p) } else { path.move(to: p); pen = true }
            }
            switch f.curve {
            case .explicitY(let e):
                let n = Int(size.width * 1.5)
                var lastY: Double?
                for k in 0...n {
                    let x = xr.lowerBound + (xr.upperBound - xr.lowerBound) * Double(k) / Double(n)
                    let y = e.evaluate(vars(["x": x]))
                    if let ly = lastY, y.isFinite, abs(y - ly) > (yr.upperBound - yr.lowerBound) * 2 { pen = false } // 渐近线断开
                    plot(y.isFinite ? CGPoint(x: sx(x), y: sy(y)) : nil)
                    lastY = y.isFinite ? y : nil
                }
            case .explicitX(let e):
                let n = Int(size.height * 1.5)
                for k in 0...n {
                    let y = yr.lowerBound + (yr.upperBound - yr.lowerBound) * Double(k) / Double(n)
                    let x = e.evaluate(vars(["y": y]))
                    plot(x.isFinite ? CGPoint(x: sx(x), y: sy(y)) : nil)
                }
            case .polar(let e):
                for k in 0...720 {
                    let th = Double(k) / 720 * 4 * .pi
                    let r = e.evaluate(vars(["theta": th, "t": th, "x": th]))
                    plot(r.isFinite ? CGPoint(x: sx(r * cos(th)), y: sy(r * sin(th))) : nil)
                }
            case .parametric(let ex, let ey, let tr):
                for k in 0...600 {
                    let t = tr.lowerBound + (tr.upperBound - tr.lowerBound) * Double(k) / 600
                    let x = ex.evaluate(vars(["t": t])), y = ey.evaluate(vars(["t": t]))
                    plot(x.isFinite && y.isFinite ? CGPoint(x: sx(x), y: sy(y)) : nil)
                }
            case .implicit(let e):
                path = marchingSquares(e, xr: xr, yr: yr, size: size, sx: sx, sy: sy)
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// 隐式曲线 F(x,y)=0：网格符号变化处线性插值连线。
    private func marchingSquares(_ e: MathExpression, xr: ClosedRange<Double>, yr: ClosedRange<Double>, size: CGSize,
                                 sx: (Double) -> CGFloat, sy: (Double) -> CGFloat) -> Path {
        let nx = 90, ny = 90
        let dx = (xr.upperBound - xr.lowerBound) / Double(nx), dy = (yr.upperBound - yr.lowerBound) / Double(ny)
        var grid = [[Double]](repeating: [Double](repeating: 0, count: ny + 1), count: nx + 1)
        for i in 0...nx { for j in 0...ny { grid[i][j] = e.evaluate(vars(["x": xr.lowerBound + Double(i) * dx, "y": yr.lowerBound + Double(j) * dy])) } }
        var path = Path()
        for i in 0..<nx {
            for j in 0..<ny {
                let x0 = xr.lowerBound + Double(i) * dx, y0 = yr.lowerBound + Double(j) * dy
                let v = [grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]]
                guard v.allSatisfy(\.isFinite) else { continue }
                let corners = [(x0, y0), (x0 + dx, y0), (x0 + dx, y0 + dy), (x0, y0 + dy)]
                var pts: [CGPoint] = []
                for k in 0..<4 {
                    let a = v[k], b = v[(k + 1) % 4]
                    if (a < 0) != (b < 0) {
                        let t = a / (a - b)
                        let (ax, ay) = corners[k], (bx, by) = corners[(k + 1) % 4]
                        pts.append(CGPoint(x: sx(ax + (bx - ax) * t), y: sy(ay + (by - ay) * t)))
                    }
                }
                if pts.count >= 2 { path.move(to: pts[0]); path.addLine(to: pts[1]) }
                if pts.count == 4 { path.move(to: pts[2]); path.addLine(to: pts[3]) }
            }
        }
        return path
    }

    private func niceStep(_ span: Double) -> Double {
        let raw = span / 8
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        return (n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10) * mag
    }

    private func tick(_ v: Double) -> String { v.formatted(.number.precision(.significantDigits(1...4))) }

    private var legend: some View {
        FlowLayout(spacing: 10) {
            ForEach(Array(spec.functions.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(VisualPalette.color(i)).frame(width: 12, height: 3)
                    Text(f.label).font(.caption.monospaced())
                }
            }
        }
    }
}

// MARK: - 表格

struct DataTableView: View {
    let spec: DataTableSpec
    @State private var sortKey: String?
    @State private var ascending = true
    @State private var query = ""
    @State private var page = 0

    private var filtered: [[String: JSONValue]] {
        var rows = spec.rows
        if let q = query.nonBlank?.lowercased() {
            rows = rows.filter { r in spec.columns.contains { cell(r, $0).lowercased().contains(q) } }
        }
        if let key = sortKey, let col = spec.columns.first(where: { $0.key == key }) {
            rows.sort { a, b in
                let less: Bool
                if col.type == "number", let x = a[key]?.doubleValue, let y = b[key]?.doubleValue { less = x < y }
                else { less = cell(a, col).localizedStandardCompare(cell(b, col)) == .orderedAscending }
                return ascending ? less : !less
            }
        }
        return rows
    }

    var body: some View {
        let rows = filtered
        let pages = max(1, Int(ceil(Double(rows.count) / Double(spec.pageSize))))
        let current = min(page, pages - 1)
        let slice = Array(rows.dropFirst(current * spec.pageSize).prefix(spec.pageSize))
        VisualCard(title: spec.title) {
            HStack {
                if spec.rows.count > spec.pageSize {
                    Image(systemName: "magnifyingglass").foregroundStyle(MolaColor.secondaryLabel)
                    TextField("搜索", text: $query).onChange(of: query) { _, _ in page = 0 }
                } else { Spacer() }
                Menu {
                    Button("拷贝为表格", systemImage: "doc.on.doc") { UIPasteboard.general.string = tsv(rows) }
                    ShareLink(item: CSVFile(text: csv(rows), name: spec.title ?? "table"), preview: SharePreview("\(spec.title ?? "table").csv")) {
                        Label("导出 CSV", systemImage: "square.and.arrow.up")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .font(.footnote)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(spec.columns, id: \.key) { c in
                            Button {
                                if sortKey == c.key { ascending.toggle() } else { sortKey = c.key; ascending = true }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(c.label).font(.footnote.weight(.semibold))
                                    if sortKey == c.key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2) }
                                }
                                .frame(minWidth: 64, maxWidth: 220, alignment: c.alignEnd ? .trailing : .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(MolaColor.fill)
                    ForEach(Array(slice.enumerated()), id: \.offset) { i, r in
                        GridRow {
                            ForEach(spec.columns, id: \.key) { c in
                                Text(cell(r, c)).font(.footnote.monospacedDigit())
                                    .frame(minWidth: 64, maxWidth: 220, alignment: c.alignEnd ? .trailing : .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }
                        .background(i % 2 == 1 ? MolaColor.fill.opacity(0.5) : .clear)
                    }
                }
                .textSelection(.enabled)
            }
            if pages > 1 {
                HStack {
                    Text("\(rows.count) 行").font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                    Spacer()
                    Button { page = max(0, current - 1) } label: { Image(systemName: "chevron.left") }.disabled(current == 0)
                    Text("\(current + 1) / \(pages)").font(.caption.monospacedDigit())
                    Button { page = min(pages - 1, current + 1) } label: { Image(systemName: "chevron.right") }.disabled(current >= pages - 1)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func cell(_ r: [String: JSONValue], _ c: DataTableSpec.Column) -> String {
        guard let v = r[c.key] else { return "" }
        if let b = v.boolValue { return b ? "✓" : "—" }
        if let d = v.doubleValue, v.stringValue == nil { return d.formatted(.number.precision(.significantDigits(1...10))) }
        return v.stringValue ?? v.jsonString()
    }

    private func csv(_ rows: [[String: JSONValue]]) -> String {
        func esc(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        let head = spec.columns.map { esc($0.label) }.joined(separator: ",")
        return ([head] + rows.map { r in spec.columns.map { esc(cell(r, $0)) }.joined(separator: ",") }).joined(separator: "\n")
    }

    private func tsv(_ rows: [[String: JSONValue]]) -> String {
        ([spec.columns.map(\.label).joined(separator: "\t")] + rows.map { r in spec.columns.map { cell(r, $0) }.joined(separator: "\t") })
            .joined(separator: "\n")
    }
}

struct CSVFile: Transferable {
    let text: String
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(file.name).csv")
            try Data(("\u{FEFF}" + file.text).utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - 指标卡

struct StatGridView: View {
    let spec: StatGridSpec

    var body: some View {
        VisualCard(title: spec.title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(Array(spec.items.enumerated()), id: \.offset) { _, item in StatTile(item: item) }
            }
        }
    }
}

private struct StatTile: View {
    let item: StatGridSpec.Item
    @State private var selected: Int?

    private var deltaColor: Color {
        if item.tone == "good" { return .green }
        if item.tone == "bad" { return .red }
        switch item.trend { case "up": return .green; case "down": return .red; default: return MolaColor.secondaryLabel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.label).font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(selected.map { item.history[$0].formatted(.number.precision(.significantDigits(1...6))) } ?? item.value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let u = item.unit { Text(u).font(.caption).foregroundStyle(MolaColor.secondaryLabel) }
            }
            if let d = item.delta {
                Label(d, systemImage: item.trend == "down" ? "arrow.down.right" : item.trend == "flat" ? "arrow.right" : "arrow.up.right")
                    .font(.caption2.weight(.medium)).foregroundStyle(deltaColor)
            }
            if item.history.count > 1 {
                Chart(Array(item.history.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("i", i), y: .value("v", v)).interpolationMethod(.monotone)
                    if selected == i { PointMark(x: .value("i", i), y: .value("v", v)).symbolSize(30) }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: (item.history.min() ?? 0)...(item.history.max() ?? 1))
                .chartXSelection(value: $selected)
                .foregroundStyle(MolaColor.accent)
                .frame(height: 32)
            }
            if let n = item.note { Text(n).font(.caption2).foregroundStyle(MolaColor.tertiaryLabel).lineLimit(2) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MolaColor.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 卡片网格

struct CardGridView: View {
    let spec: CardGridSpec
    @State private var tag: String?
    @Environment(\.openURL) private var openURL

    private var tags: [String] {
        var seen = Set<String>()
        return spec.items.compactMap(\.tag).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VisualCard(title: spec.title) {
            if tags.count >= 2 {
                Picker("分类", selection: $tag) {
                    Text("全部").tag(String?.none)
                    ForEach(tags, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(Array(spec.items.filter { tag == nil || $0.tag == tag }.enumerated()), id: \.offset) { _, it in
                    Button { if let u = it.url.flatMap(URL.init(string:)) { openURL(u) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if let t = it.tag {
                                    Text(t).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(MolaColor.accentSoft, in: Capsule()).foregroundStyle(MolaColor.accent)
                                }
                                Spacer()
                                if it.url != nil { Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(MolaColor.tertiaryLabel) }
                            }
                            Text(it.title).font(.subheadline.weight(.semibold)).foregroundStyle(MolaColor.label).multilineTextAlignment(.leading)
                            if let s = it.summary { Text(s).font(.footnote).foregroundStyle(MolaColor.secondaryLabel).lineLimit(4).multilineTextAlignment(.leading) }
                            if let src = it.source { Text(src).font(.caption2).foregroundStyle(MolaColor.tertiaryLabel) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MolaColor.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(it.url == nil)
                }
            }
        }
    }
}

/// 简单换行布局（图例用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
