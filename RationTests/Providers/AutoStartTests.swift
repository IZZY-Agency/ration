import Foundation
import XCTest
@testable import Ration

final class AutoStartPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func account(
        provider: Provider = .claude,
        enabled: Bool = true,
        lastAutoStartedAt: Date? = nil
    ) -> AccountRecord {
        AccountRecord(
            id: UUID(),
            provider: provider,
            label: "Test",
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: .distantPast,
            autoStartFiveHour: enabled,
            keepAliveConversationID: nil,
            lastAutoStartedAt: lastAutoStartedAt
        )
    }

    private func window(resetsInSeconds seconds: TimeInterval?) -> UsageWindow? {
        guard let seconds else { return nil }
        return UsageWindow(
            kind: .fiveHour,
            remainingFraction: 1,
            resetsAt: now.addingTimeInterval(seconds)
        )
    }

    // MARK: Quiet hours / holidays

    /// A FIXED zone — never the machine's.
    private func quietCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    /// A fresh, unused window — the state that normally fires.
    private func notStartedWindow() -> UsageWindow {
        UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil)
    }

    func testQuietCellBlocksAnOtherwiseFiringAccount() {
        let cal = quietCalendar()
        // 2026-07-15 is a Wednesday (weekday 4); block 03:00.
        let at3am = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 3))!
        let schedule = WarmUpQuietSchedule(
            quietCells: [WarmUpQuietSchedule.cellIndex(weekday: 4, hour: 3)]
        )
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            now: at3am,
            schedule: schedule,
            calendar: cal
        ))
    }

    func testOutsideQuietHoursStillFires() {
        let cal = quietCalendar()
        let at9am = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9))!
        let schedule = WarmUpQuietSchedule(
            quietCells: [WarmUpQuietSchedule.cellIndex(weekday: 4, hour: 3)]
        )
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            now: at9am,
            schedule: schedule,
            calendar: cal
        ))
    }

    func testHolidayBlocks() {
        let cal = quietCalendar()
        let during = cal.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 9))!
        let schedule = WarmUpQuietSchedule(holidays: [
            HolidayRange(
                start: LocalDate(year: 2026, month: 8, day: 1),
                end: LocalDate(year: 2026, month: 8, day: 14),
                label: "Vacation"
            )
        ])
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            now: during,
            schedule: schedule,
            calendar: cal
        ))
    }

    /// Regression: the default `.allowAll` must preserve pre-quiet-hours behavior.
    func testAllowAllPreservesExistingBehavior() {
        let cal = quietCalendar()
        let at3am = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 3))!
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            now: at3am
        ))
    }

    /// Quiet hours must NOT permanently suppress: the gate never records a send,
    /// so once the quiet period ends every eligible account is allowed again.
    /// (Scope: the pure policy only. That several accounts therefore un-gate on
    /// the same refresh — the documented, accepted v1 concurrent release — is a
    /// property of `refreshAll`, not of this predicate.)
    func testPolicyAllowsEveryEligibleAccountOnceQuietEnds() {
        let cal = quietCalendar()
        let at9am = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9))!
        let schedule = WarmUpQuietSchedule(
            quietCells: [WarmUpQuietSchedule.cellIndex(weekday: 4, hour: 3)]
        )
        for _ in 0..<3 {
            XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
                account: account(),
                fiveHour: notStartedWindow(),
                now: at9am,
                schedule: schedule,
                calendar: cal
            ))
        }
    }

    func testQuietHoursDoNotOverrideMinimumInterval() {
        let cal = quietCalendar()
        let at9am = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9))!
        // Fired 10 minutes ago — still inside `minimumInterval`, so no fire even
        // though we are outside quiet hours.
        let recent = account(lastAutoStartedAt: at9am.addingTimeInterval(-600))
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: recent,
            fiveHour: notStartedWindow(),
            now: at9am,
            schedule: WarmUpQuietSchedule(),
            calendar: cal
        ))
    }

    // MARK: Weekly allowance gate

    private func weekly(remaining: Double, resetsInSeconds: TimeInterval? = 6 * 3600) -> UsageWindow {
        UsageWindow(
            kind: .weekly,
            remainingFraction: remaining,
            resetsAt: resetsInSeconds.map(now.addingTimeInterval)
        )
    }

    /// The reported bug: an account whose weekly allowance is spent cannot
    /// accept ANY message, so firing warm-up burns the once-per-window
    /// reservation on a POST Claude is certain to reject — and leaves a red
    /// failure banner behind. Never attempt it.
    func testSpentWeeklyAllowanceBlocksAnOtherwiseFiringAccount() {
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            weekly: weekly(remaining: 0),
            now: now
        ))
    }

    func testSpentWeeklyAllowanceIsReportedAsBlockedNotSkipped() {
        XCTAssertEqual(
            AutoStartPolicy.decide(
                account: account(),
                fiveHour: notStartedWindow(),
                weekly: weekly(remaining: 0),
                now: now
            ),
            .blockedByWeeklyLimit(resetsAt: now.addingTimeInterval(6 * 3600)),
            "the UI needs to tell the spent-allowance case apart from having nothing to do"
        )
    }

    /// `blocked` means "this is the ONLY thing in the way". A running 5h window
    /// had nothing to do regardless, so it is a plain skip — otherwise the UI
    /// would claim warm-up is being held back when it isn't.
    func testARunningWindowIsASkipEvenWhenTheWeeklyAllowanceIsSpent() {
        XCTAssertEqual(
            AutoStartPolicy.decide(
                account: account(),
                fiveHour: window(resetsInSeconds: 3600),
                weekly: weekly(remaining: 0),
                now: now
            ),
            .skip
        )
    }

    func testOnePercentOfWeeklyHeadroomStillFires() {
        // Claude reports whole percents: 1% left is a real, sendable remainder.
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            weekly: weekly(remaining: 0.01),
            now: now
        ))
    }

    /// Pins the threshold itself, not just the two values Claude reports today:
    /// half a percent is the line, so a 0.4%-remaining report is spent and a
    /// 0.6% one is not. Without this a 0.009 or 0.001 threshold would pass.
    func testTheSpentThresholdSitsHalfwayThroughTheReportingQuantum() {
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            weekly: weekly(remaining: 0.004),
            now: now
        ))
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            weekly: weekly(remaining: 0.006),
            now: now
        ))
    }

    /// Fail OPEN on an unknown weekly window: that is the pre-gate behavior, and
    /// a provider that reports no weekly window (or a fetch that dropped it)
    /// must not silently disable warm-up.
    func testUnknownWeeklyWindowStillFires() {
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: notStartedWindow(),
            weekly: nil,
            now: now
        ))
    }

    func testDisabledOrNonClaudeNeverFires() {
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(enabled: false), fiveHour: nil, now: now
        ))
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(provider: .chatGPT), fiveHour: nil, now: now
        ))
    }

    func testFiresOnlyWhenWindowDefinitelyEnded() {
        // A present window whose reset already passed → fire.
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(), fiveHour: window(resetsInSeconds: -60), now: now
        ))
    }

    func testFiresOnNotStartedWindow() {
        // The observed "not started" state: present, unused, no scheduled reset.
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
            now: now
        ))
    }

    func testNotStartedBoundaryAtOnePercent() {
        // Exactly 1% used (remainingFraction 0.99) still counts as not-started.
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.99, resetsAt: nil),
            now: now
        ))
        // 2% used → meaningful usage → do not fire.
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.98, resetsAt: nil),
            now: now
        ))
    }

    func testFailsClosedOnUnknownOrUsedNullResetWindow() {
        // Absent window → unknown → do NOT fire.
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(), fiveHour: nil, now: now
        ))
        // Null reset but the window already has usage → do NOT disturb it.
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            now: now
        ))
    }

    func testDoesNotFireWhenWindowIsActive() {
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(),
            fiveHour: window(resetsInSeconds: 3600),
            now: now
        ))
    }

    func testDoesNotRefireWithinMinimumInterval() {
        let justSent = now.addingTimeInterval(-60)
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: account(lastAutoStartedAt: justSent),
            fiveHour: window(resetsInSeconds: -60),
            now: now
        ))
    }

    func testFiresAgainAfterMinimumIntervalElapses() {
        let longAgo = now.addingTimeInterval(-(AutoStartPolicy.minimumInterval + 60))
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(
            account: account(lastAutoStartedAt: longAgo),
            fiveHour: window(resetsInSeconds: -60),
            now: now
        ))
    }

    func testPausedAccountNeverFires() {
        let paused = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Test",
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: .distantPast,
            autoStartFiveHour: true,
            isPaused: true
        )
        // Both normally-firing states: ended window, and fresh not-started window.
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: paused,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0, resetsAt: now.addingTimeInterval(-60)),
            now: now
        ))
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(
            account: paused,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
            now: now
        ))
    }

    func testEffectiveAutoStartCountExcludesPausedAndNonClaudeAndDisabled() {
        func record(
            provider: Provider = .claude,
            enabled: Bool = true,
            paused: Bool = false
        ) -> AccountRecord {
            AccountRecord(
                id: UUID(),
                provider: provider,
                label: "Test",
                webProfileID: UUID(),
                displayOrder: 0,
                createdAt: .distantPast,
                autoStartFiveHour: enabled,
                isPaused: paused
            )
        }
        XCTAssertEqual(
            AutoStartPolicy.effectiveAutoStartCount([
                record(),                                  // counted
                record(paused: true),                      // paused → excluded
                record(enabled: false),                    // disabled → excluded
                record(provider: .chatGPT),                // non-Claude → excluded
                record(),                                  // counted
            ]),
            2
        )
        XCTAssertEqual(AutoStartPolicy.effectiveAutoStartCount([]), 0)
    }
}

