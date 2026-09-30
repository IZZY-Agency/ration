import Foundation

/// Switches the account Claude Code uses (spec §4.1). Two stores cannot be
/// changed atomically: the switch narrows its windows, detects what it can,
/// rolls back from a journal and, where that fails, says so — never silently
/// half-switched. Synchronous; the model runs it off the main actor, one at a time.
struct ClaudeCodeSwitcher: Sendable {
    let entry: ClaudeCodeKeychainEntry
    let config: any ClaudeCodeConfigAccess
    let store: any ClaudeCodeSignInStore
    let journal: any ClaudeCodeJournalStore
    let now: @Sendable () -> Date
    /// Seconds between the two reads of a pair that is about to be saved.
    var confirmDelay: TimeInterval = 2

    enum Outcome: Equatable, Sendable {
        case switched(from: ClaudeCodeAccount, to: ClaudeCodeAccount)
        case alreadyActive
    }

    enum Failure: Error, Equatable, Sendable {
        /// No account in `~/.claude.json`, or no Claude login in the entry.
        case notSignedIn
        /// `~/.claude.json` could not be read as JSON.
        case configUnreadable
        /// The sign-in changed while it was being read.
        case signInChanging
        /// Switching away would lose a sign-in Ration has not remembered.
        case leftAccountNotRemembered(ClaudeCodeAccount)
        case targetNotRemembered
        /// Claude Code wrote its entry during the switch; rolled back.
        case conflict
        /// A step failed; rolled back.
        case failed
        /// The rollback itself could not finish; the journal is kept.
        case needsAttention(entryRestored: Bool, configRestored: Bool)
        /// Switched, but Claude Code wrote its entry at the same moment:
        /// not undone blindly, not reported as a clean switch.
        case unverified
    }

    enum Recovery: Equatable, Sendable { case none, completed, restored, needsAttention }

    /// The account, the login, the account again: trusted only when the
    /// account uuid and its sign-in time are the same on both sides (spec §4.1).
    func currentPair() throws -> ClaudeCodeSignIn {
        let first = try account()
        let login: Data
        do {
            login = try entry.login()
        } catch ClaudeCodeKeychainEntry.Failure.notFound, ClaudeCodeKeychainEntry.Failure.noLogin {
            throw Failure.notSignedIn
        }
        let second = try account()
        guard second.uuid == first.uuid, second.profileFetchedAt == first.profileFetchedAt else { throw Failure.signInChanging }
        return ClaudeCodeSignIn(account: second, login: login, savedAt: now())
    }

    /// Two pairs `confirmDelay` apart, identical in account and login. A
    /// `/login` may write the new login before it updates the settings; a
    /// short wait lets it finish. (A residual window stays: the spec says so.)
    func confirmedPair() throws -> ClaudeCodeSignIn {
        let first = try currentPair()
        if confirmDelay > 0 { Thread.sleep(forTimeInterval: confirmDelay) }
        let second = try currentPair()
        guard second.login == first.login, second.account.json == first.account.json else { throw Failure.signInChanging }
        return second
    }

    /// Remembers the sign-in Claude Code uses now: a confirmed pair.
    func remember() throws -> ClaudeCodeSignIn {
        let pair = try confirmedPair()
        try store.save(pair)
        return pair
    }

    /// Re-saves Claude Code's current sign-in when it is remembered and Claude
    /// Code renewed its login since. Never remembers an account by itself,
    /// and never saves another plan's login as this account.
    func refreshRememberedCopy() throws -> Bool {
        let quick = try currentPair()
        guard let saved = try store.all().first(where: { $0.uuid == quick.uuid }),
              saved.login != quick.login || saved.account.json != quick.account.json
        else { return false }
        let pair = try confirmedPair()
        guard pair.uuid == saved.uuid, Self.samePlan(pair.login, saved.login) else { return false }
        try store.save(pair)
        return true
    }

    /// `expecting`: the account an automatic decision was made for; a switch
    /// from any other account is refused.
    func switchTo(accountUUID: String, allowUnremembered: Bool, expecting: String? = nil) throws -> Outcome {
        var left = try currentPair()
        if let expecting, left.uuid != expecting { throw Failure.signInChanging }
        guard left.uuid != accountUUID else { return .alreadyActive }
        let remembered = try store.all()
        guard let target = remembered.first(where: { $0.uuid == accountUUID }) else { throw Failure.targetNotRemembered }
        if let saved = remembered.first(where: { $0.uuid == left.uuid }) {
            // Keep the newest login of the account being left — confirmed, and
            // only if it looks like that account's (same plan).
            if saved.login != left.login || saved.account.json != left.account.json {
                left = try confirmedPair()
                guard left.uuid == saved.uuid, Self.samePlan(left.login, saved.login) else { throw Failure.signInChanging }
                if let expecting, left.uuid != expecting { throw Failure.signInChanging }
                try store.save(left)
            }
        } else if !allowUnremembered {
            throw Failure.leftAccountNotRemembered(left.account)
        }
        guard let original = try config.readBytes() else { throw Failure.notSignedIn }
        try journal.write(ClaudeCodeSwitchJournal(startedAt: now(), from: left.uuid, to: target.uuid, config: original))

        do {
            try entry.replaceLogin(with: target.login, expecting: left.login)
        } catch ClaudeCodeKeychainEntry.Failure.changedBeforeWrite {
            // Nothing was written: leave Claude Code's newer entry alone.
            try? journal.clear()
            throw Failure.conflict
        } catch {
            try rollBack(left: left, target: target, lastGoodConfig: original)
            throw (error as? ClaudeCodeKeychainEntry.Failure) == .conflict ? Failure.conflict : Failure.failed
        }

        // The account is replaced in the bytes read just before writing, so a
        // change Claude Code made since the journal read is kept.
        var lastGood = original
        do {
            guard let fresh = try config.readBytes(), try ClaudeCodeConfig.account(in: fresh)?.uuid == left.uuid else {
                throw Failure.failed
            }
            lastGood = fresh
            try config.write(ClaudeCodeConfig.replacingAccount(in: fresh, with: target.account.json))
        } catch {
            try rollBack(left: left, target: target, lastGoodConfig: lastGood)
            throw Failure.failed
        }

        // Both stores, read together.
        let back = ((try? config.readBytes()) ?? nil).flatMap { try? ClaudeCodeConfig.account(in: $0) }
        guard back?.uuid == target.uuid else {
            try rollBack(left: left, target: target, lastGoodConfig: lastGood)
            throw Failure.failed
        }
        guard (try? entry.login()) == target.login else {
            // Claude Code wrote its entry during the switch: most likely it
            // renewed the new account, but Ration cannot tell — say so.
            try? journal.clear()
            throw Failure.unverified
        }
        try? journal.clear()
        return .switched(from: left.account, to: target.account)
    }

