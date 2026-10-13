import XCTest
@testable import Ration

/// The Claude section's footer: each account's plan value, gathered from
/// the rows into one line when the accounts share a span.
final class TokenBurnSectionFooterTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let fr = Locale(identifier: "fr")
    private let uk = Locale(identifier: "uk")
    private let nb = "\u{00A0}"
    private let since = Date(timeIntervalSince1970: 1_790_712_840)       // 2026-09-29 22:14 Paris
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    /// A 30-day period that began before tracking did: "since <moment>".
    private let partial = TokenBurnPeriod(start: Date(timeIntervalSince1970: 1_788_213_600), end: .distantFuture, kind: .days(30))
    /// A billing cycle that began after tracking did: the period is named.
    private let wholeCycle = TokenBurnPeriod(start: Date(timeIntervalSince1970: 1_790_900_000), end: .distantFuture, kind: .cycle)

    private func value(_ cents: Decimal, replies: Int = 10, atLeast: Bool = true, period: TokenBurnPeriod? = nil) -> AccountPlanValue {
        var value = PlanValue()
        value.cents = cents
        value.replies = replies
        value.assumedTokens = atLeast ? 1 : 0
        return AccountPlanValue(period: period ?? partial, value: value, planPriceUSD: 200)
    }

    private func lines(_ entries: [TokenBurnSectionFooter.Entry], trackingSince: Date?, grantLost: Bool = false,
                       locale: Locale) -> [String] {
        TokenBurnSectionFooter.lines(entries, trackingSince: trackingSince, grantLost: grantLost,
                                     locale: locale, calendar: calendar)
    }

    private var twoAccounts: [TokenBurnSectionFooter.Entry] {
        [
            .init(label: "Work", value: value(529_822)),
            .init(label: "Personal", value: value(552_501)),
        ]
    }

    /// One shared span: one line, the span said once at the end.
    func testSharedSpanIsOneLine() {
        XCTAssertEqual(
            lines(twoAccounts, trackingSince: since, locale: en),
            ["Work ≥\(nb)$5,298.22 · Personal ≥\(nb)$5,525.01 · since Sep 29 at 10:14\u{202F}PM"]
        )
    }

    func testSharedSpanInEachLanguage() {
        for locale in [fr, uk] {
            let moment = TokenBurnCopy.moment(since, locale: locale, calendar: calendar)
            let work = TokenBurnCopy.amount(cents: 529_822, atLeast: true, locale: locale)
            let personal = TokenBurnCopy.amount(cents: 552_501, atLeast: true, locale: locale)
            let since = locale == fr ? "depuis le \(moment)" : "з \(moment)"
            XCTAssertEqual(lines(twoAccounts, trackingSince: self.since, locale: locale),
                           ["Work \(work) · Personal \(personal) · \(since)"], locale.identifier)
        }
    }

    /// Spans that differ (a billing cycle that began after tracking): one
    /// segment per account, each with its own span.
    func testDifferentSpansGetOneSegmentEach() {
        let entries: [TokenBurnSectionFooter.Entry] = [
            .init(label: "Work", value: value(529_822)),
            .init(label: "Client", value: value(1_250, atLeast: false, period: wholeCycle)),
        ]
        XCTAssertEqual(
            lines(entries, trackingSince: since, locale: en),
            [
                "Work ≥\(nb)$5,298.22 · since Sep 29 at 10:14\u{202F}PM",
                "Client $12.50 · this billing cycle",
            ]
        )
    }

    /// No use in the span: said per account, never a "$0.00".
    func testNoUseInEachLanguage() {
        let entries: [TokenBurnSectionFooter.Entry] = [
            .init(label: "Work", value: value(529_822)),
            .init(label: "Personal", value: value(0, replies: 0, atLeast: false)),
        ]
        let moment = TokenBurnCopy.moment(since, locale: en, calendar: calendar)
        XCTAssertEqual(lines(entries, trackingSince: since, locale: en),
                       ["Work ≥\(nb)$5,298.22 · Personal: no use · since \(moment)"])
        XCTAssertTrue(lines(entries, trackingSince: since, locale: fr)[0].contains("Personal\u{202F}: aucune utilisation"))
        XCTAssertTrue(lines(entries, trackingSince: since, locale: uk)[0].contains("Personal: без використання"))
    }

    /// Accounts without a figure stay out; nothing to say, no footer.
    func testAccountsWithoutAFigureAreLeftOut() {
        let entries: [TokenBurnSectionFooter.Entry] = [
            .init(label: "Work", value: nil),
            .init(label: "Personal", value: value(552_501)),
        ]
        let moment = TokenBurnCopy.moment(since, locale: en, calendar: calendar)
        XCTAssertEqual(lines(entries, trackingSince: since, locale: en), ["Personal ≥\(nb)$5,525.01 · since \(moment)"])
        XCTAssertEqual(lines([.init(label: "Work", value: nil)], trackingSince: since, locale: en), [])
        XCTAssertEqual(lines([], trackingSince: since, locale: en), [])
    }

    /// The cards' own one-liners, said once for the section.
    func testNotTrackedAndGrantLostAreOneLine() {
        XCTAssertEqual(lines(twoAccounts, trackingSince: nil, locale: en), ["Plan value: not tracked yet"])
        XCTAssertEqual(lines(twoAccounts, trackingSince: since, grantLost: true, locale: en),
                       ["Plan value paused · grant access again in Settings"])
        XCTAssertEqual(lines([], trackingSince: since, grantLost: true, locale: en), [],
                       "no Claude row, no footer")
    }
}
