import Foundation

/// When the automatic keep-awake hold ends: the Mac is kept from idle sleep
/// exactly as long as some account reads IN USE, by the one rule the IN USE
/// pill applies (`InUsePhase.classify`). Pure, so the end instant is
/// unit-testable without a clock or an assertion.
enum KeepAwakePolicy {
    /// The instant the last bright phase among `activity` ends, or nil when
    /// no account is in use at `now`. A phase that ends later always wins;
    /// an account past its phase (last used, not in use) contributes nothing.
    static func holdUntil(activity: [UUID: ActiveUsage], now: Date) -> Date? {
        var latest: Date?
        for usage in activity.values {
            guard case .inUse = InUsePhase.classify(usage, now: now) else { continue }
            let threshold = usage.source == .weekly
                ? InUsePhase.weeklyInUseThreshold
                : InUsePhase.inUseThreshold
            let end = usage.lastUsedAt.addingTimeInterval(threshold)
            if latest.map({ end > $0 }) ?? true {
                latest = end
            }
        }
        return latest
    }
}
