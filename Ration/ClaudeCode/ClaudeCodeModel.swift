import Foundation

/// A Claude account as `AppModel` sees it after a refresh.
struct ClaudeCodeCandidate: Equatable, Sendable {
    let accountID: UUID
    let label: String
    /// From the latest snapshot (memory only, after its first fetch).
    let organizationID: String?
    let isPaused: Bool
    let usable: Bool
    let snapshot: UsageSnapshot?
    let planUnits: Int?
    let order: Int
}

enum ClaudeCodeCardState: Equatable, Sendable { case none, current, canSwitch, switching }

/// Told about every attempt to write Claude Code's sign-in (token burn: a
/// Ration write is evidence, spec §10.1). `willWrite` is awaited before the
/// write; every `willWrite` is followed by one `didWrite`, with the time
/// when the attempt may have written (successful or not), nil when it
/// wrote nothing.
@MainActor
protocol ClaudeCodeWriteObserver: AnyObject {
    func claudeCodeWillWrite() async
    func claudeCodeDidWrite(at date: Date?) async
}

/// The Focus layout's Claude Code line: the account Claude Code uses, and
/// the account a click switches it to.
struct ClaudeCodeFocusLine: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        let accountID: UUID
        let label: String
    }

    let currentLabel: String
    /// The switchable account with the most room; nil when none can take over.
    let target: Target?
}

struct RememberedSignIn: Equatable, Sendable, Identifiable {
    let account: ClaudeCodeAccount
    let savedAt: Date
    let linkedAccountID: UUID?
    /// The link is proven by the organization id (spec §4.2), not only chosen.
    let verified: Bool
    var id: String { account.uuid }
}

/// Claude Code account switching (spec §4): state, one operation at a time,
/// the automatic rule, status and notifications. Switcher work runs off the
/// main actor; every request goes through one serial queue, claimed before
/// its first await.
@MainActor
final class ClaudeCodeModel: ObservableObject {
    struct Dependencies: Sendable {
        let switcher: ClaudeCodeSwitcher
        let stateStore: JSONFileStore<ClaudeCodeState>
        let logStore: JSONFileStore<[ClaudeCodeSwitchLogEntry]>
    }

    @Published private(set) var current: ClaudeCodeAccount?
    @Published private(set) var remembered: [ClaudeCodeSignIn] = []
    @Published private(set) var state = ClaudeCodeState()
    @Published private(set) var switchingTo: UUID?
    @Published private(set) var lastError: ClaudeCodeSwitcher.Failure?
    @Published private(set) var candidates: [ClaudeCodeCandidate] = []
    /// The feature's state file could not be written; automatic switching is
    /// then off (fails closed) until it can.
    @Published private(set) var stateSaveFailed = false
    weak var bridge: AlertDeliveryBridge?
    weak var writeObserver: (any ClaudeCodeWriteObserver)?

    private let deps: Dependencies
    private let now: () -> Date
    private let queue = SerializedMutationQueue()
    private var lastConfigDate: Date?
    private var lastCopyRefresh: Date?
    private var automaticPending = false

    /// How often Ration re-saves Claude Code's current sign-in when renewed.
    static let copyRefreshInterval: TimeInterval = 600

    init(dependencies: Dependencies, now: @escaping () -> Date = { .now }) {
        self.deps = dependencies
        self.now = now
    }

    /// The real stack: `/usr/bin/security`, the user's own `~/.claude.json`
    /// (the sandbox's home is the container, so the real one comes from the
    /// user database), Ration's Keychain items, state files in `stateDirectory`.
    static func live(stateDirectory: URL) -> ClaudeCodeModel {
        // Claude Code names its item's account after $USER, else the login name.
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return ClaudeCodeModel(dependencies: .init(
            switcher: ClaudeCodeSwitcher(
                entry: ClaudeCodeKeychainEntry(tool: SystemSecurityTool(), user: user),
                config: ClaudeCodeConfigFile(url: ClaudeCodeConfigFile.userConfigURL),
                store: KeychainClaudeCodeSignInStore(),
                journal: ClaudeCodeJournalFile(url: stateDirectory.appending(path: "claude-code-switch-journal.json")),
                now: { .now }),
            stateStore: JSONFileStore(fileURL: stateDirectory.appending(path: "claude-code-switch.json"), defaultValue: ClaudeCodeState()),
            logStore: JSONFileStore(fileURL: stateDirectory.appending(path: ClaudeCodeSwitchLogEntry.fileName), defaultValue: [])))
    }

