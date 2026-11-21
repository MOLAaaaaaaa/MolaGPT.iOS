import SwiftUI
import MolaCore

/// 模型服务列表。添加走 sheet（预设 / 自定义），添加后直接推入详情。
struct ProvidersView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var pushed: String?

    var body: some View {
        List {
            if app.providers.isEmpty {
                ContentUnavailableView {
                    Label("没有模型服务", systemImage: "cpu")
                } description: {
                    Text("从预设添加，或接入任意 OpenAI 兼容服务。")
                } actions: {
                    Button("添加服务") { showAdd = true }.buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(app.providers) { p in
                NavigationLink(value: SettingsRoute.provider(p.id)) {
                    HStack(spacing: 12) {
                        ProviderIcon(type: p.type)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundStyle(p.enabled ? MolaColor.label : MolaColor.secondaryLabel)
                            Text(status(p)).font(.footnote)
                                .foregroundStyle(p.apiKey?.nonBlank == nil && p.type != .openAICompat ? .red : MolaColor.secondaryLabel)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { app.deleteProvider(p.id) } label: { Label("删除", systemImage: "trash") }
                }
            }
            if !app.providers.isEmpty { PricingFetchSection() }
        }
        .navigationTitle("模型服务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("添加", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProviderSheet { preset in
                pushed = app.addProvider(from: preset).id
            }
        }
        .navigationDestination(item: $pushed) { ProviderDetailView(providerId: $0) }
    }

    private func status(_ p: ByokProvider) -> String {
        var parts: [String] = []
        if !p.enabled { parts.append("已停用") }
        if p.apiKey?.nonBlank == nil && p.type != .openAICompat { parts.append("未设置 API Key") }
        parts.append("\(p.models.filter(\.enabled).count) 个模型")
        return parts.joined(separator: " · ")
    }
}

struct ProviderIcon: View {
    let type: ByokProviderType
    var body: some View {
        switch type {
        case .openAICompat: SettingsIcon(symbol: "bolt.horizontal.fill", color: .teal)
        case .openAIResponse: SettingsIcon(symbol: "arrow.triangle.branch", color: .mint)
        case .anthropic: SettingsIcon(symbol: "asterisk", color: .orange)
        case .gemini: SettingsIcon(symbol: "sparkle", color: .blue)
        }
    }
}

struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (ByokProviderPresets.Preset?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { pick(nil) } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "plus", color: .gray)
                            VStack(alignment: .leading) {
                                Text("自定义服务").foregroundStyle(MolaColor.label)
                                Text("任意 OpenAI 兼容接口").font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                            }
                        }
                    }
                }
                Section("预设") {
                    ForEach(ByokProviderPresets.all) { preset in
                        Button { pick(preset) } label: {
                            HStack(spacing: 12) {
                                ProviderIcon(type: preset.type)
                                VStack(alignment: .leading) {
                                    Text(preset.name).foregroundStyle(MolaColor.label)
                                    Text(URL(string: preset.baseUrl)?.host ?? preset.baseUrl)
                                        .font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func pick(_ p: ByokProviderPresets.Preset?) {
        dismiss()
        onAdd(p)
    }
}

/// 服务详情。修改即时保存。
struct ProviderDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let providerId: String

    @State private var draft: ByokProvider?
    @State private var showKey = false
    @State private var fetching = false
    @State private var fetched: FetchedList?
    @State private var message: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var addingModel = false
    @State private var newModelId = ""
    @State private var confirmDelete = false
    @State private var feedback = 0

    struct FetchedList: Identifiable { let id = UUID(); let models: [ProviderModel] }

    var body: some View {
        Group {
            if let binding = Binding($draft) { form(binding) } else { ProgressView() }
        }
        .navigationTitle(draft?.name ?? "模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if draft == nil { draft = app.provider(providerId) } }
        .onChange(of: draft) { _, new in if let new { app.saveProvider(new) } }
        .sensoryFeedback(message?.ok == false ? .error : .success, trigger: feedback)
        .sheet(item: $fetched) { list in
            FetchModelsSheet(models: list.models, existing: Set(draft?.models.map(\.id) ?? []), onAdd: merge)
        }
        .alert("添加模型", isPresented: $addingModel) {
            TextField("模型 ID，例如 gpt-4o", text: $newModelId)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { newModelId = "" }
            Button("添加") {
                if let id = newModelId.nonBlank, var d = draft, d.model(id) == nil {
                    d.models.append(ModelListAPI.inferredModel(id: id, baseUrl: d.baseUrl))
                    draft = d
                }
                newModelId = ""
            }
        }
        .confirmationDialog("删除「\(draft?.name ?? "")」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除服务", role: .destructive) { app.deleteProvider(providerId); dismiss() }
        } message: { Text("该服务下的模型配置会一并删除。") }
    }

    @ViewBuilder
    private func form(_ p: Binding<ByokProvider>) -> some View {
        Form {
            Section {
                LabeledContent("名称") { TextField("名称", text: p.name).multilineTextAlignment(.trailing) }
                Picker("接口类型", selection: p.type) {
                    ForEach(ByokProviderType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: p.wrappedValue.type) { old, new in
                    if p.wrappedValue.chatPath == old.defaultChatPath { p.wrappedValue.chatPath = new.defaultChatPath }
                    if p.wrappedValue.modelsPath == old.defaultModelsPath { p.wrappedValue.modelsPath = new.defaultModelsPath }
                }
                Toggle("启用", isOn: p.enabled)
            }

            Section {
                TextField("https://api.example.com/", text: p.baseUrl)
                    .keyboardType(.URL).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Group {
                        let key = Binding(get: { p.wrappedValue.apiKey ?? "" }, set: { p.wrappedValue.apiKey = $0 })
                        if showKey { TextField("API Key", text: key) } else { SecureField("API Key", text: key) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless).foregroundStyle(MolaColor.secondaryLabel)
                        .accessibilityLabel(showKey ? "隐藏" : "显示")
                }
            } header: { Text("连接") } footer: {
                Text(p.wrappedValue.endpoint(p.wrappedValue.chatPath)).textSelection(.enabled)
            }

            Section {
                ForEach(p.models) { $m in
                    NavigationLink(value: SettingsRoute.model(providerId: p.wrappedValue.id, modelId: m.id)) {
                        ModelRow(model: m, baseUrl: p.wrappedValue.baseUrl)
                    }
                    .swipeActions(edge: .leading) {
                        Button { m.enabled.toggle() } label: {
                            Label(m.enabled ? "停用" : "启用", systemImage: m.enabled ? "eye.slash" : "eye")
                        }
                        .tint(m.enabled ? .gray : .green)
                    }
                }
                .onDelete { p.wrappedValue.models.remove(atOffsets: $0) }
                Button { Task { await fetchModels() } } label: {
                    HStack {
                        Label("从服务获取模型", systemImage: "arrow.down.circle")
                        Spacer()
                        if fetching { ProgressView() }
                    }
                }
                .disabled(fetching)
                Button { addingModel = true } label: { Label("手动添加模型", systemImage: "plus.circle") }
            } header: {
                Text("模型")
            } footer: {
                Text("向左轻扫删除，向右轻扫启用/停用。")
            }

            Section {
                Button { Task { await test() } } label: {
                    HStack {
                        Label("测试连接", systemImage: "checkmark.seal")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || p.wrappedValue.models.isEmpty)
                if let message {
                    Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(message.ok ? .green : .red)
                        .textSelection(.enabled)
                }
            }

            Section {
                DisclosureGroup("高级") {
                    LabeledContent("对话路径") {
                        TextField("chat path", text: p.chatPath).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                    LabeledContent("模型列表路径") {
                        TextField("models path", text: p.modelsPath).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                    Picker("用途", selection: p.purpose) {
                        Text("对话").tag(ProviderPurpose.chat)
                        Text("图像").tag(ProviderPurpose.image)
                    }
                    Picker("图像接口", selection: p.imageFormat) {
                        ForEach(ImageFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledContent("图像生成路径") {
                        TextField("image path", text: p.imagePath).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                    LabeledContent("图像编辑路径") {
                        TextField("edit path", text: p.imageEditPath).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                    ForEach(p.customHeaders.indices, id: \.self) { i in
                        HStack {
                            TextField("请求头", text: p.customHeaders[i].name)
                            Divider()
                            TextField("值", text: p.customHeaders[i].value)
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                    .onDelete { p.wrappedValue.customHeaders.remove(atOffsets: $0) }
                    Button { p.wrappedValue.customHeaders.append(CustomHeader()) } label: {
                        Label("添加自定义请求头", systemImage: "plus")
                    }
                }
            }

            Section {
                Button("删除服务", role: .destructive) { confirmDelete = true }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func merge(_ chosen: [ProviderModel]) {
        guard var d = draft else { return }
        let existing = Set(d.models.map(\.id))
        d.models.append(contentsOf: chosen.filter { !existing.contains($0.id) })
        for m in chosen where existing.contains(m.id) {
            guard let i = d.models.firstIndex(where: { $0.id == m.id }) else { continue }
            if d.models[i].pricing?.isManual != true, let p = m.pricing { d.models[i].pricing = p }
            if d.models[i].contextWindow == nil { d.models[i].contextWindow = m.contextWindow }
        }
        draft = d
    }

    private func fetchModels() async {
        guard let d = draft else { return }
        fetching = true; defer { fetching = false }
        do {
            let models = try await app.client.fetchModels(d)
            if models.isEmpty { message = (false, "服务返回了空的模型列表"); feedback += 1 }
            else { fetched = FetchedList(models: models) }
        } catch {
            message = (false, "获取失败：\(error.localizedDescription)")
            feedback += 1
        }
    }

    private func test() async {
        guard let d = draft, let m = d.models.first(where: \.enabled) ?? d.models.first else { return }
        testing = true; defer { testing = false }
        message = nil
        let start = Date()
        switch await app.client.testConnection(provider: d, model: m) {
        case .success:
            message = (true, "\(m.displayName) 连接正常，耗时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")
        case .failure(let e):
            message = (false, e.localizedDescription)
        }
        feedback += 1
    }
}

struct ModelRow: View {
    let model: ProviderModel
    let baseUrl: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.displayName).lineLimit(1)
                .foregroundStyle(model.enabled ? MolaColor.label : MolaColor.tertiaryLabel)
            HStack(spacing: 8) {
                if model.effectiveThinking(baseUrl: baseUrl) != nil { Image(systemName: "brain") }
                if model.supportsVision { Image(systemName: "eye") }
                if model.supportsToolCalling { Image(systemName: "wrench.and.screwdriver") }
                if let p = model.pricing {
                    Text("$\(fmt(p.input)) / $\(fmt(p.output))")
                }
                if !model.enabled { Text("已停用") }
            }
            .font(.caption)
            .foregroundStyle(MolaColor.secondaryLabel)
        }
    }

    private func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
}

/// 拉取到的模型多选（原生编辑模式勾选；默认勾选像对话模型的条目）。
struct FetchModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let models: [ProviderModel]
    let existing: Set<String>
    let onAdd: ([ProviderModel]) -> Void

    @State private var selected: Set<String> = []
    @State private var query = ""

    private var filtered: [ProviderModel] {
        guard let q = query.nonBlank?.lowercased() else { return models }
        return models.filter { $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, selection: $selected) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.id).font(.body.monospaced()).lineLimit(1)
                    if existing.contains(m.id) {
                        Text("已添加").font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                    }
                }
                .tag(m.id)
            }
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("已选 \(selected.count) / \(models.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { onAdd(models.filter { selected.contains($0.id) }); dismiss() }
                        .fontWeight(.semibold).disabled(selected.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("全选") { selected.formUnion(filtered.map(\.id)) }
                    Spacer()
                    Button("全不选") { selected.subtract(filtered.map(\.id)) }
                }
            }
        }
        .onAppear {
            selected = Set(models.filter { existing.contains($0.id) || ModelListAPI.looksLikeChat($0.id) }.map(\.id))
        }
    }
}
