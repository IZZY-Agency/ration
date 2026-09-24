import XCTest
@testable import Ration

/// The popover header's status word must say what the data says: "LIVE" only
/// while every active account's numbers are current evidence. It derives from
/// snapshot age (`UsageEvidence`), never from the poll's transient
/// `.loading`, which every refresh passes through.
final class HeaderFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func presentation(
        age: TimeInterval?,
        state: AccountViewState = .current,
        paused: Bool = false
    ) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(
            id: id, provider: .claude, label: "A",
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast,
            isPaused: paused
        )
        let snapshot = age.map {
            UsageSnapshot(accountID: id, fetchedAt: now.addingTimeInterval(-$0), fiveHour: nil, weekly: nil)
        }
        return AccountPresentation(account: account, snapshot: snapshot, state: state)
    }

    private var fresh: TimeInterval { 60 }
    private var old: TimeInterval { UsageEvidence.maxAge + 1 }

    func testAllCurrentIsLive() {
        XCTAssertEqual(
            HeaderFreshness.make(presentations: [presentation(age: fresh), presentation(age: fresh)], now: now),
            .live
        )
    }

    func testOneStaleCountsIt() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [presentation(age: fresh), presentation(age: old), presentation(age: fresh)],
                now: now
            ),
            .stale(count: 1)
        )
    }

    func testAllTooOldIsOffline() {
        XCTAssertEqual(
            HeaderFreshness.make(presentations: [presentation(age: old), presentation(age: old)], now: now),
            .offline
        )
    }

    /// Connectivity failures (a failed fetch that let the data age out) are
    /// what OFFLINE means.
    func testAllTooOldAfterOfflineFetchFailuresIsOffline() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [
                    presentation(age: old, state: .stale(lastError: .offline)),
                    presentation(age: old, state: .stale(lastError: .offline)),
                ],
                now: now
            ),
            .offline
        )
    }

    /// One account is not "offline" — it is one stale account.
    func testSingleTooOldAccountIsStaleNotOffline() {
        XCTAssertEqual(
            HeaderFreshness.make(presentations: [presentation(age: old)], now: now),
            .stale(count: 1)
        )
    }

    /// None current, but one needs a sign-in: that is not a connectivity
    /// problem, so the header must not claim the app is offline.
    func testNoneCurrentWithAccountProblemIsStaleNotOffline() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [presentation(age: old), presentation(age: fresh, state: .reauthenticationRequired)],
                now: now
            ),
            .stale(count: 2)
        )
    }

    func testPausedAccountsAreExcluded() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [presentation(age: fresh), presentation(age: old, paused: true)],
                now: now
            ),
            .live
        )
    }

    func testOnlyPausedAccountsShowsNothing() {
        XCTAssertNil(HeaderFreshness.make(presentations: [presentation(age: old, paused: true)], now: now))
    }

    /// The flicker trap: every poll passes through `.loading`.
    func testLoadingWithFreshSnapshotCountsAsCurrent() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [presentation(age: fresh, state: .loading), presentation(age: fresh)],
                now: now
            ),
            .live
        )
    }

    func testNoAccountsShowsNothing() {
        XCTAssertNil(HeaderFreshness.make(presentations: [], now: now))
    }

    /// "With a snapshot": an account still on its first fetch has nothing to
    /// be stale about yet.
    func testAccountWithoutSnapshotIsNotCounted() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [presentation(age: fresh), presentation(age: nil, state: .loading)],
                now: now
            ),
            .live
        )
        XCTAssertNil(HeaderFreshness.make(presentations: [presentation(age: nil, state: .loading)], now: now))
    }

    /// States that persist across polls are not current even while the
    /// snapshot they carry is still young.
    func testPersistentFailureStatesAreNotCurrent() {
        let failing: [AccountViewState] = [
            .reauthenticationRequired, .rateLimited(retryAt: nil), .integrationChanged, .unavailable,
        ]
        for state in failing {
            XCTAssertEqual(
                HeaderFreshness.make(
                    presentations: [presentation(age: fresh), presentation(age: fresh, state: state)],
                    now: now
                ),
                .stale(count: 1),
                "\(state)"
            )
        }
    }

    /// A fetch that FAILED before any snapshot was cached is not "awaiting its
    /// first fetch" — it is a problem, and must stop the header saying LIVE.
    func testFailedWithoutSnapshotBesideFreshAccountIsStale() {
        let failing: [AccountViewState] = [
            .reauthenticationRequired, .rateLimited(retryAt: nil), .integrationChanged, .unavailable,
            .stale(lastError: .offline),
        ]
        for state in failing {
            XCTAssertEqual(
                HeaderFreshness.make(
                    presentations: [presentation(age: fresh), presentation(age: nil, state: state)],
                    now: now
                ),
                .stale(count: 1),
                "\(state)"
            )
        }
    }

    /// Every account failed with nothing cached: the header must say so, and
    /// it is not OFFLINE — nothing aged out, nothing was ever fetched.
    func testAllFailedWithoutSnapshotsIsStale() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [
                    presentation(age: nil, state: .unavailable),
                    presentation(age: nil, state: .reauthenticationRequired),
                ],
                now: now
            ),
            .stale(count: 2)
        )
        XCTAssertEqual(
            HeaderFreshness.make(presentations: [presentation(age: nil, state: .unavailable)], now: now),
            .stale(count: 1)
        )
    }

    /// A transient fetch failure with a still-young snapshot is not a lie yet;
    /// the age bound retracts it, exactly as the drop does.
    func testTransientStaleStateWithFreshSnapshotIsCurrent() {
        XCTAssertEqual(
            HeaderFreshness.make(
                presentations: [presentation(age: fresh, state: .stale(lastError: .offline))],
                now: now
            ),
            .live
        )
    }

    func testSpokenLabels() {
        XCTAssertEqual(HeaderFreshness.live.accessibilityLabel, "Live")
        XCTAssertEqual(HeaderFreshness.stale(count: 1).accessibilityLabel, "1 account stale")
        XCTAssertEqual(HeaderFreshness.stale(count: 2).accessibilityLabel, "2 accounts stale")
        XCTAssertEqual(HeaderFreshness.offline.accessibilityLabel, "Offline")
    }

    func testVisibleText() {
        XCTAssertEqual(HeaderFreshness.live.text, "LIVE")
        XCTAssertEqual(HeaderFreshness.stale(count: 2).text, "STALE · 2")
        XCTAssertEqual(HeaderFreshness.offline.text, "OFFLINE")
    }
}
