import Foundation

/// One menu bar ring: which account (provider colors the ring, label names it
/// in the tooltip), how full the ring is (already in display mode — used or
/// remaining), which usage window produced the value, and whether the account
/// is in the bright IN USE phase (drawn as a center dot).
struct MenuBarGauge: Equatable {
    /// Subscription provider or API vendor: colour, name and shape.
    let source: DisplaySource
    let label: String
    let fraction: Double
    /// nil for API budget gauges (no rate window).
    let windowKind: UsageWindowKind?
    let inUse: Bool
    /// API budget gauges only: the unrounded percent spent and whether it is a lower bound.
    var budget: BudgetGaugeFacts? = nil
    /// Prepaid API accounts (TypeSafe) only: the balance and the credit it is
    /// a share of.
    var credit: CreditGaugeFacts? = nil

    var provider: Provider? { if case .subscription(let provider) = source { provider } else { nil } }
}

extension MenuBarGauge {
    init(provider: Provider, label: String, fraction: Double, windowKind: UsageWindowKind, inUse: Bool) {
        self.init(source: .subscription(provider), label: label, fraction: fraction, windowKind: windowKind, inUse: inUse, budget: nil)
    }
}

struct BudgetGaugeFacts: Equatable, Sendable {
    /// Unrounded percent of budget spent.
    let exactPercent: Decimal
    let isLowerBound: Bool
}

/// A prepaid balance's gauge: the balance as a
/// share of the credit held, every unexpired grant's original amount. It
/// drains as the balance is spent; a top-up or a new free credit fills it.
struct CreditGaugeFacts: Equatable, Sendable {
    let balance: Money
    let granted: Money

    /// Share left, 0…1. A balance above the grants' total (money no grant
    /// accounts for) reads full.
    var leftFraction: Double {
        guard granted.minorUnits > 0 else { return 0 }
        return min(max(Double(balance.minorUnits) / Double(granted.minorUnits), 0), 1)
    }

    /// What has been spent of the credit held; zero when the balance exceeds it.
    var used: Money? {
        Money(minorUnits: max(granted.minorUnits - balance.minorUnits, 0), currency: granted.currency, exponent: granted.exponent)
    }

    /// nil unless the reading is current (`UsageEvidence.maxAge`), lists
    /// every grant (`complete`), and its unexpired grants — spent ones
    /// included, so spending a grant down never shrinks the whole — each say
    /// what they granted, adding up to a positive amount in the balance's
    /// currency. A guess would draw a falsely full square.
    static func make(_ credits: UsageCredits?, now: Date) -> CreditGaugeFacts? {
        guard let credits, credits.complete, UsageCreditPolicy.isCurrent(credits, now: now) else { return nil }
        let held = (credits.grants + credits.spentGrants).filter { grant in grant.expiresAt.map { $0 > now } ?? true }
        let amounts = held.compactMap(\.granted)
        guard amounts.count == held.count, let granted = Money.sum(amounts), granted.minorUnits > 0,
              granted.currency == credits.balance.currency, granted.exponent == credits.balance.exponent
        else { return nil }
        return CreditGaugeFacts(balance: credits.balance, granted: granted)
    }
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
        let entries = accountGauges(accounts: accounts, activeUsage: activeUsage, snapshots: snapshots,
                                    windowKind: windowKind, displaysRemaining: displaysRemaining, now: now)
        return grouped(entries.map(\.value))
    }

    /// Canonical order without a saved one: subscriptions by provider, then
    /// `apiOrgs`, then API-type accounts (TypeSafe) — the popover's order.
    static func grouped(_ accountGauges: [MenuBarGauge], apiOrgs: [MenuBarGauge] = []) -> [MenuBarGauge] {
        func byProvider(_ providers: [Provider]) -> [MenuBarGauge] {
            providers.flatMap { provider in accountGauges.filter { $0.provider == provider } }
        }
        return byProvider(Provider.subscriptionCases) + apiOrgs + byProvider(Provider.allCases.filter(\.isAPIAccount))
    }

    /// One gauge per account that has one, in `accounts` order, with its
    /// account — so a saved Settings order can place it (`SidebarAccountOrder.ordered`).
    static func accountGauges(
        accounts: [AccountRecord],
        activeUsage: [UUID: ActiveUsage],
        snapshots: (UUID) -> UsageSnapshot?,
        windowKind: (Provider) -> UsageWindowKind,
        displaysRemaining: Bool,
        now: Date
    ) -> [(id: UUID, value: MenuBarGauge)] {
        accounts.compactMap { account in
            guard let snapshot = snapshots(account.id) else { return nil }
            // A prepaid API account has no rate window: its square is the
            // balance left of the credit held.
            if account.provider.isAPIAccount {
                guard let credit = CreditGaugeFacts.make(snapshot.usageCredits, now: now) else { return nil }
                return (account.id, MenuBarGauge(
                    source: .subscription(account.provider), label: account.label,
                    fraction: displaysRemaining ? credit.leftFraction : 1 - credit.leftFraction,
                    windowKind: nil, inUse: false, credit: credit
                ))
            }
            guard let window = window(in: snapshot, preferring: windowKind(account.provider)) else { return nil }

            let inUse = if case .inUse = InUsePhase.classify(activeUsage[account.id], now: now) {
                true
            } else {
                false
            }
            let remaining = min(max(window.remainingFraction, 0), 1)
            return (account.id, MenuBarGauge(
                provider: account.provider,
                label: account.label,
                fraction: displaysRemaining ? remaining : 1 - remaining,
                windowKind: window.kind,
                inUse: inUse
            ))
        }
    }
}
