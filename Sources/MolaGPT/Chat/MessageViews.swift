import SwiftUI
import UIKit
import MolaCore
import MolaStorage

struct MessageRow: View {
    let message: ChatMessage
    let controller: ChatController

    var body: some View {
        if message.role == .user {
            UserMessageView(message: message, controller: controller)
        } else {
            AssistantMessageView(message: message, controller: controller)
        }
    }
}

// MARK: - 用户消息：右对齐气泡，长按菜单

struct UserMessageView: View {
    @Environment(\.uiStyle) private var style
    let message: ChatMessage
    let controller: ChatController
    @State private var expanded = false
    @State private var copied = 0

    private var bubbleFill: Color {
        switch style { case .native: return MolaColor.bubble; case .claude: return MolaColor.userBubbleClaude; case .android: return MolaColor.androidContainer }
    }

    /// 安卓风格：右上角收窄的 Material 聊天气泡。
    private var bubbleShape: UnevenRoundedRectangle {
        style == .android
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 4, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
    }

    private var isLong: Bool {
        message.text.split(separator: "\n", omittingEmptySubsequences: false).count > 10 || message.text.count > 700
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { AttachmentThumb(attachment: $0, url: controller.attachmentURL($0), size: 96) }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .frame(maxWidth: 320)
            }
            if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text)
                        .lineLimit(expanded || !isLong ? nil : 10)
                    if isLong {
                        Button(expanded ? "收起" : "展开全部") { withAnimation(.snappy) { expanded.toggle() } }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(style == .native ? .white : MolaColor.label)
                .tint(style == .native ? .white : MolaColor.accent)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(bubbleFill, in: bubbleShape)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Button { UIPasteboard.general.string = message.text; copied += 1 } label: {
                        Label("拷贝", systemImage: "doc.on.doc")
                    }
                    Button { controller.startEdit(message.messageId) } label: { Label("编辑", systemImage: "pencil") }
                        .disabled(controller.isStreaming)
                    ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        .disabled(message.text.isEmpty)
                }
                .sensoryFeedback(.success, trigger: copied)
            }
            if message.branchCount > 1, let b = message.editBranches?.value {
                VersionSwitcher(position: b.position, count: b.count, disabled: controller.isStreaming) {
                    controller.selectBranch(message.messageId, $0 - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

// MARK: - 助手消息：无气泡正文 + 轻量操作行

struct AssistantMessageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.uiStyle) private var style
    @State private var selecting = false
    let message: ChatMessage
    let controller: ChatController
    @State private var editing = false
    @State private var showStats = false
    @State private var copied = 0
    @State private var confirmDelete = false

    var isStreaming: Bool { controller.streamingMessageId == message.messageId }
    private var hasText: Bool { message.fragments.contains { if case .text = $0 { return true }; return false } }
    private var sources: [SourceReference]? {
        for f in message.fragments { if case .search(_, _, let refs, _) = f { return refs } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(FragmentGroup.build(message.fragments)) { g in
                switch g {
                case .single(let f): FragmentView(fragment: f, streaming: isStreaming)
                case .searches(_, let tools): SearchGroupView(tools: tools)
                }
            }
            if let refs = sources, !refs.isEmpty, !isStreaming || hasText {
                SourcesButton(refs: refs)
            }
            if isStreaming && !hasText {
                TypingIndicator()
            }
            if message.status == .stopped {
                Label("已停止生成", systemImage: "stop.circle").font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
            }
            if !isStreaming {
                if style == .android { androidActionBar } else { actionRow }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.citationSources, sources ?? [])
        .sheet(isPresented: $editing) {
            AssistantEditSheet(text: message.text) { controller.editAssistant(message.messageId, newText: $0) }
        }
        .sheet(isPresented: $showStats) {
            if let stats = message.stats {
                StatsSheet(stats: stats, model: message.model, sessionTotal: controller.totalCost)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $selecting) { SelectTextSheet(text: message.text) }
        .confirmationDialog("删除这条回答？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { controller.deleteMessage(message.messageId) }
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            Button { UIPasteboard.general.string = message.text; copied += 1 } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("拷贝")
            if controller.canRegenerate(message) {
                Menu {
                    Button { controller.regenerate(message.messageId) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                    ForEach(app.modelGroups, id: \.provider.id) { g in
                        Menu {
                            ForEach(g.models) { m in
                                Button(m.displayName) { controller.regenerate(message.messageId, using: (g.provider, m)) }
                            }
                        } label: { Label("换用 \(g.provider.name)", systemImage: "cpu") }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                } primaryAction: {
                    controller.regenerate(message.messageId)
                }
                .accessibilityLabel("重新生成")
            }
            if message.versionCount > 1 {
                VersionSwitcher(position: message.retryCurrent + 1, count: message.versionCount, disabled: controller.isStreaming) {
                    controller.selectVersion(message.messageId, $0 - 1)
                }
            }
            Menu {
                Button { editing = true } label: { Label("编辑回答", systemImage: "pencil") }
                if message.stats != nil {
                    Button { showStats = true } label: { Label("用量与耗时", systemImage: "chart.bar") }
                }
                // 单条分享：正文 Markdown（不含思考 / 工具调用），与「分享对话」规则一致
                ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                    .disabled(message.text.isEmpty)
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minHeight: 20)
            }
            .accessibilityLabel("更多")
            Spacer(minLength: 0)
            if let stats = message.stats {
                Button { showStats = true } label: {
                    Text(statsSummary(stats)).font(.caption.monospacedDigit())
                }
                .foregroundStyle(MolaColor.tertiaryLabel)
            }
        }
        .font(.subheadline)
        .foregroundStyle(MolaColor.secondaryLabel)
        .buttonStyle(.borderless)
    }

    /// 安卓风格：用量 chip + 常驻「复制 / 选择 / 编辑 / 重新生成」操作栏（长按重新生成可换模型）。
    private var androidActionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats = message.stats {
                Button { showStats = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar")
                        Text(androidStats(stats)).monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(Capsule().stroke(MolaColor.androidOutline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MolaColor.secondaryLabel)
            }
            HStack(spacing: 4) {
                barButton("复制", "doc.on.doc") { UIPasteboard.general.string = message.text; copied += 1 }
                barButton("选择", "selection.pin.in.out") { selecting = true }
                barButton("编辑", "pencil") { editing = true }
                if controller.canRegenerate(message) {
                    Menu {
                        ForEach(app.modelGroups, id: \.provider.id) { g in
                            Section(g.provider.name) {
                                ForEach(g.models) { m in
                                    Button(m.displayName) { controller.regenerate(message.messageId, using: (g.provider, m)) }
                                }
                            }
                        }
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise").labelStyle(.iconOnly).frame(width: 36, height: 32)
                    } primaryAction: {
                        controller.regenerate(message.messageId)
                    }
                    .accessibilityLabel("重新生成")
                }
                if message.versionCount > 1 {
                    VersionSwitcher(position: message.retryCurrent + 1, count: message.versionCount, disabled: controller.isStreaming) {
                        controller.selectVersion(message.messageId, $0 - 1)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        .disabled(message.text.isEmpty)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 32) }
            }
            .font(.subheadline)
            .foregroundStyle(MolaColor.secondaryLabel)
            .buttonStyle(.borderless)
        }
    }

    private func barButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 36, height: 32) }
            .accessibilityLabel(title)
    }

    private func androidStats(_ s: MessageStats) -> String {
        var t = "Tokens ↑\(s.usage.promptTokens.map { $0.formatted() } ?? "–") ↓\(s.usage.completionTokens.map { $0.formatted() } ?? "–")"
        if let c = s.costUsd { t += " · \(ModelPricing.format(c))" }
        return t
    }

    private func statsSummary(_ s: MessageStats) -> String {
        var parts: [String] = []
        if let c = s.costUsd { parts.append(ModelPricing.format(c)) }
        else if let out = s.usage.completionTokens { parts.append("\(out) tokens") }
        if let d = s.durationMs { parts.append(String(format: "%.1fs", Double(d) / 1000)) }
        return parts.joined(separator: " · ")
    }
}

struct FragmentView: View {
    let fragment: MessageFragment
    let streaming: Bool

    var body: some View {
        switch fragment {
        case .text(_, let md):
            MarkdownView(text: md)
        case .thinking(_, let text, _, let dur):
            ThinkingView(text: text, durationMs: dur, live: streaming && dur == nil)
        case .code(_, let lang, let code):
            if lang?.lowercased() == "mermaid" { MermaidView(source: code, closed: !streaming) }
            else { CodeBlockView(language: lang, code: code) }
        case .latex(_, let expr, _):
            MathBlockView(expr: expr)
        case .mermaid(_, let src):
            MermaidView(source: src, closed: !streaming)
        case .search:
            EmptyView() // 来源统一在消息末尾的「来源」按钮里展示
        case .tool(let t):
            ToolCallView(name: t.label ?? ToolLabels.label(t.name), icon: ToolLabels.icon(t.name), label: t.statusLabel,
                         status: t.status, detail: t.resultPreview)
        case .file(_, let f):
            Label(f.name, systemImage: "doc").font(.footnote)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(MolaColor.fill, in: Capsule())
        case .image(_, let url, _, _, _):
            RemoteOrDataImage(urlString: url).frame(maxWidth: 320, maxHeight: 320, alignment: .leading)
        case .tip(_, let t):
            Text(t).font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
        case .error(_, let msg):
            Label {
                Text(msg).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 思考过程：默认折叠，标题「已思考 Ns」；生成中显示最近几行。
struct ThinkingView: View {
    let text: String
    let durationMs: Int64?
    let live: Bool
    @State private var expanded = false

    private var title: String {
        if live { return "正在思考…" }
        if let d = durationMs { return "已思考 \(max(1, Int((Double(d) / 1000).rounded()))) 秒" }
        return "思考过程"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").symbolEffect(.pulse, isActive: live)
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(MolaColor.secondaryLabel)
            }
            .buttonStyle(.plain)
            if expanded || live {
                Text(live && !expanded ? String(text.suffix(300)) : text)
                    .font(.subheadline)
                    .foregroundStyle(MolaColor.secondaryLabel)
                    .lineLimit(live && !expanded ? 3 : nil)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule().fill(MolaColor.separator).frame(width: 2)
                    }
            }
        }
    }
}

struct ToolCallView: View {
    @Environment(\.uiStyle) private var style
    let name: String
    var icon: String = "wrench.and.screwdriver"
    let label: String?
    let status: ToolStatus
    let detail: String?
    @State private var expanded = false

    private var hasDetail: Bool { detail?.isEmpty == false }

    var body: some View {
        switch style {
        case .claude: claudeRow
        case .native: card(fill: true)
        case .android: card(fill: false)
        }
    }

    /// Claude 式轻量行：图标 + 灰色标题，可展开查看详情（左侧细线）。
    private var claudeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { toggle() } label: {
                HStack(spacing: 8) {
                    statusIcon(successIcon: icon).frame(width: 18)
                    Text(name).fontWeight(.medium)
                    if let label { Text(label).foregroundStyle(MolaColor.tertiaryLabel).lineLimit(1) }
                    if hasDetail { chevron }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .foregroundStyle(MolaColor.secondaryLabel)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(statusText)
            if expanded, let detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(MolaColor.secondaryLabel).lineLimit(20).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(MolaColor.separator).frame(width: 1.5).padding(.leading, 8) }
                    .padding(.leading, 8)
            }
        }
    }

    /// iOS 原生：填充卡片；安卓：描边卡片 + 右侧状态文字。
    private func card(fill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { toggle() } label: {
                HStack(spacing: 8) {
                    if fill {
                        switch status {
                        case .running: ProgressView().controlSize(.small)
                        case .success: Image(systemName: icon).foregroundStyle(MolaColor.accent)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(MolaColor.secondaryLabel)
                        }
                    } else {
                        Image(systemName: icon).foregroundStyle(MolaColor.accent)
                    }
                    Text(name).fontWeight(.medium)
                    if let label { Text(label).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1) }
                    Spacer(minLength: 0)
                    if !fill {
                        if status == .running { ProgressView().controlSize(.mini) }
                        Text(statusText).font(.caption)
                            .foregroundStyle(status == .failed ? MolaColor.androidError : MolaColor.secondaryLabel)
                    }
                    if hasDetail { chevron }
                }
                .font(.subheadline)
                .foregroundStyle(MolaColor.label)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(MolaColor.secondaryLabel).lineLimit(14).textSelection(.enabled)
            }
        }
        .padding(fill ? 10 : 12)
        .background {
            if fill { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MolaColor.secondaryBackground) }
            else { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MolaColor.androidOutline, lineWidth: 1) }
        }
    }

    @ViewBuilder private func statusIcon(successIcon: String) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(MolaColor.tertiaryLabel)
        case .success: Image(systemName: successIcon)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            .foregroundStyle(MolaColor.tertiaryLabel)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }

    private func toggle() { if hasDetail { withAnimation(.snappy) { expanded.toggle() } } }

    private var statusText: String {
        switch status { case .running: return "进行中"; case .success: return "完成"; case .failed: return "失败"; case .cancelled: return "已停止" }
    }
}

