import XCTest
@testable import Ration

/// `CodexModel` (spec §4): one operation at a time, the automatic rule under
/// the Codex window policy, links by the (account id, user id) pair, status
/// and notifications. Fakes only: no real `~/.codex`, Keychain or network.
@MainActor
final class CodexModelTests: XCTestCase {
    private static let loginA = "acct-A|user-1"
    private static let loginB = "acct-B|user-2"
    private static let loginC = "acct-C|user-3"
    private static let identityA = ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "a@example.com", planType: "pro")
    private static let identityB = ChatGPTIdentity(accountID: "acct-B", userID: "user-2", email: "b@example.com", planType: "plus")
    private static let identityC = ChatGPTIdentity(accountID: "acct-C", userID: "user-3", email: "c@example.com", planType: "plus")

    private static func bytes(_ account: String, _ user: String, email: String, refresh: String? = nil,
                              lastRefresh: String = "2026-10-11T18:00:00.000000Z") -> Data {
        CodexFixtures.authJSON(accountID: account, userID: user, email: email, lastRefresh: lastRefresh,
                               refreshToken: refresh ?? "rt-\(account)-\(user)")
    }

    private let aBytes = bytes("acct-A", "user-1", email: "a@example.com")
    private let bBytes = bytes("acct-B", "user-2", email: "b@example.com")
    private let cBytes = bytes("acct-C", "user-3", email: "c@example.com")
    /// Account B's id beside account A's refreshed tokens (spec §2).
    private let mixed = CodexFixtures.file(idToken: CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: "user-1")),
                                           tokensAccountID: "acct-B", refreshToken: "rt-A-2")

    private var file: FakeCodexLoginFile!
    private var store: InMemoryCodexSignInStore!
    private var journal: InMemoryCodexJournal!
    private var directory: URL!
    private var bridge: FakeAlertBridge!
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    /// The model's clock; tests move it.
    private var clock = Date(timeIntervalSince1970: 1_790_100_000)
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let idC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    override func setUp() async throws {
        clock = now
        file = FakeCodexLoginFile(bytes: aBytes)
        store = InMemoryCodexSignInStore([copy(aBytes), copy(bBytes)])
        journal = InMemoryCodexJournal()
        directory = try makeTempDirectory()
        bridge = FakeAlertBridge()
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: directory)
    }

    /// A remembered copy saved a day before `now` (usable: within 7 days).
    private func copy(_ bytes: Data, savedAt: Date? = nil) -> CodexSignIn {
        CodexSignIn(login: CodexFixtures.login(bytes), savedAt: savedAt ?? now.addingTimeInterval(-86_400))
    }

    private var stateStore: JSONFileStore<CodexState> {
        JSONFileStore(fileURL: directory.appending(path: "codex-switch.json"), defaultValue: CodexState())
    }

    private func makeModel(links: [String: UUID]? = nil, keptUnlinked: [String] = [], auto: Bool = false, notify: Bool = true,
                           paused: Bool = false, acknowledged: Bool = true, confirmDelay: TimeInterval = 0) async throws -> CodexModel {
        var state = CodexState()
        state.links = links ?? [Self.loginA: idA, Self.loginB: idB]
        state.keptUnlinked = keptUnlinked
        state.autoSwitchEnabled = auto
        state.autoSwitchPaused = paused
        state.notify = notify
        state.configurationAcknowledged = acknowledged
        try await stateStore.save(state)
        let model = makeUnstartedModel(confirmDelay: confirmDelay)
        await model.start()
        return model
    }

    /// The model before `start()`: its state file not loaded yet.
    private func makeUnstartedModel(confirmDelay: TimeInterval = 0) -> CodexModel {
        let fixed = now
        let model = CodexModel(dependencies: .init(
            switcher: CodexSwitcher(file: file, store: store, journal: journal, now: { fixed }, confirmDelay: confirmDelay, retryDelay: 0),
            stateStore: stateStore,
            logStore: JSONFileStore(fileURL: directory.appending(path: CodexSwitchLogEntry.fileName), defaultValue: [])
        ), now: { [unowned self] in self.clock })
        model.bridge = bridge
        return model
    }

    private func snap(_ used: Double?, identity: ChatGPTIdentity?, stale: Bool = false, fiveHour: Double? = 0.9) -> UsageSnapshot? {
        used.map {
            UsageSnapshot(accountID: UUID(), fetchedAt: stale ? now.addingTimeInterval(-(UsageEvidence.maxAge + 10)) : now,
                          fiveHour: fiveHour.map { UsageWindow(kind: .fiveHour, remainingFraction: $0, resetsAt: now.addingTimeInterval(3_600)) },
                          weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(86_400)),
                          chatGPTIdentity: identity)
        }
    }

    /// Arguments are USED weekly fractions.
    private func candidates(a: Double = 0.8, b: Double? = 0.1, identityA: ChatGPTIdentity? = identityA,
                            identityB: ChatGPTIdentity? = identityB, staleB: Bool = false, pausedB: Bool = false,
                            fiveHour: Double? = 0.9) -> [CodexCandidate] {
        [
            CodexCandidate(accountID: idA, label: "Work", identity: identityA, isPaused: false, usable: true,
                           snapshot: snap(a, identity: identityA, fiveHour: fiveHour), planUnits: 20, order: 0),
            CodexCandidate(accountID: idB, label: "Personal", identity: identityB, isPaused: pausedB, usable: true,
                           snapshot: snap(b, identity: identityB, stale: staleB, fiveHour: fiveHour), planUnits: 20, order: 1),
        ]
    }

    private func waitForPosts(_ count: Int) async {
        for _ in 0..<200 where bridge.posted.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private var log: [CodexSwitchLogEntry] {
        get async { (try? await JSONFileStore<[CodexSwitchLogEntry]>(fileURL: directory.appending(path: CodexSwitchLogEntry.fileName), defaultValue: []).load()) ?? [] }
    }

    /// Codex wrote its file (a login, a refresh): the next pass reads it again.
    private func codexWrites(_ bytes: Data?) {
        file.bytes = bytes
        file.modification = (file.modification ?? now).addingTimeInterval(1)
    }

    // MARK: Mirrors of the Claude Code model

    func testStartReadsTheCurrentLoginAndTheRememberedSignIns() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.current?.id, Self.loginA)
        model.usageDidChange(candidates(), now: now)
        XCTAssertEqual(model.signIns.map(\.id), [Self.loginA, Self.loginB])
        XCTAssertEqual(model.signIns.map(\.verified), [true, true])
        XCTAssertEqual(model.signIns.map(\.validityUnknown), [false, false])
        XCTAssertEqual(model.cardState(for: idA), .current)
        XCTAssertEqual(model.cardState(for: idB), .canSwitch(sameWorkspace: false))
        XCTAssertEqual(model.cardState(for: UUID()), .none)
    }

    func testAManualSwitchUpdatesStatusAndLogButDoesNotNotify() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB)
        XCTAssertEqual(file.writes, [bBytes])
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: false))
        let entries = await log
        XCTAssertEqual(entries.map(\.to), [Self.loginB])
        XCTAssertEqual(entries.first?.automatic, false)
        XCTAssertTrue(bridge.posted.isEmpty)
    }

    /// Codex refreshed the target between Ration's write and its
    /// read-back. A switch, but not with Ration's bytes: the status keeps it.
    func testAnUnverifiedSwitchIsReportedAsSuch() async throws {
        let refreshed = Self.bytes("acct-B", "user-2", email: "b@example.com", refresh: "rt-B-2",
                                   lastRefresh: "2026-10-11T19:00:00.000000Z")
        file.afterWrite = { attempt, stored in if attempt == 1 { stored = refreshed } }
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB)
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: false, verified: false))
        XCTAssertNil(model.lastError)
    }

    /// Five refreshes over the threshold → one switch.
    func testRepeatedRefreshesStartOneSwitch() async throws {
        let model = try await makeModel(auto: true)
        for _ in 0..<5 { model.usageDidChange(candidates(), now: now) }
        await model.waitUntilIdle()
        let entries = await log
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.rule, ClaudeCodeAutoSwitch.Rule())
        XCTAssertEqual(model.current?.id, Self.loginB)
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: true))
        await waitForPosts(1)
        XCTAssertEqual(bridge.posted, ["codex.switched.\(Int(now.timeIntervalSince1970))"])
    }

    /// A click during an automatic switch waits for it.
    func testAClickDuringAnAutomaticSwitchDoesNotSwitchTwice() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        await model.useInCodex(accountID: idB)
        await model.waitUntilIdle()
        let entries = await log
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(model.current?.id, Self.loginB)
    }

    /// An external `codex login` lands during the write: never overwritten,
    /// automatic switching paused until Resume.
    func testAConflictPausesAutomaticSwitchingUntilResumed() async throws {
        let third = cBytes
        file.afterWrite = { attempt, stored in if attempt == 1 { stored = third } }
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertTrue(model.state.autoSwitchPaused)
        XCTAssertEqual(model.state.status, .conflict(at: now))
        XCTAssertEqual(model.lastError, .conflict)
        XCTAssertEqual(model.current?.id, Self.loginC, "the third login is left as is")
        await waitForPosts(1)
        XCTAssertEqual(bridge.posted, ["codex.failed.\(Int(now.timeIntervalSince1970))"], "the failure is notified")

        codexWrites(aBytes)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginA)
        let entries = await log
        XCTAssertTrue(entries.isEmpty, "paused: no retry")
        await model.resumeAutoSwitch()
        XCTAssertFalse(model.state.autoSwitchPaused)
        XCTAssertNil(model.state.status)
    }

    /// A link the identity cannot prove is never used automatically.
    func testAnUnverifiedLinkIsUsedByHandOnly() async throws {
        let model = try await makeModel(auto: true)
        let otherSeat = ChatGPTIdentity(accountID: "acct-B", userID: "user-9", email: "b9@example.com", planType: "plus")
        model.usageDidChange(candidates(identityB: otherSeat), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertEqual(model.signIns.first { $0.id == Self.loginB }?.verified, false)
        XCTAssertEqual(model.cardState(for: idB), .canSwitch(sameWorkspace: false))
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB, "by hand it switches")
    }

    func testNoRoomIsToldOnceUntilUsageDropsAgain() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(b: 0.9), now: now)
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        await waitForPosts(1)
        XCTAssertEqual(bridge.posted, ["codex.noRoom.\(Self.loginB)"])
        XCTAssertEqual(model.state.status, .noRoom(at: now))
        model.usageDidChange(candidates(a: 0.1, b: 0.9), now: now)
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        await waitForPosts(2)
        XCTAssertEqual(bridge.posted.count, 2)
    }

    /// With details hidden, each notification still says what
    /// happened — a failure or no room is never announced as a switch.
    func testRedactedNotificationsSayWhatHappened() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(b: 0.9), now: now)
        await model.waitUntilIdle()
        await waitForPosts(1)

        file.afterWrite = { [cBytes] attempt, stored in if attempt == 1 { stored = cBytes } }
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        await waitForPosts(2)

        let redacted = Dictionary(uniqueKeysWithValues: bridge.decisions.flatMap(\.posts).map { ($0.id, $0.render(true)) })
        let noRoom = try XCTUnwrap(redacted["codex.noRoom.\(Self.loginB)"])
        XCTAssertEqual(noRoom.body, LocalizedStringResource.codexNotificationRedactedNoRoom.string(in: .current))
        let failed = try XCTUnwrap(redacted["codex.failed.\(Int(now.timeIntervalSince1970))"])
        XCTAssertEqual(failed.body, LocalizedStringResource.codexNotificationRedactedFailed.string(in: .current))
        XCTAssertNotEqual(failed.body, LocalizedStringResource.codexNotificationRedactedBody.string(in: .current))
        XCTAssertEqual(noRoom.title, "Ration")
        XCTAssertEqual(failed.title, "Ration")
    }

    /// The switched notification keeps its own redacted body.
    func testTheRedactedSwitchNotificationSaysCodexSwitched() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        await waitForPosts(1)
        let post = try XCTUnwrap(bridge.decisions.flatMap(\.posts).first)
        XCTAssertEqual(post.render(true).body, LocalizedStringResource.codexNotificationRedactedBody.string(in: .current))
    }

    func testNotificationsOffStillShowTheStatus() async throws {
        let model = try await makeModel(auto: true, notify: false)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: true))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(bridge.posted.isEmpty)
    }

    /// Spec §4.2: removing a Ration account unlinks; only Forget deletes the copy.
    func testRemovingAnAccountUnlinksAndKeepsTheCopy() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.accountRemoved(idB)
        XCTAssertNil(model.state.links[Self.loginB])
        XCTAssertNotNil(store.items[Self.loginB])
        XCTAssertEqual(model.cardState(for: idB), .none)
    }

    /// Forget all deletes every copy Ration keeps — also one it
    /// cannot read, which never made it into the list.
    func testForgetAllDeletesEveryCopyEvenOnesItCannotRead() async throws {
        store = InMemoryCodexSignInStore([copy(aBytes), copy(bBytes), copy(cBytes)])
        store.unreadableIDs = [Self.loginC]
        let model = try await makeModel()
        XCTAssertEqual(model.remembered, [], "the listing failed")
        await model.forgetAll()
        XCTAssertTrue(store.items.isEmpty, "no copy left behind")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.state.links, [:])
    }

    func testRememberingTheCurrentSignInLinksIt() async throws {
        store = InMemoryCodexSignInStore([copy(bBytes)])
        let model = try await makeModel(links: [Self.loginB: idB])
        XCTAssertEqual(model.rememberPrompt?.id, Self.loginA)
        await model.rememberCurrent(linkTo: idA)
        XCTAssertEqual(store.items[Self.loginA]?.login.bytes, aBytes)
        XCTAssertEqual(model.state.links[Self.loginA], idA)
        XCTAssertNil(model.rememberPrompt)
    }

    /// Settings' Remember again on the remembered current login —
    /// a link the user chose, a stale mark, a copy past 7 days — renews the
    /// copy and clears the mark, keeping the link it has.
    func testRememberingTheCurrentSignInAgainKeepsItsLink() async throws {
        store = InMemoryCodexSignInStore([copy(aBytes, savedAt: now.addingTimeInterval(-8 * 86_400)), copy(bBytes)])
        var saved = CodexState()
        saved.links = [Self.loginA: idA, Self.loginB: idB]
        saved.staleLogins = [Self.loginA]
        try await stateStore.save(saved)
        let model = makeUnstartedModel()
        await model.start()
        model.usageDidChange(candidates(a: 0.1, identityA: nil), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.signIns.first { $0.id == Self.loginA }?.verified, false, "premise: a link the user chose")
        XCTAssertEqual(model.signIns.first { $0.id == Self.loginA }?.validityUnknown, true)

        await model.rememberCurrent(linkTo: model.state.links[Self.loginA])
        XCTAssertEqual(model.state.links, [Self.loginA: idA, Self.loginB: idB])
        XCTAssertEqual(model.state.staleLogins, [])
        XCTAssertEqual(model.signIns.first { $0.id == Self.loginA }?.validityUnknown, false)
        XCTAssertEqual(store.items[Self.loginA]?.savedAt, now)
        let after = try await stateStore.load()
        XCTAssertEqual(after.staleLogins, [])
        XCTAssertEqual(after.links, [Self.loginA: idA, Self.loginB: idB])
    }

    func testTheRememberPromptCanBeDismissed() async throws {
        store = InMemoryCodexSignInStore([copy(bBytes)])
        let model = try await makeModel(links: [Self.loginB: idB])
        await model.dismissPrompt()
        XCTAssertNil(model.rememberPrompt)
        XCTAssertEqual(model.state.dismissedPrompts, [Self.loginA])
    }

    func testLeavingAnUnrememberedSignInByHandIsRefusedWithAReason() async throws {
        store = InMemoryCodexSignInStore([copy(bBytes)])
        let model = try await makeModel(links: [Self.loginB: idB])
        model.usageDidChange(candidates(), now: now)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertEqual(file.writes, [])
        guard case .leftAccountNotRemembered = model.lastError else { return XCTFail("\(String(describing: model.lastError))") }
    }

    func testStatusSurvivesARelaunch() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: false))
    }

    /// AppModel starts — and emits snapshots — before
    /// `start()` has loaded `codex-switch.json`. Until it has, nothing links,
    /// decides or persists over the saved state; the latest candidates are
    /// replayed once it is loaded.
    func testCandidatesBeforeStartNeverOverwriteTheSavedState() async throws {
        var saved = CodexState()
        saved.rule = ClaudeCodeAutoSwitch.Rule(percent: 60, kind: .weekly)
        saved.configurationAcknowledged = true
        saved.notify = false
        try await stateStore.save(saved)
        file.modification = now
        let model = makeUnstartedModel()

        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        let before = try await stateStore.load()
        XCTAssertEqual(before, saved, "nothing written before start()")
        XCTAssertTrue(model.state.links.isEmpty, "nothing linked before start()")

        await model.start()
        await model.waitUntilIdle()
        let after = try await stateStore.load()
        XCTAssertEqual(after.rule, ClaudeCodeAutoSwitch.Rule(percent: 60, kind: .weekly))
        XCTAssertTrue(after.configurationAcknowledged)
        XCTAssertFalse(after.notify)
        XCTAssertEqual(after.links, [Self.loginA: idA, Self.loginB: idB], "the replayed candidates linked the logins")
        XCTAssertEqual(model.state, after)
        XCTAssertEqual(model.candidates.map(\.accountID), [idA, idB], "replayed")
    }

    /// Before `start()` no action changes anything: the saved state is not loaded.
    func testNoActionPersistsBeforeStart() async throws {
        var saved = CodexState()
        saved.links = [Self.loginA: idA, Self.loginB: idB]
        saved.notify = false
        try await stateStore.save(saved)
        let model = makeUnstartedModel()
        await model.setNotify(true)
        await model.link(Self.loginB, to: nil)
        await model.useInCodex(accountID: idB)
        await model.forgetAll()
        let after = try await stateStore.load()
        XCTAssertEqual(after, saved)
        XCTAssertEqual(store.items.count, 2, "nothing forgotten")
        XCTAssertEqual(file.writes, [], "nothing switched")
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
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertEqual(model.state.status, .noRoom(at: now))
    }

    // MARK: Re-checked after the stability delay

    /// The stability check's first read of the next switch runs `change` on
    /// the main actor, inside the delay (Codex's file stays as it is).
    private func duringTheNextConfirm(_ change: @escaping @MainActor () async -> Void) {
        let first = file.readCount + 1
        file.afterRead = { count, _ in
            guard count == first else { return }
            Task { @MainActor in await change() }
        }
    }

    /// Spec §4.5: the decision is re-made after the 2 s stability check.
    /// Usage back below the threshold meanwhile: no write, no status, no pause.
    func testUsageBackBelowTheThresholdDuringTheConfirmAbortsTheAutomaticSwitch() async throws {
        let model = try await makeModel(auto: true, confirmDelay: 0.3)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        let below = candidates(a: 0.1)
        let date = now
        duringTheNextConfirm { model.usageDidChange(below, now: date) }

        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertNil(model.state.status)
        XCTAssertFalse(model.state.autoSwitchPaused)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.switchingTo)
        let entries = await log
        XCTAssertTrue(entries.isEmpty)
    }

    /// Automatic switching turned off during the stability check: no write.
    func testAutomaticSwitchingTurnedOffDuringTheConfirmAbortsTheSwitch() async throws {
        let model = try await makeModel(auto: true, confirmDelay: 0.3)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        duringTheNextConfirm { await model.setAutoSwitch(enabled: false, rule: model.state.rule) }

        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertNil(model.state.status)
    }

    /// By hand too: the target account paused during the stability check.
    func testATargetPausedDuringTheConfirmAbortsAManualSwitch() async throws {
        let model = try await makeModel(confirmDelay: 0.3)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        let paused = candidates(a: 0.1, pausedB: true)
        let date = now
        duringTheNextConfirm { model.usageDidChange(paused, now: date) }

        await model.useInCodex(accountID: idB)
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertNil(model.state.status)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.switchingTo)
    }

    /// Nothing changed during the stability check: the switch goes through,
    /// with no second check.
    func testAnUnchangedDecisionAfterTheConfirmSwitches() async throws {
        let model = try await makeModel(auto: true, confirmDelay: 0.3)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        let readsBefore = file.readCount
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(file.writes, [bBytes])
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: true))
        XCTAssertEqual(file.readCount - readsBefore, 5, "one stability check (2), the compare, the read-back, the reload")
    }

    /// A pause that cannot be saved turns automatic switching off.
    func testAPauseThatCannotBeSavedTurnsAutomaticSwitchingOff() async throws {
        let third = cBytes
        file.afterWrite = { attempt, stored in if attempt == 1 { stored = third } }
        let model = try await makeModel(auto: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertTrue(model.stateSaveFailed)
        XCTAssertFalse(model.state.autoSwitchEnabled, "fails closed")
    }

    /// Any state save that fails blocks automatic switching — the
    /// file no longer says what the model does — until the user turns it on
    /// again and that save succeeds ("Try turning it on again").
    func testAFailedSaveBlocksAutomaticSwitchingUntilTurnedOnAgain() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        let path = directory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        await model.link(Self.loginB, to: idB)
        XCTAssertTrue(model.stateSaveFailed)

        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(file.writes, [], "blocked")
        XCTAssertEqual(model.current?.id, Self.loginA)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        await model.setNotify(true)
        XCTAssertTrue(model.stateSaveFailed, "another save is not the user turning it on again")
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(file.writes, [])

        await model.setAutoSwitch(enabled: true, rule: model.state.rule)
        XCTAssertFalse(model.stateSaveFailed)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(file.writes, [bBytes])
    }

    /// A `codex login` to another account is not taken for a failed switch.
    func testALoginInCodexIsNotTakenForAFailure() async throws {
        let model = try await makeModel(auto: true)
        codexWrites(bBytes)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginB)
        XCTAssertFalse(model.state.autoSwitchPaused)
        XCTAssertNil(model.state.status)
        XCTAssertEqual(file.writes, [])
    }

    /// One sign-in per Ration account.
    func testOneSignInPerAccount() async throws {
        let model = try await makeModel()
        await model.link(Self.loginB, to: idA)
        XCTAssertEqual(model.state.links, [Self.loginB: idA])
    }

    /// Editing the rule does not lift a pause; only turning it on does.
    func testEditingTheRuleKeepsAPause() async throws {
        let model = try await makeModel(auto: true, paused: true)
        await model.setAutoSwitch(enabled: true, rule: ClaudeCodeAutoSwitch.Rule(percent: 85, kind: .weekly))
        XCTAssertTrue(model.state.autoSwitchPaused, "a rule edit is not Resume")
        XCTAssertEqual(model.state.rule.percent, 85)
        await model.setAutoSwitch(enabled: false, rule: model.state.rule)
        await model.setAutoSwitch(enabled: true, rule: model.state.rule)
        XCTAssertFalse(model.state.autoSwitchPaused, "turning it on again is")
    }

    /// A paused account is not a switch target by hand either.
    func testAPausedAccountCannotBeSwitchedTo() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1, pausedB: true), now: now)
        XCTAssertEqual(model.cardState(for: idB), .none)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginA)
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

    /// Spec §4.2: an unlinked login links itself when exactly one ChatGPT
    /// account's session reports its (account id, user id).
    func testUnlinkedSignInsLinkThemselvesOnAnIdentityMatch() async throws {
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links, [Self.loginA: idA, Self.loginB: idB])
        XCTAssertEqual(model.signIns.map(\.verified), [true, true])
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.links, [Self.loginA: idA, Self.loginB: idB], "persisted")
    }

    /// The same ChatGPT login added to Ration twice: the user chooses.
    func testNoSelfLinkWhenTwoAccountsReportTheSameIdentity() async throws {
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(a: 0.1, identityB: Self.identityA), now: now)
        await model.waitUntilIdle()
        XCTAssertNil(model.state.links[Self.loginA], "two accounts report A: the user chooses")
    }

    /// "None" in Settings sticks — across refreshes and a relaunch — until
    /// the user links the login again.
    func testAnUnlinkChosenByTheUserIsKept() async throws {
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links[Self.loginB], idB)

        await model.link(Self.loginB, to: nil)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertNil(model.state.links[Self.loginB], "not linked again on the next refresh")

        let saved = try await stateStore.load()
        XCTAssertEqual(saved.keptUnlinked, [Self.loginB], "the choice is on disk")
        let relaunched = try await makeModel(links: saved.links, keptUnlinked: saved.keptUnlinked)
        relaunched.usageDidChange(candidates(a: 0.1), now: now)
        await relaunched.waitUntilIdle()
        XCTAssertNil(relaunched.state.links[Self.loginB], "nor after a relaunch")

        await relaunched.link(Self.loginB, to: idB)
        XCTAssertEqual(relaunched.state.links[Self.loginB], idB)
        XCTAssertEqual(relaunched.state.keptUnlinked, [])
    }

    func testASelfLinkNeverTakesAnAccountAlreadyLinked() async throws {
        let model = try await makeModel(links: [Self.loginB: idA])
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links[Self.loginB], idA, "the user's choice stays")
        XCTAssertNil(model.state.links[Self.loginA], "idA is taken")
    }

    /// Kept fresh (spec §4.1): Codex renewed the current login's tokens; the
    /// remembered copy follows, at most every `copyRefreshInterval`.
    func testTheCurrentLoginsCopyIsKeptFresh() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(store.saves.count, 0, "unchanged: nothing saved")

        let renewed = Self.bytes("acct-A", "user-1", email: "a@example.com", refresh: "rt-A-2", lastRefresh: "2026-10-11T19:00:00.000000Z")
        file.bytes = renewed
        model.usageDidChange(candidates(a: 0.1), now: now.addingTimeInterval(60))
        await model.waitUntilIdle()
        XCTAssertEqual(store.saves.count, 0, "within the interval")

        model.usageDidChange(candidates(a: 0.1), now: now.addingTimeInterval(CodexModel.copyRefreshInterval))
        await model.waitUntilIdle()
        XCTAssertEqual(store.items[Self.loginA]?.login.bytes, renewed)
        XCTAssertEqual(model.remembered.first { $0.id == Self.loginA }?.login.bytes, renewed)
    }

    // MARK: Focus line

    /// Arguments are USED weekly fractions; nil is no snapshot.
    private func threeCandidates(b: Double?, c: Double?, pausedB: Bool = false, staleC: Bool = false,
                                 usableC: Bool = true, fiveHourC: Double? = 0.9) -> [CodexCandidate] {
        [
            CodexCandidate(accountID: idA, label: "Work", identity: Self.identityA, isPaused: false, usable: true,
                           snapshot: snap(0.8, identity: Self.identityA), planUnits: 20, order: 0),
            CodexCandidate(accountID: idB, label: "Personal", identity: Self.identityB, isPaused: pausedB, usable: true,
                           snapshot: snap(b, identity: Self.identityB), planUnits: 20, order: 1),
            CodexCandidate(accountID: idC, label: "Spare", identity: Self.identityC, isPaused: false, usable: usableC,
                           snapshot: snap(c, identity: Self.identityC, stale: staleC, fiveHour: fiveHourC), planUnits: 5, order: 2),
        ]
    }

    private func makeThreeAccountModel() async throws -> CodexModel {
        store = InMemoryCodexSignInStore([copy(aBytes), copy(bBytes), copy(cBytes)])
        return try await makeModel(links: [Self.loginA: idA, Self.loginB: idB, Self.loginC: idC])
    }

    func testTheFocusLineNamesCodexsAccountAndTheOneWithTheMostRoom() async throws {
        let model = try await makeThreeAccountModel()
        model.usageDidChange(threeCandidates(b: 0.6, c: 0.2), now: now)
        XCTAssertEqual(model.focusLine(now: now), CodexFocusLine(currentLabel: "Work", target: .init(accountID: idC, label: "Spare")))
    }

    /// Room is the tightest window reported: a nearly spent 5-hour window
    /// outweighs a roomy weekly one.
    func testTheFocusTargetIsRankedByItsTightestLimit() async throws {
        let model = try await makeThreeAccountModel()
        model.usageDidChange(threeCandidates(b: 0.6, c: 0.2, fiveHourC: 0.05), now: now)
        XCTAssertEqual(model.focusLine(now: now)?.target?.accountID, idB)
    }

    /// ChatGPT often reports only a weekly limit: that is enough (Codex policy).
    func testAWeeklyOnlyAccountIsAFocusTarget() async throws {
        let model = try await makeThreeAccountModel()
        model.usageDidChange(threeCandidates(b: 0.6, c: 0.2, fiveHourC: nil), now: now)
        XCTAssertEqual(model.focusLine(now: now)?.target?.accountID, idC)
    }

    /// A 5-hour window reported but unreadable is unknown for Focus
    /// as for the rule.
    func testAnUnreadableFiveHourWindowIsNoFocusTarget() async throws {
        let model = try await makeThreeAccountModel()
        var pool = threeCandidates(b: 0.6, c: 0.2, fiveHourC: nil)
        let spare = pool[2]
        let snapshot = try XCTUnwrap(spare.snapshot)
        pool[2] = CodexCandidate(accountID: spare.accountID, label: spare.label, identity: spare.identity, isPaused: false, usable: true,
                                 snapshot: UsageSnapshot(accountID: snapshot.accountID, fetchedAt: snapshot.fetchedAt, fiveHour: nil,
                                                         weekly: snapshot.weekly, chatGPTIdentity: snapshot.chatGPTIdentity,
                                                         unreadableWindowKinds: [.fiveHour]),
                                 planUnits: spare.planUnits, order: spare.order)
        model.usageDidChange(pool, now: now)
        XCTAssertEqual(model.focusLine(now: now)?.target?.accountID, idB, "not the account whose 5-hour window is unreadable")
    }

    func testTheFocusLineOffersNoAccountThatCannotTakeOver() async throws {
        let model = try await makeThreeAccountModel()
        model.usageDidChange(threeCandidates(b: 0.3, c: 0.2, pausedB: true, staleC: true), now: now)
        XCTAssertEqual(model.focusLine(now: now), CodexFocusLine(currentLabel: "Work", target: nil), "paused, stale")
        model.usageDidChange(threeCandidates(b: 1.0, c: nil), now: now)
        XCTAssertNil(model.focusLine(now: now)?.target, "spent, no usage yet")
        model.usageDidChange(threeCandidates(b: 1.0, c: 0.2, usableC: false), now: now)
        XCTAssertNil(model.focusLine(now: now)?.target, "waiting for a sign-in")
    }

    func testNoFocusLineUntilASignInIsRemembered() async throws {
        store = InMemoryCodexSignInStore([])
        let model = try await makeModel(links: [:])
        model.usageDidChange(candidates(), now: now)
        XCTAssertNotNil(model.current)
        XCTAssertNil(model.focusLine(now: now))
    }

    /// Codex on a login Ration has not remembered: the line names its email,
    /// as the popover status line does, and offers no switch — leaving an
    /// unremembered login by hand is refused.
    func testTheFocusLineNamesAnUnrememberedSignInByItsEmail() async throws {
        store = InMemoryCodexSignInStore([copy(bBytes)])
        let model = try await makeModel(links: [Self.loginB: idB])
        model.usageDidChange(candidates(), now: now)
        XCTAssertEqual(model.focusLine(now: now), CodexFocusLine(currentLabel: "a@example.com", target: nil))
        XCTAssertEqual(model.displayLabel(forSignIn: Self.loginB), "Personal")
        XCTAssertEqual(model.displayLabel(forSignIn: "acct-Z|user-0"), "acct-Z|user-0")
    }

    // MARK: Codex specifics

    /// Two seats of one Team workspace share the account id;
    /// the user id tells them apart, so each links to its own card.
    func testTwoSeatsOfOneWorkspaceLinkByUserID() async throws {
        let seat1 = Self.bytes("acct-X", "user-1", email: "one@example.com")
        let seat2 = Self.bytes("acct-X", "user-2", email: "two@example.com")
        file.bytes = seat1
        store = InMemoryCodexSignInStore([copy(seat1), copy(seat2)])
        let model = try await makeModel(links: [:])
        let one = ChatGPTIdentity(accountID: "acct-X", userID: "user-1", email: "one@example.com", planType: "team")
        let two = ChatGPTIdentity(accountID: "acct-X", userID: "user-2", email: "two@example.com", planType: "team")
        model.usageDidChange([
            CodexCandidate(accountID: idA, label: "Seat one", identity: one, isPaused: false, usable: true,
                           snapshot: snap(0.1, identity: one), planUnits: 20, order: 0),
            CodexCandidate(accountID: idB, label: "Seat two", identity: two, isPaused: false, usable: true,
                           snapshot: snap(0.1, identity: two), planUnits: 20, order: 1),
        ], now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.state.links, ["acct-X|user-1": idA, "acct-X|user-2": idB])
        XCTAssertEqual(model.signIns.map(\.verified), [true, true])
        XCTAssertEqual(model.cardState(for: idA), .current)
        XCTAssertEqual(model.cardState(for: idB), .canSwitch(sameWorkspace: true), "another seat of the same workspace")
    }

    /// An account whose web session reports no identity (signed
    /// out, or not fetched since launch) shows no Codex control and is never
    /// used — nor left — automatically.
    func testAnAccountWithoutIdentityIsNeverVerified() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(identityB: nil), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.signIns.first { $0.id == Self.loginB }?.verified, false)
        XCTAssertEqual(model.cardState(for: idB), .none, "no SWITCH")
        XCTAssertNil(model.focusLine(now: now)?.target)
        XCTAssertEqual(model.current?.id, Self.loginA, "never a target")
        XCTAssertEqual(file.writes, [])

        model.usageDidChange(candidates(identityA: nil), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.cardState(for: idA), .none, "no CODEX tag")
        XCTAssertEqual(model.signIns.first { $0.id == Self.loginA }?.verified, false)
        XCTAssertEqual(model.current?.id, Self.loginA, "an unverified current account is never left automatically")
        XCTAssertEqual(file.writes, [])

        // No identity, no automatic link either.
        let unlinked = try await makeModel(links: [:])
        unlinked.usageDidChange(candidates(a: 0.1, identityB: nil), now: now)
        await unlinked.waitUntilIdle()
        XCTAssertNil(unlinked.state.links[Self.loginB])
    }

    /// Codex on another login (or signed out) within 10
    /// minutes of Ration's switch means the switched-to copy is probably dead.
    func testACodexLoginChangeRightAfterASwitchIsReportedAsStale() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.state.lastSwitchTo, Self.loginB)
        XCTAssertEqual(model.state.lastSwitchAt, now)

        clock = now.addingTimeInterval(5 * 60)
        codexWrites(aBytes)
        await model.reload()
        XCTAssertEqual(model.state.status, .stale(at: clock, login: Self.loginB))
        XCTAssertNil(model.state.lastSwitchTo)
        XCTAssertNil(model.state.lastSwitchAt)
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.status, .stale(at: clock, login: Self.loginB), "persisted")

        // Signed out counts too.
        clock = now
        await model.useInCodex(accountID: idB)
        clock = now.addingTimeInterval(60)
        codexWrites(nil)
        await model.reload()
        XCTAssertEqual(model.state.status, .stale(at: clock, login: Self.loginB))

        // A half-written file is not a change of login.
        codexWrites(aBytes)
        clock = now
        await model.useInCodex(accountID: idB)
        file.unreadableReads = 2
        clock = now.addingTimeInterval(60)
        await model.reload()
        XCTAssertEqual(model.current?.id, Self.loginB, "unreadable: the last login stays")
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: false))
        XCTAssertEqual(model.state.lastSwitchTo, Self.loginB)

        // Later than 10 minutes: not stale; the pair is cleared.
        clock = now.addingTimeInterval(11 * 60)
        codexWrites(aBytes)
        await model.reload()
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: false))
        XCTAssertNil(model.state.lastSwitchTo)
    }

    /// A copy found stale is kept out of automatic switching and
    /// the Focus line — even after Resume — and automatic switching pauses.
    /// By hand it can still be tried.
    func testAStaleCopyIsNeverAnAutomaticOrFocusTarget() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        clock = now.addingTimeInterval(5 * 60)
        codexWrites(aBytes)
        await model.reload()
        XCTAssertEqual(model.state.staleLogins, [Self.loginB])
        XCTAssertTrue(model.state.autoSwitchPaused)
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.staleLogins, [Self.loginB], "persisted")
        XCTAssertTrue(saved.autoSwitchPaused)

        await model.resumeAutoSwitch()
        XCTAssertFalse(model.state.autoSwitchPaused)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertEqual(file.writes, [bBytes], "only the switch by hand")
        XCTAssertNil(model.focusLine(now: now)?.target, "no SWITCH TO a stale copy")
        XCTAssertEqual(model.cardState(for: idB), .canSwitch(sameWorkspace: false), "the card still offers it by hand")

        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB, "by hand it switches")
    }

    /// Remember again (a fresh copy) clears the stale mark.
    func testRememberingAStaleLoginAgainClearsIt() async throws {
        let model = try await makeModel()
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        clock = now.addingTimeInterval(5 * 60)
        codexWrites(aBytes)
        await model.reload()
        XCTAssertEqual(model.state.staleLogins, [Self.loginB])

        // The user signs in to B in Codex, then remembers it again.
        codexWrites(Self.bytes("acct-B", "user-2", email: "b@example.com", refresh: "rt-B-2",
                               lastRefresh: "2026-10-11T19:00:00.000000Z"))
        await model.rememberCurrent(linkTo: idB)
        XCTAssertEqual(model.state.staleLogins, [])
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.staleLogins, [])
    }

    /// ChatGPT often reports only a weekly limit: the rule still switches.
    func testAutomaticSwitchingUsesTheCodexPolicy() async throws {
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(fiveHour: nil), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginB)
        XCTAssertEqual(model.state.status, .switched(at: now, from: Self.loginA, to: Self.loginB, automatic: true))
    }

    /// Installed is not usable (spec §4.2): a copy not re-saved for 7 days may
    /// hold a dead refresh token. By hand only.
    func testACopyOlderThanSevenDaysIsNeverAnAutomaticTarget() async throws {
        store = InMemoryCodexSignInStore([copy(aBytes), copy(bBytes, savedAt: now.addingTimeInterval(-8 * 86_400))])
        let model = try await makeModel(auto: true)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.signIns.map(\.validityUnknown), [false, true])
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(model.state.status, .noRoom(at: now))

        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB, "by hand it switches")
    }

    /// A running session may follow a seat change, so another seat of the
    /// current workspace is manual only.
    func testAnotherSeatOfTheSameWorkspaceIsNeverAnAutomaticTarget() async throws {
        let seat1 = Self.bytes("acct-X", "user-1", email: "one@example.com")
        let seat2 = Self.bytes("acct-X", "user-2", email: "two@example.com")
        file.bytes = seat1
        store = InMemoryCodexSignInStore([copy(seat1), copy(seat2)])
        let model = try await makeModel(links: ["acct-X|user-1": idA, "acct-X|user-2": idB], auto: true)
        let one = ChatGPTIdentity(accountID: "acct-X", userID: "user-1", email: "one@example.com", planType: "team")
        let two = ChatGPTIdentity(accountID: "acct-X", userID: "user-2", email: "two@example.com", planType: "team")
        let pool = [
            CodexCandidate(accountID: idA, label: "Seat one", identity: one, isPaused: false, usable: true,
                           snapshot: snap(0.8, identity: one), planUnits: 20, order: 0),
            CodexCandidate(accountID: idB, label: "Seat two", identity: two, isPaused: false, usable: true,
                           snapshot: snap(0.1, identity: two), planUnits: 20, order: 1),
        ]
        model.usageDidChange(pool, now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.signIns.map(\.verified), [true, true])
        XCTAssertEqual(model.current?.id, "acct-X|user-1")
        XCTAssertEqual(file.writes, [])

        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, "acct-X|user-2", "by hand it switches")
    }

    /// Spec §1, §4.5: a running session may follow a switch to
    /// another seat of its workspace. The card, the Focus target and the
    /// status after the switch carry it, so each can say so; another
    /// workspace does not.
    func testASwitchToAnotherSeatOfTheWorkspaceIsMarked() async throws {
        let seat1 = Self.bytes("acct-X", "user-1", email: "one@example.com")
        let seat2 = Self.bytes("acct-X", "user-2", email: "two@example.com")
        file.bytes = seat1
        store = InMemoryCodexSignInStore([copy(seat1), copy(seat2), copy(cBytes)])
        let model = try await makeModel(links: ["acct-X|user-1": idA, "acct-X|user-2": idB, Self.loginC: idC])
        let one = ChatGPTIdentity(accountID: "acct-X", userID: "user-1", email: "one@example.com", planType: "team")
        let two = ChatGPTIdentity(accountID: "acct-X", userID: "user-2", email: "two@example.com", planType: "team")
        model.usageDidChange([
            CodexCandidate(accountID: idA, label: "Seat one", identity: one, isPaused: false, usable: true,
                           snapshot: snap(0.8, identity: one), planUnits: 20, order: 0),
            CodexCandidate(accountID: idB, label: "Seat two", identity: two, isPaused: false, usable: true,
                           snapshot: snap(0.1, identity: two), planUnits: 20, order: 1),
            CodexCandidate(accountID: idC, label: "Other", identity: Self.identityC, isPaused: false, usable: true,
                           snapshot: snap(0.5, identity: Self.identityC), planUnits: 20, order: 2),
        ], now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.cardState(for: idB), .canSwitch(sameWorkspace: true))
        XCTAssertEqual(model.cardState(for: idC), .canSwitch(sameWorkspace: false))
        XCTAssertEqual(model.focusLine(now: now)?.target, .init(accountID: idB, label: "Seat two", sameWorkspace: true),
                       "the most room, marked")

        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.state.status, .switched(at: now, from: "acct-X|user-1", to: "acct-X|user-2", automatic: false,
                                                     sameWorkspace: true))
        XCTAssertEqual(model.cardState(for: idA), .canSwitch(sameWorkspace: true), "and back")

        await model.useInCodex(accountID: idC)
        XCTAssertEqual(model.state.status, .switched(at: now, from: "acct-X|user-2", to: Self.loginC, automatic: false))
        XCTAssertEqual(model.focusLine(now: now)?.target?.sameWorkspace, false)
    }

    /// Spec §4.2 configuration: automatic switching waits for the user's
    /// acknowledgement that Codex uses its default file.
    func testAutomaticSwitchingNeedsTheConfigurationAcknowledgement() async throws {
        let model = try await makeModel(acknowledged: false)
        await model.setAutoSwitch(enabled: true, rule: ClaudeCodeAutoSwitch.Rule(percent: 70, kind: .weekly))
        XCTAssertFalse(model.state.autoSwitchEnabled, "refused")
        XCTAssertEqual(model.state.rule, ClaudeCodeAutoSwitch.Rule(), "no change at all")
        XCTAssertNil(model.lastError, "no error")
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginA)

        await model.setConfigurationAcknowledged(true)
        await model.setAutoSwitch(enabled: true, rule: ClaudeCodeAutoSwitch.Rule(percent: 70, kind: .weekly))
        XCTAssertTrue(model.state.autoSwitchEnabled)
        let saved = try await stateStore.load()
        XCTAssertTrue(saved.configurationAcknowledged)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginB)

        await model.setConfigurationAcknowledged(false)
        XCTAssertFalse(model.state.autoSwitchEnabled, "withdrawn: automatic switching off")
    }

    /// A mixed file (spec §2): reported, automatic switching paused, never
    /// switched from.
    func testADamagedFilePausesAutomaticSwitching() async throws {
        let model = try await makeModel(auto: true)
        codexWrites(mixed)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertNil(model.current)
        XCTAssertEqual(model.state.status, .damaged(at: now))
        XCTAssertTrue(model.state.autoSwitchPaused)
        XCTAssertEqual(file.writes, [])
        let saved = try await stateStore.load()
        XCTAssertEqual(saved.status, .damaged(at: now))
        XCTAssertTrue(saved.autoSwitchPaused)
    }

    /// A journal that cannot be read at launch, over a file that is
    /// not a whole login, needs attention and blocks switching. Then,
    /// once `codex login` brings a whole login back, Resume clears it — the
    /// way out Settings offers — and switching works again.
    func testAnUnreadableJournalNeedsAttentionUntilALoginAndResume() async throws {
        journal = InMemoryCodexJournal(CodexSwitchJournal(startedAt: now.addingTimeInterval(-60), from: Self.loginA, to: Self.loginB,
                                                          fromSavedAt: now.addingTimeInterval(-86_400)))
        journal.readFails = true
        file.bytes = mixed
        let model = try await makeModel()
        XCTAssertEqual(model.state.status, .needsAttention(at: now))
        await model.resumeAutoSwitch()
        XCTAssertEqual(model.state.status, .needsAttention(at: now), "nothing whole in the file yet")

        // `codex login`; Resume not pressed yet: still blocked.
        codexWrites(aBytes)
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.waitUntilIdle()
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(model.current?.id, Self.loginA)

        await model.resumeAutoSwitch()
        XCTAssertNil(model.state.status)
        XCTAssertNil(try journal.read(), "cleared")
        let saved = try await stateStore.load()
        XCTAssertNil(saved.status)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB)
    }

    /// At launch, an unreadable journal over a whole login is
    /// cleared like a resolved one — nothing to restore, nothing to report.
    func testAnUnreadableJournalOverAWholeLoginIsClearedAtLaunch() async throws {
        journal.readFails = true
        let model = try await makeModel()
        XCTAssertNil(model.state.status)
        XCTAssertNil(try journal.read())
        model.usageDidChange(candidates(a: 0.1), now: now)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB)
    }

    /// Spec §4.1: while a switch needs attention (its journal kept), no switch
    /// starts, automatic or by hand, and no copy is forgotten — until Resume
    /// finds the journal resolved.
    func testAnUnresolvedJournalBlocksSwitchAndForgetUntilResume() async throws {
        journal = InMemoryCodexJournal(CodexSwitchJournal(startedAt: now.addingTimeInterval(-60), from: Self.loginA, to: Self.loginB,
                                                          fromSavedAt: now.addingTimeInterval(-7_200)))
        file.bytes = mixed
        let model = try await makeModel(auto: true)
        XCTAssertEqual(model.state.status, .needsAttention(at: now), "the copy it names is gone")
        XCTAssertNotNil(try journal.read())

        await model.resumeAutoSwitch()
        XCTAssertEqual(model.state.status, .needsAttention(at: now), "still unresolved")
        XCTAssertNotNil(try journal.read())

        // `codex login` brings back a whole login; Resume not pressed yet.
        codexWrites(aBytes)
        model.usageDidChange(candidates(), now: now)
        await model.waitUntilIdle()
        XCTAssertEqual(model.current?.id, Self.loginA)
        XCTAssertFalse(model.state.autoSwitchPaused, "the rule did not run")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(bridge.posted.isEmpty)

        await model.useInCodex(accountID: idB)
        XCTAssertNil(model.lastError, "blocked before the switcher")
        XCTAssertEqual(file.writes, [])
        await model.forget(Self.loginB)
        XCTAssertNotNil(store.items[Self.loginB])
        await model.forgetAll()
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(model.state.links[Self.loginB], idB)

        await model.resumeAutoSwitch()
        XCTAssertNil(try journal.read())
        XCTAssertNil(model.state.status)
        await model.useInCodex(accountID: idB)
        XCTAssertEqual(model.current?.id, Self.loginB)
        await model.forget(Self.loginA)
        XCTAssertNil(store.items[Self.loginA])
    }
}
