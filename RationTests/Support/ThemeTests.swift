import SwiftUI
import XCTest
@testable import Ration

@MainActor
final class ThemeTests: XCTestCase {
    private static let izzyFontNames = [
        "SpaceGrotesk-Medium",
        "SpaceGrotesk-SemiBold",
        "SpaceGrotesk-Bold",
        "SpaceMono-Regular",
        "SpaceMono-Bold"
    ]

    func testAppBundleShipsEveryIzzyFontFile() {
        // Bundle.main is the app under test. This proves the .ttf files are
        // actually packaged (independent of global installs or registration).
        for name in Self.izzyFontNames {
            XCTAssertNotNil(
                Bundle.main.url(forResource: name, withExtension: "ttf"),
                "\(name).ttf is missing from the app bundle"
            )
        }
    }

    func testAppBundleShipsTheFontLicenses() {
        // Both families are SIL OFL 1.1, which requires the licence text to
        // travel with the font files — so it ships inside the bundle too.
        for name in ["SpaceGrotesk-OFL", "SpaceMono-OFL"] {
            XCTAssertNotNil(
                Bundle.main.url(forResource: name, withExtension: "txt"),
                "\(name).txt is missing from the app bundle"
            )
        }
    }

    func testBundledFontsResolveByPostScriptName() {
        // RationApp.init already registered the bundled fonts in this host;
        // registering the app bundle again is a no-op, but harmless. Each face
        // must resolve, otherwise the restyle would silently fall back to SF.
        AppFonts.register(in: .main)
        for name in Self.izzyFontNames {
            XCTAssertNotNil(
                NSFont(name: name, size: 12),
                "Font \(name) did not resolve"
            )
        }
    }

    func testTierColorMatchesUsageTier() {
        XCTAssertEqual(Theme.tierColor(usedFraction: 0.10), Theme.calm)
        XCTAssertEqual(Theme.tierColor(usedFraction: 0.60), Theme.warn)
        XCTAssertEqual(Theme.tierColor(usedFraction: 0.90), Theme.crit)
    }

    func testChatGPTWeeklyOnlyProducesSingleFullWidthSlot() {
        let weeklyOnly = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: .distantPast,
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.91, resetsAt: nil)
        )
        let kinds = AccountLimitLayout.kinds(for: .chatGPT, snapshot: weeklyOnly)
        // One kind → the meter row renders a single full-width meter (no empty
        // half), which is the behavior requested for ChatGPT.
        XCTAssertEqual(kinds, [.weekly])
    }

    func testChatGPTWithBothWindowsProducesTwoSlots() {
        let both = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: .distantPast,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: nil)
        )
        XCTAssertEqual(
            AccountLimitLayout.kinds(for: .chatGPT, snapshot: both),
            [.fiveHour, .weekly]
        )
    }
}