    // MARK: Derived

    var signIns: [RememberedSignIn] {
        remembered.map {
            RememberedSignIn(account: $0.account, savedAt: $0.savedAt, linkedAccountID: state.links[$0.uuid], verified: isVerified($0.account))
        }
    }

    var isSwitching: Bool { switchingTo != nil }

    /// Claude Code is on an account Ration has not remembered — offered once
    /// the feature is in use (at least one sign-in remembered).
    var rememberPrompt: ClaudeCodeAccount? {
        guard let current, !remembered.isEmpty, !remembered.contains(where: { $0.uuid == current.uuid }),
              !state.dismissedPrompts.contains(current.uuid)
        else { return nil }
        return current
    }

    func cardState(for accountID: UUID) -> ClaudeCodeCardState {
        guard let uuid = signInUUID(linkedTo: accountID), !isPaused(accountID) else { return .none }
        if switchingTo == accountID { return .switching }
        return uuid == current?.uuid ? .current : .canSwitch
    }

    /// Verified: the linked account's snapshot reports the sign-in's
    /// organization, and no other linked account shares it (Team seats).
    func isVerified(_ account: ClaudeCodeAccount) -> Bool {
        guard let accountID = state.links[account.uuid], let organization = account.organizationUUID,
              candidates.first(where: { $0.accountID == accountID })?.organizationID == organization
        else { return false }
        let sharing = Set(state.links.values).filter { id in candidates.first { $0.accountID == id }?.organizationID == organization }
        return sharing.count == 1
    }

    /// Spec §4.2: an unlinked remembered sign-in links itself when exactly one
    /// Claude account reports its organization, that account is free, and no
    /// other remembered sign-in shares the organization (Team seats: the
    /// organization cannot tell which seat the account is). Never one the
    /// user set to None.
    private func linkUnlinkedSignIns() {
        var changed = false
        for signIn in remembered where state.links[signIn.uuid] == nil && !state.keptUnlinked.contains(signIn.uuid) {
            guard let organization = signIn.account.organizationUUID,
                  remembered.filter({ $0.account.organizationUUID == organization }).count == 1
            else { continue }
            let matches = candidates.filter { $0.organizationID == organization }
            guard matches.count == 1, !state.links.values.contains(matches[0].accountID) else { continue }
            state.links[signIn.uuid] = matches[0].accountID
            changed = true
        }
        if changed { queue.enqueue { [weak self] in _ = await self?.persistState() } }
    }

    private func isPaused(_ accountID: UUID) -> Bool {
        candidates.first { $0.accountID == accountID }?.isPaused ?? false
    }

    private func signInUUID(linkedTo accountID: UUID) -> String? {
        state.links.filter { $0.value == accountID }.keys.sorted().first { uuid in remembered.contains { $0.uuid == uuid } }
    }

