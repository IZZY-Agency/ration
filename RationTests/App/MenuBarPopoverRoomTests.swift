import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The controller tells each surface how tall it may be on the screen it
/// opens on (`popoverAvailableHeight`), and asks again every time the surface
/// is about to show — the next opening can be on a different screen.
@MainActor
final class MenuBarPopoverRoomTests: XCTestCase {
    /// The screen the controller asks about; a test moves it between showings.
    private final class ScreenBox {
        var visibleFrame: NSRect
        init(_ frame: NSRect) { visibleFrame = frame }
    }

    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 945)
    private let external = NSRect(x: 1512, y: -200, width: 2560, height: 1415)

    private func room(_ visibleHeight: CGFloat) -> CGFloat {
        visibleHeight - AccountListMetrics.surfaceFrame - AccountListMetrics.screenMargin
    }

    private func makeController(_ fixture: AlertsFixture, popover: RoomPopoverSpy, screen: ScreenBox) -> MenuBarController {
        MenuBarController(model: fixture.model, launchAtLogin: LaunchAtLoginController(),
                          popover: popover, hotKeyRegistrar: HotKeyRegistrarSpy(),
                          makePopoverHotKeyRegistrar: { HotKeyRegistrarSpy() },
                          statusItemIsAnchored: { true },
                          screenVisibleFrame: { screen.visibleFrame })
    }

    private func content(of controller: NSViewController?) throws -> MenuBarContent {
        try XCTUnwrap((controller as? NSHostingController<MenuBarContent>)?.rootView)
    }

    func testThePopoverGetsTheRoomOfTheScreenItOpensOn() throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let popover = RoomPopoverSpy()
        let screen = ScreenBox(laptop)
        let controller = makeController(fixture, popover: popover, screen: screen)
        controller.start()
        defer { controller.stop() }

        controller.presentDashboard()
        XCTAssertTrue(popover.isShown)
        let content = try content(of: popover.contentViewController)
        XCTAssertEqual(content.availableHeight, room(945))

        // Closed, then opened from a menu bar on a taller screen.
        popover.close()
        screen.visibleFrame = external
        controller.presentDashboard()
        XCTAssertEqual(content.availableHeight, room(1415))
    }

    /// The room is taken BEFORE the popover shows, so its first layout is
    /// already the right one.
    func testTheRoomIsSetBeforeThePopoverShows() throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let popover = RoomPopoverSpy()
        let screen = ScreenBox(external)
        let controller = makeController(fixture, popover: popover, screen: screen)
        controller.start()
        defer { controller.stop() }
        var seenAtShow: CGFloat?
        popover.onShow = { [weak popover] in
            seenAtShow = (popover?.contentViewController as? NSHostingController<MenuBarContent>)?.rootView.availableHeight
        }

        controller.presentDashboard()
        XCTAssertEqual(seenAtShow, room(1415))
    }

    /// The ⌥⌘U window has its own room — from its own screen, refreshed on
    /// every summon — and opening it leaves the popover's alone.
    func testTheFallbackWindowGetsItsOwnRoom() throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let popover = RoomPopoverSpy()
        let screen = ScreenBox(external)
        let controller = makeController(fixture, popover: popover, screen: screen)
        controller.start()
        defer { controller.stop() }
        controller.presentDashboard()
        popover.close()
        let popoverContent = try content(of: popover.contentViewController)

        screen.visibleFrame = laptop
        controller.showFallbackWindow()
        let window = try XCTUnwrap(controller.fallbackWindowForTesting)
        defer { window.close() }
        let windowContent = try content(of: window.contentViewController)
        XCTAssertEqual(windowContent.availableHeight, room(945))
        XCTAssertEqual(popoverContent.availableHeight, room(1415), "the popover keeps the room of its own screen")

        // Hidden, then summoned again on another screen.
        window.orderOut(nil)
        screen.visibleFrame = external
        controller.showFallbackWindow()
        XCTAssertEqual(windowContent.availableHeight, room(1415))
    }

    /// End to end through the controller's OWN hosted popover content: laid
    /// out for the first time after a show on a short screen, its list pins;
    /// shown again on a tall one, the same view grows.
    func testThePopoversHostedContentSizesItsListByTheScreen() async throws {
        let directory = try makeTempDirectory()
        let accountStore = AccountStore(fileURL: directory.appending(path: "accounts.json"))
        let snapshotStore = UsageSnapshotStore(fileURL: directory.appending(path: "snapshots.json"))
        for order in 0..<3 {
            let account = AccountRecord(id: UUID(), provider: .claude, label: "Claude \(order)", webProfileID: UUID(),
                                        displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
            try await accountStore.add(account)
            try await snapshotStore.save(UsageSnapshot(
                accountID: account.id, fetchedAt: .now,
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.6, resetsAt: .now.addingTimeInterval(3_600)),
                weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: .now.addingTimeInterval(86_400))))
        }
        let fixture = try makeAlertsFixture(directory: directory)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertEqual(fixture.model.presentations.count, 3)

        let popover = RoomPopoverSpy()
        // Too short for the chrome: the list gets the floor.
        let screen = ScreenBox(NSRect(x: 0, y: 0, width: 1280, height: 200))
        let controller = makeController(fixture, popover: popover, screen: screen)
        controller.start()
        defer { controller.stop() }
        controller.presentDashboard()

        let hosted = try XCTUnwrap(popover.contentViewController?.view)
        let frame = NSRect(x: 0, y: 0, width: MenuBarView.popoverWidth, height: 2_000)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        hosted.frame = frame
        defer {
            window.contentView = nil
            window.close()
        }
        func settledHeight() async throws -> CGFloat {
            for _ in 0..<6 {
                hosted.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            return hosted.fittingSize.height
        }

        // Three folded rows (the fold switch is on by default) under the
        // Claude header; the floor holds only the first.
        let cramped = try await settledHeight()
        popover.close()
        screen.visibleFrame = external
        controller.presentDashboard()
        let roomy = try await settledHeight()
        XCTAssertGreaterThan(roomy, cramped + 20, "the list pins on the short screen only: \(cramped) vs \(roomy)")
    }

    /// Content built outside the controller (the SwiftUI scene, tests) gets
    /// the fixed default room.
    func testContentWithoutAControllerUsesTheDefaultRoom() throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let content = MenuBarContent(
            model: fixture.model, history: fixture.model.history, pinSnapshot: AccountPinSnapshot(),
            settings: fixture.model.settings,
            onAddAccount: {}, onSettings: {}, onAbout: {}, onHistory: {}, onOpenSignIn: { _ in },
            onOpenSetupGuide: {}, attentionPresence: AttentionDropPresence()
        )
        XCTAssertEqual(content.availableHeight, AccountListMetrics.defaultRoom)
    }
}

/// Shows on request without AppKit, and lets a test look at the content at
/// the moment of showing.
@MainActor
private final class RoomPopoverSpy: PopoverPresenting {
    private(set) var isShown = false
    var behavior: NSPopover.Behavior = .transient
    var contentViewController: NSViewController?
    var appearance: NSAppearance?
    var hasFullSizeContent = false
    weak var delegate: (any NSPopoverDelegate)?
    var onShow: (() -> Void)?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        onShow?()
        isShown = true
    }

    func performClose(_ sender: Any?) { close() }
    func close() { isShown = false }
}
