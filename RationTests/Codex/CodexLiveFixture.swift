import Foundation
@testable import Ration

/// A started `CodexModel` over the fakes, for the views that observe one (the
/// popover, Settings › Codex, their renders): Codex on login A, logins A and B
/// remembered, the given state saved before `start()`, then the ChatGPT
/// candidates handed in as `AppModel` would. No real `~/.codex`, Keychain or
/// network. The caller removes `directory`.
@MainActor
struct CodexLiveFixture {
    static let loginA = "acct-A|user-1"
    static let loginB = "acct-B|user-2"
    static let identityA = ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "client@example.com", planType: "pro")
    static let identityB = ChatGPTIdentity(accountID: "acct-B", userID: "user-2", email: "personal@example.com", planType: "prolite")
    static let bytesA = CodexFixtures.authJSON(accountID: "acct-A", userID: "user-1", email: "client@example.com", planType: "pro",
                                               refreshToken: "rt-A")
    static let bytesB = CodexFixtures.authJSON(accountID: "acct-B", userID: "user-2", email: "personal@example.com", planType: "prolite",
                                               refreshToken: "rt-B")

    let model: CodexModel
    let file: FakeCodexLoginFile
    let store: InMemoryCodexSignInStore
    let directory: URL

    /// `bSavedAgo`: how long before `now` login B's copy was saved (over 7
    /// days makes it validity-unknown).
    static func make(
        now: Date,
        state: CodexState,
        current: Data? = bytesA,
        bSavedAgo: TimeInterval = 86_400,
        candidates: [CodexCandidate]
    ) async throws -> CodexLiveFixture {
        let directory = try makeTemporaryDirectory()
        let stateStore = JSONFileStore(fileURL: directory.appending(path: "codex-switch.json"), defaultValue: CodexState())
        try await stateStore.save(state)
        let file = FakeCodexLoginFile(bytes: current)
        let store = InMemoryCodexSignInStore([
            CodexSignIn(login: CodexFixtures.login(bytesA), savedAt: now.addingTimeInterval(-3_600)),
            CodexSignIn(login: CodexFixtures.login(bytesB), savedAt: now.addingTimeInterval(-bSavedAgo)),
        ])
        let model = CodexModel(dependencies: .init(
            switcher: CodexSwitcher(file: file, store: store, journal: InMemoryCodexJournal(), now: { now },
                                    confirmDelay: 0, retryDelay: 0),
            stateStore: stateStore,
            logStore: JSONFileStore(fileURL: directory.appending(path: CodexSwitchLogEntry.fileName), defaultValue: [])
        ), now: { now })
        await model.start()
        model.usageDidChange(candidates, now: now)
        await model.waitUntilIdle()
        return CodexLiveFixture(model: model, file: file, store: store, directory: directory)
    }

    /// A ChatGPT account as `AppModel.codexCandidates` builds it: its latest
    /// snapshot (weekly `used`, fetched a minute before `now`) carries the
    /// identity its own fetch read.
    static func candidate(_ accountID: UUID, _ label: String, identity: ChatGPTIdentity?, used: Double, order: Int,
                          now: Date) -> CodexCandidate {
        CodexCandidate(
            accountID: accountID, label: label, identity: identity, isPaused: false, usable: true,
            snapshot: UsageSnapshot(accountID: accountID, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil,
                                    weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - used,
                                                        resetsAt: now.addingTimeInterval(2 * 86_400)),
                                    chatGPTIdentity: identity),
            planUnits: 20, order: order)
    }
}
