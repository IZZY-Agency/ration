import SwiftUI
import CoreText

/// The izzy "Terminal Ledger" design tokens, in two palettes: D2 Graphite
/// (dark) and L2 Paper (light). Each token is ONE dynamic NSColor that
/// resolves per appearance at draw time; the SwiftUI `Color` wraps that same
/// object, so AppKit and SwiftUI can never disagree. Names predate the light
/// theme — `cream` is the primary TEXT colour (near-black in light mode),
/// `ink` the window GROUND.
enum Theme {
    static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    /// Which palette an appearance draws from. Increase Contrast (System
    /// Settings → Accessibility → Display) is its own pair of appearances,
    /// and only the tokens built from a `Tone` answer it.
    enum Variant: Equatable {
        case dark, light, highContrastDark, highContrastLight
    }

    static let variantAppearanceNames: [NSAppearance.Name] = [
        .darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
    ]

    /// `bestMatch` is the appearance's answer from `variantAppearanceNames`.
    ///
    /// The high-contrast names alone are not enough: the popover, the drop
    /// and the explicit Light/Dark modes use hand-made
    /// `NSAppearance(named: .darkAqua/.aqua)`, whose `bestMatch` never
    /// answers one. So the system's Increase Contrast flag also selects the
    /// high-contrast variant of the matched family.
    static func variant(bestMatch: NSAppearance.Name?, increaseContrast: Bool) -> Variant {
        switch bestMatch {
        case .accessibilityHighContrastDarkAqua?: .highContrastDark
        case .accessibilityHighContrastAqua?: .highContrastLight
        case .darkAqua?: increaseContrast ? .highContrastDark : .dark
        default: increaseContrast ? .highContrastLight : .light
        }
    }

    /// Test seam: non-nil replaces the system Increase Contrast flag. Set
    /// only by tests (and reset in their tearDown).
    nonisolated(unsafe) static var increaseContrastOverride: Bool?

    /// System Settings → Accessibility → Display → Increase Contrast.
    static var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// A token that also has Increase Contrast values. The normal pair is the
    /// same D2 / L2 hex as ever; the high-contrast pair keeps each palette's
    /// family (the grounds do not change) and only strengthens.
    struct Tone: Equatable {
        let dark: UInt32
        let light: UInt32
        let highContrastDark: UInt32
        let highContrastLight: UInt32

        func hex(_ variant: Variant) -> UInt32 {
            switch variant {
            case .dark: dark
            case .light: light
            case .highContrastDark: highContrastDark
            case .highContrastLight: highContrastLight
            }
        }
    }

