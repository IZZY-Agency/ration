import SwiftUI

/// The words and figures of a TypeSafe card (option B: balance first).
struct TypeSafeCard: Equatable {
    /// "$26.58", or "—" before the first reading.
    let headline: String
    let isAvailable: Bool
    /// The balance is older than `UsageEvidence.maxAge`: drawn faint.
    let isOld: Bool
    /// "$3.41 spent this cycle · resets in 1d".
    let caption: String
    /// The spend is older than `UsageEvidence.maxAge` (billing and daily
    /// usage are read apart, so each fades on its own).
    let captionIsOld: Bool
    let barsAreOld: Bool
    /// "$1.58 expires in 17d" while a grant is inside its warning window.
    let expiry: String?
    /// Estimated dollars per day of the current cycle so far, oldest first.
    let bars: [Double]
    let spoken: String
    /// Below the user's low-balance threshold: the headline is drawn in the
    /// warning colour, as the alert would say.
    var isLow: Bool = false

    static func make(
        snapshot: UsageSnapshot?, leadDays: Int, showsExpiry: Bool, now: Date,
        lowBalanceCents: Int? = nil, locale: Locale = .current
    ) -> TypeSafeCard {
        func old(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) > UsageEvidence.maxAge } ?? false }
        guard let credits = snapshot?.usageCredits else {
            // No balance read yet (a billing miss on the first fetch): the
            // daily usage still shows.
            return TypeSafeCard(
                headline: "—", isAvailable: false, isOld: false, caption: "", captionIsOld: false,
                barsAreOld: old(snapshot?.typeSafeDailyUsage?.fetchedAt), expiry: nil,
                bars: cycleBars(snapshot?.typeSafeDailyUsage, now: now), spoken: "—"
            )
        }
        let balance: String = UsageFormatters.money(credits.balance, locale: locale)
        let isOld = now.timeIntervalSince(credits.fetchedAt) > UsageEvidence.maxAge
        var caption = ""
        if let spend = snapshot?.typeSafeSpend {
            caption = LocalizedStringResource.typeSafeCardSpent(UsageFormatters.money(spend.cycleSpent, locale: locale)).string(in: locale)
            // A monthly cycle: whole days, else hours (never minutes, which
            // push the caption off the card in French).
            if let resetsAt = spend.resetsAt, resetsAt > now {
                caption += LocalizedStringResource.typeSafeCardResetsIn(UsageFormatters.resetCreditRemaining(resetsAt, relativeTo: now, locale: locale)).string(in: locale)
            }
        }
        var expiry: String?
        if showsExpiry,
           let summary = UsageCreditsSummary.make(credits: credits, enabled: nil, leadDays: leadDays, now: now,
                                                  verified: snapshot?.usageCreditsVerified ?? false),
           let expiring = summary.expiring {
            let amount: String = UsageFormatters.money(expiring.amount, locale: locale)
            expiry = UsageFormatters.isResetDue(expiring.expiresAt, relativeTo: now)
                ? LocalizedStringResource.typeSafeCardExpiresNow(amount).string(in: locale)
                : LocalizedStringResource.typeSafeCardExpiresIn(amount, UsageFormatters.resetCreditRemaining(expiring.expiresAt, relativeTo: now, locale: locale)).string(in: locale)
        }
        // Only a balance young enough to speak for the present: an old one is
        // drawn faint and never said to be below the alert.
        let isLow = !isOld && (lowBalanceCents.map { LowBalancePolicy.isBelow(credits.balance, thresholdCents: $0) } ?? false)
        let low: String? = isLow ? lowBalanceCents.map {
            LocalizedStringResource.typeSafeSpokenLow(LowBalancePolicy.thresholdText($0, like: credits.balance, locale: locale)).string(in: locale)
        } : nil
        let spoken: String = [LocalizedStringResource.typeSafeSpokenBalance(balance).string(in: locale), low ?? "", caption, expiry ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return TypeSafeCard(
            headline: balance, isAvailable: true, isOld: isOld, caption: caption,
            captionIsOld: old(snapshot?.typeSafeSpend?.fetchedAt), barsAreOld: old(snapshot?.typeSafeDailyUsage?.fetchedAt),
            expiry: expiry, bars: cycleBars(snapshot?.typeSafeDailyUsage, now: now), spoken: spoken, isLow: isLow
        )
    }

    /// One bar per UTC day of the cycle so far that the usage answer covers
    /// (the last 30 days): estimated dollars from input tokens. The cycle is
    /// the calendar month the console bills (it resets on the 1st). A covered
    /// day without an entry had no usage; a day before the coverage is
    /// unknown and left out rather than drawn as zero.
    static func cycleBars(_ usage: TypeSafeDailyUsage?, now: Date) -> [Double] {
        guard let usage else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let today = min(calendar.startOfDay(for: now), calendar.startOfDay(for: usage.fetchedAt))
        let byDay = Dictionary(usage.days.map { ($0.day, $0.inputTokens) }, uniquingKeysWith: +)
        var bars: [Double] = []
        var day = max(monthStart, usage.coverageStart)
        while day <= today {
            let tokens = byDay[day] ?? 0
            bars.append(NSDecimalNumber(decimal: TypeSafePrice.estimate(inputTokens: tokens)).doubleValue)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return bars
    }
}

/// A TypeSafe card's content: the balance headline with "left", the cycle's
/// daily bars, the spend caption and, near an expiry, the warning line.
struct TypeSafeCardView: View {
    let card: TypeSafeCard

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.headline)
                        .font(Theme.display(22, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(headlineColor)
                        .contentTransition(.numericText())
                    if card.isAvailable {
                        Text(LocalizedStringResource.typeSafeCardLeft)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.creamDim)
                    }
                }
                Spacer(minLength: 8)
                if card.bars.count >= 2 {
                    TypeSafeDayBars(values: card.bars)
                        .opacity(card.barsAreOld ? 0.45 : 1)
                }
            }
            if !card.caption.isEmpty {
                Text(card.caption)
                    .font(Theme.mono(14, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(card.captionIsOld ? Theme.creamFaint : Theme.resetAccent)
                    .lineLimit(1)
            }
            if let expiry = card.expiry {
                Text(expiry)
                    .font(Theme.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.warn)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.spoken)
    }

    private var headlineColor: Color {
        guard card.isAvailable, !card.isOld else { return Theme.creamFaint }
        return card.isLow ? Theme.warn : Theme.cream
    }
}

/// Thin daily bars scaled to the cycle's busiest day; today is drawn full
/// strength, the rest faint.
struct TypeSafeDayBars: View {
    let values: [Double]

    var body: some View {
        let peak = max(values.max() ?? 0, .leastNonzeroMagnitude)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(index == values.count - 1 ? Theme.typeSafeRose : Theme.creamFaint.opacity(0.6))
                    .frame(width: 3, height: max(1, 24 * value / peak))
            }
        }
        .frame(height: 24, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
