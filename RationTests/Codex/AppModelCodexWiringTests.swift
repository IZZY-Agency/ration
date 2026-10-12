import XCTest
@testable import Ration

/// `AppModel` hands the ChatGPT accounts — with the identity each one's
/// latest fetch read — to the Codex switch after every snapshot pass, and a
/// removed account's login is unlinked.
@MainActor
final class AppModelCodexWiringTests: XCTestCase {
    private func signIn(_ fixture: AlertsFixture, _ label: String, provider: Provider = .chatGPT) async throws -> AccountRecord {
        let sessionID = try fixture.model.beginSignIn(provider: provider)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: label)
        return try XCTUnwrap(fixture.model.accounts.first { $0.label == label })
    }

    private func codexModel(in directory: URL, links: [String: UUID] = [:]) async throws -> CodexModel {
        var state = CodexState()
        state.links = links
        let stateStore = JSONFileStore(fileURL: directory.appending(path: "codex-switch.json"), defaultValue: CodexState())
        try await stateStore.save(state)
        let a = CodexFixtures.authJSON(accountID: "acct-A", userID: "user-1")
        let b = CodexFixtures.authJSON(accountID: "acct-B", userID: "user-2", email: "b@example.com", refreshToken: "rt-B")
        let model = CodexModel(dependencies: .init(
            switcher: CodexSwitcher(
                file: FakeCodexLoginFile(bytes: a),
                store: InMemoryCodexSignInStore([CodexSignIn(login: CodexFixtures.login(a), savedAt: .now),
                                                 CodexSignIn(login: CodexFixtures.login(b), savedAt: .now)]),
                journal: InMemoryCodexJournal(), now: { .now }, confirmDelay: 0, retryDelay: 0),
            stateStore: stateStore,
            logStore: JSONFileStore(fileURL: directory.appending(path: CodexSwitchLogEntry.fileName), defaultValue: [])))
        await model.start()
        return model
    }

    func testASnapshotPassHandsTheChatGPTAccountsToTheSwitch() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        _ = try await signIn(fixture, "Claude", provider: .claude)
        let work = try await signIn(fixture, "Work")
        let personal = try await signIn(fixture, "Personal")
        let codex = try await codexModel(in: fixture.directory)
        fixture.model.codex = codex

        let identity = ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "a@example.com", planType: "pro")
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: nil),
            chatGPTIdentity: identity))

        XCTAssertEqual(codex.candidates.map(\.accountID), [work.id, personal.id], "ChatGPT accounts only, in card order")
        let first = try XCTUnwrap(codex.candidates.first)
        XCTAssertEqual(first.label, "Work")
        XCTAssertEqual(first.identity, identity)
        XCTAssertEqual(first.snapshot?.weekly?.remainingFraction, 0.4)
        XCTAssertFalse(first.isPaused)
        XCTAssertEqual(first.order, 1, "the card order counts every account")
        XCTAssertNil(codex.candidates.last?.identity, "no fetch, no identity")
        await codex.waitUntilIdle()
        XCTAssertEqual(codex.state.links["acct-A|user-1"], work.id, "the identity links the remembered login")
    }

    /// A signed-out web account keeps its last snapshot, but not
    /// the identity read with it: its card offers no Codex control and its
    /// link is not verified until a fetch with a session says who it is.
    func testASignedOutAccountForwardsNoIdentity() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let identity = ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "a@example.com", planType: "pro")
        let snapshot = UsageSnapshot(accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000), fiveHour: nil,
                                     weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: nil),
                                     chatGPTIdentity: identity)

        let signedOut = fixture.model.codexCandidates(snapshots: [work.id: snapshot], states: [work.id: .reauthenticationRequired])
        XCTAssertNil(signedOut.first?.identity)
        XCTAssertEqual(signedOut.first?.snapshot, snapshot, "the usage itself stays")
        XCTAssertEqual(signedOut.first?.usable, false)

        let current = fixture.model.codexCandidates(snapshots: [work.id: snapshot], states: [work.id: .current])
        XCTAssertEqual(current.first?.identity, identity)
        let stale = fixture.model.codexCandidates(snapshots: [work.id: snapshot], states: [work.id: .stale(lastError: .transport)])
        XCTAssertEqual(stale.first?.identity, identity, "a failed refresh is not a signed-out session")
    }

    func testAPausedAccountArrivesMarkedPaused() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let codex = try await codexModel(in: fixture.directory)
        fixture.model.codex = codex
        try await fixture.model.setPaused(accountID: work.id, paused: true)
        try await fixture.snapshots.save(UsageSnapshot(accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000),
                                                       fiveHour: nil, weekly: nil))
        XCTAssertEqual(codex.candidates.map(\.isPaused), [true])
    }

    func testRemovingAnAccountUnlinksItsLogin() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let personal = try await signIn(fixture, "Personal")
        let codex = try await codexModel(in: fixture.directory, links: ["acct-A|user-1": work.id, "acct-B|user-2": personal.id])
        fixture.model.codex = codex

        try await fixture.model.removeAccount(id: personal.id)

        XCTAssertEqual(codex.state.links, ["acct-A|user-1": work.id])
    }

    /// Settings removes through `requestRemoveAccount`.
    func testRemovingThroughTheRequestPathUnlinksToo() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let personal = try await signIn(fixture, "Personal")
        let codex = try await codexModel(in: fixture.directory, links: ["acct-A|user-1": work.id, "acct-B|user-2": personal.id])
        fixture.model.codex = codex

        let task = try fixture.model.requestRemoveAccount(id: personal.id)
        try await task.value

        XCTAssertEqual(codex.state.links, ["acct-A|user-1": work.id])
    }
}
