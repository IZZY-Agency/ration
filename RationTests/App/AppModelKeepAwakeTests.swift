import WebKit
import XCTest
@testable import Ration

/// Keep awake through the model: the automatic hold follows a real burn
/// through refresh, the switches, the power source and the 60 s tick; the
/// user's override holds on its own terms. Every hold is observed on the
/// assertion spy, never inferred from state.
@MainActor
final class AppModelKeepAwakeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Automatic hold

    func testABurnHoldsIdleSleepWhileTheSwitchIsOn() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()

        XCTAssertEqual(fixture.assertion.holds, [KeepAwakeController.automaticReason])
        XCTAssertTrue(fixture.assertion.isHeld)
        XCTAssertFalse(fixture.assertion.isDisplayHeld, "an agent run needs no screen")
        XCTAssertEqual(fixture.model.keepAwakeStatus, .automatic)
    }

    func testTheSameBurnHoldsNothingWhileTheSwitchIsOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.signInAndBurn()

        XCTAssertEqual(fixture.assertion.holds, [])
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    func testTheSwitchIsDeadWhileInUseDetectionIsOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.settings.setFeature(.inUse, enabled: false)
        try await fixture.signInAndBurn()

        XCTAssertEqual(fixture.assertion.holds, [])
    }

    func testBatteryPowerReleasesTheAutomaticHoldAndTheAdapterRestoresIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()
        XCTAssertTrue(fixture.assertion.isHeld)

        fixture.power.powerSource = .battery
        fixture.power.firePowerSourceChanged()
        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)

        fixture.power.powerSource = .external
        fixture.power.firePowerSourceChanged()
        XCTAssertTrue(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.assertion.holds.count, 2)
    }

    func testABurnOnBatteryHoldsNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        fixture.power.powerSource = .battery
        try await fixture.signInAndBurn()

        XCTAssertEqual(fixture.assertion.holds, [])
    }

    /// The IN USE phase ends 15 minutes after the last observed burn; the
    /// tick (not a refresh) lets the hold go.
    func testTheHoldAgesOutOnTheTick() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()
        await fixture.model.history.flush()

        fixture.clock.advance(by: InUsePhase.inUseThreshold - 1)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertTrue(fixture.assertion.isHeld, "still in use")

        fixture.clock.advance(by: 2)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.assertion.releases, 1)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    func testTurningTheSwitchOffReleasesTheHold() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()
        XCTAssertTrue(fixture.assertion.isHeld)

        try await fixture.model.setFeature(.keepAwake, enabled: false)

        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    func testTurningInUseDetectionOffReleasesTheHold() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()
        XCTAssertTrue(fixture.assertion.isHeld)

        try await fixture.model.setFeature(.inUse, enabled: false)

        XCTAssertFalse(fixture.assertion.isHeld)
    }

    /// A recompute queued before `stop()` runs after it; the hold must not
    /// come back behind a stopped model.
    func testStopReleasesTheHoldAndAQueuedRecomputeCannotRetakeIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()
        XCTAssertTrue(fixture.assertion.isHeld)

        fixture.model.switchAdviceTick()
        fixture.model.stop()
        await fixture.model.flushSwitchAdvice()

        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.assertion.holds.count, 1, "nothing re-held after stop")
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    /// Fail closed: with no readable power source the automatic hold is not
    /// taken — the adapter was never established.
    func testAnUnknownPowerSourceHoldsNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        fixture.power.powerSource = .unknown
        try await fixture.signInAndBurn()

        XCTAssertEqual(fixture.assertion.holds, [])
    }

    // MARK: Override

    func testTheOverrideHoldsWhileTheSwitchIsOnAndStopsOnRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)

        fixture.model.startKeepAwake(for: 3_600)

        XCTAssertEqual(fixture.assertion.holds, [KeepAwakeController.manualReason])
        XCTAssertTrue(fixture.assertion.isDisplayHeld, "the override keeps the display on")
        XCTAssertEqual(fixture.model.keepAwakeStatus, .manual(until: start.addingTimeInterval(3_600)))

        fixture.model.stopKeepAwake()

        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    /// The Features switch governs the whole feature: with it off the
    /// footer's eye is disabled, and the model refuses an override from
    /// anywhere else too.
    func testTheOverrideIsRefusedWhileTheSwitchIsOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        fixture.model.startKeepAwake(for: 3_600)

        XCTAssertEqual(fixture.assertion.holds, [])
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    func testTurningTheSwitchOffEndsTheOverrideForGood() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.model.startKeepAwake(for: nil)
        XCTAssertTrue(fixture.assertion.isHeld)

        try await fixture.model.settings.setFeature(.keepAwake, enabled: false)

        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)

        // Forgotten, not paused: the switch coming back does not revive it.
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.assertion.holds.count, 1)
    }

    /// In-use detection off makes the Keep awake switch dead, override included.
    func testTurningInUseDetectionOffEndsTheOverride() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.model.startKeepAwake(for: 3_600)
        XCTAssertTrue(fixture.assertion.isHeld)

        try await fixture.model.settings.setFeature(.inUse, enabled: false)

        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    func testAnOpenEndedOverrideReportsNoEnd() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)

        fixture.model.startKeepAwake(for: nil)

        XCTAssertEqual(fixture.model.keepAwakeStatus, .manual(until: nil))
        fixture.clock.advance(by: 30 * 86_400)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertTrue(fixture.assertion.isHeld)
    }

    func testATimedOverrideEndsOnItsOwn() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.model.startKeepAwake(for: 1_800)

        fixture.clock.advance(by: 1_799)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertTrue(fixture.assertion.isHeld)

        fixture.clock.advance(by: 1)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off, "the ended override is forgotten")

        // Forgotten, not merely expired: a clock that steps back before the
        // deadline (a time-zone or NTP correction) cannot revive it.
        fixture.clock.advance(by: -600)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertFalse(fixture.assertion.isHeld)
        XCTAssertEqual(fixture.assertion.holds.count, 1)
    }

    /// A wall clock set back must not stretch a timed override. The deadline
    /// is monotonic; the banner's end follows what is left.
    func testAWallClockSetBackDoesNotExtendATimedOverride() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.model.startKeepAwake(for: 1_800)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .manual(until: start.addingTimeInterval(1_800)))

        fixture.clock.advance(by: 600)
        fixture.clock.setWall(by: -3_600)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertTrue(fixture.assertion.isHeld)
        XCTAssertEqual(
            fixture.model.keepAwakeStatus,
            .manual(until: fixture.clock.now.addingTimeInterval(1_200)),
            "the banner names the real end: 20 minutes from the wall clock as it is now"
        )

        fixture.clock.advance(by: 1_199)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertTrue(fixture.assertion.isHeld)

        fixture.clock.advance(by: 1)
        fixture.model.switchAdviceTick()
        await fixture.model.flushSwitchAdvice()
        XCTAssertFalse(fixture.assertion.isHeld, "30 minutes of real time, not 90")
        XCTAssertEqual(fixture.model.keepAwakeStatus, .off)
    }

    func testStartingAgainReplacesTheRunningOverride() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.model.startKeepAwake(for: 1_800)

        fixture.model.startKeepAwake(for: nil)

        XCTAssertEqual(fixture.model.keepAwakeStatus, .manual(until: nil))
        XCTAssertEqual(fixture.assertion.holds.count, 1, "the same source keeps its hold")
    }

    /// An explicit choice: the override holds on battery, unlike the
    /// automatic hold.
    func testTheOverrideHoldsOnBattery() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.power.powerSource = .battery

        fixture.model.startKeepAwake(for: 3_600)

        XCTAssertTrue(fixture.assertion.isHeld)
        fixture.power.firePowerSourceChanged()
        XCTAssertTrue(fixture.assertion.isHeld)
    }

    func testTheOverrideOutranksTheAutomaticHoldAndHandsBack() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.settings.setFeature(.keepAwake, enabled: true)
        try await fixture.signInAndBurn()
        XCTAssertEqual(fixture.model.keepAwakeStatus, .automatic)

        fixture.model.startKeepAwake(for: nil)
        XCTAssertEqual(fixture.model.keepAwakeStatus, .manual(until: nil))
        XCTAssertEqual(fixture.assertion.holds.last, KeepAwakeController.manualReason)

        fixture.model.stopKeepAwake()
        XCTAssertEqual(fixture.model.keepAwakeStatus, .automatic)
        XCTAssertEqual(fixture.assertion.holds.last, KeepAwakeController.automaticReason)
        XCTAssertTrue(fixture.assertion.isHeld)
    }

    // MARK: - Fixture

    private struct Fixture {
        let directory: URL
        let model: AppModel
        let adapter: KeepAwakeAdapterSpy
        let power: NoopSystemPowerObserver
        let assertion: IdleSleepAssertionSpy
        let clock: KeepAwakeClock

        func removeFiles() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// One Claude account, then two refreshes 5 minutes apart with the
        /// 5-hour meter moving down between them — the IN USE signal.
        @MainActor
        func signInAndBurn() async throws {
            try await model.load(startBackgroundRefresh: false)
            let sessionID = try model.beginSignIn(provider: .claude)
            try await model.completeSignIn(sessionID: sessionID, label: "Personal")
            adapter.fiveHourRemaining = 0.9
            await model.refreshAll(reason: .manual)
            clock.advance(by: 300)
            adapter.fiveHourRemaining = 0.8
            await model.refreshAll(reason: .manual)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = try makeTempDirectory()
        let clock = KeepAwakeClock(now: start)
        let accounts = AccountStore(fileURL: directory.appending(path: "accounts.json"))
        let snapshots = UsageSnapshotStore(fileURL: directory.appending(path: "snapshots.json"))
        let pendingStore = PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending-profile-deletions.json")
        )
        let historyStore = UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory),
            now: { clock.now }
        )
        let appSettings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let alertStateStore = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"))
        let adapter = KeepAwakeAdapterSpy(clock: clock)
        let power = NoopSystemPowerObserver()
        let assertion = IdleSleepAssertionSpy()
        let model = AppModel(
            accountStore: accounts,
            snapshotStore: snapshots,
            pendingProfileDeletionStore: pendingStore,
            historyStore: historyStore,
            appSettings: appSettings,
            alertStateStore: alertStateStore,
            profileManager: AlertsWebProfileManagerSpy(),
            adapterRegistry: ProviderAdapterRegistry(adapters: [adapter]),
            now: { clock.now },
            monotonicNow: { clock.monotonic },
            systemPowerObserver: power,
            idleSleepAssertion: assertion
        )
        return Fixture(
            directory: directory, model: model, adapter: adapter,
            power: power, assertion: assertion, clock: clock
        )
    }
}

