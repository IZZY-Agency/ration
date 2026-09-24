import XCTest
@testable import Ration

final class SwitchAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var order = 0

    // MARK: Helpers

    private func window(
        _ kind: UsageWindowKind,
        used: Double,
        resetsAt: Date? = nil
    ) -> UsageWindow {
        UsageWindow(kind: kind, remainingFraction: 1 - used, resetsAt: resetsAt)
    }

    private func account(
        _ label: String,
        provider: Provider = .claude,
        paused: Bool = false,
        fiveHour: Double? = nil,
        weekly: Double? = nil,
        fable: Double? = nil,
        weeklyResetsAt: Date? = nil,
        fiveHourResetsAt: Date? = nil,
        fetchedAt: Date? = nil,
        state: AccountViewState = .current,
        hasSnapshot: Bool = true,
        plan: PlanTier? = nil
    ) -> AccountPresentation {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id,
            provider: provider,
            label: label,
            webProfileID: UUID(),
            displayOrder: order,
            createdAt: now,
            isPaused: paused,
            plan: plan,
            planSource: plan == nil ? nil : .detected
        )
        var snapshot: UsageSnapshot?
        if hasSnapshot {
            snapshot = UsageSnapshot(
                accountID: id,
                fetchedAt: fetchedAt ?? now.addingTimeInterval(-60),
                fiveHour: fiveHour.map { window(.fiveHour, used: $0, resetsAt: fiveHourResetsAt) },
                weekly: weekly.map { window(.weekly, used: $0, resetsAt: weeklyResetsAt) },
                modelWeekly: fable.map { window(.modelWeekly, used: $0) }
            )
        }
        return AccountPresentation(account: record, snapshot: snapshot, state: state)
    }

    private func presentation(_ label: String, weekly: UsageWindow) -> AccountPresentation {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: .claude, label: label, webProfileID: UUID(),
            displayOrder: order, createdAt: now
        )
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil, weekly: weekly
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    private func inUse(_ accounts: AccountPresentation...) -> [UUID: InUsePhase] {
        var phases: [UUID: InUsePhase] = [:]
        for presentation in accounts {
            phases[presentation.id] = .inUse(age: 60)
        }
        return phases
    }

    private func advice(
        _ presentations: [AccountPresentation],
        phases: [UUID: InUsePhase],
        thresholds: @escaping (Provider, UsageWindowKind) -> ThresholdPair = { _, _ in .default },
        fableCounts: @escaping (UUID) -> Bool = { _ in false }
    ) -> [SwitchAdvice] {
        SwitchAdvisor.advice(
            presentations: presentations,
            phases: phases,
            thresholds: thresholds,
            fableCounts: fableCounts,
            now: now
        )
    }

    // MARK: Trigger

    func testNoInUseAccountGivesNoAdvice() {
        let a = account("A", weekly: 0.95)
        let b = account("B", weekly: 0.1)
        XCTAssertEqual(advice([a, b], phases: [:]), [])
    }

    func testLastUsedIsNotInUse() {
        let a = account("A", weekly: 0.95)
        let b = account("B", weekly: 0.1)
        XCTAssertEqual(advice([a, b], phases: [a.id: .lastUsed(age: 3_000)]), [])
    }

    func testInUseBelowEveryWarnGivesNoAdvice() {
        let a = account("A", fiveHour: 0.74, weekly: 0.74)
        let b = account("B", fiveHour: 0, weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testInUseAtWarnGivesAdvice() {
        let a = account("A", fiveHour: 0.2, weekly: 0.75)
        let b = account("B", fiveHour: 0.1, weekly: 0.15)
        let result = advice([a, b], phases: inUse(a))
        XCTAssertEqual(result, [
            SwitchAdvice(
                provider: .claude,
                fromAccountID: a.id, fromLabel: "A",
                toAccountID: b.id, toLabel: "B",
                toHeadroom: 0.85, toBinding: .weekly
            ),
        ])
    }

    /// 5h at 80 % with a 5h Warn of 75 triggers even though weekly is the
    /// tighter limit and sits below the weekly Warn.
    func testAnyWindowAtItsOwnWarnTriggers() {
        let a = account("A", fiveHour: 0.80, weekly: 0.85)
        let b = account("B", fiveHour: 0, weekly: 0.2)
        let thresholds: (Provider, UsageWindowKind) -> ThresholdPair = { _, kind in
            kind == .weekly
                ? ThresholdPair(warningPercent: 90, criticalPercent: 95)
                : ThresholdPair(warningPercent: 75, criticalPercent: 90)
        }
        let result = advice([a, b], phases: inUse(a), thresholds: thresholds)
        XCTAssertEqual(result.map(\.toAccountID), [b.id])
    }

    func testPerWindowThresholdsAreRespected() {
        let a = account("A", fiveHour: 0.80, weekly: 0.5)
        let b = account("B", fiveHour: 0, weekly: 0)
        let thresholds: (Provider, UsageWindowKind) -> ThresholdPair = { _, kind in
            kind == .fiveHour
                ? ThresholdPair(warningPercent: 85, criticalPercent: 95)
                : ThresholdPair(warningPercent: 75, criticalPercent: 90)
        }
        XCTAssertEqual(advice([a, b], phases: inUse(a), thresholds: thresholds), [])
    }

    func testThresholdsAreAskedForTheAccountsProvider() {
        let a = account("A", provider: .chatGPT, weekly: 0.6)
        let b = account("B", provider: .chatGPT, weekly: 0)
        let thresholds: (Provider, UsageWindowKind) -> ThresholdPair = { provider, _ in
            provider == .chatGPT
                ? ThresholdPair(warningPercent: 50, criticalPercent: 90)
                : .default
        }
        let result = advice([a, b], phases: inUse(a), thresholds: thresholds)
        XCTAssertEqual(result.map(\.provider), [.chatGPT])
    }

    // MARK: Margin

    func testMarginBelowTwentyPointsGivesNoAdvice() {
        let a = account("A", weekly: 0.80)
        let b = account("B", weekly: 0.61)  // headroom 0.39 vs 0.20 → +0.19
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testMarginOfExactlyTwentyPointsGivesAdvice() {
        let a = account("A", weekly: 0.80)
        let b = account("B", weekly: 0.60)  // headroom 0.40 vs 0.20 → +0.20
        XCTAssertEqual(advice([a, b], phases: inUse(a)).map(\.toAccountID), [b.id])
    }

    // MARK: Target eligibility

    func testPausedTargetIsExcluded() {
        let a = account("A", weekly: 0.9)
        let b = account("B", paused: true, weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testPausedInUseAccountNeverAdvises() {
        let a = account("A", paused: true, weekly: 0.9)
        let b = account("B", weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testStaleSnapshotTargetIsExcluded() {
        let old = now.addingTimeInterval(-(UsageEvidence.maxAge + 60))
        let a = account("A", weekly: 0.9)
        let b = account("B", weekly: 0, fetchedAt: old)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testTargetWithoutSnapshotIsExcluded() {
        let a = account("A", weekly: 0.9)
        let b = account("B", hasSnapshot: false)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testProblemStateTargetsAreExcluded() {
        let problems: [AccountViewState] = [
            .reauthenticationRequired,
            .rateLimited(retryAt: nil),
            .integrationChanged,
            .unavailable,
        ]
        for state in problems {
            let a = account("A", weekly: 0.9)
            let b = account("B", weekly: 0, state: state)
            XCTAssertEqual(advice([a, b], phases: inUse(a)), [], "state \(state)")
        }
    }

    func testLoadingAndStaleViewStatesWithCurrentEvidenceStayEligible() {
        let states: [AccountViewState] = [.loading, .stale(lastError: .offline)]
        for state in states {
            let a = account("A", weekly: 0.9)
            let b = account("B", weekly: 0, state: state)
            XCTAssertEqual(advice([a, b], phases: inUse(a)).map(\.toAccountID), [b.id], "state \(state)")
        }
    }

    func testTargetWithWindowOvertakenByResetIsExcluded() {
        // B was fetched 60 s ago; its weekly reset 30 s ago → B's weekly is unknown.
        let a = account("A", weekly: 0.9)
        let b = account("B", fiveHour: 0, weekly: 0.1, weeklyResetsAt: now.addingTimeInterval(-30))
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testFromWindowOvertakenByResetCannotTrigger() {
        let a = account("A", fiveHour: 0.1, weekly: 0.95, weeklyResetsAt: now.addingTimeInterval(-30))
        let b = account("B", fiveHour: 0, weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testStaleFromSnapshotCannotTrigger() {
        let old = now.addingTimeInterval(-(UsageEvidence.maxAge + 60))
        let a = account("A", weekly: 0.95, fetchedAt: old)
        let b = account("B", weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    // MARK: Fable

    func testFableCountingForFromIsConsideredOnTargets() {
        let a = account("A", weekly: 0.5, fable: 0.9)
        let exhausted = account("B", weekly: 0, fable: 1.0)
        let roomy = account("C", weekly: 0.3, fable: 0.2)
        let result = advice(
            [a, exhausted, roomy],
            phases: inUse(a),
            fableCounts: { $0 == a.id }
        )
        XCTAssertEqual(result.map(\.toAccountID), [roomy.id])
        XCTAssertEqual(result.first?.toBinding, .weekly)
        XCTAssertEqual(result.first?.toHeadroom ?? 0, 0.7, accuracy: 1e-9)
    }

    func testFableBindingIsReportedForTarget() {
        let a = account("A", weekly: 0.5, fable: 0.9)
        let b = account("B", weekly: 0.1, fable: 0.6)
        let result = advice([a, b], phases: inUse(a), fableCounts: { $0 == a.id })
        XCTAssertEqual(result.first?.toBinding, .modelWeekly)
        XCTAssertEqual(result.first?.toHeadroom ?? 0, 0.4, accuracy: 1e-9)
    }

    func testFableNotCountingIsIgnored() {
        // A's Fable is at 90 % but does not count → A is at 50 % weekly, no trigger.
        let a = account("A", weekly: 0.5, fable: 0.9)
        let b = account("B", weekly: 0, fable: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testFableNotCountingForFromIgnoresTargetFableEvenIfTargetUsesIt() {
        let a = account("A", weekly: 0.9)
        let b = account("B", weekly: 0.1, fable: 1.0)
        let result = advice([a, b], phases: inUse(a), fableCounts: { $0 == b.id })
        XCTAssertEqual(result.map(\.toAccountID), [b.id])
        XCTAssertEqual(result.first?.toBinding, .weekly)
    }

    // MARK: Shapes

    func testWeeklyOnlyChatGPT() {
        let a = account("A", provider: .chatGPT, weekly: 0.8)
        let b = account("B", provider: .chatGPT, weekly: 0.3)
        let result = advice([a, b], phases: inUse(a))
        XCTAssertEqual(result.map(\.provider), [.chatGPT])
        XCTAssertEqual(result.first?.toBinding, .weekly)
        XCTAssertEqual(result.first?.toHeadroom ?? 0, 0.7, accuracy: 1e-9)
    }

    func testTwoInUseSameProviderLeastHeadroomIsFrom() {
        let a = account("A", weekly: 0.80)
        let b = account("B", weekly: 0.95)
        let c = account("C", weekly: 0.1)
        let result = advice([a, b, c], phases: inUse(a, b))
        XCTAssertEqual(result.first?.fromAccountID, b.id)
        XCTAssertEqual(result.first?.fromLabel, "B")
        XCTAssertEqual(result.first?.toAccountID, c.id)
    }

    /// Controller ruling: `from` is the least-headroom in-use account that HAS
    /// crossed its own Warn, so whoever just got the Warn gets the advice.
    func testFromIsLeastHeadroomAmongTriggeredInUseAccounts() {
        let a = account("A", weekly: 0.80)               // headroom 0.20, weekly Warn 90 → not crossed
        let b = account("B", fiveHour: 0.78, weekly: 0.1) // headroom 0.22, 5h Warn 75 → crossed
        let c = account("C", fiveHour: 0, weekly: 0.1)    // headroom 0.90
        let thresholds: (Provider, UsageWindowKind) -> ThresholdPair = { _, kind in
            kind == .weekly
                ? ThresholdPair(warningPercent: 90, criticalPercent: 95)
                : ThresholdPair(warningPercent: 75, criticalPercent: 90)
        }
        let result = advice([a, b, c], phases: inUse(a, b), thresholds: thresholds)
        XCTAssertEqual(result.map(\.fromAccountID), [b.id])
        XCTAssertEqual(result.map(\.toAccountID), [c.id])
    }

    func testInUseAccountWithOnlyUnknownWindowsHandsFromToNextInUse() {
        let a = account("A", weekly: 0.99, weeklyResetsAt: now.addingTimeInterval(-30))
        let b = account("B", weekly: 0.90)
        let c = account("C", weekly: 0.10)
        let result = advice([a, b, c], phases: inUse(a, b))
        XCTAssertEqual(result.map(\.fromAccountID), [b.id])
        XCTAssertEqual(result.map(\.toAccountID), [c.id])
    }

    func testNearlyEqualHeadroomCountsAsTieAndFallsToReset() {
        let a = account("A", weekly: 0.9)
        // 1 - 0.7 vs 0.3 differ in the last bits; they must tie.
        let later = UsageWindow(kind: .weekly, remainingFraction: 0.3 + 1e-12, resetsAt: now.addingTimeInterval(7_200))
        let sooner = account("C", weekly: 0.7, weeklyResetsAt: now.addingTimeInterval(3_600))
        let laterAccount = presentation("B", weekly: later)
        XCTAssertEqual(advice([a, laterAccount, sooner], phases: inUse(a)).map(\.toAccountID), [sooner.id])
    }

    func testOtherInUseAccountCanBeTheTarget() {
        let a = account("A", weekly: 0.9)
        let b = account("B", weekly: 0.2)
        let result = advice([a, b], phases: inUse(a, b))
        XCTAssertEqual(result.first?.fromAccountID, a.id)
        XCTAssertEqual(result.first?.toAccountID, b.id)
    }

    func testCursorIsNeverAdvised() {
        let a = account("A", provider: .cursor, weekly: 0.95)
        let b = account("B", provider: .cursor, weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testTargetMustBeSameProvider() {
        let a = account("A", provider: .claude, weekly: 0.9)
        let b = account("B", provider: .chatGPT, weekly: 0)
        XCTAssertEqual(advice([a, b], phases: inUse(a)), [])
    }

    func testBothProvidersGiveTwoAdvicesClaudeFirst() {
        let g1 = account("G1", provider: .chatGPT, weekly: 0.9)
        let g2 = account("G2", provider: .chatGPT, weekly: 0)
        let c1 = account("C1", provider: .claude, weekly: 0.9)
        let c2 = account("C2", provider: .claude, weekly: 0)
        let result = advice([g1, g2, c1, c2], phases: inUse(g1, c1))
        XCTAssertEqual(result.map(\.provider), [.claude, .chatGPT])
        XCTAssertEqual(result.map(\.toAccountID), [c2.id, g2.id])
    }

    // MARK: Ties

    func testMostHeadroomWins() {
        let a = account("A", weekly: 0.9)
        let b = account("B", weekly: 0.5)
        let c = account("C", weekly: 0.2)
        XCTAssertEqual(advice([a, b, c], phases: inUse(a)).map(\.toAccountID), [c.id])
    }

    func testEqualHeadroomSoonestWeeklyResetWins() {
        let a = account("A", weekly: 0.9)
        let later = account("B", weekly: 0.2, weeklyResetsAt: now.addingTimeInterval(7_200))
        let sooner = account("C", weekly: 0.2, weeklyResetsAt: now.addingTimeInterval(3_600))
        XCTAssertEqual(advice([a, later, sooner], phases: inUse(a)).map(\.toAccountID), [sooner.id])
    }

    func testEqualHeadroomNilResetSortsLast() {
        let a = account("A", weekly: 0.9)
        let noReset = account("B", weekly: 0.2)
        let withReset = account("C", weekly: 0.2, weeklyResetsAt: now.addingTimeInterval(7_200))
        XCTAssertEqual(advice([a, noReset, withReset], phases: inUse(a)).map(\.toAccountID), [withReset.id])
    }

    func testFullTieFallsBackToPresentationOrder() {
        let a = account("A", weekly: 0.9)
        let first = account("B", weekly: 0.2)
        let second = account("C", weekly: 0.2)
        XCTAssertEqual(advice([a, first, second], phases: inUse(a)).map(\.toAccountID), [first.id])
        XCTAssertEqual(advice([a, second, first], phases: inUse(a)).map(\.toAccountID), [second.id])
    }

    // MARK: Binding kind on equal headroom

    func testBindingPrefersWeeklyOverFiveHourOnEqualHeadroom() {
        let a = account("A", weekly: 0.9)
        let b = account("B", fiveHour: 0.3, weekly: 0.3)
        XCTAssertEqual(advice([a, b], phases: inUse(a)).first?.toBinding, .weekly)
    }

    func testBindingPrefersFiveHourOverFableOnEqualHeadroom() {
        let a = account("A", weekly: 0.9)
        let b = account("B", fiveHour: 0.3, weekly: 0.1, fable: 0.3)
        let result = advice([a, b], phases: inUse(a), fableCounts: { $0 == a.id })
        XCTAssertEqual(result.first?.toBinding, .fiveHour)
    }

    func testBindingPrefersWeeklyOverFableOnEqualHeadroom() {
        let a = account("A", weekly: 0.9)
        let b = account("B", weekly: 0.3, fable: 0.3)
        let result = advice([a, b], phases: inUse(a), fableCounts: { $0 == a.id })
        XCTAssertEqual(result.first?.toBinding, .weekly)
    }

    // MARK: Plan capacity

    func testTwentyXAtQuarterLeftIsNotSwitchedToFullFiveX() {
        let big = account("20x", provider: .chatGPT, weekly: 0.75, plan: .chatGPTPro20x)
        let small = account("5x", provider: .chatGPT, weekly: 0, plan: .chatGPTPro5x)
        XCTAssertEqual(advice([big, small], phases: inUse(big)), [])
    }

    func testTwentyXAtTenPercentSwitchesToFullFiveX() {
        let big = account("20x", provider: .chatGPT, weekly: 0.90, plan: .chatGPTPro20x)
        let small = account("5x", provider: .chatGPT, weekly: 0, plan: .chatGPTPro5x)
        let result = advice([big, small], phases: inUse(big))
        XCTAssertEqual(result.map(\.toAccountID), [small.id])
        XCTAssertEqual(result.first?.toHeadroom ?? -1, 1, accuracy: 1e-9, "copy stays a percentage")
    }

    func testCapacityPrefersBiggerPlanOverHigherPercent() {
        let from = account("from", provider: .chatGPT, weekly: 0.95, plan: .chatGPTPro5x)
        let small = account("5x-full", provider: .chatGPT, weekly: 0, plan: .chatGPTPro5x)
        let big = account("20x-half", provider: .chatGPT, weekly: 0.5, plan: .chatGPTPro20x)
        XCTAssertEqual(advice([from, small, big], phases: inUse(from)).map(\.toAccountID), [big.id])
    }

    func testEqualPlansBehaveLikePercentages() {
        let a = account("A", weekly: 0.80, plan: .claudeMax20x)
        let b19 = account("B", weekly: 0.61, plan: .claudeMax20x)
        XCTAssertEqual(advice([a, b19], phases: inUse(a)), [])
        let c20 = account("C", weekly: 0.60, plan: .claudeMax20x)
        XCTAssertEqual(advice([a, c20], phases: inUse(a)).map(\.toAccountID), [c20.id])
    }

    func testUnknownPlanTargetIsSkippedWhenFromHasPlan() {
        let from = account("from", weekly: 0.9, plan: .claudeMax5x)
        let unknown = account("unknown", weekly: 0)
        XCTAssertEqual(advice([from, unknown], phases: inUse(from)), [])
        let known = account("known", weekly: 0.5, plan: .claudeMax5x)
        XCTAssertEqual(advice([from, unknown, known], phases: inUse(from)).map(\.toAccountID), [known.id])
    }

    func testFromWithoutPlanComparesOnlyNoPlanAccountsByPercent() {
        let from = account("from", weekly: 0.9)
        let known = account("known", weekly: 0, plan: .claudeMax20x)
        XCTAssertEqual(advice([from, known], phases: inUse(from)), [])
        let unknown = account("unknown", weekly: 0.5)
        XCTAssertEqual(advice([from, known, unknown], phases: inUse(from)).map(\.toAccountID), [unknown.id])
    }

    func testCapacityTieFallsBackToSoonestWeeklyReset() {
        let from = account("from", weekly: 0.9, plan: .claudeMax5x)
        let later = account("later", weekly: 0.5, weeklyResetsAt: now.addingTimeInterval(7_200), plan: .claudeMax5x)
        let sooner = account("sooner", weekly: 0.5, weeklyResetsAt: now.addingTimeInterval(3_600), plan: .claudeMax5x)
        XCTAssertEqual(advice([from, later, sooner], phases: inUse(from)).map(\.toAccountID), [sooner.id])
    }
}
