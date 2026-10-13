import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The popover's account list takes its natural height and is pinned only
/// when the popover would otherwise run past its room on the screen
/// (`popoverAvailableHeight`): then to the bottom of the last card that fits
/// whole in what the room leaves once the popover's own rows — header,
/// banners, status strip, footer, as drawn — are taken out.
///
/// The decisions are pure (`AccountListMetrics`); the hosted tests check that
/// `MenuBarView` measures its chrome, reads the room from the environment and
/// sizes its list by both.
@MainActor
final class AccountListSizingTests: XCTestCase {
    private func capped(_ bottoms: [CGFloat?], content: CGFloat? = nil, available: CGFloat?) -> CGFloat? {
        AccountListMetrics.cappedHeight(cardBottoms: bottoms, contentBottom: content, available: available)
    }

    // MARK: The decision

    /// Seven cards that fit: no pin, however many there are — the old rule
    /// cut every list after its fourth card.
    func testAListThatFitsTakesItsNaturalHeight() {
        XCTAssertNil(capped([115, 155, 318, 358, 456, 554, 610], content: 610, available: 760))
    }

    func testOverflowPinsToTheLastCardThatFitsWhole() {
        XCTAssertEqual(capped([150, 300, 450, 640, 760], content: 760, available: 600), 450)
    }

    func testAFirstCardTallerThanTheRoomPinsToTheRoom() {
        XCTAssertEqual(capped([700, 900], content: 900, available: 600), 600)
        XCTAssertEqual(capped([700], content: 700, available: 600), 600)
    }

    /// Before the cards have reported where they end, a short list sizes to
    /// its content straight away; a long one starts at the fallback cap (or
    /// the room, when that is smaller) so the popover does not open tall and
    /// then jump.
    func testAnUnmeasuredShortListIsNotPinned() {
        XCTAssertNil(capped([nil, nil, nil, nil], available: 760))
        XCTAssertNil(capped([nil], available: 760))
    }

    func testAnUnmeasuredLongListStartsAtTheFallbackOrTheRoom() {
        let five: [CGFloat?] = [nil, nil, nil, nil, nil]
        XCTAssertEqual(capped(five, available: 760), AccountListMetrics.maxListHeight)
        XCTAssertEqual(capped(five, available: 400), 400)
    }

    /// One card still to report is not a measured list.
    func testAPartlyMeasuredListCountsAsUnmeasured() {
        XCTAssertEqual(capped([100, 200, nil, 400, 500], available: 760), AccountListMetrics.maxListHeight)
        XCTAssertNil(capped([100, nil, 300], available: 760))
    }

    /// The chrome not measured yet: the list's room is unknown, so even a
    /// fully measured list holds the unmeasured rule.
    func testAnUnmeasuredChromeCountsAsUnmeasured() {
        XCTAssertEqual(capped([100, 200, 300, 400, 500], content: 500, available: nil), AccountListMetrics.maxListHeight)
        XCTAssertNil(capped([100, 200, 300], content: 300, available: nil))
    }

    func testALastCardEndingExactlyAtTheRoomFits() {
        XCTAssertNil(capped([200, 400, 600], content: 600, available: 600))
    }

    func testACardEndingExactlyAtTheRoomIsTheOneThePinShows() {
        XCTAssertEqual(capped([200, 600, 601], content: 601, available: 600), 600)
    }

    /// The first card ending exactly at the room fits; one point less and
    /// even it does not.
    func testTheFirstCardsExactFitBoundary() {
        XCTAssertEqual(capped([600, 800], content: 800, available: 600), 600)
        XCTAssertEqual(capped([600, 800], content: 800, available: 599), 599)
    }

    /// Two cards ending at the same place (an empty row) change nothing.
    func testTiedBottomsPinToTheSharedBottom() {
        XCTAssertEqual(capped([200, 450, 450, 700], content: 700, available: 600), 450)
        XCTAssertNil(capped([200, 450, 450], content: 450, available: 450))
    }

    /// What follows the last card (the Claude footer when Claude is the last
    /// section) is part of the natural height: if it is what runs past the
    /// room, the list pins after the last card and the footer scrolls.
    func testContentPastTheLastCardCountsTowardsTheFit() {
        XCTAssertEqual(capped([200, 400, 560], content: 640, available: 600), 560)
        XCTAssertNil(capped([200, 400, 560], content: 600, available: 600))
    }

