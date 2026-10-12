import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The app hands the Codex model to every surface that shows it: the
/// delegate to the menu-bar controller, the controller to the popover and
/// to Settings, the SwiftUI scenes likewise; the popover's status line opens
/// Settings on Codex. A model over the fakes: nothing here reads the real
/// `~/.codex` or the Keychain (the live stack starts only outside the
/// unit-test host).
@MainActor
final class CodexAppWiringTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private var codexFixture: CodexLiveFixture?

    override func tearDown() async throws {
        if let codexFixture { try? FileManager.default.removeItem(at: codexFixture.directory) }
        codexFixture = nil
    }

    private func makeCodex() async throws -> CodexModel {
        let built = try await CodexLiveFixture.make(now: now, state: CodexState(), candidates: [])
        codexFixture = built
        return built.model
    }

    private func content(_ fixture: AlertsFixture, codex: CodexModel?, onSettings: @escaping () -> Void = {},
                         onSettingsSelecting: ((SettingsSelection) -> Void)? = nil) -> MenuBarContent {
        MenuBarContent(
            model: fixture.model, history: fixture.model.history, pinSnapshot: AccountPinSnapshot(),
            settings: fixture.model.settings,
            onAddAccount: {}, onSettings: onSettings, onAbout: {}, onHistory: {}, onOpenSignIn: { _ in },
            onOpenSetupGuide: {}, attentionPresence: AttentionDropPresence(),
            onSettingsSelecting: onSettingsSelecting,
            codex: codex
        )
    }

    // MARK: SwiftUI scenes

    func testThePopoverContentCarriesTheModel() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let codex = try await makeCodex()

        XCTAssertTrue(content(fixture, codex: codex).menuBarView.codex === codex)
    }

    func testTheStatusLineOpensSettingsOnCodex() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let codex = try await makeCodex()
        var selected: [SettingsSelection] = []
        var plain = 0

        content(fixture, codex: codex, onSettings: { plain += 1 }, onSettingsSelecting: { selected.append($0) })
            .menuBarView.onCodexStatus()
        XCTAssertEqual(selected, [.codex])
        XCTAssertEqual(plain, 0)

        // The SwiftUI scene has no pane routing: plain Settings.
        content(fixture, codex: codex, onSettings: { plain += 1 }).menuBarView.onCodexStatus()
        XCTAssertEqual(plain, 1)
    }

    func testTheSettingsSceneCarriesTheModel() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let codex = try await makeCodex()

        let settings = SettingsWindowContent(model: fixture.model, launchAtLogin: LaunchAtLoginController(),
                                             appearance: AppearanceController(), onOpenSetupGuide: {}, codex: codex)

        XCTAssertTrue(settings.settingsView.codex === codex)
    }

    // MARK: Menu-bar controller and delegate

    func testTheControllerHandsTheModelToThePopoverAndSettings() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let codex = try await makeCodex()
        let controller = MenuBarController(model: fixture.model, launchAtLogin: LaunchAtLoginController(),
                                           popover: QuietPopover(), hotKeyRegistrar: HotKeyRegistrarSpy(),
                                           codex: codex, statusItemIsAnchored: { true })
        defer { controller.stop() }

        XCTAssertTrue(controller.makeMenuBarContent(pinSnapshot: AccountPinSnapshot()).menuBarView.codex === codex)

        controller.showSettings(selecting: .codex)
        defer { controller.settingsWindowForTesting?.close() }
        let hosting = try XCTUnwrap(controller.settingsWindowForTesting?.contentViewController as? NSHostingController<SettingsView>)
        XCTAssertTrue(hosting.rootView.codex === codex)
        XCTAssertEqual(controller.requestedSettingsSelection, .codex)
    }

    func testTheDelegateHandsTheModelToTheMenuBar() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let codex = try await makeCodex()
        let delegate = RationApplicationDelegate()
        // The delegate holds these weakly, as the app's state objects own them.
        let launchAtLogin = LaunchAtLoginController()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        delegate.configure(model: fixture.model, launchAtLogin: launchAtLogin,
                           hotKeyRegistrar: HotKeyRegistrarSpy(), codex: codex)
        XCTAssertTrue(delegate.codex === codex)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let controller = try XCTUnwrap(delegate.menuBarController)
        XCTAssertTrue(controller.makeMenuBarContent(pinSnapshot: AccountPinSnapshot()).menuBarView.codex === codex)
    }
}

/// Never shows: no real popover in tests.
@MainActor
private final class QuietPopover: PopoverPresenting {
    private(set) var isShown = false
    var behavior: NSPopover.Behavior = .transient
    var contentViewController: NSViewController?
    var appearance: NSAppearance?
    var hasFullSizeContent = false
    weak var delegate: (any NSPopoverDelegate)?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {}
    func performClose(_ sender: Any?) { isShown = false }
    func close() { isShown = false }
}
