import SwiftUI

/// Settings › General › Language. The choice is the app's own
/// `AppleLanguages` override (`AppLanguage.store`), which the bundle reads at
/// launch — so a change applies after a relaunch, and the note says so.
@MainActor
final class LanguagePickerModel: ObservableObject {
    @Published private(set) var stored: AppLanguage

    /// The language this process is running in (never `.system`).
    let current: AppLanguage
    /// What macOS's own language order would give Ration: what `.system`
    /// means on the next launch.
    let systemLanguage: AppLanguage

    private let defaults: UserDefaults
    private let domain: String

    init(defaults: UserDefaults, domain: String, current: AppLanguage, systemLanguage: AppLanguage) {
        self.defaults = defaults
        self.domain = domain
        self.current = current
        self.systemLanguage = systemLanguage
        stored = AppLanguage.stored(in: defaults, domain: domain)
    }

    static func live() -> LanguagePickerModel {
        LanguagePickerModel(
            defaults: .standard,
            domain: Bundle.main.bundleIdentifier ?? "agency.izzy.ration",
            current: AppLanguage.current,
            systemLanguage: systemLanguage(order: globalLanguageOrder())
        )
    }

    func select(_ language: AppLanguage) {
        AppLanguage.store(language, in: defaults, domain: domain)
        stored = AppLanguage.stored(in: defaults, domain: domain)
    }

    /// The language a relaunch would switch to, or nil when it would change
    /// nothing. `.system` is not a language: it counts as what macOS picks.
    var pendingLanguage: AppLanguage? {
        let target: AppLanguage = stored == .system ? systemLanguage : stored
        return target == current ? nil : target
    }

    /// "Ration will use Français after it relaunches." — the language by its
    /// own name, so it can be found whatever the UI shows.
    nonisolated static func pendingNote(for language: AppLanguage, locale: Locale = .current) -> String {
        LocalizedStringResource.languagePending(language.nativeName).string(in: locale)
    }

    /// The shipped language macOS's order resolves to; English when none of
    /// the user's languages ships.
    nonisolated static func systemLanguage(order: [String]) -> AppLanguage {
        let shipped: [String] = AppLanguage.allCases
            .filter { $0 != .system }
            .map(\.rawValue)
        let first: String? = Bundle.preferredLocalizations(from: shipped, forPreferences: order).first
        return AppLanguage.resolved(first: first)
    }

    /// The user's macOS language order from the global domain — not
    /// `Locale.preferredLanguages`, which this process's own override (and a
    /// test run's `-AppleLanguages`) shadows.
    nonisolated static func globalLanguageOrder() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return (value as? [String]) ?? []
    }
}

/// The Language picker, the relaunch note and button, and the relaunch
/// refusal. Rows of the General section's `Form`.
struct LanguageSettingsRows: View {
    @ObservedObject var relauncher: AppRelauncher
    @StateObject private var model = LanguagePickerModel.live()

    var body: some View {
        Picker("Language", selection: Binding(
            get: { model.stored },
            set: { language in model.select(language) }
        )) {
            ForEach(AppLanguage.allCases) { language in
                Text(verbatim: language.nativeName).tag(language)
            }
        }
        .accessibilityIdentifier("languagePicker")

        if let pending = model.pendingLanguage {
            HStack(spacing: 10) {
                Text(verbatim: LanguagePickerModel.pendingNote(for: pending))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.warn)
                Spacer()
                Button("Relaunch now") { relauncher.relaunch() }
                    .disabled(relauncher.status == .pending)
                    .accessibilityIdentifier("relaunchNowButton")
            }
        }

        if relauncher.status == .refused {
            Label {
                Text(verbatim: AppRelauncher.refusedMessage())
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(Theme.mono(12))
            .foregroundStyle(Theme.crit)
            .accessibilityIdentifier("relaunchRefusedNote")
        }
    }
}
