import XCTest
@testable import Ration

/// The attention drop is DERIVED, never an event queue: `rows` answers "what
/// is over a threshold right now" from live state on every tick. That is what
/// makes it self-retracting — a window that resets overnight simply stops
/// producing a row, with nothing having to remember to withdraw it.
///
/// A row exists iff ALL seven conditions hold; there is one test per condition
/// asserting its absence removes the row, so no condition can be dropped
/// silently.
@MainActor
final class AttentionDropModelTests: XCTestCase {
    private let accountID = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Fixtures

    private func account(
        provider: Provider = .claude,
        paused: Bool = false,
        label: String = "Personal"
    ) -> AccountRecord {
        AccountRecord(
            id: accountID,
            provider: provider,
            label: label,
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            isPaused: paused
        )
    }

    /// 95% used on the weekly window — over the 90% default critical.
    private func snapshot(
        weeklyUsed: Double = 0.95,
        fetchedAt: Date? = nil,
        resetsAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: fetchedAt ?? now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: UsageWindow(
                kind: .weekly,
                remainingFraction: 1 - weeklyUsed,
                resetsAt: resetsAt ?? now.addingTimeInterval(3_600)
            )
        )
    }

    private func presentation(
        account: AccountRecord? = nil,
        snapshot: UsageSnapshot? = nil,
        state: AccountViewState = .current
    ) -> AccountPresentation {
        AccountPresentation(
            account: account ?? self.account(),
            snapshot: snapshot ?? self.snapshot(),
            state: state
        )
    }

    /// Alerts on, and the drop channel enabled for Claude's weekly cell.
    private func settings(
        alertsEnabled: Bool = true,
        drop: Bool = true,
        thresholds: ThresholdPair = .default
    ) -> AppSettingsData {
        var data = AppSettingsData()
        data.usageAlertsEnabled = alertsEnabled
        let key = AppSettingsData.thresholdKey(provider: .claude, window: .weekly)
        data.alertThresholds[key] = thresholds
        data.alertChannels[key] = AlertChannels(notification: true, drop: drop)
        return data
    }

    private func rows(
        presentations: [AccountPresentation]? = nil,
        settings: AppSettingsData? = nil,
        alertStates: [UUID: AccountAlertState] = [:],
        schedule: WarmUpQuietSchedule = .allowAll,
        now: Date? = nil
    ) -> [AttentionRow] {
        AttentionDropModel.rows(
            presentations: presentations ?? [presentation()],
            settings: settings ?? self.settings(),
            alertStates: alertStates,
            schedule: schedule,
            now: now ?? self.now,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    // MARK: - The row itself

    func testACrossingProducesOneRowCarryingItsDisplayFacts() throws {
        let result = rows()
        XCTAssertEqual(result.count, 1)
        let row = try XCTUnwrap(result.first)
        XCTAssertEqual(row.accountID, accountID)
        XCTAssertEqual(row.subject, .window(.weekly))
        XCTAssertEqual(row.tier, .critical)
        XCTAssertEqual(row.usedPercent, 95)
        XCTAssertEqual(row.accountLabel, "Personal")
        XCTAssertNil(row.spentCents)
    }

    /// Identity is `(account, subject)` and deliberately EXCLUDES the tier, so
    /// a warning escalating to critical updates one row in place instead of
    /// adding a second.
    func testRowIdentityExcludesTierSoEscalationUpdatesInPlace() {
        let warning = AttentionRow(
            accountID: accountID, accountLabel: "Personal", provider: .claude,
            subject: .window(.weekly), tier: .warning,
            usedPercent: 80, spentCents: nil, thresholdPercent: 75,
            thresholdCents: nil, resetsAt: nil, resetCount: nil, resetCreditIDs: []
        )
        let critical = AttentionRow(
            accountID: accountID, accountLabel: "Personal", provider: .claude,
            subject: .window(.weekly), tier: .critical,
            usedPercent: 95, spentCents: nil, thresholdPercent: 90,
            thresholdCents: nil, resetsAt: nil, resetCount: nil, resetCreditIDs: []
        )
        XCTAssertEqual(warning.id, critical.id)
        XCTAssertNotEqual(warning, critical)
    }

    // MARK: - Condition 1: the master switch

    func testNoRowsWhenUsageAlertsAreDisabled() {
        XCTAssertTrue(rows(settings: settings(alertsEnabled: false)).isEmpty)
    }

    // MARK: - Condition 2: the account is visible

    func testNoRowForAPausedAccount() {
        let paused = presentation(account: account(paused: true))
        XCTAssertTrue(rows(presentations: [paused]).isEmpty)
    }

    // MARK: - Condition 3: the snapshot is current evidence

    func testNoRowWhenTheSnapshotIsTooOld() {
        let stale = snapshot(fetchedAt: now.addingTimeInterval(-UsageEvidence.maxAge - 1))
        XCTAssertTrue(rows(presentations: [presentation(snapshot: stale)]).isEmpty)
    }

    /// The age bound alone is not enough: a snapshot taken before a reset that
    /// has since passed would otherwise assert a limit that already renewed.
    func testNoRowWhenTheSnapshotWasOvertakenByItsOwnReset() {
        let passed = now.addingTimeInterval(-60)
        let overtaken = snapshot(
            fetchedAt: passed.addingTimeInterval(-120),
            resetsAt: passed
        )
        XCTAssertTrue(rows(presentations: [presentation(snapshot: overtaken)]).isEmpty)
    }

    func testNoRowWhenThereIsNoSnapshotAtAll() {
        let none = AccountPresentation(account: account(), snapshot: nil, state: .loading)
        XCTAssertTrue(rows(presentations: [none]).isEmpty)
    }

    /// Deliberate: `AccountViewState` is NOT a condition. Snapshot age, not
    /// view state, is the authority on whether a number still speaks for now —
    /// a transient fetch failure must not blank a row still backed by fresh
    /// data, and a genuinely stale row is already retracted by condition 3.
    func testRowSurvivesAReauthenticationRequiredState() {
        let reauth = presentation(state: .reauthenticationRequired)
        XCTAssertEqual(rows(presentations: [reauth]).count, 1)
    }

    // MARK: - Condition 4: the drop channel

    func testNoRowWhenTheDropChannelIsOffForThatCell() {
        XCTAssertTrue(rows(settings: settings(drop: false)).isEmpty)
    }

    // MARK: - Condition 5: at or above a configured tier

    func testNoRowBelowTheConfiguredWarning() {
        let under = presentation(snapshot: snapshot(weeklyUsed: 0.50))
        XCTAssertTrue(rows(presentations: [under]).isEmpty)
    }

    func testRowUsesTheConfiguredThresholdNotTheDefault() throws {
        let lowered = settings(thresholds: ThresholdPair(warningPercent: 40, criticalPercent: 90))
        let under = presentation(snapshot: snapshot(weeklyUsed: 0.45))
        let row = try XCTUnwrap(rows(presentations: [under], settings: lowered).first)
        XCTAssertEqual(row.tier, .warning)
        XCTAssertEqual(row.thresholdPercent, 40, "the row carries the number the user configured")
    }

    /// Exactly at the boundary counts — matching `AlertTier.forUsed`.
    func testRowAtExactlyTheConfiguredThreshold() throws {
        let exact = presentation(snapshot: snapshot(weeklyUsed: 0.90))
        let row = try XCTUnwrap(rows(presentations: [exact]).first)
        XCTAssertEqual(row.tier, .critical)
    }

    // MARK: - Condition 6: not dismissed

    func testNoRowForATierTheUserDismissed() {
        var state = AccountAlertState()
        state.weekly.dismissedTier = .critical
        XCTAssertTrue(rows(alertStates: [accountID: state]).isEmpty)
    }

    /// Dismissing a warning must not hide a later critical — the dismissal is
    /// per tier, and `critical > warning`.
    func testEscalationAboveADismissedWarningStillProducesARow() throws {
        var state = AccountAlertState()
        state.weekly.dismissedTier = .warning
        let row = try XCTUnwrap(rows(alertStates: [accountID: state]).first)
        XCTAssertEqual(row.tier, .critical)
    }

    /// ...but a dismissed CRITICAL also covers the warning beneath it.
    func testDismissedCriticalAlsoSuppressesAWarningRow() {
        var state = AccountAlertState()
        state.weekly.dismissedTier = .critical
        let warningLevel = presentation(snapshot: snapshot(weeklyUsed: 0.80))
        XCTAssertTrue(rows(presentations: [warningLevel], alertStates: [accountID: state]).isEmpty)
    }

    // MARK: - Condition 7: quiet hours

    func testNoRowsDuringQuietHours() {
        let calendar = Calendar(identifier: .gregorian)
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let schedule = WarmUpQuietSchedule(
            quietCells: [WarmUpQuietSchedule.cellIndex(weekday: weekday, hour: hour)]
        )
        XCTAssertTrue(rows(schedule: schedule).isEmpty)
    }

    // MARK: - Ordering and multiplicity

    /// Critical before warning, so the worst thing is at the top; the panel
    /// renders in exactly this order.
    func testRowsAreOrderedCriticalFirst() {
        let other = UUID()
        let warnAccount = AccountRecord(
            id: other, provider: .claude, label: "Work",
            webProfileID: UUID(), displayOrder: 1,
            createdAt: Date(timeIntervalSince1970: 0), isPaused: false
        )
        let warnSnapshot = UsageSnapshot(
            accountID: other,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.2, resetsAt: nil)
        )
        let result = rows(presentations: [
            AccountPresentation(account: warnAccount, snapshot: warnSnapshot, state: .current),
            presentation(),
        ])
        XCTAssertEqual(result.map(\.tier), [.critical, .warning])
    }

    /// One account crossing on two windows yields two rows — the subject is
    /// part of the identity.
    func testTwoWindowsOnOneAccountProduceTwoRows() {
        var data = settings()
        let fableKey = AppSettingsData.thresholdKey(provider: .claude, window: .modelWeekly)
        data.alertThresholds[fableKey] = .default
        data.alertChannels[fableKey] = AlertChannels(notification: true, drop: true)

        let both = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.09, resetsAt: nil),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.22, resetsAt: nil, label: "Fable")
        )
        let result = rows(presentations: [presentation(snapshot: both)], settings: data)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.subject)), [.window(.weekly), .window(.modelWeekly)])
    }

    // MARK: - Cursor spend

    func testCursorSpendOverItsThresholdProducesARow() throws {
        var data = AppSettingsData()
        data.usageAlertsEnabled = true
        data.cursorSpend = SpendThresholds(warningCents: 5_000, criticalCents: 10_000)
        data.alertChannels[AppSettingsData.cursorSpendKey] =
            AlertChannels(notification: true, drop: true)

        let cursor = AccountRecord(
            id: accountID, provider: .cursor, label: "Cursor",
            webProfileID: UUID(), displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0), isPaused: false
        )
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: now.addingTimeInterval(-86_400 * 10),
                resetsAt: now.addingTimeInterval(86_400),
                planLabel: "Pro"
            )
        )
        let result = rows(
            presentations: [AccountPresentation(account: cursor, snapshot: snap, state: .current)],
            settings: data
        )
        let row = try XCTUnwrap(result.first)
        XCTAssertEqual(row.subject, .cursorSpend)
        XCTAssertEqual(row.tier, .warning)
        XCTAssertEqual(row.spentCents, 7_500)
        XCTAssertEqual(row.thresholdCents, 5_000)
        XCTAssertNil(row.usedPercent, "spend has no denominator, so there is no percentage")
    }

    /// Live-observed 2026-08-27: Cursor reports `periodEndMs` as the fetch
    /// time for the open invoice. A "reset" that has already passed is not a
    /// countdown the row can show — it carries none rather than "resets in now".
    func testCursorRowDropsAResetThatIsNotInTheFuture() throws {
        var data = AppSettingsData()
        data.usageAlertsEnabled = true
        data.cursorSpend = SpendThresholds(warningCents: 5_000, criticalCents: nil)
        data.alertChannels[AppSettingsData.cursorSpendKey] =
            AlertChannels(notification: true, drop: true)

        let cursor = AccountRecord(
            id: accountID, provider: .cursor, label: "Cursor",
            webProfileID: UUID(), displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0), isPaused: false
        )
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: now.addingTimeInterval(-86_400 * 10),
                resetsAt: now.addingTimeInterval(-61),
                planLabel: "Pro"
            )
        )
        let row = try XCTUnwrap(rows(
            presentations: [AccountPresentation(account: cursor, snapshot: snap, state: .current)],
            settings: data
        ).first)
        XCTAssertEqual(row.subject, .cursorSpend, "the row itself still shows — the evidence is current")
        XCTAssertNil(row.resetsAt)
    }

    /// With the provider's clock a little ahead, the
    /// drifting `periodEnd` lands AFTER the local `fetchedAt`. Once local time
    /// passes it, "overtaken by its own reset" would drop a perfectly fresh
    /// row until the next poll. Cursor has no reset boundary any more, so
    /// only age may govern its freshness.
    func testCursorRowSurvivesAServerAheadPeriodEnd() throws {
        var data = AppSettingsData()
        data.usageAlertsEnabled = true
        data.cursorSpend = SpendThresholds(warningCents: 5_000, criticalCents: nil)
        data.alertChannels[AppSettingsData.cursorSpendKey] =
            AlertChannels(notification: true, drop: true)

        let cursor = AccountRecord(
            id: accountID, provider: .cursor, label: "Cursor",
            webProfileID: UUID(), displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0), isPaused: false
        )
        // fetchedAt < periodEnd < now, all within allowed clock skew.
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: now.addingTimeInterval(-86_400 * 10),
                resetsAt: now.addingTimeInterval(-30),
                planLabel: "Pro"
            )
        )
        let result = rows(
            presentations: [AccountPresentation(account: cursor, snapshot: snap, state: .current)],
            settings: data
        )
        XCTAssertEqual(result.first?.subject, .cursorSpend, "a 60s-old observation is current")
    }

    /// Cursor has no cap in its API, so an unset threshold means off — never a
    /// default that would fire on any spend at all.
    func testCursorSpendWithNoConfiguredThresholdProducesNoRow() {
        var data = AppSettingsData()
        data.usageAlertsEnabled = true
        data.alertChannels[AppSettingsData.cursorSpendKey] =
            AlertChannels(notification: true, drop: true)

        let cursor = AccountRecord(
            id: accountID, provider: .cursor, label: "Cursor",
            webProfileID: UUID(), displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0), isPaused: false
        )
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 999_999,
                periodStart: now.addingTimeInterval(-86_400 * 10),
                resetsAt: now.addingTimeInterval(86_400),
                planLabel: "Pro"
            )
        )
        XCTAssertTrue(
            rows(
                presentations: [AccountPresentation(account: cursor, snapshot: snap, state: .current)],
                settings: data
            ).isEmpty
        )
    }

    /// Equal-tier rows keep discovery order across recomputations. The panel
    /// recomputes every 60s from identical data most of the time; an unstable
    /// sort would let those rows swap places and jitter for no reason.
    func testEqualTierRowsKeepAStableOrderAcrossRecomputation() {
        var data = settings()
        for kind in [UsageWindowKind.fiveHour, .weekly, .modelWeekly] {
            let key = AppSettingsData.thresholdKey(provider: .claude, window: kind)
            data.alertThresholds[key] = .default
            data.alertChannels[key] = AlertChannels(notification: true, drop: true)
        }
        // Three windows, all critical — nothing but the tie-break separates them.
        let all = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.02, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.03, resetsAt: nil),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.04, resetsAt: nil, label: "Fable")
        )
        let first = rows(presentations: [presentation(snapshot: all)], settings: data)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.map(\.tier), [.critical, .critical, .critical])
        XCTAssertEqual(
            first.map(\.subject),
            [.window(.fiveHour), .window(.weekly), .window(.modelWeekly)],
            "ties follow UsageWindowKind declaration order, the order allWindows walks"
        )
        for _ in 0..<8 {
            XCTAssertEqual(
                rows(presentations: [presentation(snapshot: all)], settings: data).map(\.subject),
                first.map(\.subject),
                "recomputing identical data must not reorder equal-tier rows"
            )
        }
    }

    /// Pins the INTENDED order: (tier descending, discovery ascending).
    ///
    /// Honest caveat, because it would be easy to over-claim this one: no test
    /// can prove the sort is stable. `sorted` is deterministic, so for any
    /// fixed input it returns a fixed order — removing the discovery-index
    /// tie-break leaves this test green (verified by mutation). Stability is a
    /// correctness-by-construction property of the comparator, not something
    /// observable from outside for a given input.
    ///
    /// What this test IS worth: it catches the sort key being changed or
    /// reversed, and it documents the order the panel depends on. Two accounts
    /// each cross two windows, with the CRITICAL row discovered SECOND within
    /// each account, so the expected result is not the discovery order either.
    func testEqualTierRowsFollowDiscoveryOrderAcrossAccounts() throws {
        var data = settings()
        for kind in [UsageWindowKind.weekly, .modelWeekly] {
            let key = AppSettingsData.thresholdKey(provider: .claude, window: kind)
            data.alertThresholds[key] = .default
            data.alertChannels[key] = AlertChannels(notification: true, drop: true)
        }

        func account(_ id: UUID, _ label: String, order: Int) -> AccountPresentation {
            AccountPresentation(
                account: AccountRecord(
                    id: id, provider: .claude, label: label,
                    webProfileID: UUID(), displayOrder: order,
                    createdAt: Date(timeIntervalSince1970: 0), isPaused: false
                ),
                // weekly is WARNING, modelWeekly is CRITICAL — so within each
                // account the worse row is found second.
                snapshot: UsageSnapshot(
                    accountID: id,
                    fetchedAt: now.addingTimeInterval(-60),
                    fiveHour: nil,
                    weekly: UsageWindow(kind: .weekly, remainingFraction: 0.20, resetsAt: nil),
                    modelWeekly: UsageWindow(
                        kind: .modelWeekly, remainingFraction: 0.02, resetsAt: nil, label: "Fable"
                    )
                ),
                state: .current
            )
        }
        let first = UUID(), second = UUID()
        let result = rows(
            presentations: [account(first, "One", order: 0), account(second, "Two", order: 1)],
            settings: data
        )

        XCTAssertEqual(result.map(\.tier), [.critical, .critical, .warning, .warning])
        XCTAssertEqual(
            result.map(\.accountID),
            [first, second, first, second],
            "within a tier, rows must follow discovery order — account, then window"
        )
    }

    // MARK: - Condition 8: reset rows

    func testActiveResetRowShowsAfterThresholdRowsAndHonoursChannelAndDismissal() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let account = AccountRecord(id: UUID(), provider: .claude, label: "Work", webProfileID: UUID(), displayOrder: 0, createdAt: now)
        let credit = ResetCredit(id: "c1", title: "Launch", count: 2, expiresAt: now.addingTimeInterval(86_400 * 30), usableNow: true)
        let snapshot = UsageSnapshot(accountID: account.id, fetchedAt: now, fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil), weekly: nil,
                                     resetCredits: ResetCredits(fetchedAt: now, items: [credit], complete: true))
        var memory = AccountAlertState()
        memory.resetCredits["c1"] = ResetCreditAlertMemory(lastSeenCount: 2, availableRow: .active, expiryHandled: false, expiringRow: .inactive)
        var settings = AppSettingsData(usageAlertsEnabled: true)
        let presentations = [AccountPresentation(account: account, snapshot: snapshot, state: .current)]

        var rows = AttentionDropModel.rows(presentations: presentations, settings: settings, alertStates: [account.id: memory], schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now)
        XCTAssertEqual(rows.map(\.subject), [.window(.fiveHour), .resetCredit(id: "c1", kind: .available)])
        XCTAssertEqual(rows.last?.resetCount, 2)
        XCTAssertEqual(rows.last?.resetsAt, credit.expiresAt)

        settings.alertChannels[AppSettingsData.resetCreditsKey(provider: .claude)] = .notificationOnly
        rows = AttentionDropModel.rows(presentations: presentations, settings: settings, alertStates: [account.id: memory], schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now)
        XCTAssertFalse(rows.contains { $0.isResetCredit })

        settings.alertChannels = [:]
        memory.resetCredits["c1"]?.availableRow = .dismissed
        rows = AttentionDropModel.rows(presentations: presentations, settings: settings, alertStates: [account.id: memory], schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now)
        XCTAssertFalse(rows.contains { $0.isResetCredit })
    }

    private func resetFixture(items: [ResetCredit], memory entry: ResetCreditAlertMemory, now: Date)
        -> (presentations: [AccountPresentation], states: [UUID: AccountAlertState]) {
        let account = AccountRecord(id: UUID(), provider: .claude, label: "Work", webProfileID: UUID(), displayOrder: 0, createdAt: now)
        let snapshot = UsageSnapshot(accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
                                     resetCredits: ResetCredits(fetchedAt: now, items: items, complete: true))
        var state = AccountAlertState()
        state.resetCredits["c1"] = entry
        return ([AccountPresentation(account: account, snapshot: snapshot, state: .current)], [account.id: state])
    }

    /// ChatGPT is one credit per entry, so a multi-credit
    /// grant would otherwise show N drop rows. Group ACTIVE credits for the
    /// same account and kind into one row.
    func testTwoActiveAvailableCreditsGroupIntoOneRow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let account = AccountRecord(id: UUID(), provider: .claude, label: "Work", webProfileID: UUID(), displayOrder: 0, createdAt: now)
        let a = ResetCredit(id: "a", title: nil, count: 1, expiresAt: now.addingTimeInterval(20 * 86_400), usableNow: true)
        let b = ResetCredit(id: "b", title: nil, count: 3, expiresAt: now.addingTimeInterval(10 * 86_400), usableNow: true)
        let snapshot = UsageSnapshot(
            accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
            resetCredits: ResetCredits(fetchedAt: now, items: [a, b], complete: true)
        )
        var state = AccountAlertState()
        state.resetCredits["a"] = ResetCreditAlertMemory(lastSeenCount: 1, availableRow: .active, expiryHandled: false, expiringRow: .inactive)
        state.resetCredits["b"] = ResetCreditAlertMemory(lastSeenCount: 3, availableRow: .active, expiryHandled: false, expiringRow: .inactive)
        let presentations = [AccountPresentation(account: account, snapshot: snapshot, state: .current)]
        let settings = AppSettingsData(usageAlertsEnabled: true)

        let rows = AttentionDropModel.rows(presentations: presentations, settings: settings, alertStates: [account.id: state], schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now)
        XCTAssertEqual(rows.count, 1, "one row, not two")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.subject, .resetCredit(id: "b", kind: .available), "soonest-expiring member's id")
        XCTAssertEqual(row.resetCount, 4, "sum of counts")
        XCTAssertEqual(row.resetsAt, b.expiresAt, "soonest expiry")
        XCTAssertEqual(Set(row.resetCreditIDs), ["a", "b"])
    }

    /// Only ACTIVE members are counted/listed — a per-row dismissal on one
    /// credit must shrink the group, not vanish or leave a stale count.
    func testGroupedRowOnlyCountsActiveMembers() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let account = AccountRecord(id: UUID(), provider: .claude, label: "Work", webProfileID: UUID(), displayOrder: 0, createdAt: now)
        let a = ResetCredit(id: "a", title: nil, count: 1, expiresAt: now.addingTimeInterval(20 * 86_400), usableNow: true)
        let b = ResetCredit(id: "b", title: nil, count: 3, expiresAt: now.addingTimeInterval(10 * 86_400), usableNow: true)
        let snapshot = UsageSnapshot(
            accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
            resetCredits: ResetCredits(fetchedAt: now, items: [a, b], complete: true)
        )
        var state = AccountAlertState()
        state.resetCredits["a"] = ResetCreditAlertMemory(lastSeenCount: 1, availableRow: .active, expiryHandled: false, expiringRow: .inactive)
        // "b" was dismissed — must not be counted or listed.
        state.resetCredits["b"] = ResetCreditAlertMemory(lastSeenCount: 3, availableRow: .dismissed, expiryHandled: false, expiringRow: .inactive)
        let presentations = [AccountPresentation(account: account, snapshot: snapshot, state: .current)]
        let settings = AppSettingsData(usageAlertsEnabled: true)

        let rows = AttentionDropModel.rows(presentations: presentations, settings: settings, alertStates: [account.id: state], schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.subject, .resetCredit(id: "a", kind: .available), "only the active member")
        XCTAssertEqual(row.resetCount, 1)
        XCTAssertEqual(row.resetCreditIDs, ["a"])
    }

    /// Every existing construction (including non-reset rows) carries the new
    /// field — `[]` for a subject that isn't a reset.
    func testNonResetRowsCarryAnEmptyResetCreditIDsList() {
        let result = rows()
        XCTAssertEqual(result.first?.resetCreditIDs, [])
    }

    func testResetRowDisappearsWhenCreditGoneOrExpired() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let active = ResetCreditAlertMemory(lastSeenCount: 1, availableRow: .active, expiryHandled: false, expiringRow: .inactive)
        let settings = AppSettingsData(usageAlertsEnabled: true)

        let gone = resetFixture(items: [], memory: active, now: now)
        XCTAssertTrue(AttentionDropModel.rows(presentations: gone.presentations, settings: settings, alertStates: gone.states, schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now).isEmpty)

        let expired = ResetCredit(id: "c1", title: nil, count: 1, expiresAt: now, usableNow: nil)
        let past = resetFixture(items: [expired], memory: active, now: now)
        XCTAssertTrue(AttentionDropModel.rows(presentations: past.presentations, settings: settings, alertStates: past.states, schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now).isEmpty)
    }

    func testReplenishmentReactivatesDismissedRow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let credit = ResetCredit(id: "c1", title: nil, count: 3, expiresAt: now.addingTimeInterval(86_400 * 30), usableNow: nil)
        var memory: [String: ResetCreditAlertMemory] = [
            "c1": ResetCreditAlertMemory(lastSeenCount: 2, availableRow: .dismissed, expiryHandled: false, expiringRow: .inactive)
        ]
        var events: [AlertEvent] = []
        ResetCreditPolicy.evaluate(
            ResetCreditAlertInput(credits: ResetCredits(fetchedAt: now, items: [credit], complete: true), leadDays: 1, now: now),
            memory: &memory, events: &events
        )
        let fixture = resetFixture(items: [credit], memory: memory["c1"]!, now: now)
        let rows = AttentionDropModel.rows(presentations: fixture.presentations, settings: AppSettingsData(usageAlertsEnabled: true), alertStates: fixture.states, schedule: WarmUpQuietSchedule(quietCells: [], holidays: []), now: now)
        XCTAssertEqual(rows.map(\.subject), [.resetCredit(id: "c1", kind: .available)])
    }
}
