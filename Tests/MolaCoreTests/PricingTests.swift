import XCTest
@testable import MolaCore

final class ModelsDevPricingTests: XCTestCase {
    let sample = """
    {
      "deepseek": {"name": "DeepSeek", "models": {
        "deepseek-chat": {"cost": {"input": 0.27, "output": 1.1, "cache_read": 0.07}},
        "free-model": {"name": "no cost"}
      }},
      "openrouter": {"name": "OpenRouter", "models": {
        "DeepSeek-Chat": {"cost": {"input": 0.27, "output": 1.1, "cache_read": 0.07}},
        "gpt-x": {"cost": {"input": 2, "output": 8}}
      }},
      "azure": {"name": "Azure", "models": {
        "gpt-x": {"cost": {"input": 2.5, "output": 10}},
        "bad": {"cost": {"input": -1, "output": 1}}
      }},
      "empty": {"name": "Empty", "models": {}}
    }
    """

    func testParseAndMatch() {
        let providers = ModelsDevPricing.parse(Data(sample.utf8))
        XCTAssertEqual(providers.map(\.key), ["azure", "deepseek", "openrouter"])
        XCTAssertNil(providers[0].models["bad"])
        XCTAssertEqual(providers[1].models["deepseek-chat"]?.cacheRead, 0.07)

        let m = ModelsDevPricing.match(providers, modelIds: ["deepseek-chat", "GPT-X", "nope", "deepseek-chat"])
        XCTAssertEqual(m.agreed["deepseek-chat"]?.input, 0.27)
        XCTAssertEqual(m.conflicts["GPT-X"]?.map(\.providerKey), ["azure", "openrouter"])
        XCTAssertEqual(m.unmatched, ["nope"])
    }

    func testMergeAndHelpers() {
        let manual = ModelPricing(input: 1, output: 2, source: "manual")
        let fetched = ModelPricing(input: 3, output: 4, source: "models.dev")
        XCTAssertEqual(ModelPricing.merge(manual, fetched), manual)
        XCTAssertEqual(ModelPricing.merge(nil, fetched), fetched)
        XCTAssertEqual(ModelPricing.merge(fetched, nil), fetched)

        XCTAssertTrue(ModelsDevPricing.samePrice(ModelPricing(input: 3, output: 4, source: "models.dev:azure"), fetched))
        XCTAssertFalse(ModelsDevPricing.samePrice(ModelPricing(input: 3, output: 4, source: "manual"), fetched))

        XCTAssertEqual(ModelsDevPricing.guessProviderKey("https://api.deepseek.com/v1"), "deepseek")
        XCTAssertEqual(ModelsDevPricing.guessProviderKey("https://openrouter.ai/api"), "openrouter")
    }
}
