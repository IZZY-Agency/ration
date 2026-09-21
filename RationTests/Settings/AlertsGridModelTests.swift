import XCTest
@testable import Ration

final class AlertsGridModelTests: XCTestCase {
    func testRowsCoverOnlyWindowsThatCanExist() {
        let rows = AlertsGridModel.rows(for: [.claude, .chatGPT, .cursor])
        XCTAssertEqual(
            rows.filter { $0.provider == .claude }.map(\.window),
            [.fiveHour, .weekly, .modelWeekly]
        )
        XCTAssertEqual(
            rows.filter { $0.provider == .chatGPT }.map(\.window),
            [.fiveHour, .weekly]
        )
        // Cursor has no rate window — it is represented by the spend row only.
        XCTAssertTrue(rows.filter { $0.provider == .cursor }.isEmpty)
    }

    func testRowsOmitProvidersWithNoAccounts() {
        let rows = AlertsGridModel.rows(for: [.chatGPT])
        XCTAssertTrue(rows.allSatisfy { $0.provider == .chatGPT })
    }

    // NOTE: `SettingsSelection` carries an associated value (`case account(UUID)`)
    // and therefore cannot be `CaseIterable` — assert on the sidebar's rows and
    // on case distinctness instead.
    func testAlertsIsADistinctSelection() {
        XCTAssertNotEqual(SettingsSelection.alerts, SettingsSelection.general)
        XCTAssertNotEqual(SettingsSelection.alerts, SettingsSelection.warmUp)
    }

    /// Asserts on the descriptor the sidebar actually RENDERS from, not on a
    /// parallel list — `body` builds its rows out of `fixedGroups`, so
    /// deleting the Alerts row necessarily fails this.
    func testSidebarOffersTheAlertsRow() {
        let items = SettingsSidebar.fixedGroups.flatMap(\.self)
        let alerts = items.first { $0.selection == .alerts }
        XCTAssertNotNil(alerts, "the sidebar must render an Alerts row")
        XCTAssertEqual(alerts?.title, "Alerts")
        XCTAssertEqual(alerts?.accessibilityIdentifier, "alertsSettingsItem")
        XCTAssertTrue(SettingsSidebar.fixedSelections.contains(.alerts))
    }

    /// The fixed rows must stay in their intended display order and grouping:
    /// General and Warm-up together, Alerts visually separated below.
    func testAlertsRendersInItsOwnGroupBelowGeneralAndWarmUp() {
        XCTAssertEqual(SettingsSidebar.fixedSelections, [.general, .warmUp, .alerts])
        XCTAssertEqual(SettingsSidebar.fixedGroups.count, 2)
        XCTAssertEqual(SettingsSidebar.fixedGroups.last?.map(\.selection), [.alerts])
    }
}
