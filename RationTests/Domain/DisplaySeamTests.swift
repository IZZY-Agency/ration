import XCTest
@testable import Ration

final class DisplaySeamTests: XCTestCase {
    func testLegacyRowInitMapsToAccountOwnerAndSubscriptionSource() {
        let id = UUID()
        let row = AttentionRow(accountID: id, accountLabel: "Work", provider: .claude, subject: .window(.weekly), tier: .warning,
                               usedPercent: 80, spentCents: nil, thresholdPercent: 75, thresholdCents: nil, resetsAt: nil,
                               resetCount: nil, resetCreditIDs: [])
        XCTAssertEqual(row.owner, .account(id))
        XCTAssertEqual(row.source, .subscription(.claude))
        XCTAssertEqual(row.accountID, id)
        XCTAssertEqual(row.provider, .claude)
        XCTAssertFalse(row.isLowerBound)
        XCTAssertNil(row.budgetCents)
    }

    func testAPIRowHasNoAccountIDAndDistinctIdentity() {
        let id = UUID()
        let api = AttentionRow(owner: .apiOrg(id), accountLabel: "IZZY", source: .api(.anthropic), subject: .apiBudget, tier: .warning,
                               usedPercent: 78, spentCents: 46_820, thresholdPercent: 75, thresholdCents: nil, resetsAt: nil,
                               resetCount: nil, resetCreditIDs: [], budgetCents: 60_000, isLowerBound: false)
        XCTAssertNil(api.accountID)
        XCTAssertNil(api.provider)
        XCTAssertNotEqual(api.id, AttentionRow.ID(owner: .account(id), subject: .apiBudget))
    }

    func testGaugeSourcesAndLegacyInit() {
        XCTAssertEqual(DisplaySource.subscription(.claude).gaugeShape, .ring)
        XCTAssertEqual(DisplaySource.api(.openAI).gaugeShape, .roundedSquare)
        XCTAssertEqual(DisplaySource.api(.anthropic).displayName, "Anthropic API")
        XCTAssertEqual(DisplaySource.subscription(.chatGPT).displayName, Provider.chatGPT.displayName)
        let gauge = MenuBarGauge(provider: .claude, label: "Work", fraction: 0.5, windowKind: .weekly, inUse: true)
        XCTAssertEqual(gauge.source, .subscription(.claude))
        XCTAssertEqual(gauge.provider, .claude)
        XCTAssertEqual(gauge.windowKind, .weekly)
        XCTAssertNil(gauge.budget)
    }

    func testSettingsSelectionKeepsAPIOrgOnlyWhileItExists() {
        let id = UUID()
        XCTAssertEqual(SettingsSelection.normalized(.apiOrg(id), accounts: [], apiOrgIDs: [id]), .apiOrg(id))
        XCTAssertEqual(SettingsSelection.normalized(.apiOrg(id), accounts: [], apiOrgIDs: []), .general)
        XCTAssertEqual(SettingsSelection.normalized(.alerts, accounts: []), .alerts)
    }
}
