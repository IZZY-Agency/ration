import XCTest
@testable import Ration

/// The Cursor spend history copy — the line under the card and the History
/// section — in every shipped language.
@MainActor
final class CursorHistoryCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// Closed cycles before September 2026, oldest first.
    private static func closed(_ cents: [Int]) -> [CursorSpendCycle] {
        let calendar = CursorSpendHistoryPlanner.utcCalendar
        let september = date("2026-09-01T00:00:00Z")
        var cycles: [CursorSpendCycle] = []
        for (index, value) in cents.enumerated() {
            let start = calendar.date(byAdding: .month, value: index - cents.count, to: september)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            cycles.append(CursorSpendCycle(periodStart: start, periodEnd: end, spentCents: value, isClosed: true))
        }
        return cycles
    }

    private static func spend(_ cents: Int) -> CursorSpend {
        CursorSpend(spentCents: cents, periodStart: date("2026-09-01T00:00:00Z"), resetsAt: date("2026-09-15T00:00:00Z"), planLabel: "Pro")
    }

    /// Six closed cycles averaging exactly $29.80, and $41.20 this cycle (+38%).
    private let mockup = CursorSpendTrend.card(
        closed: closed([2980, 2410, 3410, 2980, 3550, 2550]),
        current: spend(4120)
    )

    // MARK: Card line

    func testCardLineAboveAverage() {
        XCTAssertEqual(mockup.roundedAverageCents, 2980, "premise")
        XCTAssertEqual(CursorSpendHistoryCopy.cardLine(mockup, locale: L10n.en), "+38% vs your 6-cycle average ($29.80)")
        XCTAssertEqual(
            CursorSpendHistoryCopy.cardLine(mockup, locale: L10n.fr),
            "+38\(nb)% par rapport à votre moyenne sur 6 cycles (29,80\(nb)$)"
        )
        XCTAssertEqual(
            CursorSpendHistoryCopy.cardLine(mockup, locale: L10n.uk),
            "+38% порівняно з вашим середнім за 6 циклів (29,80\(nb)$)"
        )
    }

    func testCardLineBelowAverageUsesATrueMinusAndPluralForms() {
        let two = CursorSpendTrend.card(closed: Self.closed([3000, 2000]), current: Self.spend(2000))
        XCTAssertEqual(CursorSpendHistoryCopy.cardLine(two, locale: L10n.en), "\u{2212}20% vs your 2-cycle average ($25.00)")
        XCTAssertEqual(
            CursorSpendHistoryCopy.cardLine(two, locale: L10n.fr),
            "\u{2212}20\(nb)% par rapport à votre moyenne sur 2 cycles (25,00\(nb)$)"
        )
        XCTAssertEqual(
            CursorSpendHistoryCopy.cardLine(two, locale: L10n.uk),
            "\u{2212}20% порівняно з вашим середнім за 2 цикли (25,00\(nb)$)"
        )
        let even = CursorSpendTrend.card(closed: Self.closed([1000, 1000, 1000, 1000, 1000]), current: Self.spend(1000))
        XCTAssertEqual(CursorSpendHistoryCopy.cardLine(even, locale: L10n.en), "0% vs your 5-cycle average ($10.00)")
        XCTAssertEqual(
            CursorSpendHistoryCopy.cardLine(even, locale: L10n.uk),
            "0% порівняно з вашим середнім за 5 циклів (10,00\(nb)$)"
        )
    }

    func testCardLineForAllZeroCycles() {
        let zero = CursorSpendTrend.card(closed: Self.closed([0, 0, 0]), current: Self.spend(0))
        XCTAssertEqual(CursorSpendHistoryCopy.cardLine(zero, locale: L10n.en), "no usage-based charges in your last 3 cycles")
        XCTAssertEqual(CursorSpendHistoryCopy.cardLine(zero, locale: L10n.fr), "aucuns frais à l’usage sur vos 3 derniers cycles")
        XCTAssertEqual(CursorSpendHistoryCopy.cardLine(zero, locale: L10n.uk), "без оплати за використання за останні 3 цикли")
    }

    func testNoCardLineBelowTwoClosedCycles() {
        let one = CursorSpendTrend.card(closed: Self.closed([500]), current: Self.spend(900))
        XCTAssertNil(CursorSpendHistoryCopy.cardLine(one, locale: L10n.en))
        XCTAssertNil(CursorSpendHistoryCopy.cardLine(CursorSpendTrend.card(closed: [], current: nil), locale: L10n.fr))
    }

    // MARK: History section

    func testSectionHeadings() {
        XCTAssertEqual(CursorSpendHistoryCopy.sectionTitle(label: "Team", locale: L10n.fr), "Cursor · Team")
        XCTAssertEqual(CursorSpendHistoryCopy.sectionSubtitle(locale: L10n.en), "Spend per billing cycle")
        XCTAssertEqual(CursorSpendHistoryCopy.sectionSubtitle(locale: L10n.fr), "Dépenses par cycle de facturation")
        XCTAssertEqual(CursorSpendHistoryCopy.sectionSubtitle(locale: L10n.uk), "Витрати за цикл оплати")
        let en = CursorSpendHistoryCopy.columnTitles(locale: L10n.en)
        XCTAssertEqual([en.cycle, en.spend, en.versusAverage], ["Cycle", "Spend", "vs avg"])
        let fr = CursorSpendHistoryCopy.columnTitles(locale: L10n.fr)
        XCTAssertEqual([fr.cycle, fr.spend, fr.versusAverage], ["Cycle", "Dépenses", "vs moyenne"])
        let uk = CursorSpendHistoryCopy.columnTitles(locale: L10n.uk)
        XCTAssertEqual([uk.cycle, uk.spend, uk.versusAverage], ["Цикл", "Витрати", "від середнього"])
    }

    func testAverageLabel() {
        XCTAssertEqual(CursorSpendHistoryCopy.averageLabel(mockup, locale: L10n.en), "avg $29.80")
        XCTAssertEqual(CursorSpendHistoryCopy.averageLabel(mockup, locale: L10n.fr), "moy. 29,80\(nb)$")
        XCTAssertEqual(CursorSpendHistoryCopy.averageLabel(mockup, locale: L10n.uk), "сер. 29,80\(nb)$")
    }

    /// Cycle dates are UTC boundaries, drawn in UTC in the app language.
    func testRowsAndBarLabels() throws {
        let trend = CursorSpendTrend.history(closed: Self.closed([2410]), current: Self.spend(4120))
        let august = try XCTUnwrap(trend.bars.first)
        let september = try XCTUnwrap(trend.currentBar)

        XCTAssertEqual(CursorSpendHistoryCopy.rowRange(august, locale: L10n.en), "Aug 1 – Sep 1")
        XCTAssertEqual(CursorSpendHistoryCopy.rowRange(september, locale: L10n.en), "Since Sep 1 (so far)")
        XCTAssertEqual(CursorSpendHistoryCopy.barLabel(august, locale: L10n.en), "Aug")
        XCTAssertEqual(CursorSpendHistoryCopy.barLabel(september, locale: L10n.en), "Sep (now)")

        XCTAssertEqual(CursorSpendHistoryCopy.rowRange(august, locale: L10n.fr), "1 août – 1 sept.")
        XCTAssertEqual(CursorSpendHistoryCopy.rowRange(september, locale: L10n.fr), "Depuis le 1 sept. (en cours)")
        XCTAssertEqual(CursorSpendHistoryCopy.barLabel(september, locale: L10n.fr), "sept. (actuel)")

        XCTAssertEqual(CursorSpendHistoryCopy.rowRange(august, locale: L10n.uk), "1 серп. – 1 вер.")
        XCTAssertEqual(CursorSpendHistoryCopy.rowRange(september, locale: L10n.uk), "З 1 вер. (поки що)")
        XCTAssertEqual(CursorSpendHistoryCopy.barLabel(september, locale: L10n.uk), "вер. (зараз)")
    }

    func testRowVersusAverage() {
        let trend = CursorSpendTrend.history(closed: Self.closed([3000, 2000]), current: Self.spend(3750))
        let bars = trend.bars
        XCTAssertEqual(CursorSpendHistoryCopy.rowVersusAverage(bars[0], trend: trend, locale: L10n.en), "+20%")
        XCTAssertEqual(CursorSpendHistoryCopy.rowVersusAverage(bars[1], trend: trend, locale: L10n.fr), "\u{2212}20\(nb)%")
        XCTAssertEqual(CursorSpendHistoryCopy.rowVersusAverage(bars[2], trend: trend, locale: L10n.uk), "+50%")
        let lonely = CursorSpendTrend.history(closed: Self.closed([3000]), current: Self.spend(10))
        XCTAssertEqual(CursorSpendHistoryCopy.rowVersusAverage(lonely.bars[0], trend: lonely, locale: L10n.en), "—")
    }

    func testNotes() {
        XCTAssertEqual(CursorSpendHistoryCopy.noCharges(locale: L10n.en), "No usage-based charges in the cycles shown.")
        XCTAssertEqual(CursorSpendHistoryCopy.noCharges(locale: L10n.fr), "Aucuns frais à l’usage sur les cycles affichés.")
        XCTAssertEqual(CursorSpendHistoryCopy.noCharges(locale: L10n.uk), "Без оплати за використання в показаних циклах.")
        XCTAssertEqual(CursorSpendHistoryCopy.pastCyclesNote(complete: false, locale: L10n.en), "Earlier cycles are read from Cursor in the background.")
        XCTAssertEqual(CursorSpendHistoryCopy.pastCyclesNote(complete: true, locale: L10n.fr), "Aucun cycle précédent avec une utilisation de Cursor.")
        XCTAssertEqual(CursorSpendHistoryCopy.pastCyclesNote(complete: true, locale: L10n.uk), "Немає попередніх циклів із використанням Cursor.")
        XCTAssertEqual(CursorSpendHistoryCopy.noData(locale: L10n.uk), "Витрати ще не зчитано.")
    }

    /// Every Ukrainian plural category of the card line.
    func testUkrainianPluralsOfTheCycleCount() {
        let forms: [Int: String] = [1: "1 цикл", 2: "2 цикли", 5: "5 циклів", 21: "21 цикл", 22: "22 цикли", 25: "25 циклів"]
        for (count, form) in forms {
            let text = LocalizedStringResource.cursorHistoryCardNoCharges(cycles: count).string(in: L10n.uk)
            XCTAssertEqual(text, "без оплати за використання за останні \(form)", "\(count)")
        }
    }
}
