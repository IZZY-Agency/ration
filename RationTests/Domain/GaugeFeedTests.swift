import XCTest
@testable import Ration

/// One capture, two projections: the menu bar's flat order must not change,
/// and the ring bar gets fixed provider groups.
final class GaugeFeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private func account(_ provider: Provider, _ order: Int, label: String? = nil) -> AccountRecord {
        AccountRecord(id: UUID(), provider: provider, label: label ?? "\(provider.rawValue)-\(order)",
                      webProfileID: UUID(), displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func snapshot(_ account: AccountRecord, weekly: Double) -> UsageSnapshot {
        UsageSnapshot(accountID: account.id, fetchedAt: now, fiveHour: nil,
                      weekly: UsageWindow(kind: .weekly, remainingFraction: weekly, resetsAt: nil), modelWeekly: nil)
    }

    private func apiGauge(_ vendor: APIVendor, _ label: String) -> (id: UUID, value: MenuBarGauge) {
        (UUID(), MenuBarGauge(source: .api(vendor), label: label, fraction: 0.9, windowKind: nil, inUse: false,
                              budget: BudgetGaugeFacts(exactPercent: 10, isLowerBound: false)))
    }

    private func input(
        _ accounts: [AccountRecord],
        _ snapshots: [UsageSnapshot],
        api: [(id: UUID, value: MenuBarGauge)] = [],
        active: [UUID: ActiveUsage] = [:]
    ) -> GaugeFeedInput {
        GaugeFeedInput(accounts: accounts, snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.accountID, $0) }),
                       activeUsage: active, windowKinds: [.claude: .weekly, .chatGPT: .weekly], displaysRemaining: true,
                       apiGauges: api, apiPresentations: [:], apiThresholds: .default, now: now)
    }

    func testEntriesCarryIdentityAndSnapshot() {
        let a = account(.claude, 0)
        let entries = GaugeFeed.entries(input([a], [snapshot(a, weekly: 0.89)]))
        XCTAssertEqual(entries.map(\.id), [a.id])
        XCTAssertEqual(entries[0].gauge.fraction, 0.89, accuracy: 0.0001)
        guard case .subscription(let snap) = entries[0].details else { return XCTFail("expected subscription") }
        XCTAssertEqual(snap.accountID, a.id)
    }

    func testMenuBarOrderMatchesTodayWithoutSavedOrder() {
        let claude = account(.claude, 0), gpt = account(.chatGPT, 1)
        let anthropic = apiGauge(.anthropic, "Studio API")
        let entries = GaugeFeed.entries(input([gpt, claude], [snapshot(claude, weekly: 0.5), snapshot(gpt, weekly: 0.5)], api: [anthropic]))
        let expected = MenuBarGaugeState.grouped(
            entries.filter { !$0.details.isAPIOrg }.map(\.gauge), apiOrgs: [anthropic.value])
        XCTAssertEqual(GaugeFeed.menuBarOrder(entries, savedOrder: nil), expected)
        XCTAssertEqual(expected.map(\.label), ["claude-0", "chatgpt-1", "Studio API"])
    }

    func testMenuBarOrderFollowsSavedInterleaving() {
        let claude = account(.claude, 0)
        let anthropic = apiGauge(.anthropic, "Studio API")
        let entries = GaugeFeed.entries(input([claude], [snapshot(claude, weekly: 0.5)], api: [anthropic]))
        let saved: [SidebarAccountOrder.Item] = [.api(anthropic.id), .subscription(claude.id)]
        XCTAssertEqual(GaugeFeed.menuBarOrder(entries, savedOrder: saved).map(\.label), ["Studio API", "claude-0"])
    }

    func testRingBarGroupsUseFixedOrderAndKeepKindOrderInside() {
        let c1 = account(.claude, 0, label: "Client"), c2 = account(.claude, 1, label: "Personal")
        let g1 = account(.chatGPT, 2, label: "ChatGPT 20x")
        let studio = apiGauge(.anthropic, "Studio API"), openai = apiGauge(.openAI, "Platform"), research = apiGauge(.anthropic, "Research")
        let entries = GaugeFeed.entries(input([g1, c1, c2], [snapshot(c1, weekly: 0.89), snapshot(c2, weekly: 0.3), snapshot(g1, weekly: 0.5)],
                                              api: [studio, openai, research]))
        let groups = GaugeFeed.ringBarGroups(entries, savedOrder: nil)
        XCTAssertEqual(groups.map(\.source), [.subscription(.claude), .subscription(.chatGPT), .api(.anthropic), .api(.openAI)])
        XCTAssertEqual(groups[0].entries.map(\.gauge.label), ["Client", "Personal"])
        XCTAssertEqual(groups[2].entries.map(\.gauge.label), ["Studio API", "Research"])
        XCTAssertFalse(groups[1].isAPI)
        XCTAssertTrue(groups[2].isAPI)
    }

    func testRingBarGroupsFollowTheSavedOrderInsideAGroup() {
        let c1 = account(.claude, 0, label: "Client"), c2 = account(.claude, 1, label: "Personal")
        let entries = GaugeFeed.entries(input([c1, c2], [snapshot(c1, weekly: 0.5), snapshot(c2, weekly: 0.5)]))
        let saved: [SidebarAccountOrder.Item] = [.subscription(c2.id), .subscription(c1.id)]
        XCTAssertEqual(GaugeFeed.ringBarGroups(entries, savedOrder: saved).first?.entries.map(\.gauge.label), ["Personal", "Client"])
        XCTAssertEqual(GaugeFeed.ringBarGroups(entries, savedOrder: nil).first?.entries.map(\.gauge.label), ["Client", "Personal"])
    }

    func testInUseOffRemovesDotsButKeepsGauges() {
        let a = account(.chatGPT, 0)
        let active = [a.id: ActiveUsage(lastUsedAt: now.addingTimeInterval(-30), source: .weekly)]
        XCTAssertTrue(GaugeFeed.entries(input([a], [snapshot(a, weekly: 0.5)], active: active))[0].gauge.inUse)
        let off = GaugeFeed.entries(input([a], [snapshot(a, weekly: 0.5)], active: [:]))
        XCTAssertEqual(off.count, 1)
        XCTAssertFalse(off[0].gauge.inUse)
    }

    func testAPIEntryKeepsExactBudgetFacts() {
        let over = (id: UUID(), value: MenuBarGauge(source: .api(.openAI), label: "Over", fraction: 0, windowKind: nil, inUse: false,
                                                    budget: BudgetGaugeFacts(exactPercent: 137.5, isLowerBound: true)))
        let entries = GaugeFeed.entries(input([], [], api: [over]))
        XCTAssertEqual(entries[0].gauge.budget?.exactPercent, 137.5)
        XCTAssertEqual(entries[0].gauge.budget?.isLowerBound, true)
        XCTAssertTrue(entries[0].details.isAPIOrg)
    }

    func testVisibleFiltersOneSurfaceOnly() {
        let a = account(.claude, 0), b = account(.claude, 1)
        let entries = GaugeFeed.entries(input([a, b], [snapshot(a, weekly: 0.5), snapshot(b, weekly: 0.5)]))
        let shows: (GaugeSurface, UUID) -> Bool = { surface, id in !(surface == .menuBar && id == a.id) }
        XCTAssertEqual(GaugeFeed.visible(entries, on: .menuBar, shows: shows).map(\.id), [b.id])
        XCTAssertEqual(GaugeFeed.visible(entries, on: .ringBar, shows: shows).map(\.id), [a.id, b.id])
    }

    func testAllHiddenLeavesSurfaceEmpty() {
        let a = account(.chatGPT, 0)
        let entries = GaugeFeed.entries(input([a], [snapshot(a, weekly: 0.5)]))
        XCTAssertTrue(GaugeFeed.visible(entries, on: .ringBar, shows: { _, _ in false }).isEmpty)
        XCTAssertTrue(GaugeFeed.ringBarGroups(GaugeFeed.visible(entries, on: .ringBar, shows: { _, _ in false }), savedOrder: nil).isEmpty)
    }

    func testNoAccountsNoGroups() {
        XCTAssertTrue(GaugeFeed.ringBarGroups(GaugeFeed.entries(input([], [])), savedOrder: nil).isEmpty)
    }
}
