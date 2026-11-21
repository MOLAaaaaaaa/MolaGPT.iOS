import SwiftUI
import MolaCore

/// 聊天页（详情列）。
/// - 导航标题 = 当前模型，点标题弹出模型菜单（toolbarTitleMenu）；iOS 26 起副标题显示对话标题。
/// - 右上角：新对话 + 「…」对话菜单（角色、重命名、置顶、分享、删除）。
/// - 输入栏通过 safeAreaInset 悬浮在内容之上（Liquid Glass / 材质）。
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openDrawer) private var openDrawer
    let controller: ChatController

    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    private var hasTitle: Bool { controller.conversation.title != Conversation.defaultTitle }

    var body: some View {
        Group {
            if controller.messages.isEmpty {
                EmptyChatView(controller: controller)
            } else {
                MessageListView(controller: controller)
            }
        }
        .background(MolaColor.background)
        .molaBottomBar {
            ComposerView(controller: controller)
        }
        .navigationTitle(controller.selection?.model.displayName ?? "选择模型")
        .molaSubtitle(hasTitle ? controller.conversation.title : nil)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu { modelMenu }
        .toolbar {
            if let openDrawer {
                ToolbarItem(placement: .topBarLeading) {
                    Button { openDrawer() } label: { Label("对话列表", systemImage: "line.3.horizontal") }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { app.newConversation() } label: { Label("新对话", systemImage: "square.and.pencil") }
                    .disabled(controller.messages.isEmpty && !controller.isStreaming)
                conversationMenu
            }
        }
        .alert("重命名对话", isPresented: $renaming) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { app.rename(controller.conversation.sessionId, renameText) }
        }
        .confirmationDialog("删除这个对话？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除对话", role: .destructive) { app.delete([controller.conversation.sessionId]) }
        } message: { Text("此操作无法撤销。") }
    }

    @ViewBuilder
    private var modelMenu: some View {
        ForEach(app.modelGroups, id: \.provider.id) { group in
            Section(group.provider.name) {
                ForEach(group.models) { m in
                    Button {
                        controller.selectModel(group.provider, m)
                    } label: {
                        let isSelected = controller.selection?.provider.id == group.provider.id && controller.selection?.model.id == m.id
                        Label {
                            Text(m.displayName)
                            Text(capabilities(m, baseUrl: group.provider.baseUrl))
                        } icon: {
                            if isSelected { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
        Section {
            Button { app.openSettings(.providers) } label: { Label("管理模型服务…", systemImage: "slider.horizontal.3") }
        }
    }

    private func capabilities(_ m: ProviderModel, baseUrl: String) -> String {
        var parts: [String] = []
        if m.effectiveThinking(baseUrl: baseUrl) != nil { parts.append("推理") }
        if m.supportsVision { parts.append("视觉") }
        if let p = m.pricing { parts.append("$\(compact(p.input)) / $\(compact(p.output))") }
        return parts.joined(separator: " · ")
    }

    private func compact(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }

    private var conversationMenu: some View {
        Menu {
            if !controller.isOfficial {
                Menu {
                    RoleMenuItems(controller: controller)
                } label: {
                    Label("角色：\(controller.chosenRole?.name ?? "无")", systemImage: "person.crop.circle")
                }
            }
            Button { app.showImageWorkbench = true } label: { Label("画图工作台", systemImage: "paintbrush") }
            if app.settings.byokMemoryMasterEnabled && !(controller.persona?.isRolePlay ?? false) {
                let eff = app.memory.effective(controller)
                Section("记忆") {
                    Toggle(isOn: Binding(get: { eff.memory }, set: { app.memory.setConversation(controller, memory: $0, recall: eff.recall) })) {
                        Label("本对话使用记忆", systemImage: "brain")
                    }
                    Toggle(isOn: Binding(get: { eff.recall }, set: { app.memory.setConversation(controller, memory: eff.memory, recall: $0) })) {
                        Label("回忆历史对话", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            if !controller.messages.isEmpty {
                Section {
                    Button { renameText = controller.conversation.title; renaming = true } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button { app.togglePin(controller.conversation.sessionId) } label: {
                        Label(controller.conversation.pinned ? "取消置顶" : "置顶",
                              systemImage: controller.conversation.pinned ? "pin.slash" : "pin")
                    }
                    ShareLink(item: controller.shareText()) {
                        Label("分享对话", systemImage: "square.and.arrow.up")
                    }
                    if let cost = controller.totalCost {
                        Text("本对话花费 \(ModelPricing.format(cost))")
                    }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除对话", systemImage: "trash") }
                }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }
}

/// 空白对话（ContentUnavailableView）。
struct EmptyChatView: View {
    @Environment(AppModel.self) private var app
    let controller: ChatController

    var body: some View {
        if app.modelGroups.isEmpty && app.account.isLoggedIn {
            // 已登录 MolaGPT 账户但官方模型列表还没拿到（首次启动无缓存）：显示加载，不要引导去添加服务
            ProgressView("正在加载 MolaGPT 模型…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await app.account.refreshModels() }
        } else if app.modelGroups.isEmpty {
            ContentUnavailableView {
                Label("添加模型服务", systemImage: "cpu")
            } description: {
                Text("支持 OpenAI 兼容、OpenAI Responses、Anthropic、Gemini。API Key 只保存在本机钥匙串。")
            } actions: {
                Button("添加模型服务") { app.openSettings(.providers) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 12) {
                if let role = controller.chosenRole {
                    PersonaAvatar(persona: role, size: 64)
                    Text(role.name).font(.title2.weight(.semibold))
                    if role.isRolePlay, let preview = role.preview.nonBlank {
                        Text(preview).font(.subheadline).foregroundStyle(MolaColor.secondaryLabel)
                            .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 32)
                    }
                } else {
                    // 不使用角色：与安卓 PersonaWelcome 一致的通用欢迎
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(MolaColor.accent.gradient, in: Circle())
                    Text("有什么可以帮助您？").font(.title2.weight(.semibold))
                }
                // 角色只作用于自行接入的模型
                if !controller.isOfficial {
                    Menu {
                        RoleMenuItems(controller: controller)
                    } label: {
                        HStack(spacing: 4) {
                            Text(controller.chosenRole == nil ? "选择角色（可选）" : "切换角色")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
        }
    }
}

/// 消息列表：自动跟随到底部；用户上滑后出现「回到底部」玻璃按钮。
struct MessageListView: View {
    @Environment(AppModel.self) private var app
    let controller: ChatController
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    let markers = app.compaction.markers(controller.conversation.sessionId)
                    ForEach(controller.messages) { m in
                        MessageRow(message: m, controller: controller).id(m.messageId)
                        if let cp = markers[m.messageId] { CompactionMarker(checkpoint: cp) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(DragGesture().onChanged { v in
                if v.translation.height > 24 { follow = false }
            })
            .onChange(of: controller.messages.count) { _, _ in
                follow = true
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: controller.messages.last?.fragments) { _, _ in
                if follow && controller.isStreaming { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: controller.conversation.sessionId) { _, _ in
                follow = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !follow {
                    Button {
                        follow = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .molaGlass(in: Circle(), interactive: true)
                    .padding(.bottom, 8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: follow)
        }
    }
}

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// 角色菜单内容（对话「…」菜单、空对话欢迎页、安卓风格输入栏共用）：「无角色」+ 角色列表 + 管理入口。
/// 「通用助手」即不使用角色时的默认回答方式，不单独列出。
struct RoleMenuItems: View {
    @Environment(AppModel.self) private var app
    let controller: ChatController

    var body: some View {
        let current = controller.chosenRole?.id
        Button { controller.selectPersona(nil) } label: {
            Label("无角色", systemImage: current == nil ? "checkmark" : "circle.slash")
        }
        Section {
            ForEach(app.personas.filter { $0.id != Persona.builtinDefaultId }) { p in
                Button { controller.selectPersona(p) } label: {
                    Label(p.name, systemImage: current == p.id ? "checkmark" : (p.isRolePlay ? "theatermasks" : p.symbolName))
                }
            }
        }
        Button("管理角色", systemImage: "gearshape") { app.openSettings(.personas) }
    }
}
