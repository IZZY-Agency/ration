import Foundation

/// Pure card copy for an API org. Tested; the view only draws it.
enum APISpendCardText {
    typealias Text = (headline: String, budgetSuffix: String?, caption: String, meterFraction: Double?, meterTier: AlertTier?)

    static func text(for p: APIOrgPresentation, thresholds: ThresholdPair, now: Date, locale: Locale = .current) -> Text {
        guard let report = p.cost else { return ("—", nil, "", nil, nil) }
        if p.isOldMonth { return ("—", nil, LocalizedStringResource.apiSpendCardNewMonth.string(in: locale), nil, nil) }
        let lowerBound = p.coverage == .present
        let mtd = lowerBound ? APIMoney.flooredCents(report.monthToDateCents) : APIMoney.roundedCents(report.monthToDateCents)
        let headline = (lowerBound ? "≥ " : "") + UsageFormatters.usd(cents: mtd, locale: locale)
        let today = UsageFormatters.usd(cents: APIMoney.roundedCents(report.todayCents), locale: locale)
        // No bucket for today yet (Anthropic): the figures run through yesterday.
        let coversToday = report.coversToday ?? true
        // On the 1st "through yesterday" would name last month.
        let firstDay = UTCDay.start(of: report.fetchedAt) == report.month.start
        let reset = resetText(report.month.nextStart, now: now, locale: locale)
        var caption: String
        var suffix: String?
        var fraction: Double?
        var tier: AlertTier?
        if let budget = p.org.monthlyBudgetCents {
            let exact = APIMoney.exactPercent(spentCents: report.monthToDateCents, budgetCents: budget)
            let percent = APIMoney.wholePercent(exact, lowerBound ? .down : .plain)
            let shownPercent = (lowerBound ? "≥ " : "") + UsageFormatters.compactPercent(percent, locale: locale)
            caption = (coversToday
                ? LocalizedStringResource.apiSpendCardBudgetCaption(shownPercent, today, reset)
                : firstDay
                    ? LocalizedStringResource.apiSpendCardBudgetCaptionNoReportYet(shownPercent, reset)
                    : LocalizedStringResource.apiSpendCardBudgetCaptionThroughYesterday(shownPercent, reset)).string(in: locale)
            suffix = "/ " + AlertMessage.dollars(budget, locale: locale)
            fraction = min(max(NSDecimalNumber(decimal: exact / 100).doubleValue, 0), 1)
            tier = APIBudgetPolicy.tier(monthToDateCents: report.monthToDateCents, budgetCents: budget, thresholds: thresholds)
        } else {
            caption = (coversToday
                ? LocalizedStringResource.apiSpendCardNoBudgetCaption(today, reset)
                : firstDay
                    ? LocalizedStringResource.apiSpendCardNoBudgetCaptionNoReportYet(reset)
                    : LocalizedStringResource.apiSpendCardNoBudgetCaptionThroughYesterday(reset)).string(in: locale)
        }
        switch p.coverage {
        case .present?: caption += " · " + LocalizedStringResource.apiSpendCardPriorityNotIncluded.string(in: locale)
        case .unknown?: caption += " · " + LocalizedStringResource.apiSpendCardPriorityNotChecked.string(in: locale)
        default: break
        }
        return (headline, suffix, caption, fraction, tier)
    }

    static func resetText(_ reset: Date, now: Date, locale: Locale) -> String {
        let countdown = UsageFormatters.remainingUntilReset(reset, relativeTo: now, locale: locale)
        let resource: LocalizedStringResource = UsageFormatters.isResetDue(reset, relativeTo: now) ? .resetResetsNow : .resetResetsIn(countdown)
        return resource.string(in: locale)
    }

    /// VoiceOver: the countdown in words (like `CursorSpendRow.accessibilityDescription`).
    static func accessibilityDescription(for p: APIOrgPresentation, thresholds: ThresholdPair, now: Date, locale: Locale = .current) -> String {
        let t = text(for: p, thresholds: thresholds, now: now, locale: locale)
        var caption = t.caption
        if let reset = p.cost?.month.nextStart {
            let drawn = resetText(reset, now: now, locale: locale)
            let spoken: LocalizedStringResource = UsageFormatters.isResetDue(reset, relativeTo: now)
                ? .resetResetsNow
                : .resetResetsIn(UsageFormatters.spokenDuration(until: reset, relativeTo: now, locale: locale))
            caption = caption.replacingOccurrences(of: drawn, with: spoken.string(in: locale))
        }
        return [p.org.label, p.org.vendor.displayName, t.headline, t.budgetSuffix ?? "", caption]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Card / sheet copy for an `APISpendError`. Network,
/// server and integration failures reuse the account cards' own wording.
enum APISpendStateCopy {
    static func text(for error: APISpendError, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = switch error {
        case .keyRejected: .apiSpendStateKeyRejected
        case .noAdminAccess: .apiSpendStateNoAdminAccess
        case .keyMissing: .apiSpendStateKeyMissing
        case .keychain: .apiSpendStateKeychain
        case .rateLimited: .providerErrorRateLimited
        case .server: .providerErrorServer
        case .offline: .providerErrorOffline
        case .timeout, .transport: .providerErrorTransport
        case .integrationChanged, .redirectRefused: .providerErrorIntegrationChanged
        }
        return resource.string(in: locale)
    }
}
