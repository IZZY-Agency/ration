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

    private func creditRemaining(_ seconds: TimeInterval) -> String {
        UsageFormatters.resetCreditRemaining(
            now.addingTimeInterval(seconds),
            relativeTo: now
        )
    }

    /// Coarser than `remainingUntilReset` on purpose: whole days from 24 h
    /// up, whole hours below that, floored — never rounded up. A reset row
    /// lives for weeks, and "29d 7h" is noise that also truncates in the drop.
    func testResetCreditRemainingFormatsEachRange() {
        XCTAssertEqual(creditRemaining(-30), "now")
        XCTAssertEqual(creditRemaining(0), "now")
        XCTAssertEqual(creditRemaining(30 * 60), "<1h")
        XCTAssertEqual(creditRemaining(60 * 60), "1h")
        XCTAssertEqual(creditRemaining(23 * 3600 + 59 * 60), "23h")
        XCTAssertEqual(creditRemaining(24 * 3600), "1d")
        XCTAssertEqual(creditRemaining(29 * 24 * 3600 + 7 * 3600), "29d")
    }

    private let english = Locale(identifier: "en_US")

    private func spoken(_ seconds: TimeInterval) -> String {
        UsageFormatters.spokenDuration(
            until: now.addingTimeInterval(seconds),
            relativeTo: now,
            locale: english
        )
    }

    /// VoiceOver must hear words, not "4h 12m". Same units and flooring as
    /// the visual countdown, so the two never disagree about the time left.
    func testSpokenDurationUsesFullUnitsMatchingTheVisualCountdown() {
        XCTAssertEqual(spoken(-30), "now")
        XCTAssertEqual(spoken(0), "now")
        XCTAssertEqual(spoken(30), "less than a minute")
        XCTAssertEqual(spoken(60), "1 minute")
        XCTAssertEqual(spoken(45 * 60 + 59), "45 minutes")
        XCTAssertEqual(spoken(60 * 60), "1 hour")
        XCTAssertEqual(spoken(4 * 3600 + 12 * 60 + 30), "4 hours, 12 minutes")
        XCTAssertEqual(spoken(23 * 3600 + 59 * 60), "23 hours, 59 minutes")
        XCTAssertEqual(spoken(24 * 3600), "1 day")
        XCTAssertEqual(spoken(6 * 24 * 3600 + 3 * 3600 + 45 * 60), "6 days, 3 hours")
        XCTAssertEqual(spoken(7 * 24 * 3600), "7 days")
    }

    func testSpokenWindowNames() {
        XCTAssertEqual(UsageWindowKind.fiveHour.spokenName(), "5 hour")
        XCTAssertEqual(UsageWindowKind.weekly.spokenName(), "weekly")
        XCTAssertEqual(UsageWindowKind.modelWeekly.spokenName(), "Fable weekly")
        XCTAssertEqual(UsageWindowKind.modelWeekly.spokenName(label: "Opus"), "Opus weekly")
        // Only the model window takes the API label; the others are fixed.
        XCTAssertEqual(UsageWindowKind.weekly.spokenName(label: "Opus"), "weekly")
    }
}
