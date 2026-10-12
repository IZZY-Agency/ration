import XCTest
@testable import Ration

/// The Codex switch's copy in every shipped language, read
/// through the generated catalog symbols, so a missing key, a renamed key or
/// a placeholder that doesn't substitute fails here. French keeps U+00A0
/// before `:` and `;` and inside « », U+202F before `%` and before `?` in the
/// titles the Claude Code strings also space that way; Ukrainian says
/// "обліковий запис"; "Codex" and `codex login` stay as they are.
final class CodexCopyLocalizationTests: XCTestCase {
    private struct Copy {
        let key: String
        let resource: LocalizedStringResource
        let en: String
        let fr: String
        let uk: String
    }

    private func check(_ copies: [Copy], file: StaticString = #filePath, line: UInt = #line) {
        for copy in copies {
            XCTAssertEqual(copy.resource.string(in: L10n.en), copy.en, "\(copy.key) en", file: file, line: line)
            XCTAssertEqual(copy.resource.string(in: L10n.fr), copy.fr, "\(copy.key) fr", file: file, line: line)
            XCTAssertEqual(copy.resource.string(in: L10n.uk), copy.uk, "\(copy.key) uk", file: file, line: line)
        }
    }

    // MARK: cardAndFocus

    /// The card's tag and button, and the Focus line.
    private static var cardAndFocus: [Copy] {
        [
            Copy(key: "codex.card.current", resource: .codexCardCurrent,
                 en: "Codex",
                 fr: "Codex",
                 uk: "Codex"),
            Copy(key: "codex.card.current.accessibility", resource: .codexCardCurrentAccessibility,
                 en: "Codex uses this account",
                 fr: "Codex utilise ce compte",
                 uk: "Codex використовує цей обліковий запис"),
            Copy(key: "codex.card.switching", resource: .codexCardSwitching,
                 en: "Switching…",
                 fr: "Basculement…",
                 uk: "Перемикання…"),
            Copy(key: "codex.card.use", resource: .codexCardUse,
                 en: "Switch",
                 fr: "Basculer",
                 uk: "Перемкнути"),
            Copy(key: "codex.card.use.accessibility", resource: .codexCardUseAccessibility("Work"),
                 en: "Switch Codex to Work",
                 fr: "Faire passer Codex à Work",
                 uk: "Перемкнути Codex на Work"),
            Copy(key: "codex.card.use.sameWorkspace.accessibility", resource: .codexCardUseSameWorkspaceAccessibility("Work"),
                 en: "Switch Codex to Work — same workspace: running sessions may follow",
                 fr: "Faire passer Codex à Work — même espace de travail\u{00A0}: les sessions en cours peuvent basculer aussi",
                 uk: "Перемкнути Codex на Work — той самий робочий простір: запущені сесії можуть теж перемкнутися"),
            Copy(key: "codex.focus.on", resource: .codexFocusOn("Work"),
                 en: "Codex on Work",
                 fr: "Codex utilise Work",
                 uk: "Codex використовує Work"),
            Copy(key: "codex.focus.switch", resource: .codexFocusSwitch("Personal"),
                 en: "Switch to Personal",
                 fr: "Basculer vers Personal",
                 uk: "Перемкнути на Personal"),
        ]
    }

    func testCardAndFocusInEveryLanguage() {
        check(Self.cardAndFocus)
    }

    // MARK: errors

