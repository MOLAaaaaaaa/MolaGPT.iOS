import SwiftUI
import UIKit
import Photos
import MolaCore
import MolaStorage

/// 消息片段的展示分组：相邻 ≥2 个 search_web 合并为一张卡（对应安卓 consecutiveWebSearchTools）。
enum FragmentGroup: Identifiable {
    case single(MessageFragment)
    case searches(id: String, tools: [ToolCallFragment])

    var id: String {
        switch self { case .single(let f): return f.id; case .searches(let id, _): return id }
    }

    static func build(_ fragments: [MessageFragment]) -> [FragmentGroup] {
        var out: [FragmentGroup] = []
        var run: [ToolCallFragment] = []
        func flush() {
            if run.count >= 2 { out.append(.searches(id: "grp_" + run[0].id, tools: run)) }
            else { out += run.map { .single(.tool($0)) } }
            run = []
        }
        for f in fragments {
            if case .tool(let t) = f, t.name == "search_web" || t.name == "web_search" { run.append(t); continue }
            flush()
            out.append(.single(f))
        }
        flush()
        return out
    }
}

struct SearchGroupView: View {
    let tools: [ToolCallFragment]

    private var title: String {
        let running = tools.filter { $0.status == .running }.count
        let failed = tools.filter { $0.status == .failed }.count
        if running > 0 { return "正在进行 \(tools.count) 项搜索" }
        if failed == tools.count { return "搜索失败" }
        if failed > 0 { return "搜索已结束" }
        if tools.contains(where: { $0.status == .cancelled }) { return "搜索已停止" }
        return "已完成 \(tools.count) 次搜索"
    }

    private var queries: String {
        tools.enumerated().map { i, t in
            let args = JSONValue.parse(t.argsJson ?? "")
            let q = args?["query"]?.stringValue
                ?? args?["queries"]?.arrayValue?.compactMap { $0["query"]?.stringValue }.joined(separator: " / ") ?? ""
            return "\(i + 1). \(q)"
        }.joined(separator: "\n")
    }

    var body: some View {
        let status: ToolStatus = tools.contains { $0.status == .running } ? .running
            : tools.allSatisfy { $0.status == .failed } ? .failed : .success
        ToolCallView(name: title, icon: "magnifyingglass", label: nil, status: status, detail: queries)
    }
}

