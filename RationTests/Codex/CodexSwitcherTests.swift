import XCTest
@testable import Ration

/// The switch of `~/.codex/auth.json` between remembered logins (spec §4.1):
/// the order, the four-way read-back, rollback from the journal's named copy,
/// and recovery at launch. Fakes only: no real file, Keychain or network.
final class CodexSwitcherTests: XCTestCase {
    private typealias Failure = CodexSwitcher.Failure

    private static let idA = "acct-A|user-1"
    private static let idB = "acct-B|user-2"
    private static let idC = "acct-C|user-3"
    private let now = Date(timeIntervalSince1970: 1_790_100_000)

    private static func bytes(_ account: String, _ user: String, refresh: String? = nil,
                              lastRefresh: String = "2026-10-11T18:00:00.000000Z") -> Data {
        CodexFixtures.authJSON(accountID: account, userID: user, email: "\(user)@example.com", lastRefresh: lastRefresh,
                               refreshToken: refresh ?? "rt-\(account)")
    }

    private let aBytes = bytes("acct-A", "user-1")
    private let aNewer = bytes("acct-A", "user-1", refresh: "rt-A-2", lastRefresh: "2026-10-11T19:00:00.000000Z")
    private let bBytes = bytes("acct-B", "user-2")
    private let bNewer = bytes("acct-B", "user-2", refresh: "rt-B-2", lastRefresh: "2026-10-11T19:00:00.000000Z")
    private let cBytes = bytes("acct-C", "user-3")
    /// Ration's account id beside account A's refreshed tokens (spec §2).
    private let mixed = CodexFixtures.file(idToken: CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: "user-1")),
                                           tokensAccountID: "acct-B", refreshToken: "rt-A-2")
    private let savedA = Date(timeIntervalSince1970: 1_790_000_000)

    private var file: FakeCodexLoginFile!
    private var store: InMemoryCodexSignInStore!
    private var journal: InMemoryCodexJournal!
    private var recorded: [CodexSwitchJournal] = []

    override func setUp() {
        file = FakeCodexLoginFile(bytes: aBytes)
        store = InMemoryCodexSignInStore([copy(aBytes, savedAt: savedA), copy(bBytes)])
        journal = InMemoryCodexJournal()
        recorded = []
        journal.onWrite = { [unowned self] in if let record = try? self.journal.read() { self.recorded.append(record) } }
    }

    private func copy(_ bytes: Data, savedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> CodexSignIn {
        CodexSignIn(login: CodexFixtures.login(bytes), savedAt: savedAt)
    }

    private func login(_ bytes: Data) -> CodexLogin { CodexFixtures.login(bytes) }

    private var switcher: CodexSwitcher {
        let now = self.now
        return CodexSwitcher(file: file, store: store, journal: journal, now: { now }, confirmDelay: 0, retryDelay: 0)
    }

    private func assertFails(_ expected: Failure, _ body: () throws -> Any, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { XCTAssertEqual($0 as? Failure, expected, line: line) }
    }

    // MARK: - Reading

    func testCurrentLoginReadsTheFile() throws {
        let current = try switcher.currentLogin()
        XCTAssertEqual(current.id, Self.idA)
        XCTAssertEqual(current.bytes, aBytes)
    }

    func testNoFileIsNotSignedIn() {
        file.bytes = nil
        assertFails(.notSignedIn) { try self.switcher.currentLogin() }
    }

    func testAnAPIKeyLoginIsUnsupported() {
        file.bytes = CodexFixtures.apiKeyJSON()
        assertFails(.unsupported) { try self.switcher.currentLogin() }
    }

    func testAMixedFileIsDamaged() {
        file.bytes = mixed
        assertFails(.damaged) { try self.switcher.currentLogin() }
    }

    /// Codex writes in place: a read can catch the file half-written. Retried
    /// once, then unreadable — never "not signed in".
    func testAHalfWrittenFileIsRetriedOnceThenUnreadable() throws {
        file.unreadableReads = 1
        XCTAssertEqual(try switcher.currentLogin().id, Self.idA)
        XCTAssertEqual(file.readCount, 2)

        file.unreadableReads = 2
        assertFails(.unreadable) { try self.switcher.currentLogin() }

        file.bytes = aBytes.prefix(aBytes.count / 2)
        file.nextReadReplacement = aBytes
        XCTAssertEqual(try switcher.currentLogin().id, Self.idA, "truncated bytes, then the whole file")

        file.bytes = aBytes.prefix(aBytes.count / 2)
        assertFails(.unreadable) { try self.switcher.currentLogin() }
    }

    func testConfirmedLoginRefusesAChangeBetweenReads() throws {
        file.nextReadReplacement = aNewer
        assertFails(.signInChanging) { try self.switcher.confirmedLogin() }
        let confirmed = try switcher.confirmedLogin()
        XCTAssertEqual(confirmed.login.bytes, aNewer)
        XCTAssertEqual(confirmed.savedAt, now)
    }

    func testRememberSavesAConfirmedLogin() throws {
        store = InMemoryCodexSignInStore()
        let remembered = try switcher.remember()
        XCTAssertEqual(remembered, CodexSignIn(login: login(aBytes), savedAt: now))
        XCTAssertEqual(store.items, [Self.idA: remembered])
    }

    // MARK: - Kept fresh

    func testRefreshRememberedCopySavesOnlyTheSameLoginsNewerBytes() throws {
        file.bytes = aNewer
        XCTAssertTrue(try switcher.refreshRememberedCopy())
        XCTAssertEqual(store.items[Self.idA], CodexSignIn(login: login(aNewer), savedAt: now))
        XCTAssertFalse(try switcher.refreshRememberedCopy(), "unchanged now")

        file.bytes = cBytes
        XCTAssertFalse(try switcher.refreshRememberedCopy(), "not remembered: never saved behind the user's back")
        XCTAssertNil(store.items[Self.idC])
        XCTAssertEqual(store.saves.count, 1)
    }

    /// Compare-and-swap on the login id: a login that changed between the
    /// read and the save is never saved under the old one.
    func testRefreshRememberedCopyNeverSavesAnotherLoginUnderTheOldOne() throws {
        file.bytes = aNewer
        file.nextReadReplacement = cBytes
        XCTAssertFalse(try switcher.refreshRememberedCopy())
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(store.items[Self.idA]?.login.bytes, aBytes)
    }

    func testADamagedFileIsNeverSavedAsACopy() {
        file.bytes = mixed
        assertFails(.damaged) { try self.switcher.refreshRememberedCopy() }
        XCTAssertTrue(store.saves.isEmpty)
    }

    // MARK: - Switching

    /// The file holds the whole target login, read back.
    func testASwitchWritesTheWholeTargetFileAndReadsItBack() throws {
        XCTAssertEqual(try switcher.switchTo(accountID: Self.idB, allowUnremembered: false),
                       .switched(from: login(aBytes), to: login(bBytes)))
        XCTAssertEqual(file.writes, [bBytes])
        XCTAssertEqual(file.bytes, bBytes)
        XCTAssertNil(try journal.read())
        XCTAssertEqual(recorded, [CodexSwitchJournal(startedAt: now, from: Self.idA, to: Self.idB, fromSavedAt: savedA)])
        XCTAssertTrue(store.saves.isEmpty, "the left copy was current: not re-saved")
    }

    /// The left login's newest tokens are kept, and that copy is the one the
    /// journal names as the rollback source.
    func testTheLeftLoginsNewestTokensAreSavedFirst() throws {
        file.bytes = aNewer
        guard case .switched = try switcher.switchTo(accountID: Self.idB, allowUnremembered: false) else { return XCTFail() }
        XCTAssertEqual(store.items[Self.idA], CodexSignIn(login: login(aNewer), savedAt: now))
        XCTAssertEqual(recorded.first?.fromSavedAt, now)
    }

    func testSwitchingToTheCurrentAccountIsAlreadyActive() throws {
        XCTAssertEqual(try switcher.switchTo(accountID: Self.idA, allowUnremembered: false), .alreadyActive)
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(journal.writes, 0)
    }

    func testSwitchingToAnUnrememberedTargetIsRefused() {
        assertFails(.targetNotRemembered) { try self.switcher.switchTo(accountID: Self.idC, allowUnremembered: true) }
        XCTAssertEqual(file.writes, [])
    }

    /// An unremembered login would be lost by switching away: only with consent,
    /// and then there is no copy to roll back to.
    func testLeavingAnUnrememberedLoginIsRefusedUnlessAllowed() throws {
        store = InMemoryCodexSignInStore([copy(bBytes)])
        assertFails(.leftAccountNotRemembered(login(aBytes))) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(journal.writes, 0)

        guard case .switched = try switcher.switchTo(accountID: Self.idB, allowUnremembered: true) else { return XCTFail() }
        XCTAssertNil(store.items[Self.idA], "not remembered behind the user's back")
        XCTAssertEqual(recorded, [CodexSwitchJournal(startedAt: now, from: Self.idA, to: Self.idB, fromSavedAt: nil)],
                       "no copy, so nothing to roll back to")
    }

    /// An automatic decision names the login it was made for.
    func testExpectingAnotherAccountIsSignInChanging() {
        assertFails(.signInChanging) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false, expecting: Self.idC) }
        XCTAssertEqual(file.writes, [])
        XCTAssertTrue(store.saves.isEmpty)
    }

    /// The stability check: Codex changing the file between the two reads.
    func testAChangingFileIsNeverSwitched() {
        file.afterRead = { [aNewer] count, bytes in if count == 2 { bytes = aNewer } }
        assertFails(.signInChanging) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(journal.writes, 0)
    }

    /// The exact-bytes compare right before the write (spec §4.1 step 3).
    func testAChangeRightBeforeTheWriteIsRefused() {
        journal.onWrite = { [file, aNewer] in file!.bytes = aNewer }
        assertFails(.signInChanging) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(file.bytes, aNewer, "Codex's newer file stays")
        XCTAssertNil(try journal.read())
    }

    /// The model runs the stability check itself and re-decides
    /// before the write; the confirmed login is the one left, with no second
    /// check, and the exact-bytes compare still guards the time since.
    func testAConfirmedLoginFromTheCallerIsTheOneLeft() throws {
        let confirmed = try switcher.confirmedLogin()
        let readsBefore = file.readCount
        XCTAssertEqual(try switcher.switchTo(accountID: Self.idB, allowUnremembered: false, confirmed: confirmed),
                       .switched(from: login(aBytes), to: login(bBytes)))
        XCTAssertEqual(file.readCount - readsBefore, 2, "the compare before the write and the read-back: no stability reads")
        XCTAssertEqual(file.writes, [bBytes])

        setUp()
        let stale = try switcher.confirmedLogin()
        file.bytes = aNewer
        assertFails(.signInChanging) {
            try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false, confirmed: stale)
        }
        XCTAssertEqual(file.writes, [], "Codex refreshed since the check: nothing written")
        XCTAssertEqual(file.bytes, aNewer)
        XCTAssertNil(try journal.read())

        setUp()
        let other = CodexSignIn(login: login(cBytes), savedAt: now)
        assertFails(.signInChanging) {
            try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: true, expecting: Self.idA, confirmed: other)
        }
        XCTAssertEqual(file.writes, [])
    }

    /// Codex refreshed the target between Ration's write and its read-back.
    func testATargetRefreshedDuringTheWriteIsSwitchedUnverified() throws {
        file.afterWrite = { [bNewer] count, bytes in if count == 1 { bytes = bNewer } }
        XCTAssertEqual(try switcher.switchTo(accountID: Self.idB, allowUnremembered: false),
                       .switchedUnverified(from: login(aBytes), to: login(bNewer)))
        XCTAssertEqual(file.writes, [bBytes], "no second write")
        XCTAssertEqual(file.bytes, bNewer)
        XCTAssertNil(try journal.read())
    }

    /// A whole login of any other account after the write — an external
    /// `codex login`, the left account written back, an API key — is never
    /// overwritten.
    func testAnotherWholeLoginAfterTheWriteIsAConflictAndNeverOverwritten() {
        for other in [cBytes, aNewer, CodexFixtures.apiKeyJSON()] {
            setUp()
            file.afterWrite = { count, bytes in if count == 1 { bytes = other } }
            assertFails(.conflict) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
            XCTAssertEqual(file.writes, [bBytes])
            XCTAssertEqual(file.bytes, other)
            XCTAssertNil(try journal.read())
        }
    }

    /// The mixed file (spec §2) after the write: rolled back from the copy the
    /// journal names, and only that one.
    func testADamagedReadBackRollsBackFromTheNamedCopy() {
        file.afterWrite = { [mixed] count, bytes in if count == 1 { bytes = mixed } }
        assertFails(.failed) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [bBytes, aBytes])
        XCTAssertEqual(file.bytes, aBytes)
        XCTAssertNil(try journal.read())

        setUp()
        file.afterWrite = { [mixed, store, aNewer] count, bytes in
            guard count == 1 else { return }
            bytes = mixed
            try? store!.save(CodexSignIn(login: CodexFixtures.login(aNewer), savedAt: Date(timeIntervalSince1970: 1_790_050_000)))
        }
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [bBytes], "a copy re-saved since is not the rollback source")
        XCTAssertEqual(file.bytes, mixed)
        XCTAssertNotNil(try journal.read())
    }

    func testAnUnreadableReadBackRollsBack() {
        file.afterWrite = { [bBytes] count, bytes in if count == 1 { bytes = bBytes.prefix(40) } }
        assertFails(.failed) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.bytes, aBytes)
        XCTAssertNil(try journal.read())
    }

    /// Nothing written: nothing to undo.
    func testAWriteThatThrowsIsAPlainFailure() {
        file.writeFails = true
        assertFails(.failed) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(file.bytes, aBytes)
        XCTAssertNil(try journal.read())
    }

    /// The writer refused the file (a symlink, not 0600 …): unsupported, untouched.
    func testAWriterPreconditionIsUnsupported() {
        file.writeFails = true
        file.writeError = CodexAuthFile.Failure.permissive(mode: 0o644)
        assertFails(.unsupported) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.bytes, aBytes)
        XCTAssertNil(try journal.read())
    }

    /// A write that threw after the truncate left a broken file: rolled back.
    func testAWriteInterruptedAfterTheTruncateRollsBack() {
        file.partialWrites = [1]
        assertFails(.failed) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [aBytes])
        XCTAssertEqual(file.bytes, aBytes)
        XCTAssertNil(try journal.read())
    }

    /// The bytes are in the file but the sync failed — neither
    /// switched nor undone for sure. Never reported as a success: the
    /// journal stays and launch recovery classifies the file.
    func testASyncFailureAfterTheBytesLandedNeedsAttentionAndKeepsTheJournal() {
        file.writeThenFail = [1]
        file.writeError = CodexAuthFile.Failure.syncFailed
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.bytes, bBytes)
        XCTAssertEqual(try journal.read()?.to, Self.idB, "kept")
        XCTAssertEqual(switcher.recoverIfNeeded(), .completed, "recovery finds the whole target login")
        XCTAssertNil(try journal.read())
    }

    func testARollbackThatCannotRestoreNeedsAttention() {
        file.afterWrite = { [mixed] count, bytes in if count == 1 { bytes = mixed } }
        file.failingWrites = [2]
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.bytes, mixed)
        XCTAssertEqual(try journal.read()?.from, Self.idA)
    }

    /// Codex finished writing a whole login between the read-back and the
    /// rollback: the rollback never writes over it, and recovery then
    /// recognises it.
    func testARollbackNeverOverwritesALoginCodexWroteMeanwhile() {
        var armed = false
        file.afterWrite = { [mixed] count, bytes in
            if count == 1 { bytes = mixed; armed = true }
        }
        file.afterRead = { [cBytes] _, bytes in
            if armed { armed = false; bytes = cBytes }
        }
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [bBytes])
        XCTAssertEqual(file.bytes, cBytes)
        XCTAssertEqual(switcher.recoverIfNeeded(), .none)
        XCTAssertNil(try journal.read())
        XCTAssertEqual(file.bytes, cBytes)
    }

    /// A failed read is not an observation. Codex wrote a
    /// whole login C right after Ration's write and every read since failed:
    /// the read-back and the rollback's re-read must never agree with each
    /// other and write the left copy over C.
    func testAReadBackThatCannotBeReadNeedsAttentionAndWritesNothing() {
        file.afterWrite = { [cBytes] count, bytes in if count == 1 { bytes = cBytes } }
        file.unreadableReadsAfterWrite = [1: 3]
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [bBytes], "no rollback write over a file never seen")
        XCTAssertEqual(file.bytes, cBytes)
        XCTAssertEqual(try journal.read()?.from, Self.idA, "the journal is kept")
    }

    /// While a journal is unresolved (needs attention), no switch starts.
    func testAnUnresolvedJournalBlocksSwitching() {
        journal = InMemoryCodexJournal(CodexSwitchJournal(startedAt: .distantPast, from: Self.idA, to: Self.idB, fromSavedAt: savedA))
        file.bytes = mixed
        store = InMemoryCodexSignInStore([copy(bBytes)])
        assertFails(.journalUnresolved) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: true) }
        XCTAssertEqual(file.writes, [])
    }

    /// A journal that cannot be read is not "no journal": no switch
    /// starts, and recovery over a file that is not a whole login — the case
    /// that would need the copy it names — reports needs-attention.
    func testAnUnreadableJournalBlocksSwitchingAndNeedsAttention() {
        journal = InMemoryCodexJournal(CodexSwitchJournal(startedAt: .distantPast, from: Self.idA, to: Self.idB, fromSavedAt: savedA))
        journal.readFails = true
        assertFails(.journalUnresolved) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(journal.writes, 0)
        for broken: Data? in [mixed, nil, Data("{\"auth_mode\": \"chat".utf8)] {
            file.bytes = broken
            XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention, "\(String(describing: broken.map { String(decoding: $0, as: UTF8.self) }))")
            XCTAssertNotNil(journal.stored, "kept")
        }
        XCTAssertEqual(file.writes, [])
    }

    /// An unreadable journal over a whole login — any account's,
    /// or a login Ration cannot switch — names nothing recovery would need:
    /// no rollback is ever written over a whole login. It is cleared, and
    /// switching works again.
    func testAnUnreadableJournalOverAWholeLoginIsCleared() throws {
        for whole in [aBytes, cBytes, CodexFixtures.apiKeyJSON()] {
            setUp()
            journal = InMemoryCodexJournal(CodexSwitchJournal(startedAt: .distantPast, from: Self.idA, to: Self.idB, fromSavedAt: savedA))
            journal.readFails = true
            file.bytes = whole
            XCTAssertEqual(switcher.recoverIfNeeded(), .cleared)
            XCTAssertNil(journal.stored)
            XCTAssertNil(try journal.read(), "gone, not unreadable")
            XCTAssertEqual(file.writes, [], "nothing restored over it")
            XCTAssertEqual(file.bytes, whole)
        }

        setUp()
        journal.readFails = true
        XCTAssertEqual(switcher.recoverIfNeeded(), .cleared)
        XCTAssertEqual(try switcher.switchTo(accountID: Self.idB, allowUnremembered: false), .switched(from: login(aBytes), to: login(bBytes)))

        // A clear that fails leaves it unresolved.
        setUp()
        journal.readFails = true
        journal.clearFails = true
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
    }

    /// A switch whose journal cannot be cleared still blocks every
    /// later switch, so it is reported as needing attention — never a
    /// success — and so is a recovery that cannot clear it.
    func testAJournalThatCannotBeClearedNeedsAttention() {
        journal.clearFails = true
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.bytes, bBytes, "the switch itself went through")
        XCTAssertEqual(journal.stored?.to, Self.idB, "and the journal is still there")

        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention, "a finished switch, but the journal stays")
        journal.clearFails = false
        XCTAssertEqual(switcher.recoverIfNeeded(), .completed)
        XCTAssertNil(journal.stored)

        // A refused switch (Codex changed the file before the write) too.
        setUp()
        journal.clearFails = true
        journal.onWrite = { [file, aNewer] in file!.bytes = aNewer }
        assertFails(.needsAttention) { try self.switcher.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertEqual(file.writes, [])
    }

    /// Two seats of one workspace share the account id.
    func testTwoSeatsOfOneWorkspaceAreTwoLogins() throws {
        let seat1 = Self.bytes("acct-X", "user-1")
        let seat2 = Self.bytes("acct-X", "user-2")
        file.bytes = seat1
        store = InMemoryCodexSignInStore([copy(seat1), copy(seat2)])
        XCTAssertEqual(try switcher.switchTo(accountID: "acct-X|user-2", allowUnremembered: false),
                       .switched(from: login(seat1), to: login(seat2)))
        XCTAssertEqual(file.writes, [seat2])
        XCTAssertEqual(try switcher.switchTo(accountID: "acct-X|user-2", allowUnremembered: false), .alreadyActive)
        guard case .switched = try switcher.switchTo(accountID: "acct-X|user-1", allowUnremembered: false) else { return XCTFail() }
    }

    // MARK: - Recovery at launch

    private func journalAtoB(fromSavedAt: Date? = Date(timeIntervalSince1970: 1_790_000_000)) {
        journal = InMemoryCodexJournal(CodexSwitchJournal(startedAt: .distantPast, from: Self.idA, to: Self.idB, fromSavedAt: fromSavedAt))
    }

    func testNoJournalIsNone() {
        XCTAssertEqual(switcher.recoverIfNeeded(), .none)
        XCTAssertEqual(file.writes, [])
    }

    func testRecoveryCompletesAFinishedSwitch() {
        journalAtoB()
        file.bytes = bNewer
        XCTAssertEqual(switcher.recoverIfNeeded(), .completed)
        XCTAssertEqual(file.writes, [])
        XCTAssertNil(try journal.read())
    }

    func testRecoveryClearsAnUntouchedFrom() {
        journalAtoB()
        XCTAssertEqual(switcher.recoverIfNeeded(), .none)
        XCTAssertEqual(file.writes, [])
        XCTAssertNil(try journal.read())
    }

    func testRecoveryLeavesAnExternalLoginAlone() {
        for other in [cBytes, CodexFixtures.apiKeyJSON()] {
            journalAtoB()
            file.bytes = other
            XCTAssertEqual(switcher.recoverIfNeeded(), .none)
            XCTAssertEqual(file.bytes, other)
            XCTAssertNil(try journal.read())
        }
        XCTAssertEqual(file.writes, [])
    }

    func testRecoveryRestoresFromTheNamedCopy() {
        journalAtoB()
        file.bytes = mixed
        XCTAssertEqual(switcher.recoverIfNeeded(), .restored)
        XCTAssertEqual(file.bytes, aBytes)
        XCTAssertNil(try journal.read())
    }

    func testRecoveryRetriesAHalfWrittenFile() {
        journalAtoB()
        file.bytes = bBytes
        file.unreadableReads = 1
        XCTAssertEqual(switcher.recoverIfNeeded(), .completed)
        XCTAssertEqual(file.writes, [])
    }

    func testRecoveryWithARecopiedSourceNeedsAttention() {
        journalAtoB(fromSavedAt: Date(timeIntervalSince1970: 1_789_000_000))
        file.bytes = mixed
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
        XCTAssertEqual(file.writes, [])
        XCTAssertNotNil(try journal.read())
    }

    func testRecoveryWithoutARememberedCopyNeedsAttention() {
        journalAtoB(fromSavedAt: nil)
        file.bytes = mixed
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
        journalAtoB()
        store = InMemoryCodexSignInStore([copy(bBytes)])
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
        XCTAssertEqual(file.writes, [])
        XCTAssertNotNil(try journal.read())
    }

    /// Journal A→B, a valid C in the file, and three failed
    /// reads. Two unreadable reads must never compare equal and restore A
    /// over C: the journal stays and the user is told.
    func testRecoveryNeverRestoresOverAFileItCouldNotRead() {
        journalAtoB()
        file.bytes = cBytes
        file.unreadableReads = 3
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
        XCTAssertEqual(file.writes, [])
        XCTAssertEqual(file.bytes, cBytes)
        XCTAssertNotNil(try journal.read(), "the journal is kept")

        // Readable again: C is an external login, left alone.
        XCTAssertEqual(switcher.recoverIfNeeded(), .none)
        XCTAssertEqual(file.bytes, cBytes)
        XCTAssertNil(try journal.read())
    }

    /// A missing file is never created: nothing to restore into.
    func testRecoveryOfAMissingFileNeedsAttention() {
        journalAtoB()
        file.bytes = nil
        XCTAssertEqual(switcher.recoverIfNeeded(), .needsAttention)
        XCTAssertNil(file.bytes)
        XCTAssertNotNil(try journal.read())
    }

    /// Through the real journal file (ISO 8601 seconds) with a fractional
    /// clock: the named copy is still found, so the rollback source survives
    /// a relaunch.
    func testTheNamedCopySurvivesTheJournalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CodexSwitcherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journalFile = CodexJournalFile(url: folder.appending(path: "codex-switch-journal.json"))
        file.bytes = aNewer
        file.afterWrite = { [mixed] count, bytes in if count == 1 { bytes = mixed } }
        file.failingWrites = [2]
        let fractional = Date(timeIntervalSince1970: 1_790_100_000.625)
        let live = CodexSwitcher(file: file, store: store, journal: journalFile, now: { fractional }, confirmDelay: 0, retryDelay: 0)
        assertFails(.needsAttention) { try live.switchTo(accountID: Self.idB, allowUnremembered: false) }
        XCTAssertNotNil(try journalFile.read())

        file.failingWrites = []
        let relaunched = CodexSwitcher(file: file, store: store, journal: journalFile, now: { .now }, confirmDelay: 0, retryDelay: 0)
        XCTAssertEqual(relaunched.recoverIfNeeded(), .restored)
        XCTAssertEqual(file.bytes, aNewer)
        XCTAssertNil(try journalFile.read())
    }
}
