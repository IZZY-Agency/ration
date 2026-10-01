import WebKit
import XCTest
@testable import Ration

/// The background usage-credits read (`AppModel.refreshUsageCreditsInBackground`)
/// and, further down, the expiry warning's delivery.
@MainActor
final class AppModelUsageCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func credits(at: Date = Date(timeIntervalSince1970: 1_001), cents: Int64 = 1000) -> UsageCredits {
        let money = Money(minorUnits: cents, currency: "EUR", exponent: 2)!
        return UsageCredits(
            fetchedAt: at, balance: money,
            grants: [UsageCreditGrant(id: "promo-1", kind: .promotional, remaining: money, granted: money, expiresAt: at.addingTimeInterval(200 * 86_400))],
            complete: true
        )
    }

    private func signedIn(_ fixture: AlertsFixture, provider: Provider = .claude) async throws -> AccountRecord {
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: provider)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        await fixture.model.flushUsageCreditsRefreshes()
        return try XCTUnwrap(fixture.model.accounts.first)
    }

    func testAClaudeRefreshReadsTheBalanceOntoTheSnapshot() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        fixture.adapter.usageCredits = credits()
        let account = try await signedIn(fixture)

        await fixture.model.refreshAll()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.snapshots.snapshot(for: account.id)?.usageCredits, credits().applied(for: "org-1"))
        XCTAssertGreaterThan(fixture.adapter.usageCreditsCalls, 0)
    }

    func testOtherProvidersNeverRead() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.chatGPTAdapter.organizationID = "org-1"
        fixture.chatGPTAdapter.usageCredits = credits()
        _ = try await signedIn(fixture, provider: .chatGPT)

        await fixture.model.refreshAll()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.chatGPTAdapter.usageCreditsCalls, 0)
    }

    func testNoReadWithoutAKnownOrganization() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.usageCredits = credits()
        _ = try await signedIn(fixture)

        await fixture.model.refreshAll()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.adapter.usageCreditsCalls, 0)
    }

    func testOneReadPerAccountAtATime() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        fixture.adapter.usageCredits = credits()
        _ = try await signedIn(fixture)
        let before = fixture.adapter.usageCreditsCalls

        fixture.adapter.holdsUsageCredits = true
        await fixture.model.refreshAll()
        await fixture.adapter.waitUntilUsageCreditsHeld()
        await fixture.model.refreshAll()
        await fixture.model.refreshAll()
        fixture.adapter.releaseUsageCredits()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.adapter.usageCreditsCalls, before + 1)
    }

    func testAReadForAnOrganizationTheAccountHasLeftIsDropped() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        let account = try await signedIn(fixture)

        fixture.adapter.usageCredits = credits(at: Date(timeIntervalSince1970: 1_050))
        fixture.adapter.holdsUsageCredits = true
        await fixture.model.refreshAll()
        await fixture.adapter.waitUntilUsageCreditsHeld()
        // The account moves to another workspace while the read is out.
        fixture.adapter.organizationID = "org-2"
        await fixture.model.refreshAll()
        fixture.adapter.releaseUsageCredits()
        await fixture.model.flushUsageCreditsRefreshes()

        // org-1's read is refused; what the account shows is org-2's own
        // follow-up read (see testAnOrganizationSwitchDuringAReadGetsItsOwnRead).
        XCTAssertNotEqual(fixture.snapshots.snapshot(for: account.id)?.usageCredits?.organizationID, "org-1", "org-1's balance never shows under org-2")
    }

    func testRemovingTheAccountDropsAReadInFlight() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        let account = try await signedIn(fixture)

        fixture.adapter.usageCredits = credits(at: Date(timeIntervalSince1970: 1_050))
        fixture.adapter.holdsUsageCredits = true
        await fixture.model.refreshAll()
        await fixture.adapter.waitUntilUsageCreditsHeld()
        try await fixture.model.requestRemoveAccount(id: account.id).value
        fixture.adapter.releaseUsageCredits()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertNil(fixture.snapshots.snapshot(for: account.id))
    }

    /// A workspace switch while a read is out: that read is refused, and the
    /// new organization gets its own read as soon as it settles.
    func testAnOrganizationSwitchDuringAReadGetsItsOwnRead() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        let account = try await signedIn(fixture)
        let before = fixture.adapter.usageCreditsCalls

        fixture.adapter.usageCredits = credits(at: Date(timeIntervalSince1970: 1_050))
        fixture.adapter.holdsUsageCredits = true
        await fixture.model.refreshAll()
        await fixture.adapter.waitUntilUsageCreditsHeld()
        fixture.adapter.organizationID = "org-2"
        await fixture.model.refreshAll()
        fixture.adapter.releaseUsageCredits()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.adapter.usageCreditsCalls, before + 2, "the held read, then one for org-2")
        let stored = fixture.snapshots.snapshot(for: account.id)
        XCTAssertEqual(stored?.usageCredits?.organizationID, "org-2")
        XCTAssertEqual(stored?.usageCredits?.balance, credits().balance)
    }

    /// After a relaunch the restored balance shows but cannot warn: nothing
    /// says it is this organization's until this session reads it.
    func testARestoredBalanceNeverWarnsBeforeThisSessionReadsIt() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeAlertsFixture(directory: directory)
        let account = try await signedInWithAlerts(first)
        // Read far from its expiry: silent, but kept on disk.
        try await first.snapshots.save(creditSnapshot(account.id, [grant(expiresIn: 3 * 86_400)]))
        await first.model.flushAlertEvaluations()
        first.model.stop()

        // Two days later the grant is inside its window.
        let later = now.addingTimeInterval(2 * 86_400 + 60)
        let second = try makeAlertsFixture(directory: directory, now: { later })
        try await second.model.load(startBackgroundRefresh: false)
        try await second.snapshots.save(UsageSnapshot(
            accountID: account.id, fetchedAt: later.addingTimeInterval(-10),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.9, resetsAt: nil),
            organizationID: "org-2"
        ))
        await second.model.flushAlertEvaluations()
        let carried = second.snapshots.snapshot(for: account.id)?.usageCredits
        XCTAssertNotNil(carried, "the restored balance still shows")
        XCTAssertNil(carried?.organizationID)
        var posts = await creditPosts(second)
        XCTAssertEqual(posts.count, 0, "restored, unverified: display only")

        // This session reads org-2's credits: now it may warn.
        let fresh = UsageCredits(fetchedAt: later.addingTimeInterval(-5), balance: Money(minorUnits: 1000, currency: "EUR", exponent: 2)!,
                                 grants: [grant(expiresIn: 3 * 86_400)], complete: true)
        try await second.snapshots.applyUsageCredits(fresh, accountID: account.id, organizationID: "org-2")
        await second.model.flushAlertEvaluations()
        posts = await creditPosts(second)
        XCTAssertEqual(posts.count, 1)
    }

    /// A sign-in saves its snapshot outside the refresh path and starts no
    /// read of its own (it would race the sign-in flow); the next refresh
    /// reads the balance.
    func testASignInsBalanceArrivesWithTheNextRefresh() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        fixture.adapter.usageCredits = credits()
        let account = try await signedIn(fixture)
        XCTAssertNil(fixture.snapshots.snapshot(for: account.id)?.usageCredits)

        await fixture.model.refreshAll()
        await fixture.model.flushUsageCreditsRefreshes()
        XCTAssertEqual(fixture.snapshots.snapshot(for: account.id)?.usageCredits?.organizationID, "org-1")
    }

    /// Nothing follows a read cancelled by `stop()`, even when the account
    /// moved organization meanwhile.
    func testNothingFollowsAStoppedRead() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        _ = try await signedIn(fixture)
        let before = fixture.adapter.usageCreditsCalls

        fixture.adapter.holdsUsageCredits = true
        await fixture.model.refreshAll()
        await fixture.adapter.waitUntilUsageCreditsHeld()
        fixture.adapter.organizationID = "org-2"
        await fixture.model.refreshAll()
        fixture.model.stop()
        fixture.adapter.releaseUsageCredits()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.adapter.usageCreditsCalls, before + 1, "no follow-up after stop")
    }

    /// A warning row that was active before a relaunch does not come back on
    /// a restored balance: after a workspace switch it would be another
    /// organization's. It returns once this session reads the credits.
    func testARestoredWarningRowStaysHiddenUntilVerified() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeAlertsFixture(directory: directory)
        let account = try await signedInWithAlerts(first)
        try await first.snapshots.save(creditSnapshot(account.id, [grant()]))
        await first.model.flushAlertEvaluations()
        XCTAssertEqual(first.model.attentionRows(now: now).map(\.subject), [.usageCredit(id: "promo-1")], "premise: row active")
        first.model.stop()

        let later = now.addingTimeInterval(60)
        let second = try makeAlertsFixture(directory: directory, now: { later })
        try await second.model.load(startBackgroundRefresh: false)
        try await second.model.setUsageAlertsEnabled(true)
        try await second.snapshots.save(UsageSnapshot(
            accountID: account.id, fetchedAt: later.addingTimeInterval(-10),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.9, resetsAt: nil),
            organizationID: "org-2"
        ))
        await second.model.flushAlertEvaluations()
        XCTAssertNotNil(second.snapshots.snapshot(for: account.id)?.usageCredits, "the balance still shows")
        XCTAssertEqual(second.model.attentionRows(now: later), [], "no warning on an unverified reading")

        try await second.snapshots.applyUsageCredits(
            UsageCredits(fetchedAt: later.addingTimeInterval(-5), balance: Money(minorUnits: 1000, currency: "EUR", exponent: 2)!,
                         grants: [grant()], complete: true),
            accountID: account.id, organizationID: "org-2")
        await second.model.flushAlertEvaluations()
        XCTAssertEqual(second.model.attentionRows(now: later).map(\.subject), [.usageCredit(id: "promo-1")])
    }

    func testAFailingReadKeepsTheLastBalanceAndTheAccountHealthy() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.organizationID = "org-1"
        fixture.adapter.usageCredits = credits()
        let account = try await signedIn(fixture)
        await fixture.model.refreshAll()
        await fixture.model.flushUsageCreditsRefreshes()

        fixture.adapter.usageCreditsError = WebUsageClientError.timedOut
        await fixture.model.refreshAll()
        await fixture.model.flushUsageCreditsRefreshes()

        XCTAssertEqual(fixture.snapshots.snapshot(for: account.id)?.usageCredits, credits().applied(for: "org-1"))
        let state = fixture.model.presentations.first { $0.account.id == account.id }?.state
        XCTAssertEqual(state, .current)
    }

    // MARK: The expiry warning

    /// A reading of `grants`, `readAgo` seconds before the model's clock.
    private func creditSnapshot(_ accountID: UUID, _ grants: [UsageCreditGrant], readAgo: TimeInterval = 20, enabled: Bool? = false) -> UsageSnapshot {
        let at = now.addingTimeInterval(-readAgo)
        let balance = Money(minorUnits: grants.reduce(0) { $0 + $1.remaining.minorUnits }, currency: "EUR", exponent: 2)!
        // A reading this session applied for the snapshot's organization.
        return UsageSnapshot(
            accountID: accountID, fetchedAt: at.addingTimeInterval(-2),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.9, resetsAt: nil),
            organizationID: "org-1",
            usageCredits: UsageCredits(fetchedAt: at, balance: balance, grants: grants, complete: true, organizationID: "org-1"),
            usageCreditsEnabled: enabled
        )
    }

    private func grant(_ id: String = "promo-1", cents: Int64 = 1000, expiresIn: TimeInterval = 6 * 3600) -> UsageCreditGrant {
        let money = Money(minorUnits: cents, currency: "EUR", exponent: 2)!
        return UsageCreditGrant(id: id, kind: .promotional, remaining: money, granted: money, expiresAt: now.addingTimeInterval(expiresIn))
    }

    private func signedInWithAlerts(_ fixture: AlertsFixture) async throws -> AccountRecord {
        let account = try await signedIn(fixture)
        try await fixture.model.setUsageAlertsEnabled(true)
        return account
    }

    private func creditPosts(_ fixture: AlertsFixture) async -> [(id: String, title: String, body: String)] {
        await fixture.scheduler.posts.filter { $0.id.contains(".usageCredit.") }
    }

    func testAnExpiringCreditPostsOnceAndShowsARow() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await fixture.model.flushAlertEvaluations()
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()], readAgo: 5))
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.map(\.id), ["\(account.id.uuidString).usageCredit.promo-1.expiring"])
        XCTAssertEqual(posts.first?.title, "Work: credits expire soon")
        XCTAssertTrue(posts.first?.body.hasPrefix("€10.00 of usage credits on Work expire ") == true, posts.first?.body ?? "")
        XCTAssertTrue(posts.first?.body.contains("Usage credits are off on claude.ai") == true, "the switch is off in this reading")
        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.map(\.subject), [.usageCredit(id: "promo-1")])
        XCTAssertEqual(rows.first?.creditAmount, Money(minorUnits: 1000, currency: "EUR", exponent: 2))
    }

    /// A warning already due when alerts are turned on is not consumed by
    /// the priming pass; the next fresh read still delivers it.
    func testEnablingAlertsDoesNotSilentlyConsumeADueWarning() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        try await fixture.model.setUsageAlertsEnabled(true)
        await fixture.model.flushAlertEvaluations()
        XCTAssertNil(fixture.model.alertStateForTesting(accountID: account.id)?.usageCredits["promo-1"], "priming must not touch credit memory")

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()], readAgo: 5))
        await fixture.model.flushAlertEvaluations()
        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 1)
    }

    func testFarFromExpiryIsSilent() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant(expiresIn: 30 * 86_400)]))
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    func testAStaleReadingNeverWarns() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()], readAgo: UsageEvidence.maxAge + 30))
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 0, "a balance this old may already be spent")
    }

    func testARelaunchDoesNotWarnAgain() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeAlertsFixture(directory: directory)
        let account = try await signedInWithAlerts(first)
        try await first.snapshots.save(creditSnapshot(account.id, [grant()]))
        await first.model.flushAlertEvaluations()
        let firstPosts = await creditPosts(first)
        XCTAssertEqual(firstPosts.count, 1)
        first.model.stop()

        let second = try makeAlertsFixture(directory: directory)
        try await second.model.load(startBackgroundRefresh: false)
        try await second.snapshots.save(creditSnapshot(account.id, [grant()], readAgo: 5))
        await second.model.flushAlertEvaluations()

        let secondPosts = await creditPosts(second)
        XCTAssertEqual(secondPosts.count, 0, "the memory survived the relaunch")
    }

    func testFeatureOffSuppressesDeliveryButKeepsBookkeeping() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.model.setShows(.credits, for: .claude, false)

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.usageCredits["promo-1"]?.expiryHandled, true)
    }

    func testReEnablingDoesNotReplayWhatHappenedWhileOff() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.model.setShows(.credits, for: .claude, false)
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await fixture.model.flushAlertEvaluations()

        try await fixture.model.setShows(.credits, for: .claude, true)
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()], readAgo: 5))
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 0)
    }

    /// Queued while ON, then OFF→ON while it waits: the older post is dead.
    func testAQueuedWarningDoesNotSurviveAnOffOnFlip() async throws {
        let gate = UsageCreditsSaveGate()
        let directory = try makeTempDirectory()
        let store = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"), saveStates: { _ in await gate.pass() })
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store)
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)

        gate.arm()
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await gate.waitUntilHeld()
        try await fixture.model.setShows(.credits, for: .claude, false)
        try await fixture.model.setShows(.credits, for: .claude, true)
        gate.release()
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 0)
    }

    /// Control for the one above: left ON, the held post still goes out.
    func testAQueuedWarningDeliversWhenTheSwitchStaysOn() async throws {
        let gate = UsageCreditsSaveGate()
        let directory = try makeTempDirectory()
        let store = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"), saveStates: { _ in await gate.pass() })
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store)
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)

        gate.arm()
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await gate.waitUntilHeld()
        gate.release()
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 1)
    }

    func testTheNotificationChannelOffKeepsTheRow() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.model.setNotificationEnabled(false, forKey: AppSettingsData.usageCreditsKey(provider: .claude))

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await fixture.model.flushAlertEvaluations()

        let posts = await creditPosts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now).map(\.subject), [.usageCredit(id: "promo-1")])
    }

    func testTheDropChannelOffHidesTheRow() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.model.setDropEnabled(false, forKey: AppSettingsData.usageCreditsKey(provider: .claude))

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    func testTheCrossAcknowledgesTheRowForGood() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant("a", cents: 400), grant("b", cents: 600, expiresIn: 8 * 3600)]))
        await fixture.model.flushAlertEvaluations()
        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.map(\.subject), [.usageCredit(id: "a")], "one row per account")
        XCTAssertEqual(rows.first?.creditAmount, Money(minorUnits: 1000, currency: "EUR", exponent: 2), "the grants summed")

        fixture.model.snoozeAttentionDrop(rows)
        fixture.model.showAttentionDrop()
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant("a", cents: 400), grant("b", cents: 600, expiresIn: 8 * 3600)], readAgo: 5))
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(fixture.model.attentionRows(now: now), [], "both grants acknowledged")
        let state = fixture.model.alertStateForTesting(accountID: account.id)
        XCTAssertEqual(state?.usageCredits["a"]?.row, .dismissed)
        XCTAssertEqual(state?.usageCredits["b"]?.row, .dismissed)
    }

    func testAWarningLiftsTheSnoozeOnlyWithTheDropChannelOn() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.model.setDropEnabled(false, forKey: AppSettingsData.usageCreditsKey(provider: .claude))
        fixture.model.snoozeAttentionDrop([])
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant("a")]))
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed, "a hidden row must not undo the ✕")

        try await fixture.model.setDropEnabled(true, forKey: AppSettingsData.usageCreditsKey(provider: .claude))
        try await fixture.snapshots.save(creditSnapshot(account.id, [grant("a"), grant("b", expiresIn: 7 * 3600)], readAgo: 5))
        await fixture.model.flushAlertEvaluations()
        XCTAssertFalse(fixture.model.settings.data.dropSnoozed, "a new warning is new information")
    }

    func testPrivacyModeHidesTheAmountAndTheAccount() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedInWithAlerts(fixture)
        try await fixture.model.setRedactNotifications(true)

        try await fixture.snapshots.save(creditSnapshot(account.id, [grant()]))
        await fixture.model.flushAlertEvaluations()

        let post = await creditPosts(fixture).first
        XCTAssertEqual(post?.title, "Ration")
        XCTAssertEqual(post?.body, "An account's usage credits expire soon.")
    }
}

@MainActor
private final class UsageCreditsSaveGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldSignal: CheckedContinuation<Void, Never>?

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            held = continuation
            heldSignal?.resume()
            heldSignal = nil
        }
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldSignal = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

