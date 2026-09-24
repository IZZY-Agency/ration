import AppKit
import SwiftUI
import XCTest
@testable import Ration

@MainActor
final class ThemeContrastTests: XCTestCase {
    // (token, dark D2, light L2) — verbatim from the spec table.
    static let pins: [(String, NSColor, UInt32, UInt32)] = [
        ("ink", Theme.inkNS, 0x141519, 0xEDEBE4),
        ("panel", Theme.panelNS, 0x1D1F24, 0xF8F7F3),
        ("line", Theme.lineNS, 0x2F3239, 0xDDD9CF),
        ("line2", Theme.line2NS, 0x3A3E46, 0xCFCABE),
        ("track", Theme.trackNS, 0x2B2E35, 0xE3E0D7),
        ("hover", Theme.hoverNS, 0x23252B, 0xF0EEE8),
        ("cream", Theme.creamNS, 0xE8E8EB, 0x1F1E1A),
        ("creamDim", Theme.creamDimNS, 0xAEB0B6, 0x4F4C44),
        ("creamFaint", Theme.creamFaintNS, 0x8D9097, 0x6A665C),
        ("gold", Theme.goldNS, 0xD9B44A, 0x836400),
        ("iris", Theme.irisNS, 0xB0A6EE, 0x5A55B5),
        ("chatGPTGreen", Theme.chatGPTGreenNS, 0x5CC79F, 0x0F7657),
        ("calm", Theme.calmNS, 0x98AABE, 0x4B5C70),
        ("warn", Theme.warnNS, 0xDDA05E, 0x9C5210),
        ("crit", Theme.critNS, 0xEC7C7C, 0xB5332E),
        ("resetAccent", Theme.resetAccentNS, 0x8FB8F2, 0x21667A),
        ("active", Theme.activeNS, 0x8FC79A, 0x3B7239),
    ]
    static let textTokens: Set = ["cream", "creamDim", "creamFaint", "gold", "iris", "chatGPTGreen",
                                  "calm", "warn", "crit", "resetAccent", "active"]

    func testEveryTokenResolvesToItsSpecHexInBothAppearances() {
        for (name, color, dark, light) in Self.pins {
            XCTAssertEqual(resolvedHex(color, .darkAqua), dark, "\(name) dark")
            XCTAssertEqual(resolvedHex(color, .aqua), light, "\(name) light")
        }
    }

