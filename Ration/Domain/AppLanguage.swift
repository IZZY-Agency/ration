import Foundation

/// The app's UI language: English (the source), French or Ukrainian, or
/// whatever macOS picks from the user's language order.
///
/// The override is the standard per-app `AppleLanguages` preference — the same
/// one System Settings › Language & Region › Applications writes — so the
/// bundle resolves it at launch and nothing else in the app has to know about
/// it. Changing it takes effect on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case french = "fr"
    case ukrainian = "uk"

    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Name in its own language, so a user can find theirs whatever the UI is
    /// currently showing ("System" is localized in the current language).
    var nativeName: String {
        switch self {
        case .system: String(localized: .commonSystem)
        case .english: "English"
        case .french: "Français"
        case .ukrainian: "Українська"
        }
    }

    /// The override stored in the app's own domain, or `.system` when none.
    static func stored() -> AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier else { return .system }
        return stored(in: .standard, domain: domain)
    }

    /// Sets or, for `.system`, removes the app's own override.
    static func store(_ language: AppLanguage) {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        store(language, in: .standard, domain: domain)
    }

    /// The override stored in `AppleLanguages`, or `.system` when none.
    ///
    /// `domain` is the persistent domain `defaults` writes to: the bundle
    /// identifier for `.standard`, the suite name for a suite. Only that domain
    /// is read, because `object(forKey:)` falls through to domains this app
    /// never chose: the argument domain (`-AppleLanguages (en)`, which
    /// `xcodebuild -testLanguage` and Xcode's scheme language set) shadows the
    /// stored value, and the global domain holds the user's whole macOS
    /// language order.
    ///
    /// A single entry counts by its language, so a regional code written by
    /// System Settings › Language & Region › Applications (`fr-FR`, `uk-UA`)
    /// reads as that language. Several entries, or one unsupported language,
    /// are not a choice this picker can show: `.system`.
    static func stored(in defaults: UserDefaults, domain: String) -> AppLanguage {
        guard let codes = defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              codes.count == 1
        else { return .system }
        return supported(codes[0]) ?? .system
    }

    /// `.system` removes the override so the macOS language order applies
    /// again. Takes the same `domain` as `stored` so a caller cannot write one
    /// domain and read another; a mismatched pair traps in debug builds.
    static func store(_ language: AppLanguage, in defaults: UserDefaults, domain: String) {
        if language == .system {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set([language.rawValue], forKey: defaultsKey)
        }
        assert(
            stored(in: defaults, domain: domain) == language,
            "AppLanguage.store: '\(domain)' is not the domain these defaults write to"
        )
    }

    /// The language the running bundle resolved — never `.system`.
    static func resolved(bundle: Bundle = .main) -> AppLanguage {
        resolved(first: bundle.preferredLocalizations.first)
    }

    /// English unless the bundle resolved one of the translations.
    static func resolved(first localization: String?) -> AppLanguage {
        localization.flatMap(supported) ?? .english
    }

    /// The shipped language a localization code names, by its language part
    /// (`fr-CA`, `fr_CA`, `uk-UA`, `en-GB`); nil when unsupported.
    static func supported(_ code: String) -> AppLanguage? {
        guard let language = Locale.Language(identifier: code).languageCode?.identifier,
              let match = AppLanguage(rawValue: language),
              match != .system
        else { return nil }
        return match
    }

    static var current: AppLanguage { resolved() }
}