    static func dynamic(_ tone: Tone) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: tone.hex(variant(
                bestMatch: appearance.bestMatch(from: variantAppearanceNames),
                increaseContrast: increaseContrast
            )))
        }
    }

    // Grounds
    /// Window / popover ground.
    static let inkNS = dynamic(dark: 0x141519, light: 0xEDEBE4)
    /// Cards and the drop panel.
    static let panelNS = dynamic(dark: 0x1D1F24, light: 0xF8F7F3)
    /// Hairlines, card borders, dividers. Increase Contrast: ≥ 3 : 1 on ink
    /// and panel (WCAG 1.4.11) — the normal hairline is ~1.3 : 1 by design.
    static let lineTone = Tone(dark: 0x2F3239, light: 0xDDD9CF, highContrastDark: 0x6E737D, highContrastLight: 0x858075)
    static let lineNS = dynamic(lineTone)
    /// Stronger divider.
    static let line2Tone = Tone(dark: 0x3A3E46, light: 0xCFCABE, highContrastDark: 0x80858F, highContrastLight: 0x747064)
    static let line2NS = dynamic(line2Tone)
    /// Meter / bar background.
    static let trackTone = Tone(dark: 0x2B2E35, light: 0xE3E0D7, highContrastDark: 0x6A6F79, highContrastLight: 0x88837A)
    static let trackNS = dynamic(trackTone)
    /// Row hover fill.
    static let hoverNS = dynamic(dark: 0x23252B, light: 0xF0EEE8)

    // Text
    /// Primary text.
    static let creamNS = dynamic(dark: 0xE8E8EB, light: 0x1F1E1A)
    /// Secondary text. Raised under Increase Contrast only to stay above
    /// `creamFaint`, which must reach 7 : 1 there.
    static let creamDimTone = Tone(dark: 0xAEB0B6, light: 0x4F4C44, highContrastDark: 0xC8CACF, highContrastLight: 0x36342E)
    static let creamDimNS = dynamic(creamDimTone)
    /// Labels (FABLE / 5H / WK), section headers. Increase Contrast: ≥ 7 : 1.
    static let creamFaintTone = Tone(dark: 0x8D9097, light: 0x6A665C, highContrastDark: 0xA9ACB3, highContrastLight: 0x4A473F)
    static let creamFaintNS = dynamic(creamFaintTone)

    // Brand + provider accents
    static let goldNS = dynamic(dark: 0xD9B44A, light: 0x836400)
    /// Cursor's accent — clear of `resetAccent` and `active` so a Cursor rail
    /// never reads as a state signal.
    static let irisNS = dynamic(dark: 0xB0A6EE, light: 0x5A55B5)
    /// ChatGPT's accent: OpenAI green, identity only. Kept apart from
    /// `active` (the "in use" state green) by hue — bluer — and by role
    /// (their lightness is nearly equal), and from the slate `calm` tier, so
    /// a ChatGPT mark or rail never reads as a state. (It was `calm`, which made a ChatGPT card look
    /// permanently "fine".)
    static let chatGPTGreenNS = dynamic(dark: 0x5CC79F, light: 0x0F7657)

    // Semantic usage tiers
    /// Low usage: a quiet slate, so teal and green (ChatGPT, `active`) never
    /// double as "fine". Distinct from `resetAccent` by saturation — reset is
    /// the saturated blue, calm the greyed one.
    static let calmNS = dynamic(dark: 0x98AABE, light: 0x4B5C70)
    static let warnNS = dynamic(dark: 0xDDA05E, light: 0x9C5210)
    static let critNS = dynamic(dark: 0xEC7C7C, light: 0xB5332E)
    /// Reset countdowns and resets.
    static let resetAccentNS = dynamic(dark: 0x8FB8F2, light: 0x21667A)
    /// "In use" marker (popover pill, menu-bar dot).
    static let activeNS = dynamic(dark: 0x8FC79A, light: 0x3B7239)

    static let ink = Color(nsColor: inkNS)
    static let panel = Color(nsColor: panelNS)
    static let line = Color(nsColor: lineNS)
    static let line2 = Color(nsColor: line2NS)
    static let track = Color(nsColor: trackNS)
    static let hover = Color(nsColor: hoverNS)
    static let cream = Color(nsColor: creamNS)
    static let creamDim = Color(nsColor: creamDimNS)
    static let creamFaint = Color(nsColor: creamFaintNS)
    static let gold = Color(nsColor: goldNS)
    static let iris = Color(nsColor: irisNS)
    static let chatGPTGreen = Color(nsColor: chatGPTGreenNS)
    static let calm = Color(nsColor: calmNS)
    static let warn = Color(nsColor: warnNS)
    static let crit = Color(nsColor: critNS)
    static let resetAccent = Color(nsColor: resetAccentNS)
    static let active = Color(nsColor: activeNS)

    /// Opacity of a provider-accent fill behind that accent's own letter.
    /// Light needs less tint: at 0.16 light gold composites to 4.16 : 1.
    static func markFillOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.16 : 0.10
    }

    /// Opacity of the `active` wash behind a highlighted (in-use) account
    /// card, over `ink`. Every text token on the card must stay AA on the
    /// composite; see `ThemeContrastTests.testHighlightedCardKeepsTextAA`.
    /// Light needs less: at 0.05 light gold composites to 4.36 : 1.
    static func cardHighlightOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.05 : 0.04
    }

    /// Surface under an in-use card's green wash. Dark: the popover's own
    /// `ink` (a bright frame on near-black already stands out). Light: the
    /// raised `panel`, like an iOS grouped card — a 2 % wash on the grey page
    /// was invisible (1.02 : 1), and lifting also RAISES text contrast
    /// (gold 4.91 : 1 on the composite) instead of spending it.
    static let cardHighlightBaseNS = dynamic(dark: 0x141519, light: 0xF8F7F3)
    static let cardHighlightBase = Color(nsColor: cardHighlightBaseNS)

    /// In-use frame width. A dark hairline on a light ground reads weaker than
    /// a bright one on near-black, so Light draws it heavier.
    static func highlightFrameWidth(_ scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 1 : 1.5
    }

    /// The last-used tail dims the in-use green to encode recency. 0.35 of the
    /// dark green on ink is 2.2 : 1; the same 0.35 in Light was 1.6 : 1 and
    /// all but vanished, so Light keeps more of it (2.37 : 1).
    static func lastUsedFrameOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.35 : 0.6
    }

    /// Label colour on a gold FILL (prominent buttons, gold pills). The
    /// system draws white on a gold-tinted `.borderedProminent` button, which
    /// is 1.99 : 1 on dark gold — hence `GoldProminentButtonStyle`. Dark: ink
    /// (9.19 : 1); light: white (5.54 : 1).
    static let onGoldNS = dynamic(dark: 0x141519, light: 0xFFFFFF)
    static let onGold = Color(nsColor: onGoldNS)

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
    static let cream = Theme.cream

    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
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
