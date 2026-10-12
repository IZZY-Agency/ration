import XCTest
@testable import Ration

/// The popover's keep-awake wording in English: the footer button, its
/// duration menu, the time left and the banner per status. French and
/// Ukrainian live in `PopoverCopyLocalizationTests`.
final class KeepAwakeCopyTests: XCTestCase {
    private let nnb = "\u{202F}"
    /// 2026-10-11 15:40:00 UTC.
    private let until = Date(timeIntervalSince1970: 1_791_733_200)
    private let utc = TimeZone(identifier: "UTC")!

    func testDurationsInMenuOrderWithTheirSeconds() {
        XCTAssertEqual(
            KeepAwakeDuration.allCases,
            [.minutes30, .hours1, .hours2, .hours4, .hours8, .untilOff]
        )
        XCTAssertEqual(KeepAwakeDuration.allCases.map(\.seconds), [1_800, 3_600, 7_200, 14_400, 28_800, nil])
        XCTAssertEqual(
            KeepAwakeDuration.allCases.map { $0.title(locale: L10n.en) },
            ["30 minutes", "1 hour", "2 hours", "4 hours", "8 hours", "Until I turn it off"]
        )
    }

    func testButtonAndStopTitles() {
        XCTAssertEqual(KeepAwakeCopy.buttonLabel(locale: L10n.en), "Keep awake")
        XCTAssertEqual(KeepAwakeCopy.stopTitle(locale: L10n.en), "Turn off")
        XCTAssertEqual(KeepAwakeCopy.offInSettings(locale: L10n.en), "Keep awake is off in Settings")
    }

    /// The footer's eye: dim and dead while the switch is off in Settings,
    /// cream-dim at rest, gold while a hold is live.
    func testFooterTintFollowsTheSwitchAndTheHold() {
        XCTAssertEqual(MenuBarView.keepAwakeTint(.off, available: false), Theme.creamFaint)
        XCTAssertEqual(MenuBarView.keepAwakeTint(.off, available: true), Theme.creamDim)
        XCTAssertEqual(MenuBarView.keepAwakeTint(.automatic, available: true), Theme.gold)
        XCTAssertEqual(MenuBarView.keepAwakeTint(.manual(until: nil), available: true), Theme.gold)
    }

    func testTimeLeftUsesTheCompactCountdown() {
        let now = until.addingTimeInterval(-(3_600 + 12 * 60))
        XCTAssertEqual(KeepAwakeCopy.timeLeft(until: until, now: now, locale: L10n.en), "1h 12m left")
        XCTAssertEqual(KeepAwakeCopy.timeLeft(until: until, now: until.addingTimeInterval(-45), locale: L10n.en), "0m left")
    }

    func testBannerPerStatus() {
        XCTAssertNil(KeepAwakeCopy.banner(.off, locale: L10n.en, timeZone: utc))
        XCTAssertEqual(
            KeepAwakeCopy.banner(.automatic, locale: L10n.en, timeZone: utc),
            "Mac kept awake while an account is in use"
        )
        XCTAssertEqual(
            KeepAwakeCopy.banner(.manual(until: until), locale: L10n.en, timeZone: utc),
            "Mac kept awake until 3:40\(nnb)PM"
        )
        XCTAssertEqual(
            KeepAwakeCopy.banner(.manual(until: nil), locale: L10n.en, timeZone: utc),
            "Mac kept awake until you turn it off"
        )
    }

    /// The footer glyph fills while a hold is live, whatever its source.
    func testFooterGlyphFillsWhileHeld() {
        XCTAssertEqual(MenuBarView.keepAwakeGlyph(.off), "eye")
        XCTAssertEqual(MenuBarView.keepAwakeGlyph(.automatic), "eye.fill")
        XCTAssertEqual(MenuBarView.keepAwakeGlyph(.manual(until: nil)), "eye.fill")
        XCTAssertEqual(MenuBarView.keepAwakeGlyph(.manual(until: until)), "eye.fill")
    }
}
