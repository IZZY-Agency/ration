import Combine
import XCTest
@testable import Ration

/// `AppModel.switchAdvice`: recomputed inside the snapshot pass (before that
/// revision's alert decision), on account/settings/Fable changes, and on a
/// clock tick — published only when it changes.
@MainActor
final class AppModelSwitchAdviceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100_000)

    // MARK: Snapshot pass

    func testCrossingAndFirstActivityInOneRefreshAdviseAtThatPass() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)

        // A's only prior sample: no activity yet, below Warn.
        let before = snapshot(a.id, at: t0.addingTimeInterval(-300), fiveHour: 0.30)
        fixture.model.history.record(account: a, snapshot: before)
        try await fixture.snapshots.save(before)
        try await fixture.snapshots.save(snapshot(b.id, at: t0, fiveHour: 0.90))
        XCTAssertEqual(fixture.model.switchAdvice, [])

        // One refresh: A burns 10 points (first activity) AND crosses 75% Warn.
        try await fixture.snapshots.save(snapshot(a.id, at: t0, fiveHour: 0.20))

        // History has not recorded this snapshot yet (that happens after the
        // save, in `onSnapshotSaved`) — the pass must still see the activity.
        XCTAssertEqual(fixture.model.history.rawSamples(accountID: a.id, kind: .fiveHour).count, 1)
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])
        XCTAssertEqual(fixture.model.advice(forAccount: a.id)?.toAccountID, b.id)
        XCTAssertEqual(fixture.model.advice(forAccount: a.id)?.fromAccountID, a.id)
        XCTAssertNil(fixture.model.advice(forAccount: b.id))
    }

    func testTargetPausedMidFlightClearsAdviceOnNextPass() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])

        try await fixture.model.setPaused(accountID: b.id, paused: true)
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice, [])
        // A later snapshot pass must not resurrect it.
        try await fixture.snapshots.save(snapshot(a.id, at: t0.addingTimeInterval(1), fiveHour: 0.19))
        XCTAssertEqual(fixture.model.switchAdvice, [])
    }

    func testTargetBeingPausedIsDroppedBeforeThePausePersists() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])

        let pause = try fixture.model.requestSetPaused(accountID: b.id, paused: true)
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice, [])
        try await pause.value
        await fixture.model.flushSwitchAdvice()
        XCTAssertEqual(fixture.model.switchAdvice, [])
    }

    func testAccountListChangeRecomputes() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toLabel), ["B"])

        try await fixture.model.renameAccount(id: b.id, label: "Work")
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice.map(\.toLabel), ["Work"])
    }

    func testRolledBackRemovalRestoresAdviceImmediately() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])

        struct ProfileRemovalFailed: Error {}
        fixture.profileManager.removeError = ProfileRemovalFailed()
        do {
            try await fixture.model.removeAccount(id: b.id)
            XCTFail("Profile removal failure must roll the removal back")
        } catch {}
        XCTAssertNotNil(fixture.model.accounts.first { $0.id == b.id })
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])
    }

    func testTargetChangeFromBToCRepublishes() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        let c = try await signIn(fixture, label: "C")
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90), (c, 0.50)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])

        var published: [[SwitchAdvice]] = []
        let cancellable = fixture.model.$switchAdvice.dropFirst().sink { published.append($0) }
        defer { cancellable.cancel() }

        try await fixture.snapshots.save(snapshot(b.id, at: t0.addingTimeInterval(1), fiveHour: 0.45))

        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [c.id])
        XCTAssertEqual(published.map { $0.map(\.toAccountID) }, [[c.id]])
    }

    func testUnchangedInputsDoNotRepublish() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        await fixture.model.flushSwitchAdvice()

        var publishes = 0
        let cancellable = fixture.model.$switchAdvice.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        fixture.model.recomputeSwitchAdvice()
        fixture.model.switchAdviceTick()
        fixture.model.switchAdviceTick()
        try await fixture.snapshots.save(snapshot(b.id, at: t0.addingTimeInterval(1), fiveHour: 0.90))
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])
    }

    // MARK: Clock + settings

    func testClockOnlyInUseExpiryRemovesAdviceAfterTick() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertFalse(fixture.model.switchAdvice.isEmpty)

        // 16 minutes later: past the 15-minute IN USE phase, evidence still
        // current — so only the in-use expiry can clear the advice.
        XCTAssertGreaterThan(UsageEvidence.maxAge, 16 * 60)
        XCTAssertLessThan(InUsePhase.inUseThreshold, 16 * 60)
        clock.now = t0.addingTimeInterval(16 * 60)
        XCTAssertFalse(fixture.model.switchAdvice.isEmpty, "Nothing recomputes without a tick")

        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice, [])
    }

    func testThresholdChangeRecomputes() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        // 70% used: in use, but below the default 75% Warn.
        try await makeAInUse(fixture, a: a, fiveHour: 0.30, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice, [])

        try await fixture.model.setWarningPercent(65, provider: .claude, window: .fiveHour)
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])
    }

    func testBurstOfTriggersPublishesOnce() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        await fixture.model.flushSwitchAdvice()

        var publishes = 0
        let cancellable = fixture.model.$switchAdvice.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        clock.now = t0.addingTimeInterval(16 * 60)
        fixture.model.switchAdviceTick()
        fixture.model.fableVerdictsDidChange()
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(fixture.model.switchAdvice, [])
    }

    // MARK: Notification capture

    func testCrossingNotificationOfTheFromAccountCarriesTheAdviceLine() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        // C sits at the same 80% but is idle: it crosses Warn too, yet is
        // nobody's `from` — its notification must stay plain.
        let c = try await signIn(fixture, label: "C")
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.snapshots.save(snapshot(c.id, at: t0, fiveHour: 0.20))

        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.model.advice(forAccount: a.id)?.toAccountID, b.id)

        let posts = await fixture.scheduler.posts
        let warnA = AlertMessage.id(for: .threshold(kind: .fiveHour, tier: .warning, percent: 75), accountID: a.id)
        let warnC = AlertMessage.id(for: .threshold(kind: .fiveHour, tier: .warning, percent: 75), accountID: c.id)
        let postA = try XCTUnwrap(posts.first { $0.id == warnA })
        let postC = try XCTUnwrap(posts.first { $0.id == warnC })
        XCTAssertTrue(postA.body.hasSuffix("\nSwitch to B — 90% of its 5 hours left."), postA.body)
        XCTAssertFalse(postC.body.contains("Switch"), postC.body)
    }

    func testRedactedCrossingNotificationCarriesOnlyTheGenericAdviceLine() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.model.setRedactNotifications(true)

        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        let warnA = AlertMessage.id(for: .threshold(kind: .fiveHour, tier: .warning, percent: 75), accountID: a.id)
        let post = try XCTUnwrap(posts.first { $0.id == warnA })
        XCTAssertTrue(post.body.hasSuffix("\nAnother Claude account has more room."), post.body)
        XCTAssertFalse(post.body.contains("B —"))
        XCTAssertNil(post.body.rangeOfCharacter(from: .decimalDigits))
    }

    // MARK: Composition-time advice

    /// The target's pause starts after the crossing was decided but before
    /// the notification is composed: the line must not name it.
    func testTargetPauseStartedBeforeCompositionDropsTheLine() async throws {
        let clock = SwitchAdviceClock(t0)
        let gate = SaveGate()
        let (fixture, a, b) = try await makeGatedCrossing(clock: clock, gate: gate, targetResetsAt: nil)
        defer { fixture.removeFiles() }

        let pause = try fixture.model.requestSetPaused(accountID: b.id, paused: true)
        gate.release()
        await fixture.model.flushAlertEvaluations()
        try await pause.value

        let body = try await warnBody(fixture, accountID: a.id)
        XCTAssertFalse(body.contains("Switch"), body)
    }

    /// The target's window is overtaken by its reset between ticks (no
    /// recompute has run): the cached advice is stale, the line must go.
    func testTargetWindowOvertakenBeforeCompositionDropsTheLine() async throws {
        let clock = SwitchAdviceClock(t0)
        let gate = SaveGate()
        let (fixture, a, _) = try await makeGatedCrossing(
            clock: clock,
            gate: gate,
            targetResetsAt: t0.addingTimeInterval(240)
        )
        defer { fixture.removeFiles() }

        clock.now = t0.addingTimeInterval(300)
        gate.release()
        await fixture.model.flushAlertEvaluations()

        let body = try await warnBody(fixture, accountID: a.id)
        XCTAssertFalse(body.contains("Switch"), body)
    }

    /// Two accounts, alerts on, B saved as the target; A then crosses Warn
    /// while the alert-state save (the side effect queued before the post)
    /// is held — so the test can change the world before composition.
    private func makeGatedCrossing(
        clock: SwitchAdviceClock,
        gate: SaveGate,
        targetResetsAt: Date?
    ) async throws -> (AlertsFixture, AccountRecord, AccountRecord) {
        let directory = try makeTempDirectory()
        let store = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json"),
            saveStates: { _ in await gate.pass() }
        )
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store, now: { clock.now })
        let (a, b) = try await signInTwo(fixture)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: b.id,
            fetchedAt: t0,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.90, resetsAt: targetResetsAt),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        gate.arm()
        try await makeAInUseAtWarn(fixture, a: a, targets: [])
        await gate.waitUntilHeld()
        XCTAssertEqual(fixture.model.advice(forAccount: a.id)?.toAccountID, b.id, "Cached advice names B")
        return (fixture, a, b)
    }

    private func warnBody(_ fixture: AlertsFixture, accountID: UUID) async throws -> String {
        let posts = await fixture.scheduler.posts
        let warn = AlertMessage.id(for: .threshold(kind: .fiveHour, tier: .warning, percent: 75), accountID: accountID)
        return try XCTUnwrap(posts.first { $0.id == warn }).body
    }

    // MARK: Feature switches

    func testSwitchSuggestionsOffPublishesNoAdviceAndOnRestoresIt() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id], "premise")

        try await fixture.model.setFeature(.switchAdvice, enabled: false)
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice, [])
        XCTAssertNil(fixture.model.currentAdvice(forAccount: a.id))
        XCTAssertNil(fixture.model.advice(forAccount: a.id))
        // A later snapshot pass does not bring it back while off.
        try await fixture.snapshots.save(snapshot(a.id, at: t0.addingTimeInterval(1), fiveHour: 0.19))
        XCTAssertEqual(fixture.model.switchAdvice, [])
        XCTAssertTrue(fixture.model.focusModel(now: t0).switchLines.isEmpty, "no Focus \"Next …\" lines")

        try await fixture.model.setFeature(.switchAdvice, enabled: true)
        await fixture.model.flushSwitchAdvice()

        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])
        XCTAssertEqual(fixture.model.currentAdvice(forAccount: a.id)?.toAccountID, b.id)
    }

    func testInUseDetectionOffAlsoEmptiesAdvice() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id], "premise")

        try await fixture.model.setFeature(.inUse, enabled: false)
        await fixture.model.flushSwitchAdvice()

        XCTAssertTrue(fixture.model.settings.featureSwitchAdviceEnabled, "the Switch choice itself is kept")
        XCTAssertEqual(fixture.model.switchAdvice, [])
        XCTAssertNil(fixture.model.currentAdvice(forAccount: a.id))

        try await fixture.model.setFeature(.inUse, enabled: true)
        await fixture.model.flushSwitchAdvice()
        XCTAssertEqual(fixture.model.switchAdvice.map(\.toAccountID), [b.id])
    }

    func testSwitchSuggestionsOffLeavesTheWarnNotificationWithoutASwitchLine() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        let (a, b) = try await signInTwo(fixture)
        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.model.setFeature(.switchAdvice, enabled: false)
        await fixture.model.flushSwitchAdvice()

        try await makeAInUseAtWarn(fixture, a: a, targets: [(b, 0.90)])
        await fixture.model.flushAlertEvaluations()

        let body = try await warnBody(fixture, accountID: a.id)
        XCTAssertFalse(body.contains("Switch"), body)
    }

    // MARK: Helpers

    // MARK: Plan readings reach advice before the store saves them

    /// B's stored plan says Pro; its newest snapshot reads Max 20x. The
    /// snapshot is saved straight to the store, so the account record is
    /// NEVER updated (the plan save is, in effect, held forever): advice and
    /// the notification must still size B as Max 20x.
    func testNewestPlanReadingSizesTheTargetBeforeThePlanIsSaved() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudePro)
        let (a, b) = try await signInTwo(fixture)
        let c = try await signIn(fixture, label: "C")
        try await fixture.model.requestSetPlan(accountID: c.id, plan: .claudeMax20x).value
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertEqual(fixture.model.accounts.first { $0.id == b.id }?.plan, .claudePro, "premise")

        // B: 90% of a Pro (0.9 units) vs C: 50% of a Max 20x (10 units) → C.
        try await fixture.snapshots.save(snapshot(c.id, at: t0, fiveHour: 0.50))
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: b.id,
            fetchedAt: t0,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.90, resetsAt: nil),
            weekly: nil,
            planDetection: .tier(.claudeMax20x)
        ))
        try await makeAInUseAtWarn(fixture, a: a, targets: [])
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(fixture.model.accounts.first { $0.id == b.id }?.plan, .claudePro, "record not yet saved")
        XCTAssertEqual(fixture.model.advice(forAccount: a.id)?.toAccountID, b.id, "B read as Max 20x: 18 units")
        XCTAssertEqual(fixture.model.currentAdvice(forAccount: a.id)?.toAccountID, b.id)
        let body = try await warnBody(fixture, accountID: a.id)
        XCTAssertTrue(body.contains("B"), "the notification names B: \(body)")
    }

    /// A user's plan choice outranks any reading, saved or not.
    func testNewestPlanReadingNeverOverridesAUserChoiceInAdvice() async throws {
        let clock = SwitchAdviceClock(t0)
        let fixture = try makeAlertsFixture(now: { clock.now })
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudePro)
        let (a, b) = try await signInTwo(fixture)
        let c = try await signIn(fixture, label: "C")
        try await fixture.model.requestSetPlan(accountID: b.id, plan: .claudePro).value
        try await fixture.model.requestSetPlan(accountID: c.id, plan: .claudeMax20x).value

        try await fixture.snapshots.save(snapshot(c.id, at: t0, fiveHour: 0.50))
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: b.id,
            fetchedAt: t0,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.90, resetsAt: nil),
            weekly: nil,
            planDetection: .tier(.claudeMax20x)
        ))
        try await makeAInUseAtWarn(fixture, a: a, targets: [])

        XCTAssertEqual(fixture.model.advice(forAccount: a.id)?.toAccountID, c.id)
    }

    private func signIn(_ fixture: AlertsFixture, label: String) async throws -> AccountRecord {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: label)
        return try XCTUnwrap(fixture.model.accounts.first { $0.label == label })
    }

    private func signInTwo(_ fixture: AlertsFixture) async throws -> (AccountRecord, AccountRecord) {
        try await fixture.model.load(startBackgroundRefresh: false)
        let a = try await signIn(fixture, label: "A")
        let b = try await signIn(fixture, label: "B")
        return (a, b)
    }

    /// A burns 0.30 → 0.20 five minutes apart (IN USE, 80% ≥ Warn 75%).
    private func makeAInUseAtWarn(
        _ fixture: AlertsFixture,
        a: AccountRecord,
        targets: [(AccountRecord, Double)]
    ) async throws {
        try await makeAInUse(fixture, a: a, fiveHour: 0.20, targets: targets)
    }

    private func makeAInUse(
        _ fixture: AlertsFixture,
        a: AccountRecord,
        fiveHour: Double,
        targets: [(AccountRecord, Double)]
    ) async throws {
        for (target, remaining) in targets {
            try await fixture.snapshots.save(snapshot(target.id, at: t0, fiveHour: remaining))
        }
        let before = snapshot(a.id, at: t0.addingTimeInterval(-300), fiveHour: fiveHour + 0.10)
        fixture.model.history.record(account: a, snapshot: before)
        let now = snapshot(a.id, at: t0, fiveHour: fiveHour)
        fixture.model.history.record(account: a, snapshot: now)
        try await fixture.snapshots.save(now)
    }

    private func snapshot(_ accountID: UUID, at date: Date, fiveHour: Double) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: date,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: fiveHour, resetsAt: nil),
            weekly: nil
        )
    }
}

@MainActor
private final class SwitchAdviceClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Holds the next alert-state save until released.
@MainActor
private final class SaveGate {
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
        await withCheckedContinuation { continuation in
            heldSignal = continuation
        }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