    /// The switcher's failures, as Settings and the popover word them.
    private static var errors: [Copy] {
        [
            Copy(key: "codex.error.changing", resource: .codexErrorChanging,
                 en: "Codex is changing its sign-in. Try again in a moment.",
                 fr: "Codex est en train de changer de connexion. Réessayez dans un instant.",
                 uk: "Codex саме змінює вхід. Спробуйте ще раз за мить."),
            Copy(key: "codex.error.conflict", resource: .codexErrorConflict,
                 en: "Codex signed in to another account during the switch; Ration left it as it is.",
                 fr: "Codex s’est connecté à un autre compte pendant le basculement\u{00A0}; Ration l’a laissé tel quel.",
                 uk: "Під час перемикання Codex увійшов в інший обліковий запис; Ration залишив його як є."),
            Copy(key: "codex.error.failed", resource: .codexErrorFailed,
                 en: "The switch didn’t go through and was undone.",
                 fr: "Le basculement n’a pas abouti et a été annulé.",
                 uk: "Перемикання не вдалося, його скасовано."),
            Copy(key: "codex.error.needsAttention", resource: .codexErrorNeedsAttention,
                 en: "Ration couldn’t fully undo a switch. Run codex login to be safe.",
                 fr: "Ration n’a pas pu annuler complètement un basculement. Lancez codex login par précaution.",
                 uk: "Ration не зміг повністю скасувати перемикання. Для певності виконайте codex login."),
            Copy(key: "codex.error.notSignedIn", resource: .codexErrorNotSignedIn,
                 en: "Codex isn’t signed in with a ChatGPT account.",
                 fr: "Codex n’est pas connecté à un compte ChatGPT.",
                 uk: "Codex не ввійшов в обліковий запис ChatGPT."),
            Copy(key: "codex.error.unsupported", resource: .codexErrorUnsupported,
                 en: "Codex is signed in with an API key or keeps its login in the keychain, which Ration can’t switch.",
                 fr: "Codex est connecté avec une clé API ou garde sa connexion dans le trousseau\u{00A0}: Ration ne peut pas le basculer.",
                 uk: "Codex увійшов за допомогою ключа API або зберігає вхід у в’язці ключів, тож Ration не може його перемкнути."),
            Copy(key: "codex.error.rememberFirst", resource: .codexErrorRememberFirst,
                 en: "Codex is on an account Ration hasn’t remembered. Remember it first, so it isn’t lost.",
                 fr: "Codex utilise un compte que Ration n’a pas mémorisé. Mémorisez-le d’abord pour ne pas le perdre.",
                 uk: "Codex використовує обліковий запис, який Ration не зберіг. Спершу збережіть його, щоб не втратити."),
        ]
    }

    func testErrorsInEveryLanguage() {
        check(Self.errors)
    }

    // MARK: notifications

    /// Notifications, including the redacted body (no account names).
    private static var notifications: [Copy] {
        [
            Copy(key: "codex.notification.failed.body", resource: .codexNotificationFailedBody,
                 en: "Automatic switching is paused. Open Ration to see why.",
                 fr: "Le basculement automatique est en pause. Ouvrez Ration pour en savoir plus.",
                 uk: "Автоматичне перемикання призупинено. Відкрийте Ration, щоб дізнатися причину."),
            Copy(key: "codex.notification.failed.title", resource: .codexNotificationFailedTitle,
                 en: "Codex was not switched",
                 fr: "Codex n’a pas été basculé",
                 uk: "Codex не перемкнено"),
            Copy(key: "codex.notification.noRoom.body", resource: .codexNotificationNoRoomBody("Work"),
                 en: "Codex stays on Work: every remembered account is past your limit.",
                 fr: "Codex reste sur Work\u{00A0}: tous les comptes mémorisés ont dépassé votre limite.",
                 uk: "Codex залишається на Work: усі збережені облікові записи перевищили ваш ліміт."),
            Copy(key: "codex.notification.noRoom.title", resource: .codexNotificationNoRoomTitle,
                 en: "No ChatGPT account has room",
                 fr: "Aucun compte ChatGPT n’a de marge",
                 uk: "Жоден обліковий запис ChatGPT не має запасу"),
            Copy(key: "codex.notification.redacted.body", resource: .codexNotificationRedactedBody,
                 en: "Codex switched accounts.",
                 fr: "Codex a changé de compte.",
                 uk: "Codex змінив обліковий запис."),
            Copy(key: "codex.notification.redacted.failed", resource: .codexNotificationRedactedFailed,
                 en: "Codex was not switched.",
                 fr: "Codex n’a pas été basculé.",
                 uk: "Codex не перемкнено."),
            Copy(key: "codex.notification.redacted.noRoom", resource: .codexNotificationRedactedNoRoom,
                 en: "No ChatGPT account has room for Codex.",
                 fr: "Aucun compte ChatGPT n’a de marge pour Codex.",
                 uk: "Жоден обліковий запис ChatGPT не має запасу для Codex."),
            Copy(key: "codex.notification.switched.body", resource: .codexNotificationSwitchedBody("Work", 80),
                 en: "Work used 80% of its weekly limit. Restart running Codex sessions.",
                 fr: "Work a utilisé 80\u{202F}% de sa limite hebdomadaire. Redémarrez les sessions Codex en cours.",
                 uk: "Work використав 80% тижневого ліміту. Перезапустіть запущені сесії Codex."),
            Copy(key: "codex.notification.switched.title", resource: .codexNotificationSwitchedTitle("Personal"),
                 en: "Codex switched to Personal",
                 fr: "Codex est passé à Personal",
                 uk: "Codex перемкнено на Personal"),
        ]
    }

