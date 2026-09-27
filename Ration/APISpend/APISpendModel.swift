import AppKit
import Combine
import Foundation
import os

/// Card-ready view of one API org.
struct APIOrgPresentation: Identifiable, Equatable {
    let org: APIOrgRecord
    let cost: APICostReport?
    let tokens: APITokenReport?
    let coverage: PriorityCoverage?
    let costError: APISpendError?
    let tokenError: APISpendError?
    let isStale: Bool
    let isOldMonth: Bool
    let tier: AlertTier?
    var id: UUID { org.id }
}

/// Owns API orgs, their reports and budget alerts. Never touches
/// `AppModel` state except through `AlertDeliveryBridge`.
@MainActor
final class APISpendModel: ObservableObject {
    struct Dependencies {
        var clients: [APIVendor: any APISpendClient]
        var keyStore: any APIKeyStore
        var persistence: APISpendPersistence
        var now: @MainActor () -> Date = { .now }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var lowPowerMode: @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        var jitter: @MainActor () -> Int = { Int.random(in: 0...PollSchedule.maxJitterSeconds) }
        /// Tests set false and drive `refresh` / `retryPendingKeyDeletions` themselves.
        var autoPoll = true
    }

    @Published private(set) var state = APISpendState() { didSet { stateRevision &+= 1 } }
    /// Bumped on every state change; a quit saves while it is ahead of
    /// `writtenRevision` (`PendingEditFlushing`).
    private(set) var stateRevision: UInt64 = 0
    private(set) var writtenRevision: UInt64 = 0
    @Published private(set) var snapshots: [UUID: APISpendSnapshot] = [:]
    @Published private(set) var costErrors: [UUID: APISpendError] = [:]
    @Published private(set) var tokenErrors: [UUID: APISpendError] = [:]
    @Published private(set) var removeFailures: Set<UUID> = []
    @Published private(set) var loadFailed = false

    weak var bridge: (any AlertDeliveryBridge)?
    let deps: Dependencies
    let settings: AppSettings
    let log = Logger(subsystem: "agency.izzy.ration", category: "api-spend")

    private(set) var hydrated = false
    // Internal (not private) so APISpendModel+Edits.swift can use them.
    var generation: [UUID: UInt64] = [:]
    var removingOrgIDs: Set<UUID> = []
    var pausingOrgIDs: Set<UUID> = []
    var replacing: [UUID: UUID] = [:]
    var inFlight: Set<UUID> = []
    var followUp: Set<UUID> = []
    var retryAt: [UUID: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastSeenMonth: UTCMonth?

    init(dependencies: Dependencies, settings: AppSettings) {
        self.deps = dependencies
        self.settings = settings
    }

    // MARK: Lifecycle

    func start() async {
        do {
            state = try await deps.persistence.loadState()
            writtenRevision = stateRevision
        } catch {
            // Never overwrite an unreadable file with an empty state.
            loadFailed = true
            log.error("api-spend state unreadable: \(String(describing: type(of: error)), privacy: .public)")
            return
        }
        snapshots = await deps.persistence.loadSnapshots()
        await reconcile()
        hydrated = true
        lastSeenMonth = UTCMonth(containing: deps.now())
        if let bridge, bridge.registerPrimeHook({ [weak self] in self?.primeAll() }) {
            primeAll()
        }
        guard deps.autoPoll else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
        boundaryTask = Task { [weak self] in await self?.boundaryLoop() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfMonthChanged() }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        boundaryTask?.cancel(); boundaryTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshAll()
            await retryPendingKeyDeletions()   // runs even with no pollable org
            let interval = PollSchedule.interval(lowPowerMode: deps.lowPowerMode(), jitterSeconds: deps.jitter())
            do { try await deps.sleep(interval) } catch { return }
        }
    }

    /// Refresh at 00:00Z and again 5 minutes later (the UTC month boundary).
    private func boundaryLoop() async {
        while !Task.isCancelled {
            let next = UTCMonth(containing: deps.now()).nextStart
            let wait = max(1, next.timeIntervalSince(deps.now()) + 1)
            do { try await deps.sleep(.seconds(wait)) } catch { return }
            await refreshIfMonthChanged()
            do { try await deps.sleep(.seconds(300)) } catch { return }
            await refreshAll()
        }
    }

