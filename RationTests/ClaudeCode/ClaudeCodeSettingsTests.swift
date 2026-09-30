import SwiftUI
import XCTest
@testable import Ration

final class ClaudeCodeSettingsTests: XCTestCase {
    func testThePaneSurvivesAccountChanges() {
        XCTAssertEqual(SettingsSelection.normalized(.claudeCode, accounts: []), .claudeCode)
    }

    func testTheSidebarListsClaudeCodeAfterAlerts() {
        let order = SettingsSidebar.fixedGroups(locale: Locale(identifier: "en")).flatMap { $0.map(\.selection) }
        XCTAssertEqual(order, [.general, .warmUp, .alerts, .claudeCode])
        let item = SettingsSidebar.fixedGroups(locale: Locale(identifier: "en")).flatMap { $0 }.first { $0.selection == .claudeCode }
        XCTAssertEqual(item?.title, "Claude Code")
        XCTAssertEqual(item?.accessibilityIdentifier, "claudeCodeSettingsItem")
    }

    private func candidate(_ id: UUID, org: String?) -> ClaudeCodeCandidate {
        ClaudeCodeCandidate(accountID: id, label: "L", organizationID: org, isPaused: false, usable: true,
                            snapshot: nil, planUnits: nil, order: 0)
    }

    /// The Remember sheet preselects the one account whose organization matches.
    func testTheSheetSuggestsTheAccountWithTheSameOrganization() {
        let account = ClaudeCodeConfig.account(from: ClaudeCodeConfigTests.account("A"))!
        let a = UUID(), b = UUID()
        XCTAssertEqual(ClaudeCodeDetailView.suggestedLink(for: account, candidates: [candidate(a, org: "org-A"), candidate(b, org: "org-B")]), a)
        XCTAssertNil(ClaudeCodeDetailView.suggestedLink(for: account, candidates: [candidate(a, org: "org-A"), candidate(b, org: "org-A")]),
                     "two accounts in one organization: the user chooses")
        XCTAssertNil(ClaudeCodeDetailView.suggestedLink(for: account, candidates: [candidate(a, org: nil)]))
    }

    func testEveryFailureHasAMessage() {
        let failures: [ClaudeCodeSwitcher.Failure] = [
            .notSignedIn, .configUnreadable, .signInChanging,
            .leftAccountNotRemembered(ClaudeCodeConfig.account(from: ClaudeCodeConfigTests.account("A"))!),
            .targetNotRemembered, .conflict, .failed, .needsAttention(entryRestored: true, configRestored: false),
        ]
        for failure in failures {
            XCTAssertFalse(ClaudeCodeDetailView.message(for: failure).string(in: Locale(identifier: "en")).isEmpty, "\(failure)")
        }
    }

    /// The card's button and the Focus line, in every language.
    func testTheSwitchWordsInEveryLanguage() {
        let cases: [(locale: String, use: String, on: String, to: String)] = [
            ("en", "Switch", "Claude Code on Work", "Switch to Personal"),
            ("fr", "Basculer", "Claude Code utilise Work", "Basculer vers Personal"),
            ("uk", "Перемкнути", "Claude Code використовує Work", "Перемкнути на Personal"),
        ]
        for item in cases {
            let locale = Locale(identifier: item.locale)
            XCTAssertEqual(LocalizedStringResource.claudeCodeCardUse.string(in: locale), item.use)
            XCTAssertEqual(LocalizedStringResource.claudeCodeFocusOn("Work").string(in: locale), item.on)
            XCTAssertEqual(LocalizedStringResource.claudeCodeFocusSwitch("Personal").string(in: locale), item.to)
        }
    }

    /// A long account name truncates inside the Focus button
    /// instead of pushing the line past the popover.
    @MainActor
    func testTheFocusLineFitsTheWidthItIsGiven() {
        let long = String(repeating: "Very long account name ", count: 6)
        let line = ClaudeCodeFocusLine(currentLabel: "Client", target: .init(accountID: UUID(), label: long))
        let host = NSHostingController(rootView: ClaudeCodeFocusLineView(line: line, busy: false, action: { _ in }))
        let size = host.sizeThatFits(in: CGSize(width: 508, height: 1_000))
        XCTAssertLessThanOrEqual(size.width, 508)
    }
}
