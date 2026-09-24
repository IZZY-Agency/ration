import AppKit
import XCTest
@testable import Ration

@MainActor
final class AppearanceControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var savedAppAppearance: NSAppearance?
    /// `apply()` restyles EVERY existing window, not just the app — so each
    /// window the host already had is snapshotted and put back, or a test
    /// here would leave, say, the host's windows forced Dark for later tests.
    private var savedWindowAppearances: [(NSWindow, NSAppearance?)] = []

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "AppearanceControllerTests-\(UUID())")
        savedAppAppearance = NSApp.appearance
        savedWindowAppearances = NSApp.windows.map { ($0, $0.appearance) }
    }
    override func tearDown() async throws {
        NSApp.appearance = savedAppAppearance
        for (window, appearance) in savedWindowAppearances { window.appearance = appearance }
        savedWindowAppearances = []
    }

    func testMissingValueIsSystem() {
        XCTAssertEqual(AppearanceController(defaults: defaults).mode, .system)
    }

    func testUnknownValueIsSystem() {
        defaults.set("sepia", forKey: AppearanceController.defaultsKey)
        XCTAssertEqual(AppearanceController(defaults: defaults).mode, .system)
    }

    func testSetModePersistsAndSurvivesRelaunch() {
        AppearanceController(defaults: defaults).setMode(.light)
        XCTAssertEqual(AppearanceController(defaults: defaults).mode, .light)
    }

    func testModeMapsToAppAppearance() {
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    /// Saved Dark must be in force before ANY window exists (read
    /// synchronously — no async settings hydration in the way).
    func testSavedDarkAppliesBeforeAnyWindow() {
        defaults.set("dark", forKey: AppearanceController.defaultsKey)
        let controller = AppearanceController(defaults: defaults)
        controller.apply()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    /// Open windows restyle in place; listeners (popover, drop panel, status
    /// icon) hear every apply, including the return to System.
    func testSetModeRestylesOpenWindowsAndNotifiesListeners() {
        let controller = AppearanceController(defaults: defaults)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: true)
        // Programmatic NSWindows default to release-on-close, which under ARC
        // over-releases the window when the test's autorelease pool drains.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        var heard: [NSAppearance.Name?] = []
        let id = controller.addApplyListener { heard.append($0?.name) }
        controller.setMode(.light)
        XCTAssertEqual(window.appearance?.name, .aqua)
        controller.setMode(.dark)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        controller.setMode(.system)
        XCTAssertNil(window.appearance)
        XCTAssertEqual(heard, [.aqua, .darkAqua, nil])
        controller.removeApplyListener(id)
        controller.setMode(.light)
        XCTAssertEqual(heard.count, 3)
    }

    /// The menu bar owns its status items' appearance (it follows the bar,
    /// not the app). Restyling `NSApp.windows` must skip the status-bar
    /// window, or a template icon draws dark-on-dark after a live switch.
    func testSetModeLeavesStatusItemAppearanceAlone() throws {
        let statusBar = NSStatusBar.system
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        defer { statusBar.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)
        let window = try XCTUnwrap(button.window)
        let before = button.effectiveAppearance.name
        let controller = AppearanceController(defaults: defaults)

        controller.setMode(.light)
        XCTAssertEqual(button.effectiveAppearance.name, before)
        XCTAssertNil(window.appearance)
        controller.setMode(.dark)
        XCTAssertEqual(button.effectiveAppearance.name, before)
        XCTAssertNil(window.appearance)
    }

    /// Toggling Increase Contrast must restyle what is open: the change
    /// arrives on NSWorkspace's centre, and every apply listener (popover,
    /// drop, status icon) hears it.
    func testIncreaseContrastChangeReappliesAndNotifiesListeners() {
        let center = NotificationCenter()
        let controller = AppearanceController(defaults: defaults, workspaceNotificationCenter: center)
        var heard = 0
        controller.addApplyListener { _ in heard += 1 }
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(heard, 1)
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(heard, 2)
    }
}
