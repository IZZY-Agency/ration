import XCTest
@testable import Ration

/// Which accounts need attention, why, and which one the header's click
/// opens. Copy is covered by `AttentionCopyLocalizationTests`.
final class AttentionGuidanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_434_800)
    private var fresh: TimeInterval { 60 }
    private var old: TimeInterval { UsageEvidence.maxAge + 60 }

    private func presentation(
        _ label: String = "A",
        provider: Provider = .claude,
        age: TimeInterval?,
        state: AccountViewState,
        paused: Bool = false
    ) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(
            id: id, provider: provider, label: label,
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast,
            isPaused: paused
        )
        let snapshot = age.map {
            UsageSnapshot(accountID: id, fetchedAt: now.addingTimeInterval(-$0), fiveHour: nil, weekly: nil)
        }
        return AccountPresentation(account: account, snapshot: snapshot, state: state)
    }

    // MARK: Classification

    func testHealthyAccountsHaveNoGuidance() {
        XCTAssertNil(AttentionGuidance.make(presentation: presentation(age: fresh, state: .current), now: now))
        // Every poll passes through `.loading`: not a problem while fresh.
        XCTAssertNil(AttentionGuidance.make(presentation: presentation(age: fresh, state: .loading), now: now))
        // First fetch still running: nothing to judge yet.
        XCTAssertNil(AttentionGuidance.make(presentation: presentation(age: nil, state: .loading), now: now))
        // A failed refresh over young data: the header still says LIVE, and
        // the banner agrees.
        XCTAssertNil(AttentionGuidance.make(presentation: presentation(age: fresh, state: .stale(lastError: .transport)), now: now))
    }

    func testPausedAccountHasNoGuidance() {
        let paused = presentation(age: old, state: .reauthenticationRequired, paused: true)
        XCTAssertNil(AttentionGuidance.make(presentation: paused, now: now))
    }

    func testCauses() {
        func cause(_ age: TimeInterval?, _ state: AccountViewState) -> AttentionCause? {
            AttentionCause.classify(presentation(age: age, state: state), now: now)
        }
        XCTAssertEqual(cause(fresh, .reauthenticationRequired), .signInExpired)
        XCTAssertEqual(cause(nil, .reauthenticationRequired), .signInExpired)
        XCTAssertEqual(cause(fresh, .integrationChanged), .integrationChanged)
        XCTAssertEqual(cause(fresh, .rateLimited(retryAt: nil)), .rateLimited(retryAt: nil))
        XCTAssertEqual(cause(nil, .unavailable), .pageNotLoading(lastError: nil))
        XCTAssertEqual(cause(nil, .stale(lastError: .transport)), .pageNotLoading(lastError: .transport))
        XCTAssertEqual(cause(old, .stale(lastError: .transport)), .pageNotLoading(lastError: .transport))
        XCTAssertEqual(cause(old, .stale(lastError: .server(statusCode: 500))), .serverErrors)
        XCTAssertEqual(cause(old, .stale(lastError: .offline)), .connection(lastError: .offline))
        XCTAssertEqual(cause(old, .current), .agedOut)
        XCTAssertEqual(cause(old, .loading), .agedOut)
    }

    /// The banner shows exactly for the accounts the header counts.
    func testAgreesWithTheHeader() {
        let states: [AccountViewState] = [
            .loading, .current, .stale(lastError: .transport), .reauthenticationRequired,
            .rateLimited(retryAt: nil), .integrationChanged, .unavailable,
        ]
        for state in states {
            for age in [nil, fresh, old] as [TimeInterval?] {
                let p = presentation(age: age, state: state)
                let header = HeaderFreshness.make(presentations: [p], now: now)
                let counted: Bool = header == .stale(count: 1)
                XCTAssertEqual(
                    AttentionGuidance.make(presentation: p, now: now) != nil,
                    counted,
                    "\(state) age \(String(describing: age))"
                )
            }
        }
    }

    /// The OFFLINE header says "check your internet connection"; no account
    /// it counts may be told to sign in again (button or step), in any mix
    /// of states and ages.
    func testOfflineHeaderNeverComesWithSignInGuidance() {
        let states: [AccountViewState] = [
            .loading, .current, .stale(lastError: .transport), .stale(lastError: .offline),
            .stale(lastError: .server(statusCode: 500)), .reauthenticationRequired,
            .rateLimited(retryAt: nil), .integrationChanged, .unavailable,
        ]
        let ages: [TimeInterval?] = [nil, fresh, old]
        var offlineMixes = 0
        for firstState in states {
            for firstAge in ages {
                for secondState in states {
                    for secondAge in ages {
                        let accounts = [
                            presentation("one", age: firstAge, state: firstState),
                            presentation("two", age: secondAge, state: secondState),
                        ]
                        guard HeaderFreshness.make(presentations: accounts, now: now) == .offline else { continue }
                        offlineMixes += 1
                        for account in accounts {
                            let guidance = AttentionGuidance.make(presentation: account, among: accounts, now: now)
                            let label = "\(firstState)/\(String(describing: firstAge)) + \(secondState)/\(String(describing: secondAge))"
                            XCTAssertNotNil(guidance, label)
                            XCTAssertFalse(guidance?.actions.contains(.signInAgain) ?? true, label)
                            XCTAssertFalse(guidance?.steps.contains { $0.link == .signInAgain } ?? true, label)
                            XCTAssertEqual(guidance?.actions, [.refreshNow], label)
                            if case .connection = guidance?.cause {} else { XCTFail("\(label): \(String(describing: guidance?.cause))") }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(offlineMixes, 0, "the sweep reached OFFLINE")
    }

    // MARK: Most actionable

    func testPriorityOrder() {
        let rate = presentation("rate", age: fresh, state: .rateLimited(retryAt: nil))
        let aged = presentation("aged", age: old, state: .current)
        let failing = presentation("failing", age: old, state: .stale(lastError: .transport))
        let server = presentation("server", age: old, state: .stale(lastError: .server(statusCode: 502)))
        let connection = presentation("connection", age: old, state: .stale(lastError: .offline))
        let changed = presentation("changed", age: fresh, state: .integrationChanged)
        let signIn = presentation("signIn", age: fresh, state: .reauthenticationRequired)
        let healthy = presentation("healthy", age: fresh, state: .current)

        XCTAssertEqual(
            AttentionCause.ranked([healthy, rate, aged, connection, server, failing, changed, signIn], now: now)
                .map(\.presentation.account.label),
            ["signIn", "changed", "failing", "server", "connection", "aged", "rate"]
        )
        var accounts = [healthy, rate, aged, failing, changed, signIn]
        XCTAssertEqual(AttentionGuidance.mostActionable(accounts, now: now)?.id, signIn.id)

        accounts.removeLast()
        XCTAssertEqual(AttentionGuidance.mostActionable(accounts, now: now)?.id, changed.id)
        accounts.removeLast()
        XCTAssertEqual(AttentionGuidance.mostActionable(accounts, now: now)?.id, failing.id)
        accounts.removeLast()
        XCTAssertEqual(AttentionGuidance.mostActionable(accounts, now: now)?.id, aged.id)
        accounts.removeLast()
        XCTAssertEqual(AttentionGuidance.mostActionable(accounts, now: now)?.id, rate.id)
        accounts.removeLast()
        XCTAssertNil(AttentionGuidance.mostActionable(accounts, now: now))
    }

    /// Unavailable (never loaded) is a failure like a stale transport error.
    func testUnavailableRanksWithFailures() {
        let aged = presentation("aged", age: old, state: .current)
        let unavailable = presentation("unavailable", age: nil, state: .unavailable)
        XCTAssertEqual(AttentionGuidance.mostActionable([aged, unavailable], now: now)?.id, unavailable.id)
    }

    func testTiesGoToDisplayOrder() {
        let first = presentation("first", age: fresh, state: .reauthenticationRequired)
        let second = presentation("second", age: fresh, state: .reauthenticationRequired)
        XCTAssertEqual(AttentionGuidance.mostActionable([first, second], now: now)?.id, first.id)
        XCTAssertEqual(AttentionGuidance.mostActionable([second, first], now: now)?.id, second.id)
    }

    func testPausedAccountsAreNeverTheTarget() {
        let paused = presentation("paused", age: fresh, state: .reauthenticationRequired, paused: true)
        let aged = presentation("aged", age: old, state: .current)
        XCTAssertEqual(AttentionGuidance.mostActionable([paused, aged], now: now)?.id, aged.id)
    }

    // MARK: Hover card

    func testLiveHasNoHoverCard() {
        XCTAssertNil(FreshnessHelp.make(presentations: [presentation(age: fresh, state: .current)], now: now))
        XCTAssertNil(FreshnessHelp.make(presentations: [], now: now))
    }

    func testHoverCardTargetsTheMostActionableAccount() throws {
        let aged = presentation("aged", age: old, state: .current)
        let signIn = presentation("signIn", age: fresh, state: .reauthenticationRequired)
        let help = try XCTUnwrap(FreshnessHelp.make(presentations: [aged, signIn], now: now))
        XCTAssertEqual(help.target, .account(signIn.id))
    }

    func testOfflineRefreshes() throws {
        let help = try XCTUnwrap(FreshnessHelp.make(
            presentations: [presentation(age: old, state: .current), presentation(age: old, state: .current)],
            now: now
        ))
        XCTAssertEqual(help.target, .refreshAll)
    }

    // MARK: Actions and hosts

    func testLinkActions() {
        XCTAssertEqual(AttentionGuidance.Action.checkForUpdates.url, URL(string: "https://github.com/IZZY-Agency/ration/releases"))
        XCTAssertEqual(AttentionGuidance.Action.reportIssue.url, AppLinks.issues)
        XCTAssertNil(AttentionGuidance.Action.signInAgain.url)
        XCTAssertNil(AttentionGuidance.Action.refreshNow.url)
    }

    /// The "check <host> opens" step names the host the sign-in page is on.
    @MainActor
    func testProviderHostsMatchTheSignInPages() {
        XCTAssertEqual(Provider.claude.appHost, ClaudeProviderAdapter().signInURL.host())
        XCTAssertEqual(Provider.chatGPT.appHost, ChatGPTProviderAdapter().signInURL.host())
        XCTAssertEqual(Provider.cursor.appHost, CursorProviderAdapter().signInURL.host())
    }
}
