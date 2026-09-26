import XCTest
@testable import Ration

final class AlertPolicyTests: XCTestCase {
    private let accountID = UUID()

    private func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    private func window(_ used: Double, resetsAt: Date?, kind: UsageWindowKind = .fiveHour) -> UsageWindow {
        UsageWindow(kind: kind, remainingFraction: 1 - used, resetsAt: resetsAt)
    }

    private func snapshot(
        five: UsageWindow? = nil,
        weekly: UsageWindow? = nil,
        fetchedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> UsageSnapshot {
        UsageSnapshot(accountID: accountID, fetchedAt: fetchedAt, fiveHour: five, weekly: weekly)
    }

    private let resetA = Date(timeIntervalSince1970: 100_000)
    private let resetB = Date(timeIntervalSince1970: 200_000)

    // MARK: - Threshold crossing

    func testCrossing75ThenFires90FiresEachOnce() {
        var state = AccountAlertState()

        // 75% crossing → warning fires once.
        let snap75 = snapshot(five: window(0.80, resetsAt: resetA))
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap75, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.threshold(kind: .fiveHour, tier: .warning, percent: 75)])
        state = r1.next

        // Staying at 80% (still warning tier) does not re-fire.
        let r1b = AlertPolicy.evaluate(previous: state, snapshot: snap75, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1b.events, [])
        state = r1b.next

