import XCTest
@testable import Ration

/// Settings › Display › Rings: a row per account, grouped like the ring bar,
/// with a reason instead of checkboxes where no gauge can exist.
final class RingsGridModelTests: XCTestCase {
    private func account(_ provider: Provider, _ label: String, order: Int, paused: Bool = false) -> AccountRecord {
        var record = AccountRecord(id: UUID(), provider: provider, label: label, webProfileID: UUID(),
                                   displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
        record.isPaused = paused
        return record
    }

    private func org(_ vendor: APIVendor, _ label: String, order: Int, budget: Int? = 20_000, paused: Bool = false) -> APIOrgRecord {
        APIOrgRecord(id: UUID(), vendor: vendor, vendorOrgID: nil, label: label, monthlyBudgetCents: budget,
                     isPaused: paused, displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testAccountsGroupLikeTheRingBar() {
        let ai = account(.claude, "Client", order: 0), sb = account(.claude, "Personal", order: 1)
        let g20 = account(.chatGPT, "ChatGPT 20x", order: 2), g5 = account(.chatGPT, "ChatGPT 5x", order: 3)
        let cursor = account(.cursor, "Cursor", order: 4)
        let studio = org(.anthropic, "Studio API", order: 0), openai = org(.openAI, "Platform", order: 1)
        let agency = org(.anthropic, "Agency", order: 2), research = org(.anthropic, "Research", order: 3)
        let groups = RingsGridModel.groups(accounts: [ai, sb, g20, g5, cursor], apiOrgs: [research, studio, openai, agency],
                                           shows: { _, _ in true })
        XCTAssertEqual(groups.map(\.source), [.subscription(.claude), .subscription(.chatGPT), .subscription(.cursor),
                                              .api(.anthropic), .api(.openAI)])
        XCTAssertEqual(groups[0].rows.map(\.label), ["Client", "Personal"])
        XCTAssertEqual(groups[3].rows.map(\.label), ["Studio API", "Agency", "Research"], "orgs by display order")
        XCTAssertEqual(groups[2].rows.first?.state, .noLimit)
        XCTAssertEqual(groups[0].rows.first?.state, .available(menuBar: true, ringBar: true))
    }

    func testReasonsReplaceCheckboxes() {
        let paused = account(.claude, "Old", order: 0, paused: true)
        let noBudget = org(.openAI, "Lab", order: 0, budget: nil)
        let groups = RingsGridModel.groups(accounts: [paused], apiOrgs: [noBudget], shows: { _, _ in true })
        XCTAssertEqual(groups.flatMap(\.rows).map(\.state), [.paused, .noBudget])
    }

    func testChoicesAreReflected() {
        let a = account(.claude, "Client", order: 0)
        let groups = RingsGridModel.groups(accounts: [a], apiOrgs: [], shows: { surface, _ in surface == .ringBar })
        XCTAssertEqual(groups.first?.rows.first?.state, .available(menuBar: false, ringBar: true))
    }

    func testUnknownIDsAreIgnored() {
        let a = account(.claude, "Client", order: 0)
        let stale = UUID()
        let groups = RingsGridModel.groups(accounts: [a], apiOrgs: [], shows: { _, id in id != stale })
        XCTAssertEqual(groups.flatMap(\.rows).map(\.id), [a.id])
        XCTAssertEqual(groups.first?.rows.first?.state, .available(menuBar: true, ringBar: true))
    }

    func testNoAccountsNoGroups() {
        XCTAssertTrue(RingsGridModel.groups(accounts: [], apiOrgs: [], shows: { _, _ in true }).isEmpty)
    }
}
