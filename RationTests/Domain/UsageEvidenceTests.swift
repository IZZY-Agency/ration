import XCTest
@testable import Ration

/// `UsageEvidence` is the shared "does this observation still describe the
/// present" predicate, extracted from `WarmUpBanner` so the warm-up banner and
/// the attention drop cannot drift apart on the question.
final class UsageEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(accountID: UUID(), fetchedAt: fetchedAt, fiveHour: nil, weekly: nil)
    }

    // MARK: - The age bound

    func testFreshSnapshotIsCurrent() {
        XCTAssertTrue(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: now.addingTimeInterval(-60)),
                windowResetsAt: nil,
                now: now
            )
        )
    }

    func testSnapshotOlderThanMaxAgeIsNotCurrent() {
        XCTAssertFalse(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: now.addingTimeInterval(-UsageEvidence.maxAge - 1)),
                windowResetsAt: nil,
                now: now
            )
        )
    }

    /// The bound is inclusive — exactly at the limit still speaks for now.
    func testSnapshotExactlyAtMaxAgeIsCurrent() {
        XCTAssertTrue(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: now.addingTimeInterval(-UsageEvidence.maxAge)),
                windowResetsAt: nil,
                now: now
            )
        )
    }

    /// Derived from the poll cadence, never a hand-picked constant, so the two
    /// cannot drift. Two of the longest normal gaps.
    func testMaxAgeIsDerivedFromTheSlowestPollCadence() {
        XCTAssertEqual(
            UsageEvidence.maxAge,
            2 * Double(PollSchedule.lowPowerSeconds + PollSchedule.maxJitterSeconds)
        )
    }

    // MARK: - Overtaken by its own reset

    /// The trap the age bound alone misses: a snapshot taken minutes before a
    /// reset is still inside the ~32-minute age bound after that reset has
    /// passed, and would otherwise assert a limit that has already renewed.
    func testSnapshotTakenBeforeAPassedResetIsNotCurrent() {
        let resetsAt = now.addingTimeInterval(-60)
        XCTAssertFalse(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: resetsAt.addingTimeInterval(-120)),
                windowResetsAt: resetsAt,
                now: now
            ),
            "an observation from before a reset that has since passed says nothing about now"
        )
    }

    /// But a snapshot taken AFTER its own reported reset that still shows the
    /// window spent IS current: the provider had every chance to roll the
    /// counter and did not.
    func testSnapshotTakenAfterItsOwnPassedResetIsCurrent() {
        let resetsAt = now.addingTimeInterval(-300)
        XCTAssertTrue(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: resetsAt.addingTimeInterval(60)),
                windowResetsAt: resetsAt,
                now: now
            )
        )
    }

    /// A reset still in the future cannot have overtaken anything.
    func testFutureResetDoesNotInvalidateAFreshSnapshot() {
        XCTAssertTrue(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: now.addingTimeInterval(-60)),
                windowResetsAt: now.addingTimeInterval(3_600),
                now: now
            )
        )
    }

    /// Age is checked first: being taken after its own reset does not rescue a
    /// snapshot that is simply too old.
    func testAgeStillDisqualifiesASnapshotTakenAfterItsReset() {
        let resetsAt = now.addingTimeInterval(-UsageEvidence.maxAge - 600)
        XCTAssertFalse(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: resetsAt.addingTimeInterval(60)),
                windowResetsAt: resetsAt,
                now: now
            )
        )
    }

    // MARK: - Clock skew

    /// A snapshot dated in the future has a NEGATIVE age, which sails past a
    /// bare `age <= maxAge` check. If the system clock moves backwards, such a
    /// snapshot would keep asserting a limit for the size of the jump plus the
    /// whole age bound, instead of retracting normally.
    func testSnapshotFarInTheFutureIsNotCurrent() {
        XCTAssertFalse(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: now.addingTimeInterval(3_600)),
                windowResetsAt: nil,
                now: now
            )
        )
    }

    /// A small forward skew is tolerated — clocks disagree by seconds all the
    /// time, and treating that as stale would blank rows for no reason.
    func testSnapshotSlightlyInTheFutureIsStillCurrent() {
        XCTAssertTrue(
            UsageEvidence.isCurrent(
                snapshot: snapshot(fetchedAt: now.addingTimeInterval(UsageEvidence.allowedClockSkew / 2)),
                windowResetsAt: nil,
                now: now
            )
        )
    }
}
