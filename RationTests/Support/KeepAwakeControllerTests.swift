import XCTest
@testable import Ration

/// `KeepAwakeController`: one idle-sleep assertion, held while either source
/// (the automatic in-use hold or the user's override) is live, released the
/// moment neither is — and re-taken when the reason changes, so what
/// `pmset -g assertions` shows stays true.
@MainActor
final class KeepAwakeControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    /// A monotonic clock reading (seconds since boot); unrelated to `now`.
    private let tick: TimeInterval = 10_000
    private var assertion = IdleSleepAssertionSpy()
    private lazy var controller = KeepAwakeController(assertion: assertion)

    func testNothingToHoldTakesNoAssertion() {
        controller.update(automaticUntil: nil, manual: nil, now: now, monotonicNow: tick)

        XCTAssertEqual(assertion.holds, [])
        XCTAssertNil(controller.source)
    }

    func testAutomaticHoldTakesTheAssertionOnceAndKeepsIt() {
        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now.addingTimeInterval(60), monotonicNow: tick)

        XCTAssertEqual(assertion.holds, [KeepAwakeController.automaticReason])
        XCTAssertEqual(assertion.releases, 0)
        XCTAssertEqual(controller.source, .automatic)
    }

    /// The IN USE phase is inclusive at its end (`InUsePhase.classify`), so
    /// the hold lasts through the end instant and goes one second later.
    func testAutomaticHoldLastsThroughItsEndInstantThenReleases() {
        let until = now.addingTimeInterval(600)
        controller.update(automaticUntil: until, manual: nil, now: now, monotonicNow: tick)
        controller.update(automaticUntil: until, manual: nil, now: until, monotonicNow: tick)
        XCTAssertTrue(assertion.isHeld, "still in use at the boundary")

        controller.update(automaticUntil: until, manual: nil, now: until.addingTimeInterval(1), monotonicNow: tick)
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertNil(controller.source)
    }

    /// Policy and controller agree at the boundary: activity exactly at the
    /// threshold still classifies as in use, yields an end of `now`, and the
    /// controller holds for it.
    func testPolicyBoundaryIsHeldByTheController() {
        let usage = ActiveUsage(lastUsedAt: now.addingTimeInterval(-InUsePhase.inUseThreshold), source: .fiveHour)
        XCTAssertEqual(InUsePhase.classify(usage, now: now), .inUse(age: InUsePhase.inUseThreshold))
        let until = KeepAwakePolicy.holdUntil(activity: [UUID(): usage], now: now)
        XCTAssertEqual(until, now)

        controller.update(automaticUntil: until, manual: nil, now: now, monotonicNow: tick)
        XCTAssertTrue(assertion.isHeld)
    }

    /// The override's end stays exclusive: a timed override is over at its
    /// end — measured on the monotonic clock, never the wall clock.
    func testTimedOverrideEndIsExclusive() {
        let manual = ManualKeepAwake(startedAt: tick, duration: 600)
        controller.update(automaticUntil: nil, manual: manual, now: now.addingTimeInterval(600), monotonicNow: tick + 600)
        XCTAssertFalse(assertion.isHeld)
    }

    func testTimedOverrideHoldsUntilItsEnd() {
        let manual = ManualKeepAwake(startedAt: tick, duration: 1_800)
        controller.update(automaticUntil: nil, manual: manual, now: now, monotonicNow: tick)
        XCTAssertEqual(assertion.holds, [KeepAwakeController.manualReason])
        XCTAssertEqual(controller.source, .manual)

        controller.update(automaticUntil: nil, manual: manual, now: now.addingTimeInterval(1_800), monotonicNow: tick + 1_800)
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertNil(controller.source)
    }

    /// A wall clock set back an hour changes nothing: the monotonic clock
    /// decides, so the override still ends after its 30 minutes.
    func testAWallClockSetBackDoesNotStretchATimedOverride() {
        let manual = ManualKeepAwake(startedAt: tick, duration: 1_800)
        controller.update(automaticUntil: nil, manual: manual, now: now, monotonicNow: tick)
        controller.update(automaticUntil: nil, manual: manual, now: now.addingTimeInterval(-3_000), monotonicNow: tick + 600)
        XCTAssertTrue(assertion.isHeld)
        controller.update(automaticUntil: nil, manual: manual, now: now.addingTimeInterval(-1_800), monotonicNow: tick + 1_800)
        XCTAssertFalse(assertion.isHeld, "30 minutes elapsed, whatever the wall clock says")
    }

    /// The override is "keep the Mac awake": the display stays on too (the
    /// user asked, and is looking). The automatic hold is for an agent run,
    /// which needs no screen: idle sleep only, the display still sleeps.
    func testTheOverrideKeepsTheDisplayAwakeAndTheAutomaticHoldDoesNot() {
        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertFalse(assertion.isDisplayHeld)
        XCTAssertEqual(assertion.displayHolds, [])

        controller.update(
            automaticUntil: now.addingTimeInterval(600),
            manual: ManualKeepAwake(startedAt: tick, duration: nil),
            now: now,
            monotonicNow: tick
        )
        XCTAssertTrue(assertion.isDisplayHeld)
        XCTAssertEqual(assertion.displayHolds, [KeepAwakeController.manualReason])

        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertFalse(assertion.isDisplayHeld, "back to the automatic hold: the display may sleep again")
    }

    /// A timed override that ends while an account is still in use hands
    /// back to the automatic hold — re-taken without the display option, so
    /// the screen may sleep again once the user's half hour is over.
    func testAnExpiredOverrideHandsBackToTheAutomaticHoldWithoutTheDisplay() {
        let manual = ManualKeepAwake(startedAt: tick, duration: 1_800)
        let automaticUntil = now.addingTimeInterval(3 * 3_600)
        controller.update(automaticUntil: automaticUntil, manual: manual, now: now, monotonicNow: tick)
        XCTAssertEqual(controller.source, .manual)
        XCTAssertTrue(assertion.isDisplayHeld)

        controller.update(automaticUntil: automaticUntil, manual: manual, now: now.addingTimeInterval(1_800), monotonicNow: tick + 1_800)

        XCTAssertEqual(controller.source, .automatic)
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertEqual(assertion.holds, [KeepAwakeController.manualReason, KeepAwakeController.automaticReason])
        XCTAssertTrue(assertion.isHeld)
        XCTAssertFalse(assertion.isDisplayHeld)
    }

    /// The live assertion's options: what `caffeinate -i` takes, plus what
    /// `caffeinate -d` takes for the override.
    func testTheLiveAssertionOptions() {
        XCTAssertEqual(ProcessInfoIdleSleepAssertion.options(display: false), [.idleSystemSleepDisabled])
        XCTAssertEqual(ProcessInfoIdleSleepAssertion.options(display: true), [.idleSystemSleepDisabled, .idleDisplaySleepDisabled])
    }

    func testOpenEndedOverrideHoldsUntilStopped() {
        let manual = ManualKeepAwake(startedAt: tick, duration: nil)
        controller.update(automaticUntil: nil, manual: manual, now: now, monotonicNow: tick)
        controller.update(automaticUntil: nil, manual: manual, now: now.addingTimeInterval(10 * 86_400), monotonicNow: tick + 10 * 86_400)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertEqual(assertion.holds.count, 1)

        controller.update(automaticUntil: nil, manual: nil, now: now.addingTimeInterval(10 * 86_400), monotonicNow: tick + 10 * 86_400)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertNil(controller.source)
    }

    func testOverrideNamesTheReasonWhenBothSourcesAreLive() {
        controller.update(
            automaticUntil: now.addingTimeInterval(600),
            manual: ManualKeepAwake(startedAt: tick, duration: 3_600),
            now: now,
            monotonicNow: tick
        )

        XCTAssertEqual(assertion.holds, [KeepAwakeController.manualReason])
        XCTAssertEqual(controller.source, .manual)
    }

    func testSourceChangeSwapsTheAssertionSoTheReasonStaysTrue() {
        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        controller.update(
            automaticUntil: now.addingTimeInterval(600),
            manual: ManualKeepAwake(startedAt: tick, duration: nil),
            now: now,
            monotonicNow: tick
        )
        XCTAssertEqual(assertion.holds, [KeepAwakeController.automaticReason, KeepAwakeController.manualReason])
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertTrue(assertion.isHeld)

        // Override stopped while the account is still in use: back to automatic.
        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        XCTAssertEqual(assertion.holds.last, KeepAwakeController.automaticReason)
        XCTAssertEqual(controller.source, .automatic)
    }

    func testStopReleasesAndALaterUpdateHoldsAgain() {
        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        controller.stop()
        XCTAssertFalse(assertion.isHeld)
        XCTAssertNil(controller.source)

        controller.update(automaticUntil: now.addingTimeInterval(600), manual: nil, now: now, monotonicNow: tick)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertEqual(assertion.holds.count, 2)
    }

    func testStopWithoutAHoldReleasesNothing() {
        controller.stop()
        XCTAssertEqual(assertion.releases, 0)
    }

    // MARK: ManualKeepAwake

    func testOverrideLivenessFollowsItsEndOnTheMonotonicClock() {
        let timed = ManualKeepAwake(startedAt: tick, duration: 60)
        XCTAssertTrue(timed.isLive(monotonic: tick))
        XCTAssertTrue(timed.isLive(monotonic: tick + 59))
        XCTAssertFalse(timed.isLive(monotonic: tick + 60))
        XCTAssertTrue(ManualKeepAwake(startedAt: tick, duration: nil).isLive(monotonic: tick + 365 * 86_400))
    }

    /// The end the banner shows is the wall clock plus what is left on the
    /// monotonic clock: it moves with a wall clock set back or forward, so
    /// it always names the real end.
    func testTheDisplayedEndFollowsWhatIsLeft() {
        let timed = ManualKeepAwake(startedAt: tick, duration: 1_800)
        XCTAssertEqual(timed.until(wall: now, monotonic: tick), now.addingTimeInterval(1_800))
        XCTAssertEqual(timed.until(wall: now.addingTimeInterval(600), monotonic: tick + 600), now.addingTimeInterval(1_800))
        // The wall clock set back an hour after ten minutes: 20 minutes remain.
        XCTAssertEqual(timed.until(wall: now.addingTimeInterval(-3_000), monotonic: tick + 600), now.addingTimeInterval(-1_800))
        XCTAssertNil(ManualKeepAwake(startedAt: tick, duration: nil).until(wall: now, monotonic: tick + 5))
    }
}
