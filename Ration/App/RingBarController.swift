import AppKit
import SwiftUI

/// What the ring bar shows and where, from `AppSettings`.
struct RingBarConfiguration: Equatable {
    var enabled: Bool
    var style: RingBarStyle
    var edge: RingBarEdge
    var hidesAtEdge: Bool
    var displaysRemaining: Bool
    var scale: Double

    init(enabled: Bool, style: RingBarStyle, edge: RingBarEdge, hidesAtEdge: Bool, displaysRemaining: Bool, scale: Double = 1) {
        self.enabled = enabled
        self.style = style
        self.edge = edge
        self.hidesAtEdge = hidesAtEdge
        self.displaysRemaining = displaysRemaining
        self.scale = scale
    }

    @MainActor
    init(settings: AppSettings) {
        self.init(
            enabled: settings.ringBarEnabled,
            style: settings.ringBarStyle,
            edge: settings.ringBarEdge,
            hidesAtEdge: settings.ringBarHidesAtEdge,
            displaysRemaining: settings.menuBarDisplaysRemaining,
            scale: settings.ringBarScale
        )
    }
}

/// What the bar asks of the app: a gauge's click, a size dragged to, and
/// its right-click menu's settings.
struct RingBarActions {
    var openDashboard: @MainActor () -> Void
    /// Saves a size the user dragged to (once, on release).
    var setScale: @MainActor (Double) -> Void = { _ in }
    var setHidesAtEdge: @MainActor (Bool) -> Void = { _ in }
    var setEdge: @MainActor (RingBarEdge) -> Void = { _ in }
    var setStyle: @MainActor (RingBarStyle) -> Void = { _ in }
    /// Settings, at the pane with the bar's options.
    var openSettings: @MainActor () -> Void = {}
}

/// `MenuBarController`'s view of the ring bar (a spy in its tests).
@MainActor
protocol RingBarPresenting: AnyObject {
    func update(groups: [RingBarGroup], configuration: RingBarConfiguration, keepAwake: KeepAwakeEye, now: Date)
    func setAppearance(_ appearance: NSAppearance?)
    func screensChanged()
    func stop()
}

@MainActor
protocol RingBarPoll: AnyObject {
    func cancel()
}

struct RingBarScreen: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
}

/// Everything the controller touches outside itself, so tests run it with
/// fakes and never put a window on screen.
struct RingBarEnvironment {
    var makePanel: @MainActor () -> NSPanel
    var makeCardPanel: @MainActor () -> NSPanel
    /// The strip beside the bar that holds the floating grip.
    var makeGripPanel: @MainActor () -> NSPanel
    /// The display with the menu bar (`NSScreen.screens.first`), read fresh:
    /// Apple says not to cache `visibleFrame`.
    var primaryScreen: @MainActor () -> RingBarScreen?
    var pointerLocation: @MainActor () -> NSPoint
    var pressedMouseButtons: @MainActor () -> Int
    var after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    var startPolling: @MainActor (@escaping @MainActor @Sendable () -> Void) -> any RingBarPoll
    var reduceMotion: @MainActor () -> Bool
    var clock: @MainActor () -> Date
    /// The pointer over the bar (`RingBarCursor`).
    var showPointer: @MainActor (RingBarPointer) -> Void
    /// The window a press at a screen point would reach, if any: a menu or
    /// panel over the bar owns the pointer there.
    var windowNumberAt: @MainActor (NSPoint) -> Int?
    /// Shows the bar's right-click menu; returns when it closes.
    var popUpMenu: @MainActor (NSMenu, NSEvent, NSView) -> Void

