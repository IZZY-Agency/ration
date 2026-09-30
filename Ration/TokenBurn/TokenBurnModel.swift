import Foundation
import os

/// A Ration Claude account as token burn needs it.
struct TokenBurnAccount: Equatable, Sendable {
    let id: UUID
    let label: String
    /// Resolved from its web session; nil until its first fetch.
    let organizationID: String?
    /// Its organization's own rate-limit tier says Pro, Max 5x or Max 20x: a
    /// personal plan, one seat (spec §10.1).
    let personalPlanDetected: Bool
    /// The plan Ration shows (detected or set); prices the ratio.
    let plan: PlanTier?
    let renewalDay: Int?
}

/// "Claude plan value" (spec §4–§5, §10): the grant, readings of Claude
/// Code's sign-in every minute, log counting every five, attribution, and
/// Stop and forget. Off until the user consents and grants the folder;
/// nothing is opened before that.
@MainActor
final class TokenBurnModel: ObservableObject, ClaudeCodeWriteObserver {
    enum Phase: Equatable, Sendable {
        case off
        case counting(done: Int, total: Int)
        case ready
        /// The folder grant no longer resolves, or the folder is gone.
        case grantLost
        case failed
    }

    struct Dependencies: Sendable {
        let folderAccess: any TokenBurnFolderAccess
        let settings: JSONFileStore<TokenBurnSettings>
        let databaseURL: URL
        /// The sign-in fields token burn keeps; nil when signed out.
        let readSignIn: @Sendable () -> (identity: SignInIdentity, fetchedAt: Date?)?
        /// When the switcher's log says it switched (whole seconds).
        var loadSwitchTimes: @Sendable () async -> [Date] = { [] }
        var scanInterval: TimeInterval = 300
        var readingInterval: TimeInterval = 60
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var summary: TokenBurnStore.Summary?
    @Published private(set) var lastReport: TokenBurnScanner.Report?
    @Published private(set) var countedThrough: Date?
    /// The granted folder's own name, for Settings; the path is never kept.
    @Published private(set) var folderName: String?
    @Published private(set) var values: [UUID: TokenBurnAccountValues] = [:]
    /// Everything not on an account, over the days History shows.
    @Published private(set) var pooled: [TokenBurnOwner: PlanValue] = [:]
    /// History's days for the chosen period, up to today.
    @Published private(set) var days: [TokenBurnDay] = []
    /// All Claude Code use in the period, on an account or not.
    @Published private(set) var total: PlanValue?
    /// Where per-account figures begin: Ration's first proven reading.
    @Published private(set) var trackingSince: Date?
    /// What the figures cover; kept in `token-burn.json`.
    @Published private(set) var period: TokenBurnPeriod.Choice = .last30Days
    /// Why the last attempt to turn it on did not (spec §6); nil after one
    /// that did.
    @Published private(set) var enableProblem: EnableProblem?

    enum EnableProblem: Equatable, Sendable {
        /// `~/.claude.json` names no Claude Code sign-in: nothing to count.
        case noSignIn
        /// The folder could not be kept, or the store could not open.
        case failed
    }

    /// The switcher's links (Claude account uuid → Ration account).
    var linksProvider: @MainActor () -> [String: UUID] = { [:] }

    private let deps: Dependencies
    private let now: () -> Date
    private let lifecycle = SerializedMutationQueue()
    /// Readings and the switcher's writes, recorded in the order they
    /// happened, each with the time it happened: the store may be busy
    /// counting logs, and nobody waits for that.
    private let recorder = SerializedMutationQueue()
    private var scanner: TokenBurnScanner?
    private var folder: URL?
    private var loop: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var lastScan: Date?
    /// The Ration Claude accounts from the latest refresh.
    private(set) var accounts: [TokenBurnAccount] = []
    /// Every account seen, kept after a refresh drops it: removal runs after
    /// the refresh that left it out and still needs its plan to know which
    /// sign-in was its.
    private var lastKnown: [UUID: TokenBurnAccount] = [:]
    /// Figures are computed one at a time, so the last one queued (with the
    /// latest period) is the one left showing.
    private let publisher = SerializedMutationQueue()
    /// The switcher's writes before the store is open (launch recovery runs
    /// before token burn starts).
    private var pendingWrites: [Date] = []
    /// Sign-in readings in flight, and switcher writes under way. A reading
    /// that overlapped a write could see the new account stamped before the
    /// switch: a write waits for the readings in flight,
    /// and none starts until it is done.
    private var readingsInFlight: [UUID: Task<Bool, Never>] = [:]
    private var writesUnderWay = 0
    /// Bumped by Stop and forget; work that started under an older one
    /// publishes and writes nothing.
    private var generation = 0

