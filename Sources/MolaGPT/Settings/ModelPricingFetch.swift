import SwiftUI
import MolaCore

// 一键获取模型价格（对应安卓 ModelsDevCatalog + SettingsViewModel.fetchAllModelPrices + ByokPricingSection）。
// 价目来自 models.dev 公开 api.json，缓存在 Caches 7 天；各来源一致的价格直接写入，冲突/未匹配的进「完善价格」逐个确认。

actor ModelsDevCatalog {
    static let shared = ModelsDevCatalog()
    struct Loaded: Sendable { let providers: [ModelsDevProvider]; let warning: String? }

    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("models-dev.json")
    private var memo: (date: Date, providers: [ModelsDevProvider])?

    nonisolated var cachedAt: Date? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("models-dev.json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func load(force: Bool = false) async throws -> Loaded {
        let cachedDate = cachedAt
        var cached: [ModelsDevProvider]?
        if let memo, memo.date == cachedDate { cached = memo.providers }
        else if let data = try? Data(contentsOf: cacheURL) {
            let parsed = ModelsDevPricing.parse(data)
            if !parsed.isEmpty, let cachedDate { cached = parsed; memo = (cachedDate, parsed) }
        }
        if !force, let cached, let cachedDate, Date().timeIntervalSince(cachedDate) < ModelsDevPricing.cacheTTL {
            return Loaded(providers: cached, warning: nil)
        }
        do {
            var req = URLRequest(url: ModelsDevPricing.catalogURL, timeoutInterval: 30)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw PricingError("价目获取失败：HTTP \(code)") }
            let parsed = ModelsDevPricing.parse(data)
            guard !parsed.isEmpty else { throw PricingError("公开价目未包含有效价格") }
            try? data.write(to: cacheURL, options: .atomic)
            if let d = cachedAt { memo = (d, parsed) }
            return Loaded(providers: parsed, warning: nil)
        } catch {
            guard let cached else { throw error }
            return Loaded(providers: cached, warning: "刷新失败，已使用缓存价目：\(error.localizedDescription)")
        }
    }
}

struct PricingError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct ModelPriceReview: Identifiable, Hashable {
    let providerId: String
    let providerName: String
    let model: ProviderModel
    let candidates: [ModelsDevPrice]
    let preferredSource: String?
    var id: String { providerId + "\u{1F}" + model.id }
}

@MainActor @Observable
final class PricingCenter {
    static let shared = PricingCenter()
    var busy = false
    var result: String?
    var reviews: [ModelPriceReview] = []
    var cachedAt: Date? = ModelsDevCatalog.shared.cachedAt

    private func isPriced(_ m: ProviderModel) -> Bool { !m.supportsImageGeneration }

    func fetchAll(app: AppModel, force: Bool) async {
        guard !busy else { return }
        busy = true; result = nil
        defer { busy = false; cachedAt = ModelsDevCatalog.shared.cachedAt }
        do {
            let loaded = try await ModelsDevCatalog.shared.load(force: force)
            let targets = app.providers.filter { $0.purpose == .chat }
            let match = ModelsDevPricing.match(loaded.providers,
                                               modelIds: targets.flatMap { $0.models.filter(isPriced).map(\.id) })
            var written = 0
            for p in targets { written += apply(app: app, providerId: p.id, prices: match.agreed) }
            var resolved = 0
            var reviews: [ModelPriceReview] = []
            for p in app.providers where p.purpose == .chat {
                for m in p.models where isPriced(m) && m.pricing?.isManual != true {
                    let cands = match.conflicts[m.id]
                    guard cands != nil || match.unmatched.contains(m.id) else { continue }
                    if let cands, cands.contains(where: { ModelsDevPricing.samePrice(m.pricing, $0.pricing) }) { resolved += 1; continue }
                    reviews.append(ModelPriceReview(providerId: p.id, providerName: p.name, model: m, candidates: cands ?? [],
                                                    preferredSource: ModelsDevPricing.guessProviderKey(p.baseUrl)))
                }
            }
            let manual = targets.reduce(0) { $0 + $1.models.filter { isPriced($0) && $0.pricing?.isManual == true }.count }
            let conflicts = reviews.filter { !$0.candidates.isEmpty }.count
            let unmatched = reviews.count - conflicts
            let parts = [
                written > 0 ? "已保存 \(written) 项价格" : nil,
                manual > 0 ? "保留 \(manual) 项手动价格" : nil,
                conflicts > 0 ? "\(conflicts) 项价格不一致" : nil,
                unmatched > 0 ? "\(unmatched) 项未匹配" : nil,
                loaded.warning,
            ].compactMap { $0 }
            self.reviews = reviews
            result = parts.isEmpty ? (resolved > 0 ? "模型价格已是最新" : "没有可用的价格") : parts.joined(separator: "；")
        } catch {
            result = "获取定价失败：\(error.localizedDescription)"
        }
    }

