import SwiftUI

extension Provider {
    /// Single-letter glyph distinguishing providers in compact marks.
    var markLetter: String {
        switch self {
        case .claude: "C"
        case .chatGPT: "G"
        // "C" belongs to Claude, so Cursor takes a two-letter mark rather than
        // a colliding initial (ChatGPT already uses "G" for the same reason).
        case .cursor: "Cu"
        }
    }

    /// The provider's brand accent, used for marks and rails.
    var markAccent: Color {
        switch self {
        case .claude: Theme.gold
        case .chatGPT: Theme.calm
        case .cursor: Theme.iris
        }
    }

    /// `markAccent` for AppKit surfaces (the menu bar's in-use dots). Bridged
    /// from the single SwiftUI source of truth rather than re-stating the hex;
    /// `testMarkAccentNSPinsBrandHexes` pins that the bridge resolves to the
    /// exact brand values.
    var markAccentNS: NSColor {
        NSColor(markAccent)
    }
}