    func testNotificationsInEveryLanguage() {
        check(Self.notifications)
    }

    // MARK: rememberSheet

    /// The Remember sheet.
    private static var rememberSheet: [Copy] {
        [
            Copy(key: "codex.remember.account", resource: .codexRememberAccount,
                 en: "It belongs to this Ration account",
                 fr: "Elle appartient à ce compte Ration",
                 uk: "Він належить цьому обліковому запису Ration"),
            Copy(key: "codex.remember.confirm", resource: .codexRememberConfirm,
                 en: "Remember",
                 fr: "Mémoriser",
                 uk: "Зберегти"),
            Copy(key: "codex.remember.disclosure", resource: .codexRememberDisclosure,
                 en: "Ration keeps a copy of this sign-in in your login Keychain (not synced) so it can switch Codex back to it without a login. It reads and writes Codex’s own sign-in file, which the ChatGPT app’s Codex also uses, and sends none of it anywhere.",
                 fr: "Ration garde une copie de cette connexion dans votre trousseau de session (non synchronisé) pour y rebasculer Codex sans nouvelle connexion. Il lit et écrit le fichier de connexion de Codex, que le Codex de l’app ChatGPT utilise aussi, et n’en envoie rien nulle part.",
                 uk: "Ration зберігає копію цього входу у вашій в’язці ключів входу (без синхронізації), щоб повертати на нього Codex без нового входу. Він читає й записує власний файл входу Codex, яким також користується Codex у застосунку ChatGPT, і нікуди нічого з цього не надсилає."),
            Copy(key: "codex.remember.notNow", resource: .codexRememberNotNow,
                 en: "Not now",
                 fr: "Pas maintenant",
                 uk: "Не зараз"),
            Copy(key: "codex.remember.title", resource: .codexRememberTitle,
                 en: "Remember this Codex sign-in?",
                 fr: "Mémoriser cette connexion Codex\u{202F}?",
                 uk: "Зберегти цей вхід Codex?"),
        ]
    }

    func testRememberSheetInEveryLanguage() {
        check(Self.rememberSheet)
    }

    // MARK: settings

