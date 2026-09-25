import XCTest
@testable import Ration

/// Spoken durations, spoken window names, the reset-credit line, the NEXT
/// RESET line's spoken form and the "resets in" wrappers, in every shipped
/// language.
final class ResetCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func spoken(_ seconds: TimeInterval, _ locale: Locale) -> String {
        UsageFormatters.spokenDuration(until: now.addingTimeInterval(seconds), relativeTo: now, locale: locale)
    }

    // MARK: Spoken durations

    func testSpokenDurationEnglishIsUnchanged() {
        XCTAssertEqual(spoken(-30, L10n.en), "now")
        XCTAssertEqual(spoken(30, L10n.en), "less than a minute")
        XCTAssertEqual(spoken(60, L10n.en), "1 minute")
        XCTAssertEqual(spoken(4 * 3600 + 12 * 60 + 30, L10n.en), "4 hours, 12 minutes")
        XCTAssertEqual(spoken(24 * 3600, L10n.en), "1 day")
        XCTAssertEqual(spoken(6 * 24 * 3600 + 3 * 3600 + 45 * 60, L10n.en), "6 days, 3 hours")
        XCTAssertEqual(spoken(7 * 24 * 3600, L10n.en), "7 days")
    }

    func testSpokenDurationFrench() {
        XCTAssertEqual(spoken(-30, L10n.fr), "maintenant")
        XCTAssertEqual(spoken(0, L10n.fr), "maintenant")
        XCTAssertEqual(spoken(30, L10n.fr), "moins d’une minute")
        XCTAssertEqual(spoken(60, L10n.fr), "1 minute")
        XCTAssertEqual(spoken(45 * 60 + 59, L10n.fr), "45 minutes")
        XCTAssertEqual(spoken(3600, L10n.fr), "1 heure")
        XCTAssertEqual(spoken(4 * 3600 + 12 * 60 + 30, L10n.fr), "4 heures et 12 minutes")
        XCTAssertEqual(spoken(24 * 3600, L10n.fr), "1 jour")
        XCTAssertEqual(spoken(6 * 24 * 3600 + 3 * 3600 + 45 * 60, L10n.fr), "6 jours et 3 heures")
        XCTAssertEqual(spoken(7 * 24 * 3600, L10n.fr), "7 jours")
    }

    func testSpokenDurationUkrainian() {
        XCTAssertEqual(spoken(-30, L10n.uk), "зараз")
        XCTAssertEqual(spoken(30, L10n.uk), "менше ніж хвилину")
        XCTAssertEqual(spoken(4 * 3600 + 12 * 60 + 30, L10n.uk), "4 години 12 хвилин")
        XCTAssertEqual(spoken(6 * 24 * 3600 + 3 * 3600 + 45 * 60, L10n.uk), "6 днів 3 години")
    }

    func testSpokenDurationUkrainianPlurals() {
        let minutes: [Int: String] = [1: "1 хвилину", 2: "2 хвилини", 5: "5 хвилин", 21: "21 хвилину", 22: "22 хвилини", 25: "25 хвилин"]
        let hours: [Int: String] = [1: "1 годину", 2: "2 години", 5: "5 годин", 21: "21 годину", 22: "22 години"]
        let days: [Int: String] = [1: "1 день", 2: "2 дні", 5: "5 днів", 21: "21 день", 22: "22 дні", 25: "25 днів"]
        for (count, expected) in minutes {
            XCTAssertEqual(spoken(TimeInterval(count * 60), L10n.uk), expected)
        }
        for (count, expected) in hours {
            XCTAssertEqual(spoken(TimeInterval(count * 3600), L10n.uk), expected)
        }
        for (count, expected) in days {
            XCTAssertEqual(spoken(TimeInterval(count * 86_400), L10n.uk), expected)
        }
    }

    // MARK: Spoken window names (the drawn tags stay 5H / WK / FABLE)

    func testSpokenWindowNames() {
        XCTAssertEqual(UsageWindowKind.fiveHour.spokenName(locale: L10n.en), "5 hour")
        XCTAssertEqual(UsageWindowKind.fiveHour.spokenName(locale: L10n.fr), "fenêtre de 5 heures")
        XCTAssertEqual(UsageWindowKind.weekly.spokenName(locale: L10n.fr), "fenêtre hebdomadaire")
        XCTAssertEqual(UsageWindowKind.modelWeekly.spokenName(label: "Opus", locale: L10n.fr), "fenêtre hebdomadaire Opus")
        XCTAssertEqual(UsageWindowKind.fiveHour.spokenName(locale: L10n.uk), "5-годинне вікно")
        XCTAssertEqual(UsageWindowKind.weekly.spokenName(label: "Opus", locale: L10n.uk), "тижневе вікно")
        XCTAssertEqual(UsageWindowKind.modelWeekly.spokenName(locale: L10n.uk), "тижневе вікно Fable")
        XCTAssertEqual(WindowTag.text(kind: .weekly, label: nil), "WK")
    }

    // MARK: Reset-credit line

    private func summary(_ count: Int, within: Bool = true, noneUsable: Bool = false) -> ResetCreditsSummary {
        ResetCreditsSummary(
            totalCount: count,
            soonestExpiry: now.addingTimeInterval(within ? 18 * 3600 : 20 * 86_400),
            withinLeadWindow: within,
            noneUsable: noneUsable
        )
    }

    private func shortDate(_ locale: Locale) -> String {
        now.addingTimeInterval(20 * 86_400).formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    private func wideDate(_ locale: Locale) -> String {
        now.addingTimeInterval(20 * 86_400).formatted(.dateTime.month(.wide).day().locale(locale))
    }

    func testResetCreditLineFrench() {
        XCTAssertEqual(summary(1).text(now: now, locale: L10n.fr), "↻ 1 réinitialisation · expire dans 18\(nb)h")
        XCTAssertEqual(
            summary(3, within: false, noneUsable: true).text(now: now, locale: L10n.fr),
            "↻ 3 réinitialisations · la prochaine expire le \(shortDate(L10n.fr)) · pas encore utilisable"
        )
        XCTAssertEqual(summary(2).text(now: now, locale: L10n.fr), "↻ 2 réinitialisations · la prochaine expire dans 18\(nb)h")
        XCTAssertEqual(summary(1, within: false).text(now: now, locale: L10n.fr), "↻ 1 réinitialisation · expire le \(shortDate(L10n.fr))")
    }

    func testResetCreditLineUkrainianPlurals() {
        XCTAssertEqual(summary(0).text(now: now, locale: L10n.uk), "↻ 0 скидань · діє ще 18\(nb)год")
        XCTAssertEqual(summary(1).text(now: now, locale: L10n.uk), "↻ 1 скидання · діє ще 18\(nb)год")
        let nouns: [Int: String] = [2: "скидання", 5: "скидань", 21: "скидання", 22: "скидання", 25: "скидань"]
        for (count, noun) in nouns {
            XCTAssertEqual(
                summary(count).text(now: now, locale: L10n.uk),
                "↻ \(count) \(noun) · наступне діє ще 18\(nb)год",
                "\(count)"
            )
        }
        XCTAssertEqual(
            summary(5, within: false, noneUsable: true).text(now: now, locale: L10n.uk),
            "↻ 5 скидань · наступне діє до \(shortDate(L10n.uk)) · поки недоступно"
        )
    }

    func testResetCreditLineEnglishKeepsItsWordingForZeroOneAndMany() {
        XCTAssertEqual(summary(0).text(now: now, locale: L10n.en), "↻ 0 resets · expires in 18h")
        XCTAssertEqual(summary(1).text(now: now, locale: L10n.en), "↻ 1 reset · expires in 18h")
        XCTAssertEqual(
            summary(2, within: false, noneUsable: true).text(now: now, locale: L10n.en),
            "↻ 2 resets · next expires \(shortDate(L10n.en)) · not usable yet"
        )
    }

    func testResetCreditSpokenLine() {
        XCTAssertEqual(
            summary(1).accessibilityText(now: now, locale: L10n.fr),
            "Réinitialisations de limite\(nb): 1, expire dans 18 heures"
        )
        XCTAssertEqual(
            summary(3, within: false, noneUsable: true).accessibilityText(now: now, locale: L10n.fr),
            "Réinitialisations de limite\(nb): 3, la prochaine expire le \(wideDate(L10n.fr)), pas encore utilisable"
        )
        XCTAssertEqual(
            summary(21).accessibilityText(now: now, locale: L10n.uk),
            "Скидання ліміту: 21, наступне діє ще 18 годин"
        )
        XCTAssertEqual(
            summary(1, within: false, noneUsable: true).accessibilityText(now: now, locale: L10n.uk),
            "Скидання ліміту: 1, діє до \(wideDate(L10n.uk)), поки недоступно"
        )
    }

    // MARK: NEXT RESET, spoken

    func testSoonestResetSpoken() {
        let next = SoonestReset(accountLabel: "Max", kind: .weekly, resetsAt: now.addingTimeInterval(45 * 60), label: nil)
        XCTAssertEqual(next.accessibilityLabel(now: now, locale: L10n.en), "Next reset, Max weekly, in 45 minutes")
        XCTAssertEqual(
            next.accessibilityLabel(now: now, locale: L10n.fr),
            "Prochaine réinitialisation\(nb): Max, fenêtre hebdomadaire, dans 45 minutes"
        )
        XCTAssertEqual(
            next.accessibilityLabel(now: now, locale: L10n.uk),
            "Наступне скидання: Max, тижневе вікно, через 45 хвилин"
        )
        let fable = SoonestReset(accountLabel: "Max", kind: .modelWeekly, resetsAt: now.addingTimeInterval(21 * 60), label: "Fable")
        XCTAssertEqual(
            fable.accessibilityLabel(now: now, locale: L10n.uk),
            "Наступне скидання: Max, тижневе вікно Fable, через 21 хвилину"
        )
    }

    // MARK: "resets in" wrappers

    func testCursorSpendResetsInWrapper() {
        let spend = CursorSpend(
            spentCents: 1_250,
            periodStart: now.addingTimeInterval(-86_400),
            resetsAt: now.addingTimeInterval(4 * 86_400 + 3 * 3600),
            planLabel: "Pro"
        )
        XCTAssertTrue(
            CursorSpendRow.text(for: spend, now: now, locale: L10n.fr).caption.hasSuffix("réinitialisation dans 4\(nb)j 3\(nb)h")
        )
        XCTAssertTrue(
            CursorSpendRow.text(for: spend, now: now, locale: L10n.uk).caption.hasSuffix("скидання через 4\(nb)д 3\(nb)год")
        )
        XCTAssertTrue(
            CursorSpendRow.accessibilityDescription(for: spend, now: now, locale: L10n.uk).hasSuffix("скидання через 4 дні 3 години")
        )
        XCTAssertTrue(CursorSpendRow.text(for: spend, now: now, locale: L10n.en).caption.hasSuffix("resets in 4d 3h"))
    }

    func testLimitRowSpokenResetClause() {
        let resetsAt = now.addingTimeInterval(2 * 3600 + 5 * 60)
        let window = UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: resetsAt)
        let utc = TimeZone(identifier: "UTC")!
        let exactFR = UsageFormatters.exactReset(resetsAt, locale: L10n.fr, timeZone: utc)
        let exactUK = UsageFormatters.exactReset(resetsAt, locale: L10n.uk, timeZone: utc)
        XCTAssertTrue(
            LimitRowView.accessibilityDescription(title: "WK", kind: .weekly, window: window, now: now, locale: L10n.fr, timeZone: utc)
                .hasSuffix("réinitialisation dans 2 heures et 5 minutes, le \(exactFR)")
        )
        XCTAssertTrue(
            LimitRowView.accessibilityDescription(title: "WK", kind: .weekly, window: window, now: now, locale: L10n.uk, timeZone: utc)
                .hasSuffix("скидання через 2 години 5 хвилин, \(exactUK)")
        )
        let due = UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: now)
        XCTAssertTrue(
            LimitRowView.accessibilityDescription(title: "WK", kind: .weekly, window: due, now: now, locale: L10n.uk, timeZone: utc)
                .hasSuffix("скидання зараз, \(UsageFormatters.exactReset(now, locale: L10n.uk, timeZone: utc))")
        )
    }
}
