import AppKit
import XCTest
@testable import Ration

/// Records presentation without putting anything on screen.
final class RingBarSpyPanel: NSPanel {
    private(set) var frontCount = 0
    private(set) var setFrameCount = 0
    private var orderedIn = false
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { setFrameCount += 1; super.setFrame(frameRect, display: flag) }
    override func orderFrontRegardless() { frontCount += 1; orderedIn = true }
    override func orderOut(_ sender: Any?) { orderedIn = false }
    override var isVisible: Bool { orderedIn }
}

/// The grip strip: a `RingBarPanel` (so presses on it route to the bar's
/// router) that records presentation without going on screen.
final class RingBarGripSpyPanel: RingBarPanel {
    private var orderedIn = false
    override func orderFrontRegardless() { orderedIn = true }
    override func orderOut(_ sender: Any?) { orderedIn = false }
    override var isVisible: Bool { orderedIn }
}

@MainActor
final class RingBarFakePoll: RingBarPoll {
    private(set) var cancelled = false
    let tick: @MainActor @Sendable () -> Void
    init(_ tick: @escaping @MainActor @Sendable () -> Void) { self.tick = tick }
    func cancel() { cancelled = true }
}

/// The controller's lifecycle with fakes: no real windows, timers or
/// pointer. Platform behaviour (focus, glass, Spaces) is checked on a real Mac.
@MainActor
final class RingBarControllerTests: XCTestCase {
    private var panels: [RingBarSpyPanel] = []
    private var cardPanels: [RingBarSpyPanel] = []
    private var pending: [@MainActor @Sendable () -> Void] = []
    private var polls: [RingBarFakePoll] = []
    private var pointer = NSPoint(x: 800, y: 500)
    private var buttons = 0
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var opened = 0
    private var savedScales: [Double] = []
    /// The pointer last set by the bar.
    private var systemPointer: RingBarPointer?
    private var shownPointers: [RingBarPointer] = []
    private var gripPanels: [RingBarGripSpyPanel] = []
    private var hidesAtEdgeChanges: [Bool] = []
    private var edgeChanges: [RingBarEdge] = []
    private var styleChanges: [RingBarStyle] = []
    private var settingsOpened = 0
    private var shownMenus: [NSMenu] = []
    private var shownMenuViews: [NSView] = []
    /// Runs while a menu is "open" (the real one tracks modally).
    private var whileMenuOpen: () -> Void = {}
    /// Another window on top under the pointer (a menu, a panel).
    private var coveringWindow: Int?
    private let ids = [UUID(), UUID()]
    private let extraID = UUID()
    private let screen = RingBarScreen(frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
                                       visibleFrame: NSRect(x: 0, y: 0, width: 1677, height: 1084))

    private func environment() -> RingBarEnvironment {
        RingBarEnvironment(
            makePanel: { [unowned self] in let panel = RingBarSpyPanel(); panels.append(panel); return panel },
            makeCardPanel: { [unowned self] in let panel = RingBarSpyPanel(); cardPanels.append(panel); return panel },
            makeGripPanel: { [unowned self] in let panel = RingBarGripSpyPanel(); gripPanels.append(panel); return panel },
            primaryScreen: { [unowned self] in screen },
            pointerLocation: { [unowned self] in pointer },
            pressedMouseButtons: { [unowned self] in buttons },
            after: { [unowned self] _, work in pending.append(work) },
            startPolling: { [unowned self] tick in let poll = RingBarFakePoll(tick); polls.append(poll); return poll },
            reduceMotion: { true },
            clock: { [unowned self] in clock },
            showPointer: { [unowned self] in shownPointers.append($0); systemPointer = $0 },
            windowNumberAt: { [unowned self] _ in coveringWindow },
            popUpMenu: { [unowned self] menu, _, view in
                shownMenus.append(menu)
                shownMenuViews.append(view)
                whileMenuOpen()
            }
        )
    }

    private func runPending() {
        let work = pending
        pending = []
        work.forEach { $0() }
    }

    private func controller() -> RingBarController {
        RingBarController(environment: environment(), actions: RingBarActions(
            openDashboard: { [unowned self] in opened += 1 },
            setScale: { [unowned self] in savedScales.append($0) },
            setHidesAtEdge: { [unowned self] in hidesAtEdgeChanges.append($0) },
            setEdge: { [unowned self] in edgeChanges.append($0) },
            setStyle: { [unowned self] in styleChanges.append($0) },
            openSettings: { [unowned self] in settingsOpened += 1 }
        ))
    }

