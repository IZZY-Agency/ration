import XCTest
@testable import Ration

/// A pane asked of the Settings window from outside it — the popover
/// header's STALE click. Each request moves the selection exactly once.
@MainActor
final class SettingsSelectionRequestTests: XCTestCase {
    private func account() -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: .cursor, label: "Team",
            webProfileID: UUID(), displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testOpeningWithATargetSelectsIt() throws {
        let team = account()
        let request = SettingsSelectionRequest(initial: .account(team.id))
        let resolved = try XCTUnwrap(SettingsSelectionRequest.resolve(request.latest, appliedSerial: 0, accounts: [team]))
        XCTAssertEqual(resolved.selection, .account(team.id))
    }

    /// Nothing requested: the window keeps its default, General.
    func testOpeningWithoutATargetRequestsNothing() {
        let request = SettingsSelectionRequest()
        XCTAssertNil(request.latest)
        XCTAssertNil(SettingsSelectionRequest.resolve(request.latest, appliedSerial: 0, accounts: [account()]))
        XCTAssertEqual(SettingsSelection.normalized(nil, accounts: [account()]), .general)
    }

    /// Already open: a new request switches the selection.
    func testANewRequestSwitchesAnOpenWindow() throws {
        let team = account()
        let work = account()
        let request = SettingsSelectionRequest(initial: .account(team.id))
        let first = try XCTUnwrap(SettingsSelectionRequest.resolve(request.latest, appliedSerial: 0, accounts: [team, work]))

        request.request(.account(work.id))
        let second = try XCTUnwrap(
            SettingsSelectionRequest.resolve(request.latest, appliedSerial: first.serial, accounts: [team, work])
        )
        XCTAssertEqual(second.selection, .account(work.id))
        XCTAssertGreaterThan(second.serial, first.serial)
    }

    /// The same request again (the user clicked STALE twice) is a new
    /// request: it brings them back to the account after they moved away.
    func testRepeatingARequestAppliesAgain() throws {
        let team = account()
        let request = SettingsSelectionRequest(initial: .account(team.id))
        let first = try XCTUnwrap(SettingsSelectionRequest.resolve(request.latest, appliedSerial: 0, accounts: [team]))
        request.request(.account(team.id))
        XCTAssertNotNil(SettingsSelectionRequest.resolve(request.latest, appliedSerial: first.serial, accounts: [team]))
    }

    /// A replay of an applied request (re-render, re-subscription) must not
    /// yank the user back from the pane they moved to.
    func testAnAppliedRequestIsNotReplayed() throws {
        let team = account()
        let request = SettingsSelectionRequest(initial: .account(team.id))
        let applied = try XCTUnwrap(SettingsSelectionRequest.resolve(request.latest, appliedSerial: 0, accounts: [team]))
        XCTAssertNil(SettingsSelectionRequest.resolve(request.latest, appliedSerial: applied.serial, accounts: [team]))
    }

    /// An account removed before the window applied the request falls back
    /// to General, like any stale selection.
    func testARemovedAccountFallsBackToGeneral() throws {
        let request = SettingsSelectionRequest(initial: .account(UUID()))
        let resolved = try XCTUnwrap(SettingsSelectionRequest.resolve(request.latest, appliedSerial: 0, accounts: [account()]))
        XCTAssertEqual(resolved.selection, .general)
    }
}
