import XCTest
@testable import Ration

/// Settings labels, feature-switch copy, the warm-up disclosure, the
/// profile-cleanup banner and the user-facing error messages in every
/// shipped language. None of these carries a count, so there is no plural
/// matrix here.
final class SettingsAndErrorCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp

    // MARK: Feature switches

    func testFeatureSwitchTitlesInEveryLanguage() {
        XCTAssertEqual(
            FeatureSwitch.allCases.map { $0.title(locale: L10n.en) },
            ["Resets", "Switch suggestions", "Claude warm-up", "In-use detection"]
        )
        XCTAssertEqual(
            FeatureSwitch.allCases.map { $0.title(locale: L10n.fr) },
            ["Réinitialisations", "Suggestions de changement", "Préchauffage de Claude", "Détection du compte en cours"]
        )
        XCTAssertEqual(
            FeatureSwitch.allCases.map { $0.title(locale: L10n.uk) },
            ["Скидання", "Поради щодо перемикання", "Розігрів Claude", "Визначення активного облікового запису"]
        )
    }

    func testFeatureSwitchSummariesInEveryLanguage() {
        XCTAssertEqual(
            FeatureSwitch.allCases.map { $0.summary(locale: L10n.en) },
            [
                "Shows usage-limit resets on cards and in account settings, and alerts about them.",
                "Suggests which account to move to when the one you're on nears its limit.",
                "Starts Claude 5-hour windows automatically for accounts with Auto-start on.",
                "Marks the account you're working in: IN USE tags, menu-bar dots, Focus hero.",
            ]
        )
        XCTAssertEqual(
            FeatureSwitch.allCases.map { $0.summary(locale: L10n.fr) },
            [
                "Affiche les réinitialisations de limite sur les cartes et dans les réglages du compte, et envoie des alertes à leur sujet.",
                "Suggère le compte vers lequel passer quand celui que vous utilisez approche de sa limite.",
                "Démarre automatiquement les fenêtres de 5\(nb)heures de Claude pour les comptes où le démarrage auto est activé.",
                "Signale le compte sur lequel vous travaillez\(nb): étiquettes EN COURS, points dans la barre des menus, compte mis en avant dans Focus.",
            ]
        )
        XCTAssertEqual(
            FeatureSwitch.allCases.map { $0.summary(locale: L10n.uk) },
            [
                "Показує скидання лімітів на картках і в параметрах облікового запису та надсилає про них сповіщення.",
                "Підказує, на який обліковий запис перейти, коли поточний наближається до ліміту.",
                "Автоматично запускає 5-годинні вікна Claude для облікових записів з увімкненим автозапуском.",
                "Позначає обліковий запис, з яким ви працюєте: мітки АКТИВНИЙ, крапки в рядку меню, головний блок у режимі «Фокус».",
            ]
        )
    }

    func testFeatureSwitchNotesInEveryLanguage() {
        XCTAssertEqual(FeatureSwitch.switchAdviceNeedsInUseNote(locale: L10n.en), "Needs in-use detection")
        XCTAssertEqual(FeatureSwitch.switchAdviceNeedsInUseNote(locale: L10n.fr), "Nécessite la détection du compte en cours")
        XCTAssertEqual(FeatureSwitch.switchAdviceNeedsInUseNote(locale: L10n.uk), "Потрібне визначення активного облікового запису")

        XCTAssertEqual(FeatureSwitch.warmUpOffNote(locale: L10n.en), "Warm-up is off in General")
        XCTAssertEqual(FeatureSwitch.warmUpOffNote(locale: L10n.fr), "Le préchauffage est désactivé dans Général")
        XCTAssertEqual(FeatureSwitch.warmUpOffNote(locale: L10n.uk), "Розігрів вимкнено в розділі «Загальні»")
    }

    // MARK: Pickers

    func testAppearanceModeTitlesInEveryLanguage() {
        XCTAssertEqual(AppearanceMode.allCases.map { $0.title(locale: L10n.en) }, ["System", "Light", "Dark"])
        XCTAssertEqual(AppearanceMode.allCases.map { $0.title(locale: L10n.fr) }, ["Système", "Clair", "Sombre"])
        XCTAssertEqual(AppearanceMode.allCases.map { $0.title(locale: L10n.uk) }, ["Системний", "Світлий", "Темний"])
    }

    func testPopoverLayoutTitlesInEveryLanguage() {
        XCTAssertEqual(PopoverLayout.allCases.map { $0.title(locale: L10n.en) }, ["Standard", "Focus"])
        XCTAssertEqual(PopoverLayout.allCases.map { $0.title(locale: L10n.fr) }, ["Standard", "Focus"])
        XCTAssertEqual(PopoverLayout.allCases.map { $0.title(locale: L10n.uk) }, ["Стандарт", "Фокус"])
    }

    // MARK: Warm-up disclosure

    func testWarmUpDisclosureInEveryLanguage() {
        XCTAssertEqual(
            WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: true, locale: L10n.en),
            "Warm-up is on: Ration will start your 5-hour window automatically. Turn it off per account under Auto-start 5h window in Settings."
        )
        XCTAssertEqual(
            WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: true, locale: L10n.fr),
            "Le préchauffage est activé\(nb): Ration démarrera automatiquement votre fenêtre de 5\(nb)heures. "
                + "Désactivez-le compte par compte avec «\(nb)Démarrage auto de la fenêtre de 5\(nb)h\(nb)» dans les Réglages."
        )
        XCTAssertEqual(
            WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: true, locale: L10n.uk),
            "Розігрів увімкнено: Ration автоматично запускатиме ваше 5-годинне вікно. "
                + "Вимкнути його для кожного облікового запису окремо можна в Параметрах, пункт «Автозапуск 5-годинного вікна»."
        )
        XCTAssertEqual(
            WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: false, locale: L10n.en),
            "Warm-up is off in General: Ration won't start your 5-hour window automatically."
        )
        XCTAssertEqual(
            WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: false, locale: L10n.fr),
            "Le préchauffage est désactivé dans Général\(nb): Ration ne démarrera pas automatiquement votre fenêtre de 5\(nb)heures."
        )
        XCTAssertEqual(
            WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: false, locale: L10n.uk),
            "Розігрів вимкнено в розділі «Загальні»: Ration не запускатиме ваше 5-годинне вікно автоматично."
        )
    }

    // MARK: Profile-cleanup banner

    func testProfileCleanupCopyInEveryLanguage() {
        XCTAssertEqual(ProfileCleanupCopy.pending(locale: L10n.en), "A cancelled sign-in profile still needs cleanup.")
        XCTAssertEqual(ProfileCleanupCopy.pending(locale: L10n.fr), "Le profil d’une connexion annulée doit encore être nettoyé.")
        XCTAssertEqual(ProfileCleanupCopy.pending(locale: L10n.uk), "Профіль скасованого входу ще потрібно очистити.")

        XCTAssertEqual(
            ProfileCleanupCopy.blockingQuit(locale: L10n.en),
            "Quit is paused until the cancelled sign-in profile is removed."
        )
        XCTAssertEqual(
            ProfileCleanupCopy.blockingQuit(locale: L10n.fr),
            "La fermeture de Ration est suspendue jusqu’à la suppression du profil de la connexion annulée."
        )
        XCTAssertEqual(
            ProfileCleanupCopy.blockingQuit(locale: L10n.uk),
            "Закриття Ration призупинено, доки не буде вилучено профіль скасованого входу."
        )

        XCTAssertEqual(
            ProfileCleanupCopy.blockingQuitOnSignIn(locale: L10n.en),
            "Quit is paused until the active sign-in finishes."
        )
        XCTAssertEqual(
            ProfileCleanupCopy.blockingQuitOnSignIn(locale: L10n.fr),
            "La fermeture de Ration est suspendue jusqu’à la fin de la connexion en cours."
        )
        XCTAssertEqual(
            ProfileCleanupCopy.blockingQuitOnSignIn(locale: L10n.uk),
            "Закриття Ration призупинено до завершення поточного входу."
        )
    }

    // MARK: Errors

    func testProviderErrorMessagesInEveryLanguage() {
        let errors: [ProviderError] = [
            .authenticationRequired, .rateLimited(retryAt: nil), .server(statusCode: 500),
            .integrationChanged, .offline, .transport,
        ]
        XCTAssertEqual(errors.map { $0.message(locale: L10n.en) }, [
            "Sign in again to refresh this account.",
            "The provider is rate limiting usage checks. Try again later.",
            "The provider could not return subscription limits right now.",
            "The provider integration needs an update.",
            "Subscription limits are unavailable while offline.",
            "The provider request could not be completed.",
        ])
        XCTAssertEqual(errors.map { $0.message(locale: L10n.fr) }, [
            "Reconnectez-vous pour actualiser ce compte.",
            "Le fournisseur limite la fréquence des vérifications d’utilisation. Réessayez plus tard.",
            "Le fournisseur ne peut pas fournir les limites de l’abonnement pour le moment.",
            "L’intégration du fournisseur doit être mise à jour.",
            "Les limites de l’abonnement ne sont pas disponibles hors ligne.",
            "La requête au fournisseur n’a pas pu aboutir.",
        ])
        XCTAssertEqual(errors.map { $0.message(locale: L10n.uk) }, [
            "Увійдіть знову, щоб оновити цей обліковий запис.",
            "Постачальник обмежує частоту перевірок використання. Спробуйте пізніше.",
            "Постачальник зараз не може надати дані про ліміти підписки.",
            "Інтеграцію з постачальником потрібно оновити.",
            "Ліміти підписки недоступні офлайн.",
            "Не вдалося виконати запит до постачальника.",
        ])
    }

    func testAccountStoreErrorMessagesInEveryLanguage() {
        let errors: [AccountStoreError] = [.accountNotFound, .accountAlreadyExists, .emptyLabel, .operationInProgress]
        XCTAssertEqual(errors.map { $0.message(locale: L10n.en) }, [
            "The account no longer exists.",
            "This account is already connected.",
            "Enter a local label for this account.",
            "Another operation is already in progress for this account.",
        ])
        XCTAssertEqual(errors.map { $0.message(locale: L10n.fr) }, [
            "Le compte n’existe plus.",
            "Ce compte est déjà connecté.",
            "Saisissez un libellé local pour ce compte.",
            "Une autre opération est déjà en cours pour ce compte.",
        ])
        XCTAssertEqual(errors.map { $0.message(locale: L10n.uk) }, [
            "Обліковий запис більше не існує.",
            "Цей обліковий запис уже під’єднано.",
            "Введіть локальну назву для цього облікового запису.",
            "Для цього облікового запису вже виконується інша операція.",
        ])
    }

    func testAccountRollbackErrorMessagesInEveryLanguage() {
        XCTAssertEqual(
            AccountRemovalError.rollbackFailed.message(locale: L10n.en),
            "The account could not be removed safely. Its local data may need attention."
        )
        XCTAssertEqual(
            AccountRemovalError.rollbackFailed.message(locale: L10n.fr),
            "Le compte n’a pas pu être supprimé en toute sécurité. Ses données locales peuvent nécessiter votre attention."
        )
        XCTAssertEqual(
            AccountRemovalError.rollbackFailed.message(locale: L10n.uk),
            "Не вдалося безпечно вилучити обліковий запис. Його локальні дані можуть потребувати уваги."
        )
        XCTAssertEqual(
            AccountCommitError.rollbackFailed.message(locale: L10n.en),
            "The account was saved without its latest limits. Remove it or try refreshing again."
        )
        XCTAssertEqual(
            AccountCommitError.rollbackFailed.message(locale: L10n.fr),
            "Le compte a été enregistré sans ses dernières limites. Supprimez-le ou réessayez de l’actualiser."
        )
        XCTAssertEqual(
            AccountCommitError.rollbackFailed.message(locale: L10n.uk),
            "Обліковий запис збережено без останніх лімітів. Вилучіть його або спробуйте оновити ще раз."
        )
    }

    /// `localizedDescription` — what every error surface shows — resolves
    /// in the running language: French under `l10n-test fr`, Ukrainian
    /// under `uk`, English under the pinned `unit-test`.
    func testErrorDescriptionFollowsTheRunningLanguage() {
        let offline = ProviderError.offline.localizedDescription
        let busy = AccountStoreError.operationInProgress.localizedDescription
        let cleanup = ProfileCleanupCopy.pending
        switch Locale.current.language.languageCode {
        case .french?:
            XCTAssertEqual(offline, "Les limites de l’abonnement ne sont pas disponibles hors ligne.")
            XCTAssertEqual(busy, "Une autre opération est déjà en cours pour ce compte.")
            XCTAssertEqual(cleanup, "Le profil d’une connexion annulée doit encore être nettoyé.")
        case .ukrainian?:
            XCTAssertEqual(offline, "Ліміти підписки недоступні офлайн.")
            XCTAssertEqual(busy, "Для цього облікового запису вже виконується інша операція.")
            XCTAssertEqual(cleanup, "Профіль скасованого входу ще потрібно очистити.")
        default:
            XCTAssertEqual(offline, "Subscription limits are unavailable while offline.")
            XCTAssertEqual(busy, "Another operation is already in progress for this account.")
            XCTAssertEqual(cleanup, "A cancelled sign-in profile still needs cleanup.")
        }
    }
}
