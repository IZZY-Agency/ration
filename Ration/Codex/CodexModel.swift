import Foundation

/// A ChatGPT account as `AppModel` sees it after a refresh.
struct CodexCandidate: Equatable, Sendable {
    let accountID: UUID
    let label: String
    /// Who the account's web session is, read by the latest snapshot's own
    /// fetch (memory only). nil when signed out, reauthenticating, or not
    /// fetched since launch: the account is then never verified.
    let identity: ChatGPTIdentity?
    let isPaused: Bool
    let usable: Bool
    let snapshot: UsageSnapshot?
    let planUnits: Int?
    let order: Int
}

struct RememberedCodexSignIn: Equatable, Sendable, Identifiable {
    let login: CodexLogin
    let savedAt: Date
    let linkedAccountID: UUID?
    /// The linked account's web session reports this login's account id and
    /// user id (spec §4.2), not only a link the user chose.
    let verified: Bool
    /// Not saved for 7 days (spec §4.2 "installed is not usable"): its refresh
    /// token may be dead, which the file cannot show. Never an automatic
    /// target; switchable by hand with the hint.
    let validityUnknown: Bool
    var id: String { login.id }
}

/// Codex account switching (spec §4): state, one operation at a time, the
/// automatic rule, status and notifications. The Claude Code model's twin,
/// keyed by the login id (`CodexLogin.id`, "<account id>|<user id>"). Switcher
/// work runs off the main actor; every request goes through one serial queue,
/// claimed before its first await.
@MainActor
final class CodexModel: ObservableObject {
    struct Dependencies: Sendable {
        let switcher: CodexSwitcher
        let stateStore: JSONFileStore<CodexState>
        let logStore: JSONFileStore<[CodexSwitchLogEntry]>
    }

    @Published private(set) var current: CodexLogin?
    @Published private(set) var remembered: [CodexSignIn] = []
    @Published private(set) var state = CodexState()
    @Published private(set) var switchingTo: UUID?
    @Published private(set) var lastError: CodexSwitcher.Failure?
    @Published private(set) var candidates: [CodexCandidate] = []
    /// A save of the feature's state file failed: the file may no longer say
    /// what the model does (a pause, a link), so automatic switching is off
    /// (fails closed) until the user turns it on again and that save
    /// succeeds. Any save can set it; only that one clears it.
    @Published private(set) var stateSaveFailed = false
    weak var bridge: AlertDeliveryBridge?

    /// `start()` has loaded `codex-switch.json` and run launch recovery.
    /// AppModel starts — and emits snapshots — before that: until then
    /// nothing links, decides or persists (a write would put the default
    /// state over the saved one), and every action is a no-op.
    private(set) var isHydrated = false

    private let deps: Dependencies
    private let now: () -> Date
    private let queue = SerializedMutationQueue()
    private var lastConfigDate: Date?
    private var lastCopyRefresh: Date?
    private var automaticPending = false
    /// The latest candidates handed in before `start()`, replayed once by it.
    private var pendingUsage: (candidates: [CodexCandidate], now: Date)?

    /// How often Ration re-saves Codex's current login when renewed.
    static let copyRefreshInterval: TimeInterval = 600
    /// A copy saved this recently is usable for automatic switching (spec
    /// §4.2): under Codex's 8-day refresh interval, so Codex never had to
    /// refresh it with a parked token.
    private static let usableFor: TimeInterval = 7 * 86_400
    /// Codex on another login this soon after Ration's switch: the copy
    /// Ration wrote is probably dead (spec §5).
    private static let staleWithin: TimeInterval = 600

    init(dependencies: Dependencies, now: @escaping () -> Date = { .now }) {
        self.deps = dependencies
        self.now = now
    }