    /// Unknown content height: the last card's bottom decides.
    func testAnUnmeasuredContentHeightFallsBackToTheLastCard() {
        XCTAssertNil(capped([200, 400, 560], content: nil, available: 600))
        XCTAssertEqual(capped([200, 400, 660], content: nil, available: 600), 400)
    }

    func testNoCardsIsNotPinned() {
        XCTAssertNil(capped([], content: 0, available: 600))
    }

    // MARK: The room

    /// The screen's visible height less the surface's frame and the margin —
    /// whatever the frame's origin (a second screen sits at its own origin).
    func testTheRoomIsTheVisibleHeightLessTheFrameAndTheMargin() {
        let visible = NSRect(x: 1512, y: -200, width: 2560, height: 1415)
        XCTAssertEqual(AccountListMetrics.room(visibleFrame: visible),
                       1415 - AccountListMetrics.surfaceFrame - AccountListMetrics.screenMargin)
    }

    /// The list gets what the room leaves once the drawn chrome is out; a
    /// screen too short for the chrome still leaves it a floor, never a
    /// negative height; an unmeasured chrome leaves it nothing known.
    func testTheListGetsTheRoomLessTheMeasuredChrome() {
        XCTAssertEqual(AccountListMetrics.listAvailableHeight(room: 900, chrome: 150), 750)
        XCTAssertEqual(AccountListMetrics.listAvailableHeight(room: 100, chrome: 150), AccountListMetrics.minimumListHeight)
        XCTAssertNil(AccountListMetrics.listAvailableHeight(room: 900, chrome: nil))
    }

    /// The frame reserve covers the ⌥⌘U window's title bar (and the
    /// popover's own frame, which is smaller).
    func testTheSurfaceFrameCoversTheWindowTitleBar() {
        // The window's own style (`MenuBarController.standardWindowStyle`).
        let content = NSRect(x: 0, y: 0, width: 540, height: 600)
        let titleBar: CGFloat = NSWindow.frameRect(forContentRect: content,
                                                   styleMask: [.titled, .closable, .miniaturizable, .resizable]).height - content.height
        XCTAssertLessThanOrEqual(titleBar, AccountListMetrics.surfaceFrame)
    }

    /// Tests and snapshots never depend on the screen they run on.
    func testTheEnvironmentDefaultIsFixed() {
        XCTAssertEqual(EnvironmentValues().popoverAvailableHeight, AccountListMetrics.defaultRoom)
        XCTAssertEqual(AccountListMetrics.defaultRoom, 900)
    }

    // MARK: The view measures its chrome and reads the room

    private let now = Date(timeIntervalSince1970: 1_790_100_000)

