import Foundation

struct DayCost: Codable, Equatable, Sendable { let dayStart: Date; let cents: Decimal }
struct ModelCost: Codable, Equatable, Sendable { let model: String; let cents: Decimal }
struct DescriptionCost: Codable, Equatable, Sendable { let description: String; let cents: Decimal }
struct LineItemCost: Codable, Equatable, Sendable { let lineItem: String; let cents: Decimal }

struct ModelTokens: Codable, Equatable, Sendable {
    let model: String
    /// nil = at least one contributing result lacked the field — never a partial sum.
    let input: Int?
    let cacheWrite: Int?
    let cacheRead: Int?
    let output: Int?
}

/// The authoritative cost path. Only this drives headline, gauge and alerts.
struct APICostReport: Codable, Equatable, Sendable {
    let month: UTCMonth
    let fetchedAt: Date
    /// When the refresh operation that produced this report started — the
    /// coverage rule compares it with the token report's.
    let refreshStartedAt: Date
    let days: [DayCost]
    let byModel: [ModelCost]
    let otherCharges: [DescriptionCost]
    let byLineItem: [LineItemCost]
    /// Whether the vendor sent a bucket (even an empty one) for the UTC day of
    /// `fetchedAt`. Anthropic's cost report has none until the day is over,
    /// so the card reads "through yesterday". nil: cached
    /// before this existed — treated as covering today until the next fetch.
    var coversToday: Bool? = nil

    var monthToDateCents: Decimal { days.reduce(0) { $0 + $1.cents } }

    func with(coversToday: Bool?) -> APICostReport {
        var copy = self
        copy.coversToday = coversToday
        return copy
    }

    var todayCents: Decimal {
        let today = UTCDay.start(of: fetchedAt)
        return days.first(where: { $0.dayStart == today })?.cents ?? 0
    }

    /// Current only while its REQUESTED month is the current UTC month.
    func isCurrent(at now: Date) -> Bool { month == UTCMonth(containing: now) }
}

struct APITokenReport: Codable, Equatable, Sendable {
    let month: UTCMonth
    let fetchedAt: Date
    let refreshStartedAt: Date
    let byModel: [ModelTokens]
    let hasPriorityTierUsage: Bool
}

/// Anthropic's cost report excludes Priority Tier.
enum PriorityCoverage: String, Codable, Sendable {
    case none, present, unknown

    /// nil for vendors with no documented exclusion (OpenAI).
    static func resolve(
        vendor: APIVendor,
        cost: APICostReport?,
        tokens: APITokenReport?,
        presentMonth: UTCMonth?
    ) -> PriorityCoverage? {
        guard vendor == .anthropic else { return nil }
        guard let cost else { return .unknown }
        if presentMonth == cost.month { return .present }
        guard let tokens, tokens.month == cost.month,
              tokens.refreshStartedAt >= cost.refreshStartedAt,
              !tokens.hasPriorityTierUsage
        else { return .unknown }
        return PriorityCoverage.none
    }
}

/// One org's last good reports — a display cache.
struct APISpendSnapshot: Codable, Equatable, Sendable {
    var cost: APICostReport?
    var tokens: APITokenReport?
    /// The month in which any token report showed Priority usage (sticky).
    var priorityPresentMonth: UTCMonth?
}
