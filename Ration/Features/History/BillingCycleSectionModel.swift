import Foundation

/// An OPTIONAL secondary utilisation line for the `.modelWeekly` (Fable)
/// sub-limit, carried alongside the label so the view never has to hardcode
/// "Fable" text. `nil` (the whole `FableSecondary?` on `BillingCycleCard`)
/// means Fable isn't present at all for this account (gated on the CURRENT
/// snapshot's modelWeekly window — see `card(...)`). When present but
/// `summary` is nil, the metric hasn't accrued enough rollups yet: the view
/// must render an honest "not enough data yet", never a fabricated percentage.
struct FableSecondary: Equatable, Sendable {
    let label: String
    let summary: CycleUtilizationSummary?
}

/// One row in the Billing-cycle list.
enum BillingCycleCard: Equatable, Identifiable, Sendable {
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

    /// The card with its label read again from the current accounts, at
    /// render time: a rename in Settings changes no load key, so the stored
    /// label would stay stale until the next reload. A card whose account is
    /// gone keeps its stored label.
    func relabeled(from accounts: [AccountRecord], locale: Locale = .current) -> BillingCycleCard {
        guard let account = accounts.first(where: { $0.id == id }) else { return self }
        let label: String = account.historyLabel(locale: locale)
        switch self {
        case let .noRenewalDay(id, _, provider):
            return .noRenewalDay(id: id, label: label, provider: provider)
        case let .tracked(id, _, provider, cycle, summary, fable):
            return .tracked(id: id, label: label, provider: provider, cycle: cycle, summary: summary, fable: fable)
        }
    }
}

/// Every line a Billing-cycle card draws, resolved in one language. The card
/// view renders exactly these strings, so a test of this model is a test of
/// the card's copy.
struct BillingCycleCardText: Equatable, Sendable {
    struct FableLine: Equatable, Sendable {
        let text: String
        /// Drawn dimmer: "Fable · not enough data yet this cycle".
        let isInsufficient: Bool
    }

    enum Body: Equatable, Sendable {
        /// No renewal day: the view's fixed "Set a renewal day…" prompt and button.
        case noRenewalDay
        /// Too little data: "Not enough data yet" over the watched line.
        case insufficient(notEnoughData: String, watched: String)
        /// The figure: headline, caption (drawn uppercase), detail, and the
        /// optional Fable line.
        case figure(headline: String, caption: String, detail: String, fable: FableLine?)
    }

    let label: String
    let subtitle: String
    let body: Body
}

/// Everything one account's card needs, gathered on the main actor (rollups
/// from `UsageHistoryStore.loadRollups`, Fable presence from the current
/// snapshot) and handed as a value to the off-main batch.
struct BillingCycleCardInput: Equatable, Sendable {
    let account: AccountRecord
    let weekly: [UsageHourlyBucket]
    let fiveHour: [UsageHourlyBucket]
    let modelWeekly: [UsageHourlyBucket]
    let fablePresent: Bool
    let fableLabel: String?
}

/// Identity of the Billing-cycle window's load: the card reloads when
/// any part changes. Built from `HistoryRefreshClock`'s `now` and zone.
struct BillingCycleLoadKey: Hashable, Sendable {
    struct AccountPart: Hashable, Sendable {
        let id: UUID
        let renewalDay: Int?
        let plan: PlanTier?
        /// Drives the card's "— PAUSED" label.
        let isPaused: Bool
        /// The current cycle's start: moves when a renewal boundary is
        /// crossed. Nil without a renewal day.
        let cycleStart: Date?
    }

    let accounts: [AccountPart]
    /// `UsageHistoryStore.historyRevision`: new rollups (throttled).
    let historyRevision: Int
    /// Start of today in `timeZoneID`: moves at midnight ("Day 3/30",
    /// "watched X/Y hrs").
    let day: Date
    let timeZoneID: String

