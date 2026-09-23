import AppKit
import XCTest
@testable import Ration

final class DockPresenceTests: XCTestCase {
    private func window(
        visible: Bool = true,
        miniaturized: Bool = false,
        titled: Bool = true,
        panel: Bool = false
    ) -> DockPresence.WindowTraits {
        DockPresence.WindowTraits(
            isVisible: visible,
            isMiniaturized: miniaturized,
            isTitled: titled,
            isPanel: panel
        )
    }

    func testMenuBarOnlyWhenNothingIsOpen() {
        XCTAssertEqual(DockPresence.policy(for: []), .accessory)
    }

    func testAVisibleTitledWindowPutsRationInTheDockAndCommandTab() {
        XCTAssertEqual(DockPresence.policy(for: [window()]), .regular)
    }

    func testAMinimizedWindowStillNeedsTheDockToComeBack() {
        XCTAssertEqual(DockPresence.policy(for: [window(visible: false, miniaturized: true)]), .regular)
    }

    func testClosedOrHiddenWindowsDoNotCount() {
        XCTAssertEqual(DockPresence.policy(for: [window(visible: false)]), .accessory)
    }

    func testChromeWindowsDoNotCount() {
        // The attention drop is an NSPanel; the popover and the status item
        // live in borderless (untitled) windows.
        XCTAssertEqual(
            DockPresence.policy(for: [window(panel: true), window(titled: false)]),
            .accessory
        )
    }

    func testOneRealWindowAmongChromeIsEnough() {
        XCTAssertEqual(
            DockPresence.policy(for: [window(titled: false), window(panel: true), window()]),
            .regular
        )
    }
}

final class DockPresenceReopenTests: XCTestCase {
    func testDockClickWithAVisibleWindowLetsAppKitBringItForward() {
        XCTAssertEqual(
            DockPresence.reopenAction(hasVisibleWindows: true, hasMiniaturizedWindow: true),
            .bringExistingForward
        )
    }

    func testDockClickRestoresAMinimizedWindowInsteadOfOpeningTheDashboard() {
        XCTAssertEqual(
            DockPresence.reopenAction(hasVisibleWindows: false, hasMiniaturizedWindow: true),
            .deminiaturize
        )
    }

    func testDockClickWithNoWindowsOpensTheDashboard() {
        XCTAssertEqual(
            DockPresence.reopenAction(hasVisibleWindows: false, hasMiniaturizedWindow: false),
            .showFallback
        )
    }
}
