import XCTest
@testable import Ration

final class TokenBurnPricingTests: XCTestCase {
    private func total(_ model: String = "claude-opus-5-5", speed: String = "standard", geo: String = "not_available",
                       tokens: TokenCounts, searches: Int = 0, replies: Int = 1) -> TokenBurnStore.UsageTotal {
        .init(priceClass: PriceClass(model: model, speed: speed, geo: geo, tier: "standard", longContext: false),
              tokens: tokens, webSearches: searches, replies: replies)
    }

    /// One million of each kind on Opus 5.5: $4 + $20 + $0.20 + $5 + $8 = $37.20.
    func testEachTokenKindAtItsRate() {
        let million = 1_000_000
        let value = TokenBurnPricing.value(of: [total(tokens: TokenCounts(input: million, output: million, cacheRead: million,
                                                                         cacheWrite5m: million, cacheWrite1h: million))])
        XCTAssertEqual(value.cents, 3_720)
        XCTAssertEqual(value.pricedTokens, 5 * million)
        XCTAssertTrue(value.isComplete)
    }

    func testSmallCountsKeepFractionsOfACent() {
        let value = TokenBurnPricing.value(of: [total(tokens: TokenCounts(output: 1))])
        XCTAssertEqual(value.cents, Decimal(string: "0.002")!, "$20 per million = 0.002 cents a token")
    }

    /// Unsplit cache writes are unpriced, and the figure becomes a lower bound.
    func testUnsplitCacheWritesAreUnpricedAndTheFigureBecomesALowerBound() {
        let value = TokenBurnPricing.value(of: [total(tokens: TokenCounts(input: 1_000_000, cacheWriteUnsplit: 500))])
        XCTAssertEqual(value.cents, 400)
        XCTAssertEqual(value.unpricedTokens, 500)
        XCTAssertFalse(value.isComplete)
    }

    func testUnknownModelIsUnpricedButCounted() {
        let value = TokenBurnPricing.value(of: [total("claude-future-9", tokens: TokenCounts(input: 10, output: 5), replies: 3)])
        XCTAssertEqual(value.cents, 0)
        XCTAssertEqual(value.unpricedTokens, 15)
        XCTAssertEqual(value.replies, 3)
    }

    func testFastModeAndUSRegion() {
        let fast = TokenBurnPricing.value(of: [total(speed: "fast", tokens: TokenCounts(output: 1_000_000))])
        XCTAssertEqual(fast.cents, 4_000)
        let us = TokenBurnPricing.value(of: [total("claude-opus-5", geo: "us", tokens: TokenCounts(input: 1_000_000))])
        XCTAssertEqual(us.cents, 550)
    }

    func testWebSearchesCostOneCentEachWhateverTheModel() {
        let value = TokenBurnPricing.value(of: [total(tokens: TokenCounts(), searches: 7), total("claude-future-9", tokens: TokenCounts(), searches: 3)])
        XCTAssertEqual(value.cents, 10)
        XCTAssertEqual(value.webSearches, 10)
    }

    /// Older logs carry no speed. Standard is the lowest rate
    /// it can have been, so it is priced at that and the figure says "at least".
    func testMissingSpeedIsPricedAsStandardAndMakesTheFigureALowerBound() {
        let value = TokenBurnPricing.value(of: [total(speed: "", tokens: TokenCounts(input: 1_000_000))])
        XCTAssertEqual(value.cents, 400)
        XCTAssertEqual(value.assumedTokens, 1_000_000)
        XCTAssertFalse(value.isComplete)
        let known = TokenBurnPricing.value(of: [total(tokens: TokenCounts(input: 1_000_000))])
        XCTAssertEqual(known.assumedTokens, 0)
        XCTAssertTrue(known.isComplete)
    }
}
