import Foundation

/// Switches the ChatGPT account Codex uses by writing a remembered login over
/// `~/.codex/auth.json` (spec §4.1). Codex holds no lock Ration could take,
/// so the switch narrows the window — identical bytes across two reads, an
/// exact compare right before the write, a read-back right after — sorts
/// what it reads back into four classes, rolls back only from the copy the
/// journal names, and says so where it cannot: never silently half-switched.
/// Synchronous; the model runs it off the main actor, one call at a time, on
/// the queue that also runs the kept-fresh re-saves (so none can change the
/// rollback source mid-switch).
struct CodexSwitcher: Sendable {
    let file: any CodexLoginAccess
    let store: any CodexSignInStore
    let journal: any CodexJournalStore
    let now: @Sendable () -> Date
    /// Seconds between the two reads of the stability check.
    var confirmDelay: TimeInterval = 2
    /// The pause before the one retry of an unreadable file (Codex writes in place).
    var retryDelay: TimeInterval = 0.25

    enum Outcome: Equatable, Sendable {
        case switched(from: CodexLogin, to: CodexLogin)
        /// Switched, but Codex refreshed the target meanwhile: the file holds
        /// the target's newer tokens (`to`), not Ration's bytes. The next
        /// kept-fresh pass re-saves the copy.
        case switchedUnverified(from: CodexLogin, to: CodexLogin)
        case alreadyActive
    }

    enum Failure: Error, Equatable, Sendable {
        /// No file.
        case notSignedIn
        /// An API-key or keyring login, not a ChatGPT one; or the writer
        /// refused the file (not the user's own 0600 regular file).
        case unsupported
        /// Unreadable twice.
        case unreadable
        /// A mixed file (spec §2): run `codex login`.
        case damaged
        /// The file changed between reads, or right before the write, or is
        /// not on the login an automatic decision expected.
        case signInChanging
        /// Switching away would lose a login Ration has not remembered.
        case leftAccountNotRemembered(CodexLogin)
        case targetNotRemembered
        /// A switch needs attention (its journal is kept): no switch until it
        /// is resolved (spec §4.1).
        case journalUnresolved
        /// After the write the file held a whole login of another account (an
        /// external `codex login`): left as is, journal cleared.
        case conflict
        /// The write failed before touching the file, or the read-back was
        /// broken and the left copy was written back and read back.
        case failed
        /// A broken read-back the rollback could not repair, or a file that
        /// could not be read at all (never rolled back over); the journal is kept.
        case needsAttention
    }

    enum Recovery: Equatable, Sendable {
        case none, completed, restored, needsAttention
        /// A journal that could not be read, over a whole login: whatever it
        /// named, recovery would not have written over that login, so it is
        /// cleared like a resolved one.
        case cleared
    }

    /// The login Codex has now; one retry when the file reads as half-written.
    func currentLogin() throws -> CodexLogin {
        switch read() {
        case .missing: throw Failure.notSignedIn
        case .login(let login): return login
        case .broken(let failure, _): throw Self.failure(failure)
        }
    }

    /// The stability check (spec §4.1): two reads `confirmDelay` apart with
    /// identical bytes — hence the same login id and `last_refresh`.
    func confirmedLogin() throws -> CodexSignIn {
        let first = try currentLogin()
        if confirmDelay > 0 { Thread.sleep(forTimeInterval: confirmDelay) }
        let second = try currentLogin()
        guard second.bytes == first.bytes else { throw Failure.signInChanging }
        return CodexSignIn(login: second, savedAt: now())
    }

    /// Remembers the login Codex uses now: a confirmed one.
    func remember() throws -> CodexSignIn {
        let signIn = try confirmedLogin()
        try store.save(signIn)
        return signIn
    }