    func refreshIfMonthChanged() async {
        let month = UTCMonth(containing: deps.now())
        guard month != lastSeenMonth else { return }
        lastSeenMonth = month
        await refreshAll()
    }

    private func reconcile() async {
        let live = Set(state.orgs.map(\.id))
        snapshots = snapshots.filter { live.contains($0.key) }
        state.memory = state.memory.filter { live.contains($0.key) }
        // NO Keychain orphan sweep: the Keychain is shared by every copy of the
        // app, and one with another state file — such as the unsandboxed
        // unit-test host — would see this copy's keys as orphans and delete
        // them. Only a removal this state journaled (`pendingKeyDeletions`)
        // ever deletes a key.
        persistState()
        persistSnapshots()
        await retryPendingKeyDeletions()
    }

    // MARK: Fetch path

    func refreshAll() async {
        for org in state.orgs.sorted(by: { $0.displayOrder < $1.displayOrder }) { await refresh(org.id) }
    }

    func refresh(_ id: UUID) async {
        guard hydrated, let org = org(id), !org.isPaused,
              !removingOrgIDs.contains(id), !pausingOrgIDs.contains(id), replacing[id] == nil
        else { return }
        if let until = retryAt[id], until > deps.now() { return }
        guard !inFlight.contains(id) else { followUp.insert(id); return }
        inFlight.insert(id)
        repeat {
            followUp.remove(id)
            await fetchOnce(id)
        } while followUp.contains(id)
        inFlight.remove(id)
    }

    /// Popover-open refresh: skipped while the cost report is under 60 s old.
    func refreshWhenOpened() async {
        for org in state.orgs {
            if let fetched = snapshots[org.id]?.cost?.fetchedAt, deps.now().timeIntervalSince(fetched) < 60 { continue }
            await refresh(org.id)
        }
    }

    private func fetchOnce(_ id: UUID) async {
        guard let org = org(id), let client = deps.clients[org.vendor] else { return }
        let gen = generation[id, default: 0]
        let startedAt = deps.now()
        let month = UTCMonth(containing: startedAt)
        let key: String
        do { key = try await keyCall { try $0.read(for: id) } } catch {
            guard isCurrent(id, gen) else { return }
            recordCostError(id, error)
            return
        }
        guard isCurrent(id, gen) else { return }
        let wanted: @Sendable () async -> Bool = { [weak self] in await self?.isCurrent(id, gen) ?? false }
        do {
            let report = try await APISpendFetchScope.$isStillWanted.withValue(wanted) {
                try await client.costReport(month: month, key: key, refreshStartedAt: startedAt)
            }
            guard isCurrent(id, gen) else { return }
            acceptCost(report, for: id)
        } catch {
            guard isCurrent(id, gen) else { return }
            recordCostError(id, error)
        }
        do {
            let tokens = try await APISpendFetchScope.$isStillWanted.withValue(wanted) {
                try await client.tokenReport(month: month, key: key, refreshStartedAt: startedAt)
            }
            guard isCurrent(id, gen) else { return }
            acceptTokens(tokens, for: id)
        } catch {
            guard isCurrent(id, gen) else { return }
            tokenErrors[id] = error as? APISpendError ?? .transport
        }
        log.notice("api-spend refresh org=\(id.uuidString, privacy: .public) vendor=\(org.vendor.rawValue, privacy: .public) month=\(month.key, privacy: .public)")
    }

    func isCurrent(_ id: UUID, _ gen: UInt64) -> Bool {
        guard let org = org(id) else { return false }
        return generation[id, default: 0] == gen && !org.isPaused
            && !removingOrgIDs.contains(id) && !pausingOrgIDs.contains(id) && replacing[id] == nil
    }

