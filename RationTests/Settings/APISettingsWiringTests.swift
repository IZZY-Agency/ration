import SwiftUI
import XCTest
@testable import Ration

/// The Settings scenes must hand the API model through, or the "API orgs"
/// section, the org pane and the API budgets row silently disappear.
@MainActor
final class APISettingsWiringTests: APISpendModelTestCase {
    func testSceneSettingsCarriesTheAPIModel() throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let apiSpend = makeModel()

        let content = SettingsWindowContent(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            appearance: AppearanceController(),
            onOpenSetupGuide: {},
            apiSpend: apiSpend
        )

        XCTAssertTrue(content.settingsView.apiSpend === apiSpend)
    }

    func testRemovedOrgPaneFallsBack() {
        let id = UUID()
        XCTAssertEqual(SettingsSelection.normalized(.apiOrg(id), accounts: [], apiOrgIDs: [id]), .apiOrg(id))
        XCTAssertNotEqual(SettingsSelection.normalized(.apiOrg(id), accounts: [], apiOrgIDs: []), .apiOrg(id))
    }

    /// The add dialog used to flicker several times before saving. A
    /// sheet anchored inside the sidebar List is re-presented each time the
    /// List's rows change (measured: 6 presentations for 4 appended rows); the
    /// add inserts a row and its first refresh publishes more changes.
    func testAddSheetStaysUpWhileTheOrgListChanges() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let apiSpend = makeModel()
        await apiSpend.start()
        AddAPIOrgSheet.appearancesForTesting = 0
        let view = SettingsView(
            model: fixture.model, launchAtLogin: LaunchAtLoginController(), appearance: AppearanceController(),
            history: fixture.model.history, onAddAccount: {}, onOpenSignIn: { _ in }, onOpenSetupGuide: {},
            apiSpend: apiSpend, startsAddingAPIAccount: true
        )
        let hosting = NSHostingView(rootView: view.frame(width: 760, height: 560))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.attachedSheet.map { window.endSheet($0) }; window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(window.attachedSheet, "the add sheet is up")
        XCTAssertEqual(AddAPIOrgSheet.appearancesForTesting, 1)
        // The add the sheet runs: validation, the new row, its first refresh —
        // then more rows, as a second and third add would.
        let month = UTCMonth(containing: now)
        anthropic.costResults = [.success(costReport(month: month, cents: "10450", fetchedAt: now)),
                                 .success(costReport(month: month, cents: "10450", fetchedAt: now))]
        _ = try await apiSpend.addOrg(label: "", rawKey: "sk-ant-admin01-SENTINELSENTINEL", budgetCents: 10_000)
        try await Task.sleep(for: .milliseconds(400))
        for index in 0..<3 {
            apiSpend.mutateState { $0.orgs.append(APIOrgRecord(id: UUID(), vendor: .openAI, vendorOrgID: "org-o\(index)", label: "Org \(index)",
                                                              monthlyBudgetCents: nil, isPaused: false, displayOrder: 10 + index, createdAt: self.now)) }
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTAssertEqual(AddAPIOrgSheet.appearancesForTesting, 1, "the sheet's content was never torn down and rebuilt")
        XCTAssertNotNil(window.attachedSheet, "still up")
    }
}
