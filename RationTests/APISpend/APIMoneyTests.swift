import XCTest
@testable import Ration

final class APIMoneyTests: XCTestCase {
    func testAnthropicCentsStringParsesExactly() throws {
        XCTAssertEqual(try APIMoney.anthropicCents("123.78912"), Decimal(string: "123.78912"))
        XCTAssertEqual(try APIMoney.anthropicCents("0"), 0)
    }

    func testAnthropicRejectsNonPlainDecimalText() {
        for bad in ["-1", "1e5", "NaN", " 1", "12abc", "1.2.3", ""] {
            XCTAssertThrowsError(try APIMoney.anthropicCents(bad), bad) { error in
                XCTAssertEqual(error as? APISpendError, .integrationChanged(.amountOutOfRange))
            }
        }
    }

    func testAnthropicRejectsMoreThanTwelveFractionDigits() {
        XCTAssertNoThrow(try APIMoney.anthropicCents("1.123456789012"))
        XCTAssertThrowsError(try APIMoney.anthropicCents("1.1234567890123"))
    }

    func testOpenAIDollarsBecomeCents() throws {
        XCTAssertEqual(try APIMoney.openAICents(dollars: Decimal(string: "0.06")!), 6)
        XCTAssertEqual(try APIMoney.openAICents(dollars: Decimal(string: "1.2378912")!), Decimal(string: "123.78912"))
    }

    func testResultAboveOneMillionDollarsIsRejected() {
        XCTAssertNoThrow(try APIMoney.openAICents(dollars: 1_000_000))
        XCTAssertThrowsError(try APIMoney.openAICents(dollars: Decimal(string: "1000000.01")!))
        XCTAssertThrowsError(try APIMoney.anthropicCents("100000000.5"))
    }

    func testMonthTotalCap() {
        XCTAssertNoThrow(try APIMoney.checkMonthTotal(1_000_000_000))
        XCTAssertThrowsError(try APIMoney.checkMonthTotal(Decimal(string: "1000000000.01")!))
    }

    func testRoundingAndFlooring() {
        XCTAssertEqual(APIMoney.roundedCents(Decimal(string: "100.5")!), 101)
        XCTAssertEqual(APIMoney.roundedCents(Decimal(string: "100.49")!), 100)
        XCTAssertEqual(APIMoney.flooredCents(Decimal(string: "100.6")!), 100)
    }

    func testPercentDirections() {
        let exact = APIMoney.exactPercent(spentCents: Decimal(string: "46920")!, budgetCents: 60_000) // 78.2 %
        XCTAssertEqual(APIMoney.wholePercent(exact, .plain), 78)
        XCTAssertEqual(APIMoney.wholePercent(exact, .down), 78)
        XCTAssertEqual(APIMoney.wholePercent(100 - exact, .up), 22) // "at most 22 % left"
        let over = APIMoney.exactPercent(spentCents: 67_200, budgetCents: 60_000)
        XCTAssertEqual(APIMoney.wholePercent(over, .plain), 112)
    }

    func testFractionDigitsIgnoresTrailingZeros() {
        XCTAssertEqual(APIMoney.fractionDigits(Decimal(string: "1.50")!), 1)
        XCTAssertEqual(APIMoney.fractionDigits(Decimal(string: "0.0000001")!), 7)
        XCTAssertEqual(APIMoney.fractionDigits(5), 0)
    }
}
