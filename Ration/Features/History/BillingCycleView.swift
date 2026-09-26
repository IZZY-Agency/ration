import SwiftUI

/// The "Billing cycle" section of the History window: one card per subscription,
/// showing capacity utilisation for the current renewal-to-renewal cycle.
///
/// Live: the load key (`BillingCycleLoadKey`) covers the accounts, the
/// store's throttled history revision, the cycle starts, the day and the time
/// zone — all fed by `HistoryRefreshClock`. Off-main: rollups load via
/// `loadRollups` (off-main I/O), then one detached pass computes every card.
struct BillingCycleView: View {
    @ObservedObject var model: AppModel
    @StateObject private var clock: HistoryRefreshClock
    @Environment(\.openWindow) private var openWindow
    @State private var cards: [BillingCycleCard] = []
    @State private var hasLoaded = false

    init(model: AppModel) {
        self.model = model
        _clock = StateObject(wrappedValue: HistoryRefreshClock(history: model.history))
    }

    private var loadKey: BillingCycleLoadKey {
        BillingCycleLoadKey.make(
            accounts: model.accounts,
            historyRevision: clock.historyRevision,
            now: clock.now,
            timeZone: clock.timeZone
        )
    }

    var body: some View {
        Group {
            switch BillingCycleEligibility.presentation(accounts: model.accounts, cards: cards) {
            case .noAccounts:
                ContentUnavailableView {
                    Label("No accounts", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Add \(BillingCycleEligibility.supportedProviderNames()) to track billing cycles.")
                }
                .background(Theme.ink)

            case .noEligibleAccounts:
                // A Cursor-only install. Without this branch the window would
                // render an empty scroll view, reading as a bug rather than as
                // the deliberate v1 exclusion it is.
                ContentUnavailableView {
                    Label("Nothing to reconstruct", systemImage: "calendar.badge.checkmark")
                } description: {
                    Text("Cursor reports its billing cycle directly — see the usage rows on its account card. This window reconstructs cycle usage for \(BillingCycleEligibility.supportedProviderNames()), which don't report it.")
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
                            // The label is read at render time, so a rename
                            // shows at once (it is not part of the load key).
                            BillingCycleCardView(card: card.relabeled(from: model.accounts))
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
        .task(id: loadKey) { await reload() }
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private func reload() async {
        // Deliberately the current time, not `clock.now`: the key only
        // decides WHEN to reload; `clock.now` is the time of its last event
        // and may be minutes old, while "Day 3/30", elapsed hours and the
        // cycle itself must be as of this load.
        let now = Date.now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = clock.timeZone
        var inputs: [BillingCycleCardInput] = []
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
            inputs.append(BillingCycleCardInput(
                account: account, weekly: weekly, fiveHour: fiveHour, modelWeekly: modelWeekly,
                fablePresent: currentModelWindow != nil, fableLabel: currentModelWindow?.label
            ))
        }
        let built = await BillingCycleSectionModel.cardsOffMain(inputs, now: now, calendar: calendar)
        guard !Task.isCancelled else { return }
        cards = built
        hasLoaded = true
    }
}

/// Renders a single card from `BillingCycleCopy.cardText`, so every line it
/// draws is the model's. Insufficient / empty summaries show "Not enough data yet".
struct BillingCycleCardView: View {
    let card: BillingCycleCard
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let text = BillingCycleCopy.cardText(card)
        VStack(alignment: .leading, spacing: 8) {
            header(label: text.label, provider: provider, subtitle: text.subtitle)
            switch text.body {
            case .noRenewalDay:
                Text("Set a renewal day in Settings to track this subscription's cycle.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                BillingCTAButton(title: "Set a renewal day", prominent: false) {
                    openWindow(id: "settings")
                }
                .padding(.top, 2)
            case let .insufficient(notEnoughData, watched):
                Text(verbatim: notEnoughData)
                    .font(Theme.display(17, .semibold))
                    .foregroundStyle(Theme.creamDim)
                Text(verbatim: watched)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamFaint)
            case let .figure(headline, caption, detail, fable):
                figure(headline: headline, caption: caption, detail: detail, fable: fable)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private var provider: Provider {
        switch card {
        case let .noRenewalDay(_, _, provider): provider
        case let .tracked(_, _, provider, _, _, _): provider
        }
    }

    /// The headline's tier colour follows the displayed fraction.
    private var headlineFraction: Double {
        guard case let .tracked(_, _, _, _, summary, _) = card else { return 0 }
        return min(BillingCycleCopy.displayFraction(summary), 1)
    }

    private func header(label: String, provider: Provider, subtitle: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(provider.markAccent.opacity(Theme.markFillOpacity(colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(provider.markAccent.opacity(0.4)))
                .frame(width: 28, height: 28)
                .overlay(Text(provider.markLetter).font(Theme.mono(14, bold: true)).foregroundStyle(provider.markAccent))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label).font(Theme.display(16, .semibold)).foregroundStyle(Theme.cream)
                Text(verbatim: subtitle).font(Theme.mono(11)).foregroundStyle(Theme.creamFaint)
            }
            Spacer()
        }
    }

    private func figure(
        headline: String, caption: String, detail: String, fable: BillingCycleCardText.FableLine?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: headline)
                .font(Theme.display(28, .bold))
                .foregroundStyle(Theme.tierColor(usedFraction: headlineFraction))
            Text(verbatim: caption)
                .font(Theme.mono(11))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.creamFaint)
            Text(verbatim: detail)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
            // Fable is a supporting sub-limit line, never the headline. It is
            // nil only when Fable isn't present at all for this account; when
            // present but its own metric hasn't cleared the sufficiency floor
            // yet, the line is an honest "not enough data" instead of a %.
            if let fable {
                Text(verbatim: fable.text)
                    .font(Theme.mono(12))
                    .foregroundStyle(fable.isInsufficient ? Theme.creamFaint : Theme.creamDim)
            }
        }
    }
}

/// A CTA styled to match the app's gold-pill button idiom (see the popover's
/// "Add Account" empty-state button). `prominent` = filled gold (primary); else a
/// gold-outline pill for lighter, per-card use where a filled pill would be loud.
private struct BillingCTAButton: View {
    /// A key, not a `String`: a `String` here would be drawn verbatim.
    let title: LocalizedStringKey
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
