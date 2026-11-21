import SwiftUI
import MolaStorage
import MolaCore

/// 设置页内的路由（设置以模态 sheet 呈现，自带 NavigationStack）。
enum SettingsRoute: Hashable {
    case providers
    case provider(String)
    case model(providerId: String, modelId: String)
    case chat
    case about
    case tools
    case mcpServers
    case mcpServer(String)
    case postProcessing
    case memory
    case skills
    case skill(String)
    case personas
    case persona(String)
    case lorebooks
    case lorebook(String)
    case account
    case personalization
    case context
    case notifications
    case agents
    case desktops
}

/// 根结构：NavigationSplitView。
/// iPhone 上折叠为「对话列表 ⇄ 聊天」的原生推入导航（启动直接进聊天，左滑或返回按钮回列表）；
/// iPad / 横屏大屏上为侧栏 + 详情。
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var columns: NavigationSplitViewVisibility = .automatic
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        Group {
            // 安卓风格在 iPhone 上用侧滑抽屉；iPad 仍是侧栏 + 详情。
            if app.settings.uiStyle == .android && sizeClass == .compact {
                DrawerRootView()
            } else {
                NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
                    ConversationListView(openChat: { compactColumn = .detail })
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
                } detail: {
                    NavigationStack {
                        ChatView(controller: app.current)
                    }
                }
            }
        }
        .sheet(isPresented: $app.showSettings) {
            SettingsSheet()
                .environment(app)
                .tint(MolaColor.accent)
                .preferredColorScheme(app.colorScheme)
                .environment(\.uiStyle, app.settings.uiStyle)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.didBecomeActive() }
            if phase != .active { ContinuedWork.shared.appWillLeaveForeground() }
            if phase == .background { app.didEnterBackground() }
        }
        .onChange(of: app.chatFocusToken) {
            compactColumn = .detail
        }
        // 启动即申请权限（界面出现后才能弹系统对话框）
        .task { await LaunchPermissions.requestAll() }
        .sheet(item: $app.pendingNotice) { OpsMessageSheet(message: $0) }
        .fullScreenCover(isPresented: $app.showImageWorkbench) { ImageWorkbenchView().environment(app) }
        .overlay(alignment: .top) {
            if let err = app.startupError {
                Text(err).font(.footnote).padding(8).frame(maxWidth: .infinity)
                    .background(.red.opacity(0.9)).foregroundStyle(.white)
            }
        }
    }
}

/// 安卓风格的会话抽屉：从左缘拖出（或点左上角按钮），聊天页随之右移 25%（视差），点遮罩或左滑关闭。
struct DrawerRootView: View {
    @Environment(AppModel.self) private var app
    @State private var open = false
    @State private var dragX: CGFloat = 0
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.85, 360)
            let base: CGFloat = open ? 1 : 0
            let progress = min(max(base + dragX / width, 0), 1)
            ZStack(alignment: .leading) {
                NavigationStack { ChatView(controller: app.current) }
                    .environment(\.openDrawer, { setOpen(true) })
                    .offset(x: progress * width * 0.25)
                    .overlay {
                        Color.black.opacity(0.32 * progress).ignoresSafeArea()
                            .allowsHitTesting(progress > 0.01)
                            .onTapGesture { setOpen(false) }
                    }
                NavigationStack { ConversationListView(openChat: { setOpen(false) }) }
                    .frame(width: width)
                    .background(MolaColor.background)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 20, topTrailingRadius: 20))
                    .shadow(color: .black.opacity(0.18 * progress), radius: 12)
                    .offset(x: -width + progress * width)
                    .accessibilityHidden(progress < 0.5)
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        if !open && !dragging && v.startLocation.x > 32 { return }
                        dragging = true
                        dragX = v.translation.width
                    }
                    .onEnded { v in
                        guard dragging else { return }
                        dragging = false
                        let predicted = (open ? 1 : 0) + v.predictedEndTranslation.width / width
                        dragX = 0
                        setOpen(predicted > 0.5)
                    }
            )
        }
        .sensoryFeedback(.selection, trigger: open)
    }

    private func setOpen(_ v: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { open = v; dragX = 0 }
    }
}

private struct OpenDrawerKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    /// 安卓风格下打开会话抽屉；为 nil 时（原生 / Claude 风格）由导航返回按钮处理。
    var openDrawer: (@MainActor () -> Void)? {
        get { self[OpenDrawerKey.self] }
        set { self[OpenDrawerKey.self] = newValue }
    }
}