    static func make(
        accounts: [AccountRecord],
        historyRevision: Int,
        now: Date,
        timeZone: TimeZone
    ) -> BillingCycleLoadKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts: [AccountPart] = []
        for account in accounts {
            var cycleStart: Date?
            if let renewalDay = account.billingRenewalDay {
                cycleStart = BillingCycle.current(renewalDay: renewalDay, now: now, calendar: calendar).start
            }
            parts.append(AccountPart(
                id: account.id, renewalDay: account.billingRenewalDay, plan: account.plan,
                isPaused: account.isPaused, cycleStart: cycleStart
            ))
        }
        return BillingCycleLoadKey(
            accounts: parts,
            historyRevision: historyRevision,
            day: calendar.startOfDay(for: now),
            timeZoneID: timeZone.identifier
        )
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
        // The family is the provider's, never inferred from the rollups. Cursor is
        // never eligible for this window (see `BillingCycleEligibility`); if one
        // reached here it would have no rollups, so any family reads "not enough data".
        let family: WindowFamily = WindowFamily(provider: account.provider) ?? .rolling
        let weeklySummary = BillingCycleAnalyzer.summarize(
            buckets: weekly, windowKind: .weekly, family: family, cycle: cycle, calendar: calendar)
        let fiveHourSummary = BillingCycleAnalyzer.summarize(
            buckets: fiveHour, windowKind: .fiveHour, family: family, cycle: cycle, calendar: calendar)
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
                buckets: modelWeekly, windowKind: .modelWeekly, family: family, cycle: cycle, calendar: calendar)
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

    /// Every account's card, in input order: the synchronous form of
    /// `cardsOffMain`. `shouldStop` is checked before each account; when it
    /// says stop, the pass returns no cards (a partial list is never shown).
    static func cards(
        _ inputs: [BillingCycleCardInput],
        now: Date,
        calendar: Calendar,
        locale: Locale = .current,
        shouldStop: () -> Bool = { false }
    ) -> [BillingCycleCard] {
        var result: [BillingCycleCard] = []
        result.reserveCapacity(inputs.count)
        for input in inputs {
            if shouldStop() { return [] }
            result.append(card(
                account: input.account, weekly: input.weekly, fiveHour: input.fiveHour,
                modelWeekly: input.modelWeekly, fablePresent: input.fablePresent,
                fableLabel: input.fableLabel, now: now, calendar: calendar, locale: locale
            ))
        }
        return result
    }

    /// One detached pass over every account: the analyzer walks every
    /// in-cycle bucket, so it must not run on the main actor. Only the
    /// resulting cards — each account's summaries plus its label and cycle,
    /// no buckets — come back. `isolationProbe` (tests) receives
    /// `Thread.isMainThread` from inside the pass.
    static func cardsOffMain(
        _ inputs: [BillingCycleCardInput],
        now: Date,
        calendar: Calendar,
        locale: Locale = .current,
        isolationProbe: (@Sendable (Bool) -> Void)? = nil
    ) async -> [BillingCycleCard] {
        let pass = Task.detached(priority: .userInitiated) { () -> [BillingCycleCard] in
            if let isolationProbe {
                isolationProbe(isOnMainThread())
            }
            return cards(inputs, now: now, calendar: calendar, locale: locale, shouldStop: {
                Task.isCancelled
            })
        }
        // A detached task does not inherit cancellation: forward it, so a
        // reload superseded by a newer key stops at the next account instead
        // of finishing a result nobody will show.
        return await withTaskCancellationHandler {
            await pass.value
        } onCancel: {
            pass.cancel()
        }
    }

    /// `Thread.isMainThread`, read from a synchronous frame.
    private static func isOnMainThread() -> Bool {
        Thread.isMainThread
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
/// through `UsageFormatters`.
///
/// Two framings, switched on `isLegacyLowerBound`:
/// - v2 (rolling average load, fixed average peak): a plain "42%", clamped to
///   0–100, with a caption naming the family and window.
/// - legacy (a rolling window without enough v2 data yet): the exact 1.4.0
///   copy — "≥ 42%", "observed lower bound", the allowance multiple.
enum BillingCycleCopy {
    /// Everything `card` draws, in `locale`.
    static func cardText(
        _ card: BillingCycleCard,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> BillingCycleCardText {
        switch card {
        case let .noRenewalDay(_, label, _):
            return BillingCycleCardText(label: label, subtitle: noCycleSubtitle(locale: locale), body: .noRenewalDay)
        case let .tracked(_, label, _, cycle, summary, fable):
            let subtitle: String = cycleSubtitle(cycle, locale: locale, timeZone: timeZone)
            guard summary.isSufficient else {
                let notEnough: String = LocalizedStringResource(
                    "Not enough data yet",
                    comment: "History › Billing cycle card before enough hours were watched."
                ).string(in: locale)
                return BillingCycleCardText(
                    label: label, subtitle: subtitle,
                    body: .insufficient(notEnoughData: notEnough, watched: watched(summary, cycle: cycle, locale: locale))
                )
            }
            var fableLine: BillingCycleCardText.FableLine?
            if let fable {
                if let fableSummary = fable.summary {
                    fableLine = .init(text: fableValue(label: fable.label, fableSummary, locale: locale), isInsufficient: false)
                } else {
                    fableLine = .init(text: fableInsufficient(label: fable.label, locale: locale), isInsufficient: true)
                }
            }
            return BillingCycleCardText(
                label: label, subtitle: subtitle,
                body: .figure(
                    headline: headline(summary, locale: locale),
                    caption: caption(summary, locale: locale),
                    detail: detail(summary, locale: locale),
                    fable: fableLine
                )
            )
        }
    }

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

    /// The fraction shown (and tier-coloured): v2 clamped to [0, 1]; the
    /// legacy figure as it always was (it may exceed 1).
    static func displayFraction(_ summary: CycleUtilizationSummary) -> Double {
        if summary.isLegacyLowerBound { return summary.capacityUtilization }
        return min(max(summary.capacityUtilization, 0), 1)
    }

    /// The headline, drawn in the display face: "42%" (v2) or "≥ 42%" (legacy).
    static func headline(_ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        let value: String = percent(displayFraction(summary), locale: locale, monospaced: false)
        return summary.isLegacyLowerBound ? "≥ " + value : value
    }

    /// The line under the headline, shown uppercase: what the figure means.
    static func caption(_ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        if summary.isLegacyLowerBound {
            return LocalizedStringResource(
                "observed lower bound",
                comment: "History › Billing cycle card, shown uppercase under the percentage: the true figure is at least this."
            ).string(in: locale)
        }
        return meaning(summary).string(in: locale)
    }

    /// Whole hours watched, from the summary's measured watched seconds.
    static func watchedHours(_ summary: CycleUtilizationSummary) -> Int {
        let hours: Double = (summary.watchedSeconds / 3600).rounded(.down)
        return max(0, Int(hours))
    }

    /// Shown while too few hours were watched: "watched 40 of 58 hrs · Day 3/30".
    static func watched(_ summary: CycleUtilizationSummary, cycle: BillingCycle, locale: Locale = .current) -> String {
        LocalizedStringResource
            .billingWatched(watchedHours(summary), summary.elapsedHours, cycle.dayIndex, cycle.totalDays)
            .string(in: locale)
    }

    /// v2: "Used 2 days · At ≥95% 1 day · watched 40/58 hrs".
    /// Legacy: "≥ 1.5× weekly allowance · Used 2 days · At ≥95% 1 day · watched 40/58 hrs".
    /// The allowance multiple is net burn, the legacy metric, so only the
    /// legacy line carries it. Both day counts are catalog plurals. The
    /// watched hours are capped at the elapsed hours.
    static func detail(_ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        let watched: Int = min(watchedHours(summary), summary.elapsedHours)
        if summary.isLegacyLowerBound {
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
        return LocalizedStringResource
            .billingDetailLoad(
                daysUsed: summary.daysUsed,
                atCapDays: summary.atCapDays,
                watched,
                summary.elapsedHours
            )
            .string(in: locale)
    }

    /// v2: "Fable 42% this cycle · average weekly load". Legacy: "Fable ≥ 42% this cycle".
    static func fableValue(label: String, _ summary: CycleUtilizationSummary, locale: Locale = .current) -> String {
        let value: String = percent(displayFraction(summary), locale: locale, monospaced: true)
        if summary.isLegacyLowerBound {
            return LocalizedStringResource.billingFableValue(label, value).string(in: locale)
        }
        let meaning: String = caption(summary, locale: locale)
        return LocalizedStringResource.billingFableLoad(label, value, meaning).string(in: locale)
    }

    static func fableInsufficient(label: String, locale: Locale = .current) -> String {
        LocalizedStringResource.billingFableInsufficient(label).string(in: locale)
    }

    /// The v2 caption: the family's meaning for the window kind. The
    /// model-weekly (Fable) limit is a weekly window.
    private static func meaning(_ summary: CycleUtilizationSummary) -> LocalizedStringResource {
        switch (summary.family, summary.windowKind) {
        case (.rolling, .fiveHour): .billingCaptionRollingFiveHour
        case (.rolling, .weekly), (.rolling, .modelWeekly): .billingCaptionRollingWeekly
        case (.fixed, .fiveHour): .billingCaptionFixedFiveHour
        case (.fixed, .weekly), (.fixed, .modelWeekly): .billingCaptionFixedWeekly
        }
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
