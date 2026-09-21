import XCTest
@testable import Ration

final class AccountGroupingTests: XCTestCase {
    private func pres(_ order: Int, _ provider: Provider) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(
            id: id, provider: provider, label: "L\(order)",
            webProfileID: UUID(), displayOrder: order,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        return AccountPresentation(account: account, snapshot: nil, state: .current)
    }

    func testGroupsFollowProviderAllCasesOrder() {
        let gpt = pres(0, .chatGPT)
        let claude = pres(1, .claude)
        let cursor = pres(2, .cursor)
        let groups = AccountGrouping.grouped([gpt, cursor, claude], orderingPinByProvider: [:])
        XCTAssertEqual(groups.map(\.provider), Provider.allCases)
    }

    func testProvidersWithNoAccountsAreOmitted() {
        let groups = AccountGrouping.grouped([pres(0, .claude)], orderingPinByProvider: [:])
        XCTAssertEqual(groups.map(\.provider), [.claude])
    }

    func testPinnedAccountMovesToFrontOfItsGroup() {
        let a = pres(0, .claude), b = pres(1, .claude), c = pres(2, .claude)
        let groups = AccountGrouping.grouped([a, b, c], orderingPinByProvider: [.claude: c.id])
        XCTAssertEqual(groups[0].presentations.map(\.id), [c.id, a.id, b.id])
    }

    func testNonPinnedAccountsKeepIncomingRelativeOrder() {
        let a = pres(0, .claude), b = pres(1, .claude), c = pres(2, .claude)
        let groups = AccountGrouping.grouped([b, a, c], orderingPinByProvider: [.claude: c.id])
        XCTAssertEqual(groups[0].presentations.map(\.id), [c.id, b.id, a.id])
    }

    func testGroupWithNoPinIsUntouched() {
        let a = pres(0, .claude), b = pres(1, .claude)
        let groups = AccountGrouping.grouped([a, b], orderingPinByProvider: [:])
        XCTAssertEqual(groups[0].presentations.map(\.id), [a.id, b.id])
    }

    func testStalePinMatchingNoAccountDegradesToNaturalOrder() {
        let a = pres(0, .claude), b = pres(1, .claude)
        let groups = AccountGrouping.grouped([a, b], orderingPinByProvider: [.claude: UUID()])
        XCTAssertEqual(groups[0].presentations.map(\.id), [a.id, b.id])
    }

    func testPinBelongingToAnotherProviderMovesNothing() {
        let claude = pres(0, .claude)
        let gpt = pres(1, .chatGPT)
        let groups = AccountGrouping.grouped(
            [claude, gpt], orderingPinByProvider: [.claude: gpt.id]
        )
        XCTAssertEqual(groups.first { $0.provider == .claude }?.presentations.map(\.id), [claude.id])
        XCTAssertEqual(groups.first { $0.provider == .chatGPT }?.presentations.map(\.id), [gpt.id])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(AccountGrouping.grouped([], orderingPinByProvider: [:]).isEmpty)
    }
}
