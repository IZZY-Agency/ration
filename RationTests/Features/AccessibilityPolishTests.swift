import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// What VoiceOver hears, and what reaches it without a hover: the drop's
/// announcement, spoken durations and window names instead of "4h 12m" /
/// "5H" / "WK", the exact reset time, and the quiet-hours header buttons.
@MainActor
final class AccessibilityPolishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func row(
        _ label: String = "Max",
        _ subject: AttentionRow.Subject = .window(.fiveHour),
        _ tier: AlertTier = .warning,
        account: UUID = UUID(),
        percent: Int? = 82,
        cents: Int? = nil,
        resets: TimeInterval? = 4 * 3600 + 12 * 60,
        count: Int? = nil
    ) -> AttentionRow {
        AttentionRow(
            accountID: account, accountLabel: label, provider: .claude, subject: subject, tier: tier,
            usedPercent: percent, spentCents: cents,
            thresholdPercent: percent == nil ? nil : 80, thresholdCents: cents == nil ? nil : 10_000,
            resetsAt: resets.map { now.addingTimeInterval($0) }, resetCount: count,
            resetCreditIDs: count == nil ? [] : ["credit-1"]
        )
    }

    // MARK: - C1 drop announcement

    func testDropAnnouncesWhenItAppears() {
        let rows = [row(), row("Pro", .window(.weekly), .critical)]
        let result = AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: [])
        XCTAssertEqual(result.announcement, "Nearing limits, 1 critical, 1 warning")
        XCTAssertEqual(result.announcement, AttentionDropView.headerAccessibilityLabel(rows: rows))
        XCTAssertEqual(result.seen, Set(rows.map(\.id)))
    }

    func testDropDoesNotReannounceTheSameRowsOnARefreshTick() {
        let rows = [row()]
        let first = AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: [])
        let tick = AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: first.seen)
        XCTAssertNil(tick.announcement)
        XCTAssertEqual(tick.seen, first.seen)
    }

    /// Escalation keeps the row's identity (the tier is not part of it), so it
    /// is an update in place — not a new row to announce.
    func testEscalationInPlaceIsNotANewAnnouncement() {
        let account = UUID()
        let warning = [row(account: account)]
        let seen = AttentionDropAnnouncement.evaluate(rows: warning, previouslySeen: []).seen
        let critical = [row("Max", .window(.fiveHour), .critical, account: account)]
        XCTAssertNil(AttentionDropAnnouncement.evaluate(rows: critical, previouslySeen: seen).announcement)
    }

    func testDropAnnouncesWhenItGainsARow() {
        let first = row()
        let seen = AttentionDropAnnouncement.evaluate(rows: [first], previouslySeen: []).seen
        let grown = [first, row("Pro", .window(.weekly), .critical)]
        let result = AttentionDropAnnouncement.evaluate(rows: grown, previouslySeen: seen)
        XCTAssertEqual(result.announcement, "Nearing limits, 1 critical, 1 warning")
        XCTAssertEqual(result.seen, Set(grown.map(\.id)))
    }

    /// Losing a row (the user dismissed it) is not news.
    func testDropStaysQuietWhenARowLeaves() {
        let a = row(), b = row("Pro")
        let seen = AttentionDropAnnouncement.evaluate(rows: [a, b], previouslySeen: []).seen
        let result = AttentionDropAnnouncement.evaluate(rows: [a], previouslySeen: seen)
        XCTAssertNil(result.announcement)
        XCTAssertEqual(result.seen, [a.id])
    }

    /// Closed → reset, so the next appearance of the same rows speaks again.
    func testClosingResetsSoTheNextAppearanceSpeaks() {
        let rows = [row()]
        let seen = AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: []).seen
        let closed = AttentionDropAnnouncement.evaluate(rows: [], previouslySeen: seen)
        XCTAssertNil(closed.announcement)
        XCTAssertEqual(closed.seen, [])
        XCTAssertNotNil(AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: closed.seen).announcement)
    }

    // MARK: - C2 spoken labels

    func testDropWindowRowSpeaksWordsNotAbbreviations() {
        let label = AttentionDropView.rowAccessibilityLabel(row(), now: now, locale: english)
        XCTAssertEqual(label, "Max, 5 hour, 82 percent used, warning, resets in 4 hours, 12 minutes")
        let weekly = AttentionDropView.rowAccessibilityLabel(
            row("Pro", .window(.weekly), .critical, percent: 96, resets: 6 * 86_400 + 3 * 3600),
            now: now, locale: english
        )
        XCTAssertEqual(weekly, "Pro, weekly, 96 percent used, critical, resets in 6 days, 3 hours")
        let fable = AttentionDropView.rowAccessibilityLabel(
            row("Max", .window(.modelWeekly), .critical, percent: 100, resets: nil), now: now, locale: english
        )
        XCTAssertEqual(fable, "Max, Fable weekly, 100 percent used, critical")
    }

    func testDropResetRowSpeaksItsExpiry() {
        let label = AttentionDropView.rowAccessibilityLabel(
            row("Team", .resetCredit(id: "credit-1", kind: .expiring), percent: nil, resets: 23 * 3600, count: 1),
            now: now, locale: english
        )
        XCTAssertEqual(label, "Team, 1 usage-limit reset expiring, expires in 23 hours")
    }

    func testLimitRowSpeaksWindowNameCountdownAndExactTime() {
        let window = UsageWindow(kind: .fiveHour, remainingFraction: 0.58, resetsAt: now.addingTimeInterval(4 * 3600 + 12 * 60))
        let label = LimitRowView.accessibilityDescription(
            title: "5h", kind: .fiveHour, window: window, now: now, locale: english, timeZone: utc
        )
        let exact = UsageFormatters.exactReset(now.addingTimeInterval(4 * 3600 + 12 * 60), locale: english, timeZone: utc)
        XCTAssertEqual(label, "5 hour, 42% used, resets in 4 hours, 12 minutes, at \(exact)")
        XCTAssertFalse(label.contains("5h"))

        let fable = UsageWindow(kind: .modelWeekly, remainingFraction: 1, resetsAt: nil, label: "Fable")
        XCTAssertEqual(
            LimitRowView.accessibilityDescription(title: "Fable", kind: .modelWeekly, window: fable, now: now, locale: english, timeZone: utc),
            "Fable weekly, 0% used, reset not scheduled"
        )
        XCTAssertEqual(
            LimitRowView.accessibilityDescription(title: "wk", kind: .weekly, window: nil, now: now, locale: english, timeZone: utc),
            "weekly, unavailable"
        )
    }

    func testSoonestResetLineSpeaksWords() {
        let next = SoonestReset(accountLabel: "Max", kind: .weekly, resetsAt: now.addingTimeInterval(45 * 60), label: nil)
        XCTAssertEqual(next.accessibilityLabel(now: now, locale: english), "Next reset, Max weekly, in 45 minutes")
        let fable = SoonestReset(accountLabel: "Max", kind: .modelWeekly, resetsAt: now.addingTimeInterval(3600), label: "Fable")
        XCTAssertEqual(fable.accessibilityLabel(now: now, locale: english), "Next reset, Max Fable weekly, in 1 hour")
    }

    func testResetCreditsLineSpeaksWords() {
        let summary = ResetCreditsSummary(
            totalCount: 3, soonestExpiry: now.addingTimeInterval(18 * 3600), withinLeadWindow: true, noneUsable: false
        )
        XCTAssertEqual(summary.accessibilityText(now: now, locale: english), "Usage-limit resets: 3, next expires in 18 hours")
        let unusable = ResetCreditsSummary(
            totalCount: 1, soonestExpiry: now.addingTimeInterval(18 * 3600), withinLeadWindow: true, noneUsable: true
        )
        XCTAssertEqual(unusable.accessibilityText(now: now, locale: english), "Usage-limit resets: 1, expires in 18 hours, not usable yet")
    }

    func testCursorSpendRowSpeaksWords() throws {
        let spend = CursorSpend(
            spentCents: 1_234, periodStart: now.addingTimeInterval(-86_400),
            resetsAt: now.addingTimeInterval(4 * 86_400 + 3 * 3600), planLabel: "Pro"
        )
        XCTAssertEqual(
            CursorSpendRow.accessibilityDescription(for: spend, now: now, locale: english),
            "Cursor spend, $12.34, Pro, this cycle, resets in 4 days, 3 hours"
        )
        XCTAssertEqual(CursorSpendRow.accessibilityDescription(for: nil, now: now, locale: english), "Cursor spend, unavailable")
    }

    // MARK: - C4 no tooltip-only information

    /// Clicking the countdown flips it to the absolute time, so the exact
    /// reset is reachable without a tooltip.
    func testLimitRowCaptionTogglesToTheAbsoluteTime() {
        let resetsAt = now.addingTimeInterval(4 * 3600 + 12 * 60)
        XCTAssertEqual(
            LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: false, locale: english, timeZone: utc),
            "4h 12m"
        )
        let exact = LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: true, locale: english, timeZone: utc)
        XCTAssertEqual(exact, UsageFormatters.shortReset(resetsAt, locale: english, timeZone: utc))
        XCTAssertNotEqual(exact, "4h 12m")
        XCTAssertTrue(exact.contains("Jan"), exact)
    }

    func testQuietHoursHeaderButtonsHaveSpokenLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = english
        XCTAssertEqual(QuietHoursGrid.dayToggleAccessibilityLabel(weekday: 2, calendar: calendar), "Toggle all Monday")
        XCTAssertEqual(QuietHoursGrid.dayToggleAccessibilityLabel(weekday: 1, calendar: calendar), "Toggle all Sunday")
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 9, locale: english), "Toggle all 9 AM")
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 0, locale: english), "Toggle all 12 AM")
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 15, locale: english), "Toggle all 3 PM")
        // 24-hour locales say the time, not a bare "09".
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 9, locale: Locale(identifier: "en_GB")), "Toggle all 09:00")
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 15, locale: Locale(identifier: "de_DE")), "Toggle all 15:00")
    }

    /// The Details toggle appears only when the capped text actually lost
    /// lines — never for a banner that fits.
    func testBannerDetailsOnlyWhenTheTextIsTruncated() {
        XCTAssertFalse(BannerDisclosure.isTruncated(fullHeight: 45, cappedHeight: 45))
        XCTAssertFalse(BannerDisclosure.isTruncated(fullHeight: 45.4, cappedHeight: 45))
        XCTAssertTrue(BannerDisclosure.isTruncated(fullHeight: 60, cappedHeight: 45))
    }
}
