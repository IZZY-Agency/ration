import XCTest
@testable import Ration

final class SettingsSelectionTests: XCTestCase {
    private func account(order: Int) -> AccountRecord {
        AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Acct \(order)",
            webProfileID: UUID(),
            displayOrder: order,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testDefaultSelectionIsFirstAccountWhenPresent() {
        let a = account(order: 0)
        let b = account(order: 1)
        XCTAssertEqual(
            SettingsSelection.defaultSelection(accounts: [a, b]),
            .account(a.id)
        )
    }

    func testDefaultSelectionIsGeneralWhenEmpty() {
        XCTAssertEqual(
            SettingsSelection.defaultSelection(accounts: []),
            .general
        )
    }

    // MARK: normalized(_:accounts:)

    func testWarmUpIsPreservedWhenAccountsChange() {
        XCTAssertEqual(SettingsSelection.normalized(.warmUp, accounts: [account(order: 0)]), .warmUp)
        XCTAssertEqual(SettingsSelection.normalized(.warmUp, accounts: []), .warmUp)
    }

    // Pins the hazard `normalized(_:accounts:)`'s doc comment warns about: a
    // new case must have its own branch, or it would fall through to the
    // `.account, nil` default and get yanked to another pane whenever an
    // account is added or removed — exactly while the user is editing alert
    // thresholds.
    func testAlertsSelectionSurvivesAccountListChanges() {
        XCTAssertEqual(SettingsSelection.normalized(.alerts, accounts: [account(order: 0)]), .alerts)
        XCTAssertEqual(SettingsSelection.normalized(.alerts, accounts: []), .alerts)
    }

    func testGeneralIsPreserved() {
        XCTAssertEqual(SettingsSelection.normalized(.general, accounts: []), .general)
        XCTAssertEqual(SettingsSelection.normalized(.general, accounts: [account(order: 0)]), .general)
    }

    func testExistingAccountIsPreserved() {
        let a = account(order: 0)
        XCTAssertEqual(SettingsSelection.normalized(.account(a.id), accounts: [a]), .account(a.id))
    }

    func testRemovedAccountFallsBackToFirstAccount() {
        let remaining = account(order: 0)
        XCTAssertEqual(
            SettingsSelection.normalized(.account(UUID()), accounts: [remaining]),
            .account(remaining.id)
        )
    }

    func testRemovedAccountWithNoAccountsFallsBackToGeneral() {
        XCTAssertEqual(SettingsSelection.normalized(.account(UUID()), accounts: []), .general)
    }

    func testNilFallsBackToDefault() {
        let a = account(order: 0)
        XCTAssertEqual(SettingsSelection.normalized(nil, accounts: [a]), .account(a.id))
        XCTAssertEqual(SettingsSelection.normalized(nil, accounts: []), .general)
    }
}
