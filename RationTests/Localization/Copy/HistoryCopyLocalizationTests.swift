import XCTest
@testable import Ration

/// The History window (Patterns and Billing cycle) in every shipped language:
/// the paused label, the overlay's exclusion note and legend labels, the
/// heatmap's spoken cells, the billing-cycle cards, and the view literals.
/// English is pinned to the 1.3.0 text.
final class HistoryCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let nnb = L10n.nnbsp

    // MARK: Fixtures

    private func record(_ provider: Provider, _ label: String, paused: Bool = false, renewalDay: Int? = nil) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: provider, label: label, webProfileID: UUID(),
            displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0),
            billingRenewalDay: renewalDay, isPaused: paused
        )
    }

    private func window(_ kind: UsageWindowKind) -> UsageWindow {
        UsageWindow(kind: kind, remainingFraction: 0.5, resetsAt: nil, label: nil)
    }

    private func claude(_ label: String, paused: Bool = false) -> AccountPresentation {
        let account = record(.claude, label, paused: paused)
        return AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id, fetchedAt: Date(timeIntervalSince1970: 0),
                fiveHour: window(.fiveHour), weekly: window(.weekly)
            ),
            state: .current
        )
    }

    private func cursor(_ label: String) -> AccountPresentation {
        AccountPresentation(account: record(.cursor, label), snapshot: nil, state: .current)
    }

    // MARK: Paused label

    func testPausedHistoryLabelInEveryLanguage() {
        let paused = record(.claude, "Work", paused: true)
        XCTAssertEqual(paused.historyLabel(locale: L10n.en), "Work — PAUSED")
        XCTAssertEqual(paused.historyLabel(locale: L10n.fr), "Work — EN PAUSE")
        XCTAssertEqual(paused.historyLabel(locale: L10n.uk), "Work — ПРИЗУПИНЕНО")
        XCTAssertEqual(record(.claude, "Work").historyLabel(locale: L10n.uk), "Work")
    }

    // MARK: Series identity

    /// The legend label is the Swift Charts series key. A translated paused
    /// suffix must not let two lines share one: an active account whose own
    /// label is the translated paused form of another's still gets its own key.
    func testLegendLabelsStayUniqueWithTranslatedPausedSuffix() {
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            let pausedWork = claude("Work", paused: true)
            let lookalike = claude(pausedWork.account.historyLabel(locale: locale))
            let labels = HistoryOverlay.labels(for: [pausedWork, lookalike], locale: locale)
            XCTAssertEqual(Set(labels.values).count, 2, locale.identifier)
            XCTAssertEqual(labels[pausedWork.id], "\(pausedWork.account.historyLabel(locale: locale)) · Claude")
            XCTAssertEqual(labels[lookalike.id], "\(pausedWork.account.historyLabel(locale: locale)) · Claude (2)")
        }
    }

    func testSeriesLabelsFollowTheLocaleAndKeepOneLinePerAccount() {
        let paused = claude("Work", paused: true)
        let active = claude("Home")
        let bucket = UsageHourlyBucket(
            hourStart: Date(timeIntervalSince1970: 1_790_000_000), tzOffsetSeconds: 0,
            consumed: 0.2, minRemaining: 0.5, sampleCount: 2
        )
        let loaded: [UUID: [UsageHourlyBucket]] = [paused.id: [bucket], active.id: [bucket]]
        let fr = HistoryOverlay.series(presentations: [paused, active], kind: .fiveHour, loaded: loaded, locale: L10n.fr)
        XCTAssertEqual(fr.map(\.label), ["Work — EN PAUSE", "Home"])
        XCTAssertEqual(fr.map(\.accountID), [paused.id, active.id])
        let en = HistoryOverlay.series(presentations: [paused, active], kind: .fiveHour, loaded: loaded, locale: L10n.en)
        XCTAssertEqual(en.map(\.label), ["Work — PAUSED", "Home"])
        XCTAssertEqual(en.map(\.shadeIndex), fr.map(\.shadeIndex))
    }

    // MARK: Exclusion note

    func testExclusionNoteInEveryLanguage() {
        let listed = [claude("AI"), cursor("Cu")]
        XCTAssertEqual(HistoryOverlay.exclusionNote(presentations: listed, kind: .fiveHour, locale: L10n.en), "Not shown: Cu — no 5h window")
        XCTAssertEqual(
            HistoryOverlay.exclusionNote(presentations: listed, kind: .fiveHour, locale: L10n.fr),
            "Hors graphique\(nb): Cu — pas de fenêtre 5h"
        )
        XCTAssertEqual(
            HistoryOverlay.exclusionNote(presentations: listed, kind: .weekly, locale: L10n.uk),
            "Не показано: Cu — немає вікна wk"
        )

        func counted(_ excluded: Int, _ locale: Locale) -> String? {
            let cursors = (0..<excluded).map { cursor("C\($0)") }
            return HistoryOverlay.exclusionNote(presentations: [claude("AI")] + cursors, kind: .fiveHour, locale: locale)
        }
        XCTAssertEqual(counted(4, L10n.en), "Not shown: 4 accounts with no 5h window")
        XCTAssertEqual(counted(4, L10n.fr), "Hors graphique\(nb): 4 comptes sans fenêtre 5h")
        XCTAssertEqual(counted(4, L10n.uk), "Не показано: 4 облікові записи без вікна 5h")
        XCTAssertEqual(counted(5, L10n.uk), "Не показано: 5 облікових записів без вікна 5h")
        XCTAssertEqual(counted(21, L10n.uk), "Не показано: 21 обліковий запис без вікна 5h")
        XCTAssertEqual(counted(22, L10n.uk), "Не показано: 22 облікові записи без вікна 5h")
        XCTAssertEqual(counted(25, L10n.uk), "Не показано: 25 облікових записів без вікна 5h")
    }

    // MARK: Spoken window names (controller ruling)

    /// The picker segments draw the tags (5h, wk, Fable) and speak the
    /// window's name, in every language including English.
    func testWindowPickerSpeaksTheWindowName() {
        XCTAssertEqual(HistoryOverlay.spokenWindowName(.fiveHour, snapshot: nil, locale: L10n.en), "5 hour")
        XCTAssertEqual(HistoryOverlay.spokenWindowName(.weekly, snapshot: nil, locale: L10n.fr), "fenêtre hebdomadaire")
        XCTAssertEqual(HistoryOverlay.spokenWindowName(.weekly, snapshot: nil, locale: L10n.uk), "тижневе вікно")
        for kind in UsageWindowKind.allCases {
            for locale in [L10n.en, L10n.fr, L10n.uk] {
                XCTAssertEqual(
                    HistoryOverlay.spokenWindowName(kind, snapshot: nil, locale: locale),
                    kind.spokenName(label: nil, locale: locale)
                )
            }
        }
    }

    func testExclusionNoteHasASpokenFormInEveryLanguage() {
        let listed = [claude("AI"), cursor("Cu")]
        XCTAssertEqual(
            HistoryOverlay.spokenExclusionNote(presentations: listed, kind: .fiveHour, locale: L10n.en),
            "Not shown: Cu — no 5 hour window"
        )
        XCTAssertEqual(
            HistoryOverlay.spokenExclusionNote(presentations: listed, kind: .weekly, locale: L10n.fr),
            "Hors graphique\(nb): Cu — pas de fenêtre hebdomadaire"
        )
        XCTAssertEqual(
            HistoryOverlay.spokenExclusionNote(presentations: listed, kind: .fiveHour, locale: L10n.uk),
            "Не показано: Cu — відсутнє 5-годинне вікно"
        )
        let many = [claude("AI")] + (0..<5).map { cursor("C\($0)") }
        XCTAssertEqual(
            HistoryOverlay.spokenExclusionNote(presentations: many, kind: .weekly, locale: L10n.en),
            "Not shown: 5 accounts with no weekly window"
        )
        XCTAssertEqual(
            HistoryOverlay.spokenExclusionNote(presentations: many, kind: .weekly, locale: L10n.fr),
            "Hors graphique\(nb): 5 comptes sans fenêtre hebdomadaire"
        )
        XCTAssertEqual(
            HistoryOverlay.spokenExclusionNote(presentations: many, kind: .fiveHour, locale: L10n.uk),
            "Не показано: 5 облікових записів, у яких відсутнє 5-годинне вікно"
        )
        XCTAssertNil(HistoryOverlay.spokenExclusionNote(presentations: [claude("AI")], kind: .fiveHour, locale: L10n.uk))
    }

    // MARK: Heatmap

    func testHeatmapCellIsSpokenInEveryLanguage() {
        let hour = HourOfDayBurn(hour: 9, averageConsumed: 0.25)
        XCTAssertEqual(HistoryHeatmapView.accessibilityLabel(for: hour, locale: L10n.en), "09:00, 25% average burn")
        XCTAssertEqual(
            HistoryHeatmapView.accessibilityLabel(for: hour, locale: L10n.fr),
            "09:00, consommation moyenne de 25\(nnb)%"
        )
        XCTAssertEqual(HistoryHeatmapView.accessibilityLabel(for: hour, locale: L10n.uk), "09:00, середнє витрачання 25%")
    }

    // MARK: Billing cycle

    func testSupportedProviderNamesInEveryLanguage() {
        XCTAssertEqual(BillingCycleEligibility.supportedProviderNames(locale: L10n.en), "Claude or ChatGPT")
        XCTAssertEqual(BillingCycleEligibility.supportedProviderNames(locale: L10n.fr), "Claude ou ChatGPT")
        XCTAssertEqual(BillingCycleEligibility.supportedProviderNames(locale: L10n.uk), "Claude або ChatGPT")
        XCTAssertEqual(BillingCycleEligibility.providerList(["A", "B", "C"], locale: L10n.en), "A, B, or C")
        XCTAssertEqual(BillingCycleEligibility.providerList(["A", "B", "C"], locale: L10n.fr), "A, B ou C")
        XCTAssertEqual(BillingCycleEligibility.providerList(["A", "B", "C"], locale: L10n.uk), "A, B або C")
        XCTAssertEqual(BillingCycleEligibility.providerList(["A"], locale: L10n.uk), "A")
        XCTAssertEqual(BillingCycleEligibility.providerList([], locale: L10n.uk), "")
    }

    func testCardLabelFollowsTheLocale() {
        let account = record(.claude, "Work", paused: true)
        let card = BillingCycleSectionModel.card(
            account: account, weekly: [], fiveHour: [], now: Date(timeIntervalSince1970: 1_790_000_000),
            calendar: Calendar(identifier: .gregorian), locale: L10n.uk
        )
        XCTAssertEqual(card, .noRenewalDay(id: account.id, label: "Work — ПРИЗУПИНЕНО", provider: .claude))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 12 Sep → 11 Oct, day 3 of 30.
    private var cycle: BillingCycle {
        let now = utc.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 10))!
        return BillingCycle.current(renewalDay: 12, now: now, calendar: utc)
    }

    private func summary(_ kind: UsageWindowKind = .weekly) -> CycleUtilizationSummary {
        CycleUtilizationSummary(
            windowKind: kind, family: .rolling, capacityUtilization: 0.424, isLegacyLowerBound: true, consumedAllowances: 1.46,
            daysUsed: 2, atCapDays: 1, observedHours: 40, elapsedHours: 58,
            observedSeconds: 40 * 3600, elapsedSeconds: 58 * 3600
        )
    }

    func testCycleSubtitleInEveryLanguage() {
        let utcZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            BillingCycleCopy.cycleSubtitle(cycle, locale: L10n.en, timeZone: utcZone),
            "Cycle Sep 12 – Oct 11 · Day 3/30"
        )
        XCTAssertEqual(
            BillingCycleCopy.cycleSubtitle(cycle, locale: L10n.fr, timeZone: utcZone),
            "Cycle du 12 sept. au 11 oct. · jour 3/30"
        )
        XCTAssertEqual(
            BillingCycleCopy.cycleSubtitle(cycle, locale: L10n.uk, timeZone: utcZone),
            "Цикл 12 вер. – 11 жовт. · день 3/30"
        )
        XCTAssertEqual(BillingCycleCopy.noCycleSubtitle(locale: L10n.en), "No billing cycle set")
        XCTAssertEqual(BillingCycleCopy.noCycleSubtitle(locale: L10n.fr), "Aucun cycle de facturation défini")
        XCTAssertEqual(BillingCycleCopy.noCycleSubtitle(locale: L10n.uk), "Платіжний цикл не задано")
    }

    func testCardLinesInEveryLanguage() {
        let s = summary()
        XCTAssertEqual(BillingCycleCopy.headline(s, locale: L10n.en), "≥ 42%")
        XCTAssertEqual(BillingCycleCopy.headline(s, locale: L10n.fr), "≥ 42\(nnb)%")
        XCTAssertEqual(BillingCycleCopy.headline(s, locale: L10n.uk), "≥ 42%")

        XCTAssertEqual(
            BillingCycleCopy.detail(s, locale: L10n.en),
            "≥ 1.5× weekly allowance · Used 2 days · At ≥95% 1 day · watched 40/58 hrs"
        )
        XCTAssertEqual(
            BillingCycleCopy.detail(s, locale: L10n.fr),
            "≥ 1,5× l’allocation hebdomadaire · utilisé 2\(nb)j · à ≥95\(nb)%\(nb): 1\(nb)j · suivi 40/58\(nb)h"
        )
        XCTAssertEqual(
            BillingCycleCopy.detail(s, locale: L10n.uk),
            "≥ 1,5× тижневого обсягу · використано 2 дн. · на ≥95%: 1 дн. · відстежено 40/58 год"
        )
        XCTAssertEqual(
            BillingCycleCopy.detail(summary(.fiveHour), locale: L10n.en),
            "≥ 1.5× 5h allowance · Used 2 days · At ≥95% 1 day · watched 40/58 hrs"
        )
        XCTAssertTrue(BillingCycleCopy.detail(summary(.fiveHour), locale: L10n.fr).hasPrefix("≥ 1,5× l’allocation de 5\(nb)h ·"))
        XCTAssertTrue(BillingCycleCopy.detail(summary(.fiveHour), locale: L10n.uk).hasPrefix("≥ 1,5× 5-годинного обсягу ·"))

        XCTAssertEqual(BillingCycleCopy.watched(s, cycle: cycle, locale: L10n.en), "watched 40 of 58 hrs · Day 3/30")
        XCTAssertEqual(BillingCycleCopy.watched(s, cycle: cycle, locale: L10n.fr), "suivi 40\(nb)h sur 58 · jour 3/30")
        XCTAssertEqual(BillingCycleCopy.watched(s, cycle: cycle, locale: L10n.uk), "відстежено 40 з 58 год · день 3/30")

        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", s, locale: L10n.en), "Fable ≥ 42% this cycle")
        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", s, locale: L10n.fr), "Fable ≥ 42\(nb)% sur ce cycle")
        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", s, locale: L10n.uk), "Fable ≥ 42% у цьому циклі")
        XCTAssertEqual(BillingCycleCopy.fableInsufficient(label: "Fable", locale: L10n.en), "Fable · not enough data yet this cycle")
        XCTAssertEqual(
            BillingCycleCopy.fableInsufficient(label: "Fable", locale: L10n.fr),
            "Fable · pas encore assez de données sur ce cycle"
        )
        XCTAssertEqual(
            BillingCycleCopy.fableInsufficient(label: "Fable", locale: L10n.uk),
            "Fable · у цьому циклі ще недостатньо даних"
        )
    }

    /// The card's numbers come from the shared formatters, not a second
    /// hand-built copy of the French spacing rules.
    func testCardNumbersUseTheSharedFormatters() {
        let s = summary()
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            XCTAssertEqual(
                BillingCycleCopy.headline(s, locale: locale),
                "≥ " + UsageFormatters.wholePercent(42, monospaced: false, locale: locale)
            )
            XCTAssertEqual(
                BillingCycleCopy.fableValue(label: "Fable", s, locale: locale),
                LocalizedStringResource.billingFableValue(
                    "Fable", UsageFormatters.wholePercent(42, monospaced: true, locale: locale)
                ).string(in: locale)
            )
        }
        XCTAssertEqual(UsageFormatters.wholePercent(42, monospaced: true, locale: L10n.fr), UsageFormatters.compactPercent(42, locale: L10n.fr))
        XCTAssertEqual(UsageFormatters.oneDecimal(1.46, locale: L10n.en), "1.5")
        XCTAssertEqual(UsageFormatters.oneDecimal(1.46, locale: L10n.fr), "1,5")
        XCTAssertEqual(UsageFormatters.oneDecimal(1.46, locale: L10n.uk), "1,5")
        // Rounds as 1.3.0's `%.1f` did (the binary value of 0.15 is just below).
        XCTAssertEqual(UsageFormatters.oneDecimal(0.15, locale: L10n.en), String(format: "%.1f", 0.15))
        // The region never changes English.
        XCTAssertEqual(UsageFormatters.wholePercent(42, monospaced: false, locale: Locale(identifier: "en_DE")), "42%")
        XCTAssertEqual(UsageFormatters.oneDecimal(1.46, locale: Locale(identifier: "en_DE")), "1.5")
    }

    /// The watched hours are capped at the elapsed hours, as in 1.3.0.
    func testDetailCapsWatchedHoursAtElapsed() {
        let over = CycleUtilizationSummary(
            windowKind: .weekly, family: .rolling, capacityUtilization: 1.0, isLegacyLowerBound: true, consumedAllowances: 2.0,
            daysUsed: 5, atCapDays: 0, observedHours: 70, elapsedHours: 60,
            observedSeconds: 70 * 3600, elapsedSeconds: 60 * 3600
        )
        XCTAssertEqual(
            BillingCycleCopy.detail(over, locale: L10n.en),
            "≥ 2.0× weekly allowance · Used 5 days · At ≥95% 0 days · watched 60/60 hrs"
        )
    }

    /// The day counts are plurals: "Used 1 day", never "Used 1 days". French
    /// and Ukrainian abbreviate the unit ("j", "дн."), which does not change
    /// with the count, but every plural category is still spelled out.
    func testDetailDayCountsArePlurals() {
        func detail(_ used: Int, _ atCap: Int, _ locale: Locale) -> String {
            let s = CycleUtilizationSummary(
                windowKind: .weekly, family: .rolling, capacityUtilization: 0.1, isLegacyLowerBound: true, consumedAllowances: 0.5,
                daysUsed: used, atCapDays: atCap, observedHours: 10, elapsedHours: 10,
            observedSeconds: 10 * 3600, elapsedSeconds: 10 * 3600
            )
            return BillingCycleCopy.detail(s, locale: locale)
        }
        let enPrefix = "≥ 0.5× weekly allowance · "
        XCTAssertEqual(detail(1, 0, L10n.en), enPrefix + "Used 1 day · At ≥95% 0 days · watched 10/10 hrs")
        XCTAssertEqual(detail(2, 1, L10n.en), enPrefix + "Used 2 days · At ≥95% 1 day · watched 10/10 hrs")
        XCTAssertEqual(detail(21, 5, L10n.en), enPrefix + "Used 21 days · At ≥95% 5 days · watched 10/10 hrs")

        let frPrefix = "≥ 0,5× l’allocation hebdomadaire · "
        XCTAssertEqual(detail(1, 0, L10n.fr), frPrefix + "utilisé 1\(nb)j · à ≥95\(nb)%\(nb): 0\(nb)j · suivi 10/10\(nb)h")
        XCTAssertEqual(detail(2, 21, L10n.fr), frPrefix + "utilisé 2\(nb)j · à ≥95\(nb)%\(nb): 21\(nb)j · suivi 10/10\(nb)h")

        let ukPrefix = "≥ 0,5× тижневого обсягу · "
        // one (1, 21), few (2), many (5, 11): the abbreviation stays "дн.".
        XCTAssertEqual(detail(1, 2, L10n.uk), ukPrefix + "використано 1 дн. · на ≥95%: 2 дн. · відстежено 10/10 год")
        XCTAssertEqual(detail(5, 11, L10n.uk), ukPrefix + "використано 5 дн. · на ≥95%: 11 дн. · відстежено 10/10 год")
        XCTAssertEqual(detail(21, 0, L10n.uk), ukPrefix + "використано 21 дн. · на ≥95%: 0 дн. · відстежено 10/10 год")
    }

    // MARK: Billing cycle v2 (average load / average peak)

    private func v2(
        _ kind: UsageWindowKind = .weekly, _ family: WindowFamily = .rolling, _ value: Double = 0.424,
        daysUsed: Int = 2, atCapDays: Int = 1, observedSeconds: Double = 40 * 3600
    ) -> CycleUtilizationSummary {
        CycleUtilizationSummary(
            windowKind: kind, family: family, capacityUtilization: value, isLegacyLowerBound: false,
            consumedAllowances: 1.46, daysUsed: daysUsed, atCapDays: atCapDays,
            observedHours: Int(observedSeconds / 3600), elapsedHours: 58,
            observedSeconds: observedSeconds, elapsedSeconds: 58 * 3600
        )
    }

    /// v2 is a plain "N%": no "≥", in every language.
    func testV2HeadlineIsAPlainPercentInEveryLanguage() {
        XCTAssertEqual(BillingCycleCopy.headline(v2(), locale: L10n.en), "42%")
        XCTAssertEqual(BillingCycleCopy.headline(v2(), locale: L10n.fr), "42\(nnb)%")
        XCTAssertEqual(BillingCycleCopy.headline(v2(), locale: L10n.uk), "42%")
        XCTAssertEqual(BillingCycleCopy.headline(v2(.fiveHour, .fixed, 0.6), locale: L10n.en), "60%")
    }

    /// Over 100% is impossible by construction; the display clamps anyway.
    func testV2HeadlineClampsToZeroThroughHundred() {
        XCTAssertEqual(BillingCycleCopy.headline(v2(.weekly, .rolling, 1.3), locale: L10n.en), "100%")
        XCTAssertEqual(BillingCycleCopy.headline(v2(.weekly, .fixed, -0.02), locale: L10n.en), "0%")
        XCTAssertEqual(BillingCycleCopy.displayFraction(v2(.weekly, .rolling, 1.3)), 1)
        XCTAssertEqual(BillingCycleCopy.displayFraction(v2(.weekly, .rolling, -0.2)), 0)
        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", v2(.modelWeekly, .rolling, 1.7), locale: L10n.en),
                       "Fable 100% this cycle · average weekly load")
    }

    /// The legacy fallback keeps its figure unclamped, as in 1.4.0.
    func testLegacyDisplayIsNotClamped() {
        let over = CycleUtilizationSummary(
            windowKind: .weekly, family: .rolling, capacityUtilization: 1.3, isLegacyLowerBound: true,
            consumedAllowances: 1, daysUsed: 1, atCapDays: 0, observedHours: 50, elapsedHours: 60,
            observedSeconds: 50 * 3600, elapsedSeconds: 60 * 3600
        )
        XCTAssertEqual(BillingCycleCopy.headline(over, locale: L10n.en), "≥ 130%")
        XCTAssertEqual(BillingCycleCopy.displayFraction(over), 1.3)
    }

    /// The caption names the family and the window; Fable (model-weekly)
    /// follows its window kind.
    func testV2CaptionsInEveryLanguage() {
        let expected: [(UsageWindowKind, WindowFamily, String, String, String)] = [
            (.weekly, .rolling, "average weekly load", "charge hebdomadaire moyenne", "середнє тижневе навантаження"),
            (.modelWeekly, .rolling, "average weekly load", "charge hebdomadaire moyenne", "середнє тижневе навантаження"),
            (.fiveHour, .rolling, "average 5-hour load", "charge moyenne sur 5\(nb)h", "середнє 5-годинне навантаження"),
            (.weekly, .fixed, "average peak per week", "pic moyen par semaine", "середній пік за тиждень"),
            (.modelWeekly, .fixed, "average peak per week", "pic moyen par semaine", "середній пік за тиждень"),
            (.fiveHour, .fixed, "average peak per 5 hours", "pic moyen par période de 5\(nb)h", "середній пік за 5 годин"),
        ]
        for (kind, family, en, fr, uk) in expected {
            let s = v2(kind, family)
            XCTAssertEqual(BillingCycleCopy.caption(s, locale: L10n.en), en, "\(kind) \(family)")
            XCTAssertEqual(BillingCycleCopy.caption(s, locale: L10n.fr), fr, "\(kind) \(family)")
            XCTAssertEqual(BillingCycleCopy.caption(s, locale: L10n.uk), uk, "\(kind) \(family)")
        }
    }

    /// The legacy fallback keeps the exact 1.4.0 caption.
    func testLegacyCaptionIsTheObservedLowerBound() {
        let s = summary()
        XCTAssertEqual(BillingCycleCopy.caption(s, locale: L10n.en), "observed lower bound")
        XCTAssertEqual(BillingCycleCopy.caption(s, locale: L10n.fr), "borne inférieure observée")
        XCTAssertEqual(BillingCycleCopy.caption(s, locale: L10n.uk), "спостережена нижня межа")
    }

    /// The v2 detail keeps the days and "watched", and drops the net-burn
    /// allowance multiple (a legacy figure with a different meaning).
    func testV2DetailInEveryLanguage() {
        XCTAssertEqual(BillingCycleCopy.detail(v2(), locale: L10n.en), "Used 2 days · At ≥95% 1 day · watched 40/58 hrs")
        XCTAssertEqual(
            BillingCycleCopy.detail(v2(), locale: L10n.fr),
            "Utilisé 2\(nb)j · à ≥95\(nb)%\(nb): 1\(nb)j · suivi 40/58\(nb)h"
        )
        XCTAssertEqual(
            BillingCycleCopy.detail(v2(), locale: L10n.uk),
            "Використано 2 дн. · на ≥95%: 1 дн. · відстежено 40/58 год"
        )
        XCTAssertEqual(BillingCycleCopy.detail(v2(.fiveHour, .fixed), locale: L10n.en),
                       "Used 2 days · At ≥95% 1 day · watched 40/58 hrs")
    }

    func testV2DetailDayCountsArePlurals() {
        XCTAssertEqual(BillingCycleCopy.detail(v2(daysUsed: 1, atCapDays: 0), locale: L10n.en),
                       "Used 1 day · At ≥95% 0 days · watched 40/58 hrs")
        XCTAssertEqual(BillingCycleCopy.detail(v2(daysUsed: 21, atCapDays: 1), locale: L10n.en),
                       "Used 21 days · At ≥95% 1 day · watched 40/58 hrs")
        XCTAssertEqual(BillingCycleCopy.detail(v2(daysUsed: 1, atCapDays: 2), locale: L10n.fr),
                       "Utilisé 1\(nb)j · à ≥95\(nb)%\(nb): 2\(nb)j · suivi 40/58\(nb)h")
        XCTAssertEqual(BillingCycleCopy.detail(v2(daysUsed: 5, atCapDays: 21), locale: L10n.uk),
                       "Використано 5 дн. · на ≥95%: 21 дн. · відстежено 40/58 год")
    }

    /// "watched" counts whole hours of observed seconds (a sleep-gapped hour
    /// is partly watched), capped at the elapsed hours in the detail line.
    func testWatchedHoursComeFromObservedSeconds() {
        let partial = v2(observedSeconds: 41 * 3600 - 1)
        XCTAssertEqual(BillingCycleCopy.watchedHours(partial), 40)
        XCTAssertTrue(BillingCycleCopy.detail(partial, locale: L10n.en).hasSuffix("watched 40/58 hrs"))
        XCTAssertEqual(BillingCycleCopy.watched(partial, cycle: cycle, locale: L10n.en), "watched 40 of 58 hrs · Day 3/30")
        // `observedHours` disagrees on purpose: the seconds are the source.
        let seconds = CycleUtilizationSummary(
            windowKind: .weekly, family: .rolling, capacityUtilization: 0.3, isLegacyLowerBound: false,
            consumedAllowances: 0, daysUsed: 1, atCapDays: 0, observedHours: 7, elapsedHours: 58,
            observedSeconds: 30.5 * 3600, elapsedSeconds: 58 * 3600
        )
        XCTAssertEqual(BillingCycleCopy.watchedHours(seconds), 30)
        let over = v2(observedSeconds: 70 * 3600)
        XCTAssertTrue(BillingCycleCopy.detail(over, locale: L10n.en).hasSuffix("watched 58/58 hrs"))
    }

    func testV2FableLineInEveryLanguage() {
        let fable = v2(.modelWeekly, .rolling, 0.424)
        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", fable, locale: L10n.en),
                       "Fable 42% this cycle · average weekly load")
        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", fable, locale: L10n.fr),
                       "Fable 42\(nb)% sur ce cycle · charge hebdomadaire moyenne")
        XCTAssertEqual(BillingCycleCopy.fableValue(label: "Fable", fable, locale: L10n.uk),
                       "Fable 42% у цьому циклі · середнє тижневе навантаження")
    }

    // MARK: Whole cards

    /// Every line of each card state, in every language: v2 rolling (with a
    /// v2 Fable line), v2 fixed, legacy (with a not-enough-data Fable line),
    /// not enough data, and no renewal day. The card view draws exactly
    /// `BillingCycleCopy.cardText`, so wrong or missing copy fails here.
    func testCardTextForEveryStateInEveryLanguage() {
        let utcZone = TimeZone(identifier: "UTC")!
        func sufficient(_ family: WindowFamily, _ value: Double, legacy: Bool = false, kind: UsageWindowKind = .weekly) -> CycleUtilizationSummary {
            CycleUtilizationSummary(
                windowKind: kind, family: family, capacityUtilization: value, isLegacyLowerBound: legacy,
                consumedAllowances: 1.46, daysUsed: 2, atCapDays: 1, observedHours: 50, elapsedHours: 58,
                observedSeconds: 50 * 3600, elapsedSeconds: 58 * 3600
            )
        }
        let id = UUID()
        let rolling = BillingCycleCard.tracked(
            id: id, label: "Work", provider: .claude, cycle: cycle, summary: sufficient(.rolling, 0.424),
            fable: FableSecondary(label: "Fable", summary: sufficient(.rolling, 0.31, kind: .modelWeekly)))
        let fixed = BillingCycleCard.tracked(
            id: id, label: "Work", provider: .chatGPT, cycle: cycle, summary: sufficient(.fixed, 0.6), fable: nil)
        let legacy = BillingCycleCard.tracked(
            id: id, label: "Work", provider: .claude, cycle: cycle, summary: sufficient(.rolling, 0.424, legacy: true),
            fable: FableSecondary(label: "Fable", summary: nil))
        let insufficient = BillingCycleCard.tracked(
            id: id, label: "Work", provider: .claude, cycle: cycle, summary: summary(), fable: nil)
        let unset = BillingCycleCard.noRenewalDay(id: id, label: "Work", provider: .chatGPT)

        struct Expected {
            let locale: Locale
            let subtitle, noCycle: String
            let v2Headline, rollingCaption, v2Detail, fable: String
            let fixedHeadline, fixedCaption: String
            let legacyHeadline, legacyCaption, legacyDetail, fableInsufficient: String
            let notEnough, watched: String
        }
        let expected: [Expected] = [
            Expected(
                locale: L10n.en, subtitle: "Cycle Sep 12 – Oct 11 · Day 3/30", noCycle: "No billing cycle set",
                v2Headline: "42%", rollingCaption: "average weekly load",
                v2Detail: "Used 2 days · At ≥95% 1 day · watched 50/58 hrs",
                fable: "Fable 31% this cycle · average weekly load",
                fixedHeadline: "60%", fixedCaption: "average peak per week",
                legacyHeadline: "≥ 42%", legacyCaption: "observed lower bound",
                legacyDetail: "≥ 1.5× weekly allowance · Used 2 days · At ≥95% 1 day · watched 50/58 hrs",
                fableInsufficient: "Fable · not enough data yet this cycle",
                notEnough: "Not enough data yet", watched: "watched 40 of 58 hrs · Day 3/30"
            ),
            Expected(
                locale: L10n.fr, subtitle: "Cycle du 12 sept. au 11 oct. · jour 3/30", noCycle: "Aucun cycle de facturation défini",
                v2Headline: "42\(nnb)%", rollingCaption: "charge hebdomadaire moyenne",
                v2Detail: "Utilisé 2\(nb)j · à ≥95\(nb)%\(nb): 1\(nb)j · suivi 50/58\(nb)h",
                fable: "Fable 31\(nb)% sur ce cycle · charge hebdomadaire moyenne",
                fixedHeadline: "60\(nnb)%", fixedCaption: "pic moyen par semaine",
                legacyHeadline: "≥ 42\(nnb)%", legacyCaption: "borne inférieure observée",
                legacyDetail: "≥ 1,5× l’allocation hebdomadaire · utilisé 2\(nb)j · à ≥95\(nb)%\(nb): 1\(nb)j · suivi 50/58\(nb)h",
                fableInsufficient: "Fable · pas encore assez de données sur ce cycle",
                notEnough: "Pas encore assez de données", watched: "suivi 40\(nb)h sur 58 · jour 3/30"
            ),
            Expected(
                locale: L10n.uk, subtitle: "Цикл 12 вер. – 11 жовт. · день 3/30", noCycle: "Платіжний цикл не задано",
                v2Headline: "42%", rollingCaption: "середнє тижневе навантаження",
                v2Detail: "Використано 2 дн. · на ≥95%: 1 дн. · відстежено 50/58 год",
                fable: "Fable 31% у цьому циклі · середнє тижневе навантаження",
                fixedHeadline: "60%", fixedCaption: "середній пік за тиждень",
                legacyHeadline: "≥ 42%", legacyCaption: "спостережена нижня межа",
                legacyDetail: "≥ 1,5× тижневого обсягу · використано 2 дн. · на ≥95%: 1 дн. · відстежено 50/58 год",
                fableInsufficient: "Fable · у цьому циклі ще недостатньо даних",
                notEnough: "Ще недостатньо даних", watched: "відстежено 40 з 58 год · день 3/30"
            ),
        ]
        for e in expected {
            func text(_ card: BillingCycleCard) -> BillingCycleCardText {
                BillingCycleCopy.cardText(card, locale: e.locale, timeZone: utcZone)
            }
            let name = e.locale.identifier
            XCTAssertEqual(text(rolling), BillingCycleCardText(
                label: "Work", subtitle: e.subtitle,
                body: .figure(headline: e.v2Headline, caption: e.rollingCaption, detail: e.v2Detail,
                              fable: .init(text: e.fable, isInsufficient: false))), name)
            XCTAssertEqual(text(fixed), BillingCycleCardText(
                label: "Work", subtitle: e.subtitle,
                body: .figure(headline: e.fixedHeadline, caption: e.fixedCaption, detail: e.v2Detail, fable: nil)), name)
            XCTAssertEqual(text(legacy), BillingCycleCardText(
                label: "Work", subtitle: e.subtitle,
                body: .figure(headline: e.legacyHeadline, caption: e.legacyCaption, detail: e.legacyDetail,
                              fable: .init(text: e.fableInsufficient, isInsufficient: true))), name)
            XCTAssertEqual(text(insufficient), BillingCycleCardText(
                label: "Work", subtitle: e.subtitle,
                body: .insufficient(notEnoughData: e.notEnough, watched: e.watched)), name)
            XCTAssertEqual(text(unset), BillingCycleCardText(label: "Work", subtitle: e.noCycle, body: .noRenewalDay), name)
        }
    }

    // MARK: SwiftUI literal keys

    func testViewLiteralsResolve() {
        let expected: [(key: String, fr: String, uk: String)] = [
            ("Mode", "Mode", "Режим"),
            ("Patterns", "Tendances", "Тенденції"),
            ("Billing cycle", "Cycle de facturation", "Цикл оплати"),
            ("Account", "Compte", "Обліковий запис"),
            ("All accounts", "Tous les comptes", "Усі облікові записи"),
            ("Window", "Fenêtre", "Вікно"),
            ("Daily Burn", "Consommation quotidienne", "Щоденне витрачання"),
            ("Day", "Jour", "День"),
            ("Consumed", "Consommé", "Витрачено"),
            ("Add an account to see usage history.",
             "Ajoutez un compte pour voir l’historique d’utilisation.",
             "Додайте обліковий запис, щоб бачити історію використання."),
            ("No rolling windows", "Aucune fenêtre glissante", "Немає ковзних вікон"),
            ("Cursor tracks usage-based spend rather than 5h or weekly windows — its spend and cycle reset show on its account card.",
             "Cursor suit les dépenses à l’usage plutôt que des fenêtres de 5\(nb)h ou hebdomadaires — ses dépenses et la réinitialisation de son cycle s’affichent sur la carte de son compte.",
             "Cursor відстежує витрати на використання, а не 5-годинні чи тижневі вікна, — його витрати й скидання циклу показано на картці облікового запису."),
            ("No history yet", "Pas encore d’historique", "Історії ще немає"),
            ("Usage is recorded as it's fetched.",
             "L’utilisation est enregistrée à chaque récupération.",
             "Використання записується щоразу, коли надходять дані."),
            ("Hour of Day", "Heure de la journée", "Година доби"),
            ("Nothing to reconstruct", "Rien à reconstituer", "Нічого відновлювати"),
            ("No billing cycles set", "Aucun cycle de facturation défini", "Платіжні цикли не задано"),
            ("Set a billing renewal day for an account in Settings to see its cycle utilisation.",
             "Définissez un jour de facturation pour un compte dans les Réglages afin de voir son utilisation par cycle.",
             "Задайте день оплати для облікового запису в Параметрах, щоб бачити використання за цикл."),
            ("Set a billing renewal day", "Définir un jour de facturation", "Задати день оплати"),
            ("Set a renewal day in Settings to track this subscription's cycle.",
             "Définissez un jour de facturation dans les Réglages pour suivre le cycle de cet abonnement.",
             "Задайте день оплати в Параметрах, щоб відстежувати цикл цієї підписки."),
            ("Set a renewal day", "Définir le jour de facturation", "Задати день оплати"),
            ("Not enough data yet", "Pas encore assez de données", "Ще недостатньо даних"),
            ("observed lower bound", "borne inférieure observée", "спостережена нижня межа"),
            // Reused from Tasks 5 and 6.
            ("History", "Historique", "Історія"),
            ("No accounts", "Aucun compte", "Немає облікових записів"),
        ]
        for entry in expected {
            let resource = LocalizedStringResource(String.LocalizationValue(entry.key))
            XCTAssertEqual(resource.string(in: L10n.en), entry.key)
            XCTAssertEqual(resource.string(in: L10n.fr), entry.fr, entry.key)
            XCTAssertEqual(resource.string(in: L10n.uk), entry.uk, entry.key)
        }
    }

    func testInterpolatedLiteralsResolve() {
        let names = "Claude or ChatGPT"
        let add = LocalizedStringResource("Add \(names) to track billing cycles.")
        XCTAssertEqual(add.string(in: L10n.en), "Add Claude or ChatGPT to track billing cycles.")
        let frNames = BillingCycleEligibility.supportedProviderNames(locale: L10n.fr)
        XCTAssertEqual(
            LocalizedStringResource("Add \(frNames) to track billing cycles.").string(in: L10n.fr),
            "Ajoutez un compte Claude ou ChatGPT pour suivre les cycles de facturation."
        )
        let ukNames = BillingCycleEligibility.supportedProviderNames(locale: L10n.uk)
        XCTAssertEqual(
            LocalizedStringResource("Add \(ukNames) to track billing cycles.").string(in: L10n.uk),
            "Додайте обліковий запис Claude або ChatGPT, щоб відстежувати платіжні цикли."
        )
        let reconstruct = LocalizedStringResource(
            "Cursor reports its billing cycle directly — see the usage rows on its account card. This window reconstructs cycle usage for \(frNames), which don't report it."
        )
        XCTAssertEqual(
            reconstruct.string(in: L10n.fr),
            "Cursor indique directement son cycle de facturation — voir les lignes d’utilisation sur la carte de son compte. Cette fenêtre reconstitue l’utilisation par cycle pour Claude ou ChatGPT, qui ne l’indiquent pas."
        )
    }

    func testDefaultsFollowTheRunningLanguage() {
        let running = Locale(identifier: AppLanguage.current.rawValue)
        let paused = record(.claude, "Work", paused: true)
        XCTAssertEqual(paused.historyLabel, paused.historyLabel(locale: running))
        XCTAssertEqual(BillingCycleCopy.noCycleSubtitle(), BillingCycleCopy.noCycleSubtitle(locale: running))
        XCTAssertEqual(
            BillingCycleEligibility.supportedProviderNames(),
            BillingCycleEligibility.supportedProviderNames(locale: running)
        )
    }
}
