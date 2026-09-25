import Foundation

/// An OPTIONAL secondary utilisation line for the `.modelWeekly` (Fable)
/// sub-limit, carried alongside the label so the view never has to hardcode
/// "Fable" text. `nil` (the whole `FableSecondary?` on `BillingCycleCard`)
/// means Fable isn't present at all for this account (gated on the CURRENT
/// snapshot's modelWeekly window — see `card(...)`). When present but
/// `summary` is nil, the metric hasn't accrued enough rollups yet: the view
/// must render an honest "not enough data yet", never a fabricated percentage.
struct FableSecondary: Equatable {
    let label: String
    let summary: CycleUtilizationSummary?
}

/// One row in the Billing-cycle list.
enum BillingCycleCard: Equatable, Identifiable {
    case noRenewalDay(id: UUID, label: String, provider: Provider)
    /// `fable`: never the headline — `summary` (weekly/5h via `selectWindow`)
    /// always is. See `FableSecondary` for the presence/insufficient-data
    /// semantics.
    case tracked(id: UUID, label: String, provider: Provider,
                 cycle: BillingCycle, summary: CycleUtilizationSummary,
                 fable: FableSecondary?)

    var id: UUID {
        switch self {
        case let .noRenewalDay(id, _, _): id
        case let .tracked(id, _, _, _, _, _): id
        }
    }
}

/// Pure mapping from an account + its loaded rollups to a card. Loading the
/// window kinds is the view's job (off-main via `UsageHistoryStore.loadRollups`);
/// this stays SwiftUI-free and fully unit-tested.
enum BillingCycleSectionModel {
    static func card(
        account: AccountRecord,
        weekly: [UsageHourlyBucket],
        fiveHour: [UsageHourlyBucket],
        modelWeekly: [UsageHourlyBucket] = [],
        fablePresent: Bool = false,
        fableLabel: String? = nil,
        now: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> BillingCycleCard {
        let label: String = account.historyLabel(locale: locale)
        guard let renewalDay = account.billingRenewalDay else {
            return .noRenewalDay(id: account.id, label: label, provider: account.provider)
        }
        let cycle = BillingCycle.current(renewalDay: renewalDay, now: now, calendar: calendar)
        let weeklySummary = BillingCycleAnalyzer.summarize(
            buckets: weekly, windowKind: .weekly, cycle: cycle, calendar: calendar)
        let fiveHourSummary = BillingCycleAnalyzer.summarize(
            buckets: fiveHour, windowKind: .fiveHour, cycle: cycle, calendar: calendar)
        let summary = selectWindow(weekly: weeklySummary, fiveHour: fiveHourSummary)
        // Fable is a supporting sub-limit line, never the headline. Visibility
        // gates on `fablePresent` — the CURRENT snapshot's modelWeekly presence —
        // NOT on whether modelWeekly rollups happen to be non-empty. Rollups are
        // retained forever, so gating on them would keep a stale Fable secondary
        // visible after a Max→non-Max downgrade, and hide a fresh Max account's
        // Fable line until rollups accrue. When present, the summary itself is
        // still gated on its own sufficiency floor so an under-observed cycle
        // never fabricates a percentage — `nil` there renders "not enough data
        // yet" instead.
        let fable: FableSecondary?
        if fablePresent {
            let fableSummary = BillingCycleAnalyzer.summarize(
                buckets: modelWeekly, windowKind: .modelWeekly, cycle: cycle, calendar: calendar)
            fable = FableSecondary(
                label: fableLabel ?? "Fable",
                summary: fableSummary.isSufficient ? fableSummary : nil
            )
        } else {
            fable = nil
        }
        return .tracked(id: account.id, label: label, provider: account.provider,
                        cycle: cycle, summary: summary, fable: fable)
    }

    /// Prefer the weekly (plan-defining) window when it is sufficient; else the 5h
    /// window if IT is sufficient; else the better-covered of the two (so the card's
    /// own honesty gate still renders "Not enough data yet").
    static func selectWindow(
        weekly: CycleUtilizationSummary,
        fiveHour: CycleUtilizationSummary
    ) -> CycleUtilizationSummary {
        if weekly.isSufficient { return weekly }
        if fiveHour.isSufficient { return fiveHour }
        return weekly.coverageFraction >= fiveHour.coverageFraction ? weekly : fiveHour
    }
}

/// The text of a Billing cycle card, resolved in one language. Numbers go
/// through `UsageFormatters` and keep their 1.3.0 English form ("≥ 42%",
/// "1.5×").
enum BillingCycleCopy {
    static func noCycleSubtitle(locale: Locale = .current) -> String {
        LocalizedStringResource.billingSubtitleNone.string(in: locale)
    }

    /// "Cycle Sep 12 – Oct 11 · Day 3/30". The last day shown is the day
    /// before the (exclusive) end.
    static func cycleSubtitle(
        _ cycle: BillingCycle,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day()
        let first: String = cycle.start.formatted(style)
        let last: String = cycle.end.addingTimeInterval(-1).formatted(style)
        return LocalizedStringResource
            .billingSubtitleCycle(first, last, cycle.dayIndex, cycle.totalDays)
            .string(in: locale)
    }

    /// The headline, drawn in the display face: "≥ 42%".
    static func headline(_ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        "≥ " + percent(summary.capacityUtilization, locale: locale, monospaced: false)
    }

    /// Shown while too few hours were watched: "watched 40 of 58 hrs · Day 3/30".
    static func watched(_ summary: CycleUtilizationSummary, cycle: BillingCycle, locale: Locale = .current) -> String {
        LocalizedStringResource
            .billingWatched(summary.observedHours, summary.elapsedHours, cycle.dayIndex, cycle.totalDays)
            .string(in: locale)
    }

    /// "≥ 1.5× weekly allowance · Used 2 days · At ≥95% 1 day · watched 40/58 hrs".
    /// Both day counts are catalog plurals.
    /// The watched hours are capped at the elapsed hours.
    static func detail(_ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        let watched: Int = min(summary.observedHours, summary.elapsedHours)
        return LocalizedStringResource
            .billingDetail(
                allowance(summary, locale: locale),
                daysUsed: summary.daysUsed,
                atCapDays: summary.atCapDays,
                watched,
                summary.elapsedHours
            )
            .string(in: locale)
    }

    static func fableValue(label: String, _ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        let value: String = percent(summary.capacityUtilization, locale: locale, monospaced: true)
        return LocalizedStringResource.billingFableValue(label, value).string(in: locale)
    }

    static func fableInsufficient(label: String, locale: Locale = .current) -> String {
        LocalizedStringResource.billingFableInsufficient(label).string(in: locale)
    }

    /// "≥ 1.5× weekly allowance".
    private static func allowance(_ summary: CycleUtilizationSummary, locale: Locale) -> String {
        let number: String = UsageFormatters.oneDecimal(summary.consumedAllowances, locale: locale)
        let resource: LocalizedStringResource = summary.windowKind == .weekly
            ? .billingAllowanceWeekly(number)
            : .billingAllowanceFiveHour(number)
        return resource.string(in: locale)
    }

    private static func percent(_ fraction: Double, locale: Locale, monospaced: Bool) -> String {
        let whole: Int = Int((fraction * 100).rounded())
        return UsageFormatters.wholePercent(whole, monospaced: monospaced, locale: locale)
    }
}
