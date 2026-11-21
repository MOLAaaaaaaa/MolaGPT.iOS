import SwiftUI
import MolaCore
import MolaStorage

/// 设置以模态 sheet 呈现，自带导航栈和「完成」按钮。
struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.settingsPath) {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }.fontWeight(.semibold)
                    }
                }
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .providers: ProvidersView()
                    case .provider(let id): ProviderDetailView(providerId: id)
                    case .model(let pid, let mid): ModelEditView(providerId: pid, modelId: mid)
                    case .chat: ChatSettingsView()
                    case .about: AboutView()
                    case .tools: ToolsSettingsView()
                    case .mcpServers: McpServersView()
                    case .mcpServer(let id): McpServerDetailView(serverId: id)
                    case .postProcessing: PostProcessingView()
                    case .memory: MemorySettingsView()
                    case .skills: SkillsView()
                    case .skill(let id): SkillDetailView(skillId: id)
                    case .personas: PersonasView()
                    case .persona(let id): PersonaRouteView(personaId: id)
                    case .lorebooks: LorebooksView()
                    case .lorebook(let id): LorebookEditView(bookId: id)
                    case .account: AccountView()
                    case .personalization: PersonalizationView()
                    case .agents: AgentSessionsView()
                    case .desktops: DesktopsView()
                    default: SettingsPlaceholder(route: route)
                    }
                }
        }
    }
}

