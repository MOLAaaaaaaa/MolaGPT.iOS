import SwiftUI
import MolaCore
import MolaStorage

/// 输入栏旁的上下文仪表环：实测 token ÷ 窗口；点开为详情 sheet。
struct ContextGaugeButton: View {
    @Environment(AppModel.self) private var app
    let controller: ChatController
    @State private var show = false

    var body: some View {
        if let g = app.compaction.gauge(controller), !controller.messages.isEmpty {
            let ratio = min(Double(g.used) / Double(max(g.window, 1)), 1)
            Button { show = true } label: {
                ZStack {
                    Circle().stroke(MolaColor.separator, lineWidth: 3)
                    Circle().trim(from: 0, to: ratio)
                        .stroke(color(g.pressure), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if app.compaction.compacting.contains(controller.conversation.sessionId) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上下文 \(Int(ratio * 100))%")
            .sheet(isPresented: $show) {
                ContextGaugeSheet(controller: controller)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func color(_ p: ContextEstimator.Pressure) -> Color {
        switch p { case .normal: return MolaColor.accent; case .warning: return .orange; case .critical: return .red }
    }
}

struct ContextGaugeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let controller: ChatController
    @State private var showSummary = false

    var body: some View {
        @Bindable var app = app
        let sid = controller.conversation.sessionId
        let st = app.compaction.stats(sid)
        NavigationStack {
            Form {
                if let g = app.compaction.gauge(controller) {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(g.estimated ? "约 " : "")\(g.used.formatted()) / \(g.window.formatted())").font(.headline.monospacedDigit())
                                Spacer()
                                Text("\(Int(Double(g.used) / Double(max(g.window, 1)) * 100))%").foregroundStyle(MolaColor.secondaryLabel)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(MolaColor.fill)
                                    Capsule().fill(g.pressure == .critical ? Color.red : g.pressure == .warning ? .orange : MolaColor.accent)
                                        .frame(width: geo.size.width * min(Double(g.used) / Double(max(g.window, 1)), 1))
                                    Rectangle().fill(MolaColor.secondaryLabel).frame(width: 1.5, height: 12)
                                        .offset(x: geo.size.width * ContextEstimator.triggerRatio)
                                }
                            }
                            .frame(height: 8)
                            Text(remaining(g)).font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                            if g.estimated { Text("当前为估算值，回答后更新。").font(.caption).foregroundStyle(MolaColor.tertiaryLabel) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    Toggle("自动压缩", isOn: $app.settings.contextCompactionEnabled)
                    Toggle("精简旧工具结果与图片", isOn: $app.settings.contextSlimmingEnabled)
                    ModelKeyPicker(title: "摘要模型", selection: $app.settings.compactionModelKey, noneLabel: "与对话相同")
                } footer: { Text("接近上下文上限时，较早的对话会压缩成摘要，原消息仍保留在界面上。") }
                Section {
                    LabeledContent("累计压缩", value: "\(st.count) 次")
                    if st.saved > 0 { LabeledContent("最近节省", value: "约 \(st.saved.formatted()) tokens") }
                    if st.cost > 0 { LabeledContent("摘要费用", value: ModelPricing.format(st.cost)) }
                    if st.latest != nil { Button("查看对话摘要") { showSummary = true } }
                    Button {
                        app.compaction.compactNow(controller)
                    } label: {
                        HStack {
                            Text(controller.isStreaming ? "回答完成后可压缩" : "立即压缩")
                            Spacer()
                            if app.compaction.compacting.contains(sid) { ProgressView() }
                        }
                    }
                    .disabled(controller.isStreaming || app.compaction.compacting.contains(sid))
                    if let e = app.compaction.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showSummary) {
                NavigationStack {
                    ScrollView { Text(st.latest?.summary ?? "").textSelection(.enabled).padding() }
                        .navigationTitle("对话摘要").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private func remaining(_ g: CompactionService.Gauge) -> String {
        guard app.settings.contextCompactionEnabled else { return "自动压缩已关闭" }
        let left = Int(Double(g.window) * ContextEstimator.triggerRatio) - g.used
        return left <= 0 ? "下次发送前自动压缩" : "自动压缩还需约 \(left.formatted()) tokens"
    }
}

/// 消息列表里的压缩记录。
struct CompactionMarker: View {
    let checkpoint: ContextCheckpoint
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(MolaColor.separator).frame(height: 0.5)
            Label("以上内容已压缩为摘要", systemImage: "rectangle.compress.vertical")
                .font(.caption).foregroundStyle(MolaColor.secondaryLabel).fixedSize()
            Rectangle().fill(MolaColor.separator).frame(height: 0.5)
        }
        .padding(.vertical, 4)
    }
}
