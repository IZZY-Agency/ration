import XCTest
@testable import Ration

/// Contract tests on real, redacted vendor responses, kept outside the
/// public source tree. Skipped when the fixtures are absent.
final class APISpendPrivateFixtureTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../docs/verification/api-spend").standardizedFileURL
    }

    private func fixture(_ name: String) throws -> Data {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("private fixture \(name) absent") }
        return try Data(contentsOf: url)
    }

    /// Anthropic amounts are strings, so a JSONSerialization split is lossless.
    private func anthropicPages(_ name: String) throws -> [Data] {
        let array = try JSONSerialization.jsonObject(with: try fixture(name)) as? [Any] ?? []
        return try array.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    func testAnthropicFixturesDecodeAndReconcile() throws {
        let month = UTCMonth(year: 2026, month: 9)
        let at = ISO8601DateFormatter().date(from: "2026-09-27T14:22:43Z")!
        let cost = try AnthropicSpendDecoder.costReport(pages: try anthropicPages("anthropic-cost.pages.json"), month: month, fetchedAt: at, refreshStartedAt: at)
        let detail = cost.byModel.map(\.cents).reduce(0, +) + cost.otherCharges.map(\.cents).reduce(0, +)
        XCTAssertEqual(detail, cost.monthToDateCents)
        // The Console total for the same days, kept with the fixtures.
        let expected = Int(String(decoding: try fixture("anthropic-cost.expected-cents"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(APIMoney.roundedCents(cost.monthToDateCents), expected)
        // The real response has no Sep 27 bucket at 14:22Z → "through yesterday".
        XCTAssertEqual(cost.coversToday, false)
        _ = try AnthropicSpendDecoder.tokenReport(pages: try anthropicPages("anthropic-usage.pages.json"), month: month, fetchedAt: at, refreshStartedAt: at)
    }

    /// The real OpenAI amount tokens: every non-zero token
    /// decodes exactly; zero-significand tokens (`0E-6176`) are exact zero.
    func testOpenAIRealAmountTokensDecodeExactly() throws {
        struct Box: Decodable { let value: Decimal }
        let tokens = String(decoding: try fixture("openai-amount-tokens.txt"), as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        XCTAssertFalse(tokens.isEmpty)
        for token in tokens {
            let json = OpenAISpendDecoder.normalizingZeroExponents(Data(#"{"value":\#(token)}"#.utf8))
            let decoded = try JSONDecoder().decode(Box.self, from: json).value
            let expected = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) ?? 0
            XCTAssertEqual(decoded, token.uppercased().contains("E") && token.hasPrefix("0") ? 0 : expected, token)
        }
    }

    /// The real OpenAI costs page array decodes once zero exponents are normalized.
    func testOpenAIRealCostFixtureDecodesAfterNormalization() throws {
        struct Page: Decodable {
            struct Bucket: Decodable {
                struct Result: Decodable { struct Amount: Decodable { let value: Decimal }; let amount: Amount }
                let results: [Result]
            }
            let data: [Bucket]
        }
        let pages = try JSONDecoder().decode([Page].self, from: OpenAISpendDecoder.normalizingZeroExponents(try fixture("openai-costs.pages.json")))
        let dollars = pages.flatMap(\.data).flatMap(\.results).map(\.amount.value).reduce(0, +)
        XCTAssertEqual(APIMoney.roundedCents(dollars * 100), 1, "the OpenAI Usage page showed $0.01")
    }

    /// The real OpenAI response carries an (empty)
    /// bucket for Sep 27, so the card may say "today".
    func testOpenAIRealCostFixtureCoversToday() throws {
        let month = UTCMonth(year: 2026, month: 9)
        let at = ISO8601DateFormatter().date(from: "2026-09-27T14:16:00Z")!
        let raw = OpenAISpendDecoder.normalizingZeroExponents(try fixture("openai-costs.pages.json"))
        let pages = try (JSONSerialization.jsonObject(with: raw) as? [Any] ?? [])
            .map { try JSONSerialization.data(withJSONObject: $0) }
        let report = try OpenAISpendDecoder.costReport(pages: pages, month: month, fetchedAt: at, refreshStartedAt: at)
        XCTAssertEqual(report.coversToday, true)
        XCTAssertEqual(APIMoney.roundedCents(report.monthToDateCents), 1)
    }
}
