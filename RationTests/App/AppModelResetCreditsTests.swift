import WebKit
import XCTest
@testable import Ration

/// Verifies `AppModel.decideAlerts` wires `ResetCreditPolicy` in: evaluated
/// only on fresh reads (never while priming), lifting the attention-drop
/// snooze on a reset event, and per-row dismissal via `dismissAttentionRows`.
/// Shares its fixture plumbing with `AppModelAlertsTests` — see
/// `AlertsTestSupport.swift`.
@MainActor
final class AppModelResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func creditSnapshot(_ accountID: UUID, _ items: [ResetCredit], fetchedAt: Date? = nil) -> UsageSnapshot {
        let at = fetchedAt ?? now.addingTimeInterval(-30)
        return UsageSnapshot(
            accountID: accountID, fetchedAt: at,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.9, resetsAt: nil),
            resetCredits: ResetCredits(fetchedAt: at, items: items, complete: true)
        )
    }

    private func credit(_ id: String = "c1", expiresIn: TimeInterval = 30 * 86_400) -> ResetCredit {
        ResetCredit(id: id, title: "Launch reset", count: 1, expiresAt: now.addingTimeInterval(expiresIn), usableNow: true)
    }

    func testNewResetPostsOneNotification() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        try await fixture.snapshots.save(creditSnapshot(account.id, [credit()]))
        await fixture.model.flushAlertEvaluations()
        try await fixture.snapshots.save(creditSnapshot(account.id, [credit()], fetchedAt: now.addingTimeInterval(-10)))
        await fixture.model.flushAlertEvaluations()

        let ids = await fixture.scheduler.posts.map(\.id)
        XCTAssertEqual(ids.filter { $0.contains(".resetCredit.c1.available") }.count, 1)
    }

    /// ChatGPT is one credit per entry, so two
    /// credits arriving together for the same account in one fresh read must
    /// post exactly ONE notification, not two.
    func testTwoCreditsArrivingTogetherPostExactlyOneNotification() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        try await fixture.snapshots.save(creditSnapshot(account.id, [credit("a"), credit("b")]))
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        let resetPosts = posts.filter { $0.id.contains(".resetCredit.") }
        XCTAssertEqual(resetPosts.count, 1, "one notification, not two — got \(resetPosts.map(\.id))")
    }

    func testEnablingAlertsDoesNotSilentlyConsumeAnExistingReset() async throws {
        // Snapshot lands while alerts are OFF; enabling primes; the next fresh
        // read must still announce it.
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.snapshots.save(creditSnapshot(account.id, [credit()]))
        try await fixture.model.setUsageAlertsEnabled(true)
        await fixture.model.flushAlertEvaluations()
        XCTAssertNil(fixture.model.alertStateForTesting(accountID: account.id)?.resetCredits["c1"], "priming must not touch reset memory")

        try await fixture.snapshots.save(creditSnapshot(account.id, [credit()], fetchedAt: now.addingTimeInterval(-5)))
        await fixture.model.flushAlertEvaluations()
        let ids = await fixture.scheduler.posts.map(\.id)
        XCTAssertTrue(ids.contains { $0.contains(".resetCredit.c1.available") })
    }

    func testExpiryCrossedWhileClosedAlertsAfterRelaunch() async throws {
        // Session 1 (clock at `now` = 1_000) reads a credit expiring just
        // OUTSIDE the 1-day lead window (60 s short): "available" fires,
        // expiry not yet handled. The relaunch's clock is only 120 s later —
        // enough to cross that boundary for the SAME stored snapshot. If
        // priming evaluated resets, it would silently flip the credit's
        // `expiryHandled` to true from data it never told the user about,
        // and the genuine first fresh read after relaunch would then stay
        // silent. This is the exact scenario the `prime ? nil :` gate in
        // `decideAlerts` exists for — see mutation-check evidence in the
        // task report for confirmation this test actually reaches that gate
        // (unlike its predecessor, which passed with or without it).
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeAlertsFixture(directory: directory)
        try await first.model.load(startBackgroundRefresh: false)
        let sessionID = try first.model.beginSignIn(provider: .claude)
        try await first.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(first.model.accounts.first)
        try await first.model.setUsageAlertsEnabled(true)
        let expiresIn: TimeInterval = 86_400 + 60
        try await first.snapshots.save(creditSnapshot(account.id, [credit(expiresIn: expiresIn)]))
        await first.model.flushAlertEvaluations()
        let firstIDs = await first.scheduler.posts.map(\.id)
        XCTAssertTrue(
            firstIDs.contains { $0.contains(".resetCredit.c1.available") },
            "premise: session 1 must have seen the credit as available"
        )

        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(true)
        let relaunchNow = now.addingTimeInterval(120)
        let second = try makeAlertsFixture(directory: directory, scheduler: scheduler, now: { relaunchNow })
        // Priming (inside load()) sees the snapshot session 1 stored
        // (fetchedAt = now - 30 = 970; age at relaunch = 150 s, still
        // current) — the SAME credit, now inside the lead window from the
        // relaunch clock's point of view. It must not be evaluated here.
        try await second.model.load(startBackgroundRefresh: false)
        // The first FRESH read after relaunch: same credit, read anew.
        let expiringNow = ResetCredit(id: "c1", title: "Launch reset", count: 1, expiresAt: now.addingTimeInterval(expiresIn), usableNow: true)
        try await second.snapshots.save(creditSnapshot(account.id, [expiringNow], fetchedAt: relaunchNow.addingTimeInterval(-5)))
        await second.model.flushAlertEvaluations()
        let ids = await scheduler.posts.map(\.id)
        XCTAssertTrue(ids.contains { $0.contains(".resetCredit.c1.expiring") })
    }

    func testCarriedListNeverAlerts() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)
        // A list read LONG ago, carried onto a fresh snapshot.
        let old = now.addingTimeInterval(-10_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id, fetchedAt: now.addingTimeInterval(-30),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil), weekly: nil,
            resetCredits: ResetCredits(fetchedAt: old, items: [credit()], complete: true)
        ))
        await fixture.model.flushAlertEvaluations()
        let ids = await fixture.scheduler.posts.map(\.id)
        XCTAssertFalse(ids.contains { $0.contains(".resetCredit.") })
    }

    func testResetCreditArrivalLiftsSnooze() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeAlertsFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)
        fixture.model.snoozeAttentionDrop([])
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed)

        try await fixture.snapshots.save(creditSnapshot(account.id, [credit()]))
        await fixture.model.flushAlertEvaluations()
        XCTAssertFalse(fixture.model.settings.data.dropSnoozed)
        XCTAssertEqual(fixture.model.attentionRows(now: now).map(\.subject), [.resetCredit(id: "c1", kind: .available)])
    }

    /// The snooze lift for a reset-credit event must
    /// respect that provider's own "Resets" drop channel — a user who
    /// turned drop notifications off for resets should not have their ✕
    /// silently undone by one. Window `.reset` (a different event) is
    /// untouched by this and still lifts the snooze; that is covered by
    /// `testResetCreditArrivalLiftsSnooze`'s sibling in
    /// `AppModelAlertsTests` and is not re-asserted here.
    func testResetCreditArrivalDoesNotLiftSnoozeWhenResetsDropChannelIsOff() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.model.settings.setDropEnabled(false, forKey: AppSettingsData.resetCreditsKey(provider: .claude))
        fixture.model.snoozeAttentionDrop([])
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed)

        try await fixture.snapshots.save(creditSnapshot(account.id, [credit()]))
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed, "resets drop channel is off: this reset must not lift the snooze")
    }

    /// The ✕ acknowledges reset-credit rows individually
    /// (unlike limit rows, which stay governed purely by the global snooze).
    /// Without this, a dismissed reset row would return the moment ANY
    /// window on ANY account reset — for as long as ~30 days, until the
    /// credit itself expires or is used.
    func testPanelCloseAcknowledgesTheResetRowSoItStaysHiddenAfterSnoozeLifts() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeAlertsFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        // 5h and weekly both over threshold (critical); a reset credit is
        // also available. All three rows show.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-90),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil),
            resetCredits: ResetCredits(fetchedAt: now.addingTimeInterval(-90), items: [credit()], complete: true)
        ))
        await fixture.model.flushAlertEvaluations()
        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(
            Set(rows.map(\.subject)),
            Set([.window(.fiveHour), .window(.weekly), .resetCredit(id: "c1", kind: .available)]),
            "premise: all three rows visible"
        )

        fixture.model.snoozeAttentionDrop(rows)
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.resetCredits["c1"]?.availableRow, .dismissed,
            "the ✕ acknowledges the reset row, unlike limit rows"
        )

        // The 5h window resets (freed capacity) — a DIFFERENT window's reset
        // lifts the global snooze. Weekly is still over threshold and was
        // never per-row dismissed, so it returns; the credit is unchanged
        // but was per-row dismissed, so it must not.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-30),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.95, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil),
            resetCredits: ResetCredits(fetchedAt: now.addingTimeInterval(-30), items: [credit()], complete: true)
        ))
        await fixture.model.flushAlertEvaluations()
        XCTAssertFalse(fixture.model.settings.data.dropSnoozed, "premise: the 5h reset lifted the snooze")
        XCTAssertEqual(
            fixture.model.attentionRows(now: now).map(\.subject), [.window(.weekly)],
            "the still-over-threshold window row returns; the dismissed reset row does not"
        )

        // A count increase re-shows the available row regardless.
        let replenished = ResetCredit(id: "c1", title: "Launch reset", count: 2, expiresAt: now.addingTimeInterval(30 * 86_400), usableNow: true)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-10),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.95, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil),
            resetCredits: ResetCredits(fetchedAt: now.addingTimeInterval(-10), items: [replenished], complete: true)
        ))
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(
            fixture.model.attentionRows(now: now).contains { $0.subject == .resetCredit(id: "c1", kind: .available) },
            "a count increase re-activates the row even though it was dismissed"
        )
    }

    /// Two credits arriving together for the same account and kind are
    /// GROUPED into one drop row: clicking that
    /// one row must acknowledge every credit it folded in, not just the
    /// row's representative subject id.
    func testGroupedRowClickDismissesAllMembers() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.snapshots.save(creditSnapshot(account.id, [credit("a"), credit("b")]))
        await fixture.model.flushAlertEvaluations()
        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.filter(\.isResetCredit).count, 1, "premise: grouped into one row")
        let row = try XCTUnwrap(rows.first(where: \.isResetCredit))
        XCTAssertEqual(row.resetCount, 2)
        XCTAssertEqual(Set(row.resetCreditIDs), ["a", "b"])

        fixture.model.dismissAttentionRows([row])

        XCTAssertTrue(fixture.model.attentionRows(now: now).filter(\.isResetCredit).isEmpty, "both members acknowledged")
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.resetCredits["a"]?.availableRow, .dismissed)
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.resetCredits["b"]?.availableRow, .dismissed)
    }

    /// A row click with an EMPTY `resetCreditIDs` (a plain single-credit row
    /// built directly, not via the grouping path) falls back to the
    /// subject's own id — preserves the pre-grouping single-credit path.
    func testRowClickWithEmptyResetCreditIDsFallsBackToSubjectID() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.snapshots.save(creditSnapshot(account.id, [credit("a")]))
        await fixture.model.flushAlertEvaluations()
        let row = AttentionRow(
            accountID: account.id, accountLabel: "Work", provider: .claude,
            subject: .resetCredit(id: "a", kind: .available), tier: .warning,
            usedPercent: nil, spentCents: nil, thresholdPercent: nil,
            thresholdCents: nil, resetsAt: nil, resetCount: 1, resetCreditIDs: []
        )
        fixture.model.dismissAttentionRows([row])
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.resetCredits["a"]?.availableRow, .dismissed)
    }
}
