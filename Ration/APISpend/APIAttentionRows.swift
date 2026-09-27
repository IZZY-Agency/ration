import Foundation

/// The display facts of one API budget drop row (mapped to `AttentionRow` in the drop).
struct APIBudgetRowFacts: Equatable, Sendable {
    let orgID: UUID
    let label: String
    let vendor: APIVendor
    let tier: AlertTier
    let usedPercent: Int
    let spentCents: Int
    let budgetCents: Int
    let isLowerBound: Bool
    let resetsAt: Date
}

enum APIAttentionRows {
    static func facts(
        org: APIOrgRecord,
        report: APICostReport?,
        memory: BudgetAlertMemory?,
        thresholds: ThresholdPair,
        isLowerBound: Bool,
        now: Date
    ) -> APIBudgetRowFacts? {
        guard !org.isPaused, let budget = org.monthlyBudgetCents,
              let report, report.isCurrent(at: now),
              let tier = APIBudgetPolicy.tier(monthToDateCents: report.monthToDateCents, budgetCents: budget, thresholds: thresholds)
        else { return nil }
        if let memory, memory.evaluatedMonthKey == report.month.key,
           let dismissed = memory.dismissedTier, dismissed >= tier { return nil }
        let exact = APIMoney.exactPercent(spentCents: report.monthToDateCents, budgetCents: budget)
        return APIBudgetRowFacts(
            orgID: org.id, label: org.label, vendor: org.vendor, tier: tier,
            usedPercent: APIMoney.wholePercent(exact, isLowerBound ? .down : .plain),
            spentCents: isLowerBound ? APIMoney.flooredCents(report.monthToDateCents) : APIMoney.roundedCents(report.monthToDateCents),
            budgetCents: budget, isLowerBound: isLowerBound, resetsAt: report.month.nextStart
        )
    }
}
