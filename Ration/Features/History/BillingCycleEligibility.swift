import Foundation

/// Which providers the Billing-cycle window covers, and what the window should
/// show for a given set of accounts.
///
/// Pure so the view stays dumb and every empty-state combination is unit
/// tested — the states differ only in which accounts exist and whether any
/// carry a renewal day, which is exactly the kind of thing that silently
/// regresses into a blank pane.
enum BillingCycleEligibility {
    /// Cursor is excluded in v1.
    ///
    /// This window exists to *reconstruct* cycle utilisation for providers that
    /// only expose rolling windows — it infers "how much of your month have you
    /// burned" from hourly rollups. Cursor reports that natively: its two
    /// monthly pools ARE the cycle, percent-used IS the utilisation, and
    /// `resetsAt` IS the renewal. Including it would re-derive, less accurately,
    /// a number already on the account card. A dedicated snapshot-driven card
    /// is a separate design (v2), deliberately not smuggled in here.
    static func supports(_ provider: Provider) -> Bool {
        switch provider {
        case .claude, .chatGPT: true
        case .cursor: false
        }
    }

    /// The accounts this window may build cards for. Applied BEFORE rollup
    /// loading, not just before rendering: an excluded account should cost no
    /// disk reads either.
    static func eligible(_ accounts: [AccountRecord]) -> [AccountRecord] {
        accounts.filter { supports($0.provider) }
    }

    /// What the window should render.
    enum Presentation: Equatable {
        /// No accounts configured at all.
        case noAccounts
        /// Accounts exist, but none are covered by this window (e.g. a
        /// Cursor-only install). Distinct from `.noAccounts` because the
        /// explanation differs — and distinct from an empty card list, which
        /// would otherwise render as a blank scroll view.
        case noEligibleAccounts
        /// Every eligible account still needs a renewal day: one global CTA
        /// rather than a prompt per card.
        case noRenewalDaysSet
        /// At least one tracked card (possibly mixed with per-card prompts).
        case cards
    }

    static func presentation(accounts: [AccountRecord], cards: [BillingCycleCard]) -> Presentation {
        if accounts.isEmpty { return .noAccounts }
        if eligible(accounts).isEmpty { return .noEligibleAccounts }
        // Preserve the existing global-vs-per-card distinction: the global CTA
        // appears only when NOTHING is tracked yet.
        if !cards.isEmpty, cards.allSatisfy(\.isNoRenewalDay) { return .noRenewalDaysSet }
        return .cards
    }

    /// Human-readable list of the providers this window covers, so copy never
    /// hardcodes a provider list that goes stale the next time one is added.
    static func supportedProviderNames(locale: Locale = .current) -> String {
        let names = Provider.allCases.filter(supports).map(\.displayName)
        return providerList(names, locale: locale)
    }

    /// Provider names joined with "or" ("Claude or ChatGPT", "A, B, or C").
    /// Catalog entries rather than `ListFormatStyle`, so English keeps its
    /// 1.3.0 form in every region.
    static func providerList(_ names: [String], locale: Locale = .current) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return LocalizedStringResource.listOrPair(names[0], names[1]).string(in: locale)
        default:
            let head: String = names.dropLast().joined(separator: ", ")
            return LocalizedStringResource.listOrSeries(head, names[names.count - 1]).string(in: locale)
        }
    }
}

extension BillingCycleCard {
    var isNoRenewalDay: Bool {
        if case .noRenewalDay = self { return true }
        return false
    }
}