    private func groups(fraction: Double = 0.5, count: Int = 2) -> [RingBarGroup] {
        [RingBarGroup(source: .subscription(.claude), entries: zip(ids + [extraID], ["Client", "Personal", "Work"]).prefix(count).map { id, label in
            GaugeEntry(id: id, gauge: MenuBarGauge(provider: .claude, label: label, fraction: fraction, windowKind: .weekly, inUse: false),
                       details: .credit)
        })]
    }

    private func config(enabled: Bool = true, style: RingBarStyle = .rail, edge: RingBarEdge = .left, hides: Bool = false,
                        scale: Double = 1) -> RingBarConfiguration {
        RingBarConfiguration(enabled: enabled, style: style, edge: edge, hidesAtEdge: hides, displaysRemaining: true, scale: scale)
    }

    func testOffMeansNoPanel() {
        let c = controller()
        c.update(groups: groups(), configuration: config(enabled: false), now: clock)
        XCTAssertTrue(panels.isEmpty)
        XCTAssertFalse(c.isPanelVisible)
        XCTAssertFalse(c.isPolling)
    }

    func testOnShowsPanelWithShieldThatLiftsAfterSettle() {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        XCTAssertTrue(c.isPanelVisible)
        XCTAssertTrue(c.isShieldUp)
        runPending()
        XCTAssertFalse(c.isShieldUp)
    }

