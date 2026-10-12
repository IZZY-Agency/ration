import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The Codex controls in the popover (spec §4.4): which accessibility
/// elements each state draws, the busy states, and the status line's text,
/// symbol and colour per case.
///
/// SwiftUI builds a hosting view's accessibility tree only for an assistive
/// client. `AXEnhancedUserInterface` on the app is what such a client sets,
/// so `tree(of:_:)` sets it for the walk and puts the old value back.
@MainActor
final class CodexViewsTests: XCTestCase {
    private struct Element: Equatable {
        let identifier: String
        let label: String
        let enabled: Bool
    }

    /// Hosts `view` in a window, hands `body` every accessibility node that
    /// carries an identifier (depth first), then closes the window.
    private func tree<T>(of view: some View, _ body: ([String: NSObject], [Element]) -> T) -> T {
        let host = NSHostingView(rootView: view.fixedSize())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
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
                elements.append(Element(
                    identifier: identifier,
                    label: read(node, "accessibilityLabel", key: "accessibilityLabel") ?? "",
                    enabled: read(node, "isAccessibilityEnabled", key: "accessibilityEnabled") ?? false
                ))
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

    private func identifiers(in view: some View) -> [String] {
        elements(in: view).map(\.identifier)
    }

    /// Presses the element with `identifier` the way VoiceOver does.
    private func press(_ identifier: String, in view: some View) -> Bool {
        tree(of: view) { nodes, _ in
            guard let node = nodes[identifier] else { return false }
            _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return true
        }
    }

    // MARK: Card row

    func testACardCodexDoesNotUseDrawsNoCodexControl() {
        XCTAssertEqual(identifiers(in: CodexCardRow(state: .none, accountLabel: "20x", busy: false, action: {})), [])
    }

    func testTheAccountCodexUsesWearsTheCodexTag() {
        XCTAssertEqual(elements(in: CodexCardRow(state: .current, accountLabel: "20x", busy: false, action: {})),
                       [Element(identifier: "codexCurrentTag", label: "Codex uses this account", enabled: true)])
    }

    func testAnotherLinkedAccountOffersSwitch() {
        XCTAssertEqual(elements(in: CodexCardRow(state: .canSwitch(sameWorkspace: false), accountLabel: "5x", busy: false, action: {})),
                       [Element(identifier: "useInCodexButton", label: "Switch Codex to 5x", enabled: true)])
    }

    func testWhileASwitchRunsTheSwitchButtonIsDisabled() {
        XCTAssertEqual(elements(in: CodexCardRow(state: .canSwitch(sameWorkspace: false), accountLabel: "5x", busy: true, action: {})),
                       [Element(identifier: "useInCodexButton", label: "Switch Codex to 5x", enabled: false)])
    }

    func testTheAccountBeingSwitchedToShowsProgressInPlace() {
        let found = identifiers(in: CodexCardRow(state: .switching, accountLabel: "5x", busy: true, action: {}))
        XCTAssertFalse(found.contains("codexCurrentTag"))
        XCTAssertFalse(found.contains("useInCodexButton"))
    }

    func testTheSwitchButtonRunsItsAction() {
        var pressed = 0
        XCTAssertTrue(press("useInCodexButton", in: CodexCardRow(state: .canSwitch(sameWorkspace: false), accountLabel: "5x", busy: false, action: { pressed += 1 })))
        XCTAssertEqual(pressed, 1)
    }

    /// The tooltip (`.help`) as an assistive client reads it.
    private func help(_ identifier: String, in view: some View) -> String? {
        tree(of: view) { nodes, _ in
            guard let node = nodes[identifier], node.responds(to: NSSelectorFromString("accessibilityHelp")) else { return nil }
            return node.value(forKey: "accessibilityHelp") as? String
        }
    }

    /// Spec §1, §4.5: another seat of the workspace Codex is on
    /// — running sessions may follow it; the button says so, aloud and in
    /// its tooltip.
    func testASameWorkspaceSwitchWarnsThatRunningSessionsMayFollow() {
        let sentence = "Switch Codex to 5x — same workspace: running sessions may follow"
        let row = CodexCardRow(state: .canSwitch(sameWorkspace: true), accountLabel: "5x", busy: false, action: {})
        XCTAssertEqual(elements(in: row), [Element(identifier: "useInCodexButton", label: sentence, enabled: true)])
        XCTAssertEqual(help("useInCodexButton", in: row), sentence)
        let other = CodexCardRow(state: .canSwitch(sameWorkspace: false), accountLabel: "5x", busy: false, action: {})
        XCTAssertEqual(help("useInCodexButton", in: other), "Switch Codex to 5x")
    }

    func testTheFocusTargetInTheSameWorkspaceWarnsToo() {
        let sentence = "Switch Codex to 5x — same workspace: running sessions may follow"
        let line = CodexFocusLine(currentLabel: "20x", target: .init(accountID: UUID(), label: "5x", sameWorkspace: true))
        let view = CodexFocusLineView(line: line, busy: false, action: { _ in })
        // The button's uppercase text case reaches its label and tooltip as
        // read by an assistive client; the words are what matter.
        XCTAssertEqual(elements(in: view).last?.label.lowercased(), sentence.lowercased())
        XCTAssertEqual(help("focusCodexSwitch", in: view)?.lowercased(), sentence.lowercased())
        let other = CodexFocusLine(currentLabel: "20x", target: .init(accountID: UUID(), label: "5x"))
        XCTAssertEqual(help("focusCodexSwitch", in: CodexFocusLineView(line: other, busy: false, action: { _ in }))?.lowercased(),
                       "switch codex to 5x")
    }

    // MARK: Focus line

    func testTheFocusLineOffersTheAccountWithTheMostRoom() {
        let line = CodexFocusLine(currentLabel: "20x", target: .init(accountID: UUID(), label: "5x"))
        let found = elements(in: CodexFocusLineView(line: line, busy: false, action: { _ in }))
        XCTAssertEqual(found.map(\.identifier), ["focusCodexLine", "focusCodexSwitch"])
        // The button's uppercase text case reaches its VoiceOver label (as on
        // Claude Code's line); the words are what matter.
        XCTAssertEqual(found.last?.label.lowercased(), "switch codex to 5x")
        XCTAssertEqual(found.last?.enabled, true)
    }

    func testTheFocusLineWithoutATargetHasNoButton() {
        let line = CodexFocusLine(currentLabel: "20x", target: nil)
        XCTAssertEqual(identifiers(in: CodexFocusLineView(line: line, busy: false, action: { _ in })), ["focusCodexLine"])
    }

    func testWhileASwitchRunsTheFocusLineShowsProgressInsteadOfTheButton() {
        let line = CodexFocusLine(currentLabel: "20x", target: .init(accountID: UUID(), label: "5x"))
        XCTAssertEqual(identifiers(in: CodexFocusLineView(line: line, busy: true, action: { _ in })), ["focusCodexLine"])
    }

    func testTheFocusButtonSwitchesToItsTarget() {
        let target = UUID()
        var switched: [UUID] = []
        let line = CodexFocusLine(currentLabel: "20x", target: .init(accountID: target, label: "5x"))
        XCTAssertTrue(press("focusCodexSwitch", in: CodexFocusLineView(line: line, busy: false, action: { switched.append($0) })))
        XCTAssertEqual(switched, [target])
    }

    /// A long account name truncates inside the Focus button instead of
    /// pushing the line past the popover.
    func testTheFocusLineFitsTheWidthItIsGiven() {
        let long = String(repeating: "Very long account name ", count: 6)
        let line = CodexFocusLine(currentLabel: "20x", target: .init(accountID: UUID(), label: long))
        let host = NSHostingController(rootView: CodexFocusLineView(line: line, busy: false, action: { _ in }))
        XCTAssertLessThanOrEqual(host.sizeThatFits(in: CGSize(width: 508, height: 1_000)).width, 508)
    }

    // MARK: On the card and in Focus

    private func chatGPT(_ label: String, weekly: Double = 0.4, order: Int = 1) -> AccountPresentation {
        let id = UUID()
        let now = Date()
        let record = AccountRecord(id: id, provider: .chatGPT, label: label, webProfileID: UUID(), displayOrder: order, createdAt: now)
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - weekly, resetsAt: now.addingTimeInterval(3 * 86_400))
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    private static let codexIdentifiers: Set<String> = ["codexCurrentTag", "useInCodexButton", "focusCodexLine", "focusCodexSwitch"]

    /// Other callers pass nothing and get no Codex control.
    func testACardDrawsNoCodexControlByDefault() {
        let found = Set(identifiers(in: AccountCardView(presentation: chatGPT("20x"), onReauthenticate: {})))
        XCTAssertTrue(found.isDisjoint(with: Self.codexIdentifiers), "\(found)")
    }

    func testAChatGPTCardShowsTheCodexTagOrTheSwitchButton() {
        let card = chatGPT("20x")
        XCTAssertTrue(identifiers(in: AccountCardView(presentation: card, onReauthenticate: {}, codex: .current)).contains("codexCurrentTag"))
        let busy = elements(in: AccountCardView(presentation: card, onReauthenticate: {}, codex: .canSwitch(sameWorkspace: false), codexBusy: true))
        XCTAssertEqual(busy.first { $0.identifier == "useInCodexButton" },
                       Element(identifier: "useInCodexButton", label: "Switch Codex to 20x", enabled: false))
    }

    func testTheCardsSwitchButtonCallsOnUseInCodex() {
        var pressed = 0
        let view = AccountCardView(presentation: chatGPT("20x"), onReauthenticate: {}, codex: .canSwitch(sameWorkspace: false), onUseInCodex: { pressed += 1 })
        XCTAssertTrue(press("useInCodexButton", in: view))
        XCTAssertEqual(pressed, 1)
    }

    private func focus(_ presentations: [AccountPresentation], inUse: AccountPresentation) -> FocusModel {
        FocusModel.make(presentations: presentations, phases: [inUse.id: .inUse(age: 60)], advice: [],
                        fableCounts: { _ in false }, now: Date())
    }

    func testFocusDrawsNoCodexLineByDefault() {
        let gpt20 = chatGPT("20x"), gpt5 = chatGPT("5x", weekly: 0, order: 2)
        let view = FocusView(model: focus([gpt20, gpt5], inUse: gpt20), now: Date(), onShowHero: { _ in }, onReauthenticate: { _ in })
        XCTAssertTrue(Set(identifiers(in: view)).isDisjoint(with: Self.codexIdentifiers))
    }

    /// Codex's line sits under Claude Code's, and its button switches to
    /// the target.
    func testFocusShowsTheCodexLineUnderClaudeCodes() {
        let gpt20 = chatGPT("20x"), gpt5 = chatGPT("5x", weekly: 0, order: 2)
        var switched: [UUID] = []
        let view = FocusView(
            model: focus([gpt20, gpt5], inUse: gpt20), now: Date(), onShowHero: { _ in }, onReauthenticate: { _ in },
            claudeCode: ClaudeCodeFocusLine(currentLabel: "Client", target: nil),
            codex: CodexFocusLine(currentLabel: "20x", target: .init(accountID: gpt5.id, label: "5x")),
            onCodexSwitch: { switched.append($0) }
        )
        let found = identifiers(in: view)
        let claudeCode = found.firstIndex(of: "focusClaudeCodeLine")
        let codex = found.firstIndex(of: "focusCodexLine")
        XCTAssertNotNil(claudeCode, "\(found)")
        XCTAssertNotNil(codex, "\(found)")
        if let claudeCode, let codex { XCTAssertLessThan(claudeCode, codex) }
        XCTAssertTrue(press("focusCodexSwitch", in: view))
        XCTAssertEqual(switched, [gpt5.id])
    }

    func testWhileASwitchRunsFocusHidesTheCodexButton() {
        let gpt20 = chatGPT("20x"), gpt5 = chatGPT("5x", weekly: 0, order: 2)
        let view = FocusView(
            model: focus([gpt20, gpt5], inUse: gpt20), now: Date(), onShowHero: { _ in }, onReauthenticate: { _ in },
            codex: CodexFocusLine(currentLabel: "20x", target: .init(accountID: gpt5.id, label: "5x")), codexBusy: true
        )
        let found = identifiers(in: view)
        XCTAssertTrue(found.contains("focusCodexLine"))
        XCTAssertFalse(found.contains("focusCodexSwitch"))
    }

    // MARK: Status line

    /// Every case is one button, `codexStatusLine`, reading its own sentence.
    func testEveryStatusLineReadsItsOwnSentence() {
        let cases: [(CodexStatusLine, String)] = [
            (.needsAttention, "Codex’s sign-in needs attention"),
            (.paused, "Automatic Codex switching is paused"),
            (.failed, "Couldn’t switch Codex"),
            (.noRoom, "No remembered ChatGPT account has room"),
            (.waiting, "Waiting for fresh usage to switch Codex"),
            (.stale(account: "5x"), "Sign in to 5x in Codex, then Remember it again"),
            (.damaged, "Codex’s sign-in file mixes two accounts — run codex login"),
            (.rememberPrompt(email: "me@example.com"), "Codex is on me@example.com — remember it"),
            (.switched(to: "5x", automatic: true), "Codex switched to 5x automatically — restart running sessions"),
            (.switched(to: "5x", automatic: false), "Codex now uses 5x — restart running sessions"),
            (.switched(to: "5x", automatic: true, verified: false),
             "Codex now uses 5x — it refreshed its sign-in meanwhile; restart running sessions"),
            (.switched(to: "5x", automatic: false, verified: false),
             "Codex now uses 5x — it refreshed its sign-in meanwhile; restart running sessions"),
            // Another seat of the workspace — and Codex refreshing
            // meanwhile is then likely a running session that followed.
            (.switched(to: "5x", automatic: false, sameWorkspace: true),
             "Codex now uses 5x — same workspace: running sessions may follow; restart to be sure"),
            (.switched(to: "5x", automatic: false, verified: false, sameWorkspace: true),
             "Codex now uses 5x — same workspace: running sessions may follow; restart to be sure"),
        ]
        for (line, sentence) in cases {
            XCTAssertEqual(elements(in: CodexStatusLineView(line: line, action: {})),
                           [Element(identifier: "codexStatusLine", label: sentence, enabled: true)], "\(line)")
            XCTAssertEqual(String(localized: CodexStatusLineView(line: line, action: {}).text), sentence, "\(line)")
        }
    }

    /// Trouble is red, a reason to act is amber, waiting is quiet, a switch
    /// wears Codex's teal and its symbol — a switch with a caveat (unverified,
    /// another seat of the workspace) is amber with the warning glyph.
    func testTheStatusLineSymbolAndColourPerCase() {
        let cases: [(CodexStatusLine, String, Color)] = [
            (.needsAttention, "exclamationmark.triangle", Theme.crit),
            (.failed, "exclamationmark.triangle", Theme.crit),
            (.stale(account: "5x"), "exclamationmark.triangle", Theme.warn),
            (.damaged, "exclamationmark.triangle", Theme.warn),
            (.paused, "pause.circle", Theme.warn),
            (.noRoom, "gauge.with.dots.needle.100percent", Theme.warn),
            (.waiting, "hourglass", Theme.creamDim),
            (.rememberPrompt(email: "me@example.com"), "plus.circle", Theme.creamDim),
            (.switched(to: "5x", automatic: true), "chevron.left.forwardslash.chevron.right", Theme.codex),
            (.switched(to: "5x", automatic: false), "chevron.left.forwardslash.chevron.right", Theme.codex),
            // A switch with a caveat the user should act on.
            (.switched(to: "5x", automatic: false, verified: false), "exclamationmark.triangle", Theme.warn),
            (.switched(to: "5x", automatic: true, verified: false), "exclamationmark.triangle", Theme.warn),
            (.switched(to: "5x", automatic: false, sameWorkspace: true), "exclamationmark.triangle", Theme.warn),
        ]
        for (line, symbol, color) in cases {
            let view = CodexStatusLineView(line: line, action: {})
            XCTAssertEqual(view.symbol, symbol, "\(line)")
            XCTAssertEqual(view.color, color, "\(line)")
        }
    }

    func testAClickOnTheStatusLineRunsItsAction() {
        var pressed = 0
        XCTAssertTrue(press("codexStatusLine", in: CodexStatusLineView(line: .paused, action: { pressed += 1 })))
        XCTAssertEqual(pressed, 1)
    }

    /// A caveat's copy is longer than the popover (540 pt) — the
    /// unverified and same-workspace lines truncated before "restart". The
    /// line wraps instead, within the width it is given; a short one keeps
    /// its single line.
    func testALongStatusLineWrapsInsteadOfTruncating() {
        func size(_ line: CodexStatusLine) -> CGSize {
            NSHostingController(rootView: CodexStatusLineView(line: line, action: {}))
                .sizeThatFits(in: CGSize(width: 540, height: 1_000))
        }
        let short = size(.switched(to: "5x", automatic: false))
        for line: CodexStatusLine in [.switched(to: "5x", automatic: false, verified: false),
                                      .switched(to: "5x", automatic: false, sameWorkspace: true)] {
            let long = size(line)
            XCTAssertLessThanOrEqual(long.width, 540, "\(line)")
            XCTAssertGreaterThan(long.height, short.height * 1.5, "\(line) wraps to a second line")
        }
    }
}