    /// The real stack: the user's own `~/.codex/auth.json` (the sandbox's home
    /// is the container, so the real one comes from the user database),
    /// Ration's Keychain items, state files in `stateDirectory`.
    static func live(stateDirectory: URL) -> CodexModel {
        CodexModel(dependencies: .init(
            switcher: CodexSwitcher(
                file: CodexAuthFile(url: CodexAuthFile.userAuthURL),
                store: KeychainCodexSignInStore(),
                journal: CodexJournalFile(url: stateDirectory.appending(path: "codex-switch-journal.json")),
                now: { .now }),
            stateStore: JSONFileStore(fileURL: stateDirectory.appending(path: "codex-switch.json"), defaultValue: CodexState()),
            logStore: JSONFileStore(fileURL: stateDirectory.appending(path: CodexSwitchLogEntry.fileName), defaultValue: [])))
    }

    // MARK: Derived

    var signIns: [RememberedCodexSignIn] {
        let date = now()
        return remembered.map {
            RememberedCodexSignIn(login: $0.login, savedAt: $0.savedAt, linkedAccountID: state.links[$0.id],
                                  verified: isVerified($0.login), validityUnknown: !isUsable($0, now: date))
        }
    }

    var isSwitching: Bool { switchingTo != nil }

    /// Codex is on a login Ration has not remembered — offered once the
    /// feature is in use (at least one login remembered).
    var rememberPrompt: CodexLogin? {
        guard let current, !remembered.isEmpty, !remembered.contains(where: { $0.id == current.id }),
              !state.dismissedPrompts.contains(current.id)
        else { return nil }
        return current
    }

    /// No control on a card whose web session reports no identity: Ration
    /// cannot tell whose card it is.
    func cardState(for accountID: UUID) -> CodexCardState {
        guard let id = signInID(linkedTo: accountID), let candidate = candidate(accountID),
              candidate.identity != nil, !candidate.isPaused
        else { return .none }
        if switchingTo == accountID { return .switching }
        return id == current?.id ? .current : .canSwitch(sameWorkspace: isSameWorkspace(id))
    }

    /// The remembered login `id` is another seat of the workspace Codex is on
    /// now: its account id — what the switch writes — is the current
    /// login's.
    private func isSameWorkspace(_ id: String) -> Bool {
        guard let current, let login = remembered.first(where: { $0.id == id })?.login else { return false }
        return login.id != current.id && login.accountID == current.accountID
    }

    /// Verified: the linked account's session reports the login's account id
    /// AND user id — two seats of one Team workspace share the account id.
    func isVerified(_ login: CodexLogin) -> Bool {
        guard let accountID = state.links[login.id], let identity = candidate(accountID)?.identity else { return false }
        return Self.identity(identity, is: login)
    }

    private static func identity(_ identity: ChatGPTIdentity, is login: CodexLogin) -> Bool {
        identity.accountID == login.accountID && identity.userID == login.userID
    }

    /// Spec §4.2: an unlinked remembered login links itself when exactly one
    /// ChatGPT account reports its (account id, user id) and that account is
    /// free. Never one the user set to None.
    private func linkUnlinkedSignIns() {
        var changed = false
        for signIn in remembered where state.links[signIn.id] == nil && !state.keptUnlinked.contains(signIn.id) {
            let matches = candidates.filter { $0.identity.map { Self.identity($0, is: signIn.login) } ?? false }
            guard matches.count == 1, !state.links.values.contains(matches[0].accountID) else { continue }
            state.links[signIn.id] = matches[0].accountID
            changed = true
        }
        if changed { queue.enqueue { [weak self] in _ = await self?.persistState() } }
    }

    private func candidate(_ accountID: UUID) -> CodexCandidate? {
        candidates.first { $0.accountID == accountID }
    }

    private func isPaused(_ accountID: UUID) -> Bool {
        candidate(accountID)?.isPaused ?? false
    }

    private func signInID(linkedTo accountID: UUID) -> String? {
        state.links.filter { $0.value == accountID }.keys.sorted().first { id in remembered.contains { $0.id == id } }
    }