    private func acceptCost(_ report: APICostReport, for id: UUID) {
        var snapshot = snapshots[id] ?? APISpendSnapshot()
        snapshot.cost = report
        snapshots[id] = snapshot
        costErrors[id] = nil
        retryAt[id] = nil
        persistSnapshots()
        if report.isCurrent(at: deps.now()) { evaluate(id) }
    }

    private func acceptTokens(_ tokens: APITokenReport, for id: UUID) {
        var snapshot = snapshots[id] ?? APISpendSnapshot()
        snapshot.tokens = tokens
        if tokens.hasPriorityTierUsage { snapshot.priorityPresentMonth = tokens.month }
        snapshots[id] = snapshot
        tokenErrors[id] = nil
        persistSnapshots()
    }

    private func recordCostError(_ id: UUID, _ error: Error) {
        let mapped = error as? APISpendError ?? .transport
        costErrors[id] = mapped
        if case .rateLimited(let at) = mapped {
            retryAt[id] = at ?? deps.now().addingTimeInterval(TimeInterval(PollSchedule.baseSeconds))
        }
        log.notice("api-spend error org=\(id.uuidString, privacy: .public) case=\(String(describing: mapped), privacy: .public)")
    }

    // MARK: Commit

    /// Evaluates `id` against its current-month cost report. Returns true when
    /// a decision was handed to the bridge (which then writes state).
    @discardableResult
    func evaluate(_ id: UUID, prime: Bool = false) -> Bool {
        guard hydrated, let bridge, let org = org(id), let budget = org.monthlyBudgetCents,
              !removingOrgIDs.contains(id), replacing[id] == nil,
              let report = snapshots[id]?.cost, report.isCurrent(at: deps.now())
        else { return false }
        if !prime {
            guard bridge.alertsReady, bridge.alertsEnabled, !org.isPaused, !pausingOrgIDs.contains(id) else { return false }
        }
        let previous = state.memory[id] ?? BudgetAlertMemory()
        let decision = APIBudgetPolicy.evaluate(report: report, budgetCents: budget, thresholds: state.thresholds, previous: previous, prime: prime)
        state.memory[id] = decision.next
        if decision.monthAdvanced, apiChannels.drop, bridge.alertsEnabled { bridge.liftDropSnooze() }
        if prime { return false }
        let gen = generation[id, default: 0]
        let isLowerBound = coverage(for: id) == .present
        let posts = decision.crossed.map { [makePost(org: org, report: report, tier: $0, budget: budget, isLowerBound: isLowerBound, gen: gen)] } ?? []
        bridge.enqueueExternalAlertDecision(
            persist: { [weak self] in
                guard let self, self.org(id) != nil, self.generation[id, default: 0] == gen, !self.removingOrgIDs.contains(id) else { return .stale }
                return await self.writeStateNow()
            },
            posts: posts
        )
        return true
    }

    private func makePost(org: APIOrgRecord, report: APICostReport, tier: AlertTier, budget: Int, isLowerBound: Bool, gen: UInt64) -> ExternalAlertPost {
        let event = AlertEvent.budgetThreshold(
            orgID: org.id, monthKey: report.month.key, tier: tier,
            percent: state.thresholds.percent(for: tier),
            spentCents: isLowerBound ? APIMoney.flooredCents(report.monthToDateCents) : APIMoney.roundedCents(report.monthToDateCents),
            budgetCents: budget, isLowerBound: isLowerBound, reportFetchedAt: report.fetchedAt
        )
        let orgID = org.id
        let fallbackLabel = org.label
        return ExternalAlertPost(
            id: AlertMessage.id(for: event, accountID: orgID),
            stillValid: { [weak self] in self?.postStillValid(orgID, gen, tier: tier) ?? false },
            render: { [weak self] redacted in
                AlertMessage.text(for: event, accountLabel: self?.org(orgID)?.label ?? fallbackLabel, redacted: redacted)
            }
        )
    }

