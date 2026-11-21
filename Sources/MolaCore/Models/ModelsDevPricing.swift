import Foundation

// models.dev 公开价目（对应安卓 core/model/ModelsDevPricing.kt）。
// api.json：{ providerKey: { name, models: { modelId: { cost: { input, output, cache_read, cache_write } } } } }，单位 USD / 1M tokens。

public struct ModelsDevProvider: Sendable, Hashable {
    public let key: String
    public let name: String
    /// 小写模型 id → 价格。
    public let models: [String: ModelPricing]
    public init(key: String, name: String, models: [String: ModelPricing]) { self.key = key; self.name = name; self.models = models }
}

public struct ModelsDevPrice: Sendable, Hashable, Identifiable {
    public let providerKey: String
    public let providerName: String
    public let pricing: ModelPricing
    public var id: String { providerKey }
    public init(providerKey: String, providerName: String, pricing: ModelPricing) {
        self.providerKey = providerKey; self.providerName = providerName; self.pricing = pricing
    }
}

public struct PricingMatch: Sendable {
    /// 所有来源价格一致 → 可直接写入。
    public var agreed: [String: ModelPricing] = [:]
    /// 多个来源价格不同 → 需用户选择。
    public var conflicts: [String: [ModelsDevPrice]] = [:]
    public var unmatched: [String] = []
}

public enum ModelsDevPricing {
    public static let catalogURL = URL(string: "https://models.dev/api.json")!
    public static let cacheTTL: TimeInterval = 7 * 24 * 3600

    public static func parse(_ data: Data) -> [ModelsDevProvider] {
        guard let root = JSONValue.parse(data)?.objectValue else { return [] }
        return root.compactMap { key, value -> ModelsDevProvider? in
            guard let models = value["models"]?.objectValue else { return nil }
            var prices: [String: ModelPricing] = [:]
            for (id, model) in models {
                guard let cost = model["cost"],
                      let p = readPricing(cost, "input", "output", "cache_read", "cache_write", scale: 1, source: "models.dev")
                else { continue }
                prices[id.lowercased()] = p
            }
            guard !prices.isEmpty else { return nil }
            return ModelsDevProvider(key: key, name: value["name"]?.stringValue ?? key, models: prices)
        }
        .sorted { $0.key < $1.key }
    }

    public static func candidates(_ providers: [ModelsDevProvider], modelId: String) -> [ModelsDevPrice] {
        let id = modelId.trimmingCharacters(in: .whitespaces).lowercased()
        return providers.compactMap { p in p.models[id].map { ModelsDevPrice(providerKey: p.key, providerName: p.name, pricing: $0) } }
    }

    public static func match(_ providers: [ModelsDevProvider], modelIds: [String]) -> PricingMatch {
        var out = PricingMatch()
        var seen = Set<String>()
        for id in modelIds where seen.insert(id).inserted {
            let prices = candidates(providers, modelId: id)
            if prices.isEmpty { out.unmatched.append(id) }
            else if Set(prices.map(\.pricing)).count == 1 { out.agreed[id] = prices[0].pricing }
            else { out.conflicts[id] = prices }
        }
        return out
    }

    /// 由服务地址猜 models.dev 的 provider key（api.deepseek.com → deepseek）。
    public static func guessProviderKey(_ baseUrl: String) -> String? {
        let skip: Set<String> = ["www", "api", "com", "org", "net", "ai", "io", "cn", "co"]
        return URL(string: baseUrl)?.host?.lowercased().split(separator: ".").map(String.init).first { !skip.contains($0) }
    }

    /// 已是 models.dev 价格且数值相同（忽略来源字段）。
    public static func samePrice(_ a: ModelPricing?, _ b: ModelPricing) -> Bool {
        guard var a, let s = a.source, s == "models.dev" || s.hasPrefix("models.dev:") else { return false }
        var b = b
        a.source = nil; b.source = nil
        return a == b
    }

    static func readPricing(_ obj: JSONValue, _ input: String, _ output: String, _ read: String, _ write: String,
                            scale: Double, source: String) -> ModelPricing? {
        func rate(_ k: String) -> Double? { obj[k]?.doubleValue.map { $0 * scale } }
        guard let i = rate(input), let o = rate(output) else { return nil }
        let p = ModelPricing(input: i, output: o, cacheRead: rate(read), cacheWrite: rate(write), source: source)
        return p.isValid ? p : nil
    }
}

public extension ModelPricing {
    /// 手动价格优先，其次用新获取的价格（安卓 `mergeModelPricing`）。
    static func merge(_ current: ModelPricing?, _ incoming: ModelPricing?) -> ModelPricing? {
        if current?.isManual == true { return current }
        return incoming ?? current
    }
}
