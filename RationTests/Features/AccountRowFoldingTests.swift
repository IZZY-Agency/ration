import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The compact and folded account rows as VoiceOver and a click meet them:
/// the row's one label, the chevron's name and what it stores, the Switch
/// hidden while folded — and the app handing the settings to the popover.
///
/// SwiftUI builds a hosting view's accessibility tree only for an assistive
/// client; the walk sets `AXEnhancedUserInterface` as one does (see
/// `CodexViewsTests`).
@MainActor
final class AccountRowFoldingTests: XCTestCase {
    private let now = Date()

    private struct Element: Equatable {
        let identifier: String
        let label: String
    }

    private func tree<T>(of view: some View, _ body: ([String: NSObject], [Element]) -> T) -> T {
        let host = NSHostingView(rootView: view.frame(width: MenuBarView.popoverWidth).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(origin: .zero, size: NSSize(width: MenuBarView.popoverWidth, height: host.fittingSize.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: enhanced.rawValue)?
            .takeUnretainedValue() as? Bool ?? false
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: enhanced.rawValue)
        defer {
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: previous), with: enhanced.rawValue)
            window.contentView = nil
            window.close()
        }
        var nodes: [String: NSObject] = [:]
        var elements: [Element] = []
        func read<V>(_ object: NSObject, _ selector: String, key: String) -> V? {
            object.responds(to: NSSelectorFromString(selector)) ? object.value(forKey: key) as? V : nil
        }
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, let node = object as? NSObject else { return }
            let identifier: String = read(node, "accessibilityIdentifier", key: "accessibilityIdentifier") ?? ""
            if !identifier.isEmpty {
                nodes[identifier] = node
                elements.append(Element(identifier: identifier,
                                        label: read(node, "accessibilityLabel", key: "accessibilityLabel") ?? ""))
            }
            let children: [Any] = read(node, "accessibilityChildren", key: "accessibilityChildren") ?? []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return body(nodes, elements)
    }

    private func elements(in view: some View) -> [Element] {
        tree(of: view) { _, elements in elements }
    }

    private func press(_ identifier: String, in view: some View) -> Bool {
        tree(of: view) { nodes, _ in
            guard let node = nodes[identifier] else { return false }
            _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return true
        }
    }

    /// ChatGPT "5x": weekly 30 %, linked to Codex but not its login.
    private func chatGPT() -> AccountPresentation {
        let id = UUID()
        let record = AccountRecord(id: id, provider: .chatGPT, label: "5x", webProfileID: UUID(), displayOrder: 0,
                                   createdAt: now, plan: .chatGPTPro5x, planSource: .detected)
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.7, resetsAt: now.addingTimeInterval(3 * 86_400))
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    private func row(
        _ presentation: AccountPresentation, inUse: Bool = false, folds: Bool = true, expanded: Bool = false,
        onSetExpanded: @escaping (Bool) -> Void = { _ in }
    ) -> AccountCardView {
        AccountCardView(
            presentation: presentation, onReauthenticate: {},
            activeUsage: inUse ? ActiveUsage(lastUsedAt: now.addingTimeInterval(-120), source: .weekly) : nil,
            now: now, codex: .canSwitch(sameWorkspace: false),
            foldsAccountsNotInUse: folds, isExpanded: expanded, onSetExpanded: onSetExpanded
        )
    }

    // MARK: Folded

    /// Folded: one row element that says it shows its tightest limit, a
    /// chevron named "Expand 5x", and no Switch.
    func testFoldedRowSpeaksOnceOffersExpandAndHidesTheSwitch() {
        let presentation = chatGPT()
        let found = elements(in: row(presentation))
        let ids = found.map(\.identifier)
        XCTAssertFalse(ids.contains("useInCodexButton"), "the Switch is hidden while folded: \(ids)")
        XCTAssertEqual(found.first { $0.identifier == "accountRowChevron" }?.label, "Expand 5x")
        XCTAssertEqual(
            found.first { $0.identifier == "accountRow" }?.label,
            AccountRowCopy.spokenRow(presentation, phase: .none, mode: .folded, now: now)
        )
    }

    func testTheChevronExpandsAFoldedRowAndFoldsAnExpandedOne() {
        var stored: [Bool] = []
        XCTAssertTrue(press("accountRowChevron", in: row(chatGPT(), onSetExpanded: { stored.append($0) })))
        XCTAssertTrue(press("accountRowChevron", in: row(chatGPT(), expanded: true, onSetExpanded: { stored.append($0) })))
        XCTAssertEqual(stored, [true, false])
    }

    // MARK: Expanded

    /// Expanded by the user: every gauge in the row's label, the Switch
    /// back, and a chevron named "Collapse 5x".
    func testExpandedRowShowsTheSwitchAndOffersCollapse() {
        let presentation = chatGPT()
        let found = elements(in: row(presentation, expanded: true))
        XCTAssertTrue(found.map(\.identifier).contains("useInCodexButton"))
        XCTAssertEqual(found.first { $0.identifier == "accountRowChevron" }?.label, "Collapse 5x")
        XCTAssertEqual(
            found.first { $0.identifier == "accountRow" }?.label,
            AccountRowCopy.spokenRow(presentation, phase: .none, mode: .expanded(sparklines: true, collapsible: true), now: now)
        )
    }

    /// In use: always expanded, no chevron; the label says in use.
    func testInUseRowHasNoChevron() {
        let found = elements(in: row(chatGPT(), inUse: true))
        XCTAssertFalse(found.map(\.identifier).contains("accountRowChevron"))
        XCTAssertTrue(found.map(\.identifier).contains("useInCodexButton"))
        XCTAssertTrue(found.first { $0.identifier == "accountRow" }?.label.contains("in use") ?? false)
    }

    /// The Settings switch off: compact rows, no chevron, the Switch shown.
    func testFoldSwitchOffDrawsNoChevron() {
        let ids = elements(in: row(chatGPT(), folds: false)).map(\.identifier)
        XCTAssertFalse(ids.contains("accountRowChevron"))
        XCTAssertTrue(ids.contains("useInCodexButton"))
    }

    // MARK: Wiring

    private func content(_ fixture: AlertsFixture) -> MenuBarContent {
        MenuBarContent(
            model: fixture.model, history: fixture.model.history, pinSnapshot: AccountPinSnapshot(),
            settings: fixture.model.settings,
            onAddAccount: {}, onSettings: {}, onAbout: {}, onHistory: {}, onOpenSignIn: { _ in },
            onOpenSetupGuide: {}, attentionPresence: AttentionDropPresence()
        )
    }

    /// The popover gets the fold switch, In-use detection and the expanded
    /// set from Settings, and a chevron click lands in Settings.
    func testThePopoverFollowsTheSettings() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let id = UUID()

        var view = content(fixture).menuBarView
        XCTAssertTrue(view.foldsAccountsNotInUse)
        XCTAssertTrue(view.inUseDetection)
        XCTAssertEqual(view.expandedAccountIDs, [])

        view.onSetAccountExpanded(id, true)
        for _ in 0..<50 where fixture.model.settings.popoverExpandedAccountIDs != [id] {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fixture.model.settings.popoverExpandedAccountIDs, [id])

        try await fixture.model.setPopoverFoldsAccountsNotInUse(false)
        try await fixture.model.setFeature(.inUse, enabled: false)
        view = content(fixture).menuBarView
        XCTAssertFalse(view.foldsAccountsNotInUse)
        XCTAssertFalse(view.inUseDetection)
        XCTAssertEqual(view.expandedAccountIDs, [id])
    }
}
