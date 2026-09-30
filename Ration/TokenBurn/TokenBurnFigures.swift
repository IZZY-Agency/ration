import Foundation

/// One account's figures: the chosen period and the three before it.
struct TokenBurnAccountValues: Equatable, Sendable {
    let current: AccountPlanValue
    let previous: [AccountPlanValue]
    /// The current period by model, largest value first.
    let byModel: [TokenBurnModelValue]
    let tokens: TokenCounts
    /// Where this account's proven time begins; nil before any.
    let since: Date?
}

struct TokenBurnModelValue: Equatable, Sendable {
    let model: String
    let value: PlanValue
}

/// One local day for History: the value per owner, days with no use included.
struct TokenBurnDay: Equatable, Sendable {
    let day: Date
    let values: [TokenBurnOwner: PlanValue]
}

/// The figures the cards, Settings and History show for the chosen period
/// (spec §5.2). Pure: minutes are attributed
/// once, then summed per period, owner, model and day.
enum TokenBurnFigures {
    struct Row: Sendable {
        let minute: Int64
        let owner: TokenBurnOwner
        let total: TokenBurnStore.UsageTotal
    }

    struct Result: Equatable, Sendable {
        var values: [UUID: TokenBurnAccountValues] = [:]
        /// Everything not on an account, over the days History shows.
        var pooled: [TokenBurnOwner: PlanValue] = [:]
        var days: [TokenBurnDay] = []
        /// All Claude Code use over those days, on an account or not: exact
        /// for the whole period, with no need to know whose it was.
        var total = PlanValue()
        /// When Ration first proved who was signed in: per account, figures
        /// start here. Nil before any reading.
        var trackingSince: Date?
    }

    static let pooledOwners: [TokenBurnOwner] = [.beforeTracking, .notObserved, .unassigned, .apiKey, .unclassified]

    static func compute(rows: [Row], accounts: [TokenBurnAccount], choice: TokenBurnPeriod.Choice,
                        proven: [TokenBurnTimeline.Proven], resolve: (SignInIdentity) -> TokenBurnOwner,
                        now: Date, calendar: Calendar) -> Result {
        // A link to an account Ration no longer has reads as unassigned.
        let known = Set(accounts.map(\.id))
        let rows = rows.map { row -> Row in
            if case .account(let id) = row.owner, !known.contains(id) {
                return Row(minute: row.minute, owner: .unassigned, total: row.total)
            }
            return row
        }
        func totals(_ start: Date, _ end: Date, _ include: (TokenBurnOwner) -> Bool) -> [TokenBurnStore.UsageTotal] {
            let from = minute(start), to = minute(end)
            return rows.filter { $0.minute >= from && $0.minute < to && include($0.owner) }.map(\.total)
        }

        var result = Result()
        for account in accounts {
            let current = TokenBurnPeriod.current(choice: choice, renewalDay: account.renewalDay, now: now, calendar: calendar)
            let periods = [current] + current.previous(count: 3, choice: choice, renewalDay: account.renewalDay, calendar: calendar)
            let price = ClaudePlanPrice.monthlyUSD(account.plan)
            let figures = periods.map { period in
                AccountPlanValue(period: period, value: TokenBurnPricing.value(of: totals(period.start, period.end) {
                    $0 == .account(account.id)
                }), planPriceUSD: price)
            }
            let mine = totals(current.start, current.end) { $0 == .account(account.id) }
            var tokens = TokenCounts()
            for total in mine { tokens += total.tokens }
            let byModel = Dictionary(grouping: mine, by: \.priceClass.model)
                .map { TokenBurnModelValue(model: $0.key, value: TokenBurnPricing.value(of: $0.value)) }
                .sorted { $0.value.cents != $1.value.cents ? $0.value.cents > $1.value.cents : $0.model < $1.model }
            let since = proven.filter { resolve($0.identity) == .account(account.id) }.map(\.start).min()
            result.values[account.id] = TokenBurnAccountValues(current: figures[0], previous: Array(figures.dropFirst()),
                                                               byModel: byModel, tokens: tokens, since: since)
        }

        let range = chartRange(accounts: accounts, choice: choice, now: now, calendar: calendar)
        result.total = TokenBurnPricing.value(of: totals(range.start, range.end) { _ in true })
        result.trackingSince = proven.map(\.start).min()
        for owner in pooledOwners {
            let value = TokenBurnPricing.value(of: totals(range.start, range.end) { $0 == owner })
            if value.replies > 0 { result.pooled[owner] = value }
        }
        var day = range.start
        while day < range.end {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let inDay = rows.filter { $0.minute >= minute(day) && $0.minute < minute(next) }
            var values: [TokenBurnOwner: PlanValue] = [:]
            for (owner, group) in Dictionary(grouping: inDay, by: \.owner) {
                values[owner] = TokenBurnPricing.value(of: group.map(\.total))
            }
            result.days.append(TokenBurnDay(day: day, values: values))
            day = next
        }
        return result
    }

    /// The first minute any figure needs: every account's period and the
    /// three before it.
    static func earliest(accounts: [TokenBurnAccount], choice: TokenBurnPeriod.Choice, now: Date,
                         calendar: Calendar) -> Date {
        let starts = accounts.flatMap { account -> [Date] in
            let current = TokenBurnPeriod.current(choice: choice, renewalDay: account.renewalDay, now: now, calendar: calendar)
            return ([current] + current.previous(count: 3, choice: choice, renewalDay: account.renewalDay, calendar: calendar))
                .map(\.start)
        }
        let range = chartRange(accounts: accounts, choice: choice, now: now, calendar: calendar)
        return (starts + [range.start]).min() ?? range.start
    }

    /// History's days: the chosen period up to tonight. A billing cycle
    /// differs per account, so it starts at the earliest current cycle.
    static func chartRange(accounts: [TokenBurnAccount], choice: TokenBurnPeriod.Choice, now: Date,
                           calendar: Calendar) -> (start: Date, end: Date) {
        let tonight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let starts = choice == .billingCycle
            ? accounts.map { TokenBurnPeriod.current(choice: choice, renewalDay: $0.renewalDay, now: now, calendar: calendar).start }
            : []
        let start = starts.min() ?? TokenBurnPeriod.current(choice: choice, renewalDay: nil, now: now, calendar: calendar).start
        return (start, tonight)
    }

    private static func minute(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 60).rounded(.down)) }
}