    /// A journal left by a crash or a failed rollback (spec §4.1). Clears it
    /// only when the stores are a known pair again.
    func recoverIfNeeded() -> Recovery {
        guard let record = journal.read() else { return .none }
        let remembered = (try? store.all()) ?? []
        let from = remembered.first { $0.uuid == record.from }
        let to = remembered.first { $0.uuid == record.to }
        let live = (try? config.readBytes()) ?? nil
        let liveAccount = live.flatMap { try? ClaudeCodeConfig.account(in: $0) }
        let login = try? entry.login()

        switch liveAccount?.uuid {
        case record.to where login != nil && login != from?.login:
            // The settings are written after the entry: the switch completed,
            // and a login other than the left one is the new account's.
            try? journal.clear()
            return .completed
        case record.from where login == from?.login:
            try? journal.clear()
            return .none
        case record.from:
            guard let from, let to, login == to.login else { return .needsAttention }
            try? entry.restoreLogin(from.login)
            guard (try? entry.login()) == from.login else { return .needsAttention }
            try? journal.clear()
            return .restored
        case nil:
            guard let from, (try? config.write(record.config)) != nil,
                  ((try? config.readBytes()) ?? nil).flatMap({ try? ClaudeCodeConfig.account(in: $0)?.uuid }) == record.from
            else { return .needsAttention }
            if login == to?.login { try? entry.restoreLogin(from.login) }
            guard (try? entry.login()) == from.login else { return .needsAttention }
            try? journal.clear()
            return .restored
        default:
            return .needsAttention
        }
    }

    /// Same `subscriptionType` and `rateLimitTier` (absent on both counts as
    /// same): a cheap proof that a login is not another plan's account.
    static func samePlan(_ a: Data, _ b: Data) -> Bool {
        func hint(_ data: Data) -> [String?] {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return [object?["subscriptionType"] as? String, object?["rateLimitTier"] as? String]
        }
        return hint(a) == hint(b)
    }

    private func account() throws -> ClaudeCodeAccount {
        guard let bytes = try config.readBytes() else { throw Failure.notSignedIn }
        let parsed: ClaudeCodeAccount?
        do { parsed = try ClaudeCodeConfig.account(in: bytes) } catch { throw Failure.configUnreadable }
        guard let parsed else { throw Failure.notSignedIn }
        return parsed
    }

    /// Undoes only Ration's own writes (spec §4.1): the settings get the left
    /// account back in their LIVE bytes (the last good bytes only when they
    /// are unreadable, never over a third account); the entry gets the left
    /// login only while it still holds Ration's. Clears the journal only when
    /// both are exactly the left pair again.
    private func rollBack(left: ClaudeCodeSignIn, target: ClaudeCodeSignIn, lastGoodConfig: Data) throws {
        let live = (try? config.readBytes()) ?? nil
        let liveUUID = live.flatMap { try? ClaudeCodeConfig.account(in: $0)?.uuid }
        var configRestored: Bool
        switch liveUUID {
        case left.uuid:
            configRestored = true
        case target.uuid:
            if let live, let restored = try? ClaudeCodeConfig.replacingAccount(in: live, with: left.account.json) {
                try? config.write(restored)
            }
            configRestored = accountInConfig() == left.uuid
        case nil:
            try? config.write(lastGoodConfig)
            configRestored = accountInConfig() == left.uuid
        default:
            configRestored = false
        }
        var entryRestored = false
        if let login = try? entry.login() {
            if login == target.login { try? entry.restoreLogin(left.login) }
            entryRestored = (try? entry.login()) == left.login
        }
        guard entryRestored, configRestored else {
            throw Failure.needsAttention(entryRestored: entryRestored, configRestored: configRestored)
        }
        try? journal.clear()
    }

    private func accountInConfig() -> String? {
        ((try? config.readBytes()) ?? nil).flatMap { try? ClaudeCodeConfig.account(in: $0)?.uuid }
    }
}
