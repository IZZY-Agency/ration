import XCTest
@testable import Ration

/// Focus layout copy and the attention drop's header and spoken rows, in
/// every shipped language.
final class FocusAndDropCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Focus

    func testFocusCaptions() {
        XCTAssertEqual(FocusModel.caption(.weekly, label: nil, locale: L10n.en), "of the week left")
        XCTAssertEqual(FocusModel.caption(.weekly, label: nil, locale: L10n.fr), "de la semaine restant")
        XCTAssertEqual(FocusModel.caption(.fiveHour, label: nil, locale: L10n.fr), "des 5 heures restant")
        XCTAssertEqual(FocusModel.caption(.modelWeekly, label: "Fable", locale: L10n.fr), "de Fable restant")
        XCTAssertEqual(FocusModel.caption(.weekly, label: nil, locale: L10n.uk), "тижня залишилося")
        XCTAssertEqual(FocusModel.caption(.fiveHour, label: nil, locale: L10n.uk), "з 5 годин залишилося")
        XCTAssertEqual(FocusModel.caption(.modelWeekly, label: nil, locale: L10n.uk), "Fable залишилося")
    }

    func testFocusLimitsLine() {
        let limits = [
            FocusModel.Limit(kind: .fiveHour, label: nil, headroom: 0.73),
            FocusModel.Limit(kind: .weekly, label: nil, headroom: 0.4),
            FocusModel.Limit(kind: .modelWeekly, label: "Fable", headroom: 0.14),
        ]
        let resetsAt = now.addingTimeInterval(11 * 3600 + 18 * 60)
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, locale: L10n.en),
            "resets in 11h 18m · 5h 73% left · week 40% left · Fable 14% left"
        )
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, locale: L10n.fr),
            "réinitialisation dans 11\(nb)h 18\(nb)min · 5\(nb)h\(nb): 73\(nb)% restant · semaine\(nb): 40\(nb)% restant · Fable\(nb): 14\(nb)% restant"
        )
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, locale: L10n.uk),
            "скидання через 11\(nb)год 18\(nb)хв · 5\(nb)год: залишилося 73% · тиждень: залишилося 40% · Fable: залишилося 14%"
        )
    }

    func testFocusLineRightAndWarning() {
        let resetsAt = now.addingTimeInterval(2 * 86_400 + 2 * 3600)
        XCTAssertEqual(FocusModel.lineRight(headroom: 0.25, resetsAt: resetsAt, now: now, locale: L10n.fr), "25\(nb)% restant · 2\(nb)j 2\(nb)h")
        XCTAssertEqual(FocusModel.lineRight(headroom: 0.25, resetsAt: nil, now: now, locale: L10n.uk), "залишилося 25%")
        XCTAssertEqual(FocusModel.resetText(resetsAt, now: now, locale: L10n.uk), "скидання через 2\(nb)д 2\(nb)год")
        XCTAssertEqual(
            FocusModel.warningText(label: "Client", headroom: 0.01, kind: .weekly, windowLabel: nil, locale: L10n.fr),
            "Client · 1\(nb)% de la semaine restant"
        )
        XCTAssertEqual(
            FocusModel.warningText(label: "Client", headroom: 0.01, kind: .weekly, windowLabel: nil, locale: L10n.uk),
            "Client · 1% тижня залишилося"
        )
    }

    // MARK: Drop header

    func testDropHeaderDrawnText() {
        XCTAssertEqual(AttentionDropView.headerTitle(hasLimitRows: true, locale: L10n.fr), "LIMITES PROCHES")
        XCTAssertEqual(AttentionDropView.headerTitle(hasLimitRows: false, locale: L10n.fr), "RÉINITIALISATIONS")
        XCTAssertEqual(AttentionDropView.headerTitle(hasLimitRows: true, locale: L10n.uk), "БЛИЗЬКО ДО ЛІМІТІВ")
        XCTAssertEqual(AttentionDropView.headerTitle(hasLimitRows: false, locale: L10n.en), "RESETS")
        for count in L10n.ukrainianCounts {
            XCTAssertEqual(AttentionDropView.criticalCountText(count, locale: L10n.uk), "\(count) КРИТ")
            XCTAssertEqual(AttentionDropView.warningCountText(count, locale: L10n.uk), "\(count) ПОПЕР")
            XCTAssertEqual(AttentionDropView.resetCountText(count, locale: L10n.uk), "\(count) СКИД")
        }
        XCTAssertEqual(AttentionDropView.criticalCountText(2, locale: L10n.en), "2 CRIT")
        XCTAssertEqual(AttentionDropView.warningCountText(2, locale: L10n.fr), "2 AVERT")
        XCTAssertEqual(AttentionDropView.resetCountText(2, locale: L10n.fr), "2 RÉINIT")
    }

    func testDropHeaderSpoken() {
        XCTAssertEqual(
            AttentionDropView.headerAccessibilityLabel(critical: 2, warning: 1, resets: 2, hasLimitRows: true, locale: L10n.en),
            "Nearing limits, 2 critical, 1 warning, 2 resets"
        )
        XCTAssertEqual(
            AttentionDropView.headerAccessibilityLabel(critical: 2, warning: 1, resets: 1, hasLimitRows: true, locale: L10n.fr),
            "Limites proches, 2 critiques, 1 avertissement, 1 réinitialisation"
        )
        XCTAssertEqual(
            AttentionDropView.headerAccessibilityLabel(critical: 0, warning: 0, resets: 3, hasLimitRows: false, locale: L10n.fr),
            "Réinitialisations"
        )
        let critical: [Int: String] = [1: "1 критичний", 2: "2 критичні", 5: "5 критичних", 21: "21 критичний", 22: "22 критичні", 25: "25 критичних"]
        let warning: [Int: String] = [1: "1 попередження", 2: "2 попередження", 5: "5 попереджень", 21: "21 попередження", 22: "22 попередження", 25: "25 попереджень"]
        let resets: [Int: String] = [1: "1 скидання", 2: "2 скидання", 5: "5 скидань", 21: "21 скидання", 22: "22 скидання", 25: "25 скидань"]
        for count in [1, 2, 5, 21, 22, 25] {
            XCTAssertEqual(
                AttentionDropView.headerAccessibilityLabel(critical: count, warning: count, resets: count, hasLimitRows: true, locale: L10n.uk),
                "Близько до лімітів, \(critical[count]!), \(warning[count]!), \(resets[count]!)",
                "\(count)"
            )
        }
    }

    func testDropSubjectWords() {
        XCTAssertEqual(AttentionDropView.subjectLabel(.cursorSpend, locale: L10n.en), "SPEND")
        XCTAssertEqual(AttentionDropView.subjectLabel(.cursorSpend, locale: L10n.fr), "FRAIS")
        XCTAssertEqual(AttentionDropView.subjectLabel(.resetCredit(id: "c", kind: .available), locale: L10n.uk), "СКИДАННЯ")
        XCTAssertEqual(AttentionDropView.subjectLabel(.resetCredit(id: "c", kind: .expiring), locale: L10n.fr), "EXPIRE")
        XCTAssertEqual(AttentionDropView.subjectLabel(.window(.weekly), locale: L10n.uk), "WK")
    }

    // MARK: Drop rows, spoken

    private func row(
        subject: AttentionRow.Subject = .window(.weekly),
        tier: AlertTier = .critical,
        used: Int? = 92,
        spent: Int? = nil,
        resetsIn: TimeInterval? = 2 * 3600 + 5 * 60,
        resetCount: Int? = nil
    ) -> AttentionRow {
        AttentionRow(
            accountID: UUID(), accountLabel: "Work", provider: .claude, subject: subject, tier: tier,
            usedPercent: used, spentCents: spent, thresholdPercent: nil, thresholdCents: nil,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, resetCount: resetCount, resetCreditIDs: []
        )
    }

    func testDropLimitRowSpoken() {
        let advice = SwitchAdvice(
            provider: .claude, fromAccountID: UUID(), fromLabel: "Work",
            toAccountID: UUID(), toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(row(), now: now, advice: advice, locale: L10n.fr),
            "Work, fenêtre hebdomadaire, 92 pour cent utilisés, critique, réinitialisation dans 2 heures et 5 minutes, passer à Personal"
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(row(tier: .warning, used: 1), now: now, locale: L10n.fr),
            "Work, fenêtre hebdomadaire, 1 pour cent utilisé, avertissement, réinitialisation dans 2 heures et 5 minutes"
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(row(), now: now, advice: advice, locale: L10n.uk),
            "Work, тижневе вікно, використано 92 відсотки, критичний, скидання через 2 години 5 хвилин, перейти на Personal"
        )
        let percents: [Int: String] = [1: "1 відсоток", 2: "2 відсотки", 5: "5 відсотків", 21: "21 відсоток", 22: "22 відсотки", 25: "25 відсотків"]
        for (used, phrase) in percents {
            XCTAssertEqual(
                AttentionDropView.rowAccessibilityLabel(row(subject: .window(.fiveHour), tier: .warning, used: used, resetsIn: nil), now: now, locale: L10n.uk),
                "Work, 5-годинне вікно, використано \(phrase), попередження",
                "\(used)"
            )
        }
    }

    func testDropSpendRowSpoken() {
        let spend = row(subject: .cursorSpend, tier: .warning, used: nil, spent: 1_250, resetsIn: nil)
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(spend, now: now, locale: L10n.fr),
            "Work, dépenses, \(AlertMessage.dollars(1_250, locale: L10n.fr)) dépensés, avertissement"
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(spend, now: now, locale: L10n.uk),
            "Work, витрати, витрачено \(AlertMessage.dollars(1_250, locale: L10n.uk)), попередження"
        )
    }

    func testDropResetRowSpoken() {
        func reset(_ kind: ResetCreditRowKind, _ count: Int) -> AttentionRow {
            row(subject: .resetCredit(id: "c", kind: kind), tier: .warning, used: nil, resetsIn: 2 * 86_400, resetCount: count)
        }
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(reset(.available, 1), now: now, locale: L10n.en),
            "Work, 1 usage-limit reset available, expires in 2 days"
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(reset(.available, 3), now: now, locale: L10n.fr),
            "Work, 3 réinitialisations de limite disponibles, expire dans 2 jours"
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(reset(.expiring, 1), now: now, locale: L10n.fr),
            "Work, 1 réinitialisation de limite sur le point d’expirer, expire dans 2 jours"
        )
        let nouns: [Int: String] = [1: "скидання", 2: "скидання", 5: "скидань", 21: "скидання", 22: "скидання", 25: "скидань"]
        for (count, noun) in nouns {
            XCTAssertEqual(
                AttentionDropView.rowAccessibilityLabel(reset(.available, count), now: now, locale: L10n.uk),
                "Work, доступно \(count) \(noun) ліміту, термін дії спливає через 2 дні",
                "\(count)"
            )
            XCTAssertEqual(
                AttentionDropView.rowAccessibilityLabel(reset(.expiring, count), now: now, locale: L10n.uk),
                "Work, термін дії скоро спливає: \(count) \(noun) ліміту, термін дії спливає через 2 дні",
                "\(count)"
            )
        }
    }
}