    /// Also re-checks the crossing itself: thresholds or the budget edited
    /// while the post was queued may no longer reach its tier.
    private func postStillValid(_ id: UUID, _ gen: UInt64, tier: AlertTier) -> Bool {
        guard settings.usageAlertsEnabled, apiChannels.notification, isCurrent(id, gen),
              let budget = org(id)?.monthlyBudgetCents, let report = snapshots[id]?.cost,
              let reached = APIBudgetPolicy.tier(monthToDateCents: report.monthToDateCents, budgetCents: budget, thresholds: state.thresholds)
        else { return false }
        return reached >= tier
    }

    /// Prime hook: baseline every org with a current-month report,
    /// paused ones included, without posting; one state write.
    func primeAll() {
        guard hydrated else { return }
        for org in state.orgs { evaluate(org.id, prime: true) }
        persistState()
    }

    // MARK: Read models

    var apiChannels: AlertChannels { settings.data.channels(forKey: AppSettingsData.apiBudgetsKey) }

    func org(_ id: UUID) -> APIOrgRecord? { state.orgs.first { $0.id == id } }

    func coverage(for id: UUID) -> PriorityCoverage? {
        guard let org = org(id) else { return nil }
        let snapshot = snapshots[id]
        return PriorityCoverage.resolve(vendor: org.vendor, cost: snapshot?.cost, tokens: snapshot?.tokens, presentMonth: snapshot?.priorityPresentMonth)
    }

    func presentations(now: Date) -> [APIOrgPresentation] {
        let staleAfter = 2 * PollSchedule.maxIntervalSeconds(lowPowerMode: deps.lowPowerMode())
        return state.orgs.filter { !$0.isPaused && !removingOrgIDs.contains($0.id) }
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { org in
                let cost = snapshots[org.id]?.cost
                let tier = cost.flatMap { report in
                    org.monthlyBudgetCents.flatMap { APIBudgetPolicy.tier(monthToDateCents: report.monthToDateCents, budgetCents: $0, thresholds: state.thresholds) }
                }
                return APIOrgPresentation(
                    org: org, cost: cost, tokens: snapshots[org.id]?.tokens, coverage: coverage(for: org.id),
                    costError: costErrors[org.id], tokenError: tokenErrors[org.id],
                    isStale: cost.map { now.timeIntervalSince($0.fetchedAt) > staleAfter } ?? true,
                    isOldMonth: cost.map { !$0.isCurrent(at: now) } ?? false,
                    tier: tier
                )
            }
    }

    /// Menu-bar gauges: one rounded square per unpaused org with a budget and a
    /// current-month report, in `displayOrder`.
    func gauges(displaysRemaining: Bool, now: Date) -> [MenuBarGauge] {
        orgGauges(displaysRemaining: displaysRemaining, now: now).map(\.value)
    }

    /// The Settings list's order once the user has dragged it (nil before:
    /// the popover and menu bar keep their provider-grouped layout).
    func savedAccountOrder(subscriptions: [UUID]) -> [SidebarAccountOrder.Item]? {
        guard !state.sidebarOrder.isEmpty else { return nil }
        return SidebarAccountOrder.merged(subscriptions: subscriptions,
                                          apis: state.orgs.sorted { $0.displayOrder < $1.displayOrder }.map(\.id),
                                          saved: state.sidebarOrder)
    }

    func orgGauges(displaysRemaining: Bool, now: Date) -> [(id: UUID, value: MenuBarGauge)] {
        state.orgs.filter { !$0.isPaused }.sorted { $0.displayOrder < $1.displayOrder }.compactMap { org in
            guard let budget = org.monthlyBudgetCents, let report = snapshots[org.id]?.cost, report.isCurrent(at: now) else { return nil }
            let exact = APIMoney.exactPercent(spentCents: report.monthToDateCents, budgetCents: budget)
            let spent = min(max(NSDecimalNumber(decimal: exact / 100).doubleValue, 0), 1)
            return (org.id, MenuBarGauge(source: .api(org.vendor), label: org.label, fraction: displaysRemaining ? 1 - spent : spent,
                                         windowKind: nil, inUse: false,
                                         budget: BudgetGaugeFacts(exactPercent: exact, isLowerBound: coverage(for: org.id) == .present)))
        }
    }

