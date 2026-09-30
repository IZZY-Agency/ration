import XCTest
@testable import Ration

/// Plan value's words in each shipped language.
final class TokenBurnCopyTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let fr = Locale(identifier: "fr")
    private let uk = Locale(identifier: "uk")

    private func value(cents: Decimal, replies: Int, assumed: Int = 0, kind: TokenBurnPeriod.Kind = .days(30)) -> AccountPlanValue {
        var value = PlanValue()
        value.cents = cents
        value.replies = replies
        value.assumedTokens = assumed
        return AccountPlanValue(period: TokenBurnPeriod(start: .distantPast, end: .distantFuture, kind: kind), value: value,
                                planPriceUSD: 200)
    }

    /// Tracking covers the whole period: the period is named.
    func testTheCardLineInEachLanguage() {
        let exact = value(cents: 30_656, replies: 3_190)
        XCTAssertEqual(TokenBurnCopy.cardLine(exact, trackingSince: .distantPast, locale: en),
                       "$306.56 at API prices · last 30 days")
        XCTAssertEqual(TokenBurnCopy.cardLine(exact, trackingSince: .distantPast, locale: fr),
                       "306,56\u{00A0}$ aux prix de l’API · 30 derniers jours")
        XCTAssertEqual(TokenBurnCopy.cardLine(exact, trackingSince: .distantPast, locale: uk),
                       "306,56\u{00A0}$ за цінами API · останні 30 днів")
    }

    func testAtLeastAndThousands() {
        XCTAssertEqual(TokenBurnCopy.cardLine(value(cents: 1_311_677, replies: 9, assumed: 1), trackingSince: .distantPast,
                                              locale: en),
                       "≥\u{00A0}$13,116.77 at API prices · last 30 days")
    }

    func testNoUseNamesThePeriod() {
        XCTAssertEqual(TokenBurnCopy.cardLine(value(cents: 0, replies: 0, kind: .cycle), trackingSince: .distantPast,
                                              locale: en),
                       "No Claude Code use · this billing cycle")
        XCTAssertEqual(TokenBurnCopy.cardLine(value(cents: 0, replies: 0, kind: .days(7)), trackingSince: .distantPast,
                                              locale: uk),
                       "Claude Code не використовувався · останні 7 днів")
    }

    /// Tracking began inside the period, so the line says since when — never
    /// "no use" or the whole period.
    func testTrackingThatBeganInsideThePeriodSaysSince() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let since = Date(timeIntervalSince1970: 1_790_712_840)       // 2026-09-29 22:14 Paris
        let period = TokenBurnPeriod(start: Date(timeIntervalSince1970: 1_788_213_600), end: .distantFuture, kind: .days(30))
        var some = PlanValue()
        some.cents = 28_703
        some.replies = 3_000
        some.assumedTokens = 1
        let used = AccountPlanValue(period: period, value: some, planPriceUSD: 200)
        let unused = AccountPlanValue(period: period, value: PlanValue(), planPriceUSD: 200)
        XCTAssertEqual(TokenBurnCopy.cardLine(used, trackingSince: since, locale: en, calendar: calendar),
                       "≥\u{00A0}$287.03 at API prices · since Sep 29 at 10:14\u{202F}PM")
        XCTAssertEqual(TokenBurnCopy.cardLine(unused, trackingSince: since, locale: en, calendar: calendar),
                       "No Claude Code use since Sep 29 at 10:14\u{202F}PM")
        XCTAssertEqual(TokenBurnCopy.cardLine(unused, trackingSince: nil, locale: en), "Plan value: not tracked yet")
    }

    func testModelNames() {
        XCTAssertEqual(TokenBurnCopy.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(TokenBurnCopy.modelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(TokenBurnCopy.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(TokenBurnCopy.modelName("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(TokenBurnCopy.modelName("<synthetic>"), "<synthetic>")
        XCTAssertEqual(TokenBurnCopy.modelName("claude-3-opus"), "claude-3-opus", "another shape is shown as is")
    }

    func testRatioAndTokens() {
        XCTAssertEqual(TokenBurnCopy.ratio(Decimal(string: "1.5328")!, locale: en), "1.53×")
        XCTAssertEqual(TokenBurnCopy.ratio(Decimal(string: "1.5328")!, locale: fr), "1,53×")
        XCTAssertEqual(TokenBurnCopy.tokens(783_817_393, locale: en), "783.8M")
    }
}
