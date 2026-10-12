import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Settings › Codex (Codex spec §4.2, §4.3, §4.7, §5): the pane's place,
/// its pure helpers, and — hosted over a live model on the fakes — what it
/// enables and says: automatic switching only after the configuration
/// acknowledgement, Forget blocked while a switch needs attention, the
/// validity line on an old copy, Verified / Chosen.
@MainActor
final class CodexSettingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private var fixture: CodexLiveFixture?

    override func tearDown() async throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture = nil
    }

    // MARK: Place

    func testThePaneSurvivesAccountChanges() {
        XCTAssertEqual(SettingsSelection.normalized(.codex, accounts: []), .codex)
    }

    func testTheSidebarListsCodexAfterClaudeCodeWithItsGlyph() {
        let items = SettingsSidebar.fixedGroups(locale: Locale(identifier: "en")).flatMap { $0 }
        XCTAssertEqual(items.suffix(2).map(\.selection), [.claudeCode, .codex])
        let item = items.first { $0.selection == .codex }
        XCTAssertEqual(item?.title, "Codex")
        XCTAssertEqual(item?.systemImage, CodexSymbol.name)
        XCTAssertEqual(item?.accessibilityIdentifier, "codexSettingsItem")
    }

    // MARK: Pure helpers

    private func candidate(_ id: UUID, _ identity: ChatGPTIdentity?) -> CodexCandidate {
        CodexCandidate(accountID: id, label: "L", identity: identity, isPaused: false, usable: true,
                       snapshot: nil, planUnits: nil, order: 0)
    }

    /// The Remember sheet preselects the one account whose session is this
    /// login: the account id AND the user id (two seats share the account id).
    func testTheSheetSuggestsTheAccountWithTheSameIdentity() {
        let login = CodexFixtures.login(CodexLiveFixture.bytesA)
        let otherSeat = ChatGPTIdentity(accountID: "acct-A", userID: "user-9", email: nil, planType: nil)
        XCTAssertEqual(CodexDetailView.suggestedLink(for: login, candidates: [
            candidate(idB, otherSeat), candidate(idA, CodexLiveFixture.identityA),
        ]), idA)
        XCTAssertNil(CodexDetailView.suggestedLink(for: login, candidates: [candidate(idA, otherSeat)]),
                     "another seat of the workspace is not this login")
        XCTAssertNil(CodexDetailView.suggestedLink(for: login, candidates: [
            candidate(idA, CodexLiveFixture.identityA), candidate(idB, CodexLiveFixture.identityA),
        ]), "two matches: the user chooses")
        XCTAssertNil(CodexDetailView.suggestedLink(for: login, candidates: [candidate(idA, nil)]), "no identity, no suggestion")
    }

    func testEveryFailureHasItsMessage() {
        let en = Locale(identifier: "en")
        let cases: [(CodexSwitcher.Failure, LocalizedStringResource)] = [
            (.notSignedIn, .codexErrorNotSignedIn),
            (.unsupported, .codexErrorUnsupported),
            (.unreadable, .codexErrorChanging),
            (.damaged, .codexStatusDamaged),
            (.signInChanging, .codexErrorChanging),
            (.leftAccountNotRemembered(CodexFixtures.login(CodexLiveFixture.bytesA)), .codexErrorRememberFirst),
            (.targetNotRemembered, .codexErrorFailed),
            (.journalUnresolved, .codexErrorNeedsAttention),
            (.conflict, .codexErrorConflict),
            (.failed, .codexErrorFailed),
            (.needsAttention, .codexErrorNeedsAttention),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(CodexDetailView.message(for: failure).string(in: en), expected.string(in: en), "\(failure)")
        }
    }

    /// Every status the model can save has its Last event line, the stale one
    /// naming the account by the label the user knows.
    func testEveryStatusHasALastEventLine() {
        let en = Locale(identifier: "en")
        let at = now
        let label: (String) -> String = { $0 == CodexLiveFixture.loginB ? "5x" : "20x" }
        let cases: [(CodexStatus, String)] = [
            (.switched(at: at, from: CodexLiveFixture.loginA, to: CodexLiveFixture.loginB, automatic: true),
             "Codex switched to 5x automatically — restart running sessions"),
            (.switched(at: at, from: CodexLiveFixture.loginA, to: CodexLiveFixture.loginB, automatic: false),
             "Codex now uses 5x — restart running sessions"),
            (.switched(at: at, from: CodexLiveFixture.loginA, to: CodexLiveFixture.loginB, automatic: true, verified: false),
             "Codex now uses 5x — it refreshed its sign-in meanwhile; restart running sessions"),
            (.switched(at: at, from: CodexLiveFixture.loginA, to: CodexLiveFixture.loginB, automatic: false, sameWorkspace: true),
             "Codex now uses 5x — same workspace: running sessions may follow; restart to be sure"),
            (.failed(at: at), "The switch didn’t go through and was undone."),
            (.conflict(at: at), "Codex signed in to another account during the switch; Ration left it as it is."),
            (.needsAttention(at: at), "Ration couldn’t fully undo a switch. Run codex login to be safe."),
            (.noRoom(at: at), "No remembered ChatGPT account has room"),
            (.waiting(at: at), "Waiting for fresh usage to switch Codex"),
            (.paused(at: at), "Automatic Codex switching is paused"),
            (.stale(at: at, login: CodexLiveFixture.loginB), "Sign in to 5x in Codex, then Remember it again"),
            (.damaged(at: at), "Codex’s sign-in file mixes two accounts — run codex login"),
        ]
        for (status, text) in cases {
            let (resource, date, _) = CodexDetailView.statusText(status, label: label)
            XCTAssertEqual(resource.string(in: en), text, "\(status)")
            XCTAssertEqual(date, at)
        }
    }

    /// A switch with a caveat — another seat of the
    /// workspace, or Codex refreshing meanwhile — is amber, as in the
    /// popover; a plain switch stays teal.
    func testASwitchWithACaveatIsAmberInLastEvent() {
        let label: (String) -> String = { _ in "5x" }
        let seat = CodexStatus.switched(at: now, from: "acct-X|user-1", to: "acct-X|user-2", automatic: false, sameWorkspace: true)
        XCTAssertEqual(CodexDetailView.statusText(seat, label: label).2, Theme.warn)
        for automatic in [true, false] {
            let unverified = CodexStatus.switched(at: now, from: CodexLiveFixture.loginA, to: CodexLiveFixture.loginB,
                                                  automatic: automatic, verified: false)
            XCTAssertEqual(CodexDetailView.statusText(unverified, label: label).2, Theme.warn, "automatic: \(automatic)")
        }
        let plain = CodexStatus.switched(at: now, from: CodexLiveFixture.loginA, to: CodexLiveFixture.loginB, automatic: false)
        XCTAssertEqual(CodexDetailView.statusText(plain, label: label).2, Theme.codex)
    }

    func testThePlanReadsAsTheCardsName() {
        XCTAssertEqual(CodexDetailView.planName("pro"), "Pro 20x")
        XCTAssertEqual(CodexDetailView.planName("prolite"), "Pro 5x")
        XCTAssertEqual(CodexDetailView.planName("plus"), "Plus")
        XCTAssertEqual(CodexDetailView.planName("team"), "team", "an unknown plan is shown as Codex names it")
        XCTAssertNil(CodexDetailView.planName(nil))
        XCTAssertNil(CodexDetailView.planName(""))
    }

    /// Any whole percent: ChatGPT reports the weekly limit only, no 5% grid.
    func testTheThresholdRunsFrom1To99() {
        XCTAssertEqual(CodexDetailView.percentRange, 1...99)
    }

    // MARK: Hosted pane

    /// Codex on A (verified: the 20x session is A); B linked to 5x by choice
    /// (its session reports no identity) and saved 8 days ago.
    private func makeModel(acknowledged: Bool = false, paused: Bool = false, status: CodexStatus? = nil,
                           current: Data? = CodexLiveFixture.bytesA) async throws -> CodexModel {
        var state = CodexState()
        state.links = [CodexLiveFixture.loginA: idA, CodexLiveFixture.loginB: idB]
        state.configurationAcknowledged = acknowledged
        state.autoSwitchPaused = paused
        state.status = status
        let built = try await CodexLiveFixture.make(now: now, state: state, current: current, bSavedAgo: 8 * 86_400, candidates: [
            CodexLiveFixture.candidate(idA, "20x", identity: CodexLiveFixture.identityA, used: 0.8, order: 1, now: now),
            CodexLiveFixture.candidate(idB, "5x", identity: nil, used: 0.1, order: 2, now: now),
        ])
        fixture = built
        return built.model
    }

    private struct Element: Equatable {
        let identifier: String
        let enabled: Bool
    }

    @MainActor
    private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow

        init(_ root: some View) {
            let frame = NSRect(x: 0, y: 0, width: 560, height: 1_900)
            view = NSHostingView(rootView: AnyView(root.frame(width: frame.width, height: frame.height)))
            view.frame = frame
            window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// Every node with an identifier, read as an assistive client would.
    private func walk(_ host: Host) -> (nodes: [String: NSObject], elements: [Element]) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
                                        enabled: read(node, "isAccessibilityEnabled", key: "accessibilityEnabled") ?? false))
            }
            let children: [Any] = read(node, "accessibilityChildren", key: "accessibilityChildren") ?? []
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(host.view, depth: 0)
        return (nodes, elements)
    }

    private func elements(_ id: String, in host: Host) -> [Element] {
        walk(host).elements.filter { $0.identifier == id }
    }

    func testAutomaticSwitchingWaitsForTheAcknowledgement() async throws {
        let model = try await makeModel(acknowledged: false)
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexAcknowledgeToggle", in: host).map(\.enabled), [true])
        XCTAssertEqual(elements("codexAutoToggle", in: host).map(\.enabled), [false])
        XCTAssertEqual(elements("codexNeedsAcknowledge", in: host).count, 1)
        XCTAssertEqual(elements("codexPercentStepper", in: host).count, 1)

        // The acknowledgement line writes through the model; the toggle follows.
        let toggle = try XCTUnwrap(walk(host).nodes["codexAcknowledgeToggle"])
        _ = toggle.perform(NSSelectorFromString("accessibilityPerformPress"))
        for _ in 0..<200 where !model.state.configurationAcknowledged { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.state.configurationAcknowledged)
        XCTAssertEqual(elements("codexAutoToggle", in: host).map(\.enabled), [true])
        XCTAssertTrue(elements("codexNeedsAcknowledge", in: host).isEmpty)
    }

    func testRememberedSignInsShowTheirLinksAndValidity() async throws {
        let model = try await makeModel(acknowledged: true)
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexLinkVerified", in: host).count, 1, "A: the 20x session is this login")
        XCTAssertEqual(elements("codexLinkChosen", in: host).count, 1, "B: linked by the user")
        XCTAssertEqual(elements("codexValidityUnknown", in: host).count, 1, "B was saved 8 days ago")
        XCTAssertEqual(elements("codexSwitchButton", in: host).map(\.enabled), [true], "Switch on the login Codex is not on")
        XCTAssertEqual(elements("codexForgetButton", in: host).map(\.enabled), [true, true])
        XCTAssertTrue(elements("codexForgetBlocked", in: host).isEmpty)
        XCTAssertTrue(elements("codexRememberButton", in: host).isEmpty, "Codex's login is remembered")
        XCTAssertEqual(elements("codexRestartLine", in: host).count, 1)
    }

    /// Spec §4.1: while a switch needs attention nothing is switched or
    /// forgotten until Resume (after `codex login`).
    func testANeedsAttentionSwitchBlocksForgetUntilResume() async throws {
        let model = try await makeModel(acknowledged: true, status: .needsAttention(at: now))
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexLastEvent", in: host).count, 1)
        XCTAssertEqual(elements("codexForgetButton", in: host).map(\.enabled), [false, false])
        XCTAssertEqual(elements("codexSwitchButton", in: host).map(\.enabled), [false])
        XCTAssertEqual(elements("codexForgetBlocked", in: host).count, 1)
        XCTAssertEqual(elements("codexForgetAllButton", in: host).map(\.enabled), [false])
        XCTAssertEqual(elements("codexResumeButton", in: host).count, 1, "the way out")
    }

    func testAPausedRuleOffersResume() async throws {
        let model = try await makeModel(acknowledged: true, paused: true)
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexResumeButton", in: host).count, 1)
        XCTAssertEqual(elements("codexForgetButton", in: host).map(\.enabled), [true, true], "a pause alone blocks nothing")
    }

    /// A remembered current login can be remembered again — after
    /// signing in to it anew in Codex, the stale hint's way out — keeping its
    /// link; the copy is renewed and no longer stale.
    func testARememberedLoginCanBeRememberedAgainKeepingItsLink() async throws {
        var state = CodexState()
        state.links = [CodexLiveFixture.loginA: idA, CodexLiveFixture.loginB: idB]
        state.staleLogins = [CodexLiveFixture.loginA]
        let built = try await CodexLiveFixture.make(now: now, state: state, candidates: [
            CodexLiveFixture.candidate(idA, "20x", identity: nil, used: 0.8, order: 1, now: now),
            CodexLiveFixture.candidate(idB, "5x", identity: CodexLiveFixture.identityB, used: 0.1, order: 2, now: now),
        ])
        fixture = built
        let model = built.model
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexRememberAgainButton", in: host).map(\.enabled), [true])
        XCTAssertTrue(elements("codexRememberButton", in: host).isEmpty, "not the sheet: nothing to choose")
        let button = try XCTUnwrap(walk(host).nodes["codexRememberAgainButton"])
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        for _ in 0..<400 where !model.state.staleLogins.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await model.waitUntilIdle()

        XCTAssertEqual(model.state.staleLogins, [])
        XCTAssertEqual(model.state.links, [CodexLiveFixture.loginA: idA, CodexLiveFixture.loginB: idB], "the link is kept")
        XCTAssertEqual(built.store.items[CodexLiveFixture.loginA]?.savedAt, now, "a fresh copy")
    }

    func testAnUnrememberedLoginOffersRemember() async throws {
        let other = CodexFixtures.authJSON(accountID: "acct-C", userID: "user-3", email: "c@example.com", refreshToken: "rt-C")
        let model = try await makeModel(current: other)
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexRememberButton", in: host).map(\.enabled), [true])
        XCTAssertTrue(elements("codexNowNone", in: host).isEmpty)
    }

    func testNoLoginSaysSo() async throws {
        let model = try await makeModel(current: nil)
        let host = Host(CodexDetailView(model: model))
        defer { host.close() }

        XCTAssertEqual(elements("codexNowNone", in: host).count, 1)
        XCTAssertTrue(elements("codexRememberButton", in: host).isEmpty)
    }
}
