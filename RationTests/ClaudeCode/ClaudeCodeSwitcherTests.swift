import XCTest
@testable import Ration

final class ClaudeCodeSwitcherTests: XCTestCase {
    private var tool: FakeSecurityTool!
    private var config: FakeClaudeCodeConfig!
    private var store: InMemoryClaudeCodeSignInStore!
    private var journal: InMemoryJournal!
    private let original = ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("A"))

    private func loginObject(_ token: String, _ id: String) -> [String: Any] { ["refreshToken": token, "accessToken": "access-\(id)"] }
    private func entryItem(login: [String: Any], mcp: String = "m1") -> [String: Any] {
        ["claudeAiOauth": login, "mcpOAuth": ["server": ["token": mcp]]]
    }

    override func setUp() {
        tool = FakeSecurityTool(item: entryItem(login: loginObject("refresh-A", "A")))
        config = FakeClaudeCodeConfig(bytes: original)
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A", token: "refresh-A-old"), ClaudeCodeSignInTests.signIn("B")])
        journal = InMemoryJournal()
    }

    private var switcher: ClaudeCodeSwitcher {
        ClaudeCodeSwitcher(entry: ClaudeCodeKeychainEntry(tool: tool, user: "me"), config: config, store: store, journal: journal,
                           now: { Date(timeIntervalSince1970: 1_790_100_000) }, confirmDelay: 0)
    }

    private var entryLogin: Data { ClaudeCodeKeychainEntry.canonical(tool.item!["claudeAiOauth"]!) }
    private var entryMCP: Data { ClaudeCodeKeychainEntry.canonical(tool.item!["mcpOAuth"]!) }
    private var configAccount: String? { config.bytes.flatMap { try? ClaudeCodeConfig.account(in: $0)?.uuid } }
    private var loginA: Data { ClaudeCodeSignInTests.signIn("A").login }
    private var loginB: Data { ClaudeCodeSignInTests.signIn("B").login }

    func testSwitchChangesBothAndKeepsEverythingElse() throws {
        let outcome = try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)
        guard case .switched(let from, let to) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(from.uuid, "acc-A")
        XCTAssertEqual(to.uuid, "acc-B")
        XCTAssertEqual(entryLogin, loginB)
        XCTAssertEqual(entryMCP, ClaudeCodeKeychainEntry.canonical(["server": ["token": "m1"]]))
        XCTAssertEqual(configAccount, "acc-B")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: config.bytes!) as? [String: Any])
        XCTAssertEqual(object["numStartups"] as? Int, 5)
        XCTAssertEqual(store.signIn("acc-A")?.login, loginA, "the account being left is re-saved with its newest login")
        XCTAssertNil(journal.read())
    }

    func testSwitchingToTheCurrentAccountDoesNothing() throws {
        XCTAssertEqual(try switcher.switchTo(accountUUID: "acc-A", allowUnremembered: false), .alreadyActive)
        XCTAssertEqual(tool.writes, 0)
        XCTAssertEqual(config.writeCount, 0)
    }

    func testTargetMustBeRemembered() {
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-C", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .targetNotRemembered)
        }
    }

    /// An unremembered sign-in would be lost by switching away: only with consent.
    func testLeavingAnUnrememberedSignInNeedsConsent() throws {
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("B")])
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            guard case .leftAccountNotRemembered(let account) = $0 as? ClaudeCodeSwitcher.Failure else { return XCTFail("\($0)") }
            XCTAssertEqual(account.uuid, "acc-A")
        }
        XCTAssertEqual(tool.writes, 0)
        guard case .switched = try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: true) else { return XCTFail() }
        XCTAssertNil(store.signIn("acc-A"), "not remembered behind the user's back")
    }

    /// The sign-in changes between reads → nothing saved or written.
    func testAChangingSignInIsNeverSavedOrSwitched() {
        config.afterRead = { count, bytes in
            if count == 1 { bytes = ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("A", fetchedAt: 42)) }
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .signInChanging)
        }
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(tool.writes, 0)
    }

    /// Claude Code changed its entry before Ration wrote → untouched.
    /// Also the renewal hazard: Claude Code renewed the left account after
    /// Ration saved it — the renewed login must survive (compare-and-swap).
    func testAChangeBeforeTheWriteTouchesNothing() {
        journal.onWrite = { [tool] in
            tool!.setItem(self.entryItem(login: self.loginObject("refresh-A2", "A")))
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .conflict)
        }
        XCTAssertEqual(tool.writes, 0)
        XCTAssertEqual(entryLogin, ClaudeCodeKeychainEntry.canonical(loginObject("refresh-A2", "A")), "Claude Code's newer login stays")
        XCTAssertEqual(config.bytes, original)
        XCTAssertNil(journal.read())
    }

    /// A change right after Ration's write → rolled back, the change kept.
    func testAConflictAfterTheWriteRollsBackAndKeepsClaudeCodesChange() {
        var fired = false
        tool.afterWrite = { item in
            guard !fired else { return }
            fired = true
            item = try! JSONSerialization.data(withJSONObject: self.entryItem(login: self.loginObject("refresh-B", "B"), mcp: "m9"))
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .conflict)
        }
        XCTAssertEqual(entryLogin, loginA)
        XCTAssertEqual(entryMCP, ClaudeCodeKeychainEntry.canonical(["server": ["token": "m9"]]))
        XCTAssertEqual(config.bytes, original)
        XCTAssertNil(journal.read())
    }

    /// Claude Code wrote ITS login over Ration's right after: never overwritten back.
    func testALoginClaudeCodeWroteAfterUsIsLeftAlone() {
        var fired = false
        tool.afterWrite = { item in
            guard !fired else { return }
            fired = true
            item = try! JSONSerialization.data(withJSONObject: self.entryItem(login: self.loginObject("refresh-A-new", "A")))
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false))
        XCTAssertEqual(entryLogin, ClaudeCodeKeychainEntry.canonical(loginObject("refresh-A-new", "A")))
        XCTAssertEqual(tool.writes, 1)
    }

    /// A truncated settings write is restored from the journal.
    func testAFailedSettingsWriteRestoresBoth() {
        config.failingWrites = [1]
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .failed)
        }
        XCTAssertEqual(config.bytes, original)
        XCTAssertEqual(entryLogin, loginA)
        XCTAssertNil(journal.read())
    }

    /// Claude Code signed in to a third account meanwhile —
    /// its settings are never erased; Ration only takes its own login back.
    func testAThirdAccountInTheSettingsIsLeftAlone() {
        config.afterWrite = { count, bytes in
            if count == 1 { bytes = ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("C")) }
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .needsAttention(entryRestored: true, configRestored: false))
        }
        XCTAssertEqual(configAccount, "acc-C")
        XCTAssertEqual(entryLogin, loginA)
        XCTAssertNotNil(journal.read())
    }

    /// A settings change Claude Code made after Ration's first
    /// read is kept — the account is replaced in the bytes read just before writing.
    func testASettingsChangeBeforeRationsWriteIsKept() throws {
        journal.onWrite = { [config] in
            var object = try! JSONSerialization.jsonObject(with: config!.bytes!) as! [String: Any]
            object["theme"] = "light"
            config!.bytes = try! JSONSerialization.data(withJSONObject: object)
        }
        _ = try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: config.bytes!) as? [String: Any])
        XCTAssertEqual(object["theme"] as? String, "light")
        XCTAssertEqual(configAccount, "acc-B")
    }

    /// A rollback puts back only the account, not old bytes.
    func testARollbackPutsBackOnlyTheAccount() throws {
        config.writeThenFail = [1]
        config.afterWrite = { count, bytes in
            guard count == 1 else { return }
            var object = try! JSONSerialization.jsonObject(with: bytes!) as! [String: Any]
            object["theme"] = "light"
            bytes = try! JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .failed)
        }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: config.bytes!) as? [String: Any])
        XCTAssertEqual(object["theme"] as? String, "light")
        XCTAssertEqual(configAccount, "acc-A")
        XCTAssertEqual(entryLogin, loginA)
    }

    /// A login that changes between two reads (a /login may
    /// write it before the settings) is never remembered.
    func testALoginChangingBetweenTwoReadsIsNotRemembered() {
        tool.afterRead = { count, item in
            if count == 1 { item = try! JSONSerialization.data(withJSONObject: self.entryItem(login: self.loginObject("refresh-C", "C"))) }
        }
        XCTAssertThrowsError(try switcher.remember()) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .signInChanging)
        }
        XCTAssertTrue(store.saves.isEmpty)
    }

    /// Another plan's login under this account is not this account's.
    func testAnotherPlansLoginIsNeverSavedAsThisAccount() throws {
        var maxLogin = loginObject("refresh-A-old", "A")
        maxLogin["subscriptionType"] = "max"
        store = InMemoryClaudeCodeSignInStore([
            ClaudeCodeSignIn(account: ClaudeCodeConfig.account(from: ClaudeCodeConfigTests.account("A"))!,
                             login: ClaudeCodeKeychainEntry.canonical(maxLogin), savedAt: .distantPast),
            ClaudeCodeSignInTests.signIn("B"),
        ])
        var proLogin = loginObject("refresh-P", "P")
        proLogin["subscriptionType"] = "pro"
        tool.setItem(entryItem(login: proLogin))
        XCTAssertFalse(try switcher.refreshRememberedCopy())
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .signInChanging)
        }
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(tool.writes, 0)
    }

    /// The entry changed while the settings were written —
    /// not reported as a clean switch, and not undone blindly.
    func testAnEntryChangeDuringTheSwitchIsNotReportedAsSuccess() {
        config.afterWrite = { [tool] count, _ in
            if count == 1 { tool!.setItem(self.entryItem(login: self.loginObject("refresh-B2", "B"))) }
        }
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .unverified)
        }
        XCTAssertEqual(entryLogin, ClaudeCodeKeychainEntry.canonical(loginObject("refresh-B2", "B")))
        XCTAssertEqual(configAccount, "acc-B")
    }

    /// A login Ration cannot place is left alone and reported.
    func testLaunchRecoveryLeavesAnUnknownLoginAlone() {
        journal = InMemoryJournal(ClaudeCodeSwitchJournal(startedAt: .distantPast, from: "acc-A", to: "acc-B", config: original))
        tool.setItem(entryItem(login: loginObject("refresh-X", "X")))
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B")])
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
        XCTAssertEqual(entryLogin, ClaudeCodeKeychainEntry.canonical(loginObject("refresh-X", "X")))
        XCTAssertNotNil(journal.read())
    }

    func testLaunchRecoveryPutsTheLeftLoginBackAfterAHalfSwitch() {
        journal = InMemoryJournal(ClaudeCodeSwitchJournal(startedAt: .distantPast, from: "acc-A", to: "acc-B", config: original))
        tool.setItem(entryItem(login: loginObject("refresh-B", "B")))
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B")])
        XCTAssertEqual(switcher.recoverIfNeeded(), .restored)
        XCTAssertEqual(entryLogin, loginA)
        XCTAssertNil(journal.read())
    }

    /// A rollback that cannot finish is reported, and the journal stays.
    func testAFailedRollbackNeedsAttentionAndKeepsTheJournal() {
        config.failingWrites = [1, 2]
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false)) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .needsAttention(entryRestored: true, configRestored: false))
        }
        XCTAssertEqual(entryLogin, loginA)
        XCTAssertNotNil(journal.read())
    }

    func testLaunchRecoveryRestoresAnInterruptedSwitch() throws {
        journal = InMemoryJournal(ClaudeCodeSwitchJournal(startedAt: .distantPast, from: "acc-A", to: "acc-B", config: original))
        config.bytes = original.prefix(40)
        tool.setItem(entryItem(login: loginObject("refresh-B", "B")))
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B")])
        XCTAssertEqual(switcher.recoverIfNeeded(), .restored)
        XCTAssertEqual(config.bytes, original)
        XCTAssertEqual(entryLogin, loginA)
        XCTAssertNil(journal.read())
    }

    func testLaunchRecoveryOfACompletedSwitchChangesNothing() {
        journal = InMemoryJournal(ClaudeCodeSwitchJournal(startedAt: .distantPast, from: "acc-A", to: "acc-B", config: original))
        config.bytes = ClaudeCodeConfigTests.file(account: ClaudeCodeConfigTests.account("B"))
        tool.setItem(entryItem(login: loginObject("refresh-B", "B")))
        XCTAssertEqual(switcher.recoverIfNeeded(), .completed)
        XCTAssertEqual(tool.writes, 0)
        XCTAssertEqual(config.writeCount, 0)
        XCTAssertNil(journal.read())
    }

    func testLaunchRecoveryWhenNothingHappened() {
        journal = InMemoryJournal(ClaudeCodeSwitchJournal(startedAt: .distantPast, from: "acc-A", to: "acc-B", config: original))
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("A"), ClaudeCodeSignInTests.signIn("B")])
        XCTAssertEqual(switcher.recoverIfNeeded(), .none)
        XCTAssertEqual(tool.writes, 0)
        XCTAssertNil(journal.read())
    }

    func testRememberedCopyIsRefreshedOnlyWhenPairedAndChanged() throws {
        XCTAssertTrue(try switcher.refreshRememberedCopy())
        XCTAssertEqual(store.signIn("acc-A")?.login, loginA)
        XCTAssertFalse(try switcher.refreshRememberedCopy(), "unchanged now")
        store = InMemoryClaudeCodeSignInStore([ClaudeCodeSignInTests.signIn("B")])
        XCTAssertFalse(try switcher.refreshRememberedCopy(), "not remembered: never saved behind the user's back")
    }

    /// An automatic switch names the account whose usage triggered it; if
    /// Claude Code is on another one by now (a /login meanwhile), nothing happens.
    func testAnAutomaticSwitchChecksTheAccountItDecidedFor() {
        XCTAssertThrowsError(try switcher.switchTo(accountUUID: "acc-B", allowUnremembered: false, expecting: "acc-C")) {
            XCTAssertEqual($0 as? ClaudeCodeSwitcher.Failure, .signInChanging)
        }
        XCTAssertEqual(tool.writes, 0)
        XCTAssertTrue(store.saves.isEmpty)
    }
}