    func testRevealUnderHeldButtonKeepsShieldUntilRelease() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        let panel = try XCTUnwrap(panels.first)
        XCTAssertFalse(c.isShieldUp, "hidden: nothing to shield yet")
        // The pointer pushes against the edge with the button held down.
        buttons = 1
        pointer = NSPoint(x: 0, y: panel.frame.midY)
        polls.last?.tick()
        clock = clock.addingTimeInterval(0.2)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertTrue(c.isShieldUp)
        runPending()
        XCTAssertTrue(c.isShieldUp, "a held button keeps the shield")
        buttons = 0
        runPending()
        XCTAssertFalse(c.isShieldUp)
    }

    func testTurningHideOffWhileHiddenShowsAndArms() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        let panel = try XCTUnwrap(panels.first)
        XCTAssertEqual(panel.alphaValue, 0)
        c.update(groups: groups(), configuration: config(hides: false), now: clock)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(c.isShieldUp)
    }

    func testTurningHideOnWhileShownHidesAndLetsClicksThrough() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testGrowingUnderThePointerRearms() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        XCTAssertFalse(c.isShieldUp)
        c.update(groups: groups(count: 3), configuration: config(), now: clock)
        XCTAssertTrue(c.isShieldUp, "new gauges under the pointer settle first")
    }

    func testOpenCardRefreshesOnUpdate() throws {
        let c = controller()
        c.update(groups: groups(fraction: 0.5), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let rect = CGRect(x: 9, y: 30, width: 24, height: 24)
        c.model.reportFrames([ids[0]: rect], segment: 0)
        let host = try XCTUnwrap(c.segmentHostsForTesting.first)
        let onScreen = panel.convertToScreen(host.convert(rect, to: nil))
        pointer = NSPoint(x: onScreen.midX, y: onScreen.midY)
        polls.last?.tick()
        runPending()
        let before = try XCTUnwrap(c.lastCardForTesting?.lines.first?.text)
        c.update(groups: groups(fraction: 0.2), configuration: config(), now: clock)
        let after = try XCTUnwrap(c.lastCardForTesting?.lines.first?.text)
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.contains("20%"), after)
    }

    func testZeroGaugesOrdersOutAndReappearanceRearms() {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        c.update(groups: [], configuration: config(), now: clock)
        XCTAssertFalse(c.isPanelVisible)
        XCTAssertFalse(c.isPolling)
        c.update(groups: groups(), configuration: config(), now: clock)
        XCTAssertTrue(c.isPanelVisible)
        XCTAssertTrue(c.isShieldUp)
        XCTAssertEqual(panels.count, 1, "the panel is kept, not recreated")
    }

    func testBurstOfUpdatesDoesNotRebuild() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        let built = c.rebuildCount
        for i in 0..<20 { c.update(groups: groups(fraction: Double(i) / 20), configuration: config(), now: clock) }
        XCTAssertEqual(c.rebuildCount, built)
        XCTAssertEqual(panels.first?.frontCount, 1)
        XCTAssertEqual(polls.count, 1, "one poll for the bar's life on screen")
        let panel = try XCTUnwrap(panels.first)
        let frames = panel.setFrameCount
        for _ in 0..<20 { c.update(groups: groups(), configuration: config(), now: clock) }
        XCTAssertEqual(panel.setFrameCount, frames, "identical updates never move the panel")
    }

    func testStyleOrEdgeChangeRebuildsOnce() {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        let built = c.rebuildCount
        c.update(groups: groups(), configuration: config(style: .capsules), now: clock)
        c.update(groups: groups(), configuration: config(style: .capsules), now: clock)
        XCTAssertEqual(c.rebuildCount, built + 1)
        c.update(groups: groups(), configuration: config(style: .capsules, edge: .bottom), now: clock)
        XCTAssertEqual(c.rebuildCount, built + 2)
    }

    /// Over a light window untinted glass turned mid-grey and text fell to
    /// 1.5:1; every glass is tinted toward the ink colour.
    func testEveryGlassIsTintedTowardInk() throws {
        for style in RingBarStyle.allCases {
            let c = controller()
            c.update(groups: groups(), configuration: config(style: style), now: clock)
            let glass = c.segmentHostsForTesting.compactMap { host -> NSGlassEffectView? in
                var view: NSView? = host.superview
                while let current = view, !(current is NSGlassEffectView) { view = current.superview }
                return view as? NSGlassEffectView
            }
            XCTAssertEqual(glass.count, c.segmentHostsForTesting.count, "\(style)")
            for view in glass {
                XCTAssertTrue(view.tintColor === RingBarMetrics.glassTintColor, "\(style)")
            }
        }
        // Ink (dark #141519) at 40%: resolved the way the glass draws it.
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = RingBarMetrics.glassTintColor.usingColorSpace(.sRGB)
        }
        let tint = try XCTUnwrap(resolved)
        XCTAssertEqual(tint.alphaComponent, 0.4, accuracy: 0.01)
        XCTAssertEqual(tint.redComponent * 255, 0x14, accuracy: 1)
        XCTAssertEqual(tint.blueComponent * 255, 0x19, accuracy: 1)
    }

    /// Plans and API keys, each in its own glass (both styles), 20 pt × scale apart.
    func testEachKindHasItsOwnGlass() {
        let kinds = groups() + [
            RingBarGroup(source: .subscription(.chatGPT), entries: [
                GaugeEntry(id: UUID(), gauge: MenuBarGauge(provider: .chatGPT, label: "20x", fraction: 0.5, windowKind: .weekly, inUse: false),
                           details: .credit)]),
            RingBarGroup(source: .api(.anthropic), entries: [
                GaugeEntry(id: UUID(), gauge: MenuBarGauge(provider: .claude, label: "Studio API", fraction: 0.2, windowKind: .weekly, inUse: false),
                           details: .credit)]),
        ]
        for style in RingBarStyle.allCases {
            let c = controller()
            c.update(groups: kinds, configuration: config(style: style, edge: .bottom, scale: 1.5), now: clock)
            XCTAssertEqual(c.segmentHostsForTesting.map(\.rootView.sources),
                           [[.subscription(.claude), .subscription(.chatGPT)], [.api(.anthropic)]], "\(style)")
            let glass = c.segmentHostsForTesting.map { $0.convert($0.bounds, to: nil) }
            XCTAssertEqual(glass[1].minX - glass[0].maxX, 20 * 1.5, accuracy: 0.5, "\(style): the kinds sit apart")
        }
    }

    func testPlacementUsesPrimaryVisibleFrame() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(edge: .right), now: clock)
        let frame = try XCTUnwrap(panels.first?.frame)
        XCTAssertEqual(frame.maxX, 1677 - RingBarGeometry.margin)
        XCTAssertEqual(frame.midY, 542, accuracy: 1)
    }

    func testHiddenBarIgnoresMouseEventsAndPollRevealsIt() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        let panel = try XCTUnwrap(panels.first)
        XCTAssertTrue(c.isPolling)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.alphaValue, 0)
        pointer = NSPoint(x: 0, y: panel.frame.midY)
        polls.last?.tick()
        clock = clock.addingTimeInterval(0.2)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(c.isShieldUp, "a reveal re-arms input")
        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        clock = clock.addingTimeInterval(0.7)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testHoverShowsCardAfterDelayAndClickOpensDashboard() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        // The cell frames SwiftUI would report: the first gauge at the top of segment 0.
        c.model.reportFrames([ids[0]: CGRect(x: 9, y: 30, width: 24, height: 24)], segment: 0)
        let host = try XCTUnwrap(c.segmentHostsForTesting.first)
        let onScreen = panel.convertToScreen(host.convert(CGRect(x: 9, y: 30, width: 24, height: 24), to: nil))
        pointer = NSPoint(x: onScreen.midX, y: onScreen.midY)
        polls.last?.tick()
        XCTAssertEqual(c.model.hoveredID, ids[0])
        XCTAssertTrue(cardPanels.isEmpty, "the card waits for the hover delay")
        runPending()
        XCTAssertEqual(cardPanels.first?.frontCount, 1)
        c.model.onSelect(ids[0])
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(cardPanels.first?.isVisible, false, "the card closes before the popover opens")
    }

    /// After a click the poll found the pointer still on the gauge and
    /// brought the card straight back over the popover.
    func testClickSuppressesCardUntilPointerLeaves() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let rect = CGRect(x: 9, y: 30, width: 24, height: 24)
        c.model.reportFrames([ids[0]: rect], segment: 0)
        let host = try XCTUnwrap(c.segmentHostsForTesting.first)
        let onScreen = panel.convertToScreen(host.convert(rect, to: nil))
        pointer = NSPoint(x: onScreen.midX, y: onScreen.midY)
        polls.last?.tick()
        runPending()
        let card = try XCTUnwrap(cardPanels.first)
        XCTAssertEqual(card.frontCount, 1)

        c.model.onSelect(ids[0])
        polls.last?.tick()
        runPending()
        XCTAssertFalse(card.isVisible, "no card while the pointer rests on the gauge it just clicked")
        XCTAssertEqual(card.frontCount, 1)

        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        pointer = NSPoint(x: onScreen.midX, y: onScreen.midY)
        polls.last?.tick()
        runPending()
        XCTAssertEqual(card.frontCount, 2, "leaving and coming back shows it again")
    }

    // MARK: Resize

    /// A point on the bar's empty glass: the bottom padding (the default
    /// edge is left, so the bar is a column and the gauges sit above it).
    private func glass(_ panel: NSPanel) -> NSPoint {
        NSPoint(x: panel.frame.maxX - 2, y: panel.frame.minY + 2)
    }

    func testDragGrowsLiveAndSavesOnce() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let startWidth = panel.frame.width
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y)))
        XCTAssertGreaterThan(c.model.scale, 1.3)
        XCTAssertGreaterThan(panel.frame.width, startWidth + 10)
        XCTAssertTrue(savedScales.isEmpty, "saved on release only")
        XCTAssertFalse(c.isShieldUp, "the user's own drag does not re-arm")
        buttons = 0
        XCTAssertTrue(router.mouseUp(at: NSPoint(x: start.x + 20, y: start.y)))
        XCTAssertEqual(savedScales.count, 1)
        XCTAssertEqual(savedScales.first ?? 0, c.model.scale, accuracy: 0.0001)
    }

    func testPressWithoutMoveChangesNothing() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let router = c.dragRouterForTesting
        XCTAssertTrue(router.mouseDown(at: glass(panel)))
        buttons = 0
        XCTAssertTrue(router.mouseUp(at: glass(panel)))
        XCTAssertTrue(savedScales.isEmpty)
        XCTAssertEqual(c.model.scale, 1)
        XCTAssertEqual(opened, 0)
    }

    func testSettingsUpdateDuringDragDoesNotSnapBack() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y)))
        let live = c.model.scale
        c.update(groups: groups(), configuration: config(scale: 1), now: clock)
        XCTAssertEqual(c.model.scale, live, accuracy: 0.0001)
        buttons = 0
        XCTAssertTrue(router.mouseUp(at: NSPoint(x: start.x + 20, y: start.y)))
        XCTAssertEqual(savedScales.last ?? 0, live, accuracy: 0.0001)
    }

    func testConfiguredScaleSizesTheBar() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        let panel = try XCTUnwrap(panels.first)
        let normal = panel.frame.width
        c.update(groups: groups(), configuration: config(scale: 1.5), now: clock)
        XCTAssertEqual(c.model.scale, 1.5)
        XCTAssertEqual(panel.frame.width, normal * 1.5, accuracy: 4)
    }

    func testHoverAndRevealPauseDuringResize() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        let panel = try XCTUnwrap(panels.first)
        pointer = NSPoint(x: 0, y: panel.frame.midY)
        polls.last?.tick()
        clock = clock.addingTimeInterval(0.2)
        polls.last?.tick()
        runPending()
        XCTAssertEqual(panel.alphaValue, 1)
        let rect = CGRect(x: 9, y: 30, width: 24, height: 24)
        c.model.reportFrames([ids[0]: rect], segment: 0)
        let host = try XCTUnwrap(c.segmentHostsForTesting.first)
        let onGauge = panel.convertToScreen(host.convert(rect, to: nil))

        // Along the bar: the drag is on, the size unchanged.
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x, y: start.y + 5)))
        pointer = NSPoint(x: onGauge.midX, y: onGauge.midY)
        polls.last?.tick()
        runPending()
        XCTAssertNil(c.model.hoveredID, "no hover while resizing")
        XCTAssertTrue(cardPanels.isEmpty)
        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        clock = clock.addingTimeInterval(1)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 1, "a drag past the bar does not hide it")

        buttons = 0
        XCTAssertTrue(router.mouseUp(at: NSPoint(x: start.x, y: start.y + 5)))
        polls.last?.tick()
        clock = clock.addingTimeInterval(0.7)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 0, "hiding resumes after the drag")
    }

    func testRebuildDuringDragEndsTheDragAndSaves() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y)))
        let live = c.model.scale
        let more = groups() + [RingBarGroup(source: .subscription(.chatGPT), entries: [
            GaugeEntry(id: UUID(), gauge: MenuBarGauge(provider: .chatGPT, label: "20x", fraction: 0.5, windowKind: .weekly, inUse: false),
                       details: .credit)])]
        c.update(groups: more, configuration: config(), now: clock)
        XCTAssertEqual(savedScales.count, 1, "the partial drag is kept")
        XCTAssertEqual(savedScales.first ?? 0, live, accuracy: 0.0001)
        c.update(groups: more, configuration: config(scale: 1.6), now: clock)
        XCTAssertEqual(c.model.scale, 1.6, "the drag no longer blocks the saved size")
        buttons = 0
        _ = router.mouseUp(at: NSPoint(x: start.x + 20, y: start.y))
        XCTAssertEqual(savedScales.count, 1, "the release after a rebuild saves nothing more")
        XCTAssertEqual(c.model.scale, 1.6)
    }

    func testReleaseWithoutChangeAppliesTheLatestSavedScale() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x, y: start.y + 5)), "along the bar: no size change")
        c.update(groups: groups(), configuration: config(scale: 1.4), now: clock)
        XCTAssertEqual(c.model.scale, 1, "held during the drag")
        buttons = 0
        XCTAssertTrue(router.mouseUp(at: NSPoint(x: start.x, y: start.y + 5)))
        XCTAssertEqual(c.model.scale, 1.4)
        XCTAssertTrue(savedScales.isEmpty)
    }

    func testRouterLeavesGaugesTheirClicks() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.first)
        let rect = CGRect(x: 9, y: 30, width: 24, height: 24)
        c.model.reportFrames([ids[0]: rect], segment: 0)
        let host = try XCTUnwrap(c.segmentHostsForTesting.first)
        let onGauge = panel.convertToScreen(host.convert(rect, to: nil))
        XCTAssertFalse(c.dragRouterForTesting.mouseDown(at: NSPoint(x: onGauge.midX, y: onGauge.midY)))
        XCTAssertTrue(c.dragRouterForTesting.mouseDown(at: NSPoint(x: onGauge.midX, y: onGauge.maxY + 3)),
                      "just past the gauge is glass (a divider, a letter, a gap)")
    }

    func testRouterIgnoresAHiddenOrSettlingBar() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        let panel = try XCTUnwrap(panels.first)
        XCTAssertTrue(c.isShieldUp)
        XCTAssertFalse(c.dragRouterForTesting.mouseDown(at: glass(panel)), "input still settling")
        runPending()
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        runPending()
        XCTAssertFalse(c.dragRouterForTesting.mouseDown(at: glass(panel)), "hidden at the edge")
    }

    // MARK: Resize pointer and grip

    private let both = RingBarPointer.resize(edge: .left, grows: true, shrinks: true)

    /// A shown, settled bar with the pointer on its empty glass.
    private func onGlass(hides: Bool = false) throws -> (RingBarController, NSPanel) {
        let c = controller()
        c.update(groups: groups(), configuration: config(hides: hides), now: clock)
        runPending()
        let panel = try XCTUnwrap(panels.last)
        if hides {
            pointer = NSPoint(x: 0, y: panel.frame.midY)
            polls.last?.tick()
            clock = clock.addingTimeInterval(0.2)
            polls.last?.tick()
            runPending()
        }
        pointer = glass(panel)
        polls.last?.tick()
        return (c, panel)
    }

    /// A point on the grip strip beside a left bar, level with its middle.
    private func onStrip(_ panel: NSPanel) -> NSPoint {
        NSPoint(x: panel.frame.maxX + 6, y: panel.frame.midY)
    }

    func testAssistiveTechSkipsTheGripAndTheScrollArea() throws {
        let (c, _) = try onGlass()
        XCTAssertEqual(gripPanels.last?.isAccessibilityElement(), false, "the grip is decoration for the pointer")
        XCTAssertEqual(c.segmentHostsForTesting.first?.enclosingScrollView?.isAccessibilityElement(), false)
    }

    func testGlassShowsTheResizePointerAndGrip() throws {
        let (c, _) = try onGlass()
        XCTAssertEqual(systemPointer, both)
        XCTAssertTrue(c.isGripShown)
    }

    /// The grip floats beside the bar's inner edge, 5 pt × the bar's scale
    /// off the glass, in a strip of its own.
    func testGripFloatsBesideTheBar() throws {
        let (c, panel) = try onGlass()
        let grip = try XCTUnwrap(gripPanels.last)
        XCTAssertTrue(grip.isVisible)
        XCTAssertEqual(grip.alphaValue, 1)
        XCTAssertFalse(grip.ignoresMouseEvents, "a shown grip can be grabbed")
        XCTAssertEqual(grip.frame, RingBarGeometry.gripLane(edge: .left, barFrame: panel.frame, scale: 1))
        XCTAssertEqual(c.gripPillsForTesting.count, 1, "the rail is one segment")
        XCTAssertEqual(c.gripPillsForTesting.first?.minX, panel.frame.maxX + RingBarGeometry.gripGap)
        XCTAssertTrue(grip.dragRouter === c.dragRouterForTesting, "presses on it resize the bar")
        XCTAssertNotNil(grip.onContextMenu, "a right-click on it opens the bar's menu")
    }

    func testAGaugeGetsTheArrowBack() throws {
        let (c, panel) = try onGlass()
        let rect = CGRect(x: 9, y: 30, width: 24, height: 24)
        c.model.reportFrames([ids[0]: rect], segment: 0)
        let host = try XCTUnwrap(c.segmentHostsForTesting.first)
        let onGauge = panel.convertToScreen(host.convert(rect, to: nil))
        pointer = NSPoint(x: onGauge.midX, y: onGauge.midY)
        polls.last?.tick()
        XCTAssertEqual(systemPointer, .arrow, "a gauge is a button, not a handle")
        XCTAssertFalse(c.isGripShown)
        XCTAssertEqual(gripPanels.last?.alphaValue, 0)
        XCTAssertEqual(gripPanels.last?.ignoresMouseEvents, true, "a hidden grip lets clicks through")
        let count = shownPointers.count
        polls.last?.tick()
        XCTAssertEqual(shownPointers.count, count, "the arrow is set once, not every tick")
    }

    /// Probed (macOS 27): leaving a background app's window gives the
    /// pointer back by itself; setting the arrow there could replace the
    /// next app's I-beam.
    func testLeavingTheBarLeavesThePointerToMacOS() throws {
        let (c, _) = try onGlass()
        let count = shownPointers.count
        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        XCTAssertEqual(shownPointers.count, count)
        XCTAssertFalse(c.isGripShown)
    }

    func testTheGripStripKeepsTheCueButNeverStartsIt() throws {
        let (c, panel) = try onGlass()
        pointer = onStrip(panel)
        polls.last?.tick()
        XCTAssertTrue(c.isGripShown, "on the way from the glass to the grip")
        XCTAssertEqual(systemPointer, both)
        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        XCTAssertFalse(c.isGripShown)
        let count = shownPointers.count
        pointer = onStrip(panel)
        polls.last?.tick()
        XCTAssertFalse(c.isGripShown, "coming from outside, the strip is just the desktop")
        XCTAssertEqual(shownPointers.count, count)
    }

    func testAPressOnTheGripResizes() throws {
        let (c, panel) = try onGlass()
        let router = c.dragRouterForTesting
        let start = onStrip(panel)
        pointer = start
        polls.last?.tick()
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y)))
        XCTAssertGreaterThan(c.model.scale, 1.2)
        XCTAssertEqual(gripPanels.last?.frame.minX, panel.frame.maxX, "the grip follows the bar's edge")
        XCTAssertEqual(gripPanels.last?.frame.width ?? 0, RingBarGeometry.gripLane(edge: .left, barFrame: panel.frame, scale: c.model.scale).width,
                       accuracy: 0.5, "and its scale (window frames are backing-aligned)")
        buttons = 0
        XCTAssertTrue(router.mouseUp(at: NSPoint(x: start.x + 20, y: start.y)))
        XCTAssertEqual(savedScales.count, 1)
    }

    func testHideAtEdgeKeepsTheBarWhileOnTheGrip() throws {
        let (c, panel) = try onGlass(hides: true)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertTrue(c.isGripShown)
        pointer = onStrip(panel)
        polls.last?.tick()
        clock = clock.addingTimeInterval(1)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 1, "reaching for the grip does not hide the bar")
        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        clock = clock.addingTimeInterval(1)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertFalse(c.isGripShown)
    }

    func testCoveredGlassGetsNoCue() throws {
        coveringWindow = 4242
        let (c, _) = try onGlass()
        XCTAssertTrue(shownPointers.isEmpty, "a menu or panel over the bar owns the pointer there")
        XCTAssertFalse(c.isGripShown)
    }

    func testOnlyWhereAPressWouldResize() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        let panel = try XCTUnwrap(panels.first)
        pointer = glass(panel)
        polls.last?.tick()
        XCTAssertTrue(c.isShieldUp)
        XCTAssertTrue(shownPointers.isEmpty, "still settling: a press would not resize")
        XCTAssertFalse(c.isGripShown)

        let hidden = controller()
        hidden.update(groups: groups(), configuration: config(hides: true), now: clock)
        runPending()
        let hiddenPanel = try XCTUnwrap(panels.last)
        pointer = NSPoint(x: hiddenPanel.frame.maxX + 40, y: hiddenPanel.frame.minY + 2)
        polls.last?.tick()
        XCTAssertTrue(shownPointers.isEmpty, "hidden at the edge")
    }

    func testDragKeepsThePointerAndShowsTheLimit() throws {
        let (c, panel) = try onGlass()
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x + 400, y: start.y)))
        XCTAssertEqual(c.model.scale, 1.8)
        XCTAssertEqual(systemPointer, .resize(edge: .left, grows: false, shrinks: true), "at the largest size: shrink only")
        XCTAssertTrue(c.isGripShown)
        pointer = NSPoint(x: start.x + 400, y: start.y)
        polls.last?.tick()
        XCTAssertEqual(systemPointer, .resize(edge: .left, grows: false, shrinks: true), "off the bar mid-drag: still resizing")
        buttons = 0
        XCTAssertTrue(router.mouseUp(at: pointer))
        polls.last?.tick()
        XCTAssertFalse(c.isGripShown, "released off the bar")
    }

    func testHidingTheBarRestoresTheArrow() throws {
        let (c, _) = try onGlass()
        c.update(groups: groups(), configuration: config(enabled: false), now: clock)
        XCTAssertEqual(systemPointer, .arrow, "the pointer was on the bar: it was ours to give back")
        XCTAssertFalse(c.isGripShown)
        XCTAssertEqual(gripPanels.last?.isVisible, false)

        let (stopped, _) = try onGlass()
        XCTAssertEqual(systemPointer, both)
        stopped.stop()
        XCTAssertEqual(systemPointer, .arrow)
        XCTAssertEqual(gripPanels.last?.isVisible, false)
    }

    // MARK: Right-click menu

    private func perform(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return XCTFail("no action") }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// Auto Hide, Style and Position, each showing the bar's setting.
    func testTheMenuSetsUpAutoHideStyleAndPosition() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(style: .rail, edge: .left, hides: false), now: clock)
        let menu = c.contextMenuForTesting()
        let hide = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(hide.title, String(localized: .ringBarMenuAutoHide))
        XCTAssertEqual(String(localized: .ringBarMenuAutoHide), "Auto Hide")
        XCTAssertEqual(hide.state, .off)
        perform(hide)
        XCTAssertEqual(hidesAtEdgeChanges, [true])

        let styles = menu.items.filter { item in RingBarStyle.allCases.contains { $0.title == item.title } }
        XCTAssertEqual(styles.map(\.title), RingBarStyle.allCases.map(\.title))
        XCTAssertEqual(styles.map(\.state), RingBarStyle.allCases.map { $0 == .rail ? .on : .off }, "the bar's style is ticked")
        perform(styles.first { $0.title == RingBarStyle.capsules.title })
        XCTAssertEqual(styleChanges, [.capsules])
        XCTAssertTrue(menu.items.contains { $0.title == String(localized: "Style") }, "the styles sit under a Style header")
        let titles = menu.items.map(\.title)
        XCTAssertLessThan(try XCTUnwrap(titles.firstIndex(of: String(localized: "Style"))),
                          try XCTUnwrap(titles.firstIndex(of: String(localized: "Position"))), "style first, as in Settings")

        let edges = menu.items.filter { item in RingBarEdge.allCases.contains { $0.title == item.title } }
        XCTAssertEqual(edges.map(\.title), RingBarEdge.allCases.map(\.title))
        XCTAssertEqual(edges.map(\.state), [.on, .off, .off, .off], "the bar's edge is ticked")
        perform(edges.last)
        XCTAssertEqual(edgeChanges, [RingBarEdge.allCases.last])
        XCTAssertTrue(menu.items.contains { $0.title == String(localized: "Position") }, "the edges sit under a Position header")

        let settings = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(settings.title, String(localized: .ringBarMenuSettings))
        perform(settings)
        XCTAssertEqual(settingsOpened, 1)

        c.update(groups: groups(), configuration: config(edge: .bottom, hides: true), now: clock)
        let again = c.contextMenuForTesting()
        XCTAssertEqual(again.items.first?.state, .on, "ticked while the bar hides at its edge")
        perform(again.items.first)
        XCTAssertEqual(hidesAtEdgeChanges, [true, false])
    }

    func testRightClickShowsTheMenuAndTheBarStaysWhileItIsOpen() throws {
        let (c, panel) = try onGlass(hides: true)
        XCTAssertEqual(panel.alphaValue, 1)
        var alphaWhileOpen: [CGFloat] = []
        whileMenuOpen = { [unowned self] in
            pointer = NSPoint(x: 900, y: 500)  // into the menu, away from the bar
            polls.last?.tick()
            clock = clock.addingTimeInterval(1)
            polls.last?.tick()
            alphaWhileOpen.append(panel.alphaValue)
        }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        c.contextMenuRequested(click)
        XCTAssertEqual(shownMenus.count, 1)
        XCTAssertEqual(alphaWhileOpen, [1], "the bar stays while its menu is open")
        XCTAssertFalse(c.isGripShown, "the menu takes over the pointer")
        polls.last?.tick()
        clock = clock.addingTimeInterval(1)
        polls.last?.tick()
        XCTAssertEqual(panel.alphaValue, 0, "after the menu closes, hiding resumes")
    }

    /// AppKit reads the click's location in the view it is given; a
    /// right-click on the grip strip opened the menu offset by the bar's
    /// thickness. The menu opens in the window that got the click.
    func testTheMenuOpensWhereTheClickWas() throws {
        let (c, panel) = try onGlass()
        let grip = try XCTUnwrap(gripPanels.last)
        func click(in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        c.contextMenuRequested(try click(in: grip))
        XCTAssertTrue(shownMenuViews.last === grip.contentView, "the grip strip's click, the grip strip's view")
        c.contextMenuRequested(try click(in: panel))
        XCTAssertTrue(shownMenuViews.last === panel.contentView)
    }

    // MARK: Interrupted and stale input

    func testALostReleaseEndsTheDragOnTheNextTick() throws {
        let (c, panel) = try onGlass()
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        XCTAssertTrue(router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y)))
        let live = c.model.scale
        buttons = 0  // the button is up, but no mouse-up came
        pointer = NSPoint(x: 900, y: 500)
        polls.last?.tick()
        XCTAssertEqual(savedScales, [live], "the drag ends where it was and saves once")
        XCTAssertFalse(c.isGripShown, "the poll is back in charge")
        XCTAssertFalse(router.mouseDragged(at: NSPoint(x: start.x + 60, y: start.y)), "nothing left to drag")
    }

    func testARebuildDropsAPendingPress() throws {
        let (c, panel) = try onGlass()
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        let more = groups() + [RingBarGroup(source: .subscription(.chatGPT), entries: [
            GaugeEntry(id: UUID(), gauge: MenuBarGauge(provider: .chatGPT, label: "20x", fraction: 0.5, windowKind: .weekly, inUse: false),
                       details: .credit)])]
        c.update(groups: more, configuration: config(), now: clock)
        XCTAssertFalse(router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y)), "the press belonged to the old layout")
        XCTAssertEqual(c.model.scale, 1)
    }

    func testAPressFromBeforeTheBarMovedDoesNotResize() throws {
        let (c, panel) = try onGlass()
        let router = c.dragRouterForTesting
        let start = glass(panel)
        XCTAssertTrue(router.mouseDown(at: start))
        buttons = 1
        c.update(groups: groups(count: 3), configuration: config(), now: clock)
        XCTAssertTrue(c.isShieldUp, "the bar grew under the press")
        _ = router.mouseDragged(at: NSPoint(x: start.x + 20, y: start.y))
        XCTAssertEqual(c.model.scale, 1, "the shield is the rule for drags too")
        buttons = 0
        _ = router.mouseUp(at: NSPoint(x: start.x + 20, y: start.y))
        XCTAssertTrue(savedScales.isEmpty)
    }

    func testSwitchingOffStopsPolling() {
        let c = controller()
        c.update(groups: groups(), configuration: config(hides: true), now: clock)
        c.update(groups: groups(), configuration: config(enabled: false, hides: true), now: clock)
        XCTAssertTrue(polls.allSatisfy(\.cancelled))
        XCTAssertFalse(c.isPanelVisible)
    }

    func testStopCancelsEverythingAndLateCallbacksAreIgnored() throws {
        let c = controller()
        c.update(groups: groups(), configuration: config(), now: clock)
        let panel = try XCTUnwrap(panels.first)
        XCTAssertFalse(pending.isEmpty, "a settle callback is pending")
        c.stop()
        runPending()
        c.update(groups: groups(), configuration: config(), now: clock)
        XCTAssertFalse(c.isPanelVisible)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frontCount, 1)
        XCTAssertTrue(polls.allSatisfy(\.cancelled))
    }

    func testProductionFactoryIsInertUnderXCTest() {
        XCTAssertNil(RingBarController.makeForProduction(actions: RingBarActions(openDashboard: {})))
    }

    func testPanelKeepsOutOfTheWay() {
        let panel = RingBarPanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .stationary, .fullScreenNone])
    }
}
