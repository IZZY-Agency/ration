import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Where a click lands on a popover row. Only the chevron and the row's
/// first line fold or expand an expanded row; a gauge's countdown toggles
/// its exact reset time both ways; the gauges, the exact time, the
/// sparklines and the lines under them never touch the row; the Switch and
/// the chevron each take their own click, once.
///
/// Driven two ways on ONE hosted row (so the countdown's state lives across
/// steps): accessibility presses, as VoiceOver makes them, and mouse events
/// sent to the hosting window, so SwiftUI's own hit testing decides which
/// view takes each click. The events go to that window alone (`sendEvent`),
/// never to the screen.
///
/// No fixed waits: each step polls for the state it expects (`waitUntil`).
/// A click that must change nothing is followed by `flush`, a click whose
/// effect is polled for; clicks are handled in order, so once it lands,
/// everything before it has too.
@MainActor
final class AccountRowClickRoutingTests: XCTestCase {
    private let now = Date()
    private var resetsAt: Date { now.addingTimeInterval(3 * 86_400) }

    /// ChatGPT "5x": weekly 30 %, 25 Codex credits left, linked to Codex
    /// but not its login.
    private func chatGPT() -> AccountPresentation {
        let id = UUID()
        let record = AccountRecord(id: id, provider: .chatGPT, label: "5x", webProfileID: UUID(), displayOrder: 0,
                                   createdAt: now, plan: .chatGPTPro5x, planSource: .detected)
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.7, resetsAt: resetsAt),
            codexCredits: CodexCredits(fetchedAt: now.addingTimeInterval(-60), balance: 25, unlimited: false)
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    /// Claude "Work": 5h 20 %, weekly 50 %, not Claude Code's account.
    private func claude() -> AccountPresentation {
        let id = UUID()
        let record = AccountRecord(id: id, provider: .claude, label: "Work", webProfileID: UUID(), displayOrder: 0,
                                   createdAt: now, plan: .claudeMax20x, planSource: .detected)
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.8, resetsAt: now.addingTimeInterval(2 * 3600)),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: resetsAt)
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    /// The weekly window's trend over the last day: 85 % left down to 70 %.
    private var weeklySamples: [UsageHistorySample] {
        [0.85, 0.8, 0.76, 0.7].enumerated().map { index, remaining in
            UsageHistorySample(ts: now.addingTimeInterval(Double(index - 3) * 6 * 3600), remaining: remaining, resetsAt: resetsAt)
        }
    }

    private var weekly: UsageWindow? { chatGPT().snapshot?.weekly }

    // MARK: Hosting

    /// The row as the popover holds it: whether it is expanded lives outside
    /// the row (Settings), and the row asks to change it. Claude rows get
    /// Claude Code's Switch, ChatGPT rows Codex's; both report to `switched`.
    private struct Harness: View {
        let presentation: AccountPresentation
        let now: Date
        let samples: [UsageHistorySample]
        let stored: (Bool) -> Void
        let switched: () -> Void
        @State var expanded: Bool

        var body: some View {
            let provider = presentation.account.provider
            AccountCardView(
                presentation: presentation, onReauthenticate: {},
                samples: { [samples] kind in kind == .weekly ? samples : [] },
                now: now,
                claudeCode: provider == .claude ? .canSwitch : .none, onUseInClaudeCode: switched,
                codex: provider == .chatGPT ? .canSwitch(sameWorkspace: false) : .none, onUseInCodex: switched,
                foldsAccountsNotInUse: true, isExpanded: expanded,
                onSetExpanded: { expanded = $0; stored($0) }
            )
            .frame(width: MenuBarView.popoverWidth)
            // At its own height, pinned to the top of a tall window: a line
            // that appears below moves nothing above it.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private struct Node {
        let object: NSObject
        let identifier: String
        let label: String
        let role: String
        let help: String
        /// A plain `Text` speaks through its value, not its label.
        let value: String
        /// What VoiceOver reads: a text's value, anything else's label.
        var spoken: String { value.isEmpty ? label : value }
    }

    /// One row in a borderless window ordered in off every screen: AppKit
    /// dispatches clicks only to a window it shows (`RingBarDragRouterTests`).
    @MainActor
    private final class Hosted {
        let window: NSWindow
        let host: NSView
        private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        private let previous: Bool

        init(_ view: Harness) {
            let size = NSSize(width: MenuBarView.popoverWidth, height: 400)
            host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            // SwiftUI builds a hosting view's accessibility tree only for an
            // assistive client (see `AccountRowFoldingTests`).
            previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: enhanced.rawValue)?
                .takeUnretainedValue() as? Bool ?? false
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                              with: enhanced.rawValue)
        }

        func close() {
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: previous),
                              with: enhanced.rawValue)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        /// Runs the run loop until `condition` holds — up to 2 s, in 10 ms
        /// steps — and says whether it did. SwiftUI applies a click or a
        /// press on a later pass; how much later depends on the machine.
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while true {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                if Date() >= deadline { return false }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }

        /// Every element in the tree, read afresh: SwiftUI rebuilds nodes
        /// when the view changes.
        var nodes: [Node] {
            var found: [Node] = []
            func read(_ object: NSObject, _ key: String) -> String {
                object.responds(to: NSSelectorFromString(key)) ? (object.value(forKey: key) as? String ?? "") : ""
            }
            func walk(_ object: Any, depth: Int) {
                guard depth < 40, let node = object as? NSObject else { return }
                found.append(Node(object: node, identifier: read(node, "accessibilityIdentifier"),
                                  label: read(node, "accessibilityLabel"), role: read(node, "accessibilityRole"),
                                  help: read(node, "accessibilityHelp"), value: read(node, "accessibilityValue")))
                let children: [Any] = node.responds(to: NSSelectorFromString("accessibilityChildren"))
                    ? (node.value(forKey: "accessibilityChildren") as? [Any] ?? []) : []
                for child in children { walk(child, depth: depth + 1) }
            }
            walk(host, depth: 0)
            return found
        }

        func node(_ identifier: String) -> Node? { nodes.first { $0.identifier == identifier } }

        /// VoiceOver's press on an element; the caller polls for its effect.
        func press(_ identifier: String) -> Bool {
            guard let node = node(identifier) else { return false }
            _ = node.object.perform(NSSelectorFromString("accessibilityPerformPress"))
            return true
        }

        /// Where the row ends, in the window's coordinates (y up): it is
        /// pinned to the window's top at its own height.
        var rowBottom: CGFloat { host.bounds.height - host.fittingSize.height }

        /// An element's frame in the window's coordinates. Exact for buttons;
        /// SwiftUI clips the row's and the sparkline's, so the tests sweep
        /// those areas by `rowBottom` instead.
        func frame(of node: Node?) -> NSRect? {
            guard let node, let screen = (node.object as? NSAccessibilityElementProtocol)?.accessibilityFrame(),
                  !screen.isEmpty else { return nil }
            return window.convertFromScreen(screen)
        }

        /// A left click at a point in the window's coordinates; the caller
        /// polls for its effect (or flushes, for a click that has none).
        func click(_ point: NSPoint) {
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure
                ) else { continue }
                window.sendEvent(event)
            }
        }
    }

    private struct RowNeverDrew: Error {}

    /// The row hosted and drawn: its accessibility tree has the chevron.
    private func hosted(
        _ presentation: AccountPresentation? = nil, expanded: Bool,
        switched: @escaping () -> Void = {}, stored: @escaping (Bool) -> Void
    ) throws -> Hosted {
        let row = Hosted(Harness(presentation: presentation ?? chatGPT(), now: now, samples: weeklySamples,
                                 stored: stored, switched: switched, expanded: expanded))
        guard row.waitUntil({ row.node("accountRowChevron") != nil }) else {
            row.close()
            throw RowNeverDrew()
        }
        return row
    }

    private var exactText: String { UsageFormatters.shortReset(resetsAt) }

    /// "Collapse 5x" while expanded, "Expand 5x" while folded.
    private func chevron(_ row: Hosted) -> String? { row.node("accountRowChevron")?.label }

    private func isExpanded(_ row: Hosted) -> Bool { chevron(row)?.hasPrefix("Collapse ") ?? false }
    private func isFolded(_ row: Hosted) -> Bool { chevron(row)?.hasPrefix("Expand ") ?? false }

    private func exactShows(_ row: Hosted) -> Bool { row.node("resetExact.weekly") != nil }

    /// Every click before this one has been handled: one on the weekly
    /// countdown shows the exact time and a second hides it, each polled
    /// for. Needs an expanded row with the exact time hidden — a row a
    /// stray click folded fails here too.
    private func flush(_ row: Hosted, file: StaticString = #filePath, line: UInt = #line) {
        guard let countdown = row.frame(of: row.node("resetCountdown.weekly")) else {
            XCTFail("flush: no countdown — the row folded, or never drew", file: file, line: line)
            return
        }
        let point = NSPoint(x: countdown.midX, y: countdown.midY)
        row.click(point)
        XCTAssertTrue(row.waitUntil { exactShows(row) }, "flush: the countdown did not show the exact time", file: file, line: line)
        row.click(point)
        XCTAssertTrue(row.waitUntil { !exactShows(row) }, "flush: the countdown did not hide the exact time", file: file, line: line)
    }

    // MARK: Accessibility

    /// Each countdown is a button again, as each gauge was before the
    /// compact rows: it speaks its gauge and carries the gauge's tooltip;
    /// the row keeps its one summary.
    func testTheCountdownIsAButtonWithItsGaugesHelp() throws {
        let row = try hosted(expanded: true) { _ in }
        defer { row.close() }
        XCTAssertTrue(row.waitUntil { row.node("resetCountdown.weekly") != nil },
                      "no countdown button: \(row.nodes.map(\.identifier))")
        let countdown = try XCTUnwrap(row.node("resetCountdown.weekly"))
        XCTAssertEqual(countdown.role, NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(countdown.help, LimitRowView.tooltip(title: "wk", window: weekly, now: now))
        XCTAssertEqual(countdown.label,
                       LimitRowView.accessibilityDescription(title: "wk", kind: .weekly, window: weekly, now: now))
        XCTAssertEqual(
            row.node("accountRow")?.label,
            AccountRowCopy.spokenRow(chatGPT(), phase: .none, mode: .expanded(sparklines: true, collapsible: true), now: now)
        )
    }

    /// Pressed twice, the countdown shows the exact time on its own line and
    /// then takes it away; the row stays expanded and nothing is stored.
    func testPressingTheCountdownTwiceTogglesTheExactTimeAndNeverFolds() throws {
        var stored: [Bool] = []
        let row = try hosted(expanded: true) { stored.append($0) }
        defer { row.close() }
        XCTAssertFalse(exactShows(row))

        XCTAssertTrue(row.press("resetCountdown.weekly"))
        XCTAssertTrue(row.waitUntil { row.node("resetExact.weekly")?.spoken == exactText }, "the press did not show the exact time")
        XCTAssertEqual(row.node("resetExact.weekly")?.role, NSAccessibility.Role.staticText.rawValue, "text, not a control")
        XCTAssertNotNil(row.node("resetCountdown.weekly"), "the countdown stays for the next click")
        XCTAssertTrue(isExpanded(row))

        XCTAssertTrue(row.press("resetCountdown.weekly"))
        XCTAssertTrue(row.waitUntil { !exactShows(row) }, "the second press did not hide the exact time")
        XCTAssertTrue(isExpanded(row))
        XCTAssertEqual(stored, [])
    }

    // MARK: Clicks

    /// The reported bug: the first click on a countdown showed the exact
    /// time, the second folded the row. Now the second click hides the
    /// exact time again; and a click on the exact time does nothing — the
    /// countdown's next click hides it.
    func testTheSecondClickOnTheCountdownHidesTheExactTime() throws {
        var stored: [Bool] = []
        let row = try hosted(expanded: true) { stored.append($0) }
        defer { row.close() }
        let countdown = try XCTUnwrap(row.frame(of: row.node("resetCountdown.weekly")), "no countdown")
        let point = NSPoint(x: countdown.midX, y: countdown.midY)

        row.click(point)
        XCTAssertTrue(row.waitUntil { row.node("resetExact.weekly")?.spoken == exactText }, "the first click shows the exact time")
        row.click(point)
        XCTAssertTrue(row.waitUntil { !exactShows(row) }, "the second click hides the exact time")
        XCTAssertTrue(isExpanded(row), "the second click folded the row")

        row.click(point)
        XCTAssertTrue(row.waitUntil { exactShows(row) })
        let exact = try XCTUnwrap(row.frame(of: row.node("resetExact.weekly")))
        row.click(NSPoint(x: exact.midX, y: exact.midY))
        row.click(point)
        XCTAssertTrue(row.waitUntil { !exactShows(row) },
                      "the countdown's click did not hide the exact time — the click on the exact time toggled it")
        XCTAssertTrue(isExpanded(row))
        XCTAssertEqual(stored, [])
    }

    /// Everything under the first line — the gauge's tag, percent and bar,
    /// the empty columns, the sparkline, the credits line and the row's
    /// bottom padding — swept point by point: no click folds the row.
    func testNoClickUnderTheFirstLineFoldsTheRow() throws {
        var stored: [Bool] = []
        let row = try hosted(expanded: true) { stored.append($0) }
        defer { row.close() }
        let countdown = try XCTUnwrap(row.frame(of: row.node("resetCountdown.weekly")), "no countdown")
        let sparkline: String = UsageSparkline.accessibilityText(samples: weeklySamples, projection: nil)
        let credits: String = CodexCreditsCopy.spoken(try XCTUnwrap(chatGPT().snapshot?.codexCredits))
        XCTAssertTrue(row.nodes.contains { $0.spoken == sparkline }, "the sweep must cross a sparkline")
        XCTAssertTrue(row.nodes.contains { $0.spoken == credits }, "the sweep must cross the credits line")

        // Left of the countdown (tag, percent, bar, sparkline) and across
        // the empty columns; the countdown itself has its own test.
        let columns: [CGFloat] = [AccountListMetrics.cardInset + 12, countdown.minX - 50,
                                  MenuBarView.popoverWidth / 2, MenuBarView.popoverWidth - 30]
        var clicks = 0
        for y in stride(from: row.rowBottom + 2, through: countdown.maxY - 1, by: 4) {
            for x in columns {
                row.click(NSPoint(x: x, y: y))
                clicks += 1
            }
        }
        XCTAssertGreaterThan(clicks, 40)
        flush(row)
        XCTAssertTrue(isExpanded(row))
        XCTAssertEqual(stored, [], "a click under the first line folded the row")
    }

    /// The row's first line — its name, plan tag and the empty space beside
    /// them — folds an expanded row; a click on the folded line expands it.
    /// One store per click, and the Switch is never touched.
    func testTheFirstLineFoldsAndTheFoldedLineExpands() throws {
        var stored: [Bool] = []
        var switches = 0
        let row = try hosted(expanded: true, switched: { switches += 1 }) { stored.append($0) }
        defer { row.close() }
        let chevron = try XCTUnwrap(row.frame(of: row.node("accountRowChevron")))
        let control = try XCTUnwrap(row.frame(of: row.node("useInCodexButton")))

        // Empty space on the first line, left of the Switch.
        row.click(NSPoint(x: control.minX - 40, y: chevron.midY))
        XCTAssertTrue(row.waitUntil { isFolded(row) }, "the row did not fold")
        XCTAssertEqual(stored, [false])

        // Folded, the whole line expands it again.
        let folded = try XCTUnwrap(row.frame(of: row.node("accountRowChevron")))
        row.click(NSPoint(x: MenuBarView.popoverWidth / 3, y: folded.midY))
        XCTAssertTrue(row.waitUntil { isExpanded(row) }, "the row did not expand")
        flush(row)
        XCTAssertEqual(stored, [false, true])
        XCTAssertEqual(switches, 0, "a click on the line reached the Switch")
    }

    /// A real click on the chevron, expanded then folded: the chevron's
    /// button takes it, not the line's tap under it as well — exactly one
    /// store per click.
    func testTheChevronTakesEachClickOnce() throws {
        var stored: [Bool] = []
        let row = try hosted(expanded: true) { stored.append($0) }
        defer { row.close() }

        let expanded = try XCTUnwrap(row.frame(of: row.node("accountRowChevron")))
        row.click(NSPoint(x: expanded.midX, y: expanded.midY))
        XCTAssertTrue(row.waitUntil { isFolded(row) }, "the chevron did not fold the row")
        XCTAssertEqual(stored, [false])

        let folded = try XCTUnwrap(row.frame(of: row.node("accountRowChevron")))
        row.click(NSPoint(x: folded.midX, y: folded.midY))
        XCTAssertTrue(row.waitUntil { isExpanded(row) }, "the chevron did not expand the row")
        flush(row)
        XCTAssertEqual(stored, [false, true], "a chevron click stored more than once")
    }

    /// The Switch on the first line takes its own click — Codex's on a
    /// ChatGPT row, Claude Code's on a Claude row: its action runs exactly
    /// once and the row stays.
    func testTheSwitchTakesItsOwnClickOnce() throws {
        for (presentation, identifier) in [(chatGPT(), "useInCodexButton"), (claude(), "useInClaudeCodeButton")] {
            var stored: [Bool] = []
            var switches = 0
            let row = try hosted(presentation, expanded: true, switched: { switches += 1 }) { stored.append($0) }
            defer { row.close() }
            let control = try XCTUnwrap(row.frame(of: row.node(identifier)), "no \(identifier)")
            row.click(NSPoint(x: control.midX, y: control.midY))
            XCTAssertTrue(row.waitUntil { switches > 0 }, "\(identifier): the click never reached the Switch")
            flush(row)
            XCTAssertEqual(switches, 1, identifier)
            XCTAssertEqual(stored, [], "\(identifier): the click folded the row")
            XCTAssertTrue(isExpanded(row), identifier)
        }
    }
}