        // 90% crossing → critical fires once.
        let snap90 = snapshot(five: window(0.95, resetsAt: resetA))
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap90, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r2.next
    }

    // NOTE: the second snapshot originally used 99% used (remaining .01),
    // which — combined with the third snapshot reverting to 92% used
    // (remaining .08) — produced a remaining swing of +0.07, tripping the
    // new freed-capacity reset epsilon (0.05) on the revert. Adjusted to 95%
    // used (remaining .05) so every step's swing stays under the epsilon,
    // preserving the original intent: ordinary fluctuation while staying at
    // or above critical must never fire a reset or re-post.
    func testStayingAtOrAboveCriticalDoesNotRefire() {
        var state = AccountAlertState()
        let snap90 = snapshot(five: window(0.92, resetsAt: resetA)) // remaining .08
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap90, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r1.next

        let snap95 = snapshot(five: window(0.95, resetsAt: resetA)) // remaining .05, delta -.03
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap95, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])
        state = r2.next

        // Reverting to snap90 (remaining .08, delta +.03) stays under epsilon.
        let r3 = AlertPolicy.evaluate(previous: state, snapshot: snap90, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [])
    }

    // NOTE: this test originally dipped from 92% used to 50% used ("same
    // window identity ⇒ no reset") to prove a dip alone doesn't re-arm the
    // tier ladder. Under the corrected freed-capacity-based reset trigger, a
    // swing that large (remaining +0.42) legitimately IS what a reset looks
    // like, so that old scenario no longer demonstrates "no reset" — it
    // demonstrates the opposite. Rewritten with each successive dip kept
    // below `AlertPolicy.resetUpwardEpsilon` (0.05), which is what a benign
    // fluctuation actually looks like, to preserve the original intent: the
    // tier ladder must not re-arm without a genuine freed-capacity reset.
    func testSmallFluctuationsBelowEpsilonDoNotFireResetOrReArmTier() {
        var state = AccountAlertState()
        let snap90 = snapshot(five: window(0.92, resetsAt: resetA)) // remaining .08
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap90, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r1.next

        // Small dip: remaining +0.03 (below the 0.05 epsilon) — must not be
        // mistaken for freed capacity, and notifiedTier must stay .critical
        // even though the used-fraction dropped into the warning band.
        let snapDip1 = snapshot(five: window(0.89, resetsAt: resetA)) // remaining .11
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snapDip1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])
        state = r2.next

        // A further small dip, still below epsilon relative to the last
        // sample — must still not fire or re-arm.
        let snapDip2 = snapshot(five: window(0.86, resetsAt: resetA)) // remaining .14
        let r3 = AlertPolicy.evaluate(previous: state, snapshot: snapDip2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [])
        XCTAssertEqual(
            r3.next.fiveHour.notifiedTier,
            .critical,
            "small sub-epsilon fluctuations must never clear the already-notified tier"
        )
    }

    // MARK: - Reset detection

    func testFirstEverObservationDoesNotFireReset() {
        let state = AccountAlertState()
        let snap = snapshot(five: window(0.10, resetsAt: resetA))
        let r = AlertPolicy.evaluate(previous: state, snapshot: snap, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r.events, [])
        XCTAssertTrue(r.next.fiveHour.hasObserved)
        XCTAssertEqual(r.next.fiveHour.identity, resetA)
    }

    func testWindowResetFiresResetAndReArmsTier() {
        var state = AccountAlertState()
        // First observation establishes identity resetA.
        let snap1 = snapshot(five: window(0.10, resetsAt: resetA))
        state = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next

        // Cross into critical.
        let snapCritical = snapshot(five: window(0.95, resetsAt: resetA))
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snapCritical, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r2.next

        // Window resets: capacity freed (remaining jumps from .05 to .95,
        // well past the epsilon) with low usage in the new window → fires
        // .reset, no threshold. (resetsAt also changes here, but that's
        // incidental — see testDateIdentityTransitioningToDifferentDateWithFreedCapacityFiresReset
        // and testFreedCapacityFiresReset for the identity/capacity split.)
        let snapReset = snapshot(five: window(0.05, resetsAt: resetB))
        let r3 = AlertPolicy.evaluate(previous: state, snapshot: snapReset, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [.reset(kind: .fiveHour)])
        XCTAssertNil(r3.next.fiveHour.notifiedTier)
        state = r3.next

        // After reset, crossing 75% again fires warning again (re-armed).
        let snapWarningAgain = snapshot(five: window(0.80, resetsAt: resetB))
        let r4 = AlertPolicy.evaluate(previous: state, snapshot: snapWarningAgain, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r4.events, [.threshold(kind: .fiveHour, tier: .warning, percent: 75)])
    }

    // NOTE: originally a "new window (resetsAt changes) that immediately
    // starts above threshold" — but under the corrected reset trigger, a
    // window that resets shows freed capacity (remaining goes UP), so
    // "starts high [usage]" right after a reset no longer makes sense as a
    // resetsAt-only change; it must be modeled as a genuine remaining jump
    // that still lands in a notifiable tier once observed (e.g. a
    // sparsely-polled window whose fresh capacity has already been partly
    // consumed by the time this poll lands).
    func testResetAndThresholdCanFireTogetherWhenFreedCapacityStillCrossesThreshold() {
        var state = AccountAlertState()
        // First observation: already deep into critical usage.
        let snap1 = snapshot(five: window(0.98, resetsAt: resetA)) // remaining .02
        state = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next

        // Next poll: capacity was freed (remaining jumps from .02 to .20 —
        // well past the epsilon), but usage already climbed back up to 80%
        // within the fresh window by the time this poll observed it — so the
        // reset and a (re-armed) threshold crossing fire together.
        let snap2 = snapshot(five: window(0.80, resetsAt: resetB)) // remaining .20
        let r = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r.events.count, 2)
        XCTAssertTrue(r.events.contains(.reset(kind: .fiveHour)))
        XCTAssertTrue(r.events.contains(.threshold(kind: .fiveHour, tier: .warning, percent: 75)))
    }

    // MARK: - nil window

    func testNilWindowLeavesMemoryUntouched() {
        var state = AccountAlertState()
        let snap1 = snapshot(five: window(0.95, resetsAt: resetA))
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r1.next

        // Next snapshot has nil fiveHour window (e.g. provider omitted it).
        let snap2 = snapshot(five: nil)
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])
        XCTAssertEqual(r2.next.fiveHour, state.fiveHour, "memory must be untouched when window is nil")
    }

    func testNilSnapshotLeavesBothMemoriesUntouched() {
        var state = AccountAlertState()
        let snap1 = snapshot(five: window(0.95, resetsAt: resetA), weekly: window(0.80, resetsAt: resetB))
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        state = r1.next

        let r2 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])
        XCTAssertEqual(r2.next, state)
    }

    // MARK: - reauthRequired / rateLimited

    func testReauthRequiredFiresOnceOnEntryAndReArmsAfterLeaving() {
        var state = AccountAlertState()

        let r1 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .reauthenticationRequired, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.reauthRequired])
        state = r1.next

        // Still reauth-required — does not re-fire.
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .reauthenticationRequired, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])
        state = r2.next

        // Leaves the state — re-arms.
        let r3 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [])
        state = r3.next

        // Re-enters — fires again.
        let r4 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .reauthenticationRequired, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r4.events, [.reauthRequired])
    }

    func testRateLimitedFiresOnceOnEntryAndReArmsAfterLeaving() {
        var state = AccountAlertState()

        let r1 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .rateLimited(retryAt: nil), thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.rateLimited])
        state = r1.next

        let r2 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .rateLimited(retryAt: nil), thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])
        state = r2.next

        let r3 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [])
        state = r3.next

        let r4 = AlertPolicy.evaluate(previous: state, snapshot: nil, state: .rateLimited(retryAt: nil), thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r4.events, [.rateLimited])
    }

    // MARK: - Reset-metadata nil handling

    func testNilIdentityTransitioningToDateAdoptsWithoutFiringReset() {
        var state = AccountAlertState()
        // First-ever observation has NO resetsAt metadata (nil).
        let snap1 = snapshot(five: window(0.10, resetsAt: nil))
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [])
        XCTAssertTrue(r1.next.fiveHour.hasObserved)
        XCTAssertNil(r1.next.fiveHour.identity)
        state = r1.next

        // The provider starts reporting a `resetsAt`: a `nil → Date`
        // transition adopts the new identity but must NOT fire `.reset` —
        // there is no prior (non-nil) identity to have actually changed from.
        let snap2 = snapshot(five: window(0.10, resetsAt: resetA))
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [], "nil → Date must adopt the identity without firing reset")
        XCTAssertEqual(r2.next.fiveHour.identity, resetA)
    }

    func testDateIdentityTransitioningToNilUpdatesWithoutFiringReset() {
        var state = AccountAlertState()
        let snap1 = snapshot(five: window(0.10, resetsAt: resetA))
        state = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next

        // The provider stops reporting `resetsAt`: a `Date → nil` transition
        // updates the identity to nil but must NOT fire `.reset` — losing the
        // metadata is not evidence the window actually rolled over.
        let snap2 = snapshot(five: window(0.10, resetsAt: nil))
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [], "Date → nil must update the identity without firing reset")
        XCTAssertNil(r2.next.fiveHour.identity)
    }

    // NOTE: originally fired `.reset` purely because `resetsAt` changed
    // (identity resetA → resetB) with `remaining` held flat — that IS the
    // false-positive bug this fix removes (Claude's rolling windows change
    // `resetsAt` on every poll). Rewritten so the genuine-rollover case is
    // now grounded in the corrected trigger: capacity freed (`remaining`
    // jumping up ≥ epsilon), which a real rollover happens to also come with
    // an identity change here — but it's the freed capacity, not the
    // identity change, that fires `.reset` (see `testFreedCapacityFiresReset`
    // for a case where identity doesn't change at all and it still fires).
    func testDateIdentityTransitioningToDifferentDateWithFreedCapacityFiresReset() {
        var state = AccountAlertState()
        let snap1 = snapshot(five: window(0.95, resetsAt: resetA)) // remaining .05
        state = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next

        // A genuine rollover: the identity changes AND capacity was freed
        // (remaining jumps from .05 to .90 — well past the epsilon).
        let snap2 = snapshot(five: window(0.10, resetsAt: resetB)) // remaining .90
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [.reset(kind: .fiveHour)])
        XCTAssertEqual(r2.next.fiveHour.identity, resetB)
    }

    func testIdentityLosingThenRegainingSameDateDoesNotClearOrRefireTier() {
        var state = AccountAlertState()
        // Establish identity resetA and cross into critical.
        let snap1 = snapshot(five: window(0.10, resetsAt: resetA))
        state = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next
        let snapCritical = snapshot(five: window(0.95, resetsAt: resetA))
        let rCritical = AlertPolicy.evaluate(previous: state, snapshot: snapCritical, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(rCritical.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = rCritical.next

        // The provider drops the metadata (Date → nil): no reset, tier
        // untouched.
        let snapNil = snapshot(five: window(0.95, resetsAt: nil))
        let rNil = AlertPolicy.evaluate(previous: state, snapshot: snapNil, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(rNil.events, [])
        XCTAssertEqual(rNil.next.fiveHour.notifiedTier, .critical)
        state = rNil.next

        // The provider regains the SAME `resetsAt` it had before dropping it
        // (nil → Date, same value as the pre-drop identity): still just a
        // nil-involving transition, so it must NOT clear-and-refire the tier
        // ladder — the still-critical usage must not re-post.
        let snapRegained = snapshot(five: window(0.95, resetsAt: resetA))
        let rRegained = AlertPolicy.evaluate(previous: state, snapshot: snapRegained, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(
            rRegained.events,
            [],
            "regaining resetsAt after losing it must not clear+refire the already-notified tier"
        )
        XCTAssertEqual(rRegained.next.fiveHour.notifiedTier, .critical)
    }

    // MARK: - independence of 5h and weekly

    func testFiveHourAndWeeklyTrackedIndependently() {
        var state = AccountAlertState()
        let snap1 = snapshot(five: window(0.95, resetsAt: resetA), weekly: window(0.10, resetsAt: resetB))
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r1.next

        // Weekly crosses warning independently; fiveHour stays at critical (no re-fire).
        let snap2 = snapshot(five: window(0.96, resetsAt: resetA), weekly: window(0.80, resetsAt: resetB))
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [.threshold(kind: .weekly, tier: .warning, percent: 75)])

        // fiveHour resets independently of weekly.
        let snap3 = snapshot(five: window(0.05, resetsAt: Date(timeIntervalSince1970: 300_000)), weekly: window(0.80, resetsAt: resetB))
        let r3 = AlertPolicy.evaluate(previous: r2.next, snapshot: snap3, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [.reset(kind: .fiveHour)])
    }

    // MARK: - Regressions: false rolling-window reset alerts (the bug this
    // fix addresses). Claude's 5h/weekly windows are ROLLING — `resetsAt`
    // advances on essentially every poll — so it must never be the reset
    // trigger; only an upward jump in `remainingFraction` (freed capacity)
    // may fire `.reset`.

    func testRollingResetsAtDriftDoesNotFireReset() {
        var state = AccountAlertState()
        let baseDate = Date(timeIntervalSince1970: 500_000)

        // First poll: already at critical usage.
        let snap0 = snapshot(weekly: window(0.92, resetsAt: baseDate, kind: .weekly))
        let r0 = AlertPolicy.evaluate(previous: state, snapshot: snap0, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r0.events, [.threshold(kind: .weekly, tier: .critical, percent: 90)])
        state = r0.next

        // Ten subsequent polls: `resetsAt` drifts forward by 1s every poll —
        // exactly how Claude's rolling 5h/7-day windows behave in practice —
        // while `remaining` stays flat-to-slightly-decreasing (ordinary
        // continued usage), never jumping up by the reset epsilon. None of
        // these may fire `.reset` — nor any threshold, since usage only ever
        // increases and the tier is already critical.
        for i in 1...10 {
            let drift = baseDate.addingTimeInterval(TimeInterval(i))
            let usedThisPoll = min(0.92 + Double(i) * 0.001, 0.99)
            let snap = snapshot(weekly: window(usedThisPoll, resetsAt: drift, kind: .weekly))
            let r = AlertPolicy.evaluate(previous: state, snapshot: snap, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
            XCTAssertEqual(r.events, [], "poll \(i): resetsAt drift alone must never fire .reset")
            state = r.next
        }

        // The tier ladder must never have been cleared by the drift — proof
        // there was no spurious reset-triggered re-arm hiding behind the
        // empty event lists above (which would silently re-fire the next
        // time usage merely stayed at/above critical).
        XCTAssertEqual(
            state.weekly.notifiedTier,
            .critical,
            "resetsAt drift must never clear notifiedTier (which would re-arm the threshold ladder)"
        )
    }

    func testFreedCapacityFiresReset() {
        var state = AccountAlertState()
        // First observation: nearly exhausted, critical tier notified.
        let snap1 = snapshot(weekly: window(0.90, resetsAt: resetA, kind: .weekly)) // remaining .10
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events, [.threshold(kind: .weekly, tier: .critical, percent: 90)])
        state = r1.next

        // Capacity is freed: remaining jumps from .10 to 1.0 — a genuine
        // reset. Note `resetsAt` doesn't even need to change for this to be
        // detected; freed capacity alone is the trigger.
        let snap2 = snapshot(weekly: window(0.0, resetsAt: resetA, kind: .weekly))
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [.reset(kind: .weekly)])
        XCTAssertNil(r2.next.weekly.notifiedTier, "a freed-capacity reset must re-arm the tier ladder")
    }

    // Boundary: a jump of EXACTLY `resetUpwardEpsilon` must fire (the policy
    // documents "at least" the epsilon). Because binary floating point makes
    // `0.15 - 0.10` evaluate just under 0.05, this is precisely the case the
    // implementation's `- 1e-10` slack exists to protect; without it this
    // would silently NOT fire. Paired with the just-below case to pin both
    // sides of the boundary.
    func testExactEpsilonJumpFiresResetAndJustBelowDoesNot() {
        // remaining .10 → .15 is an exact-0.05 jump (subject to FP error).
        var stateAtBoundary = AccountAlertState()
        let atBoundary1 = snapshot(weekly: window(0.90, resetsAt: resetA, kind: .weekly)) // remaining .10
        stateAtBoundary = AlertPolicy.evaluate(previous: stateAtBoundary, snapshot: atBoundary1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next
        let atBoundary2 = snapshot(weekly: window(0.85, resetsAt: resetA, kind: .weekly)) // remaining .15
        let rBoundary = AlertPolicy.evaluate(previous: stateAtBoundary, snapshot: atBoundary2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertTrue(
            rBoundary.events.contains(.reset(kind: .weekly)),
            "a jump of exactly resetUpwardEpsilon must fire .reset (\"at least\" the epsilon)"
        )

        // remaining .10 → .14 is a 0.04 jump — just under the epsilon — and
        // must NOT fire.
        var stateJustBelow = AccountAlertState()
        let justBelow1 = snapshot(weekly: window(0.90, resetsAt: resetA, kind: .weekly)) // remaining .10
        stateJustBelow = AlertPolicy.evaluate(previous: stateJustBelow, snapshot: justBelow1, state: .current, thresholds: { _ in .default }, spendThresholds: .off).next
        let justBelow2 = snapshot(weekly: window(0.86, resetsAt: resetA, kind: .weekly)) // remaining .14
        let rJustBelow = AlertPolicy.evaluate(previous: stateJustBelow, snapshot: justBelow2, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertFalse(
            rJustBelow.events.contains(.reset(kind: .weekly)),
            "a jump just under resetUpwardEpsilon must NOT fire .reset"
        )
    }

    func testFirstObservationDoesNotFireReset() {
        let state = AccountAlertState()
        // A first-ever sample, even at high usage with resetsAt set, must
        // never fire `.reset` — there is no prior `lastRemaining` to compare
        // against yet.
        let snap = snapshot(weekly: window(0.95, resetsAt: resetA, kind: .weekly))
        let r = AlertPolicy.evaluate(previous: state, snapshot: snap, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertFalse(r.events.contains(.reset(kind: .weekly)), "first observation must never fire reset")
        XCTAssertEqual(r.next.weekly.lastRemaining ?? -1, 0.05, accuracy: 1e-9)
        XCTAssertTrue(r.next.weekly.hasObserved)
    }

    // MARK: - modelWeekly (Fable)

    /// `.modelWeekly` is evaluated exactly like `.fiveHour`/`.weekly`
    /// — a snapshot at 95% used (remaining .05) must fire a critical
    /// threshold, and the fired event carries the window's API `label`
    /// ("Fable") so `AlertMessage` can use it in the notification text.
    func testModelWeeklyThresholdFires() {
        let state = AccountAlertState()
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: nil,
            weekly: nil,
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.05, resetsAt: nil, label: "Fable")
        )
        let r = AlertPolicy.evaluate(previous: state, snapshot: snap, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertTrue(r.events.contains(.threshold(kind: .modelWeekly, tier: .critical, percent: 90, label: "Fable")))
    }

    /// `modelWeekly` memory must be tracked independently of `fiveHour`/`weekly`
    /// — same edge-trigger behavior (no re-fire while steady, reset re-arms).
    func testModelWeeklyTrackedIndependentlyOfFiveHourAndWeekly() {
        var state = AccountAlertState()
        let snap1 = UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: window(0.95, resetsAt: resetA),
            weekly: window(0.10, resetsAt: resetB),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.05, resetsAt: nil, label: "Fable")
        )
        let r1 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r1.events.count, 2)
        XCTAssertTrue(r1.events.contains(.threshold(kind: .fiveHour, tier: .critical, percent: 90)))
        XCTAssertTrue(r1.events.contains(.threshold(kind: .modelWeekly, tier: .critical, percent: 90, label: "Fable")))
        state = r1.next

        // Staying at the same remaining fraction must not re-fire modelWeekly.
        let r2 = AlertPolicy.evaluate(previous: state, snapshot: snap1, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r2.events, [])

        // modelWeekly resets independently (freed capacity) while fiveHour/weekly are untouched.
        let snapReset = UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1),
            fiveHour: window(0.95, resetsAt: resetA),
            weekly: window(0.10, resetsAt: resetB),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 1.0, resetsAt: nil, label: "Fable")
        )
        let r3 = AlertPolicy.evaluate(previous: r2.next, snapshot: snapReset, state: .current, thresholds: { _ in .default }, spendThresholds: .off)
        XCTAssertEqual(r3.events, [.reset(kind: .modelWeekly, label: "Fable")])
    }

    // MARK: - Configured tier resolution

    func testForUsedResolvesAgainstConfiguredThresholds() {
        let pair = ThresholdPair(warningPercent: 60, criticalPercent: 85)
        XCTAssertNil(AlertTier.forUsed(0.59, thresholds: pair))
        XCTAssertEqual(AlertTier.forUsed(0.60, thresholds: pair), .warning)
        XCTAssertEqual(AlertTier.forUsed(0.84, thresholds: pair), .warning)
        XCTAssertEqual(AlertTier.forUsed(0.85, thresholds: pair), .critical)
        XCTAssertEqual(AlertTier.forUsed(1.0, thresholds: pair), .critical)
    }

    func testForUsedWithDefaultPairMatchesLegacy75And90() {
        XCTAssertNil(AlertTier.forUsed(0.74, thresholds: .default))
        XCTAssertEqual(AlertTier.forUsed(0.75, thresholds: .default), .warning)
        XCTAssertEqual(AlertTier.forUsed(0.90, thresholds: .default), .critical)
    }

    // The raw values are persistence tokens now, not percentages — but they
    // must keep their ORDER, because the fire-once rule compares tiers.
    func testTierRawValuesStillOrderWarningBelowCritical() {
        XCTAssertLessThan(AlertTier.warning, AlertTier.critical)
        XCTAssertEqual(AlertTier.warning.rawValue, 75)
        XCTAssertEqual(AlertTier.critical.rawValue, 90)
    }

    // MARK: - Threshold changes (spec §3): no re-arm mechanism required

    private func evaluate(
        _ state: AccountAlertState,
        used: Double,
        pair: ThresholdPair
    ) -> (events: [AlertEvent], next: AccountAlertState) {
        AlertPolicy.evaluate(
            previous: state,
            snapshot: snapshot(five: window(used, resetsAt: resetA)),
            state: .current,
            thresholds: { _ in pair },
            spendThresholds: .off
        )
    }

    func testLoweringWarningBelowCurrentUsageFiresOnceThenIsSilent() {
        var state = AccountAlertState()
        // 68% with default 75/90: nothing fires, but the window is observed.
        let r0 = evaluate(state, used: 0.68, pair: .default)
        XCTAssertEqual(r0.events, [])
        state = r0.next

        // User lowers warning to 60. Next poll fires exactly once.
        let r1 = evaluate(state, used: 0.68, pair: ThresholdPair(warningPercent: 60, criticalPercent: 90))
        XCTAssertEqual(
            r1.events,
            [.threshold(kind: .fiveHour, tier: .warning, percent: 60)]
        )
        state = r1.next

        // And is silent on every subsequent poll.
        let r2 = evaluate(state, used: 0.68, pair: ThresholdPair(warningPercent: 60, criticalPercent: 90))
        XCTAssertEqual(r2.events, [])
    }

    func testRaisingCriticalAboveCurrentUsageDoesNotRefireWarning() {
        var state = AccountAlertState()
        // 92% with 75/90 → critical fires.
        let r0 = evaluate(state, used: 0.92, pair: .default)
        XCTAssertEqual(r0.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 90)])
        state = r0.next

        // Raise critical to 95: effective tier drops to warning, which is NOT
        // greater than the notified critical, so nothing fires.
        let r1 = evaluate(state, used: 0.92, pair: ThresholdPair(warningPercent: 75, criticalPercent: 95))
        XCTAssertEqual(r1.events, [])
    }

    func testLoweringCriticalBelowCurrentUsageEscalatesOnce() {
        var state = AccountAlertState()
        let r0 = evaluate(state, used: 0.80, pair: .default)
        XCTAssertEqual(r0.events, [.threshold(kind: .fiveHour, tier: .warning, percent: 75)])
        state = r0.next

        let r1 = evaluate(state, used: 0.80, pair: ThresholdPair(warningPercent: 60, criticalPercent: 75))
        XCTAssertEqual(r1.events, [.threshold(kind: .fiveHour, tier: .critical, percent: 75)])
        state = r1.next
        XCTAssertEqual(evaluate(state, used: 0.80, pair: ThresholdPair(warningPercent: 60, criticalPercent: 75)).events, [])
    }

    func testRaisingWarningAboveCurrentUsageIsSilent() {
        var state = AccountAlertState()
        let r0 = evaluate(state, used: 0.80, pair: .default)
        XCTAssertEqual(r0.events.count, 1)
        state = r0.next

        let r1 = evaluate(state, used: 0.80, pair: ThresholdPair(warningPercent: 85, criticalPercent: 90))
        XCTAssertEqual(r1.events, [])
    }

    func testLoweringWarningWhileAlreadyWarnedSaysNothingNew() {
        var state = AccountAlertState()
        let r0 = evaluate(state, used: 0.80, pair: .default)
        XCTAssertEqual(r0.events.count, 1)
        state = r0.next

        let r1 = evaluate(state, used: 0.80, pair: ThresholdPair(warningPercent: 60, criticalPercent: 90))
        XCTAssertEqual(r1.events, [])
    }

    func testPerWindowThresholdsAreIndependent() {
        let state = AccountAlertState()
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: d(0),
            fiveHour: window(0.65, resetsAt: resetA, kind: .fiveHour),
            weekly: window(0.65, resetsAt: resetA, kind: .weekly)
        )
        let result = AlertPolicy.evaluate(
            previous: state,
            snapshot: snap,
            state: .current,
            thresholds: { kind in
                kind == .fiveHour
                    ? ThresholdPair(warningPercent: 60, criticalPercent: 90)
                    : .default
            },
            spendThresholds: .off
        )
        XCTAssertEqual(
            result.events,
            [.threshold(kind: .fiveHour, tier: .warning, percent: 60)]
        )
    }

    // MARK: - Cursor spend

    /// Cursor's invoice is identified by its START. Live-observed 2026-08-27:
    /// `get-monthly-invoice.periodEndMs` is the fetch time for the open
    /// invoice, so `periodEnd` advances on every poll and says nothing about
    /// rollover.
    private let startA = Date(timeIntervalSince1970: 50_000)
    private let startB = Date(timeIntervalSince1970: 150_000)

    private func spendSnapshot(cents: Int, periodStart: Date, periodEnd: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: d(0),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: cents,
                periodStart: periodStart,
                resetsAt: periodEnd,
                planLabel: "Pro"
            )
        )
    }

    func testSpendFiresAtConfiguredCentsOnce() {
        var state = AccountAlertState()
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)

        let r0 = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_200, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(
            r0.events,
            [.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_200)]
        )
        state = r0.next

        let r1 = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_900, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(r1.events, [])
    }

    func testSpendRearmsWhenInvoicePeriodAdvances() {
        var state = AccountAlertState()
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        state = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_200, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        ).next

        // Spend RISES across the boundary (5_200 → 5_600). That is deliberate:
        // if the fixture let spend fall, a buggy implementation that re-armed on
        // a spend DECREASE would produce the same event and this test would pass
        // against it — it could not tell the two rules apart, which is the whole
        // distinction being pinned here.
        let r = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_600, periodStart: startB, periodEnd: resetB),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(
            r.events,
            [.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_600)]
        )
    }

    /// The 2026-08-27 bug: Cursor's `periodEndMs` advanced on every poll, and
    /// the re-arm keyed on it — so a spend over its threshold would have
    /// notified every five minutes. Only the period START moving is a
    /// rollover; the end drifting inside the same cycle changes nothing.
    func testSpendPeriodEndDriftWithinTheSamePeriodDoesNotRearm() {
        var state = AccountAlertState()
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        state = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_200, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        ).next
        state.spend.dismissedTier = .warning

        let r = AlertPolicy.evaluate(
            previous: state,
            snapshot: spendSnapshot(
                cents: 5_600,
                periodStart: startA,
                periodEnd: resetA.addingTimeInterval(360)
            ),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(r.events, [], "the end drifting is not a new invoice")
        XCTAssertEqual(r.next.spend.notifiedTier, .warning, "the watermark must survive")
        XCTAssertEqual(r.next.spend.dismissedTier, .warning, "and so must the drop dismissal")
    }

    /// A boundary that transiently moves BACKWARDS (B → A → B) must not
    /// duplicate the alert. The regressed observation is ignored whole, so the
    /// return to B is not mistaken for a rollover — and neither is it for the
    /// attention drop's snooze, which asks `spendPeriodAdvanced` of the same
    /// memory.
    func testSpendBoundaryRegressionDoesNotDuplicateTheAlert() {
        var state = AccountAlertState()
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        let atB = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_200, periodStart: startB, periodEnd: resetB),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(atB.events, [.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_200)])
        state = atB.next
        state.spend.dismissedTier = .warning

        let backToA = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_300, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(backToA.events, [])
        XCTAssertEqual(backToA.next.spend, state.spend, "a regressed boundary leaves spend memory untouched")
        state = backToA.next

        let againB = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_400, periodStart: startB, periodEnd: resetB),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(againB.events, [], "no rollover happened, so no second alert")
        XCTAssertEqual(againB.next.spend.notifiedTier, .warning)
        XCTAssertEqual(againB.next.spend.dismissedTier, .warning, "the drop dismissal survives too")
        XCTAssertFalse(
            AlertPolicy.spendPeriodAdvanced(from: backToA.next.spend, toStart: startB),
            "the drop's snooze sees no rollover either"
        )
    }

    /// The regression guard must not swallow a GENUINE rollover after a
    /// regressed poll: A → (earlier) → B still re-arms.
    func testGenuineRolloverStillRearmsAfterARegressedPoll() {
        var state = AccountAlertState()
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        let earlier = Date(timeIntervalSince1970: 10_000)
        state = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_200, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        ).next
        state = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_200, periodStart: earlier, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        ).next
        XCTAssertEqual(state.spend.periodStart, startA)

        let r = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_600, periodStart: startB, periodEnd: resetB),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(r.events, [.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_600)])
        XCTAssertEqual(r.next.spend.periodStart, startB)
    }

    /// A snapshot without a start (pre-0.28.2 on disk) must not erase the
    /// invoice identity already held.
    func testSpendWithoutAStartKeepsTheStoredStart() {
        var state = AccountAlertState()
        state.spend.hasObserved = true
        state.spend.periodStart = startA
        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: d(0),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(spentCents: 100, periodStart: nil, resetsAt: resetA, planLabel: "Pro")
        )
        let r = AlertPolicy.evaluate(
            previous: state, snapshot: snap,
            state: .current, thresholds: { _ in .default }, spendThresholds: .off
        )
        XCTAssertEqual(r.next.spend.periodStart, startA)
    }

    /// Memory written by 0.28.1 has no `periodStart`. If
    /// the month rolled while the app was closed, the first upgraded poll
    /// must still see the rollover — otherwise the old watermark and drop
    /// dismissal survive the entire new invoice. The only evidence the legacy
    /// memory has is its `periodEnd`; a new start AT or PAST it is a crossed
    /// boundary (equality is the real-boundary case: end Sep 1 == start Sep 1).
    func testLegacyMemoryWithoutPeriodStartRearmsWhenTheNewStartIsPastTheOldEnd() {
        var state = AccountAlertState()
        state.spend.hasObserved = true
        state.spend.periodStart = nil
        state.spend.periodEnd = resetA
        state.spend.notifiedTier = .warning
        state.spend.dismissedTier = .warning
        state.spend.lastSpentCents = 5_200
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)

        let r = AlertPolicy.evaluate(
            previous: state,
            snapshot: spendSnapshot(cents: 5_600, periodStart: resetA, periodEnd: resetB),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(
            r.events,
            [.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_600)],
            "a boundary crossed while the app was closed must re-arm on the first upgraded poll"
        )
        XCTAssertNil(r.next.spend.dismissedTier)
        XCTAssertEqual(r.next.spend.periodStart, resetA)
    }

    /// The other half of the upgrade poll: same invoice, legacy `periodEnd`
    /// was the drifting "now" of the last 0.28.1 poll — the new start lies
    /// BEFORE it, so nothing rolled and nothing may re-arm.
    func testLegacyMemoryWithoutPeriodStartDoesNotRearmWithinTheSamePeriod() {
        var state = AccountAlertState()
        state.spend.hasObserved = true
        state.spend.periodStart = nil
        state.spend.periodEnd = resetA
        state.spend.notifiedTier = .warning
        state.spend.dismissedTier = .warning
        state.spend.lastSpentCents = 5_200
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)

        let r = AlertPolicy.evaluate(
            previous: state,
            snapshot: spendSnapshot(cents: 5_600, periodStart: startA, periodEnd: resetA.addingTimeInterval(360)),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(r.events, [])
        XCTAssertEqual(r.next.spend.notifiedTier, .warning)
        XCTAssertEqual(r.next.spend.dismissedTier, .warning)
    }

    func testSpendMemoryRecordsThePeriodStart() {
        let r = AlertPolicy.evaluate(
            previous: AccountAlertState(),
            snapshot: spendSnapshot(cents: 0, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: .off
        )
        XCTAssertEqual(r.next.spend.periodStart, startA)
        XCTAssertEqual(r.next.spend.periodEnd, resetA)
    }

    // A refund or corrected event can lower spend mid-cycle; that must NOT
    // re-alert while the invoice boundary is unchanged.
    func testSpendDropWithinSamePeriodDoesNotRearm() {
        var state = AccountAlertState()
        let thresholds = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        state = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 6_000, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        ).next

        let r = AlertPolicy.evaluate(
            previous: state, snapshot: spendSnapshot(cents: 5_100, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: thresholds
        )
        XCTAssertEqual(r.events, [])
    }

    func testSpendNeverFiresWhenThresholdsAreOff() {
        let r = AlertPolicy.evaluate(
            previous: AccountAlertState(),
            snapshot: spendSnapshot(cents: 99_999, periodStart: startA, periodEnd: resetA),
            state: .current, thresholds: { _ in .default }, spendThresholds: .off
        )
        XCTAssertEqual(r.events, [])
    }

    // MARK: - Attention-drop dismissal clears with the window

    /// A dismissed drop row is dismissed for THIS window only. When the window
    /// resets, the row must be able to come back — otherwise one ✕ silences
    /// that subject permanently.
    func testWindowResetClearsTheDismissedTier() {
        var state = AccountAlertState()
        state.fiveHour.hasObserved = true
        state.fiveHour.lastRemaining = 0.05
        state.fiveHour.notifiedTier = .critical
        state.fiveHour.dismissedTier = .critical

        let snapReset = snapshot(five: window(0.05, resetsAt: resetB))
        let r = AlertPolicy.evaluate(
            previous: state,
            snapshot: snapReset,
            state: .current,
            thresholds: { _ in .default },
            spendThresholds: .off
        )

        XCTAssertEqual(r.events, [.reset(kind: .fiveHour)])
        XCTAssertNil(r.next.fiveHour.dismissedTier, "a new window must show its row again")
        XCTAssertNil(r.next.fiveHour.notifiedTier)
    }

    /// Same rule for Cursor, keyed on the invoice boundary advancing rather
    /// than on freed capacity.
    func testSpendPeriodAdvanceClearsTheDismissedTier() {
        var state = AccountAlertState()
        state.spend.hasObserved = true
        state.spend.periodStart = startA
        state.spend.periodEnd = resetA
        state.spend.notifiedTier = .warning
        state.spend.dismissedTier = .warning
        state.spend.lastSpentCents = 5_000

        let snap = UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 100,
                periodStart: startB,
                resetsAt: resetB,
                planLabel: "Pro"
            )
        )
        let r = AlertPolicy.evaluate(
            previous: state,
            snapshot: snap,
            state: .current,
            thresholds: { _ in .default },
            spendThresholds: SpendThresholds(warningCents: 4_000, criticalCents: 9_000)
        )

        XCTAssertNil(r.next.spend.dismissedTier, "a new billing period must show its row again")
        XCTAssertNil(r.next.spend.notifiedTier)
    }

    /// A dismissal must NOT be cleared by an ordinary poll inside the same
    /// window — that is the whole point of persisting it.
    func testDismissedTierSurvivesAnOrdinaryPollInTheSameWindow() {
        var state = AccountAlertState()
        state.fiveHour.hasObserved = true
        state.fiveHour.lastRemaining = 0.10
        state.fiveHour.notifiedTier = .critical
        state.fiveHour.dismissedTier = .critical

        let snap = snapshot(five: window(0.92, resetsAt: resetA))
        let r = AlertPolicy.evaluate(
            previous: state,
            snapshot: snap,
            state: .current,
            thresholds: { _ in .default },
            spendThresholds: .off
        )

        XCTAssertEqual(r.next.fiveHour.dismissedTier, .critical)
    }
}
