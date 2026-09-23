import XCTest
@testable import Ration

final class ResetCreditPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func credit(_ id: String = "c1", count: Int = 1, expiresIn: TimeInterval) -> ResetCredit {
        ResetCredit(id: id, title: "Launch reset", count: count, expiresAt: t0.addingTimeInterval(expiresIn), usableNow: true)
    }

    private func input(_ items: [ResetCredit], complete: Bool = true, lead: Int = 1, now: Date? = nil) -> ResetCreditAlertInput {
        ResetCreditAlertInput(credits: ResetCredits(fetchedAt: now ?? t0, items: items, complete: complete), leadDays: lead, now: now ?? t0)
    }

    private func run(_ state: AccountAlertState, _ input: ResetCreditAlertInput?) -> (events: [AlertEvent], next: AccountAlertState) {
        AlertPolicy.evaluate(previous: state, snapshot: nil, state: .current, thresholds: { _ in .default }, spendThresholds: .off, resetCredits: input)
    }

    func testNewCreditFiresAvailableOnceAndActivatesRow() {
        let c = credit(expiresIn: 30 * day)
        let r1 = run(AccountAlertState(), input([c]))
        XCTAssertEqual(r1.events, [.resetCreditAvailable(credit: c, expiringSoon: false)])
        XCTAssertEqual(r1.next.resetCredits["c1"]?.availableRow, .active)
        XCTAssertEqual(run(r1.next, input([c])).events, [], "same id, same count: silent")
    }

    func testExpiringFiresOnceAtTheLeadBoundary() {
        let c = credit(expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([c])).next
        let justOutside = t0.addingTimeInterval(29 * day - 1)
        XCTAssertEqual(run(state, input([c], now: justOutside)).events, [])
        let atBoundary = t0.addingTimeInterval(29 * day)
        let r = run(state, input([c], now: atBoundary))
        XCTAssertEqual(r.events, [.resetCreditExpiring(credit: c)])
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .active)
        state = r.next
        XCTAssertEqual(run(state, input([c], now: atBoundary.addingTimeInterval(60))).events, [])
    }

    func testArrivalInsideLeadWindowFiresAvailableOnlyWithExpiryWording() {
        let c = credit(expiresIn: 18 * 3600)
        let r = run(AccountAlertState(), input([c]))
        XCTAssertEqual(r.events, [.resetCreditAvailable(credit: c, expiringSoon: true)])
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiryHandled, true)
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .inactive, "one alert, one row")
        XCTAssertEqual(run(r.next, input([c], now: t0.addingTimeInterval(3600))).events, [])
    }

    func testCountDropThenRiseFiresAgain() {
        let three = credit(count: 3, expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([three])).next
        state = run(state, input([credit(count: 2, expiresIn: 30 * day)])).next
        XCTAssertEqual(state.resetCredits["c1"]?.lastSeenCount, 2)
        let back = credit(count: 3, expiresIn: 30 * day)
        XCTAssertEqual(run(state, input([back])).events, [.resetCreditAvailable(credit: back, expiringSoon: false)])
    }

    func testCountRiseReactivatesDismissedAvailableRow() {
        var state = run(AccountAlertState(), input([credit(count: 1, expiresIn: 30 * day)])).next
        state.resetCredits["c1"]?.availableRow = .dismissed
        let r = run(state, input([credit(count: 2, expiresIn: 30 * day)]))
        XCTAssertEqual(r.next.resetCredits["c1"]?.availableRow, .active)
    }

    func testNilInputLeavesMemoryUntouched() {
        let state = run(AccountAlertState(), input([credit(expiresIn: 30 * day)])).next
        let r = run(state, nil)
        XCTAssertEqual(r.events, [])
        XCTAssertEqual(r.next, state)
    }

    func testCompleteReadPrunesAbsentIdsIncompleteDoesNot() {
        let state = run(AccountAlertState(), input([credit("a", expiresIn: 30 * day), credit("b", expiresIn: 30 * day)])).next
        let partial = run(state, input([credit("a", expiresIn: 30 * day)], complete: false)).next
        XCTAssertNotNil(partial.resetCredits["b"], "incomplete read proves nothing about absence")
        let full = run(partial, input([credit("a", expiresIn: 30 * day)])).next
        XCTAssertNil(full.resetCredits["b"])
    }

    func testPartialThenCompleteDoesNotReAlert() {
        let a = credit("a", expiresIn: 30 * day)
        let state = run(AccountAlertState(), input([a])).next
        let partial = run(state, input([], complete: false)).next
        XCTAssertEqual(run(partial, input([a])).events, [])
    }

    func testLocallyExpiredItemsAreSkipped() {
        let c = credit(expiresIn: -1)
        XCTAssertEqual(run(AccountAlertState(), input([c])).events, [])
    }

    func testLeadDaysIsHonoured() {
        let c = credit(expiresIn: 3 * day)
        XCTAssertEqual(run(AccountAlertState(), input([c], lead: 3)).events, [.resetCreditAvailable(credit: c, expiringSoon: true)])
        XCTAssertEqual(run(AccountAlertState(), input([c], lead: 2)).events, [.resetCreditAvailable(credit: c, expiringSoon: false)])
    }

    func testInputRequiresFreshEvidence() {
        let fresh = ResetCredits(fetchedAt: t0, items: [credit(expiresIn: day * 30)], complete: true)
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, resetCredits: fresh)
        XCTAssertNotNil(ResetCreditPolicy.input(snapshot: snap, leadDays: 1, now: t0.addingTimeInterval(60)))
        let carried = UsageSnapshot(accountID: UUID(), fetchedAt: t0.addingTimeInterval(300), fiveHour: nil, weekly: nil, resetCredits: fresh)
        XCTAssertNil(ResetCreditPolicy.input(snapshot: carried, leadDays: 1, now: t0.addingTimeInterval(360)), "carried list is not evidence")
        XCTAssertNil(ResetCreditPolicy.input(snapshot: snap, leadDays: 1, now: t0.addingTimeInterval(UsageEvidence.maxAge + 1)), "too old")
        XCTAssertNil(ResetCreditPolicy.input(snapshot: snap, leadDays: 1, now: t0.addingTimeInterval(-UsageEvidence.allowedClockSkew - 1)), "future-dated")
        XCTAssertNil(ResetCreditPolicy.input(snapshot: nil, leadDays: 1, now: t0))
    }

    func testMemoryDecodesLossilyPerEntry() throws {
        let json = #"{"resetCredits":{"good":{"lastSeenCount":1,"availableRow":"active","expiryHandled":false,"expiringRow":"inactive"},"bad":{"lastSeenCount":"x"}},"notifiedReauth":true}"#
        let state = try JSONDecoder().decode(AccountAlertState.self, from: Data(json.utf8))
        XCTAssertEqual(state.resetCredits.keys.sorted(), ["good"])
        XCTAssertTrue(state.notifiedReauth, "a bad entry never costs the rest of the state")
        let wrongShape = try JSONDecoder().decode(AccountAlertState.self, from: Data(#"{"resetCredits":[1,2]}"#.utf8))
        XCTAssertEqual(wrongShape.resetCredits, [:])
    }

    /// One row per credit. When the expiring alert fires
    /// it must retract the "available" row (which would otherwise sit next
    /// to "expiring" showing the same credit twice) — but only if that row
    /// was still active; see `testExpiringFiringLeavesDismissedAvailableRowAlone`
    /// for the "already dismissed" half.
    func testExpiringFiringDeactivatesAnActiveAvailableRow() {
        let c = credit(expiresIn: 30 * day)
        let state = run(AccountAlertState(), input([c])).next
        XCTAssertEqual(state.resetCredits["c1"]?.availableRow, .active, "premise")
        let atBoundary = t0.addingTimeInterval(29 * day)
        let r = run(state, input([c], now: atBoundary))
        XCTAssertEqual(r.events, [.resetCreditExpiring(credit: c)])
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .active)
        XCTAssertEqual(r.next.resetCredits["c1"]?.availableRow, .inactive)
    }

    func testExpiringFiringLeavesDismissedAvailableRowAlone() {
        let c = credit(expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([c])).next
        state.resetCredits["c1"]?.availableRow = .dismissed
        let atBoundary = t0.addingTimeInterval(29 * day)
        let r = run(state, input([c], now: atBoundary))
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .active)
        XCTAssertEqual(r.next.resetCredits["c1"]?.availableRow, .dismissed, "already-dismissed rows are not resurrected")
    }

    /// The mirror of the two tests above. Replenishment
    /// (a count increase) reactivating `availableRow` must retract an
    /// active `expiringRow`, or the same credit shows twice: one row saying
    /// it's available, another saying it's about to expire.
    func testCountIncreaseAfterExpiringFiredDeactivatesAnActiveExpiringRow() {
        let c = credit(expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([c])).next
        let atBoundary = t0.addingTimeInterval(29 * day)
        state = run(state, input([c], now: atBoundary)).next
        XCTAssertEqual(state.resetCredits["c1"]?.expiringRow, .active, "premise: expiring already fired")
        XCTAssertEqual(state.resetCredits["c1"]?.availableRow, .inactive, "premise: retracted by expiring firing")

        // Still inside the credit's own lead window at `atBoundary` (it
        // hasn't expired yet, and the boundary is exactly where "soon"
        // starts) — `expiringSoon` on the re-fired available event is true.
        let risen = credit(count: 2, expiresIn: 30 * day)
        let r = run(state, input([risen], now: atBoundary))
        XCTAssertEqual(r.events, [.resetCreditAvailable(credit: risen, expiringSoon: true)])
        XCTAssertEqual(r.next.resetCredits["c1"]?.availableRow, .active)
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .inactive, "one row per credit")
    }

    /// Half of the mirror above: an already-`.dismissed` expiring row must
    /// not be resurrected as `.inactive` — it stays exactly how the user
    /// left it, same as `testExpiringFiringLeavesDismissedAvailableRowAlone`.
    func testCountIncreaseLeavesDismissedExpiringRowAlone() {
        let c = credit(expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([c])).next
        let atBoundary = t0.addingTimeInterval(29 * day)
        state = run(state, input([c], now: atBoundary)).next
        state.resetCredits["c1"]?.expiringRow = .dismissed

        let risen = credit(count: 2, expiresIn: 30 * day)
        let r = run(state, input([risen], now: atBoundary))
        XCTAssertEqual(r.next.resetCredits["c1"]?.availableRow, .active)
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .dismissed, "already-dismissed rows are not resurrected")
    }

    /// Claude grant ids are static strings (e.g. a launch
    /// grant extended), so the same id can come back with a LATER expiry —
    /// a re-grant that must be able to fire the expiring alert again, even
    /// though `expiryHandled` already latched true for the OLD expiry.
    func testReGrantUnderSameIDWithLaterExpiryRearmsExpiring() {
        let c = credit(expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([c])).next
        let atBoundary = t0.addingTimeInterval(29 * day)
        state = run(state, input([c], now: atBoundary)).next
        XCTAssertEqual(state.resetCredits["c1"]?.expiringRow, .active, "premise: expiring already fired")
        XCTAssertEqual(state.resetCredits["c1"]?.lastSeenExpiresAt, c.expiresAt, "premise")

        // Same id, re-granted with a LATER expiry — arrives far outside its
        // own new lead window, so nothing fires yet, but the re-arm itself
        // must happen on this pass.
        let regranted = credit(expiresIn: 60 * day)
        let r1 = run(state, input([regranted], now: atBoundary))
        XCTAssertEqual(r1.events, [], "the new expiry is far out — no immediate event")
        XCTAssertEqual(r1.next.resetCredits["c1"]?.expiryHandled, false, "re-armed")
        XCTAssertEqual(r1.next.resetCredits["c1"]?.expiringRow, .inactive, "re-armed")
        XCTAssertEqual(r1.next.resetCredits["c1"]?.lastSeenExpiresAt, regranted.expiresAt)

        // Later, inside the NEW expiry's lead window: expiring fires again.
        let newBoundary = t0.addingTimeInterval(60 * day - day)
        let r2 = run(r1.next, input([regranted], now: newBoundary))
        XCTAssertEqual(r2.events, [.resetCreditExpiring(credit: regranted)])
    }

    /// The re-arm is one-directional: an expiry that moved EARLIER (a
    /// correction, not a re-grant) must not undo an already-fired expiring
    /// alert. Uses an expiry that is earlier than the stored one but still
    /// in the future (not filtered by `unexpired`), and — deliberately —
    /// still inside its OWN lead window, so a wrongly-triggered re-arm would
    /// be observable as a second expiring event firing here.
    func testEarlierExpiryNeverRearms() {
        let c = credit(expiresIn: 30 * day)
        var state = run(AccountAlertState(), input([c])).next
        let atBoundary = t0.addingTimeInterval(29 * day)
        state = run(state, input([c], now: atBoundary)).next
        XCTAssertEqual(state.resetCredits["c1"]?.expiryHandled, true, "premise")

        let earlier = credit(expiresIn: 29.5 * day)
        let r = run(state, input([earlier], now: atBoundary))
        XCTAssertEqual(r.events, [], "an earlier expiry must not re-arm")
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiryHandled, true, "unchanged")
        XCTAssertEqual(r.next.resetCredits["c1"]?.expiringRow, .active, "unchanged")
    }

    /// Legacy `alert-state.json` written before this field existed has no
    /// `lastSeenExpiresAt` key at all.
    func testLegacyMemoryWithoutLastSeenExpiresAtDecodes() throws {
        let json = #"{"resetCredits":{"c1":{"lastSeenCount":1,"availableRow":"active","expiryHandled":false,"expiringRow":"inactive"}}}"#
        let state = try JSONDecoder().decode(AccountAlertState.self, from: Data(json.utf8))
        XCTAssertEqual(state.resetCredits["c1"]?.lastSeenCount, 1)
        XCTAssertNil(state.resetCredits["c1"]?.lastSeenExpiresAt)
    }

    /// A wrong-typed `lastSeenExpiresAt` must not cost the entry its row
    /// state — see `ResetCreditAlertMemory.init(from:)`.
    func testWrongTypedLastSeenExpiresAtDecodesToNilNotAThrow() throws {
        let json = #"{"resetCredits":{"c1":{"lastSeenCount":1,"availableRow":"active","expiryHandled":false,"expiringRow":"inactive","lastSeenExpiresAt":"not-a-date"}}}"#
        let state = try JSONDecoder().decode(AccountAlertState.self, from: Data(json.utf8))
        XCTAssertEqual(state.resetCredits["c1"]?.lastSeenCount, 1, "the rest of the entry survives")
        XCTAssertNil(state.resetCredits["c1"]?.lastSeenExpiresAt)
    }

    /// ChatGPT is one credit per entry, so a multi-credit
    /// grant would otherwise post N notifications and show N rows in one
    /// pass. Collapse multiple `.resetCreditAvailable` firings into one.
    func testTwoNewCreditsInOnePassCollapseToOneAvailableEvent() {
        let a = credit("a", count: 1, expiresIn: 20 * day)
        // Arrives already inside ITS OWN lead window — `expiringSoon` on the
        // merged event must be "any of them", not "all" or "none".
        let b = credit("b", count: 3, expiresIn: 12 * 3_600)
        let r = run(AccountAlertState(), input([a, b]))
        XCTAssertEqual(r.events.count, 1, "one event, not two")
        guard case .resetCreditAvailable(let merged, let expiringSoon) = r.events[0] else {
            return XCTFail("expected a single resetCreditAvailable event, got \(r.events)")
        }
        XCTAssertEqual(merged.id, "b", "the id of the soonest-expiring of the group")
        XCTAssertEqual(merged.count, 4, "sum of their counts")
        XCTAssertEqual(merged.expiresAt, b.expiresAt, "soonest expiry")
        XCTAssertTrue(expiringSoon, "any of the group being inside its lead window counts")
        // Per-credit memory is still tracked individually, unaffected by
        // the event collapse.
        XCTAssertEqual(r.next.resetCredits["a"]?.availableRow, .active)
        XCTAssertEqual(r.next.resetCredits["b"]?.availableRow, .active)
        XCTAssertEqual(r.next.resetCredits["a"]?.lastSeenCount, 1)
        XCTAssertEqual(r.next.resetCredits["b"]?.lastSeenCount, 3)
    }

    /// Same collapse for multiple `.resetCreditExpiring` firings in one pass:
    /// both credits already had their "available" alert; a single later pass
    /// crosses both of their (different) lead-window boundaries at once.
    func testTwoExpiringCreditsInOnePassCollapseToOneExpiringEvent() {
        let a = credit("a", expiresIn: 30 * day)
        let b = credit("b", expiresIn: 29 * day + 3_600) // one hour later than a's boundary
        let baseline = run(AccountAlertState(), input([a, b])).next
        let atBothBoundaries = t0.addingTimeInterval(29 * day)
        let r = run(baseline, input([a, b], now: atBothBoundaries))
        XCTAssertEqual(r.events.count, 1, "one event, not two")
        guard case .resetCreditExpiring(let merged) = r.events[0] else {
            return XCTFail("expected a single resetCreditExpiring event, got \(r.events)")
        }
        XCTAssertEqual(merged.id, "b", "the id of the soonest-expiring of the group")
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.expiresAt, b.expiresAt)
        XCTAssertEqual(r.next.resetCredits["a"]?.expiringRow, .active)
        XCTAssertEqual(r.next.resetCredits["b"]?.expiringRow, .active)
    }

    /// Title collapse rule: the merged credit's title is the shared title
    /// only when EXACTLY one distinct non-nil title exists among the group;
    /// otherwise nil (never guessed).
    func testMergedAvailableTitleRules() {
        func titled(_ id: String, _ title: String?, expiresIn: TimeInterval) -> ResetCredit {
            ResetCredit(id: id, title: title, count: 1, expiresAt: t0.addingTimeInterval(expiresIn), usableNow: true)
        }
        // Same title on both → kept.
        let sameTitle = run(AccountAlertState(), input([
            titled("a", "Launch reset", expiresIn: 20 * day),
            titled("b", "Launch reset", expiresIn: 10 * day),
        ]))
        guard case .resetCreditAvailable(let m1, _) = sameTitle.events.first else { return XCTFail() }
        XCTAssertEqual(m1.title, "Launch reset")

        // Different titles → nil.
        let differentTitles = run(AccountAlertState(), input([
            titled("c", "Launch reset", expiresIn: 20 * day),
            titled("d", "Autumn reset", expiresIn: 10 * day),
        ]))
        guard case .resetCreditAvailable(let m2, _) = differentTitles.events.first else { return XCTFail() }
        XCTAssertNil(m2.title)

        // One titled, one untitled → the one non-nil title still counts as
        // "exactly one distinct non-nil title".
        let oneUntitled = run(AccountAlertState(), input([
            titled("e", "Launch reset", expiresIn: 20 * day),
            titled("f", nil, expiresIn: 10 * day),
        ]))
        guard case .resetCreditAvailable(let m3, _) = oneUntitled.events.first else { return XCTFail() }
        XCTAssertEqual(m3.title, "Launch reset")

        // Both untitled → nil.
        let bothUntitled = run(AccountAlertState(), input([
            titled("g", nil, expiresIn: 20 * day),
            titled("h", nil, expiresIn: 10 * day),
        ]))
        guard case .resetCreditAvailable(let m4, _) = bothUntitled.events.first else { return XCTFail() }
        XCTAssertNil(m4.title)
    }

    /// `usableNow` collapse rule: true only if ALL are true, false only if
    /// ALL are false, nil (unknown) otherwise — never guessed from a mix.
    func testMergedAvailableUsableNowRules() {
        func usable(_ id: String, _ value: Bool?, expiresIn: TimeInterval) -> ResetCredit {
            ResetCredit(id: id, title: nil, count: 1, expiresAt: t0.addingTimeInterval(expiresIn), usableNow: value)
        }
        func firstUsableNow(_ items: [ResetCredit]) -> Bool? {
            let r = run(AccountAlertState(), input(items))
            guard case .resetCreditAvailable(let merged, _) = r.events.first else {
                XCTFail("expected a resetCreditAvailable event")
                return nil
            }
            return merged.usableNow
        }
        XCTAssertEqual(firstUsableNow([usable("a", true, expiresIn: day), usable("b", true, expiresIn: 2 * day)]), true)
        XCTAssertEqual(firstUsableNow([usable("c", false, expiresIn: day), usable("d", false, expiresIn: 2 * day)]), false)
        XCTAssertNil(firstUsableNow([usable("e", true, expiresIn: day), usable("f", false, expiresIn: 2 * day)]))
        XCTAssertNil(firstUsableNow([usable("g", true, expiresIn: day), usable("h", nil, expiresIn: 2 * day)]))
    }

    func testChannelKeyForResetEvents() {
        let c = credit(expiresIn: day)
        XCTAssertEqual(AlertChannelKey.forEvent(.resetCreditAvailable(credit: c, expiringSoon: false), provider: .claude), "claude.resetCredits")
        // `Provider.chatGPT.rawValue` is "chatgpt" (lowercase), not "chatGPT".
        XCTAssertEqual(AlertChannelKey.forEvent(.resetCreditExpiring(credit: c), provider: .chatGPT), "chatgpt.resetCredits")
    }
}
