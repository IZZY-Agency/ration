import XCTest
@testable import Ration

/// Spec §10.1: only proven time is attributed, whole minutes only.
final class TokenBurnAttributionTests: XCTestCase {
    private let base: TimeInterval = 1_790_000_040 * 60 / 60 // a whole minute
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: base + minutes * 60) }
    private func minute(_ minutes: Int64) -> Int64 { Int64(base / 60) + minutes }

    private let work = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: "stripe_subscription")
    private let home = SignInIdentity(accountUUID: "acc-H", organizationUUID: "org-H", billingType: "stripe_subscription")

    private func span(_ identity: SignInIdentity, fetched: Double?, _ first: Double, _ last: Double) -> SignInSpan {
        SignInSpan(identity: identity, fetchedAt: fetched.map(at), firstSeen: at(first), lastSeen: at(last))
    }

    // MARK: Proven intervals

    /// A login or a profile refresh at P wrote this identity; only Ration
    /// wrote the file since, and it did not: proven from P to the last reading.
    func testASpanIsProvenFromItsFetchTime() {
        let proven = TokenBurnTimeline.proven(spans: [span(work, fetched: -10, 0, 30)], writes: [])
        XCTAssertEqual(proven, [.init(identity: work, start: at(-10), end: at(30))])
    }

    /// A Ration write after P (a switch writes the remembered copy, whose P is
    /// older): proven only from the write.
    func testARationWriteMovesTheEvidenceStart() {
        let proven = TokenBurnTimeline.proven(spans: [span(work, fetched: -60, 0, 30)], writes: [at(-5), at(40)])
        XCTAssertEqual(proven.first?.start, at(-5))
    }

    func testWithoutAFetchTimeOnlyTheReadingsProve() {
        let proven = TokenBurnTimeline.proven(spans: [span(work, fetched: nil, 0, 30)], writes: [])
        XCTAssertEqual(proven, [.init(identity: work, start: at(0), end: at(30))])
    }

    /// A read at 0, a login at 7 (A→B→A in between), A read
    /// at 10. Minutes 1–6 are proven by nothing.
    func testTheGapBeforeANewFetchTimeIsNotProven() {
        let spans = [span(work, fetched: -30, 0, 0), span(work, fetched: 7, 10, 10)]
        let proven = TokenBurnTimeline.proven(spans: spans, writes: [])
        XCTAssertEqual(proven, [.init(identity: work, start: at(-30), end: at(0)), .init(identity: work, start: at(7), end: at(10))])
        let owners = owners(proven, minutes: [3, 8], resolve: { _ in .account(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!) })
        XCTAssertEqual(owners[3], .notObserved)
        XCTAssertEqual(owners[8], .account(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!))
    }

    /// With the store's split, equal readings around two Ration writes prove
    /// nothing between the first reading and the last write.
    func testWritesBetweenEqualReadingsLeaveThatTimeUnproven() {
        let spans = [span(work, fetched: -30, 0, 0), span(work, fetched: -30, 5, 6)]
        let proven = TokenBurnTimeline.proven(spans: spans, writes: [at(2), at(4)])
        XCTAssertEqual(proven.map(\.start), [at(-30), at(4)])
        XCTAssertEqual(owners(proven, minutes: [2], resolve: { _ in .unassigned })[2], .notObserved)
    }

    /// A start never reaches back over the previous span.
    func testStartsNeverOverlapThePreviousSpan() {
        let spans = [span(work, fetched: nil, 0, 10), span(home, fetched: 5, 12, 20)]
        let proven = TokenBurnTimeline.proven(spans: spans, writes: [])
        XCTAssertEqual(proven.map(\.start), [at(0), at(10)])
    }

    // MARK: Minutes

    private func owners(_ proven: [TokenBurnTimeline.Proven], minutes: [Int64],
                        resolve: (SignInIdentity) -> TokenBurnOwner) -> [Int64: TokenBurnOwner] {
        var result: [Int64: TokenBurnOwner] = [:]
        for offset in minutes {
            result[offset] = TokenBurnAttribution.owner(ofMinute: minute(offset), proven: proven, resolve: resolve)
        }
        return result
    }

    /// A minute goes to an owner only when it lies wholly
    /// inside one proven interval.
    func testOnlyWholeMinutesAreAttributed() {
        let proven = [TokenBurnTimeline.Proven(identity: work, start: at(0.5), end: at(10))]
        let result = owners(proven, minutes: [0, 1, 9, 10], resolve: { _ in .unassigned })
        XCTAssertEqual(result[0], .notObserved, "straddles the start")
        XCTAssertEqual(result[1], .unassigned)
        XCTAssertEqual(result[9], .unassigned, "[9, 10) ends exactly at the end")
        XCTAssertEqual(result[10], .notObserved, "after the last reading")
    }

    func testBeforeTheFirstProvenTime() {
        let proven = [TokenBurnTimeline.Proven(identity: work, start: at(10), end: at(20))]
        XCTAssertEqual(owners(proven, minutes: [3], resolve: { _ in .unassigned })[3], .beforeTracking)
        XCTAssertEqual(owners([], minutes: [3], resolve: { _ in .unassigned })[3], .beforeTracking)
    }

    func testTotalsGroupByOwner() {
        let a = UUID()
        let proven = [TokenBurnTimeline.Proven(identity: work, start: at(0), end: at(10)),
                      TokenBurnTimeline.Proven(identity: home, start: at(20), end: at(30))]
        func total(_ input: Int) -> TokenBurnStore.UsageTotal {
            .init(priceClass: PriceClass(model: "claude-opus-5-5", speed: "standard", geo: "not_available", tier: "standard", longContext: false),
                  tokens: TokenCounts(input: input), webSearches: 0, replies: 1)
        }
        let rows = [(minute(-5), total(1)), (minute(1), total(2)), (minute(2), total(4)), (minute(15), total(8)), (minute(21), total(16))]
        let grouped = TokenBurnAttribution.totals(minutes: rows, proven: proven) { $0 == self.work ? .account(a) : .unassigned }
        XCTAssertEqual(grouped[.account(a)]?.map(\.tokens.input).reduce(0, +), 6)
        XCTAssertEqual(grouped[.beforeTracking]?.map(\.tokens.input).reduce(0, +), 1)
        XCTAssertEqual(grouped[.notObserved]?.map(\.tokens.input).reduce(0, +), 8)
        XCTAssertEqual(grouped[.unassigned]?.map(\.tokens.input).reduce(0, +), 16)
    }

    // MARK: Bindings (spec §10.1)

    private let accountW = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let accountH = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    private func bindings(links: [String: UUID] = [:], organizations: [UUID: String]? = nil,
                          personal: Set<UUID>? = nil, observed: [SignInIdentity]? = nil) -> TokenBurnBindings {
        TokenBurnBindings(links: links,
                          organizations: organizations ?? [accountW: "org-W", accountH: "org-H"],
                          personalPlanAccounts: personal ?? [accountW, accountH],
                          observedIdentities: observed ?? [work, home])
    }

    func testAPersonalPlanOrganizationBinds() {
        XCTAssertEqual(bindings().owner(of: work), .account(accountW))
    }

    func testTheSwitchersLinkWins() {
        XCTAssertEqual(bindings(links: ["acc-W": accountH]).owner(of: work), .account(accountH))
    }

    /// An organization match alone cannot tell Team seats
    /// apart, so it binds only for a detected personal plan.
    func testWithoutAPersonalPlanTheOrganizationDoesNotBind() {
        XCTAssertEqual(bindings(personal: [accountH]).owner(of: work), .unassigned)
    }

    func testTwoAccountsInOneOrganizationDoNotBind() {
        XCTAssertEqual(bindings(organizations: [accountW: "org-W", accountH: "org-W"]).owner(of: work), .unassigned)
    }

    func testAnotherObservedSignInInTheOrganizationBlocksTheMatch() {
        let seat = SignInIdentity(accountUUID: "acc-X", organizationUUID: "org-W", billingType: "stripe_subscription")
        XCTAssertEqual(bindings(observed: [work, seat]).owner(of: work), .unassigned)
        XCTAssertEqual(bindings(links: ["acc-W": accountW], observed: [work, seat]).owner(of: work), .account(accountW),
                       "a link is seat-specific")
    }

    func testAPIBillingAndUnknownBillingNeverReachAnAccount() {
        let api = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: "usage_based")
        let unknown = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: "something_new")
        let absent = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: nil)
        let linked = bindings(links: ["acc-W": accountW])
        XCTAssertEqual(linked.owner(of: api), .apiKey)
        XCTAssertEqual(linked.owner(of: unknown), .unclassified)
        XCTAssertEqual(linked.owner(of: absent), .unclassified)
    }

    /// Claude Code's own subscription set (2.1.285).
    func testEverySubscriptionBillingTypeCounts() {
        for billing in ["stripe_subscription", "stripe_subscription_contracted", "stripe_subscription_enterprise_self_serve",
                        "aws_marketplace", "c4e_consumption_trial", "apple_subscription", "google_play_subscription"] {
            let identity = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: billing)
            XCTAssertEqual(bindings(links: ["acc-W": accountW]).owner(of: identity), .account(accountW), billing)
        }
    }

    /// Spec §5.2: a binding learned later re-attributes past usage — nothing
    /// is stored per owner, so recomputing is enough.
    func testABindingLearnedLaterReattributes() {
        let proven = [TokenBurnTimeline.Proven(identity: work, start: at(0), end: at(10))]
        let before = TokenBurnAttribution.owner(ofMinute: minute(2), proven: proven, resolve: bindings(organizations: [:]).owner(of:))
        let after = TokenBurnAttribution.owner(ofMinute: minute(2), proven: proven, resolve: bindings().owner(of:))
        XCTAssertEqual(before, .unassigned)
        XCTAssertEqual(after, .account(accountW))
    }
}
