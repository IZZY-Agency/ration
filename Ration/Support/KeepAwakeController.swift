import Foundation

/// Seam over the one system call that keeps the Mac from idle sleep, so
/// tests record holds instead of taking real ones.
@MainActor
protocol IdleSleepAssertionHolding: AnyObject {
    /// Take the hold. `reason` is what `pmset -g assertions` lists;
    /// `display` keeps the display from idle sleep as well.
    func hold(reason: String, display: Bool)
    /// Let the hold go. Safe without a live hold.
    func release()
}

/// Live implementation: `ProcessInfo.beginActivity` with idle system sleep
/// disabled — the same assertion `caffeinate -i` and the Claude desktop app
/// take — and, for the user's override, idle display sleep disabled too
/// (`caffeinate -d`). A closed lid, the Apple menu, low battery and thermal
/// limits still sleep the Mac. The assertion belongs to this process, so a
/// crash or quit ends it; nothing is written anywhere.
@MainActor
final class ProcessInfoIdleSleepAssertion: IdleSleepAssertionHolding {
    private var activity: (any NSObjectProtocol)?

    static func options(display: Bool) -> ProcessInfo.ActivityOptions {
        display ? [.idleSystemSleepDisabled, .idleDisplaySleepDisabled] : [.idleSystemSleepDisabled]
    }

    func hold(reason: String, display: Bool) {
        release()
        activity = ProcessInfo.processInfo.beginActivity(options: Self.options(display: display), reason: reason)
    }

    func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

/// Owns the single idle-sleep hold. Holds while either source is live, the
/// user's override first (its reason names the user, not an account), and
/// re-takes the hold when the backing source changes so the listed reason
/// stays true. `update` is idempotent: the same inputs never churn the hold.
@MainActor
final class KeepAwakeController {
    static let manualReason = "Ration: kept awake until you stop it"
    static let automaticReason = "Ration: an account is in use"

    private let assertion: any IdleSleepAssertionHolding
    /// The source backing the live hold; nil while nothing is held.
    private(set) var source: KeepAwakeSource?

    init(assertion: any IdleSleepAssertionHolding = ProcessInfoIdleSleepAssertion()) {
        self.assertion = assertion
    }

    /// `automaticUntil`: the end of the in-use hold (`KeepAwakePolicy`), nil
    /// when no account is in use or the feature is off; inclusive, like the
    /// IN USE phase it mirrors. `manual`: the user's override, nil when none;
    /// its end is exclusive.
    func update(automaticUntil: Date?, manual: ManualKeepAwake?, now: Date, monotonicNow: TimeInterval) {
        let wanted: KeepAwakeSource?
        if let manual, manual.isLive(monotonic: monotonicNow) {
            wanted = .manual
        } else if let automaticUntil, automaticUntil >= now {
            wanted = .automatic
        } else {
            wanted = nil
        }
        guard wanted != source else { return }
        if source != nil {
            assertion.release()
        }
        source = wanted
        // The override is "keep the Mac awake" for someone looking at it: the
        // display stays on. An agent run needs no screen: idle sleep only.
        switch wanted {
        case .manual: assertion.hold(reason: Self.manualReason, display: true)
        case .automatic: assertion.hold(reason: Self.automaticReason, display: false)
        case nil: break
        }
    }

    /// Releases whatever is held. The next `update` can hold again.
    func stop() {
        guard source != nil else { return }
        assertion.release()
        source = nil
    }
}
