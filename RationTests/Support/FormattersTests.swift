import XCTest
@testable import Ration

final class FormattersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func remaining(_ seconds: TimeInterval) -> String {
        UsageFormatters.remainingUntilReset(
            now.addingTimeInterval(seconds),
            relativeTo: now
        )
    }

    func testRemainingUntilResetFormatsEachRange() {
        XCTAssertEqual(remaining(-30), "now")
        XCTAssertEqual(remaining(0), "now")
        XCTAssertEqual(remaining(45 * 60), "45m")
        XCTAssertEqual(remaining(60 * 60), "1h")
        XCTAssertEqual(remaining(4 * 3600 + 12 * 60), "4h 12m")
        XCTAssertEqual(remaining(23 * 3600 + 59 * 60), "23h 59m")
        XCTAssertEqual(remaining(24 * 3600), "1d")
        XCTAssertEqual(remaining(6 * 24 * 3600 + 3 * 3600), "6d 3h")
        XCTAssertEqual(remaining(7 * 24 * 3600), "7d")
    }
}