/// 回答末尾的「来源」按钮：叠放的站点首字母 + 数量，点开为来源列表 sheet。
struct SourcesButton: View {
    let refs: [SourceReference]
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(Array(refs.prefix(3).enumerated()), id: \.offset) { _, r in
                        Text(String(r.site.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                            .font(.caption2.bold())
                            .frame(width: 20, height: 20)
                            .background(MolaColor.accentSoft, in: Circle())
                            .overlay(Circle().stroke(MolaColor.background, lineWidth: 1.5))
                    }
                }
                Text("\(refs.count) 个来源").font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(MolaColor.secondaryBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(MolaColor.label)
        .sheet(isPresented: $show) {
            SourcesSheet(refs: refs)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct SourcesSheet: View {
    let refs: [SourceReference]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List(refs, id: \.url) { r in
                Button { if let u = URL(string: r.url) { openURL(u) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("\(r.index ?? 0)").font(.caption2.bold().monospacedDigit())
                                .frame(minWidth: 18, minHeight: 18)
                                .background(MolaColor.accentSoft, in: RoundedRectangle(cornerRadius: 5))
                            Text(r.site).font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                        }
                        Text(r.title).font(.subheadline.weight(.medium)).foregroundStyle(MolaColor.label).lineLimit(2)
                        if let s = r.snippet?.nonBlank {
                            Text(s).font(.footnote).foregroundStyle(MolaColor.secondaryLabel).lineLimit(3)
                        }
                    }
                }
                .contextMenu {
                    Button("拷贝链接", systemImage: "link") { UIPasteboard.general.string = r.url }
                    ShareLink(item: r.url) { Label("分享", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 引用角标

private struct CitationSourcesKey: EnvironmentKey { static let defaultValue: [SourceReference] = [] }
extension EnvironmentValues {
    var citationSources: [SourceReference] {
        get { self[CitationSourcesKey.self] }
        set { self[CitationSourcesKey.self] = newValue }
    }
}

enum Citations {
    /// 引用标签的标记字符（零宽），InlineText 据此把链接渲染成来源小标签。
    static let marker = "\u{2060}"

    static func siteName(_ ref: SourceReference) -> String {
        var h = URL(string: ref.url)?.host ?? ref.site
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// `<ref source="1,3" />` → 行内来源小标签（Claude 式：站点名，点按打开）；解析不到的标签与末尾半截标签去掉。
    private static let superscripts: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]

    /// 按界面风格渲染引用：iOS 原生 → 上标数字；Claude → 来源小标签；安卓 → [1]。
    static func rewrite(_ text: String, sources: [SourceReference], style: UIStyle = .claude) -> String {
        guard text.contains("<ref") else { return text }
        var t = text
        if let r = t.range(of: #"<ref[^>]*$"#, options: .regularExpression) { t.removeSubrange(r) }
        guard let re = try? NSRegularExpression(pattern: #"\s*<ref\b[^>]*?/?>(?:\s*</ref>)?"#, options: [.caseInsensitive]) else { return t }
        let ns = t as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let tag = ns.substring(with: m.range)
            let nums = tag.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            var seen = Set<String>()
            for n in nums {
                guard let ref = sources.first(where: { $0.index == n }), seen.insert(ref.url).inserted else { continue }
                switch style {
                case .claude:
                    let name = siteName(ref).replacingOccurrences(of: "]", with: "")
                    out += " [\(marker)\u{2009}\(name)\u{2009}](\(ref.url))"
                case .native:
                    out += "[\(String(String(n).compactMap { superscripts[$0] }))](\(ref.url))"
                case .android:
                    out += "[\\[\(n)\\]](\(ref.url))"
                }
            }
        }
        out += ns.substring(from: cursor)
        return out
    }
}

// MARK: - 本地图片

enum LocalImages {
    static let prefix = "local:"

    /// `local:<相对 Documents 的路径>` → 绝对 URL（容器路径在升级后会变，所以库里只存相对路径）。
    static func url(_ s: String) -> URL? {
        if s.hasPrefix(prefix) { return AppPaths.documents.appendingPathComponent(String(s.dropFirst(prefix.count))) }
        if s.hasPrefix("file://"), let u = URL(string: s) { return u }
        return nil
    }

    static func load(_ s: String) -> UIImage? {
        guard let u = url(s) else { return nil }
        return UIImage(contentsOfFile: u.path)
    }

    static func data(_ s: String) async -> Data? {
        if let u = url(s) { return try? Data(contentsOf: u) }
        if s.hasPrefix("data:") { return ImageGenAPI.decodeDataURI(s)?.0 }
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u)
        r.setValue(MolaUA.browser, forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: r).0
    }
}

/// 全屏图片预览：双指缩放、双击放大、存到相册、分享。
struct ImagePreview: View {
    let urlString: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var savedTick = 0
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale).offset(offset)
                        .gesture(MagnifyGesture().onChanged { scale = max(1, lastScale * $0.magnification) }
                            .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero } })
                        .simultaneousGesture(DragGesture().onChanged { v in if scale > 1 { offset = v.translation } })
                        .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.5; lastScale = scale; offset = .zero } }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let image {
                        Button("存储到相册", systemImage: "square.and.arrow.down") { save(image) }
                        Spacer()
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("图片", image: Image(uiImage: image)))
                    }
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") {}
            }
            .sensoryFeedback(.success, trigger: savedTick)
        }
        .task {
            if let d = await LocalImages.data(urlString) { image = UIImage(data: d) }
        }
    }

    private func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else { message = "没有相册写入权限，请在系统设置中允许。"; return }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                savedTick += 1
            }
        }
    }
}