    /// Settings › Codex, its sidebar item, and the privacy wording (spec §4.7).
    private static var settings: [Copy] {
        [
            Copy(key: "codex.settings.auto.acknowledge", resource: .codexSettingsAutoAcknowledge,
                 en: "Codex uses its default sign-in file (no CODEX_HOME, no keychain store)",
                 fr: "Codex utilise son fichier de connexion par défaut (sans CODEX_HOME ni trousseau)",
                 uk: "Codex використовує стандартний файл входу (без CODEX_HOME і без зберігання у в’язці ключів)"),
            Copy(key: "codex.settings.auto.explain", resource: .codexSettingsAutoExplain,
                 en: "Ration switches Codex to the remembered account with the most room on its weekly limit, and never to one already past your threshold. Only new Codex sessions use the new account; restart running ones.",
                 fr: "Ration bascule Codex vers le compte mémorisé qui a le plus de marge sur sa limite hebdomadaire, jamais vers un compte qui a déjà dépassé votre seuil. Seules les nouvelles sessions Codex utilisent le nouveau compte\u{00A0}; redémarrez celles en cours.",
                 uk: "Ration перемикає Codex на збережений обліковий запис із найбільшим запасом тижневого ліміту і ніколи — на обліковий запис, який уже перевищив ваш поріг. Новий обліковий запис використовують лише нові сесії Codex; перезапустіть запущені."),
            Copy(key: "codex.settings.auto.header", resource: .codexSettingsAutoHeader,
                 en: "Switch automatically",
                 fr: "Basculer automatiquement",
                 uk: "Перемикати автоматично"),
            Copy(key: "codex.settings.auto.needsAcknowledge", resource: .codexSettingsAutoNeedsAcknowledge,
                 en: "Confirm the line above to switch automatically.",
                 fr: "Confirmez la ligne ci-dessus pour basculer automatiquement.",
                 uk: "Підтвердьте рядок вище, щоб перемикати автоматично."),
            Copy(key: "codex.settings.auto.paused", resource: .codexSettingsAutoPaused,
                 en: "Paused after a switch that didn’t go through.",
                 fr: "En pause après un basculement qui n’a pas abouti.",
                 uk: "Призупинено після невдалого перемикання."),
            Copy(key: "codex.settings.auto.percent", resource: .codexSettingsAutoPercent(75),
                 en: "75%",
                 fr: "75\u{202F}%",
                 uk: "75%"),
            Copy(key: "codex.settings.auto.resume", resource: .codexSettingsAutoResume,
                 en: "Resume",
                 fr: "Reprendre",
                 uk: "Відновити"),
            Copy(key: "codex.settings.auto.threshold", resource: .codexSettingsAutoThreshold,
                 en: "Switch when used",
                 fr: "Basculer à partir de",
                 uk: "Перемикати, коли використано"),
            Copy(key: "codex.settings.auto.toggle", resource: .codexSettingsAutoToggle,
                 en: "Switch Codex automatically",
                 fr: "Basculer Codex automatiquement",
                 uk: "Перемикати Codex автоматично"),
            Copy(key: "codex.settings.current.tag", resource: .codexSettingsCurrentTag,
                 en: "In use by Codex",
                 fr: "Utilisée par Codex",
                 uk: "Використовується Codex"),
            Copy(key: "codex.settings.forget", resource: .codexSettingsForget,
                 en: "Forget",
                 fr: "Oublier",
                 uk: "Забути"),
            Copy(key: "codex.settings.forget.blocked", resource: .codexSettingsForgetBlocked,
                 en: "Resume after running codex login before forgetting a sign-in.",
                 fr: "Lancez codex login, puis «\u{00A0}Reprendre\u{00A0}», avant d’oublier une connexion.",
                 uk: "Перш ніж забути вхід, виконайте codex login і натисніть «Відновити»."),
            Copy(key: "codex.settings.forgetAll", resource: .codexSettingsForgetAll,
                 en: "Forget all sign-ins",
                 fr: "Oublier toutes les connexions",
                 uk: "Забути всі входи"),
            Copy(key: "codex.settings.forgetAll.confirm", resource: .codexSettingsForgetAllConfirm,
                 en: "Forget every remembered Codex sign-in?",
                 fr: "Oublier toutes les connexions Codex mémorisées\u{202F}?",
                 uk: "Забути всі збережені входи Codex?"),
            Copy(key: "codex.settings.forgetAll.message", resource: .codexSettingsForgetAllMessage,
                 en: "Ration deletes its copies, the links and the switch history. Codex itself stays signed in.",
                 fr: "Ration supprime ses copies, les liens et l’historique des basculements. Codex lui-même reste connecté.",
                 uk: "Ration видалить свої копії, зв’язки та історію перемикань. Сам Codex залишиться в системі."),
            Copy(key: "codex.settings.link.chosen", resource: .codexSettingsLinkChosen,
                 en: "Chosen by you — not used for automatic switching",
                 fr: "Choisie par vous — pas utilisée pour le basculement automatique",
                 uk: "Вибрано вами — не використовується для автоматичного перемикання"),
            Copy(key: "codex.settings.link.label", resource: .codexSettingsLinkLabel,
                 en: "Ration account",
                 fr: "Compte Ration",
                 uk: "Обліковий запис Ration"),
            Copy(key: "codex.settings.link.none", resource: .codexSettingsLinkNone,
                 en: "Not linked",
                 fr: "Non liée",
                 uk: "Не пов’язано"),
            Copy(key: "codex.settings.link.validityUnknown", resource: .codexSettingsLinkValidityUnknown,
                 en: "Not refreshed for 7 days: used by hand only. If Codex asks you to log in, sign in and Remember again.",
                 fr: "Non actualisée depuis 7\u{00A0}jours\u{00A0}: réservée au basculement manuel. Si Codex vous demande de vous connecter, connectez-vous, puis mémorisez-la à nouveau.",
                 uk: "Не оновлювався 7 днів: лише для ручного перемикання. Якщо Codex попросить увійти, увійдіть і знову збережіть вхід."),
            Copy(key: "codex.settings.link.verified", resource: .codexSettingsLinkVerified,
                 en: "Verified",
                 fr: "Vérifiée",
                 uk: "Перевірено"),
            Copy(key: "codex.settings.notify", resource: .codexSettingsNotify,
                 en: "Notify me when Ration switches Codex",
                 fr: "M’avertir quand Ration bascule Codex",
                 uk: "Сповіщати, коли Ration перемикає Codex"),
            Copy(key: "codex.settings.now.header", resource: .codexSettingsNowHeader,
                 en: "Codex now",
                 fr: "Codex maintenant",
                 uk: "Codex зараз"),
            Copy(key: "codex.settings.now.none", resource: .codexSettingsNowNone,
                 en: "Codex isn’t signed in with a ChatGPT account in its default configuration.",
                 fr: "Codex n’est pas connecté à un compte ChatGPT dans sa configuration par défaut.",
                 uk: "Codex не ввійшов в обліковий запис ChatGPT у стандартній конфігурації."),
            Copy(key: "codex.settings.now.remember", resource: .codexSettingsNowRemember,
                 en: "Remember…",
                 fr: "Mémoriser…",
                 uk: "Зберегти…"),
            Copy(key: "codex.settings.now.rememberAgain", resource: .codexSettingsNowRememberAgain,
                 en: "Remember again",
                 fr: "Mémoriser à nouveau",
                 uk: "Зберегти знову"),
            Copy(key: "codex.settings.now.remembered", resource: .codexSettingsNowRemembered,
                 en: "Remembered",
                 fr: "Mémorisée",
                 uk: "Збережено"),
            Copy(key: "codex.settings.privacy", resource: .codexSettingsPrivacy,
                 en: "Ration keeps a copy of each remembered sign-in in its own login Keychain items (never synced) so it can switch Codex without a login, and keeps the sign-in ids, their links and its last 500 switches in its own folder. It reads and writes Codex’s sign-in file, which the ChatGPT app’s Codex also uses, and sends none of the remembered sign-ins anywhere. Forget deletes one copy and its link; Forget all deletes every copy, the links and the switch history; Codex itself stays signed in. A parked copy can stop working if that account is refreshed elsewhere; Ration then asks you to sign in and Remember again.",
                 fr: "Ration garde une copie de chaque connexion mémorisée dans ses propres éléments de votre trousseau de session (jamais synchronisés) pour basculer Codex sans nouvelle connexion, et conserve les identifiants des connexions, leurs liens et ses 500 derniers basculements dans son propre dossier. Il lit et écrit le fichier de connexion de Codex, que le Codex de l’app ChatGPT utilise aussi, et n’envoie aucune des connexions mémorisées nulle part. «\u{00A0}Oublier\u{00A0}» supprime une copie et son lien\u{00A0}; «\u{00A0}Oublier toutes les connexions\u{00A0}» supprime toutes les copies, les liens et l’historique des basculements\u{00A0}; Codex lui-même reste connecté. Une copie mise de côté peut cesser de fonctionner si ce compte est actualisé ailleurs\u{00A0}; Ration vous demande alors de vous reconnecter et de la mémoriser à nouveau.",
                 uk: "Ration зберігає копію кожного збереженого входу у власних елементах вашої в’язки ключів входу (без синхронізації), щоб перемикати Codex без нового входу, а ідентифікатори входів, їхні зв’язки та останні 500 перемикань — у власній теці. Він читає й записує файл входу Codex, яким також користується Codex у застосунку ChatGPT, і нікуди не надсилає жодного зі збережених входів. «Забути» видаляє одну копію та її зв’язок; «Забути всі входи» видаляє всі копії, зв’язки та історію перемикань; сам Codex залишається в системі. Відкладена копія може перестати працювати, якщо цей обліковий запис оновлено деінде; тоді Ration попросить вас увійти й знову зберегти вхід."),
            Copy(key: "codex.settings.remembered.empty", resource: .codexSettingsRememberedEmpty,
                 en: "None yet. Remember the sign-in Codex uses now, then sign in to your other account in Codex and remember that one too.",
                 fr: "Aucune pour l’instant. Mémorisez la connexion que Codex utilise, puis connectez-vous à votre autre compte dans Codex et mémorisez-la aussi.",
                 uk: "Поки немає. Збережіть вхід, який зараз використовує Codex, потім увійдіть в інший обліковий запис у Codex і збережіть і його."),
            Copy(key: "codex.settings.remembered.header", resource: .codexSettingsRememberedHeader,
                 en: "Remembered sign-ins",
                 fr: "Connexions mémorisées",
                 uk: "Збережені входи"),
            Copy(key: "codex.settings.restart", resource: .codexSettingsRestart,
                 en: "Only new Codex sessions use the switched account. Restart running ones, including the ChatGPT app’s Codex.",
                 fr: "Seules les nouvelles sessions Codex utilisent le compte basculé. Redémarrez celles en cours, y compris le Codex de l’app ChatGPT.",
                 uk: "Перемкнений обліковий запис використовують лише нові сесії Codex. Перезапустіть запущені, зокрема Codex у застосунку ChatGPT."),
            Copy(key: "codex.settings.saveFailed", resource: .codexSettingsSaveFailed,
                 en: "Ration couldn’t save its Codex settings, so automatic switching is off. Try turning it on again.",
                 fr: "Ration n’a pas pu enregistrer ses réglages Codex\u{00A0}; le basculement automatique est donc désactivé. Réessayez de l’activer.",
                 uk: "Ration не зміг зберегти налаштування Codex, тому автоматичне перемикання вимкнено. Спробуйте ввімкнути його знову."),
            Copy(key: "codex.settings.status.header", resource: .codexSettingsStatusHeader,
                 en: "Last event",
                 fr: "Dernier événement",
                 uk: "Остання подія"),
            Copy(key: "codex.settings.switch", resource: .codexSettingsSwitch,
                 en: "Switch",
                 fr: "Basculer",
                 uk: "Перемкнути"),
            Copy(key: "settings.sidebar.codex", resource: .settingsSidebarCodex,
                 en: "Codex",
                 fr: "Codex",
                 uk: "Codex"),
        ]
    }

