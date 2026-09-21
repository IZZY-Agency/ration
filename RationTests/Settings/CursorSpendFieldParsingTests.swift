import XCTest
@testable import Ration

/// `CursorSpendFieldParsing.parsedCents` guards a real crash: a large finite
/// `Double` (roughly ≥ 9.2e16, e.g. from a pasted 17+ digit figure) overflows
/// `Int` and TRAPS on `Int(...)`, not just returns nil. These tests pin the
/// range check that runs BEFORE that conversion.
final class CursorSpendFieldParsingTests: XCTestCase {
    func testBlankTextTurnsTheTierOff() {
        // Outer .some, inner nil: parseable-and-deliberately-off, distinct
        // from "couldn't be read at all" (outer nil).
        XCTAssertEqual(CursorSpendFieldParsing.parsedCents("   "), .some(nil))
    }

    func testOrdinaryDollarFigureParsesToCents() {
        XCTAssertEqual(CursorSpendFieldParsing.parsedCents("12.34"), .some(1234))
    }

    func testGarbageTextIsRejectedNotZeroed() {
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("abc"))
    }

    // The actual crash reproduction: a pasted, absurdly large but still
    // finite figure must not reach `Int(...)` at all. Before the fix, this
    // input trapped the process instead of returning a value.
    func testHugePastedFigureIsRejectedNotConvertedAndDoesNotCrash() {
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("99999999999999999999"))
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("9.2e16"))
    }

    func testNegativeFigureIsRejected() {
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("-5"))
    }

    func testFigureAtTheBoundIsRejectedExclusive() {
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("1000000"))
        XCTAssertNotNil(CursorSpendFieldParsing.parsedCents("999999.99"))
    }

    func testDollarsTextRoundTripsCents() {
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 1234), "12.34")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: nil), "")
    }
}