    /// Shown once the feature is in use (a sign-in remembered) and Claude
    /// Code is signed in. The target is a card that offers a switch, whose
    /// usage is current on every limit the rule considers, ranked by its
    /// tightest one: the switch the automatic rule could make, offered early.
    /// None while Claude Code's own sign-in is not remembered: leaving it by
    /// hand is refused, and Focus has no status line to say why.
    func focusLine(now date: Date) -> ClaudeCodeFocusLine? {
        guard let current, !remembered.isEmpty else { return nil }
        guard remembered.contains(where: { $0.uuid == current.uuid }) else {
            return ClaudeCodeFocusLine(currentLabel: displayLabel(forSignIn: current.uuid), target: nil)
        }
        let kinds = ClaudeCodeAutoSwitch.consideredKinds(for: state.rule)
        let rooms: [(candidate: ClaudeCodeCandidate, room: Double)] = candidates.compactMap { candidate in
            guard cardState(for: candidate.accountID) == .canSwitch, candidate.usable, let snapshot = candidate.snapshot else { return nil }
            let standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: date)
            guard !standing.hasUnknown, standing.known.count == kinds.count,
                  let room = standing.known.map(\.window.remainingFraction).min(), room > 0
            else { return nil }
            return (candidate, room)
        }
        let best = rooms.min { $0.room != $1.room ? $0.room > $1.room : $0.candidate.order < $1.candidate.order }
        return ClaudeCodeFocusLine(currentLabel: displayLabel(forSignIn: current.uuid),
                                   target: best.map { .init(accountID: $0.candidate.accountID, label: $0.candidate.label) })
    }

    /// The Ration label of a sign-in, else its organization name.
    func displayLabel(forSignIn uuid: String) -> String {
        if let id = state.links[uuid], let candidate = candidates.first(where: { $0.accountID == id }) { return candidate.label }
        return remembered.first { $0.uuid == uuid }?.account.organizationName ?? current?.organizationName ?? uuid
    }

    // MARK: Lifecycle

    func start() async {
        state = (try? await deps.stateStore.load()) ?? ClaudeCodeState()
        let switcher = deps.switcher
        await writeObserver?.claudeCodeWillWrite()
        let recovery = await Task.detached(operation: { switcher.recoverIfNeeded() }).value
        await writeObserver?.claudeCodeDidWrite(at: recovery == .none ? nil : now())
        switch recovery {
        case .needsAttention:
            state.status = .needsAttention(at: now())
            _ = await persistState()
        case .restored:
            state.status = .failed(at: now())
            _ = await persistState()
        case .none, .completed:
            break
        }
        await reload()
    }

    func reload() async {
        let switcher = deps.switcher
        let (account, signIns) = await Task.detached { () -> (ClaudeCodeAccount?, [ClaudeCodeSignIn]) in
            let bytes = (try? switcher.config.readBytes()) ?? nil
            return (bytes.flatMap { try? ClaudeCodeConfig.account(in: $0) }, (try? switcher.store.all()) ?? [])
        }.value
        if current != account { current = account }
        if remembered != signIns { remembered = signIns }
        lastConfigDate = switcher.config.modificationDate()
    }

    /// Test and quit support: waits for queued operations.
    func waitUntilIdle() async {
        try? await queue.run {}
    }

    // MARK: Usage (from AppModel's snapshot/state sink)

    func usageDidChange(_ candidates: [ClaudeCodeCandidate], now date: Date) {
        if candidates != self.candidates { self.candidates = candidates }
        linkUnlinkedSignIns()
        let configDate = deps.switcher.config.modificationDate()
        if configDate != lastConfigDate, switchingTo == nil {
            // Claude Code may have signed in to another account: decide only
            // after the settings are read again (a decision for the old
            // account would fail and pause automatic switching for nothing).
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
            // Re-decided at write time: the target may have filled up, gone
            // stale, been paused or unlinked while this waited.
            let at = self.now()
            guard let fresh = self.automaticDecision(now: at) else { return }
            if case .switchTo(let uuid, let accountID, let usedPercent) = fresh.decision {
                await self.performSwitch(to: accountID, signIn: uuid, expecting: fresh.current.uuid,
                                         automatic: true, usedPercent: usedPercent)
            } else {
                self.apply(fresh.decision, current: fresh.current, now: at)
            }
        }
    }

    /// The rule's decision for the account Claude Code uses now, or nil when
    /// automatic switching cannot act (off, paused, busy, unlinked, unknown).
    private func automaticDecision(now date: Date) -> (decision: ClaudeCodeAutoSwitch.Decision, current: ClaudeCodeAccount)? {
        guard state.autoSwitchEnabled, !state.autoSwitchPaused, switchingTo == nil,
              let current, let currentID = state.links[current.uuid]
        else { return nil }
        let pool: [ClaudeCodeAutoSwitch.Candidate] = candidates.compactMap { candidate in
            guard let uuid = signInUUID(linkedTo: candidate.accountID), let signIn = remembered.first(where: { $0.uuid == uuid }) else { return nil }
            return .init(accountID: candidate.accountID, signInUUID: uuid, verified: isVerified(signIn.account),
                         isPaused: candidate.isPaused, usable: candidate.usable, snapshot: candidate.snapshot,
                         planUnits: candidate.planUnits, order: candidate.order)
        }
        guard let mine = pool.first(where: { $0.accountID == currentID && $0.signInUUID == current.uuid }) else { return nil }
        return (ClaudeCodeAutoSwitch.decide(current: mine, others: pool, rule: state.rule, now: date), current)
    }

    /// A decision that is not a switch: the status (always) and the
    /// "no room" notification (once per set of accounts).
    private func apply(_ decision: ClaudeCodeAutoSwitch.Decision, current: ClaudeCodeAccount, now date: Date) {
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
                let stays = displayLabel(forSignIn: current.uuid)
                notify(id: "claudeCode.noRoom.\(set.joined(separator: ","))",
                       title: { LocalizedStringResource.claudeCodeNotificationNoRoomTitle.string(in: .current) },
                       body: { LocalizedStringResource.claudeCodeNotificationNoRoomBody(stays).string(in: .current) })
            }
            if changed { queue.enqueue { [weak self] in _ = await self?.persistState() } }
        case .switchTo:
            break
        }
    }

    private func isNoRoom(_ status: ClaudeCodeStatus?) -> Bool {
        if case .noRoom = status { true } else { false }
    }

    private func isNoRoomOrWaiting(_ status: ClaudeCodeStatus?) -> Bool {
        switch status { case .noRoom, .waiting: true; default: false }
    }

    private func isWaiting(_ status: ClaudeCodeStatus?) -> Bool {
        if case .waiting = status { true } else { false }
    }

    // MARK: Actions

    func useInClaudeCode(accountID: UUID) async {
        try? await queue.run { [weak self] in
            guard let self, !self.isPaused(accountID), let uuid = self.signInUUID(linkedTo: accountID) else { return }
            await self.performSwitch(to: accountID, signIn: uuid, expecting: nil, automatic: false, usedPercent: nil)
        }
    }

    func rememberCurrent(linkTo accountID: UUID?) async {
        try? await queue.run { [weak self] in
            guard let self else { return }
            let switcher = self.deps.switcher
            let result = await Task.detached {
                Result { try switcher.remember() }
            }.value
            switch result {
            case .success(let pair):
                if let accountID { self.setLink(pair.uuid, to: accountID) }
                self.state.dismissedPrompts.removeAll { $0 == pair.uuid }
                self.lastError = nil
                _ = await self.persistState()
            case .failure(let error):
                self.lastError = error as? ClaudeCodeSwitcher.Failure ?? .failed
            }
            await self.reload()
        }
    }

    /// The user's choice in Settings. None is kept: the sign-in is not linked
    /// automatically again until the user links it.
    func link(_ uuid: String, to accountID: UUID?) async {
        setLink(uuid, to: accountID)
        if accountID == nil, !state.keptUnlinked.contains(uuid) { state.keptUnlinked.append(uuid) }
        _ = await persistState()
    }

    /// One sign-in per Ration account: linking takes the account from any
    /// other sign-in.
    private func setLink(_ uuid: String, to accountID: UUID?) {
        if let accountID {
            state.links = state.links.filter { $0.value != accountID }
            state.keptUnlinked.removeAll { $0 == uuid }
        }
        state.links[uuid] = accountID
    }

    func forget(_ uuid: String) async {
        try? await queue.run { [weak self] in
            guard let self else { return }
            let store = self.deps.switcher.store
            do {
                try await Task.detached(operation: { try store.delete(accountUUID: uuid) }).value
                self.state.links[uuid] = nil
                self.state.keptUnlinked.removeAll { $0 == uuid }
                _ = await self.persistState()
            } catch {
                self.lastError = .failed
            }
            await self.reload()
        }
    }

    /// Deletes every remembered copy, the links, the status and the switch log;
    /// automatic switching off.
    func forgetAll() async {
        try? await queue.run { [weak self] in
            guard let self else { return }
            let store = self.deps.switcher.store
            let uuids = self.remembered.map(\.uuid)
            let failed = await Task.detached { () -> Bool in
                var failed = false
                for uuid in uuids { do { try store.delete(accountUUID: uuid) } catch { failed = true } }
                return failed
            }.value
            self.state = ClaudeCodeState()
            self.lastError = failed ? .failed : nil
            _ = await self.persistState()
            try? await self.deps.logStore.save([])
            await self.reload()
        }
    }

    func setAutoSwitch(enabled: Bool, rule: ClaudeCodeAutoSwitch.Rule) async {
        // Only turning it on lifts a pause; a rule edit is not Resume.
        if enabled && !state.autoSwitchEnabled { state.autoSwitchPaused = false }
        state.autoSwitchEnabled = enabled
        state.rule = rule
        state.noRoomNotified = nil
        _ = await persistState()
    }

    func resumeAutoSwitch() async {
        state.autoSwitchPaused = false
        switch state.status {
        case .failed, .conflict, .paused, .needsAttention: state.status = nil
        default: break
        }
        _ = await persistState()
    }

    func setNotify(_ on: Bool) async {
        state.notify = on
        _ = await persistState()
    }

    func dismissPrompt() async {
        guard let current, !state.dismissedPrompts.contains(current.uuid) else { return }
        state.dismissedPrompts.append(current.uuid)
        _ = await persistState()
    }

    /// Spec §4.2: a removed Ration account's sign-in is unlinked, not deleted.
    func accountRemoved(_ accountID: UUID) async {
        let before = state.links
        state.links = state.links.filter { $0.value != accountID }
        guard state.links != before else { return }
        _ = await persistState()
    }

    // MARK: Switching

    private func performSwitch(to accountID: UUID, signIn uuid: String, expecting: String?, automatic: Bool, usedPercent: Int?) async {
        switchingTo = accountID
        let switcher = deps.switcher
        await writeObserver?.claudeCodeWillWrite()
        let result = await Task.detached {
            Result { try switcher.switchTo(accountUUID: uuid, allowUnremembered: false, expecting: expecting) }
        }.value
        let at = now()
        await writeObserver?.claudeCodeDidWrite(at: at)
        switch result {
        case .success(.alreadyActive):
            break
        case .success(.switched(let from, let to)):
            state.status = .switched(at: at, from: from.uuid, to: to.uuid, automatic: automatic)
            state.noRoomNotified = nil
            lastError = nil
            _ = await persistState()
            let entries = (try? await deps.logStore.load()) ?? []
            try? await deps.logStore.save(ClaudeCodeSwitchLogEntry.appending(
                .init(at: at, from: from.uuid, to: to.uuid, automatic: automatic, rule: automatic ? state.rule : nil), to: entries))
            if automatic, let usedPercent {
                let toLabel = displayLabel(forSignIn: to.uuid)
                let fromLabel = displayLabel(forSignIn: from.uuid)
                let kind = state.rule.kind
                notify(id: "claudeCode.switched.\(Int(at.timeIntervalSince1970))",
                       title: { LocalizedStringResource.claudeCodeNotificationSwitchedTitle(toLabel).string(in: .current) },
                       body: { Self.switchedBody(from: fromLabel, percent: usedPercent, kind: kind) })
            }
        case .failure(let error):
            let failure = error as? ClaudeCodeSwitcher.Failure ?? .failed
            if automatic, failure == .signInChanging {
                // Superseded: Claude Code moved to another account meanwhile.
                // Not a failure; the next pass decides for the new account.
                break
            }
            lastError = failure
            switch failure {
            case .conflict: state.status = .conflict(at: at)
            case .needsAttention, .unverified: state.status = .needsAttention(at: at)
            default: state.status = .failed(at: at)
            }
            if automatic {
                state.autoSwitchPaused = true
                notify(id: "claudeCode.failed.\(Int(at.timeIntervalSince1970))",
                       title: { LocalizedStringResource.claudeCodeNotificationFailedTitle.string(in: .current) },
                       body: { LocalizedStringResource.claudeCodeNotificationFailedBody.string(in: .current) })
            }
            if !(await persistState()), automatic {
                // The pause is not durable: fail closed.
                state.autoSwitchEnabled = false
            }
        }
        switchingTo = nil
        await reload()
    }

    static func switchedBody(from label: String, percent: Int, kind: UsageWindowKind) -> String {
        switch kind {
        case .weekly: LocalizedStringResource.claudeCodeNotificationSwitchedBodyWeekly(label, percent).string(in: .current)
        case .fiveHour: LocalizedStringResource.claudeCodeNotificationSwitchedBodyFiveHour(label, percent).string(in: .current)
        case .modelWeekly: LocalizedStringResource.claudeCodeNotificationSwitchedBodyFable(label, percent).string(in: .current)
        }
    }

    // MARK: Persistence and notifications

    @discardableResult
    private func persistState() async -> Bool {
        do {
            try await deps.stateStore.save(state)
            if stateSaveFailed { stateSaveFailed = false }
            return true
        } catch {
            stateSaveFailed = true
            return false
        }
    }

    /// Through Ration's alerts gate (master switch, authorization); the
    /// feature's own toggle first. Redacted copy names no account.
    private func notify(id: String, title: @escaping @MainActor () -> String, body: @escaping @MainActor () -> String) {
        guard state.notify, let bridge else { return }
        let post = ExternalAlertPost(id: id, stillValid: { true }, render: { redacted in
            redacted
                ? ("Ration", LocalizedStringResource.claudeCodeNotificationRedactedBody.string(in: .current))
                : (title(), body())
        })
        bridge.enqueueExternalAlertDecision(persist: { .written }, posts: [post])
    }
}
