import SwiftUI
import UIKit
import MolaCore
import MolaStorage

/// Markdown 渲染：块级由 MolaCore.MarkdownParser 切分，行内交给 AttributedString。
struct MarkdownView: View {
    let text: String
    @Environment(\.citationSources) private var sources
    @Environment(\.uiStyle) private var style

    var body: some View {
        let blocks = MarkdownParser.parse(Citations.rewrite(text, sources: sources, style: style))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                BlockView(block: b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    @Environment(\.htmlAsCard) private var htmlAsCard

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            InlineText(text)
        case .code(let lang, let code, let closed):
            if lang?.lowercased() == "mola-ui" {
                VisualBlockView(source: code, closed: closed)
            } else if lang?.lowercased() == "mermaid" {
                MermaidView(source: code, closed: closed)
            } else if HtmlFence.isHTML(language: lang, code: code), htmlAsCard, HtmlFence.isPage(code, closed: closed) {
                HtmlCardView(code: code, closed: closed)
            } else if HtmlFence.isHTML(language: lang, code: code) {
                HtmlCodeBlock(code: code, closed: closed)
            } else {
                CodeBlockView(language: lang, code: code)
            }
        case .math(let expr):
            MathBlockView(expr: expr)
        case .quote(let inner):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
            }
            .foregroundStyle(MolaColor.secondaryLabel)
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(MolaColor.accent.opacity(0.5)).frame(width: 3) }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? MolaColor.accent : MolaColor.secondaryLabel)
                            } else if ordered {
                                Text("\(start + i).").monospacedDigit()
                            } else {
                                Text("•")
                            }
                        }
                        .foregroundStyle(MolaColor.secondaryLabel)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
                        }
                    }
                }
            }
        case .table(let header, let aligns, let rows):
            TableBlockView(header: header, alignments: aligns, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

/// 行内 Markdown（粗斜体、行内代码、链接、删除线）+ 行内公式（SwiftMath 渲染成图片嵌入文本）。
struct InlineText: View {
    let source: String
    init(_ source: String) { self.source = source }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        composed
            .foregroundStyle(MolaColor.label)
            .tint(MolaColor.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var composed: Text {
        let segments = InlineMath.split(source)
        if segments.count == 1, case .text(let t) = segments[0] { return Text(Self.attributed(t)) }
        let size = UIFont.preferredFont(forTextStyle: .body).pointSize
        var out = Text(verbatim: "")
        for seg in segments {
            switch seg {
            case .text(let t):
                out = Text("\(out)\(Text(Self.attributed(t)))")
            case .math(let latex):
                if let r = MathRenderer.inline(latex, fontSize: size, dark: scheme == .dark) {
                    let img = Text(Image(uiImage: r.image)).baselineOffset(-r.descent)
                    out = Text("\(out)\(img)")
                } else {
                    out = Text("\(out)\(Text(verbatim: latex).font(.system(.body, design: .monospaced)))")
                }
            }
        }
        return out
    }

    static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        guard var a = try? AttributedString(markdown: s, options: opts) else { return AttributedString(s) }
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(.body, design: .monospaced)
            a[run.range].backgroundColor = MolaColor.codeBackground
        }
        // 引用：带标记的链接渲染成灰底小标签
        for run in a.runs where run.link != nil {
            let text = String(a[run.range].characters)
            guard text.hasPrefix(Citations.marker) else { continue }
            a[run.range].font = .caption.weight(.medium)
            a[run.range].foregroundColor = MolaColor.secondaryLabel
            a[run.range].backgroundColor = MolaColor.fill
            a[run.range].underlineStyle = nil
        }
        return a
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code").font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MolaColor.secondaryLabel)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeColors.highlight(code, language: language))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(MolaColor.label)
                    .textSelection(.enabled)
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(MolaColor.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MolaColor.separator, lineWidth: 0.5))
    }
}

/// 块级公式：SwiftMath 原生渲染（display 模式，超宽可横向滚动）；解析失败回退显示源码。
struct MathBlockView: View {
    let expr: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = UIFont.preferredFont(forTextStyle: .body).pointSize + 2
        Group {
            if let r = MathRenderer.display(expr, fontSize: size, dark: scheme == .dark) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: r.image)
                        .padding(.vertical, 6).padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(Text(verbatim: expr))
                .contextMenu {
                    Button("拷贝 LaTeX", systemImage: "doc.on.doc") { UIPasteboard.general.string = expr }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(expr)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(MolaColor.label)
                        .textSelection(.enabled)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(MolaColor.fill))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct TableBlockView: View {
    let header: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { i in cell(header[i], i, bold: true) }
                }
                .background(MolaColor.codeBackground)
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { i in cell(rows[r][i], i, bold: false) }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MolaColor.separator, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cell(_ s: String, _ col: Int, bold: Bool) -> some View {
        let align: Alignment = switch alignments[safe: col] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return InlineText(s)
            .font(bold ? .footnote.bold() : .footnote)
            .frame(minWidth: 60, maxWidth: 260, alignment: align)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .border(MolaColor.separator.opacity(0.6), width: 0.25)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// 短 HTML 片段：普通代码块，写完后可运行。
struct HtmlCodeBlock: View {
    let code: String
    let closed: Bool
    @State private var running = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            CodeBlockView(language: "html", code: code)
            if closed {
                Button("运行", systemImage: "play.fill") { running = true }.font(.caption).buttonStyle(.bordered)
            }
        }
        .fullScreenCover(isPresented: $running) { HtmlRunnerView(html: code, title: HtmlFence.title(code)) }
    }
}

private struct HtmlAsCardKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var htmlAsCard: Bool {
        get { self[HtmlAsCardKey.self] }
        set { self[HtmlAsCardKey.self] = newValue }
    }
}