    static let log = Logger(subsystem: "agency.izzy.ration", category: "token-burn")

    init(dependencies: Dependencies, now: @escaping () -> Date = { .now }) {
        self.deps = dependencies
        self.now = now
    }

    /// The real stack: security-scoped bookmarks, the user's `~/.claude.json`
    /// (through the switcher's file access; only the four fields are kept),
    /// the store and settings in `directory`, the switcher's log beside them.
    static func live(directory: URL) -> TokenBurnModel {
        let config = ClaudeCodeConfigFile(url: ClaudeCodeConfigFile.userConfigURL)
        let switchLog = JSONFileStore(fileURL: directory.appending(path: ClaudeCodeSwitchLogEntry.fileName),
                                      defaultValue: [ClaudeCodeSwitchLogEntry]())
        return TokenBurnModel(dependencies: .init(
            folderAccess: SecurityScopedFolderAccess(),
            settings: JSONFileStore(fileURL: directory.appending(path: "token-burn.json"), defaultValue: TokenBurnSettings()),
            databaseURL: directory.appending(path: "token-burn.sqlite"),
            readSignIn: { Self.signIn(from: config) },
            loadSwitchTimes: { ((try? await switchLog.load()) ?? []).map(\.at) }))
    }

    /// The sign-in fields token burn keeps, from Claude Code's config.
    nonisolated static func signIn(from config: some ClaudeCodeConfigAccess) -> (identity: SignInIdentity, fetchedAt: Date?)? {
        guard let bytes = try? config.readBytes(), let account = try? ClaudeCodeConfig.account(in: bytes) else { return nil }
        let identity = SignInIdentity(accountUUID: account.uuid, organizationUUID: account.organizationUUID,
                                      billingType: account.billingType)
        return (identity, account.profileFetchedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    var isEnabled: Bool { phase != .off }

    // MARK: Lifecycle (one at a time: spec §10.1)

    /// At launch: carries on when the feature is on.
    func start() async {
        try? await lifecycle.run { [weak self] in await self?.startBody() }
    }

    /// After consent and the open panel. False when the grant cannot be kept.
    func enable(folder url: URL) async -> Bool {
        var result = false
        try? await lifecycle.run { [weak self] in result = await self?.enableBody(url) ?? false }
        return result
    }

    /// Quit: stops counting, keeps everything.
    func stop() async {
        try? await lifecycle.run { [weak self] in await self?.stopBody() }
    }

    /// Spec §5.5: a write barrier, then the delete. Nothing counted, no grant
    /// and no settings survive; a pass still running is cancelled and awaited
    /// and the store closed first, so no late write can recreate it.
    func stopAndForget() async -> Bool {
        var result = false
        try? await lifecycle.run { [weak self] in result = await self?.forgetBody() ?? false }
        return result
    }

    /// The period every figure covers. Only while on (the
    /// row is hidden otherwise), after any lifecycle step, so it can never
    /// write settings back over Stop and forget.
    func setPeriod(_ choice: TokenBurnPeriod.Choice) async {
        try? await lifecycle.run { [weak self] in await self?.setPeriodBody(choice) }
    }

    private func setPeriodBody(_ choice: TokenBurnPeriod.Choice) async {
        guard isEnabled, var settings = try? await deps.settings.load(), settings.enabled else { return }
        settings.period = choice
        guard (try? await deps.settings.save(settings)) != nil else { return }
        period = choice
        await publish()
    }

    private func startBody() async {
        let settings = (try? await deps.settings.load()) ?? TokenBurnSettings()
        period = settings.period
        guard settings.enabled, let bookmark = settings.bookmark else {
            pendingWrites = []
            return
        }
        guard openStore() else { return }
        let access = deps.folderAccess
        guard let resolved = try? access.resolve(bookmark), access.startAccessing(resolved.url) else {
            phase = .grantLost
            Self.log.info("grant did not resolve")
            await publish()
            return
        }
        let url = resolved.url
        // A stale bookmark is replaced before counting; one that
        // cannot be replaced asks for the folder again, keeping the counts.
        if resolved.isStale {
            var renewed = settings
            guard let fresh = try? access.bookmark(for: url) else {
                access.stopAccessing(url)
                phase = .grantLost
                Self.log.info("stale grant could not be renewed")
                await publish()
                return
            }
            renewed.bookmark = fresh
            guard (try? await deps.settings.save(renewed)) != nil else {
                access.stopAccessing(url)
                phase = .grantLost
                await publish()
                return
            }
            Self.log.info("stale grant renewed")
        }
        folder = url
        folderName = url.lastPathComponent
        phase = .ready
        startLoop()
    }

    private func enableBody(_ url: URL) async -> Bool {
        // After consent (which names ~/.claude.json), before anything is
        // kept: no sign-in, nothing to count (spec §6).
        let reader = deps.readSignIn
        guard await Task.detached(priority: .userInitiated, operation: { reader() }).value != nil else {
            enableProblem = .noSignIn
            return false
        }
        let access = deps.folderAccess
        guard let bookmark = try? access.bookmark(for: url), let resolved = try? access.resolve(bookmark).url,
              access.startAccessing(resolved)
        else {
            enableProblem = .failed
            return false
        }
        var settings = TokenBurnSettings()
        settings.period = period
        settings.enabled = true
        settings.bookmark = bookmark
        settings.grantedAt = now()
        do { try await deps.settings.save(settings) } catch {
            access.stopAccessing(resolved)
            enableProblem = .failed
            return false
        }
        if let folder { access.stopAccessing(folder) }
        folder = resolved
        folderName = resolved.lastPathComponent
        guard openStore() else {
            enableProblem = .failed
            return false
        }
        enableProblem = nil
        phase = .ready
        lastScan = nil
        startLoop()
        return true
    }

    private func stopBody() async {
        loop?.cancel()
        loop = nil
        running?.cancel()
        await running?.value
        if let folder { deps.folderAccess.stopAccessing(folder) }
        folder = nil
        // Readings and writes already heard are kept (after Stop and forget
        // the generation drops them).
        try? await recorder.run {}
        await scanner?.close()
        scanner = nil
    }

    private func forgetBody() async -> Bool {
        generation += 1
        await stopBody()
        phase = .off
        summary = nil
        lastReport = nil
        countedThrough = nil
        folderName = nil
        values = [:]
        pooled = [:]
        days = []
        total = nil
        trackingSince = nil
        period = .last30Days
        enableProblem = nil
        pendingWrites = []
        do {
            try TokenBurnStore.destroy(at: deps.databaseURL)
            try await deps.settings.save(TokenBurnSettings())
            Self.log.info("stopped and forgot")
            return true
        } catch {
            phase = .failed
            return false
        }
    }

    /// False (and `.failed`) when the store cannot open: nothing is counted
    /// and nothing claims to be ready.
    @discardableResult
    private func openStore() -> Bool {
        if scanner != nil { return true }
        scanner = try? TokenBurnScanner(databaseURL: deps.databaseURL)
        guard let scanner else {
            phase = .failed
            Self.log.error("store did not open")
            return false
        }
        let writes = pendingWrites
        pendingWrites = []
        let loadSwitchTimes = deps.loadSwitchTimes
        // Before any reading: switches made while this was off bound the
        // first span (a switch writes an older P).
        recorder.enqueue {
            for write in writes { try? await scanner.recordConfigWrite(at: write) }
            for switched in await loadSwitchTimes() { try? await scanner.recordLoggedSwitch(at: switched) }
        }
        return true
    }

    // MARK: Passes

    /// The loop's step: a reading every time; the logs when a scan is due.
    func tick() async {
        if let lastScan, now().timeIntervalSince(lastScan) < deps.scanInterval {
            await reading()
            await publishAfterRecording()
        } else {
            await scanNow()
        }
    }

    /// A reading and a full pass now, after any work already running.
    func scanNow() async {
        await exclusive { [weak self] in await self?.pass() }
    }

    private func exclusive(_ work: @escaping @MainActor () async -> Void) async {
        if let running { await running.value }
        guard scanner != nil, folder != nil else { return }
        let task = Task(priority: .utility) { @MainActor () -> Void in await work() }
        running = task
        await task.value
        if running == task { running = nil }
    }

    private func startLoop() {
        loop?.cancel()
        let interval = deps.readingInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard interval.isFinite else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Reads the sign-in now and queues the reading, stamped now; skipped
    /// while the switcher writes (it reads around its own write). False when
    /// there is no store to record it in, or Stop and forget came first.
    @discardableResult
    private func reading() async -> Bool {
        guard let scanner else { return false }
        guard writesUnderWay == 0 else { return true }
        return await read(into: scanner)
    }

    private func read(into scanner: TokenBurnScanner) async -> Bool {
        let generation = self.generation
        let at = now()
        let reader = deps.readSignIn
        let id = UUID()
        let task = Task { @MainActor [weak self] () -> Bool in
            let signIn = await Task.detached(priority: .userInitiated) { reader() }.value
            guard let self, generation == self.generation else { return false }
            recorder.enqueue { [weak self] in
                guard generation == self?.generation else { return }
                try? await scanner.observe(signIn?.identity, fetchedAt: signIn?.fetchedAt, at: at)
            }
            return true
        }
        readingsInFlight[id] = task
        let recorded = await task.value
        readingsInFlight[id] = nil
        return recorded
    }

    private func publishAfterRecording() async {
        try? await recorder.run {}
        await publish()
    }

    private func pass() async {
        guard let scanner, let folder else { return }
        let generation = self.generation
        let started = now()
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            phase = .grantLost
            await publish()
            return
        }
        guard await reading() else { return }
        let clock = ContinuousClock.now
        do {
            let report = try await scanner.scan(root: folder, progress: { [weak self] done, total in
                Task { @MainActor [weak self] in self?.progress(done: done, total: total, generation: generation) }
            })
            guard generation == self.generation else { return }
            lastReport = report
            lastScan = started
            countedThrough = started
            phase = .ready
            // A duration is redacted by default; seconds are safe to show.
            let seconds = (ContinuousClock.now - clock) / .seconds(1)
            Self.log.info("""
                pass: \(report.filesSeen) files, \(report.filesUnchanged) unchanged, \(report.filesUnreadable) unreadable, \
                \(report.repliesCounted) replies, \(report.bytesRead) bytes in \(seconds, format: .fixed(precision: 2), privacy: .public) s
                """)
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            Self.log.error("pass failed")
        }
        await publishAfterRecording()
    }

    private func progress(done: Int, total: Int, generation: Int) {
        guard generation == self.generation, phase != .off, phase != .grantLost, done < total else { return }
        phase = .counting(done: done, total: total)
    }

    // MARK: The switcher's writes (spec §10.1)

    /// Right before the switcher writes Claude Code's sign-in; it waits for
    /// the readings in flight, then this one (file reads, never the store).
    func claudeCodeWillWrite() async {
        writesUnderWay += 1
        for reading in readingsInFlight.values { _ = await reading.value }
        if let scanner { _ = await read(into: scanner) }
    }

    /// Right after it wrote (or tried to): the time is evidence, then a
    /// reading of what is there now. Nil: the attempt wrote nothing.
    func claudeCodeDidWrite(at date: Date?) async {
        writesUnderWay = max(0, writesUnderWay - 1)
        guard let date else { return }
        guard let scanner else {
            pendingWrites.append(date)
            return
        }
        let generation = self.generation
        recorder.enqueue { [weak self] in
            guard generation == self?.generation else { return }
            try? await scanner.recordConfigWrite(at: date)
        }
        await reading()
    }

    // MARK: Accounts and values

    /// From `AppModel` after every refresh. Remembers each resolved
    /// organization (kept while an account is paused or not refreshed yet).
    func accountsDidChange(_ accounts: [TokenBurnAccount]) {
        self.accounts = accounts
        for account in accounts { lastKnown[account.id] = account }
        guard let scanner else { return }
        let at = now()
        let organizations = accounts.compactMap { account in account.organizationID.map { (account.id, $0) } }
        recorder.enqueue {
            for (account, organization) in organizations {
                try? await scanner.setOrganization(organization, for: account, at: at)
            }
        }
    }

    /// Recomputes every figure from the store; nothing is re-read.
    func recompute() async {
        await publishAfterRecording()
    }

    /// The account's minutes and its sign-ins' spans are
    /// deleted, with its binding, before the switcher drops its link.
    func accountRemoved(_ id: UUID, links: [String: UUID]) async {
        guard let scanner else {
            accounts.removeAll { $0.id == id }
            lastKnown[id] = nil
            return
        }
        try? await recorder.run {}
        let generation = self.generation
        do {
            let spans = try await scanner.signInSpans()
            let proven = TokenBurnTimeline.proven(spans: spans, writes: try await scanner.configWrites())
            let bindings = try await bindings(links: links, spans: spans, scanner: scanner, including: lastKnown[id])
            let rows = try await scanner.minuteTotals(from: .distantPast, to: .distantFuture)
            guard generation == self.generation else { return }
            let minutes = Set(rows.map(\.minute)).filter {
                TokenBurnAttribution.owner(ofMinute: $0, proven: proven, resolve: bindings.owner(of:)) == .account(id)
            }
            let identities = Set(spans.map(\.identity)).filter { bindings.owner(of: $0) == .account(id) }
            try await scanner.deleteUsage(minutes: Array(minutes))
            try await scanner.deleteSpans(of: identities)
            try await scanner.removeBinding(account: id)
        } catch {
            Self.log.error("could not delete a removed account's usage")
        }
        accounts.removeAll { $0.id == id }
        lastKnown[id] = nil
        await publish()
    }

    private func bindings(links: [String: UUID], spans: [SignInSpan], scanner: TokenBurnScanner,
                          including removed: TokenBurnAccount? = nil) async throws -> TokenBurnBindings {
        var personal = Set(accounts.filter(\.personalPlanDetected).map(\.id))
        if let removed, removed.personalPlanDetected { personal.insert(removed.id) }
        return TokenBurnBindings(links: links, organizations: try await scanner.organizationBindings(),
                                 personalPlanAccounts: personal, observedIdentities: Array(Set(spans.map(\.identity))))
    }

    /// Summary, per-account values, the pooled lines and History's days;
    /// one computation at a time, in call order.
    private func publish() async {
        try? await publisher.run { [weak self] in await self?.publishBody() }
    }

    private func publishBody() async {
        guard let scanner else { return }
        let generation = self.generation
        let date = now()
        let calendar = Calendar.current
        let accounts = self.accounts
        let choice = period
        do {
            let summary = try await scanner.summary()
            let spans = try await scanner.signInSpans()
            let proven = TokenBurnTimeline.proven(spans: spans, writes: try await scanner.configWrites())
            let bindings = try await bindings(links: linksProvider(), spans: spans, scanner: scanner)
            let earliest = TokenBurnFigures.earliest(accounts: accounts, choice: choice, now: date, calendar: calendar)
            let minutes = try await scanner.minuteTotals(from: earliest, to: date.addingTimeInterval(60))
            guard generation == self.generation else { return }
            var cache: [SignInIdentity: TokenBurnOwner] = [:]
            func resolve(_ identity: SignInIdentity) -> TokenBurnOwner {
                if let known = cache[identity] { return known }
                let resolved = bindings.owner(of: identity)
                cache[identity] = resolved
                return resolved
            }
            let rows = minutes.map { row in
                TokenBurnFigures.Row(minute: row.minute, owner: TokenBurnAttribution.owner(ofMinute: row.minute, proven: proven,
                                                                                           resolve: resolve),
                                     total: row.total)
            }
            let figures = TokenBurnFigures.compute(rows: rows, accounts: accounts, choice: choice, proven: proven,
                                                   resolve: resolve, now: date, calendar: calendar)
            self.summary = summary
            self.values = figures.values
            self.pooled = figures.pooled
            self.days = figures.days
            self.total = figures.total
            self.trackingSince = figures.trackingSince
        } catch {
            Self.log.error("could not compute values")
        }
    }

    // MARK: Test seams

    /// After everything already queued is recorded.
    func signInSpansForTesting() async -> [SignInSpan] {
        try? await recorder.run {}
        return (try? await scanner?.signInSpans()) ?? []
    }

    func configWritesForTesting() async -> [Date] {
        try? await recorder.run {}
        return (try? await scanner?.configWrites()) ?? []
    }
}