final class AccountRecordAutoStartDecodingTests: XCTestCase {
    func testDecodesOlderRecordsWithoutAutoStartFields() throws {
        // A pre-feature accounts.json entry lacks the new keys.
        let json = """
        {
            "id": "123E4567-E89B-12D3-A456-426614174000",
            "provider": "claude",
            "label": "Legacy",
            "webProfileID": "223E4567-E89B-12D3-A456-426614174000",
            "displayOrder": 0,
            "createdAt": "2026-07-13T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(AccountRecord.self, from: Data(json.utf8))

        XCTAssertFalse(record.autoStartFiveHour)
        XCTAssertNil(record.keepAliveConversationID)
        XCTAssertNil(record.lastAutoStartedAt)
    }

    func testRoundTripsAutoStartFields() throws {
        let original = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Test",
            webProfileID: UUID(),
            displayOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            autoStartFiveHour: true,
            keepAliveConversationID: UUID(),
            lastAutoStartedAt: Date(timeIntervalSince1970: 2_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            AccountRecord.self,
            from: try encoder.encode(original)
        )
        XCTAssertEqual(decoded, original)
    }
}

@MainActor
final class AccountStoreAutoStartTests: XCTestCase {
    func testSetAndRecordAutoStartPersist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "accounts.json")

        let account = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Test",
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: .distantPast
        )
        let store = AccountStore(fileURL: fileURL)
        try await store.load()
        try await store.add(account)

        try await store.setAutoStart(id: account.id, enabled: true)
        XCTAssertEqual(store.accounts.first?.autoStartFiveHour, true)

        let conversation = UUID()
        let firedAt = Date(timeIntervalSince1970: 5_000)
        try await store.recordAutoStart(
            id: account.id,
            conversationID: conversation,
            at: firedAt
        )

        // Reload from disk to prove persistence.
        let reloaded = AccountStore(fileURL: fileURL)
        try await reloaded.load()
        let restored = try XCTUnwrap(reloaded.accounts.first)
        XCTAssertTrue(restored.autoStartFiveHour)
        XCTAssertEqual(restored.keepAliveConversationID, conversation)
        XCTAssertEqual(restored.lastAutoStartedAt, firedAt)
    }
}
