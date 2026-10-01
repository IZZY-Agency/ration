import XCTest
@testable import Ration

/// The one Settings order also orders the popover and the
/// menu-bar gauges. Without a saved order, both look exactly as before.
final class PopoverRunsTests: XCTestCase {
    private typealias Item = SidebarAccountOrder.Item

    private func pres(_ order: Int, _ provider: Provider) -> AccountPresentation {
        let account = AccountRecord(id: UUID(), provider: provider, label: "L\(order)", webProfileID: UUID(),
                                    displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
        return AccountPresentation(account: account, snapshot: nil, state: .current)
    }

    func testWithoutASavedOrderTheLayoutIsUnchanged() {
        let gpt = pres(0, .chatGPT), claude = pres(1, .claude), api = UUID()
        let runs = PopoverRuns.make(order: nil, presentations: [gpt, claude], apiIDs: [api], orderingPinByProvider: [:])
        XCTAssertEqual(runs.map(\.kind), [.provider(.claude), .provider(.chatGPT), .api])
        XCTAssertEqual(PopoverRuns.cardIDs(runs), [claude.id, gpt.id, api])
    }

    /// A mixed order: Work API, AI, Claude, Personal,
    /// ChatGPT 20x, Cursor, ChatGPT 5x, OpenAI — a header at each change.
    func testSavedOrderIsFollowedExactlyWithAHeaderAtEachChange() {
        let ai = pres(0, .claude), claude = pres(1, .claude), personal = pres(2, .claude)
        let gpt20 = pres(3, .chatGPT), cursor = pres(4, .cursor), gpt5 = pres(5, .chatGPT)
        let workAPI = UUID(), openAI = UUID()
        let order: [Item] = [.api(workAPI), .subscription(ai.id), .subscription(claude.id), .subscription(personal.id),
                             .subscription(gpt20.id), .subscription(cursor.id), .subscription(gpt5.id), .api(openAI)]
        let runs = PopoverRuns.make(order: order, presentations: [ai, claude, personal, gpt20, gpt5, cursor],
                                    apiIDs: [workAPI, openAI], orderingPinByProvider: [:])
        XCTAssertEqual(runs.map(\.kind), [.api, .provider(.claude), .provider(.chatGPT), .provider(.cursor), .provider(.chatGPT), .api])
        XCTAssertEqual(PopoverRuns.cardIDs(runs), [workAPI, ai.id, claude.id, personal.id, gpt20.id, cursor.id, gpt5.id, openAI])
    }

    /// The in-use pin still lifts an account to the top of ITS run only.
    func testInUsePinStaysWithinItsRun() {
        let a = pres(0, .claude), b = pres(1, .claude), api = UUID()
        let order: [Item] = [.subscription(a.id), .subscription(b.id), .api(api)]
        let runs = PopoverRuns.make(order: order, presentations: [a, b], apiIDs: [api], orderingPinByProvider: [.claude: b.id])
        XCTAssertEqual(PopoverRuns.cardIDs(runs), [b.id, a.id, api])
    }

    /// TypeSafe is an API: its card is in the API section, with no
    /// "TypeSafe" section of its own — even with no API org at all.
    func testATypeSafeCardSitsInTheAPISection() {
        let claude = pres(0, .claude), typeSafe = pres(1, .typeSafe), api = UUID()
        let runs = PopoverRuns.make(order: nil, presentations: [claude, typeSafe], apiIDs: [api], orderingPinByProvider: [:])
        XCTAssertEqual(runs.map(\.kind), [.provider(.claude), .api])
        XCTAssertEqual(PopoverRuns.cardIDs(runs), [claude.id, api, typeSafe.id])
        XCTAssertEqual(runs.last?.apiIDs, [api], "only orgs are API spend presentations")

        let alone = PopoverRuns.make(order: nil, presentations: [typeSafe], apiIDs: [], orderingPinByProvider: [:])
        XCTAssertEqual(alone.map(\.kind), [.api])
        XCTAssertEqual(alone.first?.apiEntries, [.account(typeSafe)])
    }

    /// With a saved order, a TypeSafe item joins the API run it sits in.
    func testASavedOrderPutsTypeSafeIntoTheAdjacentAPIRun() {
        let claude = pres(0, .claude), typeSafe = pres(1, .typeSafe), api = UUID()
        let order: [Item] = [.subscription(claude.id), .api(api), .subscription(typeSafe.id)]
        let runs = PopoverRuns.make(order: order, presentations: [claude, typeSafe], apiIDs: [api], orderingPinByProvider: [:])
        XCTAssertEqual(runs.map(\.kind), [.provider(.claude), .api])
        XCTAssertEqual(runs.last?.apiEntries, [.org(api), .account(typeSafe)])

        let first: [Item] = [.subscription(typeSafe.id), .subscription(claude.id), .api(api)]
        let split = PopoverRuns.make(order: first, presentations: [claude, typeSafe], apiIDs: [api], orderingPinByProvider: [:])
        XCTAssertEqual(split.map(\.kind), [.api, .provider(.claude), .api], "a header wherever the kind changes")
    }

    func testGaugesFollowTheSavedOrder() {
        let s1 = UUID(), s2 = UUID(), a1 = UUID()
        let gauge = { (label: String) in MenuBarGauge(provider: .claude, label: label, fraction: 0.5, windowKind: .fiveHour, inUse: false) }
        let entries = [(id: s1, value: gauge("s1")), (id: s2, value: gauge("s2")), (id: a1, value: gauge("a1"))]
        let ordered = SidebarAccountOrder.ordered(entries, by: [.api(a1), .subscription(s2), .subscription(s1)])
        XCTAssertEqual(ordered.map(\.label), ["a1", "s2", "s1"])
    }

    /// `gauges` (provider-grouped, as before) is built from the per-account
    /// entries the ordering uses — the same gauges either way.
    func testAccountGaugesCarryTheirAccountAndRegroupAsBefore() {
        let gpt = AccountRecord(id: UUID(), provider: .chatGPT, label: "G", webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast)
        let claude = AccountRecord(id: UUID(), provider: .claude, label: "C", webProfileID: UUID(), displayOrder: 1, createdAt: .distantPast)
        let snapshot = { (id: UUID) in
            UsageSnapshot(accountID: id, fetchedAt: Date(timeIntervalSince1970: 1_000),
                          fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.6, resetsAt: nil), weekly: nil, modelWeekly: nil)
        }
        let args = (accounts: [gpt, claude], now: Date(timeIntervalSince1970: 1_000))
        let entries = MenuBarGaugeState.accountGauges(accounts: args.accounts, activeUsage: [:], snapshots: { snapshot($0) },
                                                      windowKind: { _ in .fiveHour }, displaysRemaining: true, now: args.now)
        XCTAssertEqual(entries.map(\.id), [gpt.id, claude.id], "in account order, each with its account")
        let grouped = MenuBarGaugeState.gauges(accounts: args.accounts, activeUsage: [:], snapshots: { snapshot($0) },
                                               windowKind: { _ in .fiveHour }, displaysRemaining: true, now: args.now)
        XCTAssertEqual(grouped.map(\.label), ["C", "G"], "still Claude first when no order is saved")
    }
}
