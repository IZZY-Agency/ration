import Foundation

/// The only `AppModel` surface the API spend model uses. API
/// alerts reuse the subscription post gate instead of re-implementing it.
@MainActor
protocol AlertDeliveryBridge: AnyObject {
    /// True once a successful `load()` finished its startup reconcile and priming.
    var alertsReady: Bool { get }
    /// `usageAlertsEnabled`, the master switch.
    var alertsEnabled: Bool { get }
    /// Stores `hook` (called synchronously at the end of every `primeAllAlerts()`);
    /// returns `alertsActive` now, so a late registrant primes itself.
    func registerPrimeHook(_ hook: @escaping @MainActor () -> Void) -> Bool
    /// One decision: `persist` first, then — unless it reports `.stale` — the
    /// posts, on `alertSideEffectQueue`, behind the same gates as subscriptions.
    func enqueueExternalAlertDecision(
        persist: @escaping @MainActor () async -> PersistOutcome,
        posts: [ExternalAlertPost]
    )
    /// Lifts the ✕ snooze (in memory now, persisted via the live-value write).
    func liftDropSnooze()
    /// Read-only: the drop panel may show rows now (not snoozed, master switch
    /// on, not quiet hours).
    func dropGateOpen(at now: Date) -> Bool
}

struct ExternalAlertPost {
    let id: String
    let stillValid: @MainActor () -> Bool
    let render: @MainActor (_ redacted: Bool) -> (title: String, body: String)
}
