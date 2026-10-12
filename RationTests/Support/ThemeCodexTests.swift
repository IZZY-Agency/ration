import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Codex's switch controls — the CODEX tag on the ChatGPT card whose login
/// Codex uses, the outlined SWITCH on the others, the Focus line — draw in
/// their own teal. It must read on the window and card grounds, carry a
/// legible label on its fill, and stay clear of the two colours it sits
/// beside: ChatGPT green (the provider chip on the same card) and Claude
/// Code lavender (the same controls on Claude cards).
@MainActor
final class ThemeCodexTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.darkAqua, .aqua]

    func testCodexResolvesToItsHexInBothAppearances() {
        XCTAssertEqual(resolvedHex(Theme.codexNS, .darkAqua), 0x5FC9C2)
        XCTAssertEqual(resolvedHex(Theme.codexNS, .aqua), 0x176D69)
        XCTAssertEqual(resolvedHex(Theme.onCodexNS, .darkAqua), 0x141519)
        XCTAssertEqual(resolvedHex(Theme.onCodexNS, .aqua), 0xFFFFFF)
    }

    /// The outlined SWITCH and the Focus line draw `codex` text on the
    /// window ground (`ink`) and on the card (`panel`).
    func testCodexTextPassesAAOnInkAndPanel() {
        for appearance in appearances {
            let codex = resolvedHex(Theme.codexNS, appearance)
            XCTAssertGreaterThanOrEqual(contrast(codex, resolvedHex(Theme.inkNS, appearance)), 4.5,
                                        "codex on ink, \(appearance.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(codex, resolvedHex(Theme.panelNS, appearance)), 4.5,
                                        "codex on panel, \(appearance.rawValue)")
        }
    }

    /// The filled CODEX tag: `onCodex` on a `codex` fill.
    func testTheCodexTagPassesAA() {
        for appearance in appearances {
            XCTAssertGreaterThanOrEqual(
                contrast(resolvedHex(Theme.onCodexNS, appearance), resolvedHex(Theme.codexNS, appearance)), 4.5,
                "onCodex on codex, \(appearance.rawValue)")
        }
    }

    /// Teal is the nearest candidate to ChatGPT green, so hold it to the
    /// suite's "perceptibly apart" bar (ΔE76 ≥ 12, as in
    /// `ThemeContrastTests.testNeighbourColoursStayPerceptiblyApart`).
    /// Measured: 18.6 dark / 17.8 light from green; 58.8 / 70.3 from lavender.
    func testCodexStaysClearOfChatGPTGreenAndClaudeCode() {
        for appearance in appearances {
            let codex = resolvedHex(Theme.codexNS, appearance)
            for (name, other) in [("chatGPTGreen", Theme.chatGPTGreenNS), ("claudeCode", Theme.claudeCodeNS)] {
                let distance = deltaE76(codex, resolvedHex(other, appearance))
                XCTAssertGreaterThanOrEqual(distance, 12, "codex/\(name) ΔE \(distance), \(appearance.rawValue)")
            }
        }
    }

    /// The SwiftUI tokens wrap the same dynamic colours.
    func testSwiftUITokensStayDynamic() {
        XCTAssertEqual(resolvedHex(NSColor(Theme.codex), .darkAqua), 0x5FC9C2)
        XCTAssertEqual(resolvedHex(NSColor(Theme.codex), .aqua), 0x176D69)
        XCTAssertEqual(resolvedHex(NSColor(Theme.onCodex), .darkAqua), 0x141519)
        XCTAssertEqual(resolvedHex(NSColor(Theme.onCodex), .aqua), 0xFFFFFF)
    }
}
