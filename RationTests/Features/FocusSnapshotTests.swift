import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The popover in the Focus layout, in both appearances, for the states the
/// layout covers (typical, none in use, all paused, zero accounts, Cursor-only).
/// With `RATION_SNAPSHOT_DIR` set (xcodebuild: `TEST_RUNNER_RATION_SNAPSHOT_DIR=…`)
/// the PNGs are written there as `focus-{state}-{dark,light}.png`; CI never
/// writes files.
@MainActor
final class FocusSnapshotTests: XCTestCase {
    /// Real clock: the popover's own timelines read it, so the fixture's
    /// resets are laid out relative to it.
    private let now = Date()
    private var order = 0

    private func account(
        _ label: String,
        _ provider: Provider,
        paused: Bool = false,
        fiveHour: Double? = nil,
        weekly: Double? = nil,
        fable: Double? = nil,
        weeklyResetsIn: TimeInterval? = nil,
        fiveHourResetsIn: TimeInterval? = nil,
        spentCents: Int? = nil,
        state: AccountViewState = .current
    ) -> AccountPresentation {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: provider, label: label, webProfileID: UUID(),
            displayOrder: order, createdAt: now, isPaused: paused
        )
        let snapshot = UsageSnapshot(
            accountID: id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: fiveHour.map { UsageWindow(kind: .fiveHour, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(fiveHourResetsIn ?? 3 * 3600)) },
            weekly: weekly.map {
                UsageWindow(kind: .weekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(weeklyResetsIn ?? 5 * 86_400))
            },
            modelWeekly: fable.map { UsageWindow(kind: .modelWeekly, remainingFraction: 1 - $0, resetsAt: nil, label: "Fable") },
            cursorSpend: spentCents.map {
                CursorSpend(spentCents: $0, periodStart: nil, resetsAt: now, planLabel: "Pro")
            }
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: state)
    }

    private struct Fixture {
        let presentations: [AccountPresentation]
        let focus: FocusModel
    }

    private func fixture(
        _ presentations: [AccountPresentation],
        inUse: [AccountPresentation] = [],
        advice: [SwitchAdvice] = []
    ) -> Fixture {
        var phases: [UUID: InUsePhase] = [:]
        for presentation in inUse { phases[presentation.id] = .inUse(age: 120) }
        let focus = FocusModel.make(
            presentations: presentations, phases: phases, advice: advice,
            fableCounts: { _ in false }, now: now
        )
        return Fixture(presentations: presentations, focus: focus)
    }

    private func typical() -> Fixture {
        let client = account("Client", .claude, fiveHour: 0.27, weekly: 0.97, fable: 0.86,
                              weeklyResetsIn: 11 * 3600 + 18 * 60 + 30)
        let personal = account("Personal", .claude, fiveHour: 0.05, weekly: 0.15)
        let paused = account("Claude", .claude, paused: true, fiveHour: 0.10, weekly: 0.10)
        let gpt20 = account("20x", .chatGPT, weekly: 0.42)
        let gpt5 = account("5x", .chatGPT, weekly: 0.0)
        let cursor = account("Cursor", .cursor, spentCents: 1240)
        // In use but signed out: its line keeps the badge and Sign In.
        let work = account("Work", .claude, fiveHour: 0.40, weekly: 0.30, state: .reauthenticationRequired)
        let advice = SwitchAdvice(
            provider: .claude, fromAccountID: client.id, fromLabel: "Client",
            toAccountID: personal.id, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        return fixture(
            [client, personal, paused, work, gpt20, gpt5, cursor],
            inUse: [client, work, gpt20],
            advice: [advice]
        )
    }

    private func noneInUse() -> Fixture {
        fixture([
            account("Client", .claude, fiveHour: 0.30, weekly: 0.55),
            account("Personal", .claude, fiveHour: 0.05, weekly: 0.15),
            account("20x", .chatGPT, weekly: 0.42),
            account("Stale", .chatGPT, weekly: 0.10, state: .stale(lastError: .offline)),
            account("Work", .claude, state: .reauthenticationRequired),
        ])
    }

    private func allPaused() -> Fixture {
        fixture([
            account("Client", .claude, paused: true, fiveHour: 0.3),
            account("20x", .chatGPT, paused: true, weekly: 0.4),
        ])
    }

    private func cursorOnly() -> Fixture {
        fixture([account("Cursor", .cursor, spentCents: 1240)])
    }

    private func view(_ fixture: Fixture) -> some View {
        MenuBarView(
            presentations: AccountVisibility.visible(fixture.presentations),
            isRefreshing: false,
            profileCleanupBanner: nil,
            errorMessage: nil,
            activeAccounts: [:],
            pausedCount: fixture.presentations.filter(\.account.isPaused).count,
            onOpen: {}, onAddAccount: {}, onRefresh: {}, onSettings: {}, onAbout: {},
            onHistory: {}, onRetryProfileCleanup: {}, onQuit: {}, onReauthenticate: { _ in },
            switchAdvice: fixture.focus.switchLines,
            layout: .focus,
            focusModel: { _ in fixture.focus }
        )
    }

    private func render<V: View>(_ view: V, _ scheme: ColorScheme) throws -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        renderer.colorMode = .nonLinear
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["RATION_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appending(path: name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Whether a pixel within `tolerance` (per-channel sum) of `hex` exists.
    private func contains(_ rep: NSBitmapImageRep, _ hex: UInt32, tolerance: Int = 12) -> Bool {
        let target: [Int] = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        var pixel = [Int](repeating: 0, count: 4)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                rep.getPixel(&pixel, atX: x, y: y)
                let d0: Int = abs(pixel[0] - target[0])
                let d1: Int = abs(pixel[1] - target[1])
                let d2: Int = abs(pixel[2] - target[2])
                if d0 + d1 + d2 <= tolerance { return true }
            }
        }
        return false
    }

    func testFocusStatesRenderInBothAppearances() throws {
        let states: [(String, Fixture)] = [
            ("typical", typical()),
            ("none-in-use", noneInUse()),
            ("all-paused", allPaused()),
            ("zero", fixture([])),
            ("cursor-only", cursorOnly()),
        ]
        for (scheme, suffix) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            var heights: [String: Int] = [:]
            for (name, fixture) in states {
                let rep = try render(view(fixture), scheme)
                XCTAssertEqual(rep.pixelsWide, 540 * 2, "\(name) \(suffix)")
                heights[name] = rep.pixelsHigh
                try write(rep, "focus-\(name)-\(suffix).png")
            }

            // The typical hero is 3% left → the critical tier, drawn big.
            let typicalRep = try render(view(typical()), scheme)
            XCTAssertTrue(contains(typicalRep, resolvedHex(Theme.critNS, appearance)), "\(suffix) crit hero")
            // "Next Claude: Personal · 85% left →" in active green.
            XCTAssertTrue(contains(typicalRep, resolvedHex(Theme.activeNS, appearance)), "\(suffix) switch line")

            // The hero makes the typical popover taller than the hero-less states.
            XCTAssertGreaterThan(heights["typical"] ?? 0, heights["cursor-only"] ?? 0, suffix)
            XCTAssertGreaterThan(heights["typical"] ?? 0, heights["all-paused"] ?? 0, suffix)
        }
    }

    /// An in-use line for a signed-out account draws the gold Sign In
    /// (rendered on its own — the popover header may use gold too).
    func testInUseReauthLineDrawsTheSignInBadge() throws {
        // ChatGPT: Claude's provider dot is itself gold.
        let hero = account("Hero", .chatGPT, weekly: 0.10)
        let work = account("Work", .chatGPT, weekly: 0.30, state: .reauthenticationRequired)
        let focus = fixture([hero, work], inUse: [hero, work]).focus
        XCTAssertEqual(focus.otherInUse.first?.value, .state(.reauthenticationRequired))
        for scheme in [ColorScheme.dark, .light] {
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let view = FocusView(model: focus, now: now, onShowHero: { _ in }, onReauthenticate: { _ in })
                .frame(width: 540)
                .background(Theme.ink)
            let rep = try render(view, scheme)
            try write(rep, "focus-reauth-line-\(scheme == .dark ? "dark" : "light").png")
            XCTAssertTrue(contains(rep, resolvedHex(Theme.goldNS, appearance)), "\(scheme) Sign In")
        }
    }

    /// VoiceOver hears the hero's other limits and a window's own name.
    func testSpokenCopyCarriesOtherLimitsAndWindowLabels() throws {
        let a = account("Opus", .claude, fiveHour: 0.27, weekly: 0.50, fable: 0.97)
        let focus = FocusModel.make(
            presentations: [a], phases: [a.id: .inUse(age: 60)], advice: [],
            fableCounts: { _ in true }, now: now
        )
        let hero = try XCTUnwrap(focus.hero)
        XCTAssertEqual(hero.bindingKind, .modelWeekly)
        let label = FocusView.heroAccessibilityLabel(hero, now: now)
        XCTAssertTrue(label.contains("73 percent of the 5 hour limit left"), label)
        XCTAssertTrue(label.contains("50 percent of the weekly limit left"), label)

        let custom = UsageSnapshot(
            accountID: a.id, fetchedAt: now, fiveHour: nil, weekly: nil,
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.2, resetsAt: nil, label: "Opus 5")
        )
        XCTAssertEqual(
            FocusView.spokenValue(.headroom(0.2, .modelWeekly), snapshot: custom),
            "20 percent of the Opus 5 weekly limit left"
        )
    }

    // MARK: A realistic mix of accounts

    /// Sample numbers: Personal in use (30% of 5h left, week 85%,
    /// resets 27m), ChatGPT 20x in use (25% of the week, 2d 2h), Client
    /// nearly spent and not in use (1% of the week, 2h 27m), 5x 100%,
    /// Cursor $0.00, Claude paused.
    private func samplePresentations() -> [AccountPresentation] {
        [
            account("Client", .claude, fiveHour: 0.20, weekly: 0.99,
                    weeklyResetsIn: 2 * 3600 + 27 * 60 + 30),
            account("Personal", .claude, fiveHour: 0.70, weekly: 0.15, fable: 0.0,
                    fiveHourResetsIn: 27 * 60 + 30),
            account("Claude", .claude, paused: true, fiveHour: 0.10, weekly: 0.10),
            account("20x", .chatGPT, weekly: 0.75, weeklyResetsIn: 2 * 86_400 + 2 * 3600 + 30),
            account("5x", .chatGPT, weekly: 0.0),
            account("Cursor", .cursor, spentCents: 0),
        ]
    }

    private func sampleFocus(_ presentations: [AccountPresentation], pinned: UUID? = nil) -> FocusModel {
        let byLabel = Dictionary(uniqueKeysWithValues: presentations.map { ($0.account.label, $0.id) })
        let phases: [UUID: InUsePhase] = [
            byLabel["Personal"]!: .inUse(age: 60),
            byLabel["20x"]!: .inUse(age: 600),
            byLabel["Client"]!: .lastUsed(age: 7200),
        ]
        return FocusModel.make(
            presentations: presentations, phases: phases, advice: [],
            fableCounts: { _ in false }, pinnedHeroID: pinned, now: now
        )
    }

    private func menuBar(
        _ presentations: [AccountPresentation],
        layout: PopoverLayout,
        focus: FocusModel? = nil,
        switchAdvice: [SwitchAdvice] = []
    ) -> some View {
        MenuBarView(
            presentations: AccountVisibility.visible(presentations),
            isRefreshing: false,
            profileCleanupBanner: nil,
            errorMessage: nil,
            activeAccounts: [:],
            pausedCount: presentations.filter(\.account.isPaused).count,
            onOpen: {}, onAddAccount: {}, onRefresh: {}, onSettings: {}, onAbout: {},
            onHistory: {}, onRetryProfileCleanup: {}, onQuit: {}, onReauthenticate: { _ in },
            switchAdvice: switchAdvice,
            layout: layout,
            focusModel: { [focus] date in
                focus ?? FocusModel.make(presentations: [], phases: [:], advice: [],
                                         fableCounts: { _ in false }, now: date)
            }
        )
    }

    /// How many pixels of the top `rows` are within `tolerance` of `hex`.
    private func count(_ rep: NSBitmapImageRep, _ hex: UInt32, rows: Int, tolerance: Int = 6) -> Int {
        let target: [Int] = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        var pixel = [Int](repeating: 0, count: 4)
        var hits = 0
        for y in 0..<min(rows, rep.pixelsHigh) {
            for x in 0..<rep.pixelsWide {
                rep.getPixel(&pixel, atX: x, y: y)
                let d: Int = abs(pixel[0] - target[0]) + abs(pixel[1] - target[1]) + abs(pixel[2] - target[2])
                if d <= tolerance { hits += 1 }
            }
        }
        return hits
    }

    func testSampleNumbersRenderInFocus() throws {
        let presentations = samplePresentations()
        let focus = sampleFocus(presentations)
        XCTAssertEqual(focus.hero?.account.label, "Personal")
        XCTAssertEqual(focus.hero?.tag, .inUse)
        XCTAssertEqual(focus.hero?.bindingKind, .fiveHour)
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: focus.hero?.resetsAt, limits: focus.hero?.otherLimits ?? [], now: now),
            "resets in 27m · week 85% left · Fable 100% left"
        )
        XCTAssertEqual(focus.otherInUse.map(\.account.label), ["20x"])
        XCTAssertEqual(focus.warnings.map(\.account.label), ["Client"])
        XCTAssertEqual(focus.others.map(\.account.label), ["5x", "Cursor"])

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let rep = try render(menuBar(presentations, layout: .focus, focus: focus), scheme)
            try write(rep, "focus2-typical-\(suffix).png")
            XCTAssertTrue(contains(rep, resolvedHex(Theme.critNS, appearance)), "\(suffix) warning line")
            // No NEXT RESET line in Focus (its value is resetAccent).
            XCTAssertFalse(contains(rep, resolvedHex(Theme.resetAccentNS, appearance), tolerance: 6),
                           "\(suffix) header reset line")
            // The header switch's selected segment.
            XCTAssertGreaterThan(count(rep, resolvedHex(Theme.panelNS, appearance), rows: 90), 400, suffix)
        }
    }

    func testPinnedHeroRenders() throws {
        let presentations = samplePresentations()
        let five = try XCTUnwrap(presentations.first { $0.account.label == "5x" })
        let focus = sampleFocus(presentations, pinned: five.id)
        XCTAssertEqual(focus.hero?.account.id, five.id)
        XCTAssertEqual(focus.hero?.isPinned, true)
        XCTAssertEqual(focus.otherInUse.map(\.account.label), ["Personal", "20x"])
        let rep = try render(menuBar(presentations, layout: .focus, focus: focus), .dark)
        try write(rep, "focus2-pinned-dark.png")
        XCTAssertTrue(FocusView.heroAccessibilityLabel(try XCTUnwrap(focus.hero), now: now).hasSuffix("chosen by you"))
    }

    /// Focus in-use lines wear the cards' green IN USE pill; with in-use
    /// detection off (no phases) there are no in-use lines and no pill.
    /// The hero is pinned to an idle account so the only green is the lines'.
    func testInUseLinesWearTheInUsePill() throws {
        let presentations = samplePresentations()
        let five = try XCTUnwrap(presentations.first { $0.account.label == "5x" })
        let focus = sampleFocus(presentations, pinned: five.id)
        XCTAssertEqual(focus.otherInUse.map(\.account.label), ["Personal", "20x"], "premise")
        let off = FocusModel.make(
            presentations: presentations, phases: [:], advice: [],
            fableCounts: { _ in false }, pinnedHeroID: five.id, now: now
        )
        XCTAssertTrue(off.otherInUse.isEmpty, "premise: in-use off → no in-use lines")

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let green = resolvedHex(Theme.activeNS, appearance)
            let rep = try render(menuBar(presentations, layout: .focus, focus: focus), scheme)
            try write(rep, "focus-inuse-pill-\(suffix).png")
            // Two pills' fills, not a few anti-aliased text pixels.
            XCTAssertGreaterThan(count(rep, green, rows: rep.pixelsHigh, tolerance: 6), 1_000, suffix)

            let offRep = try render(menuBar(presentations, layout: .focus, focus: off), scheme)
            XCTAssertEqual(count(offRep, green, rows: offRep.pixelsHigh, tolerance: 6), 0, "\(suffix) in-use off")
        }
    }

    /// The switch line pins its target as the hero; in-use lines say
    /// "ChatGPT:" and show the plan as the cards' tag. Before (top) and after
    /// (bottom) the click, as `focus-next-click-dark.png`.
    func testSwitchLineClickAndPlanTags() throws {
        func record(_ label: String, _ plan: PlanTier) -> AccountRecord {
            order += 1
            return AccountRecord(
                id: UUID(), provider: .chatGPT, label: label, webProfileID: UUID(),
                displayOrder: order, createdAt: now, plan: plan, planSource: .detected
            )
        }
        func presentation(_ record: AccountRecord, weekly: Double) -> AccountPresentation {
            AccountPresentation(
                account: record,
                snapshot: UsageSnapshot(
                    accountID: record.id, fetchedAt: now.addingTimeInterval(-60), fiveHour: nil,
                    weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - weekly, resetsAt: now.addingTimeInterval(2 * 86_400))
                ),
                state: .current
            )
        }
        let claude = account("Personal", .claude, fiveHour: 0.30, weekly: 0.15)
        let from = presentation(record("ChatGPT 20x", .chatGPTPro20x), weekly: 0.80)
        let target = presentation(record("ChatGPT 5x", .chatGPTPro5x), weekly: 0.0)
        let presentations = [claude, from, target]
        let advice = SwitchAdvice(
            provider: .chatGPT, fromAccountID: from.id, fromLabel: from.account.label,
            toAccountID: target.id, toLabel: target.account.label, toHeadroom: 1.0, toBinding: .weekly
        )
        let phases: [UUID: InUsePhase] = [claude.id: .inUse(age: 60), from.id: .inUse(age: 300)]
        func focus(pinned: UUID?) -> FocusModel {
            FocusModel.make(presentations: presentations, phases: phases, advice: [advice],
                            fableCounts: { _ in false }, pinnedHeroID: pinned, now: now)
        }
        let before = focus(pinned: nil)
        XCTAssertEqual(before.hero?.account.id, claude.id)
        XCTAssertEqual(before.otherInUse.map(\.account.id), [from.id])
        XCTAssertEqual(before.switchLines, [advice])
        var shown: UUID?
        FocusView.showSwitchTarget(advice) { shown = $0 }
        let after = focus(pinned: shown)
        XCTAssertEqual(after.hero?.account.id, target.id)
        XCTAssertEqual(after.hero?.isPinned, true)

        let view = VStack(spacing: 0) {
            menuBar(presentations, layout: .focus, focus: before)
            Rectangle().fill(Color.red).frame(height: 4)
            menuBar(presentations, layout: .focus, focus: after)
        }
        let rep = try render(view, .dark)
        try write(rep, "focus-next-click-dark.png")
    }

    /// The line under the Standard header row (NEXT RESET, or a switch
    /// line) keeps ~3pt more ink gap above it (under the bordered layout
    /// control) than below it (to the divider) — an optical, not geometric,
    /// balance. Measured on the rendered pixels (2×).
    func testStandardHeaderLineSitsMidwayBetweenRowAndDivider() throws {
        let presentations = samplePresentations()
        let personal = try XCTUnwrap(presentations.first { $0.account.label == "Personal" })
        let client = try XCTUnwrap(presentations.first { $0.account.label == "Client" })
        let advice = SwitchAdvice(
            provider: .claude, fromAccountID: client.id, fromLabel: "Client",
            toAccountID: personal.id, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let line = resolvedHex(Theme.lineNS, appearance)
            for (kind, advised) in [("reset", [SwitchAdvice]()), ("switch", [advice])] {
                let rep = try render(
                    menuBar(presentations, layout: .standard, switchAdvice: advised),
                    scheme
                )
                let gaps = try headerLineGaps(rep, dividerHex: line)
                // Optical correction: ~3pt (6px at 2×) more room under the
                // bordered control than above the divider, ±1pt.
                XCTAssertEqual(
                    gaps.above, gaps.below + 6, accuracy: 2,
                    "\(suffix) \(kind): \(gaps.above)px above vs \(gaps.below)px below"
                )
                if kind == "reset" {
                    try write(rep, "standard-header-spacing-\(suffix).png")
                } else {
                    try write(rep, "standard-header-spacing-switch-\(suffix).png")
                }
            }
        }
    }

    /// Blank pixel rows between the header row's ink and the line's ink, and
    /// between the line's ink and the first divider.
    private func headerLineGaps(_ rep: NSBitmapImageRep, dividerHex: UInt32) throws -> (above: Int, below: Int) {
        var pixel = [Int](repeating: 0, count: 4)
        let width = rep.pixelsWide
        func distance(_ x: Int, _ y: Int, _ rgb: [Int]) -> Int {
            rep.getPixel(&pixel, atX: x, y: y)
            return abs(pixel[0] - rgb[0]) + abs(pixel[1] - rgb[1]) + abs(pixel[2] - rgb[2])
        }
        let divider: [Int] = [Int(dividerHex >> 16 & 0xFF), Int(dividerHex >> 8 & 0xFF), Int(dividerHex & 0xFF)]
        // First full-width divider row below the top 20 px.
        var dividerY: Int?
        for y in 20..<rep.pixelsHigh {
            var hits = 0
            for x in stride(from: 0, to: width, by: 2) where distance(x, y, divider) <= 12 { hits += 1 }
            if hits * 2 * 10 >= width * 9 { dividerY = y; break }
        }
        let bottom = try XCTUnwrap(dividerY, "divider under the header")
        // Ink = anything off the row's own background (sampled at x = 1).
        func hasInk(_ y: Int) -> Bool {
            rep.getPixel(&pixel, atX: 1, y: y)
            let ground: [Int] = [pixel[0], pixel[1], pixel[2]]
            for x in 20..<(width - 20) where distance(x, y, ground) > 40 { return true }
            return false
        }
        var y = bottom - 1
        while y > 0, !hasInk(y) { y -= 1 }
        let lineBottom = y
        while y > 0, hasInk(y) { y -= 1 }
        let lineTop = y + 1
        while y > 0, !hasInk(y) { y -= 1 }
        let rowBottom = y
        return (above: lineTop - rowBottom - 1, below: bottom - lineBottom - 1)
    }

    func testStandardHeaderShowsTheLayoutSwitch() throws {
        let presentations = samplePresentations()
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let rep = try render(menuBar(presentations, layout: .standard), scheme)
            try write(rep, "standard-header-switch-\(suffix).png")
            XCTAssertGreaterThan(count(rep, resolvedHex(Theme.panelNS, appearance), rows: 90), 400, suffix)
            // Standard keeps its NEXT RESET line.
            XCTAssertTrue(contains(rep, resolvedHex(Theme.resetAccentNS, appearance)), suffix)
        }
        // With no accounts the header still carries the switch.
        let empty = try render(menuBar([], layout: .standard), .dark)
        XCTAssertGreaterThan(count(empty, resolvedHex(Theme.panelNS, .darkAqua), rows: 90), 400)
    }

    /// Every v2 text colour on the popover ground, both appearances.
    func testV2TextColoursMeetContrast() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let ink: UInt32 = resolvedHex(Theme.inkNS, appearance)
            let panel: UInt32 = resolvedHex(Theme.panelNS, appearance)
            for color in [Theme.critNS, Theme.warnNS, Theme.calmNS, Theme.creamDimNS, Theme.creamFaintNS, Theme.activeNS] {
                XCTAssertGreaterThanOrEqual(contrast(resolvedHex(color, appearance), ink), 4.5, "\(appearance) \(color)")
            }
            XCTAssertGreaterThanOrEqual(contrast(resolvedHex(Theme.creamNS, appearance), panel), 4.5, "\(appearance)")
        }
    }

    // MARK: Window tags

    /// "↻ NEXT RESET Personal [5H] 22m" in the Standard header.
    func testStandardResetLineDrawsTheWindowAsATag() throws {
        let presentations = samplePresentations()
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let rep = try render(menuBar(presentations, layout: .standard), scheme)
            try write(rep, "standard-reset-line-\(suffix).png")
            // The account label is primary text now, and the countdown keeps reset blue.
            XCTAssertTrue(contains(rep, resolvedHex(Theme.resetAccentNS, appearance)), suffix)
        }
    }

    /// I: the Standard cards' FABLE / 5H / WK titles as tags. Cards render
    /// directly — the offscreen renderer leaves the popover's scroll list blank.
    func testCardsDrawWindowTags() throws {
        let presentations = samplePresentations().filter { !$0.account.isPaused && $0.account.provider != .cursor }
        let cards = VStack(spacing: 0) {
            ForEach(presentations) { presentation in
                AccountCardView(presentation: presentation, onReauthenticate: {}, now: self.now)
            }
        }
        .frame(width: 540)
        .background(Theme.ink)
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let rep = try render(cards, scheme)
            try write(rep, "cards-window-tags-\(suffix).png")
            XCTAssertEqual(rep.pixelsWide, 540 * 2, suffix)
        }
    }

    // MARK: K — header ring mark

    /// The popover header with the ring mark in place of "$", cropped to the
    /// header row. Gold arc pixels sit left of the wordmark.
    func testHeaderDrawsTheRingMark() throws {
        for (scheme, appearance) in [(ColorScheme.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            let suffix = scheme == .dark ? "dark" : "light"
            let rep = try render(menuBar(samplePresentations(), layout: .standard), scheme)
            let cropped = try XCTUnwrap(rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: 76)))
            let header = NSBitmapImageRep(cgImage: cropped)
            try write(header, "header-logo-\(suffix).png")
            // Gold only in the mark's box (x < 13 + 17 pt + slack).
            let gold: UInt32 = resolvedHex(Theme.goldNS, appearance)
            var pixel = [Int](repeating: 0, count: 4)
            var inMark = 0
            for y in 0..<header.pixelsHigh {
                for x in 0..<(34 * 2) {
                    header.getPixel(&pixel, atX: x, y: y)
                    let hex = UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
                    if contrast(hex, gold) < 1.1 { inMark += 1 }
                }
            }
            XCTAssertGreaterThan(inMark, 200, suffix)
        }
    }
}
