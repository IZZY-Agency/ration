import XCTest
@testable import Ration

/// `KeepAwakePolicy`: the automatic hold follows the IN USE phase and nothing
/// else — it ends exactly when the last burning account's bright phase ends.
final class KeepAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ agoSeconds: TimeInterval) -> Date { now.addingTimeInterval(-agoSeconds) }

    func testNoActivityHoldsNothing() {
        XCTAssertNil(KeepAwakePolicy.holdUntil(activity: [:], now: now))
    }

    func testFiveHourActivityHoldsUntilItsInUsePhaseEnds() {
        let usage = ActiveUsage(lastUsedAt: at(100), source: .fiveHour)
        XCTAssertEqual(
            KeepAwakePolicy.holdUntil(activity: [UUID(): usage], now: now),
            at(100).addingTimeInterval(InUsePhase.inUseThreshold)
        )
    }

    func testWeeklyOnlyActivityHoldsForTheWiderWeeklyPhase() {
        let usage = ActiveUsage(lastUsedAt: at(1_000), source: .weekly)
        XCTAssertEqual(
            KeepAwakePolicy.holdUntil(activity: [UUID(): usage], now: now),
            at(1_000).addingTimeInterval(InUsePhase.weeklyInUseThreshold)
        )
    }

    func testTheLatestEndingPhaseWins() {
        let activity: [UUID: ActiveUsage] = [
            UUID(): ActiveUsage(lastUsedAt: at(800), source: .fiveHour),   // ends in 100 s
            UUID(): ActiveUsage(lastUsedAt: at(1_500), source: .weekly),   // ends in 300 s
            UUID(): ActiveUsage(lastUsedAt: at(500), source: .fiveHour),   // ends in 400 s
        ]
        XCTAssertEqual(KeepAwakePolicy.holdUntil(activity: activity, now: now), now.addingTimeInterval(400))
    }

    func testActivityPastItsInUsePhaseHoldsNothing() {
        let usage = ActiveUsage(lastUsedAt: at(InUsePhase.inUseThreshold + 1), source: .fiveHour)
        XCTAssertNil(KeepAwakePolicy.holdUntil(activity: [UUID(): usage], now: now))
    }

    func testOnlyTheExpiredAccountIsIgnored() {
        let activity: [UUID: ActiveUsage] = [
            UUID(): ActiveUsage(lastUsedAt: at(2_000), source: .fiveHour), // last used, not in use
            UUID(): ActiveUsage(lastUsedAt: at(60), source: .fiveHour),
        ]
        XCTAssertEqual(
            KeepAwakePolicy.holdUntil(activity: activity, now: now),
            at(60).addingTimeInterval(InUsePhase.inUseThreshold)
        )
    }

    func testFutureDatedActivityHoldsNothing() {
        let usage = ActiveUsage(lastUsedAt: now.addingTimeInterval(60), source: .fiveHour)
        XCTAssertNil(KeepAwakePolicy.holdUntil(activity: [UUID(): usage], now: now))
    }
}
