import AppKit
import XCTest
@testable import Ration

/// The Settings sidebar must hold the longest real account row untruncated:
/// "ChatGPT 20x" plus the IN USE pill. At the +2 pt sizes the old 210 pt
/// column cut it to "ChatG…" and "IN U…" (screenshot pass, 1.2.0 (70)).
@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// Horizontal space the sidebar `List` takes around a row's content
    /// (row insets + selection-highlight insets, both sides). Calibrated from
    /// the 1.2.0 (70) screenshot: at the 210 pt ideal column the visible row
    /// content was mark + gaps + "Sbozh…" (56.1) + "IN U…" pill (47.7) ≈ 174 pt,
    /// leaving ≈ 36 pt of list chrome.
    private let listRowChrome: CGFloat = 36

    private func width(_ text: String, font name: String, size: CGFloat, tracking: CGFloat = 0) throws -> CGFloat {
        let font = try XCTUnwrap(NSFont(name: name, size: size), "\(name) did not resolve")
        return (text as NSString).size(withAttributes: [.font: font, .kern: tracking]).width
    }

    /// Row = mark 22 · label · Spacer(min 6) · pill · dot 6, with 9 pt
    /// between each of the five children (four gaps = 36).
    private func rowWidth(label: String, trailing: CGFloat) throws -> CGFloat {
        let labelWidth = try width(label, font: "SpaceGrotesk-Medium", size: 15)
        return 22 + 36 + 6 + 6 + labelWidth + trailing
    }

    private func inUsePillWidth() throws -> CGFloat {
        // Text + 5 pt horizontal padding each side.
        try width("IN USE", font: "SpaceMono-Bold", size: 11, tracking: 0.8) + 10
    }

    func testSidebarIdealWidthHoldsTheLongestRealRowWithItsPill() throws {
        AppFonts.register(in: .main)
        let needed = try rowWidth(label: "ChatGPT 20x", trailing: inUsePillWidth()) + listRowChrome
        XCTAssertGreaterThanOrEqual(SettingsSidebar.idealColumnWidth, ceil(needed))
    }

    /// Dragging the divider to its minimum must not bring the truncation back.
    func testSidebarMinimumWidthStillHoldsIt() throws {
        AppFonts.register(in: .main)
        let needed = try rowWidth(label: "ChatGPT 20x", trailing: inUsePillWidth()) + listRowChrome
        XCTAssertGreaterThanOrEqual(SettingsSidebar.minColumnWidth, ceil(needed))
    }

    /// A paused row carries the PAUSED badge between label and spacer.
    func testSidebarHoldsAPausedRow() throws {
        AppFonts.register(in: .main)
        let paused = try width("PAUSED", font: "SpaceMono-Bold", size: 10, tracking: 0.5) + 8 + 9
        let needed = try rowWidth(label: "Claude", trailing: paused) + listRowChrome
        XCTAssertGreaterThanOrEqual(SettingsSidebar.minColumnWidth, ceil(needed))
    }

    /// Widening the sidebar must not squeeze the detail pane: the window's
    /// minimum keeps the 450 pt of detail it had before (660 − 210).
    func testWindowMinimumKeepsTheDetailPaneWidth() {
        XCTAssertGreaterThanOrEqual(
            SettingsView.minimumWindowWidth,
            SettingsSidebar.idealColumnWidth + 450
        )
    }
}
