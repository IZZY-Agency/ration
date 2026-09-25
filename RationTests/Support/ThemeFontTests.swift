import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Space Grotesk / Space Mono have no Cyrillic, so a Ukrainian UI draws in
/// Manrope + JetBrains Mono NL (no code ligatures) instead. English and
/// French keep the Space faces.
///
/// Runs in the pinned English `make unit-test` and in
/// `make l10n-test L10N_LANG=uk`, where the defaulted `language:` parameter
/// must pick the Ukrainian faces.
@MainActor
final class ThemeFontTests: XCTestCase {
    private static let ukrainianFontNames = [
        "Manrope-Medium",
        "Manrope-SemiBold",
        "Manrope-Bold",
        "JetBrainsMonoNL-Regular",
        "JetBrainsMonoNL-Bold"
    ]

    // MARK: Name mapping

    func testUkrainianUsesManropeAndJetBrainsMono() {
        XCTAssertEqual(Theme.DisplayWeight.medium.postScriptName(for: .ukrainian), "Manrope-Medium")
        XCTAssertEqual(Theme.DisplayWeight.semibold.postScriptName(for: .ukrainian), "Manrope-SemiBold")
        XCTAssertEqual(Theme.DisplayWeight.bold.postScriptName(for: .ukrainian), "Manrope-Bold")
        XCTAssertEqual(Theme.monoPostScriptName(bold: false, language: .ukrainian), "JetBrainsMonoNL-Regular")
        XCTAssertEqual(Theme.monoPostScriptName(bold: true, language: .ukrainian), "JetBrainsMonoNL-Bold")
    }

    func testEnglishAndFrenchKeepTheSpaceFaces() {
        for language in [AppLanguage.english, .french] {
            XCTAssertEqual(Theme.DisplayWeight.medium.postScriptName(for: language), "SpaceGrotesk-Medium")
            XCTAssertEqual(Theme.DisplayWeight.semibold.postScriptName(for: language), "SpaceGrotesk-SemiBold")
            XCTAssertEqual(Theme.DisplayWeight.bold.postScriptName(for: language), "SpaceGrotesk-Bold")
            XCTAssertEqual(Theme.monoPostScriptName(bold: false, language: language), "SpaceMono-Regular")
            XCTAssertEqual(Theme.monoPostScriptName(bold: true, language: language), "SpaceMono-Bold")
        }
    }

    func testFontsCarryTheLanguagesFace() {
        XCTAssertEqual(Theme.display(14, .bold, language: .ukrainian), .custom("Manrope-Bold", size: 14))
        XCTAssertEqual(Theme.display(14, language: .french), .custom("SpaceGrotesk-Medium", size: 14))
        XCTAssertEqual(Theme.mono(11, language: .ukrainian), .custom("JetBrainsMonoNL-Regular", size: 11))
        XCTAssertEqual(Theme.mono(11, bold: true, language: .english), .custom("SpaceMono-Bold", size: 11))
    }

    /// The source-compatible call sites (`Theme.display(12)`, `Theme.mono(9)`)
    /// follow the language this process resolved.
    func testDefaultLanguageIsTheRunLanguage() throws {
        let pinned = try PinnedTestLanguage.require()
        let face: AppLanguage = AppLanguage.supported(pinned) == .ukrainian ? .ukrainian : .english
        XCTAssertEqual(AppLanguage.current == .ukrainian, face == .ukrainian)
        XCTAssertEqual(Theme.display(12, .semibold), .custom(Theme.DisplayWeight.semibold.postScriptName(for: face), size: 12))
        XCTAssertEqual(Theme.mono(9, bold: true), .custom(Theme.monoPostScriptName(bold: true, language: face), size: 9))
    }

    // MARK: Bundle + coverage

    func testAppBundleShipsTheUkrainianFontsAndLicences() {
        for name in Self.ukrainianFontNames {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "ttf"), "\(name).ttf is missing")
        }
        for name in ["Manrope-OFL", "JetBrainsMono-OFL"] {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "txt"), "\(name).txt is missing")
        }
    }

    func testUkrainianFacesResolveAndCoverUkrainianLetters() {
        AppFonts.register(in: .main)
        let letters = "жїєґ’ЖЇЄҐ"
        for name in Self.ukrainianFontNames {
            guard let font = NSFont(name: name, size: 12) else {
                XCTFail("Font \(name) did not resolve")
                continue
            }
            XCTAssertEqual(font.fontName, name)
            // A copy installed in ~/Library/Fonts would also resolve by name
            // (JetBrains Mono NL often is on developer Macs); the face must be
            // the one this app ships.
            let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
            XCTAssertEqual(url?.resolvingSymlinksInPath().deletingLastPathComponent(),
                           Bundle.main.resourceURL?.resolvingSymlinksInPath(),
                           "\(name) resolved to \(url?.path ?? "nil"), not the bundled file")
            let covered = CTFontCopyCharacterSet(font as CTFont) as CharacterSet
            for scalar in letters.unicodeScalars {
                XCTAssertTrue(covered.contains(scalar), "\(name) lacks U+\(String(scalar.value, radix: 16, uppercase: true))")
            }
        }
    }
}
