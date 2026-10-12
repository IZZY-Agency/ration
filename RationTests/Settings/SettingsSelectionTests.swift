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

    func testSettingsOpensOnGeneralEvenWithAccounts() {
        let a = account(order: 0)
        XCTAssertEqual(SettingsSelection.normalized(nil, accounts: [a, account(order: 1)]), .general)
    }

    func testSettingsOpensOnGeneralWithoutAccounts() {
        XCTAssertEqual(SettingsSelection.normalized(nil, accounts: []), .general)
    }

    func testRemovedAccountSelectionFallsBackToGeneral() {
        let removed = account(order: 0)
        XCTAssertEqual(
            SettingsSelection.normalized(.account(removed.id), accounts: [account(order: 1)]),
            .general
        )
    }

    func testExistingAccountSelectionIsKept() {
        let a = account(order: 0)
        XCTAssertEqual(SettingsSelection.normalized(.account(a.id), accounts: [a]), .account(a.id))
    }

    // MARK: normalized(_:accounts:)

    func testDisplayAndFeaturesArePreservedWhenAccountsChange() {
        XCTAssertEqual(SettingsSelection.normalized(.display, accounts: []), .display)
        XCTAssertEqual(SettingsSelection.normalized(.features, accounts: [account(order: 0)]), .features)
    }

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

    /// Settings › Codex is a fixed pane: adding or removing an account must
    /// not move the user off it.
    @MainActor
    func testCodexSurvivesAccountListChanges() {
        XCTAssertEqual(SettingsSelection.normalized(.codex, accounts: [account(order: 0)]), .codex)
        XCTAssertEqual(SettingsSelection.normalized(.codex, accounts: []), .codex)
        XCTAssertEqual(
            SettingsSelectionRequest.resolve(.init(serial: 1, selection: .codex), appliedSerial: 0, accounts: [])?.selection,
            .codex
        )
    }

    /// Codex's row comes right after Claude Code's, in the same group.
    func testTheSidebarListsCodexAfterClaudeCode() {
        let groups = SettingsSidebar.fixedGroups(locale: Locale(identifier: "en"))
        XCTAssertEqual(groups.last?.map(\.selection), [.alerts, .claudeCode, .codex])
        let item = groups.flatMap { $0 }.first { $0.selection == .codex }
        XCTAssertEqual(item?.title, "Codex")
        XCTAssertEqual(item?.accessibilityIdentifier, "codexSettingsItem")
        XCTAssertEqual(item?.systemImage, "chevron.left.forwardslash.chevron.right")
    }

    func testGeneralIsPreserved() {
        XCTAssertEqual(SettingsSelection.normalized(.general, accounts: []), .general)
        XCTAssertEqual(SettingsSelection.normalized(.general, accounts: [account(order: 0)]), .general)
    }

    func testExistingAccountIsPreserved() {
        let a = account(order: 0)
        XCTAssertEqual(SettingsSelection.normalized(.account(a.id), accounts: [a]), .account(a.id))
    }

    func testRemovedAccountWithNoAccountsFallsBackToGeneral() {
        XCTAssertEqual(SettingsSelection.normalized(.account(UUID()), accounts: []), .general)
    }
}
