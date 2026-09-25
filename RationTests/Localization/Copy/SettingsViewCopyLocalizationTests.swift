import XCTest
@testable import Ration

/// Settings panes, the plan step and the language picker in every shipped
/// language: code-built copy through its `(locale:)` form, and the SwiftUI
/// literal keys through the catalog. Plus the locale-aware Cursor spend
/// input (ruling R3).
final class SettingsViewCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp

    // MARK: Section titles and sidebar

    func testSectionTitlesInEveryLanguage() {
        XCTAssertEqual(
            SettingsSectionTitle.all(locale: L10n.en),
            ["Accounts", "General", "Menu Bar", "Features", "Identity", "Automation", "Resets", "Billing",
             "Session", "Quiet Hours", "Holidays", "Cursor Spend"]
        )
        XCTAssertEqual(
            SettingsSectionTitle.all(locale: L10n.fr),
            ["Comptes", "Général", "Barre des menus", "Fonctionnalités", "Identité", "Automatisation",
             "Réinitialisations", "Facturation", "Session", "Heures calmes", "Jours fériés", "Dépenses Cursor"]
        )
        XCTAssertEqual(
            SettingsSectionTitle.all(locale: L10n.uk),
            ["Облікові записи", "Загальні", "Рядок меню", "Функції", "Ідентифікація", "Автоматизація",
             "Скидання", "Оплата", "Сеанс", "Тихі години", "Вихідні дні", "Витрати Cursor"]
        )
    }

    /// "General" is quoted by 4b's copy (Général / «Загальні»): the sidebar
    /// item must carry the same name.
    func testSidebarItemsInEveryLanguage() {
        XCTAssertEqual(SettingsSidebar.fixedTitles(locale: L10n.en), ["General", "Warm-up", "Alerts"])
        XCTAssertEqual(SettingsSidebar.fixedTitles(locale: L10n.fr), ["Général", "Préchauffage", "Alertes"])
        XCTAssertEqual(SettingsSidebar.fixedTitles(locale: L10n.uk), ["Загальні", "Розігрів", "Сповіщення"])
        XCTAssertTrue(
            FeatureSwitch.warmUpOffNote(locale: L10n.uk).contains("«\(SettingsSidebar.fixedTitles(locale: L10n.uk)[0])»")
        )
        XCTAssertTrue(
            FeatureSwitch.warmUpOffNote(locale: L10n.fr).hasSuffix(SettingsSidebar.fixedTitles(locale: L10n.fr)[0])
        )
    }

    // MARK: Account pane

    func testPauseCopyInEveryLanguage() {
        let paused = AccountDetailPauseState(isPaused: true)
        let active = AccountDetailPauseState(isPaused: false)
        XCTAssertEqual(active.buttonTitle(locale: L10n.fr), "Mettre le compte en pause")
        XCTAssertEqual(paused.buttonTitle(locale: L10n.fr), "Réactiver le compte")
        XCTAssertEqual(active.buttonTitle(locale: L10n.uk), "Призупинити обліковий запис")
        XCTAssertEqual(paused.buttonTitle(locale: L10n.uk), "Відновити обліковий запис")
        XCTAssertEqual(
            paused.explanation(locale: L10n.fr),
            "En pause\(nb): pas d’actualisation, exclu du préchauffage, masqué dans la barre des menus. La connexion est conservée."
        )
        XCTAssertEqual(
            paused.explanation(locale: L10n.uk),
            "Призупинено: не оновлюється, не бере участі в розігріві, не показується в рядку меню. Вхід збережено."
        )
        XCTAssertNil(active.explanation(locale: L10n.fr))
        XCTAssertEqual(paused.buttonTitle(locale: L10n.en), "Resume account")
    }

    func testHeaderSubtitleInEveryLanguage() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let added = now.addingTimeInterval(-40 * 86_400)
        func date(_ locale: Locale) -> String {
            added.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        }
        XCTAssertEqual(
            AccountDetailHeader.subtitle(createdAt: added, phase: .none, now: now, locale: L10n.fr),
            "Ajouté le \(date(L10n.fr))"
        )
        XCTAssertEqual(
            AccountDetailHeader.subtitle(createdAt: added, phase: .inUse(age: 60), now: now, locale: L10n.fr),
            "Ajouté le \(date(L10n.fr)) · utilisé il y a 1 minute"
        )
        XCTAssertEqual(
            AccountDetailHeader.subtitle(createdAt: added, phase: .lastUsed(age: 7200), now: now, locale: L10n.uk),
            "Додано \(date(L10n.uk)) · востаннє використано 2 години тому"
        )
        XCTAssertEqual(
            AccountDetailHeader.subtitle(createdAt: added, phase: .lastUsed(age: 7200), now: now, locale: L10n.en),
            "Added \(date(L10n.en)) · last used 2 hours ago"
        )
    }

    func testResetCreditRowInEveryLanguage() {
        let expiry = Date(timeIntervalSince1970: 1_790_000_000)
        let utc = TimeZone(identifier: "UTC")!
        func when(_ locale: Locale) -> String {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            style.timeZone = utc
            return expiry.formatted(style)
        }
        XCTAssertEqual(SettingsCopy.resetCreditLine(count: 2, expiresAt: expiry, locale: L10n.en, timeZone: utc), "×2 · expires \(when(L10n.en))")
        XCTAssertEqual(SettingsCopy.resetCreditLine(count: 2, expiresAt: expiry, locale: L10n.fr, timeZone: utc), "×2 · expire le \(when(L10n.fr))")
        XCTAssertEqual(SettingsCopy.resetCreditLine(count: 2, expiresAt: expiry, locale: L10n.uk, timeZone: utc), "×2 · діє до \(when(L10n.uk))")

        XCTAssertEqual(SettingsCopy.resetCreditTitle(nil, locale: L10n.fr), "Réinitialisation de limite")
        XCTAssertEqual(SettingsCopy.resetCreditTitle(nil, locale: L10n.uk), "Скидання ліміту")
        XCTAssertEqual(SettingsCopy.resetCreditTitle("Weekly reset", locale: L10n.uk), "Weekly reset", "provider text is verbatim")

        XCTAssertEqual(SettingsCopy.resetCreditUsability(true, locale: L10n.fr), "utilisable maintenant")
        XCTAssertEqual(SettingsCopy.resetCreditUsability(false, locale: L10n.uk), "поки недоступно")
    }

    func testPlanPickerAutomaticOptionInEveryLanguage() {
        func record(_ plan: PlanTier?, _ source: PlanSource?) -> AccountRecord {
            AccountRecord(
                id: UUID(), provider: .claude, label: "Work", webProfileID: UUID(),
                displayOrder: 0, createdAt: .distantPast, plan: plan, planSource: source
            )
        }
        XCTAssertEqual(PlanChoice.automaticTitle(for: record(.claudeMax20x, .detected), locale: L10n.fr), "Détecter automatiquement (Max 20x)")
        XCTAssertEqual(PlanChoice.automaticTitle(for: record(nil, nil), locale: L10n.fr), "Détecter automatiquement (non détecté)")
        XCTAssertEqual(PlanChoice.automaticTitle(for: record(.claudePro, .user), locale: L10n.uk), "Визначати автоматично")
        XCTAssertEqual(PlanChoice.automaticTitle(for: record(.claudeMax5x, .detected), locale: L10n.uk), "Визначати автоматично (Max 5x)")
    }

    // MARK: Alerts pane

    func testWindowNamesInEveryLanguage() {
        let windows: [UsageWindowKind] = [.fiveHour, .weekly, .modelWeekly]
        XCTAssertEqual(windows.map { SettingsCopy.windowLabel($0, locale: L10n.en) }, ["5-hour", "Weekly", "Fable"])
        XCTAssertEqual(windows.map { SettingsCopy.windowLabel($0, locale: L10n.fr) }, ["5\(nb)heures", "Hebdomadaire", "Fable"])
        XCTAssertEqual(windows.map { SettingsCopy.windowLabel($0, locale: L10n.uk) }, ["5 годин", "Тижневий", "Fable"])
    }

    func testExpiryWarningStepperIsPluralized() {
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 1, locale: L10n.en), "Expiry warning: 1 day")
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 3, locale: L10n.en), "Expiry warning: 3 days")
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 1, locale: L10n.fr), "Prévenir 1 jour avant")
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 2, locale: L10n.fr), "Prévenir 2 jours avant")
        let uk = [1, 2, 5, 21, 22, 25].map { ResetExpiryCopy.stepperLabel(leadDays: $0, locale: L10n.uk) }
        XCTAssertEqual(uk, [
            "Попередити за 1 день", "Попередити за 2 дні", "Попередити за 5 днів",
            "Попередити за 21 день", "Попередити за 22 дні", "Попередити за 25 днів",
        ])
    }

    func testNotifyTooltipInEveryLanguage() {
        XCTAssertEqual(SettingsCopy.notifyHelp(locale: L10n.en), "Send a system notification when this is crossed")
        XCTAssertEqual(SettingsCopy.notifyHelp(locale: L10n.fr), "Envoyer une notification système quand ce seuil est franchi")
        XCTAssertEqual(SettingsCopy.notifyHelp(locale: L10n.uk), "Надсилати системне сповіщення, коли цей поріг перетнуто")
    }

    // MARK: Language and relaunch

    func testLanguageNoteAndRelaunchRefusalInEveryLanguage() {
        XCTAssertEqual(LanguagePickerModel.pendingNote(for: .french, locale: L10n.en), "Ration will use Français after it relaunches.")
        XCTAssertEqual(LanguagePickerModel.pendingNote(for: .english, locale: L10n.fr), "Ration utilisera «\(nb)English\(nb)» après son redémarrage.")
        XCTAssertEqual(LanguagePickerModel.pendingNote(for: .ukrainian, locale: L10n.uk), "Ration використовуватиме мову «Українська» після перезапуску.")
        XCTAssertEqual(
            AppRelauncher.refusedMessage(locale: L10n.fr),
            "Ration n’a pas pu redémarrer, car une tâche est encore en cours. Réessayez dans un instant."
        )
        XCTAssertEqual(
            AppRelauncher.refusedMessage(locale: L10n.uk),
            "Ration не вдалося перезапустити, бо ще завершується завдання. Спробуйте ще раз за мить."
        )
    }

    func testLaunchAtLoginApprovalNoteInEveryLanguage() {
        XCTAssertEqual(LaunchAtLoginController.requiresApprovalExplanation(locale: L10n.en), "Allow Ration in System Settings → General → Login Items.")
        XCTAssertEqual(LaunchAtLoginController.requiresApprovalExplanation(locale: L10n.fr), "Autorisez Ration dans Réglages Système → Général → Ouverture.")
        XCTAssertEqual(LaunchAtLoginController.requiresApprovalExplanation(locale: L10n.uk), "Дозвольте Ration у Системних параметрах → Загальні → Елементи входу.")
    }

    // MARK: Quiet hours

    func testQuietHoursSpokenLabelsInEveryLanguage() {
        var french = Calendar(identifier: .gregorian)
        french.locale = L10n.fr
        var ukrainian = Calendar(identifier: .gregorian)
        ukrainian.locale = L10n.uk
        XCTAssertEqual(QuietHoursGrid.dayToggleAccessibilityLabel(weekday: 2, calendar: french), "Basculer toute la journée du lundi")
        XCTAssertEqual(QuietHoursGrid.dayToggleAccessibilityLabel(weekday: 2, calendar: ukrainian), "Перемкнути весь день: понеділок")
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 9, locale: L10n.fr), "Basculer 09:00 tous les jours")
        XCTAssertEqual(QuietHoursGrid.hourToggleAccessibilityLabel(hour: 9, locale: L10n.uk), "Перемкнути 09:00 для всіх днів")
    }

    // MARK: Plan step

    func testPlanStepCopyInEveryLanguage() {
        XCTAssertEqual(PlanStepView.title(locale: L10n.en), "Which plan is this?")
        XCTAssertEqual(PlanStepView.title(locale: L10n.fr), "De quel forfait s’agit-il\(nb)?")
        XCTAssertEqual(PlanStepView.title(locale: L10n.uk), "Який це тариф?")
        XCTAssertEqual(
            PlanStepView.subtitle(locale: L10n.fr),
            "Les forfaits n’ont pas la même taille. Ration s’en sert pour suggérer le compte vers lequel passer — les pourcentages seuls peuvent induire en erreur."
        )
        XCTAssertEqual(PlanStepView.notSure(locale: L10n.fr), "Je ne sais pas")
        XCTAssertEqual(PlanStepView.notSure(locale: L10n.uk), "Не знаю")
    }

    // MARK: SwiftUI literal keys

    func testViewLiteralsResolve() {
        let expected: [(key: String, fr: String, uk: String)] = [
            ("Appearance", "Apparence", "Вигляд"),
            ("Language", "Langue", "Мова"),
            ("Relaunch now", "Redémarrer maintenant", "Перезапустити зараз"),
            ("Launch at login", "Ouvrir à la connexion", "Запускати під час входу"),
            ("Usage alerts", "Alertes d’utilisation", "Сповіщення про використання"),
            ("Used %", "Utilisé (%)", "Використано (%)"),
            ("Remaining %", "Restant (%)", "Залишок (%)"),
            ("Remove account?", "Supprimer le compte\(nb)?", "Вилучити обліковий запис?"),
            ("Cancel", "Annuler", "Скасувати"),
            ("PAUSED", "EN PAUSE", "ПРИЗУПИНЕНО"),
            ("Auto-start 5h window", "Démarrage auto de la fenêtre de 5\(nb)h", "Автозапуск 5-годинного вікна"),
            ("Plan", "Forfait", "Тариф"),
            ("Renewal day", "Jour de facturation", "День оплати"),
            ("Not set", "Non défini", "Не вказано"),
            ("Warn", "Avert.", "Попер."),
            ("Crit", "Crit.", "Крит."),
            ("Notify", "Notifier", "Сповіщати"),
            ("Drop", "Panneau", "Панель"),
            ("Turn on Usage alerts in General to use these thresholds.",
             "Activez «\(nb)Alertes d’utilisation\(nb)» dans Général pour utiliser ces seuils.",
             "Увімкніть «Сповіщення про використання» в розділі «Загальні», щоб використовувати ці пороги."),
            ("Add range", "Ajouter une période", "Додати період"),
            ("quiet", "heure calme", "тиха година"),
            ("Skip", "Ignorer", "Пропустити"),
            ("Save", "Enregistrer", "Зберегти"),
            // Reused from Task 5.
            ("Layout", "Disposition", "Макет"),
            ("Add Account", "Ajouter un compte", "Додати обліковий запис"),
        ]
        for entry in expected {
            let resource = LocalizedStringResource(String.LocalizationValue(entry.key))
            XCTAssertEqual(resource.string(in: L10n.en), entry.key)
            XCTAssertEqual(resource.string(in: L10n.fr), entry.fr, entry.key)
            XCTAssertEqual(resource.string(in: L10n.uk), entry.uk, entry.key)
        }
    }

    /// The quoted names must match the controls they name.
    func testQuotedNamesMatchTheirControls() {
        let usageAlerts = LocalizedStringResource("Usage alerts")
        let turnOn = LocalizedStringResource("Turn on Usage alerts in General to use these thresholds.")
        XCTAssertTrue(turnOn.string(in: L10n.fr).contains(usageAlerts.string(in: L10n.fr)))
        XCTAssertTrue(turnOn.string(in: L10n.uk).contains(usageAlerts.string(in: L10n.uk)))
        let toggle = LocalizedStringResource("Auto-start 5h window")
        XCTAssertTrue(WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: true, locale: L10n.fr).contains(toggle.string(in: L10n.fr)))
        XCTAssertTrue(WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: true, locale: L10n.uk).contains(toggle.string(in: L10n.uk)))
    }

    func testInterpolatedLiteralsResolve() {
        let label = "Work"
        let remove = LocalizedStringResource("Remove \(label)")
        XCTAssertEqual(remove.string(in: L10n.en), "Remove Work")
        XCTAssertEqual(remove.string(in: L10n.fr), "Supprimer Work")
        XCTAssertEqual(remove.string(in: L10n.uk), "Вилучити Work")

        let provider = "Claude"
        let plan = LocalizedStringResource("\(provider) plan")
        XCTAssertEqual(plan.string(in: L10n.en), "Claude plan")
        XCTAssertEqual(plan.string(in: L10n.fr), "Forfait Claude")
        XCTAssertEqual(plan.string(in: L10n.uk), "Тариф Claude")

        let name = "Max 20x"
        let detected = LocalizedStringResource("Plan \(name), detected")
        XCTAssertEqual(detected.string(in: L10n.fr), "Forfait Max 20x, détecté")
        XCTAssertEqual(detected.string(in: L10n.uk), "Тариф Max 20x, визначено")

        let day = "Mon"
        let dayHelp = LocalizedStringResource("Toggle all of \(day)")
        XCTAssertEqual(dayHelp.string(in: L10n.en), "Toggle all of Mon")
        XCTAssertEqual(dayHelp.string(in: L10n.fr), "Basculer toute la colonne Mon")

        let hour = "09"
        let hourHelp = LocalizedStringResource("Toggle \(hour):00 on every day")
        XCTAssertEqual(hourHelp.string(in: L10n.en), "Toggle 09:00 on every day")
        XCTAssertEqual(hourHelp.string(in: L10n.uk), "Перемкнути 09:00 для всіх днів")
    }

    // MARK: Cursor spend input (R3)

    func testSpendFieldShowsTheLanguagesDecimalSeparator() {
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 1234, locale: L10n.en), "12.34")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 1234, locale: L10n.fr), "12,34")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 1234, locale: L10n.uk), "12,34")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 123_456, locale: L10n.fr), "1234,56", "never grouped")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 123_456, locale: L10n.en), "1234.56")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 5000, locale: L10n.uk), "50,00")
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: nil, locale: L10n.fr), "")
        // The region never changes it: the separator follows the app language.
        XCTAssertEqual(CursorSpendFieldParsing.dollarsText(fromCents: 1234, locale: Locale(identifier: "en_DE")), "12.34")
    }

    func testSpendFieldAcceptsTheLanguagesCommaAndAPlainDot() {
        XCTAssertEqual(CursorSpendFieldParsing.parsedCents("12,34", locale: L10n.fr), .some(1234))
        XCTAssertEqual(CursorSpendFieldParsing.parsedCents("12,34", locale: L10n.uk), .some(1234))
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            XCTAssertEqual(CursorSpendFieldParsing.parsedCents("12.34", locale: locale), .some(1234), locale.identifier)
            XCTAssertEqual(CursorSpendFieldParsing.parsedCents("  ", locale: locale), .some(nil), "blank turns the tier off")
            XCTAssertNil(CursorSpendFieldParsing.parsedCents("abc", locale: locale))
            XCTAssertNil(CursorSpendFieldParsing.parsedCents("-5", locale: locale))
            XCTAssertNil(CursorSpendFieldParsing.parsedCents("1000000", locale: locale), "out of bounds")
            XCTAssertNil(CursorSpendFieldParsing.parsedCents("1000000,00", locale: locale), "out of bounds")
            XCTAssertNil(CursorSpendFieldParsing.parsedCents("9.2e16", locale: locale))
        }
        XCTAssertEqual(CursorSpendFieldParsing.parsedCents("999999,99", locale: L10n.fr), .some(99_999_999))
        XCTAssertEqual(CursorSpendFieldParsing.parsedCents("7", locale: L10n.uk), .some(700))
        // English keeps 1.3.0's reading: a comma is not a decimal separator.
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("12,34", locale: L10n.en))
        // A grouped figure is ambiguous, never guessed.
        XCTAssertNil(CursorSpendFieldParsing.parsedCents("1,234.50", locale: L10n.fr))
    }

    func testSpendFieldRoundTripsItsOwnText() {
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            for cents in [0, 1, 99, 1234, 99_999_999] {
                let text = CursorSpendFieldParsing.dollarsText(fromCents: cents, locale: locale)
                XCTAssertEqual(CursorSpendFieldParsing.parsedCents(text, locale: locale), .some(cents), "\(locale.identifier) \(text)")
            }
        }
    }

    // MARK: Running language

    func testDefaultsFollowTheRunningLanguage() {
        let running = Locale(identifier: AppLanguage.current.rawValue)
        XCTAssertEqual(SettingsSectionTitle.general, SettingsSectionTitle.general(locale: running))
        XCTAssertEqual(SettingsSidebar.fixedGroups.flatMap(\.self).map(\.title), SettingsSidebar.fixedTitles(locale: running))
        XCTAssertEqual(AccountDetailPauseState(isPaused: true).buttonTitle, AccountDetailPauseState(isPaused: true).buttonTitle(locale: running))
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 2), ResetExpiryCopy.stepperLabel(leadDays: 2, locale: running))
        XCTAssertEqual(PlanStepView.title, PlanStepView.title(locale: running))
        XCTAssertEqual(AppRelauncher.refusedMessage(), AppRelauncher.refusedMessage(locale: running))
    }
}
