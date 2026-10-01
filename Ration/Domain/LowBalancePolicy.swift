import Foundation

/// What one low-balance alert says, fixed when the policy fires: the balance
/// read and the threshold it fell below.
struct LowBalanceAlert: Equatable, Sendable {
    let balance: Money
    let thresholdCents: Int
}

/// Low-balance alert memory, one per account.
///
/// `notified` latches once the alert fired and stays latched while the
/// balance stays below the threshold, however the threshold is edited: the
/// user has been told. A reading at or above the threshold (a top-up) or the
/// alert being turned off re-arms it. `row` is the drop row's state.
struct LowBalanceAlertMemory: Codable, Equatable, Sendable {
    var notified = false
    var row: ResetCreditRowState = .inactive

    init(notified: Bool = false, row: ResetCreditRowState = .inactive) {
        self.notified = notified
        self.row = row
    }

    /// Per field: a wrong-typed value costs only itself.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notified = (try? c.decode(Bool.self, forKey: .notified)) ?? false
        row = (try? c.decode(ResetCreditRowState.self, forKey: .row)) ?? .inactive
    }
}

/// One evaluation's facts: the current balance (nil without current
/// evidence) and the threshold (nil when the alert is off).
struct LowBalanceAlertInput: Equatable, Sendable {
    let balance: Money?
    let thresholdCents: Int?
}

/// Pure low-balance policy for a prepaid balance (TypeSafe): one alert when a
/// current reading falls below the user's threshold, re-armed by a top-up.
enum LowBalancePolicy {
    /// The balance the policy may act on: a reading this session verified
    /// (`usageCreditsVerified`), young enough to speak for the present, in
    /// cents (the threshold's unit). nil otherwise: a restored or carried
    /// balance never alerts.
    static func currentBalance(snapshot: UsageSnapshot?, now: Date) -> Money? {
        guard
            let snapshot,
            snapshot.usageCreditsVerified,
            let credits = snapshot.usageCredits,
            UsageCreditPolicy.isCurrent(credits, now: now),
            credits.balance.exponent == 2
        else { return nil }
        return credits.balance
    }

    /// The threshold as money in the balance's currency, so copy formats the
    /// two alike ("$4.12 … below your $5.00 alert", never "$5" beside "$4.12"
    /// or "5 $" beside "4,12 $US").
    static func thresholdText(_ cents: Int, like balance: Money, locale: Locale = .current) -> String {
        guard let money = Money(minorUnits: Int64(cents), currency: balance.currency, exponent: balance.exponent) else {
            return AlertMessage.dollars(cents, locale: locale)
        }
        return UsageFormatters.money(money, locale: locale)
    }

    /// Below, strictly: landing exactly on the threshold is not "below" it.
    static func isBelow(_ balance: Money, thresholdCents: Int) -> Bool {
        balance.minorUnits < Int64(thresholdCents)
    }

    /// `thresholdCents` nil: the alert is off, and memory re-arms. `balance`
    /// nil: no current evidence, and memory is left alone.
    static func evaluate(
        balance: Money?,
        thresholdCents: Int?,
        memory: inout LowBalanceAlertMemory,
        events: inout [AlertEvent]
    ) {
        guard let thresholdCents else {
            memory = LowBalanceAlertMemory()
            return
        }
        guard let balance else { return }
        guard isBelow(balance, thresholdCents: thresholdCents) else {
            memory = LowBalanceAlertMemory()
            return
        }
        guard !memory.notified else { return }
        events.append(.lowBalance(LowBalanceAlert(balance: balance, thresholdCents: thresholdCents)))
        memory.notified = true
        memory.row = .active
    }
}