    /// 写入价格（保留手动价格），返回实际改动数。
    @discardableResult
    func apply(app: AppModel, providerId: String, prices: [String: ModelPricing]) -> Int {
        guard var p = app.provider(providerId) else { return 0 }
        var written = 0
        for i in p.models.indices {
            let merged = ModelPricing.merge(p.models[i].pricing, prices[p.models[i].id])
            if merged != p.models[i].pricing { p.models[i].pricing = merged; written += 1 }
        }
        if written > 0 { app.saveProvider(p) }
        return written
    }

    /// 保存复核结果。选了来源且 `applyToSameSource` 时，同服务下候选含该来源的待确认模型一并采用该来源价格。
    func saveReview(app: AppModel, review: ModelPriceReview, pricing: ModelPricing, sourceKey: String?, applyToSameSource: Bool) {
        let targets: [ModelPriceReview] = if applyToSameSource, let sourceKey {
            reviews.filter { $0.providerId == review.providerId && $0.candidates.contains { $0.providerKey == sourceKey } }
        } else { [review] }
        var prices: [String: ModelPricing] = [:]
        for t in targets {
            var chosen = sourceKey.flatMap { k in t.candidates.first { $0.providerKey == k }?.pricing } ?? pricing
            chosen.source = sourceKey.map { "models.dev:\($0)" } ?? pricing.source
            prices[t.model.id] = chosen
        }
        // 用户确认的价格覆盖旧值（包括手动价格以外的任何来源）。
        if var p = app.provider(review.providerId) {
            for i in p.models.indices { if let np = prices[p.models[i].id] { p.models[i].pricing = np } }
            app.saveProvider(p)
        }
        let done = Set(targets.map(\.id))
        reviews.removeAll { done.contains($0.id) }
        result = targets.count == 1 ? "已保存 \(review.providerName) / \(review.model.displayName) 的价格"
            : "已为 \(review.providerName) 的 \(targets.count) 个模型保存价格"
    }
}

// MARK: - 服务列表里的入口

struct PricingFetchSection: View {
    @Environment(AppModel.self) private var app
    @State private var center = PricingCenter.shared
    @State private var feedback = 0

    var body: some View {
        Section {
            Button {
                Task { await center.fetchAll(app: app, force: false); feedback += 1 }
            } label: {
                HStack {
                    Label("获取模型价格", systemImage: "dollarsign.circle")
                    Spacer()
                    if center.busy { ProgressView() }
                }
            }
            .disabled(center.busy || app.providers.isEmpty)
            .contextMenu {
                Button { Task { await center.fetchAll(app: app, force: true); feedback += 1 } } label: {
                    Label("强制刷新价目", systemImage: "arrow.clockwise")
                }
            }
            if !center.reviews.isEmpty {
                NavigationLink {
                    PriceReviewList()
                } label: {
                    LabeledContent("完善价格") { Text("\(center.reviews.count)") }
                }
            }
        } header: {
            Text("价格")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let r = center.result { Text(r) }
                Text("价格取自 models.dev 公开价目，手动设置的价格不会被覆盖。长按可强制刷新。")
                if let d = center.cachedAt { Text("价目更新于 \(d.formatted(date: .abbreviated, time: .shortened))") }
            }
        }
        .sensoryFeedback(.success, trigger: feedback)
    }
}

struct PriceReviewList: View {
    @State private var center = PricingCenter.shared
    @State private var query = ""

