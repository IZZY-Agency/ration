import XCTest
@testable import Ration

/// A budget typed in the user's own number format.
final class APIBudgetInputTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let fr = Locale(identifier: "fr_FR")

    func testAcceptedForms() throws {
        XCTAssertEqual(try APIBudgetInput.cents(from: "600", locale: en).get(), 60_000)
        XCTAssertEqual(try APIBudgetInput.cents(from: "$600", locale: en).get(), 60_000)
        XCTAssertEqual(try APIBudgetInput.cents(from: "600.5", locale: en).get(), 60_050)
        XCTAssertEqual(try APIBudgetInput.cents(from: "1,000", locale: en).get(), 100_000)
        XCTAssertEqual(try APIBudgetInput.cents(from: "600,50", locale: fr).get(), 60_050)
        XCTAssertEqual(try APIBudgetInput.cents(from: "1 000", locale: fr).get(), 100_000)
        XCTAssertEqual(try APIBudgetInput.cents(from: "1\u{202F}000,5 $", locale: fr).get(), 100_050)
        XCTAssertEqual(try APIBudgetInput.cents(from: "1\u{00A0}000,5", locale: Locale(identifier: "uk_UA")).get(), 100_050)
        XCTAssertEqual(try APIBudgetInput.cents(from: "   ", locale: en).get(), nil)
    }

    func testRejectedNeverTruncated() {
        XCTAssertEqual(APIBudgetInput.cents(from: "600.505", locale: en), .failure(.unreadable))   // sub-cent
        XCTAssertEqual(APIBudgetInput.cents(from: "abc", locale: en), .failure(.unreadable))
        XCTAssertEqual(APIBudgetInput.cents(from: "-5", locale: en), .failure(.unreadable))
        XCTAssertEqual(APIBudgetInput.cents(from: "0", locale: en), .failure(.outOfRange))
        XCTAssertEqual(APIBudgetInput.cents(from: "10000000.01", locale: en), .failure(.outOfRange))
    }

    /// A grouping separator must group thousands — "12,34" is not $1,234.
    func testMalformedGroupingIsRefusedNotReinterpreted() {
        XCTAssertEqual(APIBudgetInput.cents(from: "12,34", locale: en), .failure(.unreadable))
        XCTAssertEqual(APIBudgetInput.cents(from: "1,0000", locale: en), .failure(.unreadable))
        XCTAssertEqual(APIBudgetInput.cents(from: "1 00", locale: fr), .failure(.unreadable))
        XCTAssertEqual(APIBudgetInput.cents(from: "1,,000", locale: en), .failure(.unreadable))
        XCTAssertEqual(try APIBudgetInput.cents(from: "1,000,000", locale: en).get(), 100_000_000)
        XCTAssertEqual(try APIBudgetInput.cents(from: "12,345.67", locale: en).get(), 1_234_567)
        XCTAssertEqual(try APIBudgetInput.cents(from: "1 000", locale: en).get(), 100_000)
    }

    func testMessages() {
        XCTAssertFalse(APIBudgetInputError.unreadable.message(locale: en).isEmpty)
        XCTAssertTrue(APIBudgetInputError.outOfRange.message(locale: en).contains("10,000,000"))
    }
}
