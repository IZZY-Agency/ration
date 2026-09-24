import SwiftUI

/// The "Billing cycle" section of the History window: one card per subscription,
/// showing burn-based capacity utilisation for the current renewal-to-renewal
/// cycle. Loads each window kind off-main via `loadRollups`, then maps them with
/// the pure `BillingCycleSectionModel` on the main actor (cheap arithmetic, same
/// pattern as `HistoryView`'s existing `UsageHistoryAggregator` use).
struct BillingCycleView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var cards: [BillingCycleCard] = []
    @State private var hasLoaded = false

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    var body: some View {
        Group {
            switch BillingCycleEligibility.presentation(accounts: model.accounts, cards: cards) {
            case .noAccounts:
                ContentUnavailableView {
                    Label("No accounts", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Add \(BillingCycleEligibility.supportedProviderNames) to track billing cycles.")
                }
                .background(Theme.ink)

            case .noEligibleAccounts:
                // A Cursor-only install. Without this branch the window would
                // render an empty scroll view, reading as a bug rather than as
                // the deliberate v1 exclusion it is.
                ContentUnavailableView {
                    Label("Nothing to reconstruct", systemImage: "calendar.badge.checkmark")
                } description: {
                    Text("Cursor reports its billing cycle directly — see the usage rows on its account card. This window reconstructs cycle usage for \(BillingCycleEligibility.supportedProviderNames), which don't report it.")
                }
                .background(Theme.ink)

            case _ where !hasLoaded:
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .noRenewalDaysSet:
                ContentUnavailableView {
                    Label("No billing cycles set", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Set a billing renewal day for an account in Settings to see its cycle utilisation.")
                } actions: {
                    BillingCTAButton(title: "Set a billing renewal day") {
                        openWindow(id: "settings")
                    }
                }
                .background(Theme.ink)

            case .cards:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(cards) { card in
                            BillingCycleCardView(card: card)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Identity includes `isPaused` so a card's "— PAUSED" label reloads the
        // instant a pause/resume lands, instead of going stale until another
        // trigger (id/renewal-day change) fires while this window stays open.
        .task(id: model.accounts.map { "\($0.id.uuidString):\($0.billingRenewalDay ?? -1):\($0.isPaused)" }) { await reload() }
    }

    private func reload() async {
        let now = Date.now
        let cal = calendar
        var built: [BillingCycleCard] = []
        // Filter BEFORE the rollup loads, not just before rendering: an
        // excluded account should cost no disk reads either.
        for account in BillingCycleEligibility.eligible(model.accounts) {
            let weekly = await model.history.loadRollups(accountID: account.id, kind: .weekly)
            let fiveHour = await model.history.loadRollups(accountID: account.id, kind: .fiveHour)
            let modelWeekly = await model.history.loadRollups(accountID: account.id, kind: .modelWeekly)
            if Task.isCancelled { return } // never publish from a superseded task
            // Fable visibility gates on the CURRENT snapshot's modelWeekly window
            // (presence + API label), not on the rollups loaded above — those feed
            // only the metric. See `BillingCycleSectionModel.card` for why.
            let currentModelWindow = model.presentations.first { $0.id == account.id }?.snapshot?.modelWeekly
            built.append(BillingCycleSectionModel.card(
                account: account, weekly: weekly, fiveHour: fiveHour, modelWeekly: modelWeekly,
                fablePresent: currentModelWindow != nil, fableLabel: currentModelWindow?.label,
                now: now, calendar: cal))
        }
        guard !Task.isCancelled else { return }
        cards = built
        hasLoaded = true
    }
}

/// Renders a single card. Insufficient / empty summaries show "Not enough data yet".
private struct BillingCycleCardView: View {
    let card: BillingCycleCard
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch card {
            case let .noRenewalDay(_, label, provider):
                header(label: label, provider: provider, subtitle: "No billing cycle set")
                Text("Set a renewal day in Settings to track this subscription's cycle.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                BillingCTAButton(title: "Set a renewal day", prominent: false) {
                    openWindow(id: "settings")
                }
                .padding(.top, 2)
            case let .tracked(_, label, provider, cycle, summary, fable):
                header(label: label, provider: provider, subtitle: cycleSubtitle(cycle))
                if summary.isSufficient {
                    sufficientBody(summary, fable: fable)
                } else {
                    Text("Not enough data yet")
                        .font(Theme.display(17, .semibold))
                        .foregroundStyle(Theme.creamDim)
                    Text("watched \(summary.observedHours) of \(summary.elapsedHours) hrs · Day \(cycle.dayIndex)/\(cycle.totalDays)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamFaint)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func header(label: String, provider: Provider, subtitle: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(provider.markAccent.opacity(Theme.markFillOpacity(colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(provider.markAccent.opacity(0.4)))
                .frame(width: 28, height: 28)
                .overlay(Text(provider.markLetter).font(Theme.mono(14, bold: true)).foregroundStyle(provider.markAccent))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(Theme.display(16, .semibold)).foregroundStyle(Theme.cream)
                Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.creamFaint)
            }
            Spacer()
        }
    }

    private func sufficientBody(_ s: CycleUtilizationSummary, fable: FableSecondary?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("≥ \(Int((s.capacityUtilization * 100).rounded()))%")
                .font(Theme.display(28, .bold))
                .foregroundStyle(Theme.tierColor(usedFraction: min(s.capacityUtilization, 1)))
            Text("observed lower bound")
                .font(Theme.mono(11))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.creamFaint)
            Text("\(allowanceLabel(s)) · Used \(s.daysUsed) days · At ≥95% \(s.atCapDays) days · watched \(min(s.observedHours, s.elapsedHours))/\(s.elapsedHours) hrs")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
            // Fable is a supporting sub-limit line, never the headline. `fable` is
            // nil only when Fable isn't present at all for this account; when
            // present but its own metric hasn't cleared the sufficiency floor yet,
            // render an honest "not enough data" line instead of a fabricated %.
            if let fable {
                if let fableSummary = fable.summary {
                    Text("\(fable.label) ≥ \(Int((fableSummary.capacityUtilization * 100).rounded()))% this cycle")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                } else {
                    Text("\(fable.label) · not enough data yet this cycle")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamFaint)
                }
            }
        }
    }

    private func allowanceLabel(_ s: CycleUtilizationSummary) -> String {
        let unit = s.windowKind == .weekly ? "weekly" : "5h"
        return String(format: "≥ %.1f× %@ allowance", s.consumedAllowances, unit)
    }

    private func cycleSubtitle(_ cycle: BillingCycle) -> String {
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "Cycle \(cycle.start.formatted(f)) – \(cycle.end.addingTimeInterval(-1).formatted(f)) · Day \(cycle.dayIndex)/\(cycle.totalDays)"
    }
}

/// A CTA styled to match the app's gold-pill button idiom (see the popover's
/// "Add Account" empty-state button). `prominent` = filled gold (primary); else a
/// gold-outline pill for lighter, per-card use where a filled pill would be loud.
private struct BillingCTAButton: View {
    let title: String
    var prominent: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(12.5, bold: true))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(prominent ? Theme.onGold : Theme.gold)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 7).fill(Theme.gold)
                    } else {
                        RoundedRectangle(cornerRadius: 7).stroke(Theme.gold.opacity(0.5), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
