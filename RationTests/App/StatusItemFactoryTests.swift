import AppKit
import XCTest
@testable import Ration

@MainActor
final class StatusItemFactoryTests: XCTestCase {
    func testStatusItemIsVisibleAndCannotBeRemoved() {
        let statusBar = NSStatusBar.system
        let statusItem = StatusItemFactory.make(in: statusBar)
        defer { statusBar.removeStatusItem(statusItem) }

        XCTAssertEqual(
            statusItem.autosaveName,
            StatusItemFactory.autosaveName
        )
        XCTAssertTrue(statusItem.isVisible)
        XCTAssertFalse(statusItem.behavior.contains(.removalAllowed))
        XCTAssertFalse(statusItem.behavior.contains(.terminationOnRemoval))
        XCTAssertEqual(
            statusItem.button?.image?.accessibilityDescription,
            StatusItemFactory.iconName
        )
        XCTAssertEqual(statusItem.button?.toolTip, "Ration")
    }

    /// Variable length lets the item grow for the usage rings and collapse
    /// back to icon-only width when rings are off.
    func testStatusItemUsesVariableLength() {
        let statusBar = NSStatusBar.system
        let statusItem = StatusItemFactory.make(in: statusBar)
        defer { statusBar.removeStatusItem(statusItem) }

        XCTAssertEqual(statusItem.length, NSStatusItem.variableLength)
        XCTAssertEqual(statusItem.button?.imagePosition, .imageOnly)
    }

    private let attachmentChar = "\u{FFFC}"

    func testApplyGaugesRendersOneRingAttachmentPerAccount() throws {
        let statusBar = NSStatusBar.system
        let statusItem = StatusItemFactory.make(in: statusBar)
        defer { statusBar.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        StatusItemFactory.applyGauges(
            [
                MenuBarGauge(provider: .claude, label: "AI",
                             fraction: 0.86, windowKind: .fiveHour, inUse: true),
                MenuBarGauge(provider: .claude, label: "Ada",
                             fraction: 0.32, windowKind: .fiveHour, inUse: false),
                MenuBarGauge(provider: .chatGPT, label: "ChatGPT",
                             fraction: 0.13, windowKind: .weekly, inUse: false)
            ],
            displaysRemaining: false,
            to: button
        )

        XCTAssertEqual(
            button.attributedTitle.string,
            attachmentChar + attachmentChar + attachmentChar
        )
        for index in 0...2 {
            let attachment = button.attributedTitle.attribute(
                .attachment, at: index, effectiveRange: nil
            ) as? NSTextAttachment
            XCTAssertNotNil(
                try XCTUnwrap(attachment, "missing ring \(index)").image,
                "ring \(index) has no image"
            )
        }
        XCTAssertEqual(button.imagePosition, .imageLeft)
        // Kern trails every ring but the last, so spacing scales to any count
        // while the item stays flush on the right.
        for index in 0...2 {
            let kern = button.attributedTitle.attribute(
                .kern, at: index, effectiveRange: nil
            ) as? CGFloat
            if index < 2 {
                XCTAssertEqual(kern, 3, "ring \(index) must carry trailing kern")
            } else {
                XCTAssertNil(kern, "last ring must stay flush")
            }
        }
        XCTAssertEqual(
            button.toolTip,
            "Ration — Claude AI 5h 86% used (in use)"
                + " · Claude Ada 5h 32% used"
                + " · ChatGPT weekly 13% used"
        )
        XCTAssertEqual(button.accessibilityLabel(), button.toolTip)
    }

    func testApplyNoGaugesCollapsesToIconOnly() throws {
        let statusBar = NSStatusBar.system
        let statusItem = StatusItemFactory.make(in: statusBar)
        defer { statusBar.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        StatusItemFactory.applyGauges(
            [MenuBarGauge(provider: .cursor, label: "Cursor",
                          fraction: 0.5, windowKind: .fiveHour, inUse: false)],
            displaysRemaining: false,
            to: button
        )
        StatusItemFactory.applyGauges([], displaysRemaining: false, to: button)

        XCTAssertEqual(button.attributedTitle.string, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.toolTip, "Ration")
        XCTAssertEqual(button.accessibilityLabel(), "Ration")
    }

    func testToolTipRemainingModeSaysLeft() {
        let toolTip = StatusItemFactory.toolTip(
            for: [MenuBarGauge(provider: .claude, label: "AI",
                               fraction: 0.14, windowKind: .fiveHour, inUse: false)],
            displaysRemaining: true
        )
        XCTAssertEqual(toolTip, "Ration — Claude AI 5h 14% left")
    }

    func testToolTipDoesNotRepeatProviderNameWhenLabelMatches() {
        // Account labeled exactly like its provider must not read
        // "ChatGPT ChatGPT weekly …".
        let toolTip = StatusItemFactory.toolTip(
            for: [MenuBarGauge(provider: .chatGPT, label: "ChatGPT",
                               fraction: 0.21, windowKind: .weekly, inUse: true)],
            displaysRemaining: false
        )
        XCTAssertEqual(toolTip, "Ration — ChatGPT weekly 21% used (in use)")

        let mixedCase = StatusItemFactory.toolTip(
            for: [MenuBarGauge(provider: .chatGPT, label: "chatgpt",
                               fraction: 0.21, windowKind: .weekly, inUse: false)],
            displaysRemaining: false
        )
        XCTAssertEqual(
            mixedCase, "Ration — chatgpt weekly 21% used",
            "dedup must be case-insensitive"
        )
    }

    func testWindowLabels() {
        XCTAssertEqual(StatusItemFactory.windowLabel(.fiveHour), "5h")
        XCTAssertEqual(StatusItemFactory.windowLabel(.weekly), "weekly")
        XCTAssertEqual(StatusItemFactory.windowLabel(.modelWeekly), "Fable")
    }

    /// The ring is drawn, not glyph-rendered — sample rasterized pixels to pin
    /// that the arc really fills with the given color in proportion to the
    /// fraction (a full ring strokes the top; an empty ring leaves only the
    /// faint track there).
    func testRingImageArcReflectsFractionAndColor() throws {
        func sample(_ image: NSImage, _ x: Int, _ y: Int) throws -> NSColor {
            let rep = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
            )
            let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
            return try XCTUnwrap(color.usingColorSpace(.sRGB))
        }

        let gold = Provider.claude.markAccentNS
        let full = StatusItemFactory.ringImage(fraction: 1, color: gold)
        let empty = StatusItemFactory.ringImage(fraction: 0, color: gold)
        let size = Int(full.size.width)
        let topCenter = (x: size / 2, y: 1)

        let fullTop = try sample(full, topCenter.x, topCenter.y)
        let emptyTop = try sample(empty, topCenter.x, topCenter.y)

        // Full ring: solid stroke at the top, in the provider color.
        XCTAssertGreaterThan(fullTop.alphaComponent, 0.85)
        XCTAssertEqual(fullTop.redComponent, 0xF5 / 255, accuracy: 0.06)
        XCTAssertEqual(fullTop.greenComponent, 0xC5 / 255, accuracy: 0.06)
        XCTAssertEqual(fullTop.blueComponent, 0x18 / 255, accuracy: 0.06)
        // Empty ring: only the faint track remains.
        XCTAssertLessThan(emptyTop.alphaComponent, 0.6)

        // A partial arc must be asymmetric: at 0.3 exactly one side of the
        // ring is stroked (which side is a drawing-direction detail; that
        // it differs is what proves the arc is proportional, not all-or-nothing).
        let partial = StatusItemFactory.ringImage(fraction: 0.3, color: gold)
        let left = try sample(partial, 1, size / 2)
        let right = try sample(partial, size - 2, size / 2)
        let strokedSides = [left, right].filter { $0.alphaComponent > 0.85 }.count
        XCTAssertEqual(strokedSides, 1, "fraction 0.3 should stroke exactly one side")
    }

    /// The in-use dot is drawn, not inferred: an in-use ring fills its center
    /// with `Theme.active` green; an idle ring's center stays clear. Sampled
    /// on rasterized pixels like the arc test above.
    func testRingImageCenterDotReflectsInUse() throws {
        func sample(_ image: NSImage, _ x: Int, _ y: Int) throws -> NSColor {
            let rep = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
            )
            let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
            return try XCTUnwrap(color.usingColorSpace(.sRGB))
        }

        let gold = Provider.claude.markAccentNS
        let inUse = StatusItemFactory.ringImage(fraction: 0.5, color: gold, inUse: true)
        let idle = StatusItemFactory.ringImage(fraction: 0.5, color: gold, inUse: false)
        let size = Int(inUse.size.width)
        let center = (x: size / 2, y: size / 2)

        // Wider tolerance than the arc test: the draw-context → TIFF → sRGB
        // round-trip shifts mid-tone components by up to ~0.07 (the gold arc's
        // near-extreme components barely move). The pin is "solidly the green
        // dot", not the exact hex — that is `testActiveNSPinsThemeActiveHex`.
        let dot = try sample(inUse, center.x, center.y)
        XCTAssertGreaterThan(dot.alphaComponent, 0.85)
        XCTAssertEqual(dot.redComponent, 0x8F / 255, accuracy: 0.1)
        XCTAssertEqual(dot.greenComponent, 0xD6 / 255, accuracy: 0.1)
        XCTAssertEqual(dot.blueComponent, 0x94 / 255, accuracy: 0.1)

        let clear = try sample(idle, center.x, center.y)
        XCTAssertLessThan(clear.alphaComponent, 0.1, "idle ring center must stay clear")
    }