    /// Kept fresh (spec §4.1): re-saves the current login when it is
    /// remembered and Codex renewed its tokens since. Never remembers a login
    /// by itself; compare-and-swap on the login id, so a login that changed
    /// between the read and the save is never saved under the old one. A
    /// damaged file throws `.damaged` and is never saved.
    func refreshRememberedCopy() throws -> Bool {
        let quick = try currentLogin()
        guard let saved = try store.all().first(where: { $0.id == quick.id }), saved.login.bytes != quick.bytes else { return false }
        let confirmed = try confirmedLogin()
        guard confirmed.id == saved.id else { return false }
        try store.save(confirmed)
        return true
    }

    /// `accountID`: the target's login id (`CodexLogin.id`, both parts — never
    /// the account id alone, spec §4.1). `expecting`: the login an automatic
    /// decision was made for; a switch from any other login is refused.
    /// `confirmed`: the stability check the caller already ran
    /// (`confirmedLogin()`, spec §4.5: the model re-decides after its delay);
    /// it is the login being left, and no second check runs. The exact-bytes
    /// compare right before the write still guards the time since.
    func switchTo(accountID target: String, allowUnremembered: Bool, expecting: String? = nil,
                  confirmed given: CodexSignIn? = nil) throws -> Outcome {
        guard journalAbsent else { throw Failure.journalUnresolved }
        let quick = try given?.login ?? currentLogin()
        if let expecting, quick.id != expecting { throw Failure.signInChanging }
        guard quick.id != target else { return .alreadyActive }
        let remembered = try store.all()
        guard let targetCopy = remembered.first(where: { $0.id == target }) else { throw Failure.targetNotRemembered }
        var leftCopy = remembered.first { $0.id == quick.id }
        if leftCopy == nil, !allowUnremembered { throw Failure.leftAccountNotRemembered(quick) }

        // 1) Stability (unless the caller ran it), then keep the left login's
        // newest tokens.
        let confirmed = try given ?? confirmedLogin()
        guard confirmed.id == quick.id else { throw Failure.signInChanging }
        let left = confirmed.login
        if let copy = leftCopy, copy.login.bytes != left.bytes {
            try store.save(confirmed)
            leftCopy = confirmed
        }

        // 2) The journal names that exact copy as the rollback source.
        let record = CodexSwitchJournal(startedAt: now(), from: left.id, to: targetCopy.id, fromSavedAt: leftCopy?.savedAt)
        try journal.write(record)

        // 3) The file must still be exactly the left login's, then write.
        guard observe() == .bytes(left.bytes) else {
            try clearJournal()
            throw Failure.signInChanging
        }
        do {
            try file.write(targetCopy.login.bytes)
        } catch CodexAuthFile.Failure.syncFailed {
            // Written but maybe not on disk: neither switched nor undone for
            // sure. The journal stays; launch recovery classifies the file.
            throw Failure.needsAttention
        } catch {
            // Untouched: nothing to undo. Touched (an interrupted write): the
            // read-back below sorts it out.
            if observe() == .bytes(left.bytes) {
                try clearJournal()
                throw error is CodexAuthFile.Failure ? Failure.unsupported : Failure.failed
            }
        }

        // 4) Read back and classify.
        let back = read()
        switch back {
        case .login(let login) where login.bytes == targetCopy.login.bytes:
            try clearJournal()
            return .switched(from: left, to: targetCopy.login)
        case .login(let login) where login.id == targetCopy.id:
            try clearJournal()
            return .switchedUnverified(from: left, to: login)
        case .login, .broken(.unsupported, _):
            // A whole login of another account: never overwritten.
            try clearJournal()
            throw Failure.conflict
        case .missing, .broken:
            guard restore(record, over: back) else { throw Failure.needsAttention }
            try clearJournal()
            throw Failure.failed
        }
    }

