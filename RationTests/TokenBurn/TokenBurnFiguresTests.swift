import XCTest
@testable import Ration

/// The figures the card, Settings and History show for the chosen period.
/// Pure.
final class TokenBurnFiguresTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")!
        return formatter.date(from: text)!
    }

    private let now = { () -> Date in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")!
        return formatter.date(from: "2026-09-30T14:00:00")!
    }()
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func account(_ id: UUID, renewalDay: Int? = nil, plan: PlanTier? = .claudeMax20x) -> TokenBurnAccount {
        TokenBurnAccount(id: id, label: "L", organizationID: nil, personalPlanDetected: true, plan: plan, renewalDay: renewalDay)
    }

    private func row(_ at: Date, _ owner: TokenBurnOwner, model: String = "claude-opus-5-5", input: Int = 1_000_000,
                     output: Int = 0) -> TokenBurnFigures.Row {
        let priceClass = PriceClass(model: model, speed: "standard", geo: "not_available", tier: "standard", longContext: false)
        return TokenBurnFigures.Row(minute: Int64(at.timeIntervalSince1970 / 60), owner: owner,
                                    total: .init(priceClass: priceClass, tokens: TokenCounts(input: input, output: output),
                                                 webSearches: 0, replies: 1))
    }

    private func compute(_ rows: [TokenBurnFigures.Row], accounts: [TokenBurnAccount]? = nil,
                         choice: TokenBurnPeriod.Choice = .last30Days,
                         proven: [TokenBurnTimeline.Proven] = []) -> TokenBurnFigures.Result {
        TokenBurnFigures.compute(rows: rows, accounts: accounts ?? [account(a)], choice: choice, proven: proven,
                                 resolve: { _ in .account(self.a) }, now: now, calendar: calendar)
    }

    func testAnAccountsFiguresForTheChosenPeriod() throws {
        let result = compute([
            row(date("2026-09-29T23:00:00"), .account(a), model: "claude-opus-5-5"),
            row(date("2026-09-10T10:00:00"), .account(a), model: "claude-sonnet-5-5", input: 2_000_000),
            row(date("2026-08-20T10:00:00"), .account(a)),                       // 41 days back: the period before
        ])
        let values = try XCTUnwrap(result.values[a])
        XCTAssertEqual(values.current.period.kind, .days(30))
        XCTAssertEqual(values.current.value.replies, 2)
        XCTAssertEqual(values.previous.count, 3)
        XCTAssertEqual(values.previous[0].value.replies, 1)
        XCTAssertEqual(values.byModel.map(\.model), ["claude-opus-5-5", "claude-sonnet-5-5"], "largest value first")
        XCTAssertEqual(values.tokens.input, 3_000_000)
    }

    func testTheFirstProvenTimeOfTheAccount() {
        let mine = SignInIdentity(accountUUID: "acc-A", organizationUUID: "o", billingType: "stripe_subscription")
        let theirs = SignInIdentity(accountUUID: "acc-X", organizationUUID: "o", billingType: "stripe_subscription")
        let proven = [
            TokenBurnTimeline.Proven(identity: theirs, start: date("2026-09-20T08:00:00"), end: date("2026-09-21T08:00:00")),
            TokenBurnTimeline.Proven(identity: mine, start: date("2026-09-29T22:14:00"), end: now),
        ]
        let result = TokenBurnFigures.compute(rows: [], accounts: [account(a)], choice: .last30Days, proven: proven,
                                              resolve: { $0 == mine ? .account(self.a) : .unassigned }, now: now,
                                              calendar: calendar)
        XCTAssertEqual(result.values[a]?.since, date("2026-09-29T22:14:00"))
    }

    func testDaysCoverThePeriodUpToToday() {
        let result = compute([
            row(date("2026-09-28T10:00:00"), .account(a)),
            row(date("2026-09-28T11:00:00"), .beforeTracking),
        ], choice: .last7Days)
        XCTAssertEqual(result.days.map(\.day), (0..<7).map { calendar.date(byAdding: .day, value: $0, to: date("2026-09-24T00:00:00"))! })
        let day = result.days[4]
        XCTAssertEqual(day.day, date("2026-09-28T00:00:00"))
        XCTAssertEqual(day.values[.account(a)]?.cents, 400, "1M input tokens of Opus 5.5 at $4 per million")
        XCTAssertEqual(day.values[.beforeTracking]?.cents, 400)
        XCTAssertNil(result.days[0].values[.account(a)])
    }

    func testPooledLinesFollowThePeriod() {
        let rows = [row(date("2026-09-10T10:00:00"), .beforeTracking)]
        XCTAssertEqual(compute(rows, choice: .last30Days).pooled[.beforeTracking]?.replies, 1)
        XCTAssertNil(compute(rows, choice: .last7Days).pooled[.beforeTracking])
    }

    /// A link to an account Ration no longer has reads as unassigned.
    func testAnAccountRationNoLongerHasIsUnassigned() {
        let result = compute([row(date("2026-09-28T10:00:00"), .account(b))])
        XCTAssertEqual(result.pooled[.unassigned]?.replies, 1)
        XCTAssertEqual(result.days.last(where: { $0.day == date("2026-09-28T00:00:00") })?.values[.unassigned]?.cents, 400)
        XCTAssertNil(result.values[b])
    }

    /// Accounts renew on different days: History starts at the earliest
    /// current cycle and stops tonight.
    func testBillingCycleDaysStartAtTheEarliestCycle() {
        let result = compute([], accounts: [account(a, renewalDay: 15), account(b, renewalDay: nil)], choice: .billingCycle)
        XCTAssertEqual(result.values[a]?.current.period.kind, .cycle)
        XCTAssertEqual(result.values[b]?.current.period.kind, .month)
        XCTAssertEqual(result.days.first?.day, date("2026-09-01T00:00:00"))
        XCTAssertEqual(result.days.last?.day, date("2026-09-30T00:00:00"))
    }

    /// All use for the whole period, whoever's it was;
    /// per account only from when Ration started tracking.
    func testTheTotalCoversEveryOwnerAndTrackingStartsAtTheFirstProof() {
        let identity = SignInIdentity(accountUUID: "acc-A", organizationUUID: "o", billingType: "stripe_subscription")
        let start = date("2026-09-29T22:14:00")
        let result = TokenBurnFigures.compute(
            rows: [row(date("2026-09-10T10:00:00"), .beforeTracking), row(date("2026-09-30T10:00:00"), .account(a)),
                   row(date("2026-09-30T11:00:00"), .notObserved)],
            accounts: [account(a)], choice: .last30Days,
            proven: [TokenBurnTimeline.Proven(identity: identity, start: start, end: now)],
            resolve: { _ in .account(self.a) }, now: now, calendar: calendar)
        XCTAssertEqual(result.total.replies, 3)
        XCTAssertEqual(result.total.cents, 1_200)
        XCTAssertEqual(result.trackingSince, start)
        XCTAssertNil(compute([]).trackingSince, "nothing proven yet")
    }

    func testTheEarliestMinuteNeeded() {
        let earliest = TokenBurnFigures.earliest(accounts: [account(a)], choice: .last30Days, now: now, calendar: calendar)
        XCTAssertEqual(earliest, date("2026-06-03T00:00:00"), "this period and the three before")
    }
}
