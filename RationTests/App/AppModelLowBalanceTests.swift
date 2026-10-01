import XCTest
@testable import Ration

/// TypeSafe's low-balance alert, end to end through `AppModel`:
/// delivery, the drop row, the ✕, a top-up re-arming it, and the switches.
@MainActor
final class AppModelLowBalanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    // TypeSafe is switched off in this build; its code stays covered.
    override func setUp() async throws { Provider.switchedOff = [] }
    override func tearDown() async throws { Provider.switchedOff = [.typeSafe] }

    private func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "USD", exponent: 2)! }

    /// A TypeSafe reading this fetch read (`usageCreditsVerified`), `readAgo`
    /// seconds before the model's clock.
    private func balance(_ accountID: UUID, cents: Int64, readAgo: TimeInterval = 20, readThisSession: Bool = true) -> UsageSnapshot {
        let at = now.addingTimeInterval(-readAgo)
        return UsageSnapshot(
            accountID: accountID, fetchedAt: at, fiveHour: nil, weekly: nil,
            usageCredits: UsageCredits(fetchedAt: at, balance: usd(cents), grants: [], complete: true, readThisSession: readThisSession)
        )
    }

    private func signedIn(_ fixture: AlertsFixture, thresholdCents: Int? = 500) async throws -> AccountRecord {
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .typeSafe)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Lab")
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.model.setLowBalanceCents(thresholdCents, provider: .typeSafe)
        return try XCTUnwrap(fixture.model.accounts.first)
    }

    private func posts(_ fixture: AlertsFixture) async -> [(id: String, title: String, body: String)] {
        await fixture.scheduler.posts.filter { $0.id.hasSuffix(".lowBalance") }
    }

    private func save(_ fixture: AlertsFixture, _ snapshot: UsageSnapshot) async throws {
        try await fixture.snapshots.save(snapshot)
        await fixture.model.flushAlertEvaluations()
    }

    func testFallingBelowPostsOnceAndShowsARow() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        try await save(fixture, balance(account.id, cents: 412))
        try await save(fixture, balance(account.id, cents: 400, readAgo: 5))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.map(\.id), ["\(account.id.uuidString).lowBalance"])
        XCTAssertEqual(posts.first?.title, "Lab: balance low")
        XCTAssertEqual(posts.first?.body, "$4.12 left on Lab, below your $5.00 alert. API calls stop when the balance runs out.")
        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.map(\.subject), [.lowBalance])
        XCTAssertEqual(rows.first?.creditAmount, usd(400), "the row shows the latest balance")
        XCTAssertEqual(rows.first?.thresholdCents, 500)
        XCTAssertEqual(rows.first?.tier, .warning)
    }

    /// A balance already low when alerts are turned on is not consumed by
    /// the priming pass; the next fresh read still alerts.
    func testEnablingAlertsDoesNotSilentlyConsumeALowBalance() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .typeSafe)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Lab")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setLowBalanceCents(500, provider: .typeSafe)
        try await fixture.snapshots.save(balance(account.id, cents: 100))
        try await fixture.model.setUsageAlertsEnabled(true)
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.lowBalance ?? LowBalanceAlertMemory(), LowBalanceAlertMemory(),
                       "priming must not touch low-balance memory")

        try await save(fixture, balance(account.id, cents: 90, readAgo: 5))
        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 1)
    }

    func testExactlyOnTheThresholdIsNotBelowIt() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        try await save(fixture, balance(account.id, cents: 500))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    func testATopUpReArmsTheAlert() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        try await save(fixture, balance(account.id, cents: 300))
        try await save(fixture, balance(account.id, cents: 3_000, readAgo: 10))
        XCTAssertEqual(fixture.model.attentionRows(now: now), [], "topped up: no row")
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.lowBalance, LowBalanceAlertMemory())
        try await save(fixture, balance(account.id, cents: 200, readAgo: 5))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 2, "spent down again after the top-up")
    }

    func testNoThresholdNoAlert() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture, thresholdCents: nil)

        try await save(fixture, balance(account.id, cents: 1))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0, "opt-in: no threshold, no alert")
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    func testARestoredOrStaleBalanceNeverAlerts() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        try await save(fixture, balance(account.id, cents: 100, readThisSession: false))
        try await save(fixture, balance(account.id, cents: 100, readAgo: UsageEvidence.maxAge + 30))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    /// The ✕ acknowledges the row for good: a window reset elsewhere does
    /// not bring it back, only a top-up and a new fall does.
    func testTheCrossAcknowledgesTheRowUntilATopUp() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await save(fixture, balance(account.id, cents: 300))
        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.map(\.subject), [.lowBalance])

        fixture.model.snoozeAttentionDrop(rows)
        fixture.model.showAttentionDrop()
        try await save(fixture, balance(account.id, cents: 250, readAgo: 10))
        XCTAssertEqual(fixture.model.attentionRows(now: now), [], "acknowledged")
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.lowBalance.row, .dismissed)

        try await save(fixture, balance(account.id, cents: 2_000, readAgo: 8))
        try await save(fixture, balance(account.id, cents: 100, readAgo: 5))
        XCTAssertEqual(fixture.model.attentionRows(now: now).map(\.subject), [.lowBalance])
    }

    func testRaisingTheThresholdAboveTheBalanceAlertsAtOnce() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await save(fixture, balance(account.id, cents: 2_658))
        let before = await posts(fixture)
        XCTAssertEqual(before.count, 0)

        try await fixture.model.setLowBalanceCents(3_000, provider: .typeSafe)
        await fixture.model.flushAlertEvaluations()

        let after = await posts(fixture)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.body, "$26.58 left on Lab, below your $30.00 alert. API calls stop when the balance runs out.")
    }

    func testTheUsageCreditsSwitchOffSilencesIt() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await fixture.model.setShows(.credits, for: .typeSafe, false)

        try await save(fixture, balance(account.id, cents: 100))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    func testTheDropChannelOffHidesTheRowButStillNotifies() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await fixture.model.setDropEnabled(false, forKey: AppSettingsData.lowBalanceKey(provider: .typeSafe))

        try await save(fixture, balance(account.id, cents: 100))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(fixture.model.attentionRows(now: now), [])
    }

    func testTheNotificationChannelOffKeepsTheRow() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await fixture.model.setNotificationEnabled(false, forKey: AppSettingsData.lowBalanceKey(provider: .typeSafe))

        try await save(fixture, balance(account.id, cents: 100))

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(fixture.model.attentionRows(now: now).map(\.subject), [.lowBalance])
    }

    func testAFallLiftsTheSnoozeOnlyWithTheDropChannelOn() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await fixture.model.setDropEnabled(false, forKey: AppSettingsData.lowBalanceKey(provider: .typeSafe))
        fixture.model.snoozeAttentionDrop([])
        try await save(fixture, balance(account.id, cents: 100))
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed, "a hidden row must not undo the ✕")

        try await fixture.model.setDropEnabled(true, forKey: AppSettingsData.lowBalanceKey(provider: .typeSafe))
        try await save(fixture, balance(account.id, cents: 2_000, readAgo: 10))
        try await save(fixture, balance(account.id, cents: 90, readAgo: 5))
        XCTAssertFalse(fixture.model.settings.data.dropSnoozed, "a new fall is new information")
    }

    func testPrivacyModeHidesTheAmountAndTheAccount() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await fixture.model.setRedactNotifications(true)

        try await save(fixture, balance(account.id, cents: 100))

        let post = await posts(fixture).first
        XCTAssertEqual(post?.title, "Ration")
        XCTAssertEqual(post?.body, "An account's balance is low.")
    }

    func testARelaunchDoesNotAlertAgain() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeAlertsFixture(directory: directory)
        let account = try await signedIn(first)
        try await save(first, balance(account.id, cents: 100))
        let firstPosts = await posts(first)
        XCTAssertEqual(firstPosts.count, 1)
        first.model.stop()

        let second = try makeAlertsFixture(directory: directory)
        try await second.model.load(startBackgroundRefresh: false)
        try await save(second, balance(account.id, cents: 90, readAgo: 5))

        let secondPosts = await posts(second)
        XCTAssertEqual(secondPosts.count, 0, "the memory survived the relaunch")
    }

    // MARK: Re-arming, queued posts and freshness

    /// Turned off and back on while Usage alerts is off: the latch must not
    /// survive and swallow the next low reading.
    func testTurningItOffReArmsEvenWithAlertsOff() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await save(fixture, balance(account.id, cents: 100))
        let first = await posts(fixture)
        XCTAssertEqual(first.count, 1)

        try await fixture.model.setUsageAlertsEnabled(false)
        try await fixture.model.setLowBalanceCents(nil, provider: .typeSafe)
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: account.id)?.lowBalance, LowBalanceAlertMemory())
        try await fixture.model.setLowBalanceCents(500, provider: .typeSafe)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await save(fixture, balance(account.id, cents: 90, readAgo: 5))

        let after = await posts(fixture)
        XCTAssertEqual(after.count, 2)
    }

    /// A post waiting behind an earlier side effect is dropped when the
    /// threshold is cleared before it runs.
    func testAQueuedAlertDoesNotPostAfterTheThresholdIsCleared() async throws {
        let gate = LowBalanceSaveGate()
        let directory = try makeTempDirectory()
        let store = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"), saveStates: { _ in await gate.pass() })
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store)
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        gate.arm()
        try await fixture.snapshots.save(balance(account.id, cents: 100))
        await gate.waitUntilHeld()
        try await fixture.model.setLowBalanceCents(nil, provider: .typeSafe)
        gate.release()
        await fixture.model.flushAlertEvaluations()

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0)
    }

    /// …and when a top-up arrives before it runs.
    func testAQueuedAlertDoesNotPostAfterATopUp() async throws {
        let gate = LowBalanceSaveGate()
        let directory = try makeTempDirectory()
        let store = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"), saveStates: { _ in await gate.pass() })
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store)
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        gate.arm()
        try await fixture.snapshots.save(balance(account.id, cents: 100))
        await gate.waitUntilHeld()
        try await fixture.snapshots.save(balance(account.id, cents: 3_000, readAgo: 5))
        gate.release()
        await fixture.model.flushAlertEvaluations()

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 0)
    }

    /// Control for the two above: nothing changed, the held post goes out.
    func testAQueuedAlertPostsWhenNothingChanged() async throws {
        let gate = LowBalanceSaveGate()
        let directory = try makeTempDirectory()
        let store = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"), saveStates: { _ in await gate.pass() })
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store)
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)

        gate.arm()
        try await fixture.snapshots.save(balance(account.id, cents: 100))
        await gate.waitUntilHeld()
        gate.release()
        await fixture.model.flushAlertEvaluations()

        let posts = await posts(fixture)
        XCTAssertEqual(posts.count, 1)
    }

    /// A row raised by a fresh reading goes when the reading grows old (a
    /// long fetch failure), and comes back with the next fresh low one.
    func testTheRowNeedsACurrentReading() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let account = try await signedIn(fixture)
        try await save(fixture, balance(account.id, cents: 100))
        XCTAssertEqual(fixture.model.attentionRows(now: now).map(\.subject), [.lowBalance])

        XCTAssertEqual(fixture.model.attentionRows(now: now.addingTimeInterval(UsageEvidence.maxAge + 60)), [],
                       "the same reading, now too old to speak for the present")
        try await save(fixture, balance(account.id, cents: 90, readAgo: 5))
        XCTAssertEqual(fixture.model.attentionRows(now: now).map(\.subject), [.lowBalance])
    }
}

@MainActor
private final class LowBalanceSaveGate {
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
