import XCTest
@testable import Ration

@MainActor
final class ClaudeCodeModelTests: XCTestCase {
    private var tool: FakeSecurityTool!
    private var config: FakeClaudeCodeConfig!
    private var store: InMemoryClaudeCodeSignInStore!
    private var directory: URL!
    private var bridge: FakeAlertBridge!
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    override func setUp() async throws {
        tool = FakeSecurityTool(item: ["claudeAiOauth": ["refreshToken": "refresh-A", "accessToken": "access-A"],
                                       "mcpOAuth": ["server": ["token": "m1"]]])
        config = FakeClaudeCodeConfig(bytes: ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("A")))
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B")])
        directory = try makeTempDirectory()
        bridge = FakeAlertBridge()
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(links: [String: UUID]? = nil, keptUnlinked: [String] = [], auto: Bool = false, notify: Bool = true,
                           paused: Bool = false, observer: (any ClaudeCodeWriteObserver)? = nil) async throws -> ClaudeCodeModel {
        var state = ClaudeCodeState()
        state.links = links ?? ["acc-A": idA, "acc-B": idB]
        state.keptUnlinked = keptUnlinked
        state.autoSwitchEnabled = auto
        state.autoSwitchPaused = paused
        state.notify = notify
        let stateStore = JSONFileStore(fileURL: directory.appending(path: "claude-code-switch.json"), defaultValue: ClaudeCodeState())
        try await stateStore.save(state)
        let model = ClaudeCodeModel(dependencies: .init(
            switcher: ClaudeCodeSwitcher(entry: ClaudeCodeKeychainEntry(tool: tool, user: "me"), config: config, store: store,
                                         journal: InMemoryJournal(), now: { [now] in now }, confirmDelay: 0),
            stateStore: stateStore,
            logStore: JSONFileStore(fileURL: directory.appending(path: "claude-code-switches.json"), defaultValue: [])
        ), now: { [now] in now })
        model.bridge = bridge
        model.writeObserver = observer
        await model.start()
        return model
    }

