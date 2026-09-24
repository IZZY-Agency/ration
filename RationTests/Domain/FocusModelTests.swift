import XCTest
@testable import Ration

/// The Focus popover's content.
final class FocusModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var order = 0

    // MARK: Helpers

    private func window(_ kind: UsageWindowKind, used: Double, resetsAt: Date? = nil) -> UsageWindow {
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
        spentCents: Int? = nil,
        fetchedAt: Date? = nil,
        state: AccountViewState = .current,
        hasSnapshot: Bool = true
    ) -> AccountPresentation {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: provider, label: label, webProfileID: UUID(),
            displayOrder: order, createdAt: now, isPaused: paused
        )
        var snapshot: UsageSnapshot?
        if hasSnapshot {
            snapshot = UsageSnapshot(
                accountID: id,
                fetchedAt: fetchedAt ?? now.addingTimeInterval(-60),
                fiveHour: fiveHour.map { window(.fiveHour, used: $0) },
                weekly: weekly.map { window(.weekly, used: $0, resetsAt: weeklyResetsAt) },
                modelWeekly: fable.map { window(.modelWeekly, used: $0) },
                cursorSpend: spentCents.map {
                    CursorSpend(spentCents: $0, periodStart: nil, resetsAt: now, planLabel: "Pro")
                }
            )
        }
        return AccountPresentation(account: record, snapshot: snapshot, state: state)
    }

    private func make(
        _ presentations: [AccountPresentation],
        inUse: [AccountPresentation] = [],
        lastUsed: [AccountPresentation] = [],
        advice: [SwitchAdvice] = [],
        fable: Set<UUID> = [],
        phases extra: [UUID: InUsePhase] = [:],
        thresholds: [UsageWindowKind: ThresholdPair] = [:],
        pinned: UUID? = nil
    ) -> FocusModel {
        var phases: [UUID: InUsePhase] = [:]
        for presentation in inUse { phases[presentation.id] = .inUse(age: 60) }
        for presentation in lastUsed { phases[presentation.id] = .lastUsed(age: 3600) }
        phases.merge(extra) { _, new in new }
        return FocusModel.make(
            presentations: presentations,
            phases: phases,
            advice: advice,
            fableCounts: { fable.contains($0) },
            thresholds: { _, kind in thresholds[kind] ?? .default },
            pinnedHeroID: pinned,
            now: now
        )
    }

    // MARK: Hero

    /// The hero is the subscription in use most
    /// recently, not the one with the least headroom.
    func testHeroIsTheMostRecentlyUsedInUseAccount() {
        let a = account("A", fiveHour: 0.40, weekly: 0.50)
        let b = account("B", fiveHour: 0.10, weekly: 0.97)
        let idle = account("Idle", fiveHour: 0.99, weekly: 0.99)
        let model = make([a, b, idle], phases: [a.id: .inUse(age: 30), b.id: .inUse(age: 400)])

        XCTAssertEqual(model.hero?.account.id, a.id)
        XCTAssertEqual(model.hero?.headroom ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.hero?.bindingKind, .weekly)
        XCTAssertEqual(model.hero?.tag, .inUse)
        XCTAssertEqual(model.hero?.isInUse, true)
        XCTAssertEqual(model.hero?.isPinned, false)
        XCTAssertEqual(model.otherInUse.map(\.account.id), [b.id])
        XCTAssertEqual(model.emptyState, FocusModel.EmptyState.none)
    }

    func testInUseAgeTieFallsBackToListOrder() {
        let a = account("A", fiveHour: 0.40)
        let b = account("B", fiveHour: 0.10)
        XCTAssertEqual(make([a, b], inUse: [a, b]).hero?.account.id, a.id)
    }

    func testNoneInUseHeroIsTheMostRecentlyUsedWithTheLastUsedTag() {
        let a = account("A", fiveHour: 0.40)
        let b = account("B", fiveHour: 0.80)
        let c = account("C", fiveHour: 0.95)
        let model = make([a, b, c], phases: [a.id: .lastUsed(age: 5000), b.id: .lastUsed(age: 2000)])

        XCTAssertEqual(model.hero?.account.id, b.id)
        XCTAssertEqual(model.hero?.tag, .lastUsed)
        XCTAssertEqual(model.hero?.isInUse, false)
        XCTAssertEqual(model.hero?.bindingKind, .fiveHour)
    }

    func testNoActivityHeroIsLeastHeadroomWithoutATag() {
        let a = account("A", fiveHour: 0.40)
        let b = account("B", fiveHour: 0.80)
        let model = make([a, b])

        XCTAssertEqual(model.hero?.account.id, b.id)
        XCTAssertEqual(model.hero?.tag, FocusModel.Hero.Tag.none)
    }

    func testInUseWinsOverAMoreRecentLastUsed() {
        let a = account("A", fiveHour: 0.40)
        let b = account("B", fiveHour: 0.10)
        // Impossible ages in practice, but the phase must decide, not the age.
        let model = make([a, b], phases: [a.id: .lastUsed(age: 10), b.id: .inUse(age: 800)])
        XCTAssertEqual(model.hero?.account.id, b.id)
    }

    func testIneligibleInUseAccountFallsThroughToLastUsed() {
        let reauth = account("Reauth", fiveHour: 0.2, state: .reauthenticationRequired)
        let later = account("Later", fiveHour: 0.2)
        let model = make([reauth, later], phases: [reauth.id: .inUse(age: 10), later.id: .lastUsed(age: 2000)])
        XCTAssertEqual(model.hero?.account.id, later.id)
        XCTAssertEqual(model.hero?.tag, .lastUsed)
        XCTAssertEqual(model.otherInUse.map(\.account.id), [reauth.id])
    }

    // MARK: Pinned hero

    func testPinnedAccountBecomesTheHeroAndTheAutomaticOneMovesToItsLine() {
        let a = account("A", fiveHour: 0.40)
        let gpt = account("5x", provider: .chatGPT, weekly: 0.0)
        let model = make([a, gpt], inUse: [a], pinned: gpt.id)

        XCTAssertEqual(model.hero?.account.id, gpt.id)
        XCTAssertEqual(model.hero?.isPinned, true)
        XCTAssertEqual(model.hero?.tag, FocusModel.Hero.Tag.none)
        XCTAssertEqual(model.otherInUse.map(\.account.id), [a.id])
        XCTAssertTrue(model.others.isEmpty)
    }

    func testPinnedLastUsedHeroKeepsItsTag() {
        let a = account("A", fiveHour: 0.40)
        let b = account("B", fiveHour: 0.10)
        let model = make([a, b], inUse: [a], lastUsed: [b], pinned: b.id)
        XCTAssertEqual(model.hero?.account.id, b.id)
        XCTAssertEqual(model.hero?.tag, .lastUsed)
    }

    func testPinOnAnAccountThatCannotBeTheHeroIsIgnored() {
        let a = account("A", fiveHour: 0.40)
        let cursor = account("Cursor", provider: .cursor, spentCents: 0)
        let paused = account("P", paused: true, fiveHour: 0.1)
        for pin in [cursor.id, paused.id, UUID()] {
            let model = make([a, cursor, paused], inUse: [a], pinned: pin)
            XCTAssertEqual(model.hero?.account.id, a.id)
            XCTAssertEqual(model.hero?.isPinned, false)
        }
    }

    func testEntriesSayWhetherTheyCanBecomeTheHero() {
        let hero = account("Hero", fiveHour: 0.5)
        let five = account("5x", provider: .chatGPT, weekly: 0.0)
        let cursor = account("Cursor", provider: .cursor, spentCents: 0)
        let paused = account("P", paused: true, fiveHour: 0.1)
        let stale = account("S", fiveHour: 0.1, state: .stale(lastError: .offline))
        let model = make([hero, five, cursor, paused, stale], inUse: [hero])
        let pinnable = Dictionary(uniqueKeysWithValues: model.others.map { ($0.account.label, $0.canBeHero) })
        XCTAssertEqual(pinnable, ["5x": true, "Cursor": false, "S": false])
    }

    // MARK: Warning lines

    func testNearlySpentAccountsGetAWarningLine() {
        let reset = now.addingTimeInterval(2 * 3600 + 27 * 60)
        let hero = account("Personal", fiveHour: 0.70, weekly: 0.15)
        let spent = account("Client", fiveHour: 0.10, weekly: 0.99, weeklyResetsAt: reset)
        let fine = account("5x", provider: .chatGPT, weekly: 0.0)
        let model = make([hero, spent, fine], inUse: [hero])

        XCTAssertEqual(model.warnings.map(\.account.id), [spent.id])
        let warning = try? XCTUnwrap(model.warnings.first)
        XCTAssertEqual(warning?.kind, .weekly)
        XCTAssertEqual(warning?.headroom ?? -1, 0.01, accuracy: 1e-9)
        XCTAssertEqual(warning?.resetsAt, reset)
        XCTAssertEqual(model.others.map(\.account.id), [fine.id])
    }

    func testWarningUsesEachWindowsOwnCritThresholdAtTheBoundary() {
        let a = account("A", fiveHour: 0.80, weekly: 0.85)
        let hero = account("H", fiveHour: 0.1)
        // Weekly crit 90 (not crossed), 5h crit 80 (crossed exactly) → the
        // line names the 5h window even though weekly has less headroom.
        let model = make([hero, a], inUse: [hero],
                         thresholds: [.fiveHour: ThresholdPair(warningPercent: 50, criticalPercent: 80)])
        XCTAssertEqual(model.warnings.first?.kind, .fiveHour)
        XCTAssertEqual(model.warnings.first?.headroom ?? -1, 0.2, accuracy: 1e-9)

        let below = make([hero, a], inUse: [hero],
                         thresholds: [.fiveHour: ThresholdPair(warningPercent: 50, criticalPercent: 81)])
        XCTAssertTrue(below.warnings.isEmpty)
    }

    func testWarningsExcludeHeroInUseLinesPausedStaleAndProblems() {
        let hero = account("Hero", weekly: 0.99)
        let busy = account("Busy", weekly: 0.99)
        let paused = account("P", paused: true, weekly: 0.99)
        let stale = account("S", weekly: 0.99, state: .stale(lastError: .offline))
        let reauth = account("R", weekly: 0.99, state: .reauthenticationRequired)
        let model = make([hero, busy, paused, stale, reauth],
                         phases: [hero.id: .inUse(age: 10), busy.id: .inUse(age: 100)])
        XCTAssertEqual(model.hero?.account.id, hero.id)
        XCTAssertEqual(model.otherInUse.map(\.account.id), [busy.id])
        XCTAssertTrue(model.warnings.isEmpty)
        XCTAssertEqual(Set(model.others.map(\.account.id)), [stale.id, reauth.id])
    }

    func testFableCountsForWarningsOnlyWhenTheVerdictSaysSo() {
        let hero = account("Hero", fiveHour: 0.1)
        let a = account("A", weekly: 0.2, fable: 0.95)
        XCTAssertTrue(make([hero, a], inUse: [hero]).warnings.isEmpty)
        XCTAssertEqual(make([hero, a], inUse: [hero], fable: [a.id]).warnings.first?.kind, .modelWeekly)
    }

    /// An in-use line carries its binding window's reset.
    func testInUseLineCarriesTheBindingReset() {
        let reset = now.addingTimeInterval(2 * 86_400 + 2 * 3600)
        let hero = account("Personal", fiveHour: 0.70)
        let gpt = account("20x", provider: .chatGPT, weekly: 0.75, weeklyResetsAt: reset)
        let model = make([hero, gpt], phases: [hero.id: .inUse(age: 10), gpt.id: .inUse(age: 600)])
        XCTAssertEqual(model.otherInUse.first?.resetsAt, reset)
        XCTAssertEqual(
            FocusModel.lineRight(headroom: 0.25, resetsAt: reset, now: now),
            "25% left · 2d 2h"
        )
        XCTAssertEqual(FocusModel.lineRight(headroom: 0.25, resetsAt: nil, now: now), "25% left")
    }

    func testInUseTagOnlyForTheInUsePhase() {
        let a = account("A", fiveHour: 0.40)
        XCTAssertEqual(make([a], lastUsed: [a]).hero?.isInUse, false)
        XCTAssertEqual(make([a]).hero?.isInUse, false)
        XCTAssertEqual(make([a], inUse: [a]).hero?.isInUse, true)
    }

    func testHeroCarriesResetAndOtherLimits() {
        let reset = now.addingTimeInterval(11 * 3600)
        let a = account("A", fiveHour: 0.27, weekly: 0.97, fable: 0.86, weeklyResetsAt: reset)
        let hero = make([a], inUse: [a]).hero

        XCTAssertEqual(hero?.resetsAt, reset)
        XCTAssertEqual(hero?.otherLimits.map(\.kind), [.fiveHour, .modelWeekly])
        XCTAssertEqual(hero?.otherLimits.first?.headroom ?? -1, 0.73, accuracy: 1e-9)
    }

    func testFableCountsOnlyWhenTheVerdictSaysSo() {
        let a = account("A", weekly: 0.50, fable: 0.95)
        XCTAssertEqual(make([a], inUse: [a]).hero?.bindingKind, .weekly)
        let counted = make([a], inUse: [a], fable: [a.id]).hero
        XCTAssertEqual(counted?.bindingKind, .modelWeekly)
        XCTAssertEqual(counted?.headroom ?? -1, 0.05, accuracy: 1e-9)
    }

    func testProblemAndUnknownAccountsNeverBecomeTheHero() {
        let reauth = account("Reauth", fiveHour: 0.99, state: .reauthenticationRequired)
        let old = account("Old", fiveHour: 0.99, fetchedAt: now.addingTimeInterval(-86_400))
        let paused = account("Paused", paused: true, fiveHour: 0.99)
        let ok = account("OK", fiveHour: 0.10)
        let model = make([reauth, old, paused, ok], inUse: [reauth, old, paused])

        XCTAssertEqual(model.hero?.account.id, ok.id)
        XCTAssertEqual(model.hero?.isInUse, false)
    }

    // MARK: Lines

    func testOtherInUseLinesIncludeSameProviderExtrasAndOtherProviders() {
        let a = account("A", fiveHour: 0.90)
        let a2 = account("A2", fiveHour: 0.20)
        let gpt = account("20x", provider: .chatGPT, weekly: 0.42)
        let idle = account("Idle", fiveHour: 0.10)
        let model = make([a, a2, gpt, idle], inUse: [a, a2, gpt])

        XCTAssertEqual(model.hero?.account.id, a.id)
        XCTAssertEqual(model.otherInUse.map(\.account.id), [a2.id, gpt.id])
        guard case let .headroom(headroom, kind)? = model.otherInUse.last?.value else {
            return XCTFail("ChatGPT line should carry headroom")
        }
        XCTAssertEqual(headroom, 0.58, accuracy: 1e-9)
        XCTAssertEqual(kind, .weekly)
        XCTAssertEqual(model.others.map(\.account.id), [idle.id])
    }

    func testSwitchLinesPassThroughAndTargetsLeaveTheEntries() {
        let a = account("Client", weekly: 0.97)
        let target = account("Personal", weekly: 0.15)
        let rest = account("Rest", weekly: 0.30)
        let advice = SwitchAdvice(
            provider: .claude, fromAccountID: a.id, fromLabel: "Client",
            toAccountID: target.id, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        let model = make([a, target, rest], inUse: [a], advice: [advice])

        XCTAssertEqual(model.switchLines, [advice])
        XCTAssertEqual(model.others.map(\.account.id), [rest.id])
    }

    /// Clicking a switch line pins its TARGET as the hero (× AUTO returns);
    /// the in-use from-account moves to its line.
    func testClickingASwitchLinePinsItsTargetAsTheHero() {
        let a = account("Client", weekly: 0.97)
        let target = account("Personal", weekly: 0.15)
        let advice = SwitchAdvice(
            provider: .claude, fromAccountID: a.id, fromLabel: "Client",
            toAccountID: target.id, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        XCTAssertEqual(make([a, target], inUse: [a], advice: [advice]).hero?.account.id, a.id, "premise")

        var shown: [UUID?] = []
        FocusView.showSwitchTarget(advice, onShowHero: { shown.append($0) })
        XCTAssertEqual(shown, [target.id])

        let model = make([a, target], inUse: [a], advice: [advice], pinned: shown.first ?? nil)
        XCTAssertEqual(model.hero?.account.id, target.id)
        XCTAssertEqual(model.hero?.isPinned, true)
        XCTAssertEqual(model.otherInUse.map(\.account.id), [a.id])
        XCTAssertEqual(FocusView.switchLineAccessibilityLabel(advice), "Show Personal")
        // The hero already shows the target — its "Next …" line would
        // only repeat it.
        XCTAssertEqual(model.switchLines, [], "no Next line for the account the hero shows")
    }

    /// Only the line whose target is the hero hides; other providers'
    /// lines stay.
    func testOnlyTheSwitchLineTargetingTheHeroHides() {
        let a = account("A", weekly: 0.97)
        let target = account("Personal", weekly: 0.15)
        let gptFrom = account("GPT", provider: .chatGPT, weekly: 0.95)
        let gptTarget = account("GPT2", provider: .chatGPT, weekly: 0.10)
        let claudeAdvice = SwitchAdvice(
            provider: .claude, fromAccountID: a.id, fromLabel: "A",
            toAccountID: target.id, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        let gptAdvice = SwitchAdvice(
            provider: .chatGPT, fromAccountID: gptFrom.id, fromLabel: "GPT",
            toAccountID: gptTarget.id, toLabel: "GPT2", toHeadroom: 0.90, toBinding: .weekly
        )
        let model = make(
            [a, target, gptFrom, gptTarget],
            inUse: [a, gptFrom],
            advice: [claudeAdvice, gptAdvice],
            pinned: target.id
        )
        XCTAssertEqual(model.hero?.account.id, target.id, "premise")
        XCTAssertEqual(model.switchLines, [gptAdvice])
    }

    // MARK: Entries

    func testEntriesShowPercentDollarsPausedAndState() {
        let hero = account("Hero", fiveHour: 0.50)
        let five = account("5x", provider: .chatGPT, weekly: 0.0)
        let cursor = account("Cursor", provider: .cursor, spentCents: 1240)
        let paused = account("Claude", paused: true, fiveHour: 0.10)
        let stale = account("Stale", fiveHour: 0.10, state: .stale(lastError: .offline))
        let reauth = account("Reauth", state: .reauthenticationRequired, hasSnapshot: false)
        let model = make([hero, five, cursor, paused, stale, reauth], inUse: [hero])

        let values = Dictionary(uniqueKeysWithValues: model.others.map { ($0.account.label, $0.value) })
        XCTAssertEqual(values["5x"], .headroom(1.0, .weekly))
        XCTAssertEqual(values["Cursor"], .spent(cents: 1240))
        // Paused accounts are hidden in Focus, as in Standard.
        XCTAssertNil(values["Claude"])
        XCTAssertEqual(values["Stale"], .state(.stale(lastError: .offline)))
        XCTAssertEqual(values["Reauth"], .state(.reauthenticationRequired))
        XCTAssertEqual(model.others.first { $0.account.label == "5x" }?.isDimmed, false)
    }

    func testEntriesGroupByProviderKeepingOrder() {
        let gpt = account("GPT", provider: .chatGPT, weekly: 0.1)
        let c1 = account("C1", fiveHour: 0.2)
        let cursor = account("Cur", provider: .cursor, spentCents: 0)
        let c2 = account("C2", fiveHour: 0.1)
        let model = make([gpt, c1, cursor, c2], inUse: [c1])

        XCTAssertEqual(model.hero?.account.id, c1.id)
        XCTAssertEqual(model.others.map(\.account.label), ["C2", "GPT", "Cur"])
    }

    // MARK: Empty states

    func testZeroAccounts() {
        let model = make([])
        XCTAssertEqual(model.emptyState, .noAccounts)
        XCTAssertNil(model.hero)
        XCTAssertTrue(model.others.isEmpty)
    }

    func testAllPausedShowsOnlyTheNote() {
        let a = account("A", paused: true, fiveHour: 0.1)
        let b = account("B", provider: .cursor, paused: true, spentCents: 5)
        let model = make([a, b], inUse: [a])

        XCTAssertEqual(model.emptyState, .allPaused)
        XCTAssertNil(model.hero)
        XCTAssertTrue(model.otherInUse.isEmpty)
        XCTAssertTrue(model.others.isEmpty)
        XCTAssertTrue(model.warnings.isEmpty)
    }

    func testCursorOnlyHasNoHeroJustTheList() {
        let cursor = account("Cursor", provider: .cursor, spentCents: 1240)
        let model = make([cursor])

        XCTAssertEqual(model.emptyState, FocusModel.EmptyState.none)
        XCTAssertNil(model.hero)
        XCTAssertEqual(model.others.map(\.value), [.spent(cents: 1240)])
    }

    func testAllStaleHasNoHero() {
        let old = account("Old", fiveHour: 0.2, fetchedAt: now.addingTimeInterval(-86_400),
                          state: .stale(lastError: .offline))
        let model = make([old])
        XCTAssertNil(model.hero)
        XCTAssertEqual(model.others.map(\.account.id), [old.id])
    }

    // MARK: Review fixes

    /// An in-use account with a problem keeps its state on the line, so
    /// the view can draw the badge and Sign In.
    func testInUseReauthAccountLineCarriesItsState() {
        let hero = account("Hero", fiveHour: 0.50)
        let reauth = account("Work", fiveHour: 0.10, state: .reauthenticationRequired)
        let model = make([hero, reauth], inUse: [hero, reauth])
        XCTAssertEqual(model.otherInUse.map(\.account.id), [reauth.id])
        XCTAssertEqual(model.otherInUse.first?.value, .state(.reauthenticationRequired))
    }

    /// A `.stale` account is never the hero, even when its snapshot is
    /// still within the evidence age.
    func testStaleStateNeverBecomesTheHeroEvenWithFreshEvidence() {
        let stale = account("Stale", fiveHour: 0.90, state: .stale(lastError: .offline))
        let ok = account("OK", fiveHour: 0.10)
        let model = make([stale, ok], inUse: [stale, ok])
        XCTAssertEqual(model.hero?.account.id, ok.id)
        XCTAssertEqual(model.otherInUse.first?.value, .state(.stale(lastError: .offline)))
    }

    func testAllStaleWithFreshEvidenceHasNoHeroAndListsTheState() {
        let stale = account("Stale", fiveHour: 0.20, state: .stale(lastError: .offline))
        let model = make([stale])
        XCTAssertNil(model.hero)
        XCTAssertEqual(model.others.map(\.value), [.state(.stale(lastError: .offline))])
    }

    /// The hero's other-limits line leaves out windows whose evidence
    /// is not current (here a Fable window overtaken by its reset).
    func testHeroOtherLimitsSkipWindowsThatAreNotCurrent() {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: .claude, label: "A", webProfileID: UUID(),
            displayOrder: order, createdAt: now
        )
        let snapshot = UsageSnapshot(
            accountID: id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: window(.fiveHour, used: 0.30),
            weekly: window(.weekly, used: 0.50),
            modelWeekly: window(.modelWeekly, used: 0.80, resetsAt: now.addingTimeInterval(-30))
        )
        let a = AccountPresentation(account: record, snapshot: snapshot, state: .current)
        let hero = make([a], inUse: [a]).hero
        XCTAssertEqual(hero?.bindingKind, .weekly)
        XCTAssertEqual(hero?.otherLimits.map(\.kind), [.fiveHour])
    }

    // MARK: Copy

    func testCopy() {
        XCTAssertEqual(FocusModel.caption(.weekly, label: nil), "of the week left")
        XCTAssertEqual(FocusModel.caption(.fiveHour, label: nil), "of 5 hours left")
        XCTAssertEqual(FocusModel.caption(.modelWeekly, label: nil), "of Fable left")
        XCTAssertEqual(FocusModel.percentText(0.034), "3%")
        XCTAssertEqual(FocusModel.percentText(0.856), "86%")
        XCTAssertEqual(FocusModel.dollarsText(cents: 1240), "$12.40")
        let limits = [
            FocusModel.Limit(kind: .fiveHour, label: nil, headroom: 0.73),
            FocusModel.Limit(kind: .modelWeekly, label: nil, headroom: 0.14),
        ]
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: now.addingTimeInterval(11 * 3600 + 18 * 60), limits: limits, now: now),
            "resets in 11h 18m · 5h 73% left · Fable 14% left"
        )
        XCTAssertEqual(
            FocusModel.limitsLine(
                resetsAt: now.addingTimeInterval(27 * 60),
                limits: [FocusModel.Limit(kind: .weekly, label: nil, headroom: 0.85)],
                now: now
            ),
            "resets in 27m · week 85% left"
        )
        XCTAssertEqual(FocusModel.warningText(label: "Client", headroom: 0.01, kind: .weekly, windowLabel: nil),
                       "Client · 1% of the week left")
        XCTAssertEqual(FocusModel.resetText(now.addingTimeInterval(2 * 3600 + 27 * 60 + 30), now: now),
                       "resets in 2h 27m")
        XCTAssertNil(FocusModel.resetText(nil, now: now))
        XCTAssertEqual(FocusModel.limitsLine(resetsAt: nil, limits: [], now: now), "")
    }
}