    @MainActor
    static var live: RingBarEnvironment {
        RingBarEnvironment(
            makePanel: { RingBarPanel() },
            makeCardPanel: { RingBarCardPanel() },
            makeGripPanel: { RingBarPanel() },
            primaryScreen: {
                NSScreen.screens.first.map { RingBarScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            },
            pointerLocation: { NSEvent.mouseLocation },
            pressedMouseButtons: { NSEvent.pressedMouseButtons },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            },
            startPolling: { tick in RingBarTimerPoll(interval: RingBarController.pollInterval, tick: tick) },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            clock: { .now },
            showPointer: { RingBarCursor.show($0) },
            windowNumberAt: { point in
                let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                return number > 0 ? number : nil
            },
            popUpMenu: { menu, event, view in NSMenu.popUpContextMenu(menu, with: event, for: view) }
        )
    }
}

@MainActor
private final class RingBarTimerPoll: RingBarPoll {
    private var timer: Timer?

    init(interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// The ring bar: a non-activating glass panel at a screen edge showing the
/// menu bar's gauges grouped by provider.
///
/// It keeps its panel, glass and hosting views for its whole life and only
/// rebuilds them when the style, the edge or the set of providers changes;
/// values flow through `RingBarModel`. One poll (10 Hz, only while the bar is
/// on screen) drives both hover and Hide at edge: hover events never reach
/// an inactive app's panel (probed on macOS 27).
@MainActor
final class RingBarController: RingBarPresenting {
    static let pollInterval: TimeInterval = 0.1
    /// How long a freshly shown or revealed bar ignores the mouse — the
    /// drop's settle delay, for the same reason.
    static let settleDelay: TimeInterval = MenuBarController.attentionSettleDelay
    static let settleRetry: TimeInterval = 0.05
    static let hoverDelay: TimeInterval = 0.3
    /// How far a hidden bar slides toward its edge (none with Reduce Motion).
    static let slide: CGFloat = 16

    private struct Structure: Equatable {
        let style: RingBarStyle
        let edge: RingBarEdge
        let sources: [DisplaySource]
    }

    private let environment: RingBarEnvironment
    private let actions: RingBarActions
    let model = RingBarModel()
    /// Turns presses on the bar's empty glass into resize phases.
    private let dragRouter = RingBarDragRouter()
    var dragRouterForTesting: RingBarDragRouter { dragRouter }

    private var panel: NSPanel?
    private var root: NSView?
    private var document: FlippedView?
    private var segmentRoot: FlippedView?
    private var glassViews: [NSGlassEffectView] = []
    private var segmentHosts: [NSHostingView<RingBarSegmentView>] = []
    private var shield: PresentationShieldView?
    private var cardPanel: NSPanel?
    private var cardHost: NSHostingView<RingBarCardView>?
    private var gripPanel: NSPanel?
    private var gripView: RingBarGripView?
    /// The grip floats beside the bar (and takes presses) while the resize
    /// pointer shows.
    private(set) var isGripShown = false
    /// The grip's pills on screen, for tests.
    private(set) var gripPillsForTesting: [NSRect] = []

    private var structure: Structure?
    private var configuration: RingBarConfiguration?
    private var reveal = RingBarReveal(hidesAtEdge: false)
    private var poll: (any RingBarPoll)?
    /// Where the bar sits when shown; the reveal zones are measured from it.
    private var placedFrame: NSRect?
    private var appearance: NSAppearance?
    /// Fences delayed settle callbacks to the presentation that scheduled them.
    private var presentation = 0
    private var hoverGeneration = 0
    /// The last card shown, for tests.
    private(set) var lastCardForTesting: RingBarCard?
    /// The gauge just clicked: no card for it until the pointer leaves it,
    /// or the poll would bring the card straight back over the popover.
    private var suppressedHoverID: UUID?
    /// A drag on empty glass in progress: where it began, at what scale and
    /// thickness. Settings updates do not override the live scale meanwhile.
    private var resize: (pointer: NSPoint, scale: Double, thickness: CGFloat)?
    /// The resize pointer is showing (the arrow goes back once).
    private var showsResizePointer = false
    /// The right-click menu is open: the poll leaves the bar alone.
    private var menuOpen = false
    private var stopped = false
    private(set) var rebuildCount = 0

    init(environment: RingBarEnvironment, actions: RingBarActions) {
        self.environment = environment
        self.actions = actions
        model.onSelect = { [weak self] id in self?.select(id) }
        dragRouter.isOnGauge = { [weak self] point in self?.gauge(at: point) != nil }
        dragRouter.isArmed = { [weak self] in self?.inputArmed ?? false }
        dragRouter.onPhase = { [weak self] phase, point in self?.resize(phase, at: point) }
    }

    /// Nil under XCTest: the test host runs the real app, so only tests that
    /// inject fakes get a ring bar.
    static func makeForProduction(actions: RingBarActions) -> RingBarController? {
        RuntimeEnvironment.isHostingUnitTests ? nil : RingBarController(environment: .live, actions: actions)
    }

    var isPanelVisible: Bool { panel?.isVisible == true }
    /// Shown, revealed and settled: presses reach the bar.
    private var inputArmed: Bool { !stopped && isPanelVisible && reveal.isVisible && shield == nil }
    var isShieldUp: Bool { shield != nil }
    var isPolling: Bool { poll != nil }
    var segmentHostsForTesting: [NSHostingView<RingBarSegmentView>] { segmentHosts }

    // MARK: RingBarPresenting

    func update(groups: [RingBarGroup], configuration new: RingBarConfiguration, keepAwake: KeepAwakeEye, now: Date) {
        guard !stopped else { return }
        let old = configuration
        configuration = new
        guard new.enabled, !groups.isEmpty, let screen = environment.primaryScreen() else {
            conceal()
            return
        }
        // Write only what changed: every assignment re-renders.
        if model.groups != groups { model.groups = groups }
        if model.style != new.style { model.style = new.style }
        if model.edge != new.edge { model.edge = new.edge }
        if model.displaysRemaining != new.displaysRemaining { model.displaysRemaining = new.displaysRemaining }
        if model.keepAwake != keepAwake { model.keepAwake = keepAwake }
        if Int(model.now.timeIntervalSince1970 / 60) != Int(now.timeIntervalSince1970 / 60) { model.now = now }
        if resize == nil, model.scale != new.scale { model.scale = new.scale }

        let wasShown = isPanelVisible
        var revealReset = false
        if old?.enabled != true || old?.hidesAtEdge != new.hidesAtEdge || old?.edge != new.edge {
            reveal = RingBarReveal(hidesAtEdge: new.hidesAtEdge)
            revealReset = true
        }
        let wanted = Structure(style: new.style, edge: new.edge, sources: groups.map(\.source))
        if wanted != structure { rebuild(wanted) }
        place(on: screen)
        if wasShown && revealReset {
            // Hide at edge switched (or the edge moved) under a panel already
            // on screen: its alpha and click-through must follow at once.
            applyVisibility(animated: false)
            if reveal.isVisible { armInput() }
        }
        present()
        // An open card follows the numbers under it.
        if cardPanel?.isVisible == true, let id = model.hoveredID { showCard(for: id) }
        if poll == nil {
            poll = environment.startPolling { [weak self] in self?.tick() }
        }
    }

    func setAppearance(_ appearance: NSAppearance?) {
        self.appearance = appearance
        panel?.appearance = appearance
        cardPanel?.appearance = appearance
        gripPanel?.appearance = appearance
    }

    /// Displays changed or the Mac woke: re-place, and a bar that hides at
    /// the edge starts hidden again.
    func screensChanged() {
        guard !stopped, isPanelVisible, let screen = environment.primaryScreen() else { return }
        reveal.hideNow()
        place(on: screen)
        applyVisibility(animated: false)
    }

    func stop() {
        releaseResizeCue(giveArrowBack: pointerIsOnBar())
        dragRouter.reset()
        gripPanel?.orderOut(nil)
        gripPanel = nil
        gripView = nil
        stopped = true
        presentation += 1
        hoverGeneration += 1
        poll?.cancel()
        poll = nil
        closeCard()
        panel?.orderOut(nil)
        cardPanel = nil
        cardHost = nil
        panel = nil
    }

    // MARK: Presentation

    private func conceal() {
        releaseResizeCue(giveArrowBack: pointerIsOnBar())
        dragRouter.reset()
        gripPanel?.orderOut(nil)
        presentation += 1
        hoverGeneration += 1
        poll?.cancel()
        poll = nil
        closeCard()
        removeShield()
        model.hoveredID = nil
        panel?.orderOut(nil)
    }

    private func present() {
        guard let panel, !panel.isVisible else { return }
        applyVisibility(animated: false)
        panel.orderFrontRegardless()
        if reveal.isVisible { armInput() }
    }

    /// One glass view per kind (subscriptions, API keys) in both styles,
    /// each hosting a SwiftUI segment that reads the model.
    private func rebuild(_ wanted: Structure) {
        // The views under a drag are about to go, and with them its end:
        // finish the drag here, keeping the size it reached.
        if let start = resize {
            resize = nil
            if abs(model.scale - start.scale) > 0.001 { actions.setScale(model.scale) }
        }
        // A press not yet a drag belonged to the old layout too.
        dragRouter.reset()
        structure = wanted
        rebuildCount += 1
        model.resetFrames()
        model.hoveredID = nil
        closeCard()

        let panel = self.panel ?? {
            let made = environment.makePanel()
            made.appearance = appearance
            (made as? RingBarPanel)?.dragRouter = dragRouter
            (made as? RingBarPanel)?.onContextMenu = { [weak self] event in self?.contextMenuRequested(event) }
            self.panel = made
            return made
        }()

        let segments = RingBarSegments.byKind(wanted.sources)
        let segmentRoot = FlippedView()
        glassViews = []
        segmentHosts = []
        for (index, sources) in segments.enumerated() {
            let host = NSHostingView(rootView: RingBarSegmentView(model: model, sources: sources, segment: index))
            host.sizingOptions = [.intrinsicContentSize]
            let glass = NSGlassEffectView()
            glass.style = .regular
            // Never mid-grey over a light window (text fell to 1.5:1).
            glass.tintColor = RingBarMetrics.glassTintColor
            glass.cornerRadius = RingBarMetrics.cornerRadius(wanted.style)
            glass.contentView = host
            segmentRoot.addSubview(glass)
            glassViews.append(glass)
            segmentHosts.append(host)
        }
        // Batches the capsules' glass; spacing 0 merges nothing.
        let container = NSGlassEffectContainerView()
        container.contentView = segmentRoot
        let document = FlippedView()
        document.addSubview(container)
        container.autoresizingMask = [.width, .height]

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = document
        scroll.autoresizingMask = [.width, .height]
        // Only there for overflow: VoiceOver goes straight to the kinds.
        scroll.setAccessibilityElement(false)

        let root = NSView()
        root.addSubview(scroll)
        panel.contentView = root
        self.root = root
        self.document = document
        self.segmentRoot = segmentRoot
        shield = nil
        // New content under a pointer that may be pressing: settle again.
        if panel.isVisible && reveal.isVisible { armInput() }
    }

    /// Lays the segments out along the bar and returns the content size.
    private func layoutContent() -> NSSize {
        guard let structure, let document, let segmentRoot else { return .zero }
        let vertical = structure.edge.isVertical
        // The model just changed: let SwiftUI apply it before measuring, or
        // a new gauge would be measured on the next update only.
        for host in segmentHosts { host.layoutSubtreeIfNeeded() }
        let sizes = segmentHosts.map(\.fittingSize)
        let thickness = sizes.map { vertical ? $0.width : $0.height }.max() ?? 0
        var offset: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if index > 0 { offset += gap(before: index) }
            let frame = vertical
                ? NSRect(x: ((thickness - size.width) / 2).rounded(), y: offset, width: size.width, height: size.height)
                : NSRect(x: offset, y: ((thickness - size.height) / 2).rounded(), width: size.width, height: size.height)
            glassViews[index].frame = frame
            glassViews[index].cornerRadius = RingBarMetrics.cornerRadius(structure.style, scale: model.scale)
            segmentHosts[index].frame = glassViews[index].bounds
            offset += vertical ? size.height : size.width
        }
        let total = vertical ? NSSize(width: thickness, height: offset) : NSSize(width: offset, height: thickness)
        document.frame = NSRect(origin: .zero, size: total)
        segmentRoot.frame = NSRect(origin: .zero, size: total)
        return total
    }

    /// The kinds sit apart (each segment is one kind).
    private func gap(before index: Int) -> CGFloat {
        RingBarMetrics.kindGap(scale: model.scale)
    }

    private func place(on screen: RingBarScreen) {
        guard let panel, let configuration, let root else { return }
        let size = layoutContent()
        let frame = RingBarGeometry.frame(edge: configuration.edge, contentSize: size, visibleFrame: screen.visibleFrame)
        // Moved or grown while shown: new gauges may now sit under a
        // pressing pointer, so settle again.
        if let previous = placedFrame, previous != frame, panel.isVisible, reveal.isVisible, resize == nil { armInput() }
        placedFrame = frame
        let target = reveal.isVisible ? frame : hiddenFrame(frame)
        if panel.frame != target { panel.setFrame(target, display: false) }
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.subviews.first?.frame = root.bounds
    }

    private func hiddenFrame(_ frame: NSRect) -> NSRect {
        guard let edge = configuration?.edge, !environment.reduceMotion() else { return frame }
        switch edge {
        case .left: return frame.offsetBy(dx: -Self.slide, dy: 0)
        case .right: return frame.offsetBy(dx: Self.slide, dy: 0)
        case .top: return frame.offsetBy(dx: 0, dy: Self.slide)
        case .bottom: return frame.offsetBy(dx: 0, dy: -Self.slide)
        }
    }

    /// Shown: opaque and clickable. Hidden at the edge: transparent and
    /// click-through, so the app underneath gets every click.
    private func applyVisibility(animated: Bool) {
        guard let panel, let placedFrame else { return }
        let visible = reveal.isVisible
        panel.ignoresMouseEvents = !visible
        let alpha: CGFloat = visible ? 1 : 0
        let target = visible ? placedFrame : hiddenFrame(placedFrame)
        if animated && !environment.reduceMotion() {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = alpha
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.alphaValue = alpha
            if panel.frame != target { panel.setFrame(target, display: false) }
        }
        if !visible {
            closeCard()
            model.hoveredID = nil
        }
    }

    // MARK: Input arming

    /// A shield over the content until the settle delay has passed and no
    /// mouse button is held: a bar that appears under a pressing pointer must
    /// not turn that press into a click (the drop's bug, 0.28.x).
    private func armInput() {
        guard let root else { return }
        presentation += 1
        let token = presentation
        if shield == nil {
            let shield = PresentationShieldView(frame: root.bounds)
            shield.autoresizingMask = [.width, .height]
            root.addSubview(shield)
            self.shield = shield
        }
        environment.after(Self.settleDelay) { [weak self] in self?.settle(token) }
    }

    private func settle(_ token: Int) {
        guard !stopped, token == presentation else { return }
        guard environment.pressedMouseButtons() == 0 else {
            environment.after(Self.settleRetry) { [weak self] in self?.settle(token) }
            return
        }
        removeShield()
    }

    private func removeShield() {
        shield?.removeFromSuperview()
        shield = nil
    }

    // MARK: Pointer

    private func tick() {
        guard !stopped, let panel, panel.isVisible, let placedFrame, let configuration,
              let screen = environment.primaryScreen() else { return }
        // Its menu is open (it tracks modally; this poll still fires): no
        // hiding under it, no hover cards over it.
        guard !menuOpen else { return }
        if resize != nil {
            // A drag on the glass owns the pointer: no hover, no hiding.
            guard environment.pressedMouseButtons() & 1 == 0 else { return }
            // The button is up but no mouse-up came: the drag ends here.
            dragRouter.reset()
            resize(.ended, at: environment.pointerLocation())
        }
        let pointer = environment.pointerLocation()
        let reach = isGripShown ? RingBarGeometry.gripDepth(scale: model.scale) : 0
        let changed = reveal.step(
            inActivation: RingBarGeometry.contains(
                RingBarGeometry.activationZone(edge: configuration.edge, barFrame: placedFrame, screenFrame: screen.frame), pointer),
            inKeepZone: RingBarGeometry.contains(
                RingBarGeometry.keepZone(edge: configuration.edge, barFrame: placedFrame, screenFrame: screen.frame, reach: reach), pointer),
            cardShown: cardPanel?.isVisible == true,
            now: environment.clock()
        )
        if changed {
            applyVisibility(animated: true)
            if reveal.isVisible { armInput() }
        }
        updateHover(pointer: pointer)
        updateResizeCue(pointer: pointer)
    }

    /// The resize pointer and the floating grip, exactly where a press
    /// would resize (the drag router's rule) — on the bar's empty glass, or
    /// on the grip strip once the cue is on (reaching for the grip keeps it;
    /// the strip alone never starts it).
    private func updateResizeCue(pointer: NSPoint) {
        guard let configuration, let panel else { return }
        let onBar = RingBarGeometry.contains(panel.frame, pointer)
        let onStrip = isGripShown && gripPanel.map { RingBarGeometry.contains($0.frame, pointer) } == true
        // A menu or panel over the bar owns the pointer there.
        let top = environment.windowNumberAt(pointer)
        let uncovered = top == nil || top == panel.windowNumber || (onStrip && top == gripPanel?.windowNumber)
        if inputArmed, uncovered, (onBar && gauge(at: pointer) == nil) || onStrip {
            showResizePointer(edge: configuration.edge)
        } else {
            // Over the bar (a gauge) the pointer is the bar's to give back;
            // anywhere else macOS gives it to the window under it (probed).
            releaseResizeCue(giveArrowBack: uncovered && onBar)
        }
    }

    /// Set on every tick while wanted: another app may set its own between.
    private func showResizePointer(edge: RingBarEdge) {
        environment.showPointer(RingBarPointer.resize(edge: edge, scale: model.scale))
        showsResizePointer = true
        showGrip(edge: edge)
    }

    private func releaseResizeCue(giveArrowBack: Bool) {
        hideGrip()
        guard showsResizePointer else { return }
        showsResizePointer = false
        if giveArrowBack { environment.showPointer(.arrow) }
    }

    private func pointerIsOnBar() -> Bool {
        let pointer = environment.pointerLocation()
        return panel.map { RingBarGeometry.contains($0.frame, pointer) } == true
            || (isGripShown && gripPanel.map { RingBarGeometry.contains($0.frame, pointer) } == true)
    }

    // MARK: Floating grip

    /// Lays the grip out beside the bar as it is now (it follows a drag),
    /// and fades it in the first time.
    private func showGrip(edge: RingBarEdge) {
        guard let placedFrame else { return }
        let grip = gripPanel ?? {
            let made = environment.makeGripPanel()
            made.appearance = appearance
            made.ignoresMouseEvents = true
            made.alphaValue = 0
            // Decoration for the pointer; VoiceOver resizes with Settings › Size.
            made.setAccessibilityElement(false)
            (made as? RingBarPanel)?.dragRouter = dragRouter
            (made as? RingBarPanel)?.onContextMenu = { [weak self] event in self?.contextMenuRequested(event) }
            let view = RingBarGripView()
            made.contentView = view
            gripPanel = made
            gripView = view
            return made
        }()
        let lane = RingBarGeometry.gripLane(edge: edge, barFrame: placedFrame, scale: model.scale)
        // The segments as laid out (and scrolled) now, on screen.
        let segments = glassViews.map { glass -> NSRect in
            let inWindow = glass.convert(glass.bounds, to: nil)
            return inWindow.offsetBy(dx: placedFrame.minX, dy: placedFrame.minY)
        }
        let pills = RingBarGeometry.gripPills(edge: edge, barFrame: placedFrame, segmentFrames: segments, scale: model.scale)
        gripPillsForTesting = pills
        if grip.frame != lane { grip.setFrame(lane, display: false) }
        gripView?.frame = NSRect(origin: .zero, size: lane.size)
        gripView?.pills = pills.map { $0.offsetBy(dx: -lane.minX, dy: -lane.minY) }
        guard !isGripShown else { return }
        isGripShown = true
        grip.ignoresMouseEvents = false
        if !grip.isVisible { grip.orderFrontRegardless() }
        fade(grip, to: 1)
    }

    /// Fades out and lets clicks through to whatever is under the strip.
    private func hideGrip() {
        guard isGripShown, let gripPanel else { return }
        isGripShown = false
        gripPanel.ignoresMouseEvents = true
        fade(gripPanel, to: 0)
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat) {
        guard !environment.reduceMotion() else {
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = alpha
        }
    }

    private func updateHover(pointer: NSPoint) {
        let id = reveal.isVisible ? gauge(at: pointer) : nil
        if let suppressed = suppressedHoverID {
            guard id != suppressed else { return }
            suppressedHoverID = nil
        }
        guard id != model.hoveredID else { return }
        let cardWasShown = cardPanel?.isVisible == true
        model.hoveredID = id
        hoverGeneration += 1
        guard let id else {
            closeCard()
            return
        }
        // Moving along the bar with the card open follows at once; a first
        // hover waits, so a pointer passing by does not flash cards.
        if cardWasShown {
            showCard(for: id)
            return
        }
        let generation = hoverGeneration
        environment.after(Self.hoverDelay) { [weak self] in
            guard let self, !stopped, resize == nil, generation == hoverGeneration, model.hoveredID == id else { return }
            showCard(for: id)
        }
    }

    /// The gauge under `point` (screen coordinates), from the frames the
    /// SwiftUI cells report.
    private func gauge(at point: NSPoint) -> UUID? {
        guard let panel, RingBarGeometry.contains(panel.frame, point) else { return nil }
        for (id, cell) in model.cellFrames where segmentHosts.indices.contains(cell.segment) {
            let host = segmentHosts[cell.segment]
            let onScreen = panel.convertToScreen(host.convert(cell.rect, to: nil))
            if RingBarGeometry.contains(onScreen, point) { return id }
        }
        return nil
    }

    // MARK: Hover card and click

    private func showCard(for id: UUID) {
        guard let entry = model.groups.lazy.flatMap(\.entries).first(where: { $0.id == id }),
              let placedFrame, let configuration, let screen = environment.primaryScreen() else { return }
        let card = RingBarText.card(for: entry, displaysRemaining: configuration.displaysRemaining, now: environment.clock())
        lastCardForTesting = card
        let cardPanel = self.cardPanel ?? {
            let made = environment.makeCardPanel()
            made.appearance = appearance
            self.cardPanel = made
            return made
        }()
        let host: NSHostingView<RingBarCardView>
        if let cardHost {
            cardHost.rootView = RingBarCardView(card: card)
            host = cardHost
        } else {
            host = NSHostingView(rootView: RingBarCardView(card: card))
            cardPanel.contentView = host
            cardHost = host
        }
        host.layoutSubtreeIfNeeded()
        let frame = RingBarGeometry.cardFrame(
            edge: configuration.edge, cardSize: host.fittingSize, barFrame: placedFrame,
            pointer: environment.pointerLocation(), visibleFrame: screen.visibleFrame
        )
        cardPanel.setFrame(frame, display: true)
        cardPanel.orderFrontRegardless()
    }

    private func closeCard() {
        cardPanel?.orderOut(nil)
    }

    // MARK: Resize

    /// Empty glass dragged: the bar follows the pointer across its edge,
    /// live, and the size is saved once on release. `pointer` is the event's
    /// screen point (the press point for `.began`).
    private func resize(_ phase: RingBarResizePhase, at pointer: NSPoint) {
        guard !stopped, let configuration, let placedFrame, let screen = environment.primaryScreen() else { return }
        switch phase {
        case .began:
            // Settled input only: a press made before the bar moved or grew
            // under it does not become a drag (the shield's rule).
            guard inputArmed else { return }
            let thickness = configuration.edge.isVertical ? placedFrame.width : placedFrame.height
            resize = (pointer, model.scale, thickness)
            closeCard()
            model.hoveredID = nil
            hoverGeneration += 1
            showResizePointer(edge: configuration.edge)
        case .changed:
            guard let start = resize else { return }
            let scale = RingBarResize.scale(
                startScale: start.scale, startThickness: start.thickness,
                inward: RingBarResize.inward(configuration.edge, from: start.pointer, to: pointer)
            )
            if scale != model.scale {
                model.scale = scale
                place(on: screen)
            }
            // Reaching a limit leaves one arrow.
            showResizePointer(edge: configuration.edge)
        case .ended:
            guard let start = resize else { return }
            resize = nil
            if abs(model.scale - start.scale) > 0.001 {
                actions.setScale(model.scale)
            } else if model.scale != configuration.scale {
                // Unchanged by the drag, but a size saved meanwhile (the
                // slider) was held back: apply it now.
                model.scale = configuration.scale
                place(on: screen)
            }
        }
    }

    private func select(_ id: UUID) {
        closeCard()
        suppressedHoverID = id
        model.hoveredID = nil
        hoverGeneration += 1
        actions.openDashboard()
    }

    // MARK: Right-click menu

    /// Right-click or Control-click anywhere on the bar: Auto Hide, style and
    /// position, where the bar is. The bar stays up while its menu is open.
    func contextMenuRequested(_ event: NSEvent) {
        // AppKit reads the click's location in the view it is given: the
        // view of the window that got it (the bar, or its grip strip).
        guard !stopped, let root = event.window?.contentView ?? panel?.contentView else { return }
        closeCard()
        model.hoveredID = nil
        hoverGeneration += 1
        releaseResizeCue(giveArrowBack: false)
        menuOpen = true
        environment.popUpMenu(contextMenu(), event, root)
        menuOpen = false
    }

    func contextMenuForTesting() -> NSMenu { contextMenu() }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hides = configuration?.hidesAtEdge ?? false
        menu.addItem(RingBarMenuItem(title: String(localized: .ringBarMenuAutoHide), state: hides ? .on : .off) { [actions] in
            actions.setHidesAtEdge(!hides)
        })
        // Style, then position: the order of Settings › Display › Ring Bar.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Style")))
        for style in RingBarStyle.allCases {
            menu.addItem(RingBarMenuItem(title: style.title, state: configuration?.style == style ? .on : .off) { [actions] in
                actions.setStyle(style)
            })
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Position")))
        for edge in RingBarEdge.allCases {
            menu.addItem(RingBarMenuItem(title: edge.title, state: configuration?.edge == edge ? .on : .off) { [actions] in
                actions.setEdge(edge)
            })
        }
        menu.addItem(.separator())
        menu.addItem(RingBarMenuItem(title: String(localized: .ringBarMenuSettings)) { [actions] in actions.openSettings() })
        return menu
    }
}

/// Top-down layout and scrolling for the bar's content.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
