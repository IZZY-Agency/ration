import XCTest
@testable import Ration

/// The popover account badge is a button exactly when it shows a problem the
/// header counts, and its click is the header's STALE click for that account.
/// Copy is covered by `AttentionCopyLocalizationTests.testProblemBadgeCopy`.
@MainActor
final class AccountStateBadgeProblemActionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_434_800)
    private var fresh: TimeInterval { 60 }
    private var old: TimeInterval { UsageEvidence.maxAge + 60 }

    private func presentation(
        age: TimeInterval?,
        state: AccountViewState,
        paused: Bool = false
    ) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(
            id: id, provider: .cursor, label: "Work",
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast,
            isPaused: paused
        )
        var snapshot: UsageSnapshot?
        if let age {
            snapshot = UsageSnapshot(accountID: id, fetchedAt: now.addingTimeInterval(-age), fiveHour: nil, weekly: nil)
        }
        return AccountPresentation(account: account, snapshot: snapshot, state: state)
    }

    private func action(_ presentation: AccountPresentation) -> AccountBadgeProblemAction? {
        AccountStateBadge.problemAction(for: presentation, now: now, locale: L10n.en, perform: { _ in })
    }

    func testProblemStatesTheHeaderCountsAreClickable() {
        let clickable: [AccountPresentation] = [
            presentation(age: old, state: .stale(lastError: .transport)),
            presentation(age: nil, state: .stale(lastError: .transport)),
            presentation(age: fresh, state: .rateLimited(retryAt: nil)),
            presentation(age: fresh, state: .rateLimited(retryAt: now.addingTimeInterval(300))),
            presentation(age: fresh, state: .integrationChanged),
            presentation(age: nil, state: .unavailable),
            // Aged out with no error of its own.
            presentation(age: old, state: .current),
            presentation(age: old, state: .loading),
        ]
        for p in clickable {
            XCTAssertNotNil(action(p), "\(p.state) should be clickable")
            XCTAssertTrue(HeaderFreshness.needsAttention(p, now: now), "\(p.state): the header counts it")
        }
    }

    func testCurrentAndNonProblemBadgesAreNotClickable() {
        let plain: [AccountPresentation] = [
            // The live dot and the spinner over current data.
            presentation(age: fresh, state: .current),
            presentation(age: fresh, state: .loading),
            // First fetch still running: nothing to judge yet.
            presentation(age: nil, state: .loading),
            // Already its own Sign In control.
            presentation(age: old, state: .reauthenticationRequired),
            // A failed refresh over young data: the header still says LIVE.
            presentation(age: fresh, state: .stale(lastError: .transport)),
            // Paused: the header does not count it.
            presentation(age: old, state: .stale(lastError: .transport), paused: true),
        ]
        for p in plain {
            XCTAssertNil(action(p), "\(p.state) must stay plain")
        }
    }

    /// The header's own classifier is the expectation — never the badge's
    /// logic. Every account the header counts has a clickable badge, except
    /// a sign-in, whose badge is already its own Sign In button; nothing the
    /// header does not count is clickable. Swept over states × ages × paused.
    func testClickableSetIsExactlyTheHeadersProblemSet() {
        let states: [AccountViewState] = [
            .loading, .current, .stale(lastError: .transport), .stale(lastError: .offline),
            .reauthenticationRequired, .rateLimited(retryAt: nil), .integrationChanged, .unavailable,
        ]
        let ages: [TimeInterval?] = [nil, fresh, old]
        for state in states {
            for age in ages {
                for paused in [false, true] {
                    let p = presentation(age: age, state: state, paused: paused)
                    let context = "\(state), age \(String(describing: age)), paused \(paused)"
                    let headerCounts = AttentionCause.classify(p, now: now) != nil
                    if state == .reauthenticationRequired {
                        XCTAssertNil(action(p), "Sign In is its own control: \(context)")
                    } else {
                        XCTAssertEqual(action(p) != nil, headerCounts, context)
                    }
                }
            }
        }
    }

    /// `.current` / `.loading` over an aged-out snapshot: the header counts
    /// the account, so the card draws the stale word (not the live dot or
    /// the spinner) and it is clickable.
    func testAgedOutCurrentOrLoadingShowsStaleAndIsClickable() throws {
        for state in [AccountViewState.current, .loading] {
            let p = presentation(age: old, state: state)
            XCTAssertTrue(AccountStateBadge.showsAgedOut(p, now: now), "\(state)")
            XCTAssertEqual(AccountStateBadge.compactProblemText(for: p, now: now, locale: L10n.en), "stale")
            let spoken = try XCTUnwrap(action(p)).spokenLabel
            XCTAssertEqual(spoken, "Work: stale. Opens its settings.")
        }
        // Fresh: the live dot / spinner, not a problem.
        for state in [AccountViewState.current, .loading] {
            let p = presentation(age: fresh, state: state)
            XCTAssertFalse(AccountStateBadge.showsAgedOut(p, now: now), "\(state)")
        }
    }

    func testClickRequestsTheAccountsSettings() throws {
        let p = presentation(age: old, state: .stale(lastError: .transport))
        let requested = TargetLog()
        let action = try XCTUnwrap(
            AccountStateBadge.problemAction(for: p, now: now, locale: L10n.en, perform: { target in
                requested.targets.append(target)
            })
        )
        action.open()
        XCTAssertEqual(requested.targets, [.account(p.id)])
        // The same target the header's STALE click opens for this account.
        XCTAssertEqual(FreshnessHelp.make(presentations: [p], now: now, locale: L10n.en)?.target, .account(p.id))
    }
}

@MainActor
private final class TargetLog {
    var targets: [FreshnessHelp.Target] = []
}