/// 生成中占位：三个跳动的点。
struct TypingIndicator: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            Image(systemName: "ellipsis")
                .font(.title2.weight(.bold))
                .foregroundStyle(MolaColor.secondaryLabel)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// 用量明细（sheet，带 detents）。
struct StatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let stats: MessageStats
    let model: String?
    let sessionTotal: Double?

    var body: some View {
        NavigationStack {
            Form {
                Section("花费") {
                    if let c = stats.costUsd { LabeledContent("本条回答", value: ModelPricing.format(c)) }
                    else { LabeledContent("本条回答", value: stats.pricingMissing ? "未设置价格" : "—") }
                    if let t = sessionTotal { LabeledContent("对话累计", value: ModelPricing.format(t)) }
                }
                Section("Tokens") {
                    LabeledContent("输入", value: fmt(stats.usage.promptTokens))
                    if let c = stats.usage.cachedTokens, c > 0 { LabeledContent("缓存命中", value: fmt(c)) }
                    LabeledContent("输出", value: fmt(stats.usage.completionTokens))
                    if let r = stats.usage.reasoningTokens, r > 0 { LabeledContent("其中思考", value: fmt(r)) }
                }
                Section("速度") {
                    if let s = stats.tokensPerSecond { LabeledContent("生成速度", value: String(format: "%.1f tokens/秒", s)) }
                    if let t = stats.ttftMs { LabeledContent("首字延迟", value: String(format: "%.2f 秒", Double(t) / 1000)) }
                    if let d = stats.durationMs { LabeledContent("总耗时", value: String(format: "%.1f 秒", Double(d) / 1000)) }
                }
                if let model { Section("模型") { Text(model).foregroundStyle(MolaColor.secondaryLabel) } }
            }
            .monospacedDigit()
            .navigationTitle("用量与耗时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func fmt(_ n: Int?) -> String { n.map { $0.formatted() } ?? "—" }
}

/// `‹ n/m ›` 版本切换。
struct VersionSwitcher: View {
    let position: Int
    let count: Int
    let disabled: Bool
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { select(position - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(disabled || position <= 1)
            Text("\(position)/\(count)").font(.caption.monospacedDigit())
            Button { select(position + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(disabled || position >= count)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(MolaColor.secondaryLabel)
        .buttonStyle(.borderless)
        .sensoryFeedback(.selection, trigger: position)
    }
}

struct AssistantEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let save: (String) -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal, 12)
                .navigationTitle("编辑回答")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save(text); dismiss() }.fontWeight(.semibold) }
                }
        }
    }
}