    func testEveryTextTokenPassesAAOnBothGrounds() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let ink = resolvedHex(Theme.inkNS, appearance)
            let panel = resolvedHex(Theme.panelNS, appearance)
            for (name, color, _, _) in Self.pins where Self.textTokens.contains(name) {
                let fg = resolvedHex(color, appearance)
                XCTAssertGreaterThanOrEqual(contrast(fg, ink), 4.5, "\(name) on ink, \(appearance.rawValue)")
                XCTAssertGreaterThanOrEqual(contrast(fg, panel), 4.5, "\(name) on panel, \(appearance.rawValue)")
            }
        }
    }

    /// Provider mark letters sit on `accent.opacity(markFillOpacity)` over
    /// `panel` (BillingCycleView, SettingsSidebar, AccountDetailView).
    func testCompositedMarkLettersPassAA() {
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, ColorScheme.light)] {
            let panel = resolvedHex(Theme.panelNS, appearance)
            for accent in [Theme.goldNS, Theme.chatGPTGreenNS, Theme.irisNS] {
                let fg = resolvedHex(accent, appearance)
                let fill = composite(fg, alpha: Theme.markFillOpacity(scheme), over: panel)
                XCTAssertGreaterThanOrEqual(contrast(fg, fill), 4.5, "\(fg) on its fill, \(appearance.rawValue)")
            }
        }
    }

    /// ChatGPT's identity colour must never read as a state: its resolved
    /// accent differs from every semantic tier in both appearances. (It was
    /// `calm` until 1.2.x, so a ChatGPT card looked permanently "fine".)
    func testChatGPTAccentIsClearOfEverySemanticTier() {
        let semantic: [(String, NSColor)] = [
            ("calm", Theme.calmNS), ("active", Theme.activeNS), ("resetAccent", Theme.resetAccentNS),
            ("warn", Theme.warnNS), ("crit", Theme.critNS),
        ]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let chatGPT = resolvedHex(Provider.chatGPT.markAccentNS, appearance)
            XCTAssertEqual(chatGPT, resolvedHex(Theme.chatGPTGreenNS, appearance), "ChatGPT accent is OpenAI green, \(appearance.rawValue)")
            for (name, color) in semantic {
                XCTAssertNotEqual(chatGPT, resolvedHex(color, appearance), "ChatGPT == \(name), \(appearance.rawValue)")
            }
        }
    }

    /// Near-neighbour colours must stay visibly apart, measured as CIE76 ΔE
    /// (sRGB → Lab, D65) in both appearances. Floor 12 ≈ 5× the just-
    /// noticeable difference (ΔE ≈ 2.3). It is not 20: the owner approved
    /// these hexes side by side, and each pair plays different roles, which
    /// keeps them apart in use. ChatGPT green is identity and `active` is
    /// state; `calm` is a meter fill and `resetAccent` is countdown text.
    /// Measured at 1.2.x: green/active 14.6 dark, 17.2 light; calm/reset 21.6
    /// dark, 13.7 light; green/calm ≈ 45 dark, 41.5 light.
    func testNeighbourColoursStayPerceptiblyApart() {
        let pairs: [(String, NSColor, NSColor)] = [
            ("chatGPTGreen/active", Theme.chatGPTGreenNS, Theme.activeNS),
            ("calm/resetAccent", Theme.calmNS, Theme.resetAccentNS),
            ("chatGPTGreen/calm", Theme.chatGPTGreenNS, Theme.calmNS),
        ]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (name, a, b) in pairs {
                let distance = deltaE76(resolvedHex(a, appearance), resolvedHex(b, appearance))
                XCTAssertGreaterThanOrEqual(distance, 12, "\(name) ΔE \(distance), \(appearance.rawValue)")
            }
        }
    }

    func testHoverRowKeepsPrimaryAndResetTextAA() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let hover = resolvedHex(Theme.hoverNS, appearance)
            for color in [Theme.creamNS, Theme.creamFaintNS, Theme.resetAccentNS, Theme.critNS, Theme.warnNS] {
                XCTAssertGreaterThanOrEqual(contrast(resolvedHex(color, appearance), hover), 4.5)
            }
        }
    }

    /// A highlighted (in-use) account card draws `cardHighlightBase` (Dark:
    /// the popover's `ink`, i.e. no lift; Light: the raised `panel`) washed
    /// with `active` at `cardHighlightOpacity`; every text token that can sit
    /// on the card must stay AA on that composite.
    func testHighlightedCardKeepsTextAA() {
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, ColorScheme.light)] {
            let wash = highlightWash(appearance, scheme)
            for (name, color, _, _) in Self.pins where Self.textTokens.contains(name) {
                let fg = resolvedHex(color, appearance)
                XCTAssertGreaterThanOrEqual(contrast(fg, wash), 4.5, "\(name) on highlighted card, \(appearance.rawValue)")
            }
        }
    }

    /// Light mode had a near-invisible in-use card: a 2 % wash on the grey
    /// page (1.02 : 1). The card now lifts onto `panel`, so its surface must
    /// visibly differ from the page, and it must stay tinted green.
    func testLightHighlightedCardLiftsOffThePage() {
        let ink = resolvedHex(Theme.inkNS, .aqua)
        let wash = highlightWash(.aqua, .light)
        XCTAssertEqual(resolvedHex(Theme.cardHighlightBaseNS, .aqua), resolvedHex(Theme.panelNS, .aqua))
        XCTAssertEqual(resolvedHex(Theme.cardHighlightBaseNS, .darkAqua), resolvedHex(Theme.inkNS, .darkAqua))
        XCTAssertGreaterThanOrEqual(contrast(wash, ink), 1.05, "light in-use card must read as a raised surface")
        XCTAssertGreaterThan(Theme.cardHighlightOpacity(.light), 0.02)
    }

    /// The frame is the state signal: in use ≥ 3 : 1 against the card's
    /// surroundings (WCAG 1.4.11) in both appearances; last used is dimmer by
    /// design but must stay visible (≥ 2 : 1 — the "last used" text carries
    /// the state too). Light draws it thicker, since a dark hairline on a
    /// light ground reads weaker than a bright one on near-black.
    func testInUseFrameIsVisibleInBothAppearances() {
        for (appearance, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, ColorScheme.light)] {
            let ink = resolvedHex(Theme.inkNS, appearance)
            let active = resolvedHex(Theme.activeNS, appearance)
            XCTAssertGreaterThanOrEqual(contrast(active, ink), 3.0, "in-use frame, \(appearance.rawValue)")
            let lastUsed = composite(active, alpha: Theme.lastUsedFrameOpacity(scheme), over: ink)
            XCTAssertGreaterThanOrEqual(contrast(lastUsed, ink), 2.0, "last-used frame, \(appearance.rawValue)")
            XCTAssertLessThan(Theme.lastUsedFrameOpacity(scheme), 1)
        }
        XCTAssertGreaterThan(Theme.highlightFrameWidth(.light), Theme.highlightFrameWidth(.dark))
    }

    private func highlightWash(_ appearance: NSAppearance.Name, _ scheme: ColorScheme) -> UInt32 {
        composite(resolvedHex(Theme.activeNS, appearance),
                  alpha: Theme.cardHighlightOpacity(scheme),
                  over: resolvedHex(Theme.cardHighlightBaseNS, appearance))
    }

    /// Labels drawn ON an accent fill: gold prominent buttons and gold pills
    /// (`GoldProminentButtonStyle`, Add Account, the billing CTA) use
    /// `onGold`; the IN USE pill draws `ink` on `active`.
    func testLabelsOnAccentFillsPassAA() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let gold = resolvedHex(Theme.goldNS, appearance)
            XCTAssertGreaterThanOrEqual(contrast(resolvedHex(Theme.onGoldNS, appearance), gold), 4.5,
                                        "onGold on gold, \(appearance.rawValue)")
            XCTAssertGreaterThanOrEqual(
                contrast(resolvedHex(Theme.inkNS, appearance), resolvedHex(Theme.activeNS, appearance)), 4.5,
                "IN USE: ink on active, \(appearance.rawValue)")
        }
        XCTAssertEqual(resolvedHex(Theme.onGoldNS, .darkAqua), 0x141519)
        XCTAssertEqual(resolvedHex(Theme.onGoldNS, .aqua), 0xFFFFFF)
    }

    /// The SwiftUI token must wrap the SAME dynamic colour: bridging back to
    /// NSColor and resolving in both orders must give both values.
    func testSwiftUIBridgeStaysDynamic() {
        let bridged = NSColor(Theme.gold)
        XCTAssertEqual(resolvedHex(bridged, .darkAqua), 0xD9B44A)
        XCTAssertEqual(resolvedHex(bridged, .aqua), 0x836400)
        XCTAssertEqual(resolvedHex(bridged, .darkAqua), 0xD9B44A)
        let mark = Provider.claude.markAccentNS
        XCTAssertEqual(resolvedHex(mark, .aqua), 0x836400)
        XCTAssertEqual(resolvedHex(mark, .darkAqua), 0xD9B44A)
    }

    // MARK: Increase Contrast
    //
    // `NSAppearance(named:)` cannot build a high-contrast appearance — asked
    // for `.accessibilityHighContrastDarkAqua` it returns plain dark aqua
    // (probed on macOS 27) — so these pin the two halves separately: which
    // variant each appearance name selects, and each variant's values.

    func testEachAppearanceNameSelectsItsVariant() {
        XCTAssertEqual(Theme.variant(bestMatch: .darkAqua, increaseContrast: false), .dark)
        XCTAssertEqual(Theme.variant(bestMatch: .aqua, increaseContrast: false), .light)
        XCTAssertEqual(Theme.variant(bestMatch: .accessibilityHighContrastDarkAqua, increaseContrast: false), .highContrastDark)
        XCTAssertEqual(Theme.variant(bestMatch: .accessibilityHighContrastAqua, increaseContrast: false), .highContrastLight)
        XCTAssertEqual(Theme.variant(bestMatch: nil, increaseContrast: false), .light)
        XCTAssertEqual(Theme.variantAppearanceNames, [
            .darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
        ])
    }

    static let tones: [(String, Theme.Tone)] = [
        ("line", Theme.lineTone), ("line2", Theme.line2Tone), ("track", Theme.trackTone),
        ("creamDim", Theme.creamDimTone), ("creamFaint", Theme.creamFaintTone),
    ]

    /// Normal appearances stay byte-identical: every tone's normal pair is
    /// the pinned D2 / L2 hex (the resolved pins above cover the NSColor).
    func testTonesKeepTheirNormalHexes() {
        let pinned = Dictionary(uniqueKeysWithValues: Self.pins.map { ($0.0, ($0.2, $0.3)) })
        for (name, tone) in Self.tones {
            XCTAssertEqual(tone.dark, pinned[name]?.0, "\(name) dark")
            XCTAssertEqual(tone.light, pinned[name]?.1, "\(name) light")
        }
    }

    /// With Increase Contrast on, hairlines and the meter track are real
    /// boundaries (WCAG 1.4.11, ≥ 3 : 1) against both grounds, and the
    /// faintest label reaches AAA (≥ 7 : 1). The grounds do not change.
    func testIncreaseContrastStrengthensLinesTrackAndFaintText() {
        let grounds: [(Theme.Variant, ink: UInt32, panel: UInt32)] = [
            (.highContrastDark, resolvedHex(Theme.inkNS, .darkAqua), resolvedHex(Theme.panelNS, .darkAqua)),
            (.highContrastLight, resolvedHex(Theme.inkNS, .aqua), resolvedHex(Theme.panelNS, .aqua)),
        ]
        for (variant, ink, panel) in grounds {
            for (name, tone) in Self.tones {
                let minimum = name.hasPrefix("cream") ? 7.0 : 3.0
                let hex = tone.hex(variant)
                XCTAssertGreaterThanOrEqual(contrast(hex, ink), minimum, "\(name) on ink, \(variant)")
                XCTAssertGreaterThanOrEqual(contrast(hex, panel), minimum, "\(name) on panel, \(variant)")
            }
            // The hierarchy survives: dim text stays stronger than faint text,
            // and the stronger divider stays stronger than the hairline.
            XCTAssertGreaterThan(contrast(Theme.creamDimTone.hex(variant), panel),
                                 contrast(Theme.creamFaintTone.hex(variant), panel), "dim vs faint, \(variant)")
            XCTAssertGreaterThan(contrast(Theme.line2Tone.hex(variant), panel),
                                 contrast(Theme.lineTone.hex(variant), panel), "line2 vs line, \(variant)")
        }
    }

    // MARK: Increase Contrast flag
    //
    // The popover, the drop and the explicit Light/Dark modes all use
    // hand-made `NSAppearance(named: .darkAqua/.aqua)`, whose `bestMatch`
    // never answers a high-contrast name — so the system flag decides too.

    /// Pinned off by default, so the normal pins hold even on a Mac that has
    /// Increase Contrast turned on.
    override func setUp() async throws {
        Theme.increaseContrastOverride = false
    }

    override func tearDown() async throws {
        Theme.increaseContrastOverride = nil
    }

    func testIncreaseContrastFlagSwitchesPlainAppearancesToHighContrast() {
        Theme.increaseContrastOverride = true
        let tokens: [(String, NSColor, Theme.Tone)] = [
            ("line", Theme.lineNS, Theme.lineTone), ("line2", Theme.line2NS, Theme.line2Tone),
            ("track", Theme.trackNS, Theme.trackTone), ("creamDim", Theme.creamDimNS, Theme.creamDimTone),
            ("creamFaint", Theme.creamFaintNS, Theme.creamFaintTone),
        ]
        for (name, color, tone) in tokens {
            XCTAssertEqual(resolvedHex(color, .darkAqua), tone.highContrastDark, "\(name) dark, flag on")
            XCTAssertEqual(resolvedHex(color, .aqua), tone.highContrastLight, "\(name) light, flag on")
        }
        // Grounds and single-tone tokens do not move.
        XCTAssertEqual(resolvedHex(Theme.inkNS, .darkAqua), 0x141519)
        XCTAssertEqual(resolvedHex(Theme.goldNS, .aqua), 0x836400)
    }

    func testIncreaseContrastFlagOffKeepsTheNormalPins() {
        Theme.increaseContrastOverride = false
        for (name, color, dark, light) in Self.pins {
            XCTAssertEqual(resolvedHex(color, .darkAqua), dark, "\(name) dark, flag off")
            XCTAssertEqual(resolvedHex(color, .aqua), light, "\(name) light, flag off")
        }
    }

    func testVariantHonoursTheFlagAndTheHighContrastNames() {
        XCTAssertEqual(Theme.variant(bestMatch: .darkAqua, increaseContrast: true), .highContrastDark)
        XCTAssertEqual(Theme.variant(bestMatch: .aqua, increaseContrast: true), .highContrastLight)
        XCTAssertEqual(Theme.variant(bestMatch: .darkAqua, increaseContrast: false), .dark)
        XCTAssertEqual(Theme.variant(bestMatch: .accessibilityHighContrastAqua, increaseContrast: false), .highContrastLight)
    }
}