    func testSettingsInEveryLanguage() {
        check(Self.settings)
    }

    // MARK: statusLine

    /// The status line in the popover and Settings.
    private static var statusLine: [Copy] {
        [
            Copy(key: "codex.status.damaged", resource: .codexStatusDamaged,
                 en: "Codex’s sign-in file mixes two accounts — run codex login",
                 fr: "Fichier de connexion Codex mêlant deux comptes — lancez codex login",
                 uk: "Файл входу Codex змішує два облікові записи — виконайте codex login"),
            Copy(key: "codex.status.failed", resource: .codexStatusFailed,
                 en: "Couldn’t switch Codex",
                 fr: "Impossible de basculer Codex",
                 uk: "Не вдалося перемкнути Codex"),
            Copy(key: "codex.status.needsAttention", resource: .codexStatusNeedsAttention,
                 en: "Codex’s sign-in needs attention",
                 fr: "La connexion de Codex demande votre attention",
                 uk: "Вхід Codex потребує уваги"),
            Copy(key: "codex.status.noRoom", resource: .codexStatusNoRoom,
                 en: "No remembered ChatGPT account has room",
                 fr: "Aucun compte ChatGPT mémorisé n’a de marge",
                 uk: "Жоден збережений обліковий запис ChatGPT не має запасу"),
            Copy(key: "codex.status.paused", resource: .codexStatusPaused,
                 en: "Automatic Codex switching is paused",
                 fr: "Le basculement automatique de Codex est en pause",
                 uk: "Автоматичне перемикання Codex призупинено"),
            Copy(key: "codex.status.remember", resource: .codexStatusRemember("bob@example.com"),
                 en: "Codex is on bob@example.com — remember it",
                 fr: "Codex utilise bob@example.com — mémorisez-le",
                 uk: "Codex на bob@example.com — збережіть його"),
            Copy(key: "codex.status.stale", resource: .codexStatusStale("Work"),
                 en: "Sign in to Work in Codex, then Remember it again",
                 fr: "Connectez-vous à Work dans Codex, puis mémorisez à nouveau la connexion",
                 uk: "Увійдіть в обліковий запис Work у Codex, потім знову збережіть вхід"),
            Copy(key: "codex.status.switched.automatic", resource: .codexStatusSwitchedAutomatic("Work"),
                 en: "Codex switched to Work automatically — restart running sessions",
                 fr: "Codex est passé automatiquement à Work — redémarrez les sessions en cours",
                 uk: "Codex автоматично перемкнено на Work — перезапустіть запущені сесії"),
            Copy(key: "codex.status.switched.manual", resource: .codexStatusSwitchedManual("Work"),
                 en: "Codex now uses Work — restart running sessions",
                 fr: "Codex utilise maintenant Work — redémarrez les sessions en cours",
                 uk: "Codex тепер використовує Work — перезапустіть запущені сесії"),
            Copy(key: "codex.status.switched.unverified", resource: .codexStatusSwitchedUnverified("Work"),
                 en: "Codex now uses Work — it refreshed its sign-in meanwhile; restart running sessions",
                 fr: "Codex utilise maintenant Work — il a renouvelé sa connexion entre-temps\u{00A0}; redémarrez les sessions en cours",
                 uk: "Codex тепер використовує Work — тим часом він оновив свій вхід; перезапустіть запущені сесії"),
            Copy(key: "codex.status.switched.sameWorkspace", resource: .codexStatusSwitchedSameWorkspace("Work"),
                 en: "Codex now uses Work — same workspace: running sessions may follow; restart to be sure",
                 fr: "Codex utilise maintenant Work — même espace de travail\u{00A0}: les sessions en cours peuvent basculer aussi\u{00A0}; redémarrez-les par précaution",
                 uk: "Codex тепер використовує Work — той самий робочий простір: запущені сесії можуть теж перемкнутися; для певності перезапустіть їх"),
            Copy(key: "codex.status.waiting", resource: .codexStatusWaiting,
                 en: "Waiting for fresh usage to switch Codex",
                 fr: "En attente de données d’utilisation à jour pour basculer Codex",
                 uk: "Очікування свіжих даних про використання, щоб перемкнути Codex"),
        ]
    }

    func testStatusLineInEveryLanguage() {
        check(Self.statusLine)
    }

    // MARK: Coverage

    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Copy
            .deletingLastPathComponent() // Localization
            .deletingLastPathComponent() // RationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Ration/Resources/Localizable.xcstrings")
    }

    /// Every `codex.*` key in the catalog (and the sidebar item) is checked
    /// above, and every key checked above is in the catalog.
    func testEveryCodexKeyIsChecked() throws {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let inCatalog = Set(strings.keys.filter { $0.hasPrefix("codex.") || $0 == "settings.sidebar.codex" })
        let all: [Copy] = Self.cardAndFocus + Self.errors + Self.notifications + Self.rememberSheet + Self.settings + Self.statusLine
        let checked = Set(all.map(\.key))
        XCTAssertEqual(checked.count, all.count, "a key is checked twice")
        XCTAssertEqual(checked.count, 75)
        XCTAssertEqual(inCatalog.subtracting(checked).sorted(), [], "catalog keys this file doesn't check")
        XCTAssertEqual(checked.subtracting(inCatalog).sorted(), [], "checked keys missing from the catalog")
    }
}
