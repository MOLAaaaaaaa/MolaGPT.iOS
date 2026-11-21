import SwiftUI
import MolaCore

/// 模型编辑（对应安卓 ModelEditSheet）：能力、推理方式与档位、价格、上下文窗口、请求体覆写。
struct ModelEditView: View {
    @Environment(AppModel.self) private var app
    let providerId: String
    let modelId: String

    @State private var provider: ByokProvider?
    @State private var model: ProviderModel?
    @State private var showPriceCandidates = false

    var body: some View {
        Group {
            if let p = provider, let binding = Binding($model) {
                form(binding, baseUrl: p.baseUrl)
            } else {
                Text("模型不存在").foregroundStyle(MolaColor.secondaryLabel)
            }
        }
        .navigationTitle(model?.displayName ?? modelId)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard provider == nil else { return }
            provider = app.provider(providerId)
            model = provider?.model(modelId)
        }
        .onChange(of: model) { _, new in
            guard var p = provider, let new, let i = p.models.firstIndex(where: { $0.id == new.id }) else { return }
            p.models[i] = new
            provider = p
            app.saveProvider(p)
        }
    }

    @ViewBuilder
    private func form(_ m: Binding<ProviderModel>, baseUrl: String) -> some View {
        let auto = Thinking.autoConfig(modelId: m.wrappedValue.id, baseUrl: baseUrl)
        let current = m.wrappedValue.thinkingConfig
        Form {
            Section("基本") {
                LabeledContent("模型 ID", value: m.wrappedValue.id)
                TextField("显示名称", text: m.displayName)
                Toggle("启用", isOn: m.enabled)
            }
            Section("能力") {
                Toggle("视觉（可发送图片）", isOn: m.supportsVision)
                Toggle("工具调用", isOn: m.supportsToolCalling)
                Toggle("图像生成", isOn: m.supportsImageGeneration)
                if m.wrappedValue.supportsImageGeneration {
                    Toggle("图像编辑（参考图）", isOn: m.supportsImageEdit)
                }
            }
            Section {
                Picker("推理方式", selection: Binding<ThinkingParamKind?>(
                    get: { current?.manualOverride == true || current != nil && current != auto ? current?.kind : nil },
                    set: { kind in
                        if let kind {
                            var c = Thinking.config(for: kind, source: .override)
                            c.manualOverride = true
                            m.wrappedValue.thinkingConfig = c
                            m.wrappedValue.supportsThinking = kind != .none
                        } else {
                            m.wrappedValue.thinkingConfig = auto
                            m.wrappedValue.supportsThinking = auto != nil
                        }
                    })) {
                    Text("自动（\(auto?.kind.label ?? "不推理")）").tag(ThinkingParamKind?.none)
                    ForEach(ThinkingParamKind.allCases, id: \.self) { Text($0.label).tag(ThinkingParamKind?.some($0)) }
                }
                if let cfg = m.wrappedValue.effectiveThinking(baseUrl: baseUrl) {
                    let all = Thinking.effortLevels(for: Thinking.wireKind(cfg.kind, baseUrl: baseUrl))
                    if !all.isEmpty {
                        let levels = Thinking.resolveEffortLevels(cfg, baseUrl: baseUrl)
                        ForEach(all, id: \.self) { level in
                            Toggle(isOn: Binding(get: { levels.contains(level) }, set: { on in
                                var c = cfg
                                var set = Set(levels)
                                if on { set.insert(level) } else if set.count > 1 { set.remove(level) }
                                c.effortLevels = Thinking.fullOrder.filter(set.contains)
                                c.manualOverride = true
                                m.wrappedValue.thinkingConfig = c
                            })) {
                                HStack {
                                    Text(Thinking.effortLabel(level))
                                    if Thinking.isBudgetKind(Thinking.wireKind(cfg.kind, baseUrl: baseUrl)) {
                                        Text("\(Thinking.budget(for: cfg.kind, effort: level)) tokens")
                                            .font(.caption).foregroundStyle(MolaColor.secondaryLabel)
                                    }
                                }
                            }
                        }
                        Picker("默认档位", selection: Binding(get: { Thinking.resolveDefaultEffort(cfg, baseUrl: baseUrl) }, set: {
                            var c = cfg; c.defaultEffort = $0; c.manualOverride = true; m.wrappedValue.thinkingConfig = c
                        })) {
                            ForEach(levels, id: \.self) { Text(Thinking.effortLabel($0)).tag($0) }
                        }
                    }
                    Toggle("始终开启（无法关闭推理）", isOn: Binding(get: { cfg.alwaysOn }, set: {
                        var c = cfg; c.alwaysOn = $0; c.manualOverride = true; m.wrappedValue.thinkingConfig = c
                    }))
                }
            } header: { Text("推理") } footer: {
                Text(thinkingFooter(m.wrappedValue, baseUrl: baseUrl))
            }

            Section {
                OptionalIntField(title: "上下文窗口", value: m.contextWindow, unit: "tokens")
            }

            Section {
                Toggle("设置价格", isOn: Binding(get: { m.wrappedValue.pricing != nil }, set: {
                    m.wrappedValue.pricing = $0 ? ModelPricing(input: 0, output: 0, source: "manual") : nil
                }))
                if m.wrappedValue.pricing != nil {
                    priceField("输入", \.input, m)
                    priceField("输出", \.output, m)
                    optionalPriceField("缓存读取", \.cacheRead, m)
                    optionalPriceField("缓存写入", \.cacheWrite, m)
                }
                Button { showPriceCandidates = true } label: {
                    Label("从公开价目选择…", systemImage: "magnifyingglass")
                }
                .sheet(isPresented: $showPriceCandidates) {
                    PriceCandidatesSheet(modelId: m.wrappedValue.id,
                                         preferredSource: provider.flatMap { ModelsDevPricing.guessProviderKey($0.baseUrl) }) {
                        m.wrappedValue.pricing = $0
                    }
                }
            } header: { Text("价格（USD / 百万 tokens）") } footer: {
                if let s = m.wrappedValue.pricing?.source, s != "manual" { Text("来源：\(s)") }
            }

            Section {
                ForEach(m.customBody.indices, id: \.self) { i in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("字段名", text: m.customBody[i].key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Picker("", selection: m.customBody[i].type) {
                                Text("字符串").tag(CustomBodyParam.ValueType.string)
                                Text("数字").tag(CustomBodyParam.ValueType.number)
                                Text("布尔").tag(CustomBodyParam.ValueType.boolean)
                                Text("JSON").tag(CustomBodyParam.ValueType.json)
                            }
                            .labelsHidden()
                        }
                        TextField("值", text: m.customBody[i].value).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                .onDelete { m.wrappedValue.customBody.remove(atOffsets: $0) }
                Button { m.wrappedValue.customBody.append(CustomBodyParam(key: "", type: .number, value: "")) } label: {
                    Label("添加参数", systemImage: "plus")
                }
            } header: { Text("请求体参数覆写") } footer: {
                Text("覆盖或追加到请求体顶层，如 top_p、max_tokens。model / messages / stream / tools 等结构字段不可覆盖。")
            }
        }
    }

    private func thinkingFooter(_ m: ProviderModel, baseUrl: String) -> String {
        guard let cfg = m.effectiveThinking(baseUrl: baseUrl) else { return "该模型不发送推理参数。" }
        let source: String = switch cfg.detectSource {
        case .capability: "服务商能力表"
        case .host: "服务商识别"
        case .override: "手动设置"
        default: "按模型名推断"
        }
        return "\(cfg.kind.label) · \(source)"
    }

    private func priceField(_ title: String, _ kp: WritableKeyPath<ModelPricing, Double>, _ m: Binding<ProviderModel>) -> some View {
        LabeledContent(title) {
            TextField("0", value: Binding(get: { m.wrappedValue.pricing?[keyPath: kp] ?? 0 }, set: {
                m.wrappedValue.pricing?[keyPath: kp] = $0; m.wrappedValue.pricing?.source = "manual"
            }), format: .number)
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }

    private func optionalPriceField(_ title: String, _ kp: WritableKeyPath<ModelPricing, Double?>, _ m: Binding<ProviderModel>) -> some View {
        LabeledContent(title) {
            TextField("同输入", value: Binding(get: { m.wrappedValue.pricing?[keyPath: kp] }, set: {
                m.wrappedValue.pricing?[keyPath: kp] = $0; m.wrappedValue.pricing?.source = "manual"
            }), format: .number)
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }
}

struct OptionalIntField: View {
    let title: String
    @Binding var value: Int?
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("未知", value: $value, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                Text(unit).foregroundStyle(MolaColor.secondaryLabel)
            }
        }
    }
}
