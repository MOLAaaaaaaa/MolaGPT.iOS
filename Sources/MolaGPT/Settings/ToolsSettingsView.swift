import SwiftUI
import MolaCore
import MolaStorage

/// 选择 `providerId::modelId` 的 Picker（按服务分组）。
struct ModelKeyPicker: View {
    @Environment(AppModel.self) private var app
    let title: String
    @Binding var selection: String?
    var noneLabel = "自动"
    var filter: (ByokProvider, ProviderModel) -> Bool = { _, _ in true }
    var includeImageProviders = false

    var body: some View {
        Picker(title, selection: Binding(get: { selection ?? "" }, set: { selection = $0.isEmpty ? nil : $0 })) {
            Text(noneLabel).tag("")
            ForEach(groups, id: \.0.id) { p, models in
                Section(p.name) {
                    ForEach(models) { m in Text(m.displayName).tag(ModelKey(providerId: p.id, modelId: m.id).description) }
                }
            }
        }
    }

    private var groups: [(ByokProvider, [ProviderModel])] {
        app.providers.filter { $0.enabled && (includeImageProviders || $0.purpose == .chat) }
            .map { p in (p, p.models.filter { $0.enabled && filter(p, $0) }) }
            .filter { !$0.1.isEmpty }
    }
}

struct ToolsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var searchKey = ""

    private var loggedIn: Bool { app.account.isLoggedIn }
    /// 生效的搜索服务（选 MolaGPT 但未登录时为 DuckDuckGo）。
    private var provider: WebSearchProvider { app.settings.effectiveSearchProvider(loggedIn: loggedIn) }

    private var searchFooter: String {
        if app.settings.webSearchProviderChoice == .molagpt && !loggedIn {
            return "MolaGPT 搜索登录后可用，未登录期间改用 DuckDuckGo。"
        }
        if provider == .molagpt {
            return "MolaGPT 提供的开箱即用的搜索服务，无需 API Key，将使用少量账户额度。在输入框的 + 菜单里开启「联网搜索」后生效，需要模型支持工具调用。"
        }
        return "在输入框的 + 菜单里开启「联网搜索」后生效，需要模型支持工具调用。DuckDuckGo 无需密钥，但可能被限流。"
    }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("搜索服务", selection: $app.settings.webSearchProviderChoice) {
                    Text("默认（\(loggedIn ? "MolaGPT" : "DuckDuckGo")）").tag(WebSearchProvider?.none)
                    ForEach(WebSearchProvider.allCases, id: \.self) { p in
                        Text(p == .molagpt && !loggedIn ? "\(p.label)（需登录）" : p.label).tag(Optional(p))
                    }
                }
                if provider.needsKey {
                    SecureField("\(provider.label) API Key", text: $searchKey)
                        .textContentType(.password)
                        .onChange(of: searchKey) { _, v in
                            Keychain.set(Keychain.Key.webSearchKey(provider.rawValue), v.nonBlank)
                        }
                }
                Stepper(value: $app.settings.webSearchMaxResults, in: 1...provider.maxLimit) {
                    LabeledContent("每次结果数", value: "\(min(app.settings.webSearchMaxResults, provider.maxLimit))")
                }
                Toggle("允许阅读网页", isOn: $app.settings.webFetchEnabled)
            } header: { Text("联网") } footer: {
                Text(searchFooter)
            }

            Section {
                Toggle("外挂视觉", isOn: $app.settings.visionProxyEnabled)
                if app.settings.visionProxyEnabled {
                    ModelKeyPicker(title: "视觉模型", selection: $app.settings.visionProxyModelKey, noneLabel: "同服务的视觉模型",
                                   filter: { _, m in m.supportsVision })
                }
            } header: { Text("视觉理解") } footer: {
                Text("当前模型看不到图片时，图片会交给视觉模型描述，再把结果交回当前模型。")
            }

            Section {
                Toggle("图像生成", isOn: $app.settings.imageGenEnabled)
                if app.settings.imageGenEnabled {
                    ModelKeyPicker(title: "图像模型", selection: $app.settings.imageGenModelKey, noneLabel: "自动选择",
                                   filter: { _, m in m.supportsImageGeneration }, includeImageProviders: true)
                    Picker("尺寸", selection: $app.settings.imageGenConfig.imageSize) {
                        ForEach(ImageGenConfig.sizes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("宽高比", selection: $app.settings.imageGenConfig.aspectRatio) {
                        ForEach(ImageGenConfig.aspectRatios, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("推理（OpenRouter）", isOn: $app.settings.imageGenConfig.reasoning)
                    if app.settings.imageGenConfig.reasoning {
                        Picker("推理强度", selection: $app.settings.imageGenConfig.reasoningEffort) {
                            ForEach(ImageGenConfig.efforts, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            } header: { Text("图像生成") } footer: {
                Text("在模型编辑页把模型标记为「图像生成」。对话中模型会调用 generate_image 工具，生成的图片保存在本机。")
            }

            Section {
                Toggle("MCP 服务器", isOn: $app.settings.mcpEnabled)
                NavigationLink(value: SettingsRoute.mcpServers) {
                    LabeledContent("服务器", value: app.settings.mcpServers.isEmpty ? "未添加" : "\(app.settings.mcpServers.filter(\.enabled).count) 个")
                }
            } header: { Text("MCP") } footer: {
                Text("连接远程 MCP（Streamable HTTP）服务器，模型可以列出并调用其中的工具。")
            }

            Section {
                Toggle("可视化回答", isOn: $app.settings.visualAnswersEnabled)
                Toggle("网页默认显示为卡片", isOn: $app.settings.htmlAsCard)
                NavigationLink(value: SettingsRoute.postProcessing) {
                    LabeledContent("回答后处理", value: app.settings.responsePostProcessingEnabled ? "开" : "关")
                }
            } header: { Text("回答") } footer: {
                Text("可视化回答让模型输出图表、函数图像、表格与可运行的网页。")
            }
        }
        .navigationTitle("工具")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadKey() }
        .onChange(of: app.settings.webSearchProviderChoice) { _, _ in loadKey() }
    }

    private func loadKey() {
        searchKey = Keychain.get(Keychain.Key.webSearchKey(provider.rawValue)) ?? ""
    }
}

// MARK: - MCP

struct McpServersView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        List {
            if app.settings.mcpServers.isEmpty {
                ContentUnavailableView("没有 MCP 服务器", systemImage: "puzzlepiece.extension",
                                       description: Text("点右上角 + 添加远程 MCP 服务器。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(app.settings.mcpServers) { s in
                NavigationLink(value: SettingsRoute.mcpServer(s.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(s.endpoint).font(.caption).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1)
                    }
                    .opacity(s.enabled ? 1 : 0.5)
                }
                .swipeActions(edge: .leading) {
                    Button(s.enabled ? "停用" : "启用") {
                        var c = s; c.token = Keychain.get(Keychain.Key.mcpToken(s.id)); c.enabled.toggle(); app.saveMcpServer(c)
                    }
                    .tint(s.enabled ? .gray : .green)
                }
            }
            .onDelete { idx in idx.map { app.settings.mcpServers[$0].id }.forEach(app.deleteMcpServer) }
        }
        .navigationTitle("MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("添加", systemImage: "plus") { adding = true } } }
        .sheet(isPresented: $adding) { McpServerForm(server: McpServer(name: "", endpoint: "https://")) }
    }
}

/// 新建 / 编辑服务器表单（sheet）。
struct McpServerForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var server: McpServer
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $server.name)
                    TextField("地址（https://…/mcp）", text: $server.endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    SecureField("Token（可选）", text: $token)
                    TextField("请求头名称", text: $server.headerName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("鉴权") } footer: { Text("Token 以「Bearer <token>」发送，只保存在本机钥匙串。") }
                Section {
                    Button { test() } label: {
                        HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } }
                    }
                    .disabled(testing || URL(string: server.endpoint)?.host == nil)
                    if let result { Text(result).font(.footnote).foregroundStyle(MolaColor.secondaryLabel) }
                }
            }
            .navigationTitle(server.name.isEmpty ? "添加服务器" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(); dismiss() }
                        .disabled(server.name.nonBlank == nil || URL(string: server.endpoint)?.host == nil)
                }
            }
            .onAppear { token = Keychain.get(Keychain.Key.mcpToken(server.id)) ?? "" }
        }
    }

    private func save() {
        var s = server
        s.token = token.nonBlank
        app.saveMcpServer(s)
    }

    private func test() {
        testing = true; result = nil
        var s = server; s.token = token.nonBlank
        let client = app.mcp
        Task {
            await client.reset(s.id)
            do {
                let tools = try await client.listTools(s)
                result = "连接成功，发现 \(tools.count) 个工具"
            } catch {
                result = "连接失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }
}

struct McpServerDetailView: View {
    @Environment(AppModel.self) private var app
    let serverId: String
    @State private var tools: [McpToolInfo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editing = false

    private var server: McpServer? { app.mcpServersWithTokens.first { $0.id == serverId } }

    var body: some View {
        Form {
            if let server {
                Section {
                    Toggle("启用", isOn: Binding(get: { server.enabled }, set: { var s = server; s.enabled = $0; app.saveMcpServer(s) }))
                    LabeledContent("地址") { Text(server.endpoint).lineLimit(1).truncationMode(.middle) }
                }
                Section {
                    if loading { HStack { ProgressView(); Text("正在获取工具…").foregroundStyle(MolaColor.secondaryLabel) } }
                    else if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    else if tools.isEmpty { Text("服务器没有提供工具").foregroundStyle(MolaColor.secondaryLabel) }
                    ForEach(tools) { t in
                        DisclosureGroup {
                            if let d = t.description { Text(d).font(.footnote) }
                            if let schema = t.inputSchema {
                                Text(schema.jsonString(sorted: true)).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        } label: {
                            Toggle(isOn: Binding(get: { !server.disabledTools.contains(t.name) }, set: { on in
                                var s = server
                                if on { s.disabledTools.removeAll { $0 == t.name } } else { s.disabledTools.append(t.name) }
                                app.saveMcpServer(s)
                            })) {
                                Text(t.name).font(.body.monospaced())
                            }
                        }
                    }
                } header: { Text("工具") } footer: { Text("关闭的工具不会出现在列表里，模型也无法调用。") }
            }
        }
        .navigationTitle(server?.name ?? "服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("编辑") { editing = true } } }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let server { McpServerForm(server: server) }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let server else { return }
        loading = true; error = nil
        do { tools = try await app.mcp.listTools(server) } catch { self.error = "获取失败：\(error.localizedDescription)" }
        loading = false
    }
}

// MARK: - 回答后处理

struct PostProcessingView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: ResponseRegexRule?

    var body: some View {
        @Bindable var app = app
        let preview = ResponsePostProcessor.apply(ResponsePostProcessor.previewSample, rules: app.settings.responseRegexRules)
        Form {
            Section {
                Toggle("回答后处理", isOn: $app.settings.responsePostProcessingEnabled)
            } footer: { Text("回答生成完毕后按顺序应用下面的正则替换；代码块、行内代码与公式不受影响。") }
            Section("规则") {
                ForEach($app.settings.responseRegexRules) { $rule in
                    Button { editing = rule } label: {
                        Toggle(isOn: $rule.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).foregroundStyle(MolaColor.label)
                                Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(MolaColor.secondaryLabel).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { app.settings.responseRegexRules.remove(atOffsets: $0) }
                .onMove { app.settings.responseRegexRules.move(fromOffsets: $0, toOffset: $1) }
                Button("添加规则", systemImage: "plus") { editing = ResponseRegexRule(name: "", pattern: "", replacement: "") }
            }
            Section {
                Text(ResponsePostProcessor.previewSample).font(.footnote.monospaced()).foregroundStyle(MolaColor.secondaryLabel)
                Text(preview.text).font(.footnote.monospaced())
            } header: { Text("预览") } footer: { Text(preview.replacements > 0 ? "已替换 \(preview.replacements) 处" : "无替换") }
            Section {
                Button("恢复默认规则", role: .destructive) { app.settings.responseRegexRules = ResponseRegexRule.builtins }
            }
        }
        .navigationTitle("回答后处理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { rule in
            RegexRuleForm(rule: rule) { saved in
                if let i = app.settings.responseRegexRules.firstIndex(where: { $0.id == saved.id }) { app.settings.responseRegexRules[i] = saved }
                else { app.settings.responseRegexRules.append(saved) }
            }
        }
    }
}

struct RegexRuleForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: ResponseRegexRule
    let onSave: (ResponseRegexRule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("名称", text: $rule.name) }
                Section {
                    TextField("正则表达式", text: $rule.pattern, axis: .vertical).font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("替换为（$1 引用分组）", text: $rule.replacement, axis: .vertical).font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    if let e = rule.validate(), !rule.pattern.isEmpty { Text(e).foregroundStyle(.red) }
                }
                if !rule.pattern.isEmpty, rule.validate() == nil {
                    Section("预览") {
                        Text(ResponsePostProcessor.apply(ResponsePostProcessor.previewSample, rules: [rule]).text).font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle(rule.name.isEmpty ? "新规则" : rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(rule); dismiss() }.disabled(rule.name.nonBlank == nil || rule.validate() != nil)
                }
            }
        }
    }
}