    private var filtered: [ModelPriceReview] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return center.reviews }
        return center.reviews.filter {
            $0.model.id.lowercased().contains(q) || $0.model.displayName.lowercased().contains(q) || $0.providerName.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            ForEach(Dictionary(grouping: filtered, by: \.providerName).sorted { $0.key < $1.key }, id: \.key) { name, items in
                Section(name) {
                    ForEach(items) { r in
                        NavigationLink { PriceReviewDetail(review: r) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.model.displayName)
                                Text(r.candidates.isEmpty ? "未在公开价目中找到" : "\(r.candidates.count) 个来源价格不一致")
                                    .font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if center.reviews.isEmpty { ContentUnavailableView("价格均已确认", systemImage: "checkmark.circle") }
            else if filtered.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, prompt: "搜索模型或服务")
        .navigationTitle("完善价格")
    }
}

/// 单个模型：从候选来源中选一个，或手动填写。
struct PriceReviewDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let review: ModelPriceReview
    @State private var source: String?
    @State private var manual = ModelPricing(input: 0, output: 0, source: "manual")
    @State private var applyToSame = true
    @State private var query = ""

    private var sorted: [ModelsDevPrice] {
        let pref = review.preferredSource
        let all = review.candidates.sorted { a, b in
            if (a.providerKey == pref) != (b.providerKey == pref) { return a.providerKey == pref }
            return a.providerName.localizedStandardCompare(b.providerName) == .orderedAscending
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.providerName.lowercased().contains(q) || $0.providerKey.contains(q) }
    }

    private var sameSourceCount: Int {
        guard let source else { return 0 }
        return PricingCenter.shared.reviews.filter {
            $0.providerId == review.providerId && $0.id != review.id && $0.candidates.contains { $0.providerKey == source }
        }.count
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("模型", value: review.model.id)
                LabeledContent("服务", value: review.providerName)
            }
            if !review.candidates.isEmpty {
                Section {
                    ForEach(sorted) { c in
                        Button { source = c.providerKey } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.providerName).foregroundStyle(MolaColor.label)
                                    Text(PriceFormat.summary(c.pricing)).font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                                }
                                Spacer()
                                if source == c.providerKey { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                    Button { source = nil } label: {
                        HStack {
                            Text("手动填写").foregroundStyle(MolaColor.label)
                            Spacer()
                            if source == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                } header: { Text("价格来源") } footer: {
                    if review.candidates.count > 6 { TextField("搜索来源", text: $query) }
                }
            }
            if source == nil {
                PriceFields(pricing: $manual)
            } else if sameSourceCount > 0 {
                Section {
                    Toggle("同来源的其他 \(sameSourceCount) 个模型也采用", isOn: $applyToSame)
                }
            }
        }
        .navigationTitle(review.model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    PricingCenter.shared.saveReview(app: app, review: review, pricing: manual, sourceKey: source,
                                                    applyToSameSource: applyToSame)
                    dismiss()
                }
                .disabled(source == nil && !(manual.isValid && manual.input.isFinite))
            }
        }
        .onAppear {
            if let pref = review.preferredSource, review.candidates.contains(where: { $0.providerKey == pref }) { source = pref }
            else if review.candidates.count == 1 { source = review.candidates[0].providerKey }
            if let p = review.model.pricing { manual = p; manual.source = "manual" }
        }
    }
}

struct PriceFields: View {
    @Binding var pricing: ModelPricing

    var body: some View {
        Section {
            row("输入", value: Binding(get: { pricing.input }, set: { pricing.input = $0 ?? 0 }), placeholder: "0")
            row("输出", value: Binding(get: { pricing.output }, set: { pricing.output = $0 ?? 0 }), placeholder: "0")
            row("缓存读取", value: $pricing.cacheRead, placeholder: "同输入")
            row("缓存写入", value: $pricing.cacheWrite, placeholder: "可选")
        } header: { Text("USD / 百万 tokens") } footer: {
            if !pricing.isValid { Text("价格必须为非负数。").foregroundStyle(.red) }
        }
    }

    private func row(_ title: String, value: Binding<Double?>, placeholder: String) -> some View {
        LabeledContent(title) {
            TextField(placeholder, value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }
}

enum PriceFormat {
    static func num(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(0...4)))
    }
    static func summary(_ p: ModelPricing) -> String {
        var s = "输入 $\(num(p.input)) · 输出 $\(num(p.output))"
        if p.cacheRead != nil || p.cacheWrite != nil { s += " · 缓存 \(num(p.cacheRead))/\(num(p.cacheWrite))" }
        return s
    }
}

// MARK: - 模型编辑页：从公开价目选一个

struct PriceCandidatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let modelId: String
    let preferredSource: String?
    let onPick: (ModelPricing) -> Void

    @State private var state: LoadState = .loading
    enum LoadState { case loading, loaded([ModelsDevPrice], String?), failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("正在获取价目…")
                case .failed(let msg):
                    ContentUnavailableView("获取失败", systemImage: "exclamationmark.triangle", description: Text(msg))
                case .loaded(let items, let warning):
                    if items.isEmpty {
                        ContentUnavailableView("未找到价格", systemImage: "magnifyingglass",
                                               description: Text("公开价目中没有「\(modelId)」。可以手动填写。"))
                    } else {
                        List {
                            Section {
                                ForEach(items) { c in
                                    Button {
                                        var p = c.pricing
                                        p.source = "models.dev:\(c.providerKey)"
                                        onPick(p); dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(c.providerName).foregroundStyle(MolaColor.label)
                                                if c.providerKey == preferredSource {
                                                    Text("当前服务").font(.caption2).foregroundStyle(.tint)
                                                }
                                            }
                                            Text(PriceFormat.summary(c.pricing)).font(.footnote).foregroundStyle(MolaColor.secondaryLabel)
                                        }
                                    }
                                }
                            } footer: { if let warning { Text(warning) } }
                        }
                    }
                }
            }
            .navigationTitle("选择价格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            do {
                let loaded = try await ModelsDevCatalog.shared.load()
                let items = ModelsDevPricing.candidates(loaded.providers, modelId: modelId).sorted { a, b in
                    if (a.providerKey == preferredSource) != (b.providerKey == preferredSource) { return a.providerKey == preferredSource }
                    return a.providerName.localizedStandardCompare(b.providerName) == .orderedAscending
                }
                state = .loaded(items, loaded.warning)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
