import Foundation

/// Pure budget-alert decisions.
enum APIBudgetPolicy {
    struct Decision: Equatable, Sendable {
        /// Tier the current spend is at, if any.
        let tier: AlertTier?
        /// Tier that newly crossed and should post (nil when priming or nothing new).
        let crossed: AlertTier?
        /// The accepted report is in a later month than the memory last evaluated.
        let monthAdvanced: Bool
        let next: BudgetAlertMemory
    }

    /// Highest configured threshold with `spent × 100 ≥ percent × budget`,
    /// on UNROUNDED Decimal cents, inclusive.
    static func tier(monthToDateCents: Decimal, budgetCents: Int, thresholds: ThresholdPair) -> AlertTier? {
        let spent = monthToDateCents * 100
        if spent >= Decimal(thresholds.criticalPercent) * Decimal(budgetCents) { return .critical }
        if spent >= Decimal(thresholds.warningPercent) * Decimal(budgetCents) { return .warning }
        return nil
    }

    static func evaluate(
        report: APICostReport,
        budgetCents: Int,
        thresholds: ThresholdPair,
        previous: BudgetAlertMemory,
        prime: Bool
    ) -> Decision {
        let month = report.month.key
        let sameMonth = previous.evaluatedMonthKey == month
        let monthAdvanced = previous.evaluatedMonthKey != nil && !sameMonth
        let base = sameMonth ? previous : BudgetAlertMemory(evaluatedMonthKey: nil, notifiedTier: nil, dismissedTier: nil)
        let tier = tier(monthToDateCents: report.monthToDateCents, budgetCents: budgetCents, thresholds: thresholds)
        let crossed: AlertTier? = {
            guard !prime, let tier else { return nil }
            if let notified = base.notifiedTier, notified >= tier { return nil }
            return tier
        }()
        let notified: AlertTier? = [base.notifiedTier, tier].compactMap { $0 }.max()
        let next = BudgetAlertMemory(evaluatedMonthKey: month, notifiedTier: notified, dismissedTier: base.dismissedTier)
        return Decision(tier: tier, crossed: crossed, monthAdvanced: monthAdvanced, next: next)
    }
}
