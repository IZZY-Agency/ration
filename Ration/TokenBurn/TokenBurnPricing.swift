import Foundation

/// What some usage would have cost at the bundled API list prices (spec §5.3).
struct PlanValue: Equatable, Sendable {
    var cents: Decimal = 0
    var pricedTokens = 0
    var unpricedTokens = 0
    /// Priced at the standard rate because the log did not say the speed,
    /// region or tier — the lowest each could be, so still a lower bound.
    var assumedTokens = 0
    var replies = 0
    var webSearches = 0
    /// False when some tokens are unpriced or assumed: the figure is "at least".
    var isComplete: Bool { unpricedTokens == 0 && assumedTokens == 0 }
}

enum TokenBurnPricing {
    static func value(of totals: [TokenBurnStore.UsageTotal], table: ClaudePriceTable = .current) -> PlanValue {
        var value = PlanValue()
        for total in totals {
            let t = total.tokens
            value.replies += total.replies
            value.webSearches += total.webSearches
            value.cents += Decimal(total.webSearches) * table.webSearchCentsEach
            switch table.rates(for: total.priceClass) {
            case .unpriced:
                value.unpricedTokens += t.total
            case .priced(let rates, let multiplier):
                var perMillion = Decimal(t.input) * rates.input
                perMillion += Decimal(t.output) * rates.output
                perMillion += Decimal(t.cacheRead) * rates.cacheRead
                perMillion += Decimal(t.cacheWrite5m) * rates.cacheWrite5m
                perMillion += Decimal(t.cacheWrite1h) * rates.cacheWrite1h
                // USD per million tokens → cents: × 100 / 1,000,000.
                value.cents += perMillion * multiplier / 10_000
                let c = total.priceClass
                value.pricedTokens += t.total - t.cacheWriteUnsplit
                if c.speed.isEmpty || c.geo.isEmpty || c.tier.isEmpty { value.assumedTokens += t.total - t.cacheWriteUnsplit }
                value.unpricedTokens += t.cacheWriteUnsplit
            }
        }
        return value
    }
}