    private func isUsable(_ signIn: CodexSignIn, now date: Date) -> Bool {
        date.timeIntervalSince(signIn.savedAt) <= Self.usableFor
    }

    /// A switch needs attention (its journal is kept, spec §4.1): no switch,
    /// automatic or by hand, and no Forget until Resume finds it resolved.
    private var journalUnresolved: Bool {
        if case .needsAttention = state.status { true } else { false }
    }

    /// Shown once the feature is in use (a login remembered) and Codex is
    /// signed in. The target is a card that offers a switch, whose usage is
    /// current on every window the Codex policy considers (the weekly, and
    /// the 5-hour when reported), ranked by its tightest one: the switch the
    /// automatic rule could make, offered early — never a stale copy. None
    /// while Codex's own login is not remembered: leaving it by hand is
    /// refused.
    func focusLine(now date: Date) -> CodexFocusLine? {
        guard let current, !remembered.isEmpty else { return nil }
        guard remembered.contains(where: { $0.id == current.id }) else {
            return CodexFocusLine(currentLabel: displayLabel(forSignIn: current.id), target: nil)
        }
        let policy = ClaudeCodeAutoSwitch.Policy.codex
        let rooms: [(candidate: CodexCandidate, room: Double)] = candidates.compactMap { candidate in
            guard case .canSwitch = cardState(for: candidate.accountID), candidate.usable, let snapshot = candidate.snapshot,
                  let id = signInID(linkedTo: candidate.accountID), !state.staleLogins.contains(id),
                  policy.required.allSatisfy({ snapshot.window(for: $0) != nil }),
                  snapshot.unreadableWindowKinds.isDisjoint(with: policy.required + policy.optional)
            else { return nil }
            let kinds = policy.required + policy.optional.filter { snapshot.window(for: $0) != nil }
            let standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: date)
            guard !standing.hasUnknown, standing.known.count == kinds.count,
                  let room = standing.known.map(\.window.remainingFraction).min(), room > 0
            else { return nil }
            return (candidate, room)
        }
        let best = rooms.min { $0.room != $1.room ? $0.room > $1.room : $0.candidate.order < $1.candidate.order }
        return CodexFocusLine(currentLabel: displayLabel(forSignIn: current.id), target: best.map {
            .init(accountID: $0.candidate.accountID, label: $0.candidate.label,
                  sameWorkspace: cardState(for: $0.candidate.accountID) == .canSwitch(sameWorkspace: true))
        })
    }

    /// The Ration label of a login, else its email, else its id.
    func displayLabel(forSignIn id: String) -> String {
        if let accountID = state.links[id], let candidate = candidate(accountID) { return candidate.label }
        if let email = remembered.first(where: { $0.id == id })?.login.email { return email }
        if let current, current.id == id, let email = current.email { return email }
        return id
    }

    // MARK: Lifecycle

    /// Loads the state, runs launch recovery, reads Codex's file, then replays
    /// the latest candidates `AppModel` handed in meanwhile.
    func start() async {
        state = (try? await deps.stateStore.load()) ?? CodexState()
        let switcher = deps.switcher
        let recovery = await Task.detached(operation: { switcher.recoverIfNeeded() }).value
        isHydrated = true
        switch recovery {
        case .needsAttention:
            state.status = .needsAttention(at: now())
            _ = await persistState()
        case .restored:
            state.status = .failed(at: now())
            _ = await persistState()
        case .none, .completed, .cleared:
            break
        }
        await reload()
        if let pending = pendingUsage {
            pendingUsage = nil
            usageDidChange(pending.candidates, now: pending.now)
        }
    }

    /// Reads Codex's file and the remembered copies. A half-written file keeps
    /// the last login read (never "not signed in"); a mixed
    /// one is reported and pauses automatic switching; Codex on another login
    /// right after Ration's switch is reported as stale.
    func reload() async {
        let switcher = deps.switcher
        let (read, signIns) = await Task.detached { () -> (Result<CodexLogin, CodexSwitcher.Failure>, [CodexSignIn]) in
            let read = Result { try switcher.currentLogin() }.mapError { $0 as? CodexSwitcher.Failure ?? .unreadable }
            return (read, (try? switcher.store.all()) ?? [])
        }.value
        var changed = false
        switch read {
        case .success(let login):
            if current != login { current = login }
            changed = noteLoginAfterSwitch(login.id) || changed
        case .failure(.unreadable):
            break
        case .failure(.damaged):
            if current != nil { current = nil }
            changed = noteDamaged() || changed
        case .failure:
            if current != nil { current = nil }
            changed = noteLoginAfterSwitch(nil) || changed
        }
        if remembered != signIns { remembered = signIns }
        lastConfigDate = switcher.file.modificationDate()
        if changed { _ = await persistState() }
    }

    /// Stale detection: within 10 minutes of Ration's switch to a login, Codex
    /// is on another login or signed out. Either way the pair is done with.
    /// A stale copy is kept out of automatic switching and Focus until it is
    /// remembered again, and automatic switching pauses.
    private func noteLoginAfterSwitch(_ id: String?) -> Bool {
        guard let to = state.lastSwitchTo, let at = state.lastSwitchAt else { return false }
        let date = now()
        if date.timeIntervalSince(at) <= Self.staleWithin {
            guard id != to else { return false }
            if !journalUnresolved { state.status = .stale(at: date, login: to) }
            if !state.staleLogins.contains(to) { state.staleLogins.append(to) }
            state.autoSwitchPaused = true
        }
        state.lastSwitchTo = nil
        state.lastSwitchAt = nil
        return true
    }

    /// A mixed file (spec §2): run `codex login`. Needs-attention outranks it.
    private func noteDamaged() -> Bool {
        var changed = false
        if state.lastSwitchTo != nil || state.lastSwitchAt != nil {
            state.lastSwitchTo = nil
            state.lastSwitchAt = nil
            changed = true
        }
        guard !journalUnresolved else { return changed }
        if case .damaged = state.status {} else {
            state.status = .damaged(at: now())
            changed = true
        }
        if !state.autoSwitchPaused {
            state.autoSwitchPaused = true
            changed = true
        }
        return changed
    }

    /// Test and quit support: waits for queued operations.
    func waitUntilIdle() async {
        try? await queue.run {}
    }

    // MARK: Usage (from AppModel's snapshot/state sink)

    func usageDidChange(_ candidates: [CodexCandidate], now date: Date) {
        guard isHydrated else {
            // Before `start()`: kept for its replay, nothing else.
            pendingUsage = (candidates, date)
            return
        }
        pendingUsage = nil
        if candidates != self.candidates { self.candidates = candidates }
        linkUnlinkedSignIns()
        let configDate = deps.switcher.file.modificationDate()
        if configDate != lastConfigDate, switchingTo == nil {
            // Codex may have signed in to another account: decide only after
            // the file is read again (a decision for the old login would fail
            // and pause automatic switching for nothing).
            lastConfigDate = configDate
            queue.enqueue { [weak self] in
                await self?.reload()
                self?.evaluateAutomatic(now: date)
            }
            return
        }
        if !remembered.isEmpty, lastCopyRefresh.map({ date.timeIntervalSince($0) >= Self.copyRefreshInterval }) ?? true {
            lastCopyRefresh = date
            let switcher = deps.switcher
            queue.enqueue { [weak self] in
                let saved = (try? await Task.detached(operation: { try switcher.refreshRememberedCopy() }).value) ?? false
                if saved { await self?.reload() }
            }
        }
        evaluateAutomatic(now: date)
    }

    private func evaluateAutomatic(now date: Date) {
        guard !automaticPending, let decision = automaticDecision(now: date) else { return }
        guard case .switchTo = decision.decision else {
            apply(decision.decision, current: decision.current, now: date)
            return
        }
        // Claimed before the first await: later emissions see it.
        automaticPending = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            defer { self.automaticPending = false }
            // Re-decided when its turn comes (the target may have filled up,
            // gone stale, been paused or unlinked while this waited), and
            // again after the stability delay (`performSwitch`).
            let at = self.now()
            guard let fresh = self.automaticDecision(now: at) else { return }
            if case .switchTo(let id, let accountID, let usedPercent) = fresh.decision {
                await self.performSwitch(to: accountID, signIn: id, expecting: fresh.current.id,
                                         automatic: true, usedPercent: usedPercent)
            } else {
                self.apply(fresh.decision, current: fresh.current, now: at)
            }
        }
    }

    /// The rule's decision for the login Codex uses now, or nil when automatic
    /// switching cannot act (off, unacknowledged, paused, needing attention,
    /// its state unsaved, busy, unlinked, unknown). Targets are usable copies (§4.2) and never
    /// another seat of the current login's workspace (§4.5: a running
    /// session may follow a seat change); verified and unpaused is the
    /// rule's own filter.
    private func automaticDecision(now date: Date) -> (decision: ClaudeCodeAutoSwitch.Decision, current: CodexLogin)? {
        guard switchingTo == nil else { return nil }
        return ruleDecision(now: date)
    }

    /// `automaticDecision` without the busy check: the switch in progress
    /// re-makes its own decision with it after the stability delay.
    private func ruleDecision(now date: Date) -> (decision: ClaudeCodeAutoSwitch.Decision, current: CodexLogin)? {
        guard state.autoSwitchEnabled, state.configurationAcknowledged, !state.autoSwitchPaused, !journalUnresolved,
              !stateSaveFailed, let current, let currentID = state.links[current.id]
        else { return nil }
        let pool: [ClaudeCodeAutoSwitch.Candidate] = candidates.compactMap { candidate in
            guard let id = signInID(linkedTo: candidate.accountID), let signIn = remembered.first(where: { $0.id == id }) else { return nil }
            if id != current.id {
                guard isUsable(signIn, now: date), signIn.login.accountID != current.accountID,
                      !state.staleLogins.contains(id)
                else { return nil }
            }
            return .init(accountID: candidate.accountID, signInUUID: id, verified: isVerified(signIn.login),
                         isPaused: candidate.isPaused, usable: candidate.usable, snapshot: candidate.snapshot,
                         planUnits: candidate.planUnits, order: candidate.order)
        }
        guard let mine = pool.first(where: { $0.accountID == currentID && $0.signInUUID == current.id }) else { return nil }
        return (ClaudeCodeAutoSwitch.decide(current: mine, others: pool, rule: state.rule, policy: .codex, now: date), current)
    }

    /// A decision that is not a switch: the status (always) and the
    /// "no room" notification (once per set of logins).
    private func apply(_ decision: ClaudeCodeAutoSwitch.Decision, current: CodexLogin, now date: Date) {
        switch decision {
        case .none:
            guard state.noRoomNotified != nil || isNoRoomOrWaiting(state.status) else { return }
            state.noRoomNotified = nil
            if isNoRoomOrWaiting(state.status) { state.status = nil }
            queue.enqueue { [weak self] in _ = await self?.persistState() }
        case .waiting:
            guard !isWaiting(state.status) else { return }
            state.status = .waiting(at: date)
            queue.enqueue { [weak self] in _ = await self?.persistState() }
        case .noRoom(_, let set):
            var changed = false
            if !isNoRoom(state.status) {
                state.status = .noRoom(at: date)
                changed = true
            }
            if state.noRoomNotified != set {
                state.noRoomNotified = set
                changed = true
                let stays = displayLabel(forSignIn: current.id)
                notify(id: "codex.noRoom.\(set.joined(separator: ","))",
                       title: { LocalizedStringResource.codexNotificationNoRoomTitle.string(in: .current) },
                       body: { LocalizedStringResource.codexNotificationNoRoomBody(stays).string(in: .current) },
                       redacted: .codexNotificationRedactedNoRoom)
            }
            if changed { queue.enqueue { [weak self] in _ = await self?.persistState() } }
        case .switchTo:
            break
        }
    }

    private func isNoRoom(_ status: CodexStatus?) -> Bool {
        if case .noRoom = status { true } else { false }
    }

    private func isNoRoomOrWaiting(_ status: CodexStatus?) -> Bool {
        switch status { case .noRoom, .waiting: true; default: false }
    }

    private func isWaiting(_ status: CodexStatus?) -> Bool {
        if case .waiting = status { true } else { false }
    }

    // MARK: Actions

    func useInCodex(accountID: UUID) async {
        try? await queue.run { [weak self] in
            guard let self, self.isHydrated, !self.journalUnresolved, !self.isPaused(accountID),
                  let id = self.signInID(linkedTo: accountID)
            else { return }
            await self.performSwitch(to: accountID, signIn: id, expecting: nil, automatic: false, usedPercent: nil)
        }
    }

    func rememberCurrent(linkTo accountID: UUID?) async {
        try? await queue.run { [weak self] in
            guard let self, self.isHydrated else { return }
            let switcher = self.deps.switcher
            let result = await Task.detached {
                Result { try switcher.remember() }
            }.value
            switch result {
            case .success(let signIn):
                if let accountID { self.setLink(signIn.id, to: accountID) }
                self.state.dismissedPrompts.removeAll { $0 == signIn.id }
                // A fresh copy: no longer stale.
                self.state.staleLogins.removeAll { $0 == signIn.id }
                self.lastError = nil
                _ = await self.persistState()
            case .failure(let error):
                self.lastError = error as? CodexSwitcher.Failure ?? .failed
            }
            await self.reload()
        }
    }

    /// The user's choice in Settings. None is kept: the login is not linked
    /// automatically again until the user links it.
    func link(_ id: String, to accountID: UUID?) async {
        guard isHydrated else { return }
        setLink(id, to: accountID)
        if accountID == nil, !state.keptUnlinked.contains(id) { state.keptUnlinked.append(id) }
        _ = await persistState()
    }

    /// One login per Ration account: linking takes the account from any
    /// other login.
    private func setLink(_ id: String, to accountID: UUID?) {
        if let accountID {
            state.links = state.links.filter { $0.value != accountID }
            state.keptUnlinked.removeAll { $0 == id }
        }
        state.links[id] = accountID
    }

    /// Deletes one copy, its link and its prompt (spec §4.7). Not while a
    /// switch needs attention: the copy may be its rollback source.
    func forget(_ id: String) async {
        try? await queue.run { [weak self] in
            guard let self, self.isHydrated, !self.journalUnresolved else { return }
            let store = self.deps.switcher.store
            do {
                try await Task.detached(operation: { try store.delete(id: id) }).value
                self.state.links[id] = nil
                self.state.keptUnlinked.removeAll { $0 == id }
                self.state.dismissedPrompts.removeAll { $0 == id }
                self.state.staleLogins.removeAll { $0 == id }
                _ = await self.persistState()
            } catch {
                self.lastError = .failed
            }
            await self.reload()
        }
    }

    /// Deletes every remembered copy, the links, the status and the switch log;
    /// automatic switching off. Not while a switch needs attention.
    func forgetAll() async {
        try? await queue.run { [weak self] in
            guard let self, self.isHydrated, !self.journalUnresolved else { return }
            let store = self.deps.switcher.store
            // Every item, not only the listed ones: a copy that cannot be read
            // or decoded never made it into `remembered`.
            let failed = await Task.detached { () -> Bool in
                do {
                    try store.deleteAll()
                    return false
                } catch {
                    return true
                }
            }.value
            self.state = CodexState()
            self.lastError = failed ? .failed : nil
            _ = await self.persistState()
            try? await self.deps.logStore.save([])
            await self.reload()
        }
    }

    /// Turning it on is refused — no change, no error — until the user has
    /// acknowledged that Codex uses its default file (spec §4.2).
    func setAutoSwitch(enabled: Bool, rule: ClaudeCodeAutoSwitch.Rule) async {
        guard isHydrated else { return }
        if enabled && !state.configurationAcknowledged { return }
        // Only turning it on lifts a pause; a rule edit is not Resume.
        if enabled && !state.autoSwitchEnabled { state.autoSwitchPaused = false }
        state.autoSwitchEnabled = enabled
        state.rule = rule
        state.noRoomNotified = nil
        // Turned on and saved: the file says what the model does again.
        if await persistState(), enabled, stateSaveFailed { stateSaveFailed = false }
    }

    /// Settings' acknowledgement line. Withdrawn, automatic switching goes off.
    func setConfigurationAcknowledged(_ acknowledged: Bool) async {
        guard isHydrated else { return }
        state.configurationAcknowledged = acknowledged
        if !acknowledged { state.autoSwitchEnabled = false }
        _ = await persistState()
    }

    /// Settings' Resume (after `codex login` when a switch needed attention):
    /// recovery runs again, and the pause and the status clear only once no
    /// journal is left.
    func resumeAutoSwitch() async {
        try? await queue.run { [weak self] in
            guard let self, self.isHydrated else { return }
            let switcher = self.deps.switcher
            let recovery = await Task.detached(operation: { switcher.recoverIfNeeded() }).value
            guard recovery != .needsAttention else {
                if !self.journalUnresolved {
                    self.state.status = .needsAttention(at: self.now())
                    _ = await self.persistState()
                }
                return
            }
            self.state.autoSwitchPaused = false
            switch self.state.status {
            case .failed, .conflict, .paused, .needsAttention, .damaged: self.state.status = nil
            default: break
            }
            _ = await self.persistState()
            await self.reload()
        }
    }

    func setNotify(_ on: Bool) async {
        guard isHydrated else { return }
        state.notify = on
        _ = await persistState()
    }

    func dismissPrompt() async {
        guard isHydrated, let current, !state.dismissedPrompts.contains(current.id) else { return }
        state.dismissedPrompts.append(current.id)
        _ = await persistState()
    }

    /// Spec §4.2: a removed Ration account's login is unlinked, not deleted.
    func accountRemoved(_ accountID: UUID) async {
        guard isHydrated else { return }
        let before = state.links
        state.links = state.links.filter { $0.value != accountID }
        guard state.links != before else { return }
        _ = await persistState()
    }

    // MARK: Switching

    /// (a) the stability check off the main actor; (b) back here, the
    /// decision re-made with what changed during its delay (spec §4.5) — a
    /// changed one aborts quietly: no write, no status; (c) the write, with
    /// the confirmed login as the one left.
    private func performSwitch(to accountID: UUID, signIn id: String, expecting: String?, automatic: Bool, usedPercent: Int?) async {
        switchingTo = accountID
        let switcher = deps.switcher
        let confirmation = await Task.detached { Result { try switcher.confirmedLogin() } }.value
        var expecting = expecting
        var usedPercent = usedPercent
        let result: Result<CodexSwitcher.Outcome, any Error>
        switch confirmation {
        case .failure(let error):
            result = .failure(error)
        case .success(let confirmed):
            if automatic {
                guard let fresh = ruleDecision(now: now()),
                      case .switchTo(let freshID, let freshAccount, let freshUsed) = fresh.decision,
                      freshID == id, freshAccount == accountID
                else {
                    switchingTo = nil
                    return
                }
                expecting = fresh.current.id
                usedPercent = freshUsed
            } else {
                guard isHydrated, !journalUnresolved, !isPaused(accountID), signInID(linkedTo: accountID) == id else {
                    switchingTo = nil
                    return
                }
            }
            let expected = expecting
            result = await Task.detached {
                Result { try switcher.switchTo(accountID: id, allowUnremembered: false, expecting: expected, confirmed: confirmed) }
            }.value
        }
        let at = now()
        switch result {
        case .success(.alreadyActive):
            break
        case .success(.switched(let from, let to)), .success(.switchedUnverified(let from, let to)):
            // Unverified: Codex refreshed the target meanwhile.
            let verified = if case .success(.switched) = result { true } else { false }
            // Another seat of the same workspace: running sessions may follow.
            state.status = .switched(at: at, from: from.id, to: to.id, automatic: automatic, verified: verified,
                                     sameWorkspace: from.accountID == to.accountID)
            state.noRoomNotified = nil
            state.lastSwitchTo = to.id
            state.lastSwitchAt = at
            lastError = nil
            _ = await persistState()
            let entries = (try? await deps.logStore.load()) ?? []
            try? await deps.logStore.save(CodexSwitchLogEntry.appending(
                .init(at: at, from: from.id, to: to.id, automatic: automatic, rule: automatic ? state.rule : nil), to: entries))
            if automatic, let usedPercent {
                let toLabel = displayLabel(forSignIn: to.id)
                let fromLabel = displayLabel(forSignIn: from.id)
                notify(id: "codex.switched.\(Int(at.timeIntervalSince1970))",
                       title: { LocalizedStringResource.codexNotificationSwitchedTitle(toLabel).string(in: .current) },
                       body: { LocalizedStringResource.codexNotificationSwitchedBody(fromLabel, usedPercent).string(in: .current) },
                       redacted: .codexNotificationRedactedBody)
            }
        case .failure(let error):
            let failure = error as? CodexSwitcher.Failure ?? .failed
            if automatic, failure == .signInChanging {
                // Superseded: Codex moved to another login meanwhile. Not a
                // failure; the next pass decides for the new login.
                break
            }
            lastError = failure
            state.lastSwitchTo = nil
            state.lastSwitchAt = nil
            switch failure {
            case .conflict: state.status = .conflict(at: at)
            case .needsAttention, .journalUnresolved: state.status = .needsAttention(at: at)
            case .damaged:
                state.status = .damaged(at: at)
                state.autoSwitchPaused = true
            default: state.status = .failed(at: at)
            }
            if automatic {
                state.autoSwitchPaused = true
                notify(id: "codex.failed.\(Int(at.timeIntervalSince1970))",
                       title: { LocalizedStringResource.codexNotificationFailedTitle.string(in: .current) },
                       body: { LocalizedStringResource.codexNotificationFailedBody.string(in: .current) },
                       redacted: .codexNotificationRedactedFailed)
            }
            if !(await persistState()), automatic {
                // The pause is not durable: fail closed.
                state.autoSwitchEnabled = false
            }
        }
        switchingTo = nil
        await reload()
    }

    // MARK: Persistence and notifications

    /// Never before `start()` has loaded the state: that write would put an
    /// unloaded (default) state over the saved one.
    @discardableResult
    private func persistState() async -> Bool {
        guard isHydrated else { return false }
        do {
            try await deps.stateStore.save(state)
            return true
        } catch {
            stateSaveFailed = true
            return false
        }
    }

    /// Through Ration's alerts gate (master switch, authorization); the
    /// feature's own toggle first. `redacted`: the event's own body when
    /// details are hidden — it names no account and never announces a
    /// switch that did not happen.
    private func notify(id: String, title: @escaping @MainActor () -> String, body: @escaping @MainActor () -> String,
                        redacted redactedBody: LocalizedStringResource) {
        guard state.notify, let bridge else { return }
        let post = ExternalAlertPost(id: id, stillValid: { true }, render: { redacted in
            redacted
                ? ("Ration", redactedBody.string(in: .current))
                : (title(), body())
        })
        bridge.enqueueExternalAlertDecision(persist: { .written }, posts: [post])
    }
}
