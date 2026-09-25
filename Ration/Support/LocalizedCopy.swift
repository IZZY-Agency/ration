import Foundation

extension LocalizedStringResource {
    /// This catalog entry in `locale`'s language — the one way copy code
    /// resolves a generated symbol, so every caller can pin a language
    /// (tests) or default to the running one (`.current`).
    ///
    /// A locale whose language the app does not ship (macOS order "de, fr":
    /// the bundle runs in French while `Locale.current` may still say
    /// German) resolves in the language the bundle chose, so this copy never
    /// disagrees with the rest of the UI.
    func string(in locale: Locale) -> String {
        var resource = self
        resource.locale = LocalizedCopy.shippedLocale(for: locale)
        return String(localized: resource)
    }
}

enum LocalizedCopy {
    /// `locale` when the app ships its language, else the language the
    /// bundle resolved (`AppLanguage`, the one rule for which language the
    /// app is in).
    static func shippedLocale(for locale: Locale, bundle: Bundle = .main) -> Locale {
        if AppLanguage.supported(locale.identifier) != nil { return locale }
        return Locale(identifier: AppLanguage.resolved(bundle: bundle).rawValue)
    }
}
