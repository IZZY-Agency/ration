import Foundation

/// What each Claude plan costs a month (spec §10): web prices before tax,
/// from claude.com/pricing (Pro, "$20 if billed monthly") and the help
/// centre's "What is the Max plan" (Max 5x $100, Max 20x $200), read on the
/// date below. Only for the "N× your plan" ratio.
enum ClaudePlanPrice {
    static let date = "2026-09-30"

    static func monthlyUSD(_ tier: PlanTier?) -> Decimal? {
        switch tier {
        case .claudePro: 20
        case .claudeMax5x: 100
        case .claudeMax20x: 200
        case .chatGPTPlus, .chatGPTPro5x, .chatGPTPro20x, nil: nil
        }
    }
}

/// The span a figure covers (spec §5.4): the billing cycle when the
/// account's renewal day is known, otherwise the calendar month; or whole
/// local days ending tonight. Boundaries are local midnights of `calendar`'s
/// time zone; `[start, end)`.
struct TokenBurnPeriod: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case cycle, month, days(Int) }

    /// What the cards, Settings and History show: dollars for a period
    /// chosen in Settings.
    enum Choice: String, Codable, CaseIterable, Sendable {
        case last7Days, last30Days, thisMonth, billingCycle
    }

    let start: Date
    let end: Date
    let kind: Kind

    static func current(renewalDay: Int?, now: Date, calendar: Calendar) -> TokenBurnPeriod {
        if let renewalDay {
            let cycle = BillingCycle.current(renewalDay: renewalDay, now: now, calendar: calendar)
            return TokenBurnPeriod(start: cycle.start, end: cycle.end, kind: .cycle)
        }
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        return TokenBurnPeriod(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!, kind: .month)
    }

    static func current(choice: Choice, renewalDay: Int?, now: Date, calendar: Calendar) -> TokenBurnPeriod {
        switch choice {
        case .last7Days: days(7, endingTonight: now, calendar: calendar)
        case .last30Days: days(30, endingTonight: now, calendar: calendar)
        case .thisMonth: current(renewalDay: nil, now: now, calendar: calendar)
        case .billingCycle: current(renewalDay: renewalDay, now: now, calendar: calendar)
        }
    }

    /// Today and the `count - 1` local days before it.
    private static func days(_ count: Int, endingTonight now: Date, calendar: Calendar) -> TokenBurnPeriod {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return TokenBurnPeriod(start: calendar.date(byAdding: .day, value: -count, to: end)!, end: end, kind: .days(count))
    }

    /// The plan price is monthly; a week is not compared with it.
    var comparesWithMonthlyPrice: Bool {
        if case .days(let count) = kind { return count >= 28 }
        return true
    }

    /// The `count` periods of the same choice before this one, most recent first.
    func previous(count: Int, choice: Choice, renewalDay: Int?, calendar: Calendar) -> [TokenBurnPeriod] {
        var result: [TokenBurnPeriod] = []
        var cursor = self
        for _ in 0..<max(count, 0) {
            cursor = TokenBurnPeriod.current(choice: choice, renewalDay: renewalDay, now: cursor.start.addingTimeInterval(-1),
                                             calendar: calendar)
            result.append(cursor)
        }
        return result
    }

    /// The `count` periods before this one, most recent first.
    func previous(count: Int, renewalDay: Int?, calendar: Calendar) -> [TokenBurnPeriod] {
        var result: [TokenBurnPeriod] = []
        var cursor = self
        for _ in 0..<max(count, 0) {
            cursor = TokenBurnPeriod.current(renewalDay: renewalDay, now: cursor.start.addingTimeInterval(-1), calendar: calendar)
            result.append(cursor)
        }
        return result
    }
}

/// One account's figure for one period, next to its plan.
struct AccountPlanValue: Equatable, Sendable {
    let period: TokenBurnPeriod
    let value: PlanValue
    /// Monthly plan price; nil when the plan tier is not known.
    let planPriceUSD: Decimal?

    /// Value ÷ plan price, only with a known, positive price.
    var ratio: Decimal? {
        guard let planPriceUSD, planPriceUSD > 0, period.comparesWithMonthlyPrice else { return nil }
        return value.cents / (planPriceUSD * 100)
    }

    /// Some tokens are unpriced or were priced at an assumed rate.
    var isAtLeast: Bool { !value.isComplete }
}
