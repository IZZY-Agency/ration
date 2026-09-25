import XCTest
@testable import Ration

/// The setup guide, Add Account, the sign-in window, About and the app menu
/// in every shipped language: code-built copy through its `(locale:)` form,
/// and the SwiftUI literal keys through the catalog. English is pinned to the
/// 1.3.0 text.
final class OnboardingAndAccountsCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp

    // MARK: Provider hints

    /// The Claude hint is one entry per warm-up state, and each one carries
    /// the disclosure Add Account shows, word for word, so the two never
    /// drift apart.
    func testClaudeHintIsOneSentenceBlockPerWarmUpState() {
        let english = OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: true, locale: L10n.en).hint
        XCTAssertEqual(
            english,
            "If you sign in with a magic link, paste the link from your email into the field at the top of the sign-in window. Opening it in Safari signs in your browser, not Ration. Warm-up is on: Ration will start your 5-hour window automatically. Turn it off per account under Auto-start 5h window in Settings."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: false, locale: L10n.en).hint,
            "If you sign in with a magic link, paste the link from your email into the field at the top of the sign-in window. Opening it in Safari signs in your browser, not Ration. Warm-up is off in General: Ration won't start your 5-hour window automatically."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: false, locale: L10n.fr).hint,
            "Si vous vous connectez avec un lien magique, collez le lien reçu par e-mail dans le champ en haut de la fenêtre de connexion. L’ouvrir dans Safari connecte votre navigateur, pas Ration. Le préchauffage est désactivé dans Général\(nb): Ration ne démarrera pas automatiquement votre fenêtre de 5\(nb)heures."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: false, locale: L10n.uk).hint,
            "Якщо ви входите за магічним посиланням, вставте посилання з листа в поле вгорі вікна входу. Якщо відкрити його в Safari, увійде ваш браузер, а не Ration. Розігрів вимкнено в розділі «Загальні»: Ration не запускатиме ваше 5-годинне вікно автоматично."
        )
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            for enabled in [true, false] {
                let hint = OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: enabled, locale: locale).hint
                XCTAssertTrue(
                    hint.hasSuffix(" " + WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: enabled, locale: locale)),
                    "\(locale.identifier) warm-up \(enabled)"
                )
            }
        }
    }

    func testChatGPTAndCursorHintsInEveryLanguage() {
        let token = ChatGPTSessionCookiePaste.sessionTokenName
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .chatGPT, locale: L10n.en).hint,
            "Passkeys can't run in the sign-in window. Log in at chatgpt.com in your browser, then copy the \(token) cookie value (DevTools → Application → Cookies) and paste it into the sign-in window. If your browser shows numbered chunks (…session-token.0 and .1), paste BOTH as name=value pairs separated by a semicolon."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .chatGPT, locale: L10n.fr).hint,
            "Les clés d’accès ne fonctionnent pas dans la fenêtre de connexion. Connectez-vous à chatgpt.com dans votre navigateur, puis copiez la valeur du cookie \(token) (DevTools → Application → Cookies) et collez-la dans la fenêtre de connexion. Si votre navigateur affiche des fragments numérotés (…session-token.0 et .1), collez-les TOUS LES DEUX sous forme de paires name=value séparées par un point-virgule."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .chatGPT, locale: L10n.uk).hint,
            "Ключі доступу не працюють у вікні входу. Увійдіть на chatgpt.com у браузері, скопіюйте значення cookie \(token) (DevTools → Application → Cookies) і вставте його у вікно входу. Якщо браузер показує пронумеровані частини (…session-token.0 і .1), вставте ОБИДВІ як пари name=value, розділені крапкою з комою."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .cursor, locale: L10n.en).hint,
            "A normal cursor.com sign-in. Cursor reports usage-based spend for the billing cycle rather than a percentage of plan."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .cursor, locale: L10n.fr).hint,
            "Une connexion cursor.com classique. Cursor indique les dépenses à l’usage du cycle de facturation plutôt qu’un pourcentage du forfait."
        )
        XCTAssertEqual(
            OnboardingProviderGuide.guide(for: .cursor, locale: L10n.uk).hint,
            "Звичайний вхід на cursor.com. Cursor показує витрати на використання за платіжний цикл, а не відсоток від тарифу."
        )
    }

    // MARK: Steps

    func testWelcomeStepInEveryLanguage() {
        let en = OnboardingWelcomeStep.copy(locale: L10n.en)
        XCTAssertEqual(en.title, "Welcome to Ration")
        XCTAssertEqual(en.subtitle, "Your real Claude, ChatGPT and Cursor limits, in the menu bar.")
        XCTAssertEqual(en.bullets.map(\.symbol), ["gauge.with.needle", "lock.laptopcomputer", "menubar.arrow.up.rectangle"])
        XCTAssertEqual(en.bullets.map(\.title), ["Real numbers, not guesses", "No middleman", "Lives in your menu bar"])
        XCTAssertEqual(en.bullets.map(\.detail), [
            "Reads the same usage endpoints each provider's own site uses — 5-hour and weekly windows, resets, and spend.",
            "There's no Ration server, no telemetry, and no account to create. You sign in on the provider's own page — or your SSO provider's, if you use one — and the session stays in an isolated profile on this Mac.",
            "There's no Dock icon. Click the ring in the menu bar — or press ⌥⌘U — to open it.",
        ])

        let fr = OnboardingWelcomeStep.copy(locale: L10n.fr)
        XCTAssertEqual(fr.title, "Bienvenue dans Ration")
        XCTAssertEqual(fr.bullets.map(\.title), ["Des chiffres réels, pas des estimations", "Aucun intermédiaire", "Dans votre barre des menus"])
        XCTAssertEqual(
            fr.bullets[2].detail,
            "Pas d’icône dans le Dock. Cliquez sur l’anneau dans la barre des menus — ou appuyez sur ⌥⌘U — pour l’ouvrir."
        )

        let uk = OnboardingWelcomeStep.copy(locale: L10n.uk)
        XCTAssertEqual(uk.title, "Ласкаво просимо до Ration")
        XCTAssertEqual(uk.subtitle, "Ваші реальні ліміти Claude, ChatGPT і Cursor — у рядку меню.")
        XCTAssertEqual(uk.bullets.map(\.title), ["Реальні цифри, а не здогадки", "Без посередників", "Живе в рядку меню"])
        XCTAssertEqual(uk.bullets.map(\.symbol), en.bullets.map(\.symbol))
    }

    func testConnectAndLaunchStepsInEveryLanguage() {
        XCTAssertEqual(OnboardingConnectStep.header(locale: L10n.en).title, "Connect your first account")
        XCTAssertEqual(
            OnboardingConnectStep.header(locale: L10n.en).subtitle,
            "Each account gets its own isolated browser profile on this Mac. Check the padlock address bar before you type a password."
        )
        XCTAssertEqual(
            OnboardingConnectStep.waitingText(locale: L10n.en),
            "Waiting for sign-in… this step finishes by itself once the account is verified."
        )
        XCTAssertEqual(OnboardingConnectStep.header(locale: L10n.fr).title, "Connectez votre premier compte")
        XCTAssertEqual(OnboardingConnectStep.header(locale: L10n.uk).title, "Під’єднайте перший обліковий запис")
        XCTAssertEqual(
            OnboardingConnectStep.waitingText(locale: L10n.fr),
            "En attente de connexion… cette étape se termine d’elle-même une fois le compte vérifié."
        )
        XCTAssertEqual(
            OnboardingConnectStep.waitingText(locale: L10n.uk),
            "Очікування входу… цей крок завершиться сам, щойно обліковий запис буде перевірено."
        )

        let launch = OnboardingLaunchAtLoginStep.header(locale: L10n.en)
        XCTAssertEqual(launch.title, "Keep it running")
        XCTAssertEqual(
            launch.subtitle,
            "Ration can only track your limits while it's running. Starting it at login means you never have to think about it."
        )
        XCTAssertEqual(OnboardingLaunchAtLoginStep.header(locale: L10n.fr).title, "Laissez Ration ouvert")
        XCTAssertEqual(OnboardingLaunchAtLoginStep.header(locale: L10n.uk).title, "Тримайте Ration запущеним")
    }

    func testDoneStepFollowsWhetherAnAccountIsConnected() {
        let ready = OnboardingDoneStep.copy(hasAccounts: true, locale: L10n.en)
        XCTAssertEqual(ready.title, "You're all set")
        XCTAssertEqual(ready.subtitle, "Ration is watching your limits. Here's where everything lives.")
        XCTAssertEqual(ready.bullets.map(\.title), ["Can't find the icon?", "More accounts", "Settings", "History", "Alerts", "Open source"])
        XCTAssertEqual(ready.bullets.map(\.symbol), [
            "menubar.arrow.up.rectangle", "plus.circle", "gearshape", "chart.xyaxis.line", "bell.badge",
            "chevron.left.forwardslash.chevron.right",
        ])
        XCTAssertEqual(ready.bullets[1].detail, "Add another any time with the + button at the bottom of the popover.")
        XCTAssertEqual(ready.bullets[2].detail, "⌘, opens it — account labels, sort order, warm-up quiet hours, and this guide.")
        XCTAssertEqual(ready.bullets[3].detail, "Burn-down charts and billing-cycle utilisation per account.")
        XCTAssertEqual(
            ready.bullets[4].detail,
            "Notifies you at thresholds you choose (75% and 90% to begin with). Set them in Settings → Alerts."
        )
        XCTAssertEqual(
            ready.bullets[5].detail,
            "Source, releases and issues live at github.com/IZZY-Agency/ration. The website is ration.sh — both are one click away in Settings → General and in About."
        )

        let empty = OnboardingDoneStep.copy(hasAccounts: false, locale: L10n.en)
        XCTAssertEqual(empty.title, "Ready when you are")
        XCTAssertEqual(
            empty.subtitle,
            "No account is connected yet, so there's nothing to track so far. Here's where everything lives when you're ready."
        )
        XCTAssertEqual(empty.bullets[1].title, "Connect an account")
        XCTAssertEqual(
            empty.bullets[1].detail,
            "Use the + button at the bottom of the popover, or re-open this guide from Settings → General."
        )

        let fr = OnboardingDoneStep.copy(hasAccounts: true, locale: L10n.fr)
        XCTAssertEqual(fr.title, "Tout est prêt")
        XCTAssertEqual(fr.bullets[0].title, "Vous ne trouvez pas l’icône\(nb)?")
        XCTAssertEqual(
            fr.bullets[4].detail,
            "Vous avertit aux seuils de votre choix (75\(nb)% et 90\(nb)% pour commencer). Réglez-les dans Réglages → Alertes."
        )
        let ukReady = OnboardingDoneStep.copy(hasAccounts: true, locale: L10n.uk)
        XCTAssertEqual(
            ukReady.bullets[4].detail,
            "Сповіщає на вибраних вами порогах (спершу 75% і 90%). Налаштуйте їх у «Параметри → Сповіщення»."
        )
        XCTAssertEqual(
            ukReady.bullets[5].detail,
            "Вихідний код, випуски та звернення — на github.com/IZZY-Agency/ration. Вебсайт — ration.sh; обидва посилання є в «Параметри → Загальні» і в «Про програму»."
        )
        let uk = OnboardingDoneStep.copy(hasAccounts: false, locale: L10n.uk)
        XCTAssertEqual(uk.title, "Усе чекає на вас")
        XCTAssertEqual(uk.bullets[1].title, "Під’єднати обліковий запис")
        XCTAssertEqual(
            uk.bullets[1].detail,
            "Скористайтеся кнопкою + унизу меню Ration або знову відкрийте цей посібник у «Параметри → Загальні»."
        )
    }

    /// The Done step names panes and windows; each name must be the one the
    /// control itself carries in that language.
    func testDoneStepQuotesTheNamesOfTheControls() {
        for locale in [L10n.fr, L10n.uk] {
            let copy = OnboardingDoneStep.copy(hasAccounts: true, locale: locale)
            let settings = LocalizedStringResource("Settings").string(in: locale)
            let history = LocalizedStringResource("History").string(in: locale)
            let alerts = SettingsSidebar.fixedTitles(locale: locale)[2]
            let general = SettingsSidebar.fixedTitles(locale: locale)[0]
            let about = LocalizedStringResource("About").string(in: locale)
            XCTAssertEqual(copy.bullets[2].title, settings)
            XCTAssertEqual(copy.bullets[3].title, history)
            XCTAssertEqual(copy.bullets[4].title, alerts)
            XCTAssertTrue(copy.bullets[4].detail.contains("\(settings) → \(alerts)"), locale.identifier)
            XCTAssertTrue(copy.bullets[5].detail.contains("\(settings) → \(general)"), locale.identifier)
            XCTAssertTrue(copy.bullets[5].detail.contains(about), locale.identifier)
            let empty = OnboardingDoneStep.copy(hasAccounts: false, locale: locale)
            XCTAssertTrue(empty.bullets[1].detail.contains("\(settings) → \(general)"), locale.identifier)
        }
    }

    // MARK: Sign-in window

    func testSignInCodeBuiltCopyInEveryLanguage() {
        let token = ChatGPTSessionCookiePaste.sessionTokenName
        XCTAssertEqual(SignInCopy.hostText("claude.ai", locale: L10n.fr), "claude.ai")
        XCTAssertEqual(SignInCopy.hostText(nil, locale: L10n.en), "loading…")
        XCTAssertEqual(SignInCopy.hostText(nil, locale: L10n.fr), "chargement…")
        XCTAssertEqual(SignInCopy.hostText(nil, locale: L10n.uk), "завантаження…")

        XCTAssertEqual(
            SignInCopy.notASessionCookie(locale: L10n.en),
            "That doesn't look like a session cookie — copy the value of \(token)."
        )
        XCTAssertEqual(
            SignInCopy.notASessionCookie(locale: L10n.fr),
            "Cela ne ressemble pas à un cookie de session — copiez la valeur de \(token)."
        )
        XCTAssertEqual(
            SignInCopy.notASessionCookie(locale: L10n.uk),
            "Це не схоже на cookie сеансу — скопіюйте значення \(token)."
        )
        XCTAssertEqual(SignInCopy.cookieApplyFailed(locale: L10n.en), "Could not apply the cookie. Try copying it again.")
        XCTAssertEqual(SignInCopy.cookieApplyFailed(locale: L10n.fr), "Impossible d’appliquer le cookie. Essayez de le copier à nouveau.")
        XCTAssertEqual(SignInCopy.cookieApplyFailed(locale: L10n.uk), "Не вдалося застосувати cookie. Спробуйте скопіювати його ще раз.")
        XCTAssertEqual(SignInCopy.invalidMagicLink(locale: L10n.en), "Paste the secure claude.ai magic link from your email.")
        XCTAssertEqual(SignInCopy.invalidMagicLink(locale: L10n.fr), "Collez le lien magique sécurisé claude.ai reçu par e-mail.")
        XCTAssertEqual(SignInCopy.invalidMagicLink(locale: L10n.uk), "Вставте захищене магічне посилання claude.ai з листа.")
    }

    // MARK: About

    func testAboutInfoInEveryLanguage() {
        let complete: [String: Any] = [
            "CFBundleDisplayName": "Ration",
            "CFBundleShortVersionString": "1.3.0",
            "CFBundleVersion": "80",
            "NSHumanReadableCopyright": "Copyright © 2026 IZZY.Agency",
        ]
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.en).versionText, "Version 1.3.0 (80)")
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.fr).versionText, "Version 1.3.0 (80)")
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.uk).versionText, "Версія 1.3.0 (80)")
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.uk).displayName, "Ration")
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.en).copyrightText, "Copyright © 2026 IZZY.Agency")
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.fr).copyrightText, "Copyright © 2026 IZZY.Agency")
        XCTAssertEqual(AboutAppInfo(infoDictionary: complete, locale: L10n.uk).copyrightText, "© 2026 IZZY.Agency. Усі права захищено.")

        let missingFR = AboutAppInfo(infoDictionary: [:], locale: L10n.fr)
        XCTAssertEqual(missingFR.displayName, "Application")
        XCTAssertEqual(missingFR.versionText, "Version indisponible")
        XCTAssertEqual(missingFR.copyrightText, "Copyright indisponible")
        let missingUK = AboutAppInfo(infoDictionary: [:], locale: L10n.uk)
        XCTAssertEqual(missingUK.displayName, "Програма")
        XCTAssertEqual(missingUK.versionText, "Версія недоступна")
        XCTAssertEqual(missingUK.copyrightText, "Відомості про авторські права недоступні")
        let missingEN = AboutAppInfo(infoDictionary: [:], locale: L10n.en)
        XCTAssertEqual(missingEN.versionText, "Version unavailable")
    }

    func testAboutLinksTranslateOnlyTheIssueLink() {
        XCTAssertEqual(AppLinks.all.map { $0.displayTitle(locale: L10n.en) }, ["ration.sh", "GitHub", "Report an issue"])
        XCTAssertEqual(AppLinks.all.map { $0.displayTitle(locale: L10n.fr) }, ["ration.sh", "GitHub", "Signaler un bug"])
        XCTAssertEqual(AppLinks.all.map { $0.displayTitle(locale: L10n.uk) }, ["ration.sh", "GitHub", "Звіт про помилку"])
    }

    // MARK: SwiftUI literal keys

    func testViewLiteralsResolve() {
        let expected: [(key: String, fr: String, uk: String)] = [
            // Onboarding shell
            ("Skip setup", "Passer la configuration", "Пропустити налаштування"),
            ("Back", "Retour", "Назад"),
            ("Done", "Terminé", "Готово"),
            ("Skip for now", "Ignorer pour l’instant", "Поки що пропустити"),
            ("Continue", "Continuer", "Продовжити"),
            // Add Account
            ("Add account", "Ajouter un compte", "Додати обліковий запис"),
            ("Each account gets a separate persistent browser profile.",
             "Chaque compte dispose de son propre profil de navigateur persistant.",
             "Кожен обліковий запис отримує окремий постійний профіль браузера."),
            // Sign-in window
            ("This browser profile belongs only to this account.",
             "Ce profil de navigateur appartient uniquement à ce compte.",
             "Цей профіль браузера належить лише цьому обліковому запису."),
            ("Paste the link from your email", "Collez le lien reçu par e-mail", "Вставте посилання з листа"),
            ("Claude magic link", "Lien magique Claude", "Магічне посилання Claude"),
            ("Open Link", "Ouvrir le lien", "Відкрити посилання"),
            ("Magic links must open in this isolated browser profile.",
             "Les liens magiques doivent s’ouvrir dans ce profil de navigateur isolé.",
             "Магічні посилання треба відкривати в цьому ізольованому профілі браузера."),
            ("Passkey-only account? Paste your session cookie",
             "Compte avec clé d’accès uniquement\(nb)? Collez votre cookie de session",
             "Обліковий запис лише з ключем доступу? Вставте cookie сеансу"),
            ("ChatGPT session cookie", "Cookie de session ChatGPT", "Cookie сеансу ChatGPT"),
            ("Apply", "Appliquer", "Застосувати"),
            ("Cookie applied — once the page shows you signed in, add the account below.",
             "Cookie appliqué — dès que la page indique que vous êtes connecté, ajoutez le compte ci-dessous.",
             "Cookie застосовано — щойно сторінка покаже, що ви ввійшли, додайте обліковий запис нижче."),
            ("Check this address before entering your password.",
             "Vérifiez cette adresse avant de saisir votre mot de passe.",
             "Перевірте цю адресу, перш ніж вводити пароль."),
            ("Local account label", "Libellé local du compte", "Локальна назва облікового запису"),
            ("Provider page detected. Verify when sign-in is complete.",
             "Page du fournisseur détectée. Vérifiez le compte une fois connecté.",
             "Сторінку постачальника виявлено. Перевірте обліковий запис, коли вхід завершиться."),
            ("Finish sign-in, then return to the provider page.",
             "Terminez la connexion, puis revenez à la page du fournisseur.",
             "Завершіть вхід, а потім поверніться на сторінку постачальника."),
            ("Verify Account", "Vérifier le compte", "Перевірити обліковий запис"),
            // App menu and window fallbacks
            ("Settings…", "Réglages…", "Параметри…"),
            ("Sign-in session unavailable", "Session de connexion indisponible", "Сеанс входу недоступний"),
            ("Close this window and start again from Add Account.",
             "Fermez cette fenêtre et recommencez depuis «\(nb)Ajouter un compte\(nb)».",
             "Закрийте це вікно й почніть знову з пункту «Додати обліковий запис»."),
            // Reused from Tasks 5 and 6.
            ("Launch at login", "Ouvrir à la connexion", "Запускати під час входу"),
            ("Open Login Items Settings", "Ouvrir les réglages Ouverture", "Відкрити параметри елементів входу"),
            ("Cancel", "Annuler", "Скасувати"),
            ("Add Account", "Ajouter un compte", "Додати обліковий запис"),
            ("Sign In", "Se connecter", "Увійти"),
            ("About Ration", "À propos de Ration", "Про Ration"),
            ("Setup Guide", "Guide de configuration", "Посібник із налаштування"),
        ]
        for entry in expected {
            let resource = LocalizedStringResource(String.LocalizationValue(entry.key))
            XCTAssertEqual(resource.string(in: L10n.en), entry.key)
            XCTAssertEqual(resource.string(in: L10n.fr), entry.fr, entry.key)
            XCTAssertEqual(resource.string(in: L10n.uk), entry.uk, entry.key)
        }
    }

    /// The Add Account fallback names the menu command it points to.
    func testSignInFallbackQuotesTheAddAccountCommand() {
        let fallback = LocalizedStringResource("Close this window and start again from Add Account.")
        for locale in [L10n.fr, L10n.uk] {
            XCTAssertTrue(
                fallback.string(in: locale).contains(LocalizedStringResource("Add Account").string(in: locale)),
                locale.identifier
            )
        }
    }

    func testInterpolatedLiteralsResolve() {
        let index = 2
        let total = 4
        let step = LocalizedStringResource("STEP \(index) OF \(total)")
        XCTAssertEqual(step.string(in: L10n.en), "STEP 2 OF 4")
        XCTAssertEqual(step.string(in: L10n.fr), "ÉTAPE 2 SUR 4")
        XCTAssertEqual(step.string(in: L10n.uk), "КРОК 2 З 4")

        let provider = "ChatGPT"
        let signIn = LocalizedStringResource("Sign in to \(provider)")
        XCTAssertEqual(signIn.string(in: L10n.en), "Sign in to ChatGPT")
        XCTAssertEqual(signIn.string(in: L10n.fr), "Se connecter à ChatGPT")
        XCTAssertEqual(signIn.string(in: L10n.uk), "Увійти в ChatGPT")

        let connect = LocalizedStringResource("Connect another \(provider) subscription")
        XCTAssertEqual(connect.string(in: L10n.en), "Connect another ChatGPT subscription")
        XCTAssertEqual(connect.string(in: L10n.fr), "Connecter un autre abonnement ChatGPT")
        XCTAssertEqual(connect.string(in: L10n.uk), "Під’єднати ще одну підписку ChatGPT")

        let add = LocalizedStringResource("Add \(provider) account")
        XCTAssertEqual(add.string(in: L10n.en), "Add ChatGPT account")
        XCTAssertEqual(add.string(in: L10n.fr), "Ajouter un compte ChatGPT")
        XCTAssertEqual(add.string(in: L10n.uk), "Додати обліковий запис ChatGPT")

        let verified = LocalizedStringResource("Verified \(provider) domain")
        XCTAssertEqual(verified.string(in: L10n.en), "Verified ChatGPT domain")
        XCTAssertEqual(verified.string(in: L10n.fr), "Domaine ChatGPT vérifié")
        XCTAssertEqual(verified.string(in: L10n.uk), "Перевірений домен ChatGPT")

        let token = ChatGPTSessionCookiePaste.sessionTokenName
        let passkeys = LocalizedStringResource(
            "Passkeys can't run in this view. Log in at chatgpt.com in your browser, then copy the \(token) cookie value (DevTools → Application → Cookies) and paste it here. If your browser shows numbered chunks (…session-token.0 and .1), paste BOTH as name=value pairs separated by a semicolon. It stays in this account's isolated profile."
        )
        XCTAssertEqual(
            passkeys.string(in: L10n.fr),
            "Les clés d’accès ne fonctionnent pas dans cette fenêtre. Connectez-vous à chatgpt.com dans votre navigateur, puis copiez la valeur du cookie \(token) (DevTools → Application → Cookies) et collez-la ici. Si votre navigateur affiche des fragments numérotés (…session-token.0 et .1), collez-les TOUS LES DEUX sous forme de paires name=value séparées par un point-virgule. Le cookie reste dans le profil isolé de ce compte."
        )
        XCTAssertEqual(
            passkeys.string(in: L10n.uk),
            "Ключі доступу не працюють у цьому вікні. Увійдіть на chatgpt.com у браузері, скопіюйте значення cookie \(token) (DevTools → Application → Cookies) і вставте його сюди. Якщо браузер показує пронумеровані частини (…session-token.0 і .1), вставте ОБИДВІ як пари name=value, розділені крапкою з комою. Cookie залишиться в ізольованому профілі цього облікового запису."
        )
    }

    /// With no locale passed, the code-built copy follows the running language.
    func testDefaultsFollowTheRunningLanguage() {
        let running = Locale(identifier: AppLanguage.current.rawValue)
        XCTAssertEqual(OnboardingWelcomeStep.copy(), OnboardingWelcomeStep.copy(locale: running))
        XCTAssertEqual(OnboardingDoneStep.copy(hasAccounts: true), OnboardingDoneStep.copy(hasAccounts: true, locale: running))
        XCTAssertEqual(SignInCopy.hostText(nil), SignInCopy.hostText(nil, locale: running))
        XCTAssertEqual(AboutAppInfo(infoDictionary: [:]), AboutAppInfo(infoDictionary: [:], locale: running))
        XCTAssertEqual(String(localized: "Settings…"), LocalizedStringResource("Settings…").string(in: running))
    }
}