/// A clock every party shares — the model, the history store and the
/// adapter's snapshots — so a burn's timestamps and "now" agree.
private final class KeepAwakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    /// The monotonic reading (seconds since boot); advances with `now`
    /// except when the wall clock alone is set (`setWall(by:)`).
    private var uptime: TimeInterval = 10_000

    init(now: Date) { current = now }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var monotonic: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return uptime
    }

    /// Time passes: both clocks move.
    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
        uptime += seconds
    }

    /// The wall clock is set (NTP, a time zone, the user): the monotonic
    /// clock does not move.
    func setWall(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Returns a 5-hour window at `fiveHourRemaining`, stamped with the shared
/// clock, so two refreshes apart in time produce the detector's sample pair.
@MainActor
private final class KeepAwakeAdapterSpy: ProviderAdapter {
    let provider = Provider.claude
    let signInURL = URL(string: "https://claude.ai/")!
    var fiveHourRemaining: Double? = 1.0
    private let clock: KeepAwakeClock

    init(clock: KeepAwakeClock) { self.clock = clock }

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(accountID: UUID, in webView: WKWebView) async throws -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: clock.now,
            fiveHour: fiveHourRemaining.map { UsageWindow(kind: .fiveHour, remainingFraction: $0, resetsAt: nil) },
            weekly: nil
        )
    }
}
