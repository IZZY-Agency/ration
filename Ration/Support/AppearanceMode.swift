import AppKit

/// The user's appearance choice. `system` follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String { title(locale: .current) }

    func title(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .system: .appearanceModeSystem
        case .light: .appearanceModeLight
        case .dark: .appearanceModeDark
        }
        return resource.string(in: locale)
    }

    /// What `NSApp.appearance` (and each window's) is set to. `nil` = inherit
    /// the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
