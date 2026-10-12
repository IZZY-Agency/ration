import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The popover with a live `CodexModel` (spec §4.4, §4.6): the CODEX tag and
/// SWITCH on the linked ChatGPT cards, the status line under the ChatGPT
/// header (a click opens Settings), the Focus line, and a redraw whenever the
/// model publishes. Walks the hosted popover's accessibility tree, as
/// `CodexViewsTests` does for the views alone.
@MainActor
final class MenuBarCodexWiringTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private let claudeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private var fixture: CodexLiveFixture?

    override func tearDown() async throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture = nil
    }

    // MARK: Fixture

    private func presentation(_ id: UUID, _ label: String, _ provider: Provider, order: Int, used: Double) -> AccountPresentation {
        AccountPresentation(
            account: AccountRecord(id: id, provider: provider, label: label, webProfileID: UUID(), displayOrder: order,
                                   createdAt: now.addingTimeInterval(-30 * 86_400)),
            snapshot: UsageSnapshot(accountID: id, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil,
                                    weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - used,
                                                        resetsAt: now.addingTimeInterval(2 * 86_400))),
            state: .current)
    }

    /// A Claude card, then ChatGPT "20x" (Codex's login A) and "5x" (login B).
    private var presentations: [AccountPresentation] {
        [presentation(claudeID, "Client", .claude, order: 0, used: 0.3),
         presentation(idA, "20x", .chatGPT, order: 1, used: 0.8),
         presentation(idB, "5x", .chatGPT, order: 2, used: 0.1)]
    }

    private func makeCodex(status: CodexStatus? = nil, current: Data? = CodexLiveFixture.bytesA) async throws -> CodexLiveFixture {
        var state = CodexState()
        state.links = [CodexLiveFixture.loginA: idA, CodexLiveFixture.loginB: idB]
        state.status = status
        let built = try await CodexLiveFixture.make(now: now, state: state, current: current, candidates: [
            CodexLiveFixture.candidate(idA, "20x", identity: CodexLiveFixture.identityA, used: 0.8, order: 1, now: now),
            CodexLiveFixture.candidate(idB, "5x", identity: CodexLiveFixture.identityB, used: 0.1, order: 2, now: now),
        ])
        fixture = built
        return built
    }

    private func popover(_ presentations: [AccountPresentation], codex: CodexModel?, layout: PopoverLayout = .standard,
                         onCodexStatus: @escaping () -> Void = {}) -> MenuBarView {
        MenuBarView(
            presentations: presentations, isRefreshing: false, profileCleanupBanner: nil, errorMessage: nil,
            activeAccounts: [:],
            onOpen: {}, onAddAccount: {}, onRefresh: {}, onSettings: {}, onAbout: {},
            onHistory: {}, onRetryProfileCleanup: {}, onQuit: {}, onReauthenticate: { _ in },
            layout: layout,
            focusModel: { [presentations] date in
                FocusModel.make(presentations: presentations, phases: [:], advice: [], fableCounts: { _ in false }, now: date)
            },
            pinnedNow: now,
            codex: codex,
            onCodexStatus: onCodexStatus
        )
    }

    // MARK: Accessibility walk

    private struct Element: Equatable {
        let identifier: String
        let label: String
    }

    /// A popover hosted in an offscreen window, walked as many times as a
    /// test needs (the model may publish in between).
    @MainActor
    private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow

        init(_ root: some View) {
            view = NSHostingView(rootView: AnyView(root.frame(width: MenuBarView.popoverWidth, height: 900)))
            view.frame = NSRect(x: 0, y: 0, width: MenuBarView.popoverWidth, height: 900)
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// Every node with an identifier, depth first, read with the app marked
    /// as serving an assistive client (SwiftUI builds the tree only then).
    private func walk(_ host: Host) -> (nodes: [String: NSObject], elements: [Element]) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.view.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: enhanced.rawValue)?
            .takeUnretainedValue() as? Bool ?? false
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: enhanced.rawValue)
        defer {
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: previous), with: enhanced.rawValue)
        }
        var nodes: [String: NSObject] = [:]
        var elements: [Element] = []
        func read<V>(_ object: NSObject, _ selector: String, key: String) -> V? {
            object.responds(to: NSSelectorFromString(selector)) ? object.value(forKey: key) as? V : nil
        }
        func visit(_ object: Any, depth: Int) {
            guard depth < 80, let node = object as? NSObject else { return }
            let identifier: String = read(node, "accessibilityIdentifier", key: "accessibilityIdentifier") ?? ""
            if !identifier.isEmpty {
                if nodes[identifier] == nil { nodes[identifier] = node }
                elements.append(Element(identifier: identifier,
                                        label: read(node, "accessibilityLabel", key: "accessibilityLabel") ?? ""))
            }
            let children: [Any] = read(node, "accessibilityChildren", key: "accessibilityChildren") ?? []
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(host.view, depth: 0)
        return (nodes, elements)
    }

    private func identifiers(_ host: Host) -> [String] { walk(host).elements.map(\.identifier) }

    private func press(_ identifier: String, in host: Host) -> Bool {
        let (nodes, _) = walk(host)
        guard let node = nodes[identifier] else { return false }
        _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return true
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Standard layout

    func testTheCardsCarryTheCodexTagAndSwitch() async throws {
        let codex = try await makeCodex()
        let host = Host(popover(presentations, codex: codex.model))
        defer { host.close() }

        let elements = walk(host).elements
        XCTAssertEqual(elements.filter { $0.identifier == "codexCurrentTag" }.count, 1, "one card is Codex's")
        XCTAssertEqual(elements.filter { $0.identifier == "useInCodexButton" }.map(\.label), ["Switch Codex to 5x"])
    }

    func testWithoutAModelNoCodexControlIsDrawn() async throws {
        let host = Host(popover(presentations, codex: nil))
        defer { host.close() }

        let found = identifiers(host)
        XCTAssertFalse(found.contains("codexCurrentTag"))
        XCTAssertFalse(found.contains("useInCodexButton"))
        XCTAssertFalse(found.contains("codexStatusLine"))
    }

    func testTheStatusLineSitsUnderTheChatGPTHeaderAndOpensSettings() async throws {
        let codex = try await makeCodex(status: .switched(at: now.addingTimeInterval(-120), from: CodexLiveFixture.loginB,
                                                          to: CodexLiveFixture.loginA, automatic: true))
        var opened = 0
        let host = Host(popover(presentations, codex: codex.model, onCodexStatus: { opened += 1 }))
        defer { host.close() }

        let found = identifiers(host)
        XCTAssertEqual(found.filter { $0 == "codexStatusLine" }.count, 1)
        let line = try XCTUnwrap(found.firstIndex(of: "codexStatusLine"))
        let tag = try XCTUnwrap(found.firstIndex(of: "codexCurrentTag"))
        XCTAssertLessThan(line, tag, "above the ChatGPT cards, under their header")
        XCTAssertTrue(press("codexStatusLine", in: host))
        XCTAssertEqual(opened, 1)
    }

    func testNoChatGPTCardMeansNoStatusLine() async throws {
        let codex = try await makeCodex(status: .switched(at: now.addingTimeInterval(-120), from: CodexLiveFixture.loginB,
                                                          to: CodexLiveFixture.loginA, automatic: false))
        let host = Host(popover(presentations.filter { $0.account.provider == .claude }, codex: codex.model))
        defer { host.close() }

        XCTAssertFalse(identifiers(host).contains("codexStatusLine"), "it belongs under the ChatGPT header")
    }

    /// SWITCH runs the switch; the popover redraws from the model (the tag
    /// moves, the status line appears) without being rebuilt.
    func testSwitchRunsTheSwitchAndThePopoverRedraws() async throws {
        let codex = try await makeCodex()
        let host = Host(popover(presentations, codex: codex.model))
        defer { host.close() }
        XCTAssertFalse(identifiers(host).contains("codexStatusLine"), "premise: nothing to report yet")

        XCTAssertTrue(press("useInCodexButton", in: host))
        await waitFor { codex.file.writes.count == 1 }
        await codex.model.waitUntilIdle()

        XCTAssertEqual(codex.file.writes, [CodexLiveFixture.bytesB])
        XCTAssertEqual(codex.model.current?.id, CodexLiveFixture.loginB)
        let elements = walk(host).elements
        XCTAssertEqual(elements.filter { $0.identifier == "useInCodexButton" }.map(\.label), ["Switch Codex to 20x"])
        XCTAssertTrue(elements.contains { $0.identifier == "codexStatusLine" })
    }

    // MARK: Focus layout

    func testTheFocusLineOffersTheAccountWithTheMostRoomAndSwitches() async throws {
        let codex = try await makeCodex()
        let host = Host(popover(presentations, codex: codex.model, layout: .focus))
        defer { host.close() }

        let elements = walk(host).elements
        XCTAssertTrue(elements.contains { $0.identifier == "focusCodexLine" })
        // The button's uppercase text case reaches its label; the words matter.
        XCTAssertTrue(elements.contains { $0.identifier == "focusCodexSwitch" && $0.label.lowercased() == "switch codex to 5x" })

        XCTAssertTrue(press("focusCodexSwitch", in: host))
        await waitFor { codex.file.writes.count == 1 }
        await codex.model.waitUntilIdle()
        XCTAssertEqual(codex.model.current?.id, CodexLiveFixture.loginB)
    }

    /// Focus shows the status line too, whether or not Codex has
    /// a login to name: a switch that needs attention is never hidden by the
    /// layout. A click opens Settings, as in the list.
    func testFocusShowsTheStatusLineWithoutACurrentLogin() async throws {
        let codex = try await makeCodex(status: .needsAttention(at: now), current: nil)
        XCTAssertNil(codex.model.current, "premise: Codex has no login to name")
        var opened = 0
        let host = Host(popover(presentations, codex: codex.model, layout: .focus, onCodexStatus: { opened += 1 }))
        defer { host.close() }

        let elements = walk(host).elements
        XCTAssertFalse(elements.contains { $0.identifier == "focusCodexLine" }, "no login, no Codex line")
        XCTAssertEqual(elements.filter { $0.identifier == "codexStatusLine" }.map(\.label), ["Codex’s sign-in needs attention"])
        XCTAssertTrue(press("codexStatusLine", in: host))
        XCTAssertEqual(opened, 1)
    }

    /// A damaged file clears the current login; Focus still says what is wrong.
    func testFocusShowsADamagedFile() async throws {
        let mixed = CodexFixtures.file(idToken: CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: "user-1")),
                                       tokensAccountID: "acct-B", refreshToken: "rt-A-2")
        let codex = try await makeCodex(current: mixed)
        XCTAssertNil(codex.model.current)
        let host = Host(popover(presentations, codex: codex.model, layout: .focus))
        defer { host.close() }

        XCTAssertEqual(walk(host).elements.filter { $0.identifier == "codexStatusLine" }.map(\.label),
                       ["Codex’s sign-in file mixes two accounts — run codex login"])
    }

    /// With a login, the status line sits right under Codex's Focus line.
    func testFocusShowsTheStatusLineUnderTheCodexLine() async throws {
        let codex = try await makeCodex(status: .switched(at: now.addingTimeInterval(-120), from: CodexLiveFixture.loginB,
                                                          to: CodexLiveFixture.loginA, automatic: false))
        let host = Host(popover(presentations, codex: codex.model, layout: .focus))
        defer { host.close() }

        let found = identifiers(host)
        let line = try XCTUnwrap(found.firstIndex(of: "focusCodexLine"), "\(found)")
        let status = try XCTUnwrap(found.firstIndex(of: "codexStatusLine"), "\(found)")
        XCTAssertLessThan(line, status)
    }

    // MARK: Order-independent setter

    func testWithCodexSetsTheModelAndTheStatusAction() async throws {
        let codex = try await makeCodex()
        var opened = 0
        let view = popover(presentations, codex: nil).withCodex(codex.model, onStatus: { opened += 1 })
        XCTAssertTrue(view.codex === codex.model)
        view.onCodexStatus()
        XCTAssertEqual(opened, 1)
    }
}
