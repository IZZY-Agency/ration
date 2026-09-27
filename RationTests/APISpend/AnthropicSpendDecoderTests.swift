import XCTest
@testable import Ration

final class AnthropicSpendDecoderTests: XCTestCase {
    private let month = UTCMonth(year: 2026, month: 9)
    private let fetchedAt = ISO8601DateFormatter().date(from: "2026-09-27T17:05:00Z")!

    private func costPage(_ buckets: String, hasMore: Bool = false) -> Data {
        Data(#"{"data":[\#(buckets)],"has_more":\#(hasMore),"next_page":\#(hasMore ? "\"p2\"" : "null")}"#.utf8)
    }

    func testSumsCentsPerDayModelAndOtherCharges() throws {
        let page = costPage(#"""
        {"starting_at":"2026-09-26T00:00:00Z","ending_at":"2026-09-27T00:00:00Z","results":[
          {"amount":"1000.5","currency":"USD","description":"Claude Opus 5 Usage - Input Tokens","model":"claude-opus-5"},
          {"amount":"250","currency":"USD","description":"Code Execution Usage","model":null}]},
        {"starting_at":"2026-09-27T00:00:00Z","ending_at":"2026-09-28T00:00:00Z","results":[
          {"amount":"99.5","currency":"usd","description":"Claude Opus 5 Usage - Output Tokens","model":"claude-opus-5"}]}
        """#)
        let report = try AnthropicSpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.monthToDateCents, Decimal(string: "1350")!)
        XCTAssertEqual(report.todayCents, Decimal(string: "99.5")!)
        XCTAssertEqual(report.byModel, [ModelCost(model: "claude-opus-5", cents: Decimal(string: "1100")!)])
        XCTAssertEqual(report.otherCharges, [DescriptionCost(description: "Code Execution Usage", cents: 250)])
        // Reconciliation invariant: the detail sums to the month-to-date.
        let detail = report.byModel.map(\.cents).reduce(0, +) + report.otherCharges.map(\.cents).reduce(0, +)
        XCTAssertEqual(detail, report.monthToDateCents)
    }

    /// Confirmed on real responses: Anthropic's cost report
    /// has no bucket for the current day. The report says so, and the card
    /// then reads "through yesterday" instead of "today $0.00".
    func testReportsWhetherTodaysBucketArrived() throws {
        let throughYesterday = costPage(#"{"starting_at":"2026-09-26T00:00:00Z","ending_at":"2026-09-27T00:00:00Z","results":[{"amount":"1000","currency":"USD","description":"x","model":"m"}]}"#)
        let withToday = costPage(#"{"starting_at":"2026-09-27T00:00:00Z","ending_at":"2026-09-28T00:00:00Z","results":[]}"#)
        XCTAssertEqual(try AnthropicSpendDecoder.costReport(pages: [throughYesterday], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt).coversToday, false)
        XCTAssertEqual(try AnthropicSpendDecoder.costReport(pages: [withToday], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt).coversToday, true,
                       "an EMPTY bucket for today still covers today")
    }

    func testBucketsOutsideTheMonthAreExcluded() throws {
        let page = costPage(#"""
        {"starting_at":"2026-08-31T00:00:00Z","ending_at":"2026-09-01T00:00:00Z","results":[{"amount":"500","currency":"USD","description":"x","model":"m"}]},
        {"starting_at":"2026-09-01T00:00:00Z","ending_at":"2026-09-02T00:00:00Z","results":[{"amount":"7","currency":"USD","description":"x","model":"m"}]}
        """#)
        let report = try AnthropicSpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.monthToDateCents, 7)
    }

    func testPagesAreJoined() throws {
        let first = costPage(#"{"starting_at":"2026-09-01T00:00:00Z","ending_at":"2026-09-02T00:00:00Z","results":[{"amount":"1","currency":"USD","description":"x","model":"m"}]}"#, hasMore: true)
        let second = costPage(#"{"starting_at":"2026-09-02T00:00:00Z","ending_at":"2026-09-03T00:00:00Z","results":[{"amount":"2","currency":"USD","description":"x","model":"m"}]}"#)
        let report = try AnthropicSpendDecoder.costReport(pages: [first, second], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.monthToDateCents, 3)
        XCTAssertEqual(report.days.count, 2)
    }

    func testNonUSDCurrencyIsIntegrationChanged() {
        let page = costPage(#"{"starting_at":"2026-09-01T00:00:00Z","ending_at":"2026-09-02T00:00:00Z","results":[{"amount":"1","currency":"EUR","description":"x","model":"m"}]}"#)
        XCTAssertThrowsError(try AnthropicSpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)) {
            XCTAssertEqual($0 as? APISpendError, .integrationChanged(.currency))
        }
    }

    /// Token counts that overflow `Int` read as unknown ("—"), never trap.
    func testOverflowingTokenSumsAreUnknownNotACrash() {
        XCTAssertNil(AnthropicSpendDecoder.strictSum([Int.max, 1]))
        XCTAssertEqual(AnthropicSpendDecoder.strictSum([2, 3]), 5)
        XCTAssertNil(AnthropicSpendDecoder.checkedAdd(Int.max, 1))
    }

    func testGarbageIsIntegrationChangedDecode() {
        XCTAssertThrowsError(try AnthropicSpendDecoder.costReport(pages: [Data("{}".utf8)], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)) {
            XCTAssertEqual($0 as? APISpendError, .integrationChanged(.decode))
        }
    }

    /// First minutes of a month — no bucket yet.
    func testEmptyMonthIsZero() throws {
        let report = try AnthropicSpendDecoder.costReport(pages: [costPage("")], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.monthToDateCents, 0)
        XCTAssertEqual(report.todayCents, 0)
    }

    func testTokensSumPerModelAndMissingFieldStaysNil() throws {
        let page = Data(#"""
        {"data":[{"starting_at":"2026-09-26T00:00:00Z","ending_at":"2026-09-27T00:00:00Z","results":[
          {"model":"claude-opus-5","service_tier":"standard","uncached_input_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":2},"cache_read_input_tokens":30,"output_tokens":5},
          {"model":"claude-opus-5","service_tier":"standard","uncached_input_tokens":20,"cache_read_input_tokens":0,"output_tokens":5}]}],
         "has_more":false,"next_page":null}
        """#.utf8)
        let report = try AnthropicSpendDecoder.tokenReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        let opus = try XCTUnwrap(report.byModel.first)
        XCTAssertEqual(opus.input, 30)
        XCTAssertNil(opus.cacheWrite, "one result lacked cache_creation: never a partial sum")
        XCTAssertEqual(opus.cacheRead, 30)
        XCTAssertEqual(opus.output, 10)
        XCTAssertFalse(report.hasPriorityTierUsage)
    }

    func testPriorityTierUsageIsDetected() throws {
        let page = Data(#"{"data":[{"starting_at":"2026-09-26T00:00:00Z","ending_at":"2026-09-27T00:00:00Z","results":[{"model":"m","service_tier":"priority","uncached_input_tokens":1,"output_tokens":1}]}],"has_more":false,"next_page":null}"#.utf8)
        XCTAssertTrue(try AnthropicSpendDecoder.tokenReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt).hasPriorityTierUsage)
    }
}