    /// Arguments are USED weekly fractions.
    private func candidates(a: Double = 0.8, b: Double? = 0.1, orgB: String? = "org-B", staleB: Bool = false,
                            pausedB: Bool = false) -> [ClaudeCodeCandidate] {
        func snap(_ used: Double?, org: String?, stale: Bool = false) -> UsageSnapshot? {
            used.map {
                UsageSnapshot(accountID: UUID(), fetchedAt: stale ? now.addingTimeInterval(-(UsageEvidence.maxAge + 10)) : now,
                              fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: now.addingTimeInterval(3_600)),
                              weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(86_400)),
                              organizationID: org)
            }
        }
        return [
            ClaudeCodeCandidate(accountID: idA, label: "Work", organizationID: "org-A", isPaused: false, usable: true,
                                snapshot: snap(a, org: "org-A"), planUnits: 20, order: 0),
            ClaudeCodeCandidate(accountID: idB, label: "Personal", organizationID: orgB, isPaused: pausedB, usable: true,
                                snapshot: snap(b, org: orgB, stale: staleB), planUnits: 20, order: 1),
        ]
    }

    private func waitForPosts(_ count: Int) async {
        for _ in 0..<200 where bridge.posted.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private var log: [ClaudeCodeSwitchLogEntry] {
        get async { (try? await JSONFileStore<[ClaudeCodeSwitchLogEntry]>(fileURL: directory.appending(path: "claude-code-switches.json"), defaultValue: []).load()) ?? [] }
    }

    func testStartReadsTheCurrentAccountAndTheRememberedSignIns() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.current?.uuid, "acc-A")
        model.usageDidChange(candidates(), now: now)
        XCTAssertEqual(model.signIns.map(\.id), ["acc-A", "acc-B"])
        XCTAssertEqual(model.signIns.map(\.verified), [true, true])
        XCTAssertEqual(model.cardState(for: idA), .current)
        XCTAssertEqual(model.cardState(for: idB), .canSwitch)
        XCTAssertEqual(model.cardState(for: UUID()), .none)
    }

    func testAManualSwitchUpdatesStatusAndLogButDoesNotNotify() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInClaudeCode(accountID: idB)
        XCTAssertEqual(model.current?.uuid, "acc-B")
        XCTAssertEqual(model.state.status, .switched(at: now, from: "acc-A", to: "acc-B", automatic: false))
        let entries = await log
        XCTAssertEqual(entries.map(\.to), ["acc-B"])
        XCTAssertEqual(entries.first?.automatic, false)
        XCTAssertTrue(bridge.posted.isEmpty)
    }

    /// Five refreshes over the threshold → one switch.
    func testRepeatedRefreshesStartOneSwitch() async throws {
        let model = try await makeModel(auto: true)
        for _ in 0..<5 { model.usageDidChange(candidates(), now: now) }
        await model.waitUntilIdle()
        let entries = await log
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(model.current?.uuid, "acc-B")
        XCTAssertEqual(model.state.status, .switched(at: now, from: "acc-A", to: "acc-B", automatic: true))
        await waitForPosts(1)
        XCTAssertEqual(bridge.posted.count, 1)
    }

    /// A click during an automatic switch waits for it.
    func testAClickDuringAnAutomaticSwitchDoesNotSwitchTwice() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        await model.useInClaudeCode(accountID: idB)
        await model.waitUntilIdle()
        let entries = await log
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(model.current?.uuid, "acc-B")
    }

    func testAConflictPausesAutomaticSwitchingUntilResumed() async throws {
        var fired = false
        tool.afterWrite = { item in
            guard !fired else { return }
            fired = true
            var object = try! JSONSerialization.jsonObject(with: item!) as! [String: Any]
            object["mcpOAuth"] = ["server": ["token": "m9"]]
            item = try! JSONSerialization.data(withJSONObject: object)
        }
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertTrue(model.state.autoSwitchPaused)
        XCTAssertEqual(model.state.status, .conflict(at: now))
        XCTAssertEqual(model.current?.uuid, "acc-A")
        await waitForPosts(1)
        XCTAssertEqual(bridge.posted.count, 1, "the failure is notified")
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        let entries = await log
        XCTAssertTrue(entries.isEmpty, "paused: no retry")
        await model.resumeAutoSwitch()
        XCTAssertFalse(model.state.autoSwitchPaused)
    }

    /// A link the organization id cannot prove is never used automatically.
    func testAnUnverifiedLinkIsUsedByHandOnly() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(orgB: nil), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.uuid, "acc-A")
        XCTAssertEqual(model.signIns.first { $0.id == "acc-B" }?.verified, false)
        XCTAssertEqual(model.cardState(for: idB), .canSwitch)
    }

    func testNoRoomIsToldOnceUntilUsageDropsAgain() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(b: 0.9), now: now)
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        await waitForPosts(1)
        XCTAssertEqual(bridge.posted.count, 1)
        XCTAssertEqual(model.state.status, .noRoom(at: now))
        model.usageDidChange(candidates(a: 0.1, b: 0.9), now: now)
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        await waitForPosts(2)
        XCTAssertEqual(bridge.posted.count, 2)
    }

    func testNotificationsOffStillShowTheStatus() async throws {
        let model = try await makeModel(auto: true, notify: false)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.status, .switched(at: now, from: "acc-A", to: "acc-B", automatic: true))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(bridge.posted.isEmpty)
    }

    /// Spec §4.2: removing a Ration account unlinks; only Forget deletes the copy.
    func testRemovingAnAccountUnlinksAndKeepsTheCopy() async throws {
        let model = try await makeModel()
        await model.accountRemoved(idB)
        XCTAssertNil(model.state.links["acc-B"])
        XCTAssertNotNil(store.signIn("acc-B"))
        XCTAssertEqual(model.cardState(for: idB), .none)
    }

    func testRememberingTheCurrentSignInLinksIt() async throws {
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("B")])
        let model = try await makeModel(links: ["acc-B": idB])
        XCTAssertEqual(model.rememberPrompt?.uuid, "acc-A")
        await model.rememberCurrent(linkTo: idA)
        XCTAssertNotNil(store.signIn("acc-A"))
        XCTAssertEqual(model.state.links["acc-A"], idA)
        XCTAssertNil(model.rememberPrompt)
    }

    func testTheRememberPromptCanBeDismissed() async throws {
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("B")])
        let model = try await makeModel(links: ["acc-B": idB])
        await model.dismissPrompt()
        XCTAssertNil(model.rememberPrompt)
    }

    func testLeavingAnUnrememberedSignInByHandIsRefusedWithAReason() async throws {
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("B")])
        let model = try await makeModel(links: ["acc-B": idB])
        await model.useInClaudeCode(accountID: idB)
        XCTAssertEqual(model.current?.uuid, "acc-A")
        guard case .leftAccountNotRemembered = model.lastError else { return XCTFail("\(String(describing: model.lastError))") }
    }

    func testStatusSurvivesARelaunch() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInClaudeCode(accountID: idB)
        let stateStore = JSONFileStore(fileURL: directory.appending(path: "claude-code-switch.json"), defaultValue: ClaudeCodeState())
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.status, .switched(at: now, from: "acc-A", to: "acc-B", automatic: false))
    }

    // MARK: Queued switches, pauses and sign-in links

    /// A queued automatic switch re-runs the rule before writing.
    func testAQueuedAutomaticSwitchRechecksTheRule() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        let entries = await log
        XCTAssertTrue(entries.isEmpty, "B filled up while the switch waited")
        XCTAssertEqual(model.current?.uuid, "acc-A")
        XCTAssertEqual(model.state.status, .noRoom(at: now))
    }

    /// A pause that cannot be saved turns automatic switching off.
    func testAPauseThatCannotBeSavedTurnsAutomaticSwitchingOff() async throws {
        var fired = false
        tool.afterWrite = { item in
            guard !fired else { return }
            fired = true
            var object = try! JSONSerialization.jsonObject(with: item!) as! [String: Any]
            object["mcpOAuth"] = ["server": ["token": "m9"]]
            item = try! JSONSerialization.data(withJSONObject: object)
        }
        let model = try await makeModel(auto: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertTrue(model.stateSaveFailed)
        XCTAssertFalse(model.state.autoSwitchEnabled, "fails closed")
    }

    /// A /login in Claude Code is not taken for a failed switch.
    func testALoginInClaudeCodeIsNotTakenForAFailure() async throws {
        let model = try await makeModel(auto: true)
        config.bytes = ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("B"))
        config.date = now
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.uuid, "acc-B")
        XCTAssertFalse(model.state.autoSwitchPaused)
        XCTAssertNil(model.state.status)
    }

    /// One sign-in per Ration account.
    func testOneSignInPerAccount() async throws {
        let model = try await makeModel()
        await model.link("acc-B", to: idA)
        XCTAssertEqual(model.state.links, ["acc-B": idA])
    }

    /// Editing the rule does not lift a pause; only turning it on does.
    func testEditingTheRuleKeepsAPause() async throws {
        let model = try await makeModel(auto: true, paused: true)
        await model.setAutoSwitch(enabled: true, rule: ClaudeCodeAutoSwitch.Rule(percent: 85, kind: .weekly))
        XCTAssertTrue(model.state.autoSwitchPaused, "a rule edit is not Resume")
        await model.setAutoSwitch(enabled: false, rule: model.state.rule)
        await model.setAutoSwitch(enabled: true, rule: model.state.rule)
        XCTAssertFalse(model.state.autoSwitchPaused, "turning it on again is")
    }

    /// A paused account is not a switch target by hand either.
    func testAPausedAccountCannotBeSwitchedTo() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1, pausedB: true), now: now)
        XCTAssertEqual(model.cardState(for: idB), .none)
        await model.useInClaudeCode(accountID: idB)
        XCTAssertEqual(model.current?.uuid, "acc-A")
    }

    /// "no room" shows again after a spell of "waiting".
    func testNoRoomShowsAgainAfterWaiting() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(b: 0.9), now: now)
        model.usageDidChange(candidates(b: 0.9, staleB: true), now: now)
        XCTAssertEqual(model.state.status, .waiting(at: now))
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.status, .noRoom(at: now))
        await waitForPosts(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(bridge.posted.count, 1, "told once")
    }

    /// Spec §4.2: an unlinked sign-in links itself when exactly one Claude
    /// account reports its organization (sign-ins remembered by earlier builds
    /// carry over unlinked).
    func testUnlinkedSignInsLinkThemselvesOnAnOrganizationMatch() async throws {
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links, ["acc-A": idA, "acc-B": idB])
        XCTAssertEqual(model.signIns.map(\.verified), [true, true])
    }

    func testNoSelfLinkWhenTwoAccountsShareTheOrganization() async throws {
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(a: 0.1, orgB: "org-A"), now: now)
        await model.waitUntilIdle()
        XCTAssertNil(model.state.links["acc-A"], "two accounts in org-A: the user chooses")
    }

    /// Team seats — two remembered sign-ins in one
    /// organization. The organization cannot tell which seat the one account
    /// reporting it is, so neither links itself.
    func testNoSelfLinkWhenTwoSignInsShareTheOrganization() async throws {
        func seat(_ id: String) -> ClaudeCodeSignIn {
            var account = ClaudeCodeConfigTests.account(id)
            account["organizationUuid"] = "org-B"
            return ClaudeCodeSignIn(account: ClaudeCodeConfig.account(from: account)!,
                                    login: ClaudeCodeKeychainEntry.canonical(["refreshToken": "refresh-\(id)"]),
                                    savedAt: now)
        }
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), seat("T1"), seat("T2")])
        let model = try await makeModel(links: ["acc-A": idA])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links, ["acc-A": idA], "two seats in org-B: the user chooses")
    }

    /// "None" in Settings sticks — across refreshes and a
    /// relaunch — until the user links the sign-in again.
    func testAnUnlinkChosenByTheUserIsKept() async throws {
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links["acc-B"], idB)

        await model.link("acc-B", to: nil)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertNil(model.state.links["acc-B"], "not linked again on the next refresh")

        let saved = try await JSONFileStore(fileURL: directory.appending(path: "claude-code-switch.json"),
                                            defaultValue: ClaudeCodeState()).load()
        XCTAssertEqual(saved.keptUnlinked, ["acc-B"], "the choice is on disk")
        let relaunched = try await makeModel(links: saved.links, keptUnlinked: saved.keptUnlinked)
        relaunched.usageDidChange(candidates(a: 0.1), now: now)
        await relaunched.waitUntilIdle()
        XCTAssertNil(relaunched.state.links["acc-B"], "nor after a relaunch")

        await relaunched.link("acc-B", to: idB)
        XCTAssertEqual(relaunched.state.links["acc-B"], idB)
        XCTAssertEqual(relaunched.state.keptUnlinked, [])
    }

    func testASelfLinkNeverTakesAnAccountAlreadyLinked() async throws {
        let model = try await makeModel(links: ["acc-B": idA])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links["acc-B"], idA, "the user's choice stays")
        XCTAssertNil(model.state.links["acc-A"], "idA is taken")
    }

    // MARK: Focus line

    private let idC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    /// Arguments are USED weekly fractions; nil is no snapshot.
    private func threeCandidates(b: Double?, c: Double?, pausedB: Bool = false, staleC: Bool = false,
                                 usableC: Bool = true) -> [ClaudeCodeCandidate] {
        func snap(_ used: Double?, org: String, stale: Bool = false) -> UsageSnapshot? {
            used.map {
                UsageSnapshot(accountID: UUID(), fetchedAt: stale ? now.addingTimeInterval(-(UsageEvidence.maxAge + 10)) : now,
                              fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: now.addingTimeInterval(3_600)),
                              weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(86_400)),
                              organizationID: org)
            }
        }
        return [
            ClaudeCodeCandidate(accountID: idA, label: "Work", organizationID: "org-A", isPaused: false, usable: true,
                                snapshot: snap(0.8, org: "org-A"), planUnits: 20, order: 0),
            ClaudeCodeCandidate(accountID: idB, label: "Personal", organizationID: "org-B", isPaused: pausedB, usable: true,
                                snapshot: snap(b, org: "org-B"), planUnits: 20, order: 1),
            ClaudeCodeCandidate(accountID: idC, label: "Spare", organizationID: "org-C", isPaused: false, usable: usableC,
                                snapshot: snap(c, org: "org-C", stale: staleC), planUnits: 5, order: 2),
        ]
    }

    private func makeThreeAccountModel() async throws -> ClaudeCodeModel {
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B"),
                                               ClaudeCodeSignInTests.signIn("C")])
        return try await makeModel(links: ["acc-A": idA, "acc-B": idB, "acc-C": idC])
    }

    func testTheFocusLineNamesClaudeCodesAccountAndTheOneWithTheMostRoom() async throws {
        let model = try await makeThreeAccountModel()
        model.usageDidChange(threeCandidates(b: 0.6, c: 0.2), now: now)
        XCTAssertEqual(model.focusLine(now: now),
                       ClaudeCodeFocusLine(currentLabel: "Work", target: .init(accountID: idC, label: "Spare")))
    }

    /// Room is the tightest considered limit: a nearly spent 5-hour window
    /// outweighs a roomy weekly one.
    func testTheFocusTargetIsRankedByItsTightestLimit() async throws {
        let model = try await makeThreeAccountModel()
        var pool = threeCandidates(b: 0.6, c: 0.2)
        let tight = pool[2].snapshot!
        pool[2] = ClaudeCodeCandidate(
            accountID: idC, label: "Spare", organizationID: "org-C", isPaused: false, usable: true,
            snapshot: UsageSnapshot(accountID: UUID(), fetchedAt: now,
                                    fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: now.addingTimeInterval(3_600)),
                                    weekly: tight.weekly, organizationID: "org-C"),
            planUnits: 5, order: 2)
        model.usageDidChange(pool, now: now)
        XCTAssertEqual(model.focusLine(now: now)?.target?.accountID, idB)
    }

    func testTheFocusLineOffersNoAccountThatCannotTakeOver() async throws {
        let model = try await makeThreeAccountModel()
        model.usageDidChange(threeCandidates(b: 0.3, c: 0.2, pausedB: true, staleC: true), now: now)
        XCTAssertEqual(model.focusLine(now: now), ClaudeCodeFocusLine(currentLabel: "Work", target: nil), "paused, stale")
        model.usageDidChange(threeCandidates(b: 1.0, c: nil), now: now)
        XCTAssertNil(model.focusLine(now: now)?.target, "spent, no usage yet")
        model.usageDidChange(threeCandidates(b: 1.0, c: 0.2, usableC: false), now: now)
        XCTAssertNil(model.focusLine(now: now)?.target, "waiting for a sign-in")
    }

    func testNoFocusLineUntilASignInIsRemembered() async throws {
        store = InMemoryClaudeCodeSignInStore([])
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(), now: now)
        XCTAssertNotNil(model.current)
        XCTAssertNil(model.focusLine(now: now))
    }

    /// Claude Code on an account Ration has not remembered: the line names its
    /// organization, as the popover status line does, and offers no switch —
    /// leaving an unremembered sign-in by hand is refused.
    func testTheFocusLineNamesAnUnrememberedSignInByItsOrganization() async throws {
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("B")])
        let model = try await makeModel(links: ["acc-B": idB])
        model.usageDidChange(candidates(), now: now)
        XCTAssertEqual(model.focusLine(now: now), ClaudeCodeFocusLine(currentLabel: "A's Organization", target: nil))
    }

    // MARK: Token burn hears every write (token burn spec §10.1)

    func testTokenBurnHearsBeforeAndAfterEverySwitchAttempt() async throws {
        let observer = FakeWriteObserver(config: config)
        let model = try await makeModel()
        model.writeObserver = observer
        model.usageDidChange(candidates(), now: now)
        await model.useInClaudeCode(accountID: idB)
        XCTAssertEqual(observer.events, ["will:acc-A", "did:acc-B"], "read before the write; the write's time after")

        config.failingWrites = [config.writeCount + 1]
        await model.useInClaudeCode(accountID: idA)
        XCTAssertEqual(observer.events.suffix(2), ["will:acc-B", "did:acc-B"], "a failed attempt is heard too")
    }

    /// Every `willWrite` gets its `didWrite`: launch recovery with no journal
    /// wrote nothing and says so with no time.
    func testLaunchWithNothingToRecoverEndsTheWriteWithoutATime() async throws {
        let observer = FakeWriteObserver(config: config)
        _ = try await makeModel(observer: observer)
        XCTAssertEqual(observer.events, ["will:acc-A", "none:acc-A"])
    }
}

@MainActor
final class FakeWriteObserver: ClaudeCodeWriteObserver {
    private let config: FakeClaudeCodeConfig
    private(set) var events: [String] = []
    init(config: FakeClaudeCodeConfig) { self.config = config }

    private var current: String {
        (try? config.readBytes()).flatMap { $0 }.flatMap { try? ClaudeCodeConfig.account(in: $0) }?.uuid ?? "none"
    }

    func claudeCodeWillWrite() async { events.append("will:\(current)") }
    func claudeCodeDidWrite(at date: Date?) async { events.append(date == nil ? "none:\(current)" : "did:\(current)") }
}

