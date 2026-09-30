import Foundation

/// USD per million tokens for one model at one speed.
struct ModelRates: Equatable, Sendable {
    let input: Decimal
    let cacheWrite5m: Decimal
    let cacheWrite1h: Decimal
    let cacheRead: Decimal
    let output: Decimal
}

/// Anthropic's API list prices, bundled per release (spec §5.3). Exact model
/// ids only: a model, speed, tier or region not listed here is never guessed.
struct ClaudePriceTable: Sendable {
    enum UnpricedReason: String, Equatable, Sendable {
        case unknownModel, unknownSpeed, unknownTier, unknownRegion, longContext
    }

    enum Resolution: Equatable, Sendable {
        case priced(ModelRates, multiplier: Decimal)
        case unpriced(UnpricedReason)
    }

    let asOf: String
    let source: URL
    let standard: [String: ModelRates]
    let fast: [String: ModelRates]
    /// Claude 4.6 and later: list price across the whole context window, and
    /// the 1.1× US-only inference multiplier applies.
    let modernModels: Set<String>
    /// $10 per 1,000 web searches.
    let webSearchCentsEach: Decimal

    static let longContextThreshold = 200_000

    func rates(for priceClass: PriceClass) -> Resolution {
        guard priceClass.tier.isEmpty || priceClass.tier == "standard" else { return .unpriced(.unknownTier) }
        let rates: ModelRates?
        switch priceClass.speed {
        case "", "standard": rates = standard[priceClass.model]
        case "fast":
            guard standard[priceClass.model] != nil else { return .unpriced(.unknownModel) }
            rates = fast[priceClass.model]
            if rates == nil { return .unpriced(.unknownSpeed) }
        default:
            return .unpriced(.unknownSpeed)
        }
        guard let rates else { return .unpriced(.unknownModel) }
        let modern = modernModels.contains(priceClass.model)
        if priceClass.longContext && !modern { return .unpriced(.longContext) }
        switch priceClass.geo {
        case "", "not_available", "global": return .priced(rates, multiplier: 1)
        case "us" where modern: return .priced(rates, multiplier: Self.decimal("1.1"))
        default: return .unpriced(.unknownRegion)
        }
    }

    private static func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private static func rates(_ input: String, _ write5m: String, _ write1h: String, _ read: String, _ output: String) -> ModelRates {
        ModelRates(input: decimal(input), cacheWrite5m: decimal(write5m), cacheWrite1h: decimal(write1h),
                   cacheRead: decimal(read), output: decimal(output))
    }

    /// When `current` was read from the pricing page (shown in Settings).
    static let listedOn: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12))!
    }()

    /// Read from the pricing page on 2026-09-29.
    static let current: ClaudePriceTable = {
        let opus = rates("5", "6.25", "10", "0.50", "25")
        let sonnet5 = rates("2", "2.50", "4", "0.20", "10")
        let sonnet4 = rates("3", "3.75", "6", "0.30", "15")
        let haiku = rates("1", "1.25", "2", "0.10", "5")
        let standard: [String: ModelRates] = [
            "claude-fable-5-1": rates("10", "12.50", "20", "0.25", "50"),
            "claude-fable-5": rates("10", "12.50", "20", "1", "50"),
            "claude-opus-5-5": rates("4", "5", "8", "0.20", "20"),
            "claude-opus-5": opus, "claude-opus-4-8": opus, "claude-opus-4-7": opus, "claude-opus-4-6": opus,
            "claude-sonnet-5-5": sonnet5, "claude-sonnet-5": sonnet5,
            "claude-sonnet-4-6": sonnet4, "claude-sonnet-4-5-20250929": sonnet4, "claude-sonnet-4-5": sonnet4,
            "claude-haiku-4-5-20251001": haiku, "claude-haiku-4-5": haiku,
        ]
        // Fast mode: premium input/output; cache multipliers apply on top.
        let fastOpus = rates("10", "12.50", "20", "1", "50")
        let fast: [String: ModelRates] = [
            "claude-opus-5-5": rates("8", "10", "16", "0.40", "40"),
            "claude-opus-5": fastOpus, "claude-opus-4-8": fastOpus,
        ]
        return ClaudePriceTable(
            asOf: "2026-09-29",
            source: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!,
            standard: standard, fast: fast,
            modernModels: ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8",
                           "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6"],
            webSearchCentsEach: 1)
    }()
}
