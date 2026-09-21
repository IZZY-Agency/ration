import SwiftUI
import CoreText

/// The izzy "Terminal Ledger" design tokens. Dark-only: the app forces a dark
/// appearance, so these are literal values rather than dynamic light/dark pairs.
enum Theme {
    // Grounds
    static let ink = Color(hex: 0x0A0B10)
    static let panel = Color(hex: 0x12141C)
    static let line = Color.cream.opacity(0.10)
    static let line2 = Color.cream.opacity(0.16)

    // Text
    static let cream = Color(hex: 0xDDDACF)
    static let creamDim = Color.cream.opacity(0.56)
    static let creamFaint = Color.cream.opacity(0.32)

    // Accent (brand) — kept separate from the semantic tiers below.
    static let gold = Color(hex: 0xF5C518)
    static let goldSoft = Color(hex: 0xF5C518).opacity(0.16)

    // Cursor's brand accent — a muted iris. Gold (Claude) and `calm` (ChatGPT)
    // are taken, and this must also stay clear of `resetAccent`'s cyan and
    // `active`'s green so a Cursor rail never reads as a state signal.
    static let iris = Color(hex: 0x8C9EFF)

    // Semantic usage tiers.
    static let calm = Color(hex: 0x6FB2A6)
    static let warn = Color(hex: 0xE8A33D)
    static let crit = Color(hex: 0xE5484D)

    // Reset countdown — a bright cyan, distinct from the accent and the tiers,
    // to make "time until reset" pop.
    static let resetAccent = Color(hex: 0x67E8F9)

    // "In use" marker — a soft green, distinct from the gold accent, the teal
    // `.current` state dot, and the warn/crit tiers, so "which account am I
    // using" reads on its own.
    static let active = Color(hex: 0x8FD694)

    // NSColor mirrors for AppKit window/popover backgrounds.
    static let inkNS = NSColor(srgbRed: 0x0A/255, green: 0x0B/255, blue: 0x10/255, alpha: 1)
    // `active` mirror for the AppKit menu-bar in-use dot (pinned by
    // `testActiveNSPinsThemeActiveHex` so it can't drift from the SwiftUI pill).
    static let activeNS = NSColor(srgbRed: 0x8F/255, green: 0xD6/255, blue: 0x94/255, alpha: 1)

    // MARK: Fonts (registered PostScript names)
    static func display(_ size: CGFloat, _ weight: DisplayWeight = .medium) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size)
    }

    enum DisplayWeight {
        case medium, semibold, bold
        var postScriptName: String {
            switch self {
            case .medium: "SpaceGrotesk-Medium"
            case .semibold: "SpaceGrotesk-SemiBold"
            case .bold: "SpaceGrotesk-Bold"
            }
        }
    }

    /// The usage-tier color for a used fraction, matching `UsageColorTier`.
    static func tierColor(usedFraction: Double) -> Color {
        switch UsageColorTier(usedFraction: usedFraction) {
        case .blue: calm
        case .orange: warn
        case .red: crit
        }
    }
}

extension Color {
    static let cream = Color(hex: 0xDDDACF)

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// One-time registration of the bundled izzy typefaces. Call before any view
/// renders (top of app launch). Registration is process-wide; `Font.custom`
/// then resolves each PostScript name.
@MainActor
enum AppFonts {
    private static var didRegister = false

    @discardableResult
    static func register(in bundle: Bundle = .main) -> [String] {
        guard !didRegister else { return [] }
        didRegister = true

        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        var registered: [String] = []
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered.append(url.deletingPathExtension().lastPathComponent)
            }
            // Already-registered fonts return false with a benign error; ignore.
        }
        return registered
    }
}