// MARK: - 附件 / 图片

struct AttachmentThumb: View {
    let attachment: Attachment
    let url: URL?
    var size: CGFloat = 64
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.isImage, let url, let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: attachment.mimeType.contains("pdf") ? "doc.richtext.fill" : "doc.text.fill")
                            .font(.title2).foregroundStyle(MolaColor.accent)
                        Text(attachment.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                            .foregroundStyle(MolaColor.secondaryLabel)
                    }
                    .padding(6)
                }
            }
            .frame(width: size, height: size)
            .background(MolaColor.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.title3)
                }
                .offset(x: 6, y: -6)
                .accessibilityLabel("移除附件")
            }
        }
    }
}

struct RemoteOrDataImage: View {
    let urlString: String
    @State private var preview = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { preview = true }
            .fullScreenCover(isPresented: $preview) { ImagePreview(urlString: urlString) }
    }

    @ViewBuilder private var content: some View {
        if let img = LocalImages.load(urlString) {
            Image(uiImage: img).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if urlString.hasPrefix("data:"), let comma = urlString.firstIndex(of: ","),
           let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])),
           let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                case .failure: Label("图片加载失败", systemImage: "photo").font(.footnote)
                default: ProgressView()
                }
            }
        }
    }
}

/// 「选择」：在可选中的文本里自由选取一段（安卓操作栏的「选择」）。
struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("选择文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("全部拷贝", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
