import XCTest
@testable import Ration

final class OpenAISpendDecoderTests: XCTestCase {
    private let month = UTCMonth(year: 2026, month: 9)
    private let fetchedAt = ISO8601DateFormatter().date(from: "2026-09-27T17:05:00Z")!
    // 2026-09-26T00:00:00Z and 2026-09-27T00:00:00Z
    private let d26 = 1_790_380_800, d27 = 1_790_467_200

    /// OpenAI sends an (empty) bucket for today: the card may say "today $0.00".
    func testAnEmptyBucketForTodayCoversToday() throws {
        let page = Data(#"{"data":[{"object":"bucket","start_time":\#(d27),"end_time":\#(d27 + 86_400),"results":[]}],"has_more":false,"next_page":null}"#.utf8)
        let report = try OpenAISpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.coversToday, true)
        XCTAssertEqual(report.monthToDateCents, 0)
    }

    func testDollarsBecomeCentsPerDayAndLineItem() throws {
        let page = Data(#"""
        {"object":"page","data":[
          {"object":"bucket","start_time":\#(d26),"end_time":\#(d27),"results":[
            {"object":"organization.costs.result","amount":{"value":1.25,"currency":"usd"},"line_item":"gpt-5, input"},
            {"object":"organization.costs.result","amount":{"value":0.06,"currency":"usd"},"line_item":"gpt-5, output"}]},
          {"object":"bucket","start_time":\#(d27),"end_time":\#(d27 + 86_400),"results":[
            {"object":"organization.costs.result","amount":{"value":0.5,"currency":"usd"},"line_item":"gpt-5, input"}]}],
         "has_more":false,"next_page":null}
        """#.utf8)
        let report = try OpenAISpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.monthToDateCents, 181)
        XCTAssertEqual(report.todayCents, 50)
        XCTAssertEqual(report.byLineItem.map(\.cents).reduce(0, +), report.monthToDateCents)
        XCTAssertEqual(report.byLineItem.first(where: { $0.lineItem == "gpt-5, input" })?.cents, 175)
    }

    /// JSONDecoder → Decimal must be exact for literal tokens.
    func testDecimalDecodingIsExactForLiteralTokens() throws {
        for token in ["0.06", "1.2378912", "123456.789", "1e-7", "2.5E+3", "0", "1000000", "0.123456789012",
                      "0.00008250000000000000000000000000000000", "0.001669500000000000000000000000000000"] {
            let data = Data(#"{"value":\#(token)}"#.utf8)
            struct Box: Decodable { let value: Decimal }
            let decoded = try JSONDecoder().decode(Box.self, from: data).value
            let expected = try XCTUnwrap(Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")))
            XCTAssertEqual(decoded, expected, token)
        }
    }

    /// OpenAI sends zero as `0E-6176`, which JSONDecoder
    /// rejects for the WHOLE page. Zero-significand numeric tokens become `0`.
    func testZeroWithHugeExponentDecodesAsExactZero() throws {
        let page = Data(#"{"object":"page","data":[{"object":"bucket","start_time":\#(d26),"end_time":\#(d27),"results":[{"amount":{"value":0E-6176,"currency":"usd"},"line_item":"a"},{"amount":{"value": 0.0E+12 ,"currency":"usd"},"line_item":"b"},{"amount":{"value":0.00008250000000000000000000000000000000,"currency":"usd"},"line_item":"c"}]}],"has_more":false,"next_page":null}"#.utf8)
        let report = try OpenAISpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.monthToDateCents, Decimal(string: "0.00825")!)
    }

    func testZeroRewriteNeverTouchesStrings() {
        let raw = Data(#"{"line_item":"model 0E-5, input","value":0E-6176,"list":[0e-3,1]}"#.utf8)
        let normalized = String(decoding: OpenAISpendDecoder.normalizingZeroExponents(raw), as: UTF8.self)
        XCTAssertTrue(normalized.contains(#""model 0E-5, input""#))
        XCTAssertFalse(normalized.contains("0E-6176"))
        XCTAssertFalse(normalized.contains("0e-3"))
    }

    func testNonZeroOutOfRangeExponentStillRefuses() {
        let page = Data(#"{"object":"page","data":[{"object":"bucket","start_time":\#(d26),"end_time":\#(d27),"results":[{"amount":{"value":1E-6176,"currency":"usd"},"line_item":"a"}]}],"has_more":false,"next_page":null}"#.utf8)
        XCTAssertThrowsError(try OpenAISpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)) {
            XCTAssertEqual($0 as? APISpendError, .integrationChanged(.decode))
        }
    }

    func testCompletionTokensPerModel() throws {
        let page = Data(#"{"object":"page","data":[{"object":"bucket","start_time":\#(d26),"end_time":\#(d27),"results":[{"object":"organization.usage.completions.result","model":"gpt-5","input_uncached_tokens":5,"input_cache_write_tokens":1,"input_cached_tokens":4,"output_tokens":3,"input_tokens":10,"num_model_requests":1}]}],"has_more":false,"next_page":null}"#.utf8)
        let report = try OpenAISpendDecoder.tokenReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)
        XCTAssertEqual(report.byModel, [ModelTokens(model: "gpt-5", input: 5, cacheWrite: 1, cacheRead: 4, output: 3)])
        XCTAssertFalse(report.hasPriorityTierUsage)
    }

    func testCurrencyIsCaseInsensitiveButMustBeUSD() {
        let page = Data(#"{"object":"page","data":[{"object":"bucket","start_time":\#(d26),"end_time":\#(d27),"results":[{"amount":{"value":1,"currency":"eur"},"line_item":"x"}]}],"has_more":false,"next_page":null}"#.utf8)
        XCTAssertThrowsError(try OpenAISpendDecoder.costReport(pages: [page], month: month, fetchedAt: fetchedAt, refreshStartedAt: fetchedAt)) {
            XCTAssertEqual($0 as? APISpendError, .integrationChanged(.currency))
        }
    }
}
