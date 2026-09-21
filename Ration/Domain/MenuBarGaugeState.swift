import Foundation

/// One menu bar ring: which account (provider colors the ring, label names it
/// in the tooltip), how full the ring is (already in display mode — used or
/// remaining), which usage window produced the value, and whether the account
/// is in the bright IN USE phase (drawn as a center dot).
struct MenuBarGauge: Equatable {
    let provider: Provider
    let label: String
    let fraction: Double
    let windowKind: UsageWindowKind
    let inUse: Bool
}

/// The menu bar shows a usage ring for EVERY visible account that reports a
/// rate window — the rings are the always-on usage readout; the in-use dot
/// (same bright-phase rule as the popover pill) marks which of them is
/// burning right now.
enum MenuBarGaugeState {
    /// Snapshot windows in "finest first" order, used when the selected kind
    /// is absent (e.g. Fable selected on a non-Max account).
    private static func window(
        in snapshot: UsageSnapshot,
        preferring kind: UsageWindowKind
    ) -> UsageWindow? {
        let byKind: [UsageWindowKind: UsageWindow?] = [
            .fiveHour: snapshot.fiveHour,
            .weekly: snapshot.weekly,
            .modelWeekly: snapshot.modelWeekly
        ]
        if let selected = byKind[kind] ?? nil { return selected }
        for fallback in [UsageWindowKind.fiveHour, .weekly, .modelWeekly] {
            if let window = byKind[fallback] ?? nil { return window }
        }
        return nil
    }

    /// `accounts` must already be the visible (non-paused) set; usage entries
    /// for any other account are ignored. One gauge per account with a
    /// snapshot and at least one rate window (Cursor has none and yields
    /// nothing), grouped by canonical provider order (`Provider.allCases`),
    /// keeping the caller's account order within a provider.
    static func gauges(
        accounts: [AccountRecord],
        activeUsage: [UUID: ActiveUsage],
        snapshots: (UUID) -> UsageSnapshot?,
        windowKind: (Provider) -> UsageWindowKind,
        displaysRemaining: Bool,
        now: Date
    ) -> [MenuBarGauge] {
        var byProvider: [Provider: [MenuBarGauge]] = [:]
        for account in accounts {
            guard let snapshot = snapshots(account.id),
                  let window = window(in: snapshot, preferring: windowKind(account.provider))
            else { continue }

            let inUse = if case .inUse = InUsePhase.classify(activeUsage[account.id], now: now) {
                true
            } else {
                false
            }
            let remaining = min(max(window.remainingFraction, 0), 1)
            byProvider[account.provider, default: []].append(MenuBarGauge(
                provider: account.provider,
                label: account.label,
                fraction: displaysRemaining ? remaining : 1 - remaining,
                windowKind: window.kind,
                inUse: inUse
            ))
        }
        return Provider.allCases.flatMap { byProvider[$0] ?? [] }
    }
}