    /// Pins the AppKit mirror to `Theme.active`'s hex so the menu-bar dot can
    /// never silently drift from the SwiftUI IN USE pill.
    func testActiveNSPinsThemeActiveHex() throws {
        let color = try XCTUnwrap(Theme.activeNS.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0x8F / 255, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0xD6 / 255, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0x94 / 255, accuracy: 0.001)
    }

    /// Pins the NSColor mirrors to the exact brand hexes of `markAccent`
    /// (Theme.gold / Theme.calm / Theme.iris), so the AppKit dots can never
    /// silently drift from the SwiftUI marks.
    func testMarkAccentNSPinsBrandHexes() throws {
        let expected: [(Provider, UInt32)] = [
            (.claude, 0xF5C518),
            (.chatGPT, 0x6FB2A6),
            (.cursor, 0x8C9EFF)
        ]
        for (provider, hex) in expected {
            let color = try XCTUnwrap(
                provider.markAccentNS.usingColorSpace(.sRGB),
                "\(provider) mark accent did not resolve to sRGB"
            )
            XCTAssertEqual(
                color.redComponent, Double((hex >> 16) & 0xFF) / 255,
                accuracy: 0.001, "\(provider) red"
            )
            XCTAssertEqual(
                color.greenComponent, Double((hex >> 8) & 0xFF) / 255,
                accuracy: 0.001, "\(provider) green"
            )
            XCTAssertEqual(
                color.blueComponent, Double(hex & 0xFF) / 255,
                accuracy: 0.001, "\(provider) blue"
            )
        }
    }
}