    /// A journal left by a crash or a rollback that could not finish (spec
    /// §4.1), sorted into the same four classes. Clears it only when the file
    /// is a whole login again; a file it cannot read keeps the journal
    /// (needs attention) and is never restored over.
    func recoverIfNeeded() -> Recovery {
        let found: CodexSwitchJournal?
        do {
            found = try journal.read()
        } catch {
            // There, but unreadable: what it names is unknown. That
            // matters only for a file that is not a whole login — the one case
            // that needs its named copy. A whole login (any account, or one
            // Ration cannot switch) is never written over, so the journal
            // goes: `codex login`, then Resume, is the way out.
            switch read() {
            case .login, .broken(.unsupported, _): return cleared(.cleared)
            case .missing, .broken: return .needsAttention
            }
        }
        guard let record = found else { return .none }
        let state = read()
        switch state {
        case .login(let login) where login.id == record.to:
            return cleared(.completed)
        case .login, .broken(.unsupported, _):
            // The left login (nothing happened), or one made outside Ration
            // since: never overwritten.
            return cleared(.none)
        case .missing, .broken:
            guard restore(record, over: state) else { return .needsAttention }
            return cleared(.restored)
        }
    }

    // MARK: - The journal

    /// No journal at all. One that is there, or cannot be read, is unresolved
    /// (spec §4.1).
    private var journalAbsent: Bool {
        do {
            return try journal.read() == nil
        } catch {
            return false
        }
    }

    /// A journal that cannot be cleared still blocks every switch: the
    /// switch reports needs-attention, never its own outcome.
    private func clearJournal() throws {
        do {
            try journal.clear()
        } catch {
            throw Failure.needsAttention
        }
    }

    private func cleared(_ recovery: Recovery) -> Recovery {
        do {
            try journal.clear()
            return recovery
        } catch {
            return .needsAttention
        }
    }

    // MARK: - Reading

    /// One look at the file. A read that failed saw nothing: it is never
    /// equal to "missing", nor to anything a rollback compares it with.
    private enum Observation: Equatable {
        case missing
        /// The read itself failed.
        case unreadable
        case bytes(Data)
    }

    private func observe() -> Observation {
        do {
            return try file.readBytes().map(Observation.bytes) ?? .missing
        } catch {
            return .unreadable
        }
    }

    /// What the file holds.
    private enum FileState {
        case missing
        case login(CodexLogin)
        /// Not a whole ChatGPT login: bytes that do not decode to one, or a
        /// read that failed (`.unreadable`).
        case broken(CodexLogin.Failure, Observation)

        var observation: Observation {
            switch self {
            case .missing: .missing
            case .login(let login): .bytes(login.bytes)
            case .broken(_, let observation): observation
            }
        }
    }

    private func readOnce() -> FileState {
        let observation = observe()
        switch observation {
        case .missing:
            return .missing
        case .unreadable:
            return .broken(.unreadable, .unreadable)
        case .bytes(let bytes):
            do {
                return .login(try CodexLogin(fileBytes: bytes))
            } catch {
                return .broken(error as? CodexLogin.Failure ?? .unreadable, observation)
            }
        }
    }

    /// Codex writes in place (truncate, then write): a read can catch the file
    /// half-written. One retry after `retryDelay`; never read as "not signed in".
    private func read() -> FileState {
        let first = readOnce()
        guard case .broken(.unreadable, _) = first else { return first }
        if retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
        return readOnce()
    }

    private static func failure(_ failure: CodexLogin.Failure) -> Failure {
        switch failure {
        case .unreadable: .unreadable
        case .unsupported: .unsupported
        case .damaged: .damaged
        }
    }

    // MARK: - Rollback

    /// Writes the journal's named copy — the left login's copy saved at
    /// `fromSavedAt`, not one re-saved since — over a file that is not a
    /// whole login, then reads it back. Only over a file actually observed
    /// (missing, or bytes) and observed again unchanged: a read that failed
    /// saw nothing — Codex may have written a whole login there — so it is
    /// never rolled back over (the journal stays: needs attention).
    private func restore(_ record: CodexSwitchJournal, over judged: FileState) -> Bool {
        let seen = judged.observation
        guard seen != .unreadable,
              let savedAt = record.fromSavedAt,
              let copy = (try? store.all())?.first(where: { $0.id == record.from && $0.savedAt == savedAt })
        else { return false }
        guard observe() == seen else { return false }
        do {
            try file.write(copy.login.bytes)
        } catch {
            return false
        }
        guard case .login(let back) = read(), back.bytes == copy.login.bytes else { return false }
        return true
    }
}