/// 设置首页（系统「设置」风格：inset grouped + 彩色图标）。
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                NavigationLink(value: SettingsRoute.account) {
                    HStack(spacing: 12) {
                        Image(systemName: app.account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.system(size: 40)).foregroundStyle(MolaColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.account.isLoggedIn ? (app.account.username ?? "MolaGPT 账户") : "登录 MolaGPT").font(.headline)
                            Text(app.account.isLoggedIn ? "额度、云同步与个性化" : "使用官方模型、同步对话").font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                NavigationLink(value: SettingsRoute.providers) {
                    LabeledContent {
                        Text(providerSummary)
                    } label: {
                        SettingsLabel("模型服务", symbol: "cpu", color: .indigo)
                    }
                }
                NavigationLink(value: SettingsRoute.chat) {
                    SettingsLabel("对话", symbol: "bubble.left.and.text.bubble.right.fill", color: .green)
                }
                NavigationLink(value: SettingsRoute.personas) {
                    LabeledContent {
                        Text("\(app.personas.count) 个")
                    } label: {
                        SettingsLabel("角色", symbol: "theatermasks.fill", color: .brown)
                    }
                }
                NavigationLink(value: SettingsRoute.tools) {
                    SettingsLabel("工具", symbol: "wrench.and.screwdriver.fill", color: .orange)
                }
                NavigationLink(value: SettingsRoute.skills) {
                    LabeledContent {
                        Text(app.skills.skills.isEmpty ? "" : "\(app.skills.enabledSkills.count) 个")
                    } label: {
                        SettingsLabel("技能", symbol: "book.closed.fill", color: .teal)
                    }
                }
                NavigationLink(value: SettingsRoute.desktops) {
                    SettingsLabel("电脑", symbol: "desktopcomputer", color: .blue)
                }
                NavigationLink(value: SettingsRoute.agents) {
                    SettingsLabel("远程 Agent", symbol: "terminal.fill", color: .gray)
                }
                NavigationLink(value: SettingsRoute.memory) {
                    LabeledContent {
                        Text(app.settings.byokMemoryMasterEnabled ? "开" : "关")
                    } label: {
                        SettingsLabel("记忆", symbol: "brain.head.profile", color: .purple)
                    }
                }
            } footer: {
                Text("接入 OpenAI 兼容、OpenAI Responses、Anthropic、Gemini 等自定义模型服务。")
            }

            Section {
                Picker(selection: $app.settings.themeMode) {
                    ForEach(ThemeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    SettingsLabel("外观", symbol: "circle.lefthalf.filled", color: .blue)
                }
                Picker(selection: $app.settings.uiStyle) {
                    ForEach(UIStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    SettingsLabel("界面风格", symbol: "paintpalette.fill", color: .pink)
                }
                Toggle(isOn: $app.settings.enterToSend) {
                    SettingsLabel("按换行键发送", symbol: "return", color: .gray)
                }
                Picker(selection: $app.settings.linkOpenMode) {
                    ForEach(LinkOpenMode.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    SettingsLabel("打开链接", symbol: "safari.fill", color: .blue)
                }
            } footer: {
                Text("界面风格决定输入栏、工具调用与引用的样式。关闭「按换行键发送」时，换行键插入新行，点发送按钮发送。「App 内浏览器」在当前页面上打开链接，可随时用右上角按钮转到 Safari。")
            }

            Section {
                NavigationLink(value: SettingsRoute.about) {
                    SettingsLabel("关于 MolaGPT", symbol: "info", color: MolaColor.accent)
                }
                Link(destination: URL(string: "https://github.com/MOLAaaaaaaa/MolaGPT.Mobile")!) {
                    HStack {
                        SettingsLabel("开源仓库", symbol: "chevron.left.forwardslash.chevron.right", color: .black)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(MolaColor.tertiaryLabel)
                    }
                }
                .foregroundStyle(MolaColor.label)
            }
        }
        .navigationTitle("设置")
    }

    private var providerSummary: String {
        let n = app.providers.filter(\.enabled).count
        return n == 0 ? "未添加" : "\(n) 个"
    }
}

struct ChatSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                LabeledContent("称呼") {
                    TextField("用户", text: $app.settings.username).multilineTextAlignment(.trailing)
                }
                Picker("新对话角色", selection: $app.settings.defaultPersonaId) {
                    Text("无").tag("")
                    ForEach(app.personas.filter { $0.id != Persona.builtinDefaultId }) {
                        Label($0.name, systemImage: $0.isRolePlay ? "theatermasks" : $0.symbolName).tag($0.id)
                    }
                }
            } header: { Text("角色") } footer: {
                Text("角色是可选的，只作用于自行接入的模型（MolaGPT 官方模型由服务端设定）。不使用角色时按通用助手回答。称呼会替换系统提示词中的 {{user}}。")
            }

            Section {
                LabeledContent {
                    Text(app.settings.temperature, format: .number.precision(.fractionLength(1))).monospacedDigit()
                } label: {
                    Text("温度")
                }
                Slider(value: $app.settings.temperature, in: 0...2, step: 0.1) {
                    Text("温度")
                } minimumValueLabel: { Text("精确").font(.caption) } maximumValueLabel: { Text("发散").font(.caption) }
            } header: { Text("生成") } footer: {
                Text("开启推理的 Claude 模型与 Gemini 3/4 会使用服务端默认采样。")
            }

            Section {
                Toggle("回答完成通知", isOn: $app.settings.completionNotifications)
                    .onChange(of: app.settings.completionNotifications) { _, on in if on { app.notifier.requestAuthorization() } }
                Toggle("实时活动", isOn: $app.settings.liveActivities)
                    .onChange(of: app.settings.liveActivities) { _, on in LiveActivityCenter.shared.enabled = on }
            } footer: {
                Text("切到后台或正在看别的对话时，回答完成会发送通知。实时活动会在灵动岛和锁屏上显示生成进度，点按回到对应对话。切到后台后约 30 秒内会继续生成。")
            }

            Section {
                Toggle("自动生成标题", isOn: $app.settings.autoTitleEnabled)
                if app.settings.autoTitleEnabled {
                    Picker("标题模型", selection: Binding(get: { app.settings.titleModelKey ?? "" },
                                                        set: { app.settings.titleModelKey = $0.isEmpty ? nil : $0 })) {
                        Text("与对话相同").tag("")
                        ForEach(app.modelGroups, id: \.provider.id) { g in
                            Section(g.provider.name) {
                                ForEach(g.models) { m in
                                    Text(m.displayName).tag(ModelKey(providerId: g.provider.id, modelId: m.id).description)
                                }
                            }
                        }
                    }
                }
            } header: { Text("标题") } footer: {
                Text("首轮回答完成后生成。失败时使用第一条消息作为标题。")
            }
        }
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        Form {
            Section {
                VStack(spacing: 8) {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon).resizable().frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        Image(systemName: "fish.fill").font(.system(size: 56)).foregroundStyle(MolaColor.accent)
                    }
                    Text("MolaGPT").font(.title2.weight(.bold))
                    Text("版本 \(version)（\(build)）").font(.subheadline).foregroundStyle(MolaColor.secondaryLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section {
                Link("MolaGPT 网页版", destination: URL(string: "https://chatgpt.wljay.cn/v2")!)
                Link("MolaGPT 桌面版", destination: URL(string: "https://github.com/MOLAaaaaaaa/MolaGPT.Desktop")!)
                Link("LINUX DO 论坛", destination: URL(string: "https://linux.do/")!)
            }
            Section {
                Label("自定义服务的 API Key 只保存在本机钥匙串，不会上传。", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 尚未接入的路由占位（逐步替换为正式页面）。
struct SettingsPlaceholder: View {
    let route: SettingsRoute
    var body: some View {
        ContentUnavailableView("即将推出", systemImage: "hammer", description: Text(String(describing: route)))
    }
}
