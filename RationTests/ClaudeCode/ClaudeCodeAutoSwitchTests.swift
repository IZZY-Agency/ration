import XCTest
@testable import Ration

final class ClaudeCodeAutoSwitchTests: XCTestCase {
    private typealias Auto = ClaudeCodeAutoSwitch
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private let weekly = Auto.Rule(percent: 75, kind: .weekly)

    /// Arguments are USED fractions.
    private func snap(week: Double?, five: Double? = 0.1, fable: Double? = nil, fetched: Date? = nil,
                      weekResetIn days: Double = 3) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(), fetchedAt: fetched ?? now,
            fiveHour: five.map { UsageWindow(kind: .fiveHour, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(3_600)) },
            weekly: week.map { UsageWindow(kind: .weekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(days * 86_400)) },
            modelWeekly: fable.map { UsageWindow(kind: .modelWeekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(3 * 86_400), label: "Fable") }
        )
    }

    private func candidate(_ n: Int, verified: Bool = true, paused: Bool = false, usable: Bool = true,
                           _ snapshot: UsageSnapshot?, plan: Int? = 20) -> Auto.Candidate {
        Auto.Candidate(accountID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, signInUUID: "acc-\(n)",
                       verified: verified, isPaused: paused, usable: usable, snapshot: snapshot, planUnits: plan, order: n)
    }

    private func decide(_ current: Auto.Candidate, _ others: [Auto.Candidate], rule: Auto.Rule? = nil) -> Auto.Decision {
        Auto.decide(current: current, others: others, rule: rule ?? weekly, now: now)
    }

    func testBelowTheThresholdNothingHappens() {
        XCTAssertEqual(decide(candidate(1, snap(week: 0.74)), [candidate(2, snap(week: 0.1))]), .none)
    }

    func testAtTheThresholdItSwitchesToTheAccountWithRoom() {
        let target = candidate(2, snap(week: 0.2))
        XCTAssertEqual(decide(candidate(1, snap(week: 0.75)), [target]),
                       .switchTo(signInUUID: "acc-2", accountID: target.accountID, usedPercent: 75))
    }

    func testStaleOrUnverifiedCurrentUsageNeverTriggers() {
        let stale = snap(week: 0.9, fetched: now.addingTimeInterval(-(UsageEvidence.maxAge + 10)))
        XCTAssertEqual(decide(candidate(1, stale), [candidate(2, snap(week: 0.1))]), .none)
        XCTAssertEqual(decide(candidate(1, verified: false, snap(week: 0.9)), [candidate(2, snap(week: 0.1))]), .none)
        XCTAssertEqual(decide(candidate(1, usable: false, snap(week: 0.9)), [candidate(2, snap(week: 0.1))]), .none)
    }

    /// Room on the weekly limit is not enough when the 5-hour is full.
    func testATargetFullOnAnotherLimitIsNotChosen() {
        let fullFiveHour = candidate(2, snap(week: 0.1, five: 0.9))
        let roomy = candidate(3, snap(week: 0.5, five: 0.1))
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [fullFiveHour, roomy]),
                       .switchTo(signInUUID: "acc-3", accountID: roomy.accountID, usedPercent: 80))
    }

    func testEveryTargetFullIsNoRoom() {
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [candidate(2, snap(week: 0.76)), candidate(3, snap(week: 0.2, five: 0.8))]),
                       .noRoom(usedPercent: 80, candidates: ["acc-2", "acc-3"]))
    }

    /// Unknown is not full: "no room" only when every candidate is current.
    func testAStaleTargetMeansWaitingNotNoRoom() {
        let stale = snap(week: 0.1, fetched: now.addingTimeInterval(-(UsageEvidence.maxAge + 10)))
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [candidate(2, stale), candidate(3, snap(week: 0.9))]), .waiting(usedPercent: 80))
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [candidate(2, nil)]), .waiting(usedPercent: 80))
    }

    func testUnverifiedAndPausedTargetsAreNeverUsed() {
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [candidate(2, verified: false, snap(week: 0.1)), candidate(3, paused: true, snap(week: 0.1))]),
                       .noRoom(usedPercent: 80, candidates: []))
    }

    /// Needing a new sign-in is a known state, not unknown usage.
    func testATargetNeedingSignInIsIneligible() {
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [candidate(2, usable: false, snap(week: 0.1))]),
                       .noRoom(usedPercent: 80, candidates: ["acc-2"]))
    }

    func testFableRuleUsesOnlyAccountsWithAFableLimit() {
        let fable = Auto.Rule(percent: 75, kind: .modelWeekly)
        let noFable = candidate(2, snap(week: 0.1))
        let withFable = candidate(3, snap(week: 0.3, fable: 0.2))
        XCTAssertEqual(decide(candidate(1, snap(week: 0.3, fable: 0.8)), [noFable, withFable], rule: fable),
                       .switchTo(signInUUID: "acc-3", accountID: withFable.accountID, usedPercent: 80))
        XCTAssertEqual(decide(candidate(1, snap(week: 0.9)), [withFable], rule: fable), .none, "no Fable limit on the current account")
    }

    func testRankingMostRoomThenPlanThenResetThenOrder() {
        let current = candidate(1, snap(week: 0.8))
        XCTAssertEqual(decide(current, [candidate(2, snap(week: 0.5)), candidate(3, snap(week: 0.3))]).target, "acc-3")
        XCTAssertEqual(decide(current, [candidate(2, snap(week: 0.3), plan: 5), candidate(3, snap(week: 0.3), plan: 20)]).target, "acc-3")
        XCTAssertEqual(decide(current, [candidate(2, snap(week: 0.3), plan: nil), candidate(3, snap(week: 0.3), plan: 1)]).target, "acc-3")
        XCTAssertEqual(decide(current, [candidate(2, snap(week: 0.3, weekResetIn: 4)), candidate(3, snap(week: 0.3, weekResetIn: 2))]).target, "acc-3")
        XCTAssertEqual(decide(current, [candidate(3, snap(week: 0.3)), candidate(2, snap(week: 0.3))]).target, "acc-2")
    }

    /// A missing 5-hour or weekly window is unknown, not full.
    func testATargetMissingAWindowIsWaitingNotNoRoom() {
        let noWeekly = UsageSnapshot(accountID: UUID(), fetchedAt: now,
                                     fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: now.addingTimeInterval(3_600)),
                                     weekly: nil)
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), [candidate(2, noWeekly)]), .waiting(usedPercent: 80))
    }

    func testNoOtherAccountIsNoRoom() {
        XCTAssertEqual(decide(candidate(1, snap(week: 0.8)), []), .noRoom(usedPercent: 80, candidates: []))
    }
}

private extension ClaudeCodeAutoSwitch.Decision {
    var target: String? {
        if case .switchTo(let uuid, _, _) = self { uuid } else { nil }
    }
}
