import Foundation
@testable import Ration

/// Scripted client: each call pops the next result; `suspendNextCost` parks one cost call.
final class FakeSpendClient: APISpendClient, @unchecked Sendable {
    let vendor: APIVendor
    private let lock = NSLock()
    var costResults: [Result<APICostReport, APISpendError>] = []
    var tokenResults: [Result<APITokenReport, APISpendError>] = []
    var identityResult: Result<OrgIdentity?, APISpendError> = .success(OrgIdentity(id: "org-1", name: "IZZY"))
    private(set) var costCalls = 0
    private(set) var keysSeen: [String] = []
    var suspendNextCost = false
    /// The fetch scope the last cost call ran in (nil outside one).
    private(set) var lastScope: (@Sendable () async -> Bool)?
    private var costGate: CheckedContinuation<Void, Never>?
    private var suspendedSignal: CheckedContinuation<Void, Never>?

    init(vendor: APIVendor) { self.vendor = vendor }

    /// Returns once a cost call is parked (immediately if it already is).
    func waitUntilCostSuspended() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if costGate != nil { cont.resume() } else { suspendedSignal = cont }
            }
        }
    }

    func releaseCost() { lock.withLock { costGate?.resume(); costGate = nil } }

    func costReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APICostReport {
        let scope = APISpendFetchScope.isStillWanted
        lock.withLock { lastScope = scope }
        let suspend = lock.withLock { () -> Bool in
            costCalls += 1
            keysSeen.append(key)
            defer { suspendNextCost = false }
            return suspendNextCost
        }
        if suspend {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.withLock { costGate = cont; suspendedSignal?.resume(); suspendedSignal = nil }
            }
        }
        let next: Result<APICostReport, APISpendError>? = lock.withLock { costResults.isEmpty ? nil : costResults.removeFirst() }
        guard let next else { throw APISpendError.transport }
        return try next.get()
    }

    func tokenReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APITokenReport {
        let next: Result<APITokenReport, APISpendError>? = lock.withLock { tokenResults.isEmpty ? nil : tokenResults.removeFirst() }
        guard let next else { throw APISpendError.transport }
        return try next.get()
    }

    func identity(key: String) async throws -> OrgIdentity? { try identityResult.get() }
}

@MainActor
final class FakeAlertBridge: AlertDeliveryBridge {
    var alertsReady = true
    var alertsEnabled = true
    var gateOpen = true
    var dropOpen = true
    private(set) var hooks: [@MainActor () -> Void] = []
    private(set) var decisions: [(outcome: PersistOutcome, posts: [ExternalAlertPost])] = []
    private(set) var snoozeLifts = 0
    var posted: [String] = []

    func registerPrimeHook(_ hook: @escaping @MainActor () -> Void) -> Bool { hooks.append(hook); return gateOpen }
    func enqueueExternalAlertDecision(persist: @escaping @MainActor () async -> PersistOutcome, posts: [ExternalAlertPost]) {
        Task { @MainActor in
            let outcome = await persist()
            decisions.append((outcome, posts))
            guard gateOpen, outcome != .stale else { return }
            for post in posts where post.stillValid() { posted.append(post.id) }
        }
    }
    func liftDropSnooze() { snoozeLifts += 1 }
    func dropGateOpen(at now: Date) -> Bool { dropOpen }
    func runPrimeHooks() { hooks.forEach { $0() } }
}

func costReport(month: UTCMonth, cents: String, fetchedAt: Date, startedAt: Date? = nil) -> APICostReport {
    APICostReport(month: month, fetchedAt: fetchedAt, refreshStartedAt: startedAt ?? fetchedAt,
                  days: [DayCost(dayStart: UTCDay.start(of: fetchedAt), cents: Decimal(string: cents)!)],
                  byModel: [], otherCharges: [], byLineItem: [])
}
