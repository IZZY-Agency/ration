import XCTest
@testable import Ration

final class ClaudePriceTableTests: XCTestCase {
    private let table = ClaudePriceTable.current
    private func cls(_ model: String, speed: String = "standard", geo: String = "not_available",
                     tier: String = "standard", long: Bool = false) -> PriceClass {
        PriceClass(model: model, speed: speed, geo: geo, tier: tier, longContext: long)
    }

    /// Every model seen in real Claude Code logs on 2026-09-29 (spec §2) has a list price.
    func testEveryModelSeenInTheLogsIsPriced() {
        for model in ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5", "claude-fable-5-1", "claude-fable-5",
                      "claude-haiku-4-5-20251001", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5-5",
                      "claude-sonnet-4-5-20250929"] {
            guard case .priced = table.rates(for: cls(model)) else { return XCTFail("\(model) unpriced") }
        }
    }

    func testRatesAreThePublishedOnes() {
        guard case .priced(let opus, let m) = table.rates(for: cls("claude-opus-5-5")) else { return XCTFail() }
        XCTAssertEqual(m, 1)
        XCTAssertEqual(opus, ModelRates(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: Decimal(string: "0.20")!, output: 20))
        guard case .priced(let fable, _) = table.rates(for: cls("claude-fable-5-1")) else { return XCTFail() }
        XCTAssertEqual(fable.cacheRead, Decimal(string: "0.25")!)
        guard case .priced(let fable5, _) = table.rates(for: cls("claude-fable-5")) else { return XCTFail() }
        XCTAssertEqual(fable5.cacheRead, 1)
    }

    func testFastModeHasItsOwnRatesAndOtherSpeedsAreUnpriced() {
        guard case .priced(let fast, _) = table.rates(for: cls("claude-opus-5-5", speed: "fast")) else { return XCTFail() }
        XCTAssertEqual(fast.input, 8)
        XCTAssertEqual(fast.output, 40)
        XCTAssertEqual(fast.cacheRead, Decimal(string: "0.40")!)
        XCTAssertEqual(table.rates(for: cls("claude-sonnet-5", speed: "fast")), .unpriced(.unknownSpeed))
        XCTAssertEqual(table.rates(for: cls("claude-opus-5-5", speed: "turbo")), .unpriced(.unknownSpeed))
        guard case .priced = table.rates(for: cls("claude-opus-5-5", speed: "")) else { return XCTFail("older logs have no speed") }
    }

    func testUSOnlyInferenceCostsTenPercentMoreOnModernModelsOnly() {
        guard case .priced(_, let m) = table.rates(for: cls("claude-opus-5", geo: "us")) else { return XCTFail() }
        XCTAssertEqual(m, Decimal(string: "1.1")!)
        XCTAssertEqual(table.rates(for: cls("claude-sonnet-4-5-20250929", geo: "us")), .unpriced(.unknownRegion))
        XCTAssertEqual(table.rates(for: cls("claude-opus-5", geo: "eu")), .unpriced(.unknownRegion))
    }

    func testNoPrefixMatching() {
        XCTAssertEqual(table.rates(for: cls("claude-opus-5-5-20270101")), .unpriced(.unknownModel))
        XCTAssertEqual(table.rates(for: cls("claude-opus")), .unpriced(.unknownModel))
        XCTAssertEqual(table.rates(for: cls("claude-opus-4-5")), .unpriced(.unknownModel), "dated id not verified")
    }

    func testOlderModelOver200KPromptIsUnpricedModernIsNot() {
        XCTAssertEqual(table.rates(for: cls("claude-sonnet-4-5-20250929", long: true)), .unpriced(.longContext))
        guard case .priced = table.rates(for: cls("claude-opus-5-5", long: true)) else { return XCTFail() }
    }

    func testOnlyStandardTierIsPriced() {
        XCTAssertEqual(table.rates(for: cls("claude-opus-5-5", tier: "priority")), .unpriced(.unknownTier))
        guard case .priced = table.rates(for: cls("claude-opus-5-5", tier: "")) else { return XCTFail() }
    }

    func testTableCarriesItsDateAndSource() {
        XCTAssertEqual(table.asOf, "2026-09-29")
        XCTAssertEqual(table.source.host(), "platform.claude.com")
        XCTAssertEqual(table.webSearchCentsEach, 1)
    }
}