    func budgetRowFacts(now: Date) -> [APIBudgetRowFacts] {
        guard hydrated, let bridge, bridge.alertsReady, bridge.dropGateOpen(at: now), apiChannels.drop else { return [] }
        return state.orgs.sorted { $0.displayOrder < $1.displayOrder }.compactMap { org in
            APIAttentionRows.facts(org: org, report: snapshots[org.id]?.cost, memory: state.memory[org.id],
                                   thresholds: state.thresholds, isLowerBound: coverage(for: org.id) == .present, now: now)
        }
    }

    /// API budget rows for the shared drop; empty while the drop is gated.
    func attentionRows(now: Date) -> [AttentionRow] {
        budgetRowFacts(now: now).map { facts in
            AttentionRow(owner: .apiOrg(facts.orgID), accountLabel: facts.label, source: .api(facts.vendor), subject: .apiBudget,
                         tier: facts.tier, usedPercent: facts.usedPercent, spentCents: facts.spentCents,
                         thresholdPercent: state.thresholds.percent(for: facts.tier), thresholdCents: nil,
                         resetsAt: facts.resetsAt, resetCount: nil, resetCreditIDs: [],
                         budgetCents: facts.budgetCents, isLowerBound: facts.isLowerBound)
        }
    }

    /// Drop-row click: acknowledge at the row's tier (a later escalation shows again).
    func dismissBudgetRow(orgID: UUID, tier: AlertTier) {
        guard org(orgID) != nil else { return }
        var memory = state.memory[orgID] ?? BudgetAlertMemory()
        memory.dismissedTier = max(memory.dismissedTier ?? tier, tier)
        state.memory[orgID] = memory
        persistState()
    }

    // MARK: Mutation helpers (used by APISpendModel+Edits.swift)

    func mutateState(_ body: (inout APISpendState) -> Void) { body(&state) }
    func mutateOrg(at index: Int, _ body: (inout APIOrgRecord) -> Void) { body(&state.orgs[index]) }
    func markRemoveFailure(_ id: UUID) { removeFailures.insert(id) }
    func clearRemoveFailure(_ id: UUID) { removeFailures.remove(id) }
    func markCostError(_ id: UUID, _ error: APISpendError) { costErrors[id] = error }
    func dropCaches(for id: UUID) {
        snapshots[id] = nil
        costErrors[id] = nil
        tokenErrors[id] = nil
        retryAt[id] = nil
        persistSnapshots()
    }

    // MARK: Persistence helpers

    func persistState() {
        guard !loadFailed else { return }
        Task { [weak self] in _ = await self?.writeStateNow() }
    }

    @MainActor private final class RevisionBox { var value: UInt64 = 0 }

    /// Every state write goes through here, so `writtenRevision` knows what
    /// is on disk: the revision is read when the queued write encodes.
    func writeStateNow() async -> PersistOutcome {
        let box = RevisionBox()
        let outcome = await deps.persistence.writeState { [weak self] in
            box.value = self?.stateRevision ?? 0
            return self?.state
        }
        if outcome == .written { writtenRevision = max(writtenRevision, box.value) }
        return outcome
    }

    func persistSnapshots() {
        Task { [weak self] in _ = await self?.deps.persistence.writeSnapshots { [weak self] in self?.snapshots } }
    }

    /// Keychain calls run off the main actor (SecItem can block).
    func keyCall<T: Sendable>(_ body: @escaping @Sendable (any APIKeyStore) throws -> T) async throws -> T {
        let store = deps.keyStore
        return try await Task.detached { try body(store) }.value
    }

    // MARK: Test seams (tests only)

    func injectSnapshotForTesting(_ id: UUID, _ snapshot: APISpendSnapshot) { snapshots[id] = snapshot }
    func injectMemoryForTesting(_ id: UUID, _ memory: BudgetAlertMemory) { state.memory[id] = memory }
}

/// Where the app binary is running.
enum RuntimeEnvironment {
    /// XCTest loads its bundle into the app as the unit-test host.
    static var isHostingUnitTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}
