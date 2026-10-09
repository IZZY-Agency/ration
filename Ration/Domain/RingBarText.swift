import Foundation

/// A ring-bar hover card's content, computed with the same `now` as the
/// gauges it explains.
struct RingBarCard: Equatable {
    struct Line: Equatable {
        let text: String
        let detail: String?
        let isStale: Bool
    }

    let source: DisplaySource
    let provider: String
    let title: String
    let inUse: Bool
    let lines: [Line]

}

/// What the ring bar writes. Reuses the popover's and the tooltip's copy
/// wherever it says the same thing.
enum RingBarText {
    /// Inside a provider's group the provider's name is noise: "ChatGPT 20x"
    /// draws "20x". A label that IS the provider name stays.
    static func shortLabel(_ label: String, in source: DisplaySource) -> String {
        let prefix = source.displayName + " "
        guard label.count > prefix.count, label.lowercased().hasPrefix(prefix.lowercased()) else { return label }
        return String(label.dropFirst(prefix.count))
    }

    /// The whole number a capsule draws, rounded the tooltip's way; budgets
    /// from their unclamped percent, so an overspend reads as one.
    static func percent(for gauge: MenuBarGauge, displaysRemaining: Bool) -> Int {
        if let budget = gauge.budget {
            return displaysRemaining
                ? max(0, APIMoney.wholePercent(100 - budget.exactPercent, budget.isLowerBound ? .up : .plain))
                : APIMoney.wholePercent(budget.exactPercent, budget.isLowerBound ? .down : .plain)
        }
        return Int((gauge.fraction * 100).rounded())
    }

    static func card(for entry: GaugeEntry, displaysRemaining: Bool, now: Date, locale: Locale = .current) -> RingBarCard {
        let gauge = entry.gauge
        let lines: [RingBarCard.Line]
        switch entry.details {
        case .subscription(let snapshot):
            lines = [UsageWindowKind.fiveHour, .weekly, .modelWeekly].compactMap { kind in
                guard let window = snapshot.window(for: kind) else { return nil }
                return windowLine(kind: kind, window: window, snapshot: snapshot,
                                  displaysRemaining: displaysRemaining, now: now, locale: locale)
            }
        case .apiBudget(let presentation?, let thresholds):
            let text = APISpendCardText.text(for: presentation, thresholds: thresholds, now: now, locale: locale)
            lines = [RingBarCard.Line(
                text: [text.headline, text.budgetSuffix].compactMap { $0 }.joined(separator: " "),
                detail: text.caption.isEmpty ? nil : text.caption,
                isStale: presentation.isStale
            )]
        case .apiBudget(nil, _), .credit:
            lines = [RingBarCard.Line(
                text: StatusItemFactory.toolTipEntry(gauge, displaysRemaining: displaysRemaining, locale: locale),
                detail: nil,
                isStale: false
            )]
        }
        return RingBarCard(source: gauge.source, provider: gauge.source.displayName, title: gauge.label,
                           inUse: gauge.inUse, lines: lines)
    }

    /// The card's lines for VoiceOver (the gauge's custom content), with the
    /// stale wording a sighted user sees as a badge.
    static func accessibilityDetails(for card: RingBarCard, locale: Locale = .current) -> [String] {
        card.lines.map { line in
            var parts = [line.text]
            if line.isStale { parts.append(LocalizedStringResource.badgeStale.string(in: locale)) }
            if let detail = line.detail { parts.append(detail) }
            return parts.joined(separator: ", ")
        }
    }

    /// What VoiceOver reads as a gauge's value: the tooltip's own entry.
    static func accessibilityLabel(for entry: GaugeEntry, displaysRemaining: Bool, locale: Locale = .current) -> String {
        StatusItemFactory.toolTipEntry(entry.gauge, displaysRemaining: displaysRemaining, locale: locale)
    }

    /// "5h 98% left" over "resets in 3h 43m · Oct 8, 19:59", stale when the
    /// snapshot no longer speaks for the present (`UsageEvidence`). Each
    /// share is rounded from its own fraction, as the gauge rounds it — never
    /// 100 minus the other rounded share.
    private static func windowLine(
        kind: UsageWindowKind, window: UsageWindow, snapshot: UsageSnapshot,
        displaysRemaining: Bool, now: Date, locale: Locale
    ) -> RingBarCard.Line {
        let title = AccountLimitLayout.title(for: kind, snapshot: snapshot)
        let text: LocalizedStringResource = displaysRemaining
            ? .ringBarCardWindowLeft(title, Int((window.remainingFraction * 100).rounded()))
            : .ringBarCardWindowUsed(title, Int(((1 - window.remainingFraction) * 100).rounded()))
        let detail: String = window.resetsAt.map { resetsAt in
            let resource: LocalizedStringResource = UsageFormatters.isResetDue(resetsAt, relativeTo: now)
                ? .resetResetsNow
                : .resetResetsIn(UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now, locale: locale))
            return resource.string(in: locale) + " · " + UsageFormatters.shortReset(resetsAt, locale: locale)
        } ?? LocalizedStringResource("no scheduled reset").string(in: locale)
        let current = UsageEvidence.isCurrent(snapshot: snapshot, windowResetsAt: window.resetsAt, now: now)
        return RingBarCard.Line(text: text.string(in: locale), detail: detail, isStale: !current)
    }
}
