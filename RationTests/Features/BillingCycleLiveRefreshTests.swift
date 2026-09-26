import AppKit
import XCTest
@testable import Ration

/// What reloads an open Billing-cycle card, and where its
/// summaries are computed.
@MainActor
final class BillingCycleLiveRefreshTests: XCTestCase {
    private let utcZone = TimeZone(identifier: "UTC")!
    private let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, zone: TimeZone? = nil) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone ?? utcZone
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func account(
        _ provider: Provider = .claude, renewalDay: Int? = 14, plan: PlanTier? = nil, paused: Bool = false
    ) -> AccountRecord {
        AccountRecord(id: UUID(), provider: provider, label: "A", webProfileID: UUID(),
                      displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0),
                      billingRenewalDay: renewalDay, isPaused: paused, plan: plan)
    }

    private func key(_ accounts: [AccountRecord], revision: Int = 0, now: Date, zone: TimeZone? = nil) -> BillingCycleLoadKey {
        BillingCycleLoadKey.make(accounts: accounts, historyRevision: revision, now: now, timeZone: zone ?? utcZone)
    }

    // MARK: Load key

    func testKeyIsStableWithinADayWhenNothingChanges() {
        let accounts = [account()]
        XCTAssertEqual(key(accounts, now: at(2026, 9, 20, 9)), key(accounts, now: at(2026, 9, 20, 17, 30)))
    }

    func testARevisionBumpChangesTheKey() {
        let accounts = [account()]
        let now = at(2026, 9, 20, 9)
        XCTAssertNotEqual(key(accounts, revision: 3, now: now), key(accounts, revision: 4, now: now))
    }

    func testMidnightChangesTheKey() {
        let accounts = [account(renewalDay: 14)]
        let before = key(accounts, now: at(2026, 9, 20, 23, 59))
        let after = key(accounts, now: at(2026, 9, 21, 0, 1))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.accounts.map(\.cycleStart), after.accounts.map(\.cycleStart),
                       "no renewal inside: only the day part moved")
    }

    /// The window stays open across the renewal midnight.
    func testCrossingTheRenewalBoundaryMovesTheCycleStart() {
        let accounts = [account(renewalDay: 14)]
        let before = key(accounts, now: at(2026, 9, 13, 23, 59))
        let after = key(accounts, now: at(2026, 9, 14, 0, 1))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.accounts.first?.cycleStart, at(2026, 8, 14, 0))
        XCTAssertEqual(after.accounts.first?.cycleStart, at(2026, 9, 14, 0))
    }

    func testATimeZoneChangeChangesTheKey() {
        let accounts = [account()]
        let now = at(2026, 9, 20, 9)
        XCTAssertNotEqual(key(accounts, now: now, zone: utcZone), key(accounts, now: now, zone: kyiv))
        // Even a zone with today's same offset (so the same day and cycle
        // starts) is a new key: the zone's own rules can differ later.
        let helsinki = TimeZone(identifier: "Europe/Helsinki")!
        XCTAssertNotEqual(key(accounts, now: now, zone: helsinki), key(accounts, now: now, zone: kyiv))
    }

    func testAccountSettingsChangeTheKey() {
        let base = account(renewalDay: 14, plan: .claudePro)
        let now = at(2026, 9, 20, 9)
        var renewal = base
        renewal.billingRenewalDay = 15
        var plan = base
        plan.plan = .claudeMax5x
        var paused = base
        paused.isPaused = true
        let reference = key([base], now: now)
        XCTAssertNotEqual(reference, key([renewal], now: now))
        XCTAssertNotEqual(reference, key([plan], now: now))
        XCTAssertNotEqual(reference, key([paused], now: now))
        XCTAssertNotEqual(reference, key([base, account()], now: now))
    }

    func testAnAccountWithoutARenewalDayHasNoCycleStart() {
        let k = key([account(renewalDay: nil)], now: at(2026, 9, 20, 9))
        XCTAssertEqual(k.accounts.count, 1)
        XCTAssertNil(k.accounts.first?.cycleStart)
    }

    // MARK: Refresh clock

    private final class ZoneBox {
        var zone: TimeZone
        init(_ zone: TimeZone) { self.zone = zone }
    }

    private func makeStore(_ dir: URL, clock: RevisionTestClock, gate: RevisionSleepGate) -> UsageHistoryStore {
        UsageHistoryStore(rootDirectory: dir, timeZone: utcZone, now: { clock.now },
                          revisionThrottle: 60, revisionSleep: { seconds in await gate.sleep(seconds) })
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTheClockStartsFromTheStoreAndTheSystem() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let wall = RevisionTestClock(1_000)
        let store = makeStore(dir, clock: wall, gate: RevisionSleepGate())
        let clock = HistoryRefreshClock(
            history: store, notificationCenter: NotificationCenter(),
            now: { wall.now }, timeZone: { self.kyiv }
        )
        XCTAssertEqual(clock.historyRevision, 0)
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(clock.timeZone, kyiv)
    }

    /// A revision bump reaches the card's key once per throttled bump, and
    /// re-samples the time so a renewal crossed since the last reload is seen.
    func testARevisionBumpReachesTheClockOncePerThrottledBump() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let wall = RevisionTestClock(1_000)
        let gate = RevisionSleepGate()
        let store = makeStore(dir, clock: wall, gate: gate)
        let acc = account()
        await store.load(activeAccountIDs: [acc.id])
        let clock = HistoryRefreshClock(history: store, notificationCenter: NotificationCenter(),
                                        now: { wall.now }, timeZone: { self.utcZone })
        var revisions: [Int] = []
        let sub = clock.$historyRevision.sink { revisions.append($0) }
        defer { sub.cancel() }

        for step in 0..<3 {
            let t = 1_000 + TimeInterval(step) * 10
            wall.set(t)
            store.record(account: acc, snapshot: UsageSnapshot(
                accountID: acc.id, fetchedAt: Date(timeIntervalSince1970: t),
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9 - Double(step) * 0.1, resetsAt: nil),
                weekly: nil))
        }
        try await settle { clock.historyRevision == 1 }
        XCTAssertEqual(revisions, [0, 1], "three writes in a minute: one reload now")
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 1_000))

        wall.set(1_060)
        await gate.waitForSleepers(1)
        await gate.releaseAll()
        try await settle { clock.historyRevision == 2 }
        XCTAssertEqual(revisions, [0, 1, 2], "and one trailing reload")
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 1_060))
    }

    func testMidnightNotificationReSamplesTheTime() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let center = NotificationCenter()
        let wall = RevisionTestClock(at(2026, 9, 13, 23, 59).timeIntervalSince1970)
        let store = makeStore(dir, clock: wall, gate: RevisionSleepGate())
        let clock = HistoryRefreshClock(history: store, notificationCenter: center,
                                        now: { wall.now }, timeZone: { self.utcZone })
        let accounts = [account(renewalDay: 14)]
        let before = BillingCycleLoadKey.make(accounts: accounts, historyRevision: clock.historyRevision,
                                              now: clock.now, timeZone: clock.timeZone)

        wall.now = at(2026, 9, 14, 0, 0)
        center.post(name: .NSCalendarDayChanged, object: nil)
        try await settle { clock.now == wall.now }
        XCTAssertEqual(clock.now, at(2026, 9, 14, 0, 0))
        let after = BillingCycleLoadKey.make(accounts: accounts, historyRevision: clock.historyRevision,
                                             now: clock.now, timeZone: clock.timeZone)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.accounts.first?.cycleStart, at(2026, 9, 14, 0), "the card reloads into the new cycle")
    }

    /// The day notification may arrive off the main thread.
    func testADayNotificationPostedOffMainIsDelivered() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let center = NotificationCenter()
        let wall = RevisionTestClock(1_000)
        let store = makeStore(dir, clock: wall, gate: RevisionSleepGate())
        let clock = HistoryRefreshClock(history: store, notificationCenter: center,
                                        now: { wall.now }, timeZone: { self.utcZone })
        wall.set(90_000)
        await Task.detached {
            center.post(name: .NSCalendarDayChanged, object: nil)
        }.value
        try await settle { clock.now == Date(timeIntervalSince1970: 90_000) }
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 90_000))
    }

    func testTimeZoneNotificationReReadsTheZone() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let center = NotificationCenter()
        let wall = RevisionTestClock(1_000)
        let zone = ZoneBox(utcZone)
        let store = makeStore(dir, clock: wall, gate: RevisionSleepGate())
        let clock = HistoryRefreshClock(history: store, notificationCenter: center,
                                        now: { wall.now }, timeZone: { zone.zone })
        let accounts = [account()]
        let before = BillingCycleLoadKey.make(accounts: accounts, historyRevision: 0, now: clock.now, timeZone: clock.timeZone)
        zone.zone = kyiv
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await settle { clock.timeZone == self.kyiv }
        XCTAssertEqual(clock.timeZone, kyiv)
        let after = BillingCycleLoadKey.make(accounts: accounts, historyRevision: 0, now: clock.now, timeZone: clock.timeZone)
        XCTAssertNotEqual(before, after)
    }

    /// F2: waking from sleep re-reads the time and zone, so a midnight or
    /// renewal slept through re-keys the card even with no poll and no day
    /// notification.
    func testWakeReSamplesTheTimeAndZone() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let wake = NotificationCenter()
        let wall = RevisionTestClock(at(2026, 9, 13, 22).timeIntervalSince1970)
        let zone = ZoneBox(utcZone)
        let store = makeStore(dir, clock: wall, gate: RevisionSleepGate())
        let clock = HistoryRefreshClock(history: store, notificationCenter: NotificationCenter(),
                                        wakeNotificationCenter: wake,
                                        now: { wall.now }, timeZone: { zone.zone })
        wall.now = at(2026, 9, 14, 7)
        zone.zone = kyiv
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle { clock.now == wall.now }
        XCTAssertEqual(clock.now, at(2026, 9, 14, 7))
        XCTAssertEqual(clock.timeZone, kyiv)
        let key = BillingCycleLoadKey.make(accounts: [account(renewalDay: 14)], historyRevision: 0,
                                           now: clock.now, timeZone: clock.timeZone)
        XCTAssertEqual(key.accounts.first?.cycleStart, at(2026, 9, 14, 0, zone: kyiv))
    }

    /// Closing the window stops observing; reopening catches up at once.
    func testStopRemovesTheObserversAndStartCatchesUp() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let center = NotificationCenter()
        let wake = NotificationCenter()
        let wall = RevisionTestClock(1_000)
        let store = makeStore(dir, clock: wall, gate: RevisionSleepGate())
        let clock = HistoryRefreshClock(history: store, notificationCenter: center,
                                        wakeNotificationCenter: wake,
                                        now: { wall.now }, timeZone: { self.utcZone })
        clock.stop()
        wall.set(90_000)
        center.post(name: .NSCalendarDayChanged, object: nil)
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 1_000), "stopped: no observers left")

        clock.start()
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 90_000), "start re-samples at once")
        wall.set(180_000)
        center.post(name: .NSCalendarDayChanged, object: nil)
        try await settle { clock.now == Date(timeIntervalSince1970: 180_000) }
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 180_000), "and observes again")
    }

    // MARK: Off-main batch

    private func v2Hours(from start: Date, count: Int, used: Double) -> [UsageHourlyBucket] {
        (0..<count).map { i in
            UsageHourlyBucket(hourStart: start.addingTimeInterval(TimeInterval(i) * 3600), tzOffsetSeconds: 0,
                              consumed: 0, minRemaining: 1 - used, sampleCount: 12,
                              observedSeconds: 3600, usedSeconds: 3600 * used, resetCount: 0)
        }
    }

    private func inputs() -> [BillingCycleCardInput] {
        let start = at(2026, 9, 14, 0)
        let claude = account(.claude, renewalDay: 14)
        let gpt = account(.chatGPT, renewalDay: 14)
        let unset = account(.claude, renewalDay: nil)
        return [
            BillingCycleCardInput(account: claude, weekly: v2Hours(from: start, count: 60, used: 0.4),
                                  fiveHour: [], modelWeekly: v2Hours(from: start, count: 60, used: 0.2),
                                  fablePresent: true, fableLabel: "Fable"),
            BillingCycleCardInput(account: gpt, weekly: v2Hours(from: start, count: 60, used: 0.6),
                                  fiveHour: [], modelWeekly: [], fablePresent: false, fableLabel: nil),
            BillingCycleCardInput(account: unset, weekly: [], fiveHour: [], modelWeekly: [],
                                  fablePresent: false, fableLabel: nil),
        ]
    }

    func testTheBatchRunsOffTheMainActorAndMatchesTheSynchronousPass() async {
        let now = at(2026, 9, 16, 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcZone
        let given = inputs()
        let sync = BillingCycleSectionModel.cards(given, now: now, calendar: calendar)
        let probe = IsolationProbe()
        let batch = await BillingCycleSectionModel.cardsOffMain(
            given, now: now, calendar: calendar,
            isolationProbe: { onMain in probe.record(onMain) }
        )
        XCTAssertEqual(batch, sync)
        XCTAssertEqual(probe.observations, [false], "the pass must not run on the main thread")
        XCTAssertEqual(batch.count, 3)
        guard case let .tracked(_, _, _, _, claudeSummary, fable) = batch[0] else { return XCTFail("tracked") }
        XCTAssertFalse(claudeSummary.isLegacyLowerBound)
        XCTAssertEqual(claudeSummary.capacityUtilization, 0.4, accuracy: 1e-9)
        XCTAssertEqual(fable?.summary?.capacityUtilization ?? 0, 0.2, accuracy: 1e-9)
        guard case let .tracked(_, _, _, _, gptSummary, _) = batch[1] else { return XCTFail("tracked") }
        XCTAssertEqual(gptSummary.family, .fixed)
        XCTAssertEqual(gptSummary.capacityUtilization, 0.6, accuracy: 1e-9)
        XCTAssertEqual(batch[2], .noRenewalDay(id: given[2].account.id, label: "A", provider: .claude))
    }

    /// A superseded reload's pass stops early (F1): cancelling the awaiting
    /// task cancels the detached pass, which checks before every account and
    /// returns nothing.
    func testCancellingTheReloadStopsTheDetachedPass() async {
        let now = at(2026, 9, 16, 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcZone
        let given = Array(repeating: inputs(), count: 20).flatMap { $0 }
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let reload = Task { () -> [BillingCycleCard] in
            await BillingCycleSectionModel.cardsOffMain(
                given, now: now, calendar: calendar,
                isolationProbe: { _ in
                    started.signal()
                    proceed.wait()
                }
            )
        }
        await Task.detached { waitOn(started) }.value
        reload.cancel()
        proceed.signal()
        let result = await reload.value
        XCTAssertEqual(result, [], "a cancelled pass computes no further cards")
    }

    func testTheSynchronousPassStopsWhenAsked() {
        let now = at(2026, 9, 16, 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcZone
        let counter = IsolationProbe()
        let result = BillingCycleSectionModel.cards(inputs(), now: now, calendar: calendar, shouldStop: {
            counter.record(true)
            return counter.observations.count > 2
        })
        XCTAssertEqual(result, [])
        XCTAssertEqual(counter.observations.count, 3, "checked before each account, stopped at the third")
    }

    /// The batch is exactly the per-account `card` mapping, in input order.
    func testTheBatchIsThePerAccountMappingInOrder() {
        let now = at(2026, 9, 16, 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcZone
        let given = inputs()
        let expected = given.map { input in
            BillingCycleSectionModel.card(
                account: input.account, weekly: input.weekly, fiveHour: input.fiveHour,
                modelWeekly: input.modelWeekly, fablePresent: input.fablePresent,
                fableLabel: input.fableLabel, now: now, calendar: calendar)
        }
        XCTAssertEqual(BillingCycleSectionModel.cards(given, now: now, calendar: calendar), expected)
    }
}

/// Collects `Thread.isMainThread` from inside the detached pass.
final class IsolationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(_ onMain: Bool) {
        lock.lock()
        values.append(onMain)
        lock.unlock()
    }

    var observations: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// The Patterns view reloads on the same throttled revision.
@MainActor
final class HistoryPatternsLoadKeyTests: XCTestCase {
    func testTheRevisionIsPartOfThePatternsKey() {
        let identity = "all|fiveHour|A,B"
        XCTAssertNotEqual(HistoryView.patternsLoadKey(identity: identity, historyRevision: 1),
                          HistoryView.patternsLoadKey(identity: identity, historyRevision: 2))
        XCTAssertEqual(HistoryView.patternsLoadKey(identity: identity, historyRevision: 2),
                       HistoryView.patternsLoadKey(identity: identity, historyRevision: 2))
        XCTAssertNotEqual(HistoryView.patternsLoadKey(identity: identity, historyRevision: 2),
                          HistoryView.patternsLoadKey(identity: "all|weekly|A,B", historyRevision: 2))
    }

    /// While Billing cycle is shown, a revision bump does not
    /// reload the hidden Patterns charts; returning to Patterns does.
    func testARevisionDoesNotReloadHiddenPatterns() {
        let identity = "all|fiveHour|A,B"
        let hiddenBefore = HistoryView.patternsLoadKey(identity: identity, historyRevision: 1, isPatternsActive: false)
        let hiddenAfter = HistoryView.patternsLoadKey(identity: identity, historyRevision: 2, isPatternsActive: false)
        XCTAssertNil(hiddenBefore)
        XCTAssertEqual(hiddenBefore, hiddenAfter, "no reload while hidden")
        let shown = HistoryView.patternsLoadKey(identity: identity, historyRevision: 2, isPatternsActive: true)
        XCTAssertNotNil(shown)
        XCTAssertNotEqual(hiddenAfter, shown, "switching back reloads")
    }
}

/// Blocks the calling (non-main) thread on `semaphore`, from a synchronous frame.
private func waitOn(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
