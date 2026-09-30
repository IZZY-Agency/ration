import XCTest
@testable import Ration

/// `AppModel` hands the Claude accounts to the switch after every snapshot
/// pass, and a removed account's sign-in is unlinked.
@MainActor
final class AppModelClaudeCodeWiringTests: XCTestCase {
    private func signIn(_ fixture: AlertsFixture, _ label: String) async throws -> AccountRecord {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: label)
        return try XCTUnwrap(fixture.model.accounts.first { $0.label == label })
    }

    private func claudeCodeModel(in directory: URL, links: [String: UUID] = [:]) async throws -> ClaudeCodeModel {
        var state = ClaudeCodeState()
        state.links = links
        let stateStore = JSONFileStore(fileURL: directory.appending(path: "claude-code-switch.json"), defaultValue: ClaudeCodeState())
        try await stateStore.save(state)
        let model = ClaudeCodeModel(dependencies: .init(
            switcher: ClaudeCodeSwitcher(
                entry: ClaudeCodeKeychainEntry(tool: FakeSecurityTool(item: ["claudeAiOauth": ["refreshToken": "refresh-A"]]), user: "me"),
                config: FakeClaudeCodeConfig(bytes: ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("A"))),
                store: InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B")]),
                journal: InMemoryJournal(), now: { .now }, confirmDelay: 0),
            stateStore: stateStore,
            logStore: JSONFileStore(fileURL: directory.appending(path: "claude-code-switches.json"), defaultValue: [])))
        await model.start()
        return model
    }

    func testASnapshotPassHandsTheClaudeAccountsToTheSwitch() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let personal = try await signIn(fixture, "Personal")
        let claudeCode = try await claudeCodeModel(in: fixture.directory)
        fixture.model.claudeCode = claudeCode

        try await fixture.snapshots.save(UsageSnapshot(
            accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: nil),
            organizationID: "org-A"))

        XCTAssertEqual(claudeCode.candidates.map(\.accountID), [work.id, personal.id])
        let first = try XCTUnwrap(claudeCode.candidates.first)
        XCTAssertEqual(first.label, "Work")
        XCTAssertEqual(first.organizationID, "org-A")
        XCTAssertEqual(first.snapshot?.weekly?.remainingFraction, 0.4)
        XCTAssertFalse(first.isPaused)
    }

    func testAPausedAccountArrivesMarkedPaused() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let claudeCode = try await claudeCodeModel(in: fixture.directory)
        fixture.model.claudeCode = claudeCode
        try await fixture.model.setPaused(accountID: work.id, paused: true)
        try await fixture.snapshots.save(UsageSnapshot(accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000),
                                                       fiveHour: nil, weekly: nil))
        XCTAssertEqual(claudeCode.candidates.map(\.isPaused), [true])
    }

    func testRemovingAnAccountUnlinksItsSignIn() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let personal = try await signIn(fixture, "Personal")
        let claudeCode = try await claudeCodeModel(in: fixture.directory, links: ["acc-A": work.id, "acc-B": personal.id])
        fixture.model.claudeCode = claudeCode

        try await fixture.model.removeAccount(id: personal.id)

        XCTAssertEqual(claudeCode.state.links, ["acc-A": work.id])
    }

    /// Settings removes through `requestRemoveAccount`.
    func testRemovingThroughTheRequestPathUnlinksToo() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let personal = try await signIn(fixture, "Personal")
        let claudeCode = try await claudeCodeModel(in: fixture.directory, links: ["acc-A": work.id, "acc-B": personal.id])
        fixture.model.claudeCode = claudeCode

        let task = try fixture.model.requestRemoveAccount(id: personal.id)
        try await task.value

        XCTAssertEqual(claudeCode.state.links, ["acc-A": work.id])
    }
}