    private func presentation(_ label: String, _ provider: Provider, order: Int, used: Double) -> AccountPresentation {
        let id = UUID()
        return AccountPresentation(
            account: AccountRecord(id: id, provider: provider, label: label, webProfileID: UUID(), displayOrder: order,
                                   createdAt: now.addingTimeInterval(-30 * 86_400)),
            snapshot: UsageSnapshot(accountID: id, fetchedAt: now.addingTimeInterval(-60),
                                    fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1 - used,
                                                          resetsAt: now.addingTimeInterval(3 * 3600)),
                                    weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - used,
                                                        resetsAt: now.addingTimeInterval(2 * 86_400))),
            state: .current)
    }

    /// Six accounts — more than the old four-card cap.
    private var sixAccounts: [AccountPresentation] {
        [presentation("Client", .claude, order: 0, used: 0.3),
         presentation("Personal", .claude, order: 1, used: 0.5),
         presentation("Work", .claude, order: 2, used: 0.1),
         presentation("20x", .chatGPT, order: 3, used: 0.8),
         presentation("5x", .chatGPT, order: 4, used: 0.2),
         presentation("Team", .chatGPT, order: 5, used: 0.6)]
    }

    private func popover(_ presentations: [AccountPresentation], probe: PopoverLayoutProbe) -> MenuBarView {
        MenuBarView(
            presentations: presentations, isRefreshing: false, profileCleanupBanner: nil, errorMessage: nil,
            activeAccounts: [:],
            onOpen: {}, onAddAccount: {}, onRefresh: {}, onSettings: {}, onAbout: {},
            onHistory: {}, onRetryProfileCleanup: {}, onQuit: {}, onReauthenticate: { _ in },
            pinnedNow: now,
            layoutProbe: probe
        )
    }

    /// The drawn popover, its list and its chrome after everything has
    /// measured itself (a measuring pass, then the re-layout it causes).
    /// Nil `room`: the environment's default.
    private func measure(_ presentations: [AccountPresentation], room: CGFloat?) async throws -> PopoverLayoutProbe {
        let probe = PopoverLayoutProbe()
        let view: AnyView = if let room {
            AnyView(popover(presentations, probe: probe).environment(\.popoverAvailableHeight, room))
        } else {
            AnyView(popover(presentations, probe: probe))
        }
        let host = NSHostingView(rootView: view)
        let frame = NSRect(x: 0, y: 0, width: MenuBarView.popoverWidth, height: 3_000)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(probe.list.isEmpty, "the list is measured")
        XCTAssertGreaterThan(probe.chrome, 0, "the chrome is measured")
        return probe
    }

    /// The measured chrome is exactly what is not the list.
    func testTheMeasuredChromeIsEverythingButTheList() async throws {
        let probe = try await measure(sixAccounts, room: 10_000)
        XCTAssertEqual(probe.chrome, probe.popover.height - probe.list.height, accuracy: 0.5)
    }

    /// More than four accounts with room for all: the whole list shows —
    /// taller than the same list's first four cards, where the old rule cut
    /// it.
    func testALongListWithRoomShowsEveryCard() async throws {
        let roomy = try await measure(sixAccounts, room: 10_000)
        let natural = roomy.list.height
        let firstFour = try await measure(Array(sixAccounts.prefix(4)), room: 10_000).list.height
        XCTAssertGreaterThan(natural, firstFour + 100, "the fifth and sixth cards show")
        // Exactly that much room still fits — no pin.
        let exact = try await measure(sixAccounts, room: roomy.chrome + natural)
        XCTAssertEqual(exact.list.height, natural, accuracy: 0.5)
        XCTAssertEqual(exact.popover.height, roomy.popover.height, accuracy: 0.5)
    }

    /// A point less and the list pins to a card bottom; the popover stays
    /// inside its room.
    func testALongListShortOfRoomPinsInsideIt() async throws {
        let roomy = try await measure(sixAccounts, room: 10_000)
        let room = roomy.chrome + roomy.list.height - 1
        let short = try await measure(sixAccounts, room: room)
        XCTAssertLessThan(short.list.height, roomy.list.height)
        XCTAssertGreaterThan(short.list.height, 0)
        XCTAssertLessThanOrEqual(short.popover.height, room + 0.5)
    }

    /// Less room than the first card: the list takes exactly what the room
    /// leaves — the rest of the popover (its chrome) is unchanged, so the
    /// difference between two rooms is the difference between the popovers.
    func testLessRoomThanTheFirstCardPinsToTheRoom() async throws {
        let chrome = try await measure(sixAccounts, room: 10_000).chrome
        let smaller = try await measure(sixAccounts, room: chrome + 85)
        let larger = try await measure(sixAccounts, room: chrome + 100)
        XCTAssertEqual(smaller.list.height, 85, accuracy: 0.5)
        XCTAssertEqual(larger.list.height, 100, accuracy: 0.5)
        XCTAssertEqual(larger.popover.height - smaller.popover.height, 15, accuracy: 0.5)
    }

    /// No environment value set: the fixed default room.
    func testWithoutAScreenThePopoverUsesTheDefaultRoom() async throws {
        let roomy = try await measure(sixAccounts, room: 10_000)
        let fallback = try await measure(sixAccounts, room: nil)
        if roomy.popover.height <= AccountListMetrics.defaultRoom {
            XCTAssertEqual(fallback.list.height, roomy.list.height, accuracy: 0.5)
        } else {
            XCTAssertLessThanOrEqual(fallback.popover.height, AccountListMetrics.defaultRoom + 0.5)
        }
    }
}
