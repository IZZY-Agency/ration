import XCTest
@testable import Ration

/// The stale-help copy — the Settings "Needs attention" banner and the
/// popover header's hover card — for every cause, in every shipped language.
final class AttentionCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    /// 2026-09-26 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_434_800)
    private let utc = TimeZone(identifier: "UTC")!
    /// The narrow no-break space ICU puts before AM/PM in en_US.
    private let pm = "\u{202F}PM"

    private func presentation(
        _ label: String,
        _ provider: Provider,
        age: TimeInterval?,
        state: AccountViewState
    ) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(
            id: id, provider: provider, label: label,
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast
        )
        let snapshot = age.map {
            UsageSnapshot(accountID: id, fetchedAt: now.addingTimeInterval(-$0), fiveHour: nil, weekly: nil)
        }
        return AccountPresentation(account: account, snapshot: snapshot, state: state)
    }

    private func guidance(_ presentation: AccountPresentation, _ locale: Locale) throws -> AttentionGuidance {
        try XCTUnwrap(AttentionGuidance.make(presentation: presentation, now: now, locale: locale, timeZone: utc))
    }

    private let threeHours: TimeInterval = 3 * 3600
    private let tenMinutes: TimeInterval = 10 * 60

    // MARK: Banner — sign-in expired

    func testSignInExpired() throws {
        let p = presentation("Work", .claude, age: threeHours, state: .reauthenticationRequired)

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .signInExpired)
        XCTAssertEqual(en.label, "Needs attention")
        XCTAssertEqual(en.title, "Ration can't refresh this account")
        XCTAssertEqual(en.body, "Your sign-in expired.")
        XCTAssertEqual(en.steps, [])
        XCTAssertEqual(en.actions, [.signInAgain])
        XCTAssertEqual(en.meta, "Last successful update 12:00\(pm) · last error: sign-in expired")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.label, "Requiert votre attention")
        XCTAssertEqual(fr.title, "Ration ne peut pas actualiser ce compte")
        XCTAssertEqual(fr.body, "Votre connexion a expiré.")
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 12:00 · dernière erreur\(nb): connexion expirée")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.label, "Потребує уваги")
        XCTAssertEqual(uk.title, "Ration не може оновити цей обліковий запис")
        XCTAssertEqual(uk.body, "Термін вашого входу минув.")
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 12:00 · остання помилка: термін входу минув")
    }

    // MARK: Banner — the page does not load

    private func texts(_ steps: [AttentionGuidance.Step]) -> [String] {
        steps.map(\.text)
    }

    /// A sign-in is offered as one step, never as the diagnosis.
    func testPageNotLoading() throws {
        let p = presentation("Team", .cursor, age: threeHours, state: .stale(lastError: .transport))

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .pageNotLoading(lastError: .transport))
        XCTAssertEqual(en.title, "Ration can't refresh this account")
        XCTAssertEqual(en.body, "Cursor's page hasn't loaded for 3 hours.")
        XCTAssertEqual(texts(en.steps), [
            "Refresh now.",
            "Still failing and you're online? Your Cursor sign-in may have expired — Sign in again.",
            "Check cursor.com opens in your browser.",
        ])
        XCTAssertEqual(en.steps.map(\.link), [nil, nil, nil])
        XCTAssertEqual(en.actions, [.refreshNow, .signInAgain])
        XCTAssertEqual(en.meta, "Last successful update 12:00\(pm) · last error: page didn't load")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.body, "La page de Cursor ne se charge plus depuis 3 heures.")
        XCTAssertEqual(texts(fr.steps), [
            "Actualisez maintenant.",
            "Toujours en échec alors que vous êtes en ligne\(nb)? Votre connexion à Cursor a peut-être expiré — reconnectez-vous.",
            "Vérifiez que cursor.com s’ouvre dans votre navigateur.",
        ])
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 12:00 · dernière erreur\(nb): la page ne s’est pas chargée")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.body, "Сторінка Cursor не завантажується вже 3 години.")
        XCTAssertEqual(texts(uk.steps), [
            "Оновіть зараз.",
            "Досі не працює, хоча ви онлайн? Можливо, термін вашого входу в Cursor минув — увійдіть знову.",
            "Перевірте, чи відкривається cursor.com у вашому браузері.",
        ])
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 12:00 · остання помилка: сторінка не завантажилася")
    }

    /// Unavailable (a failed first fetch, nothing cached): same guidance, no age.
    func testUnavailable() throws {
        let p = presentation("Client", .chatGPT, age: nil, state: .unavailable)

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .pageNotLoading(lastError: nil))
        XCTAssertEqual(en.body, "ChatGPT's page isn't loading.")
        XCTAssertEqual(en.steps.last?.text, "Check chatgpt.com opens in your browser.")
        XCTAssertEqual(en.actions, [.refreshNow, .signInAgain])
        XCTAssertEqual(en.meta, "Last error: page didn't load")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.body, "La page de ChatGPT ne se charge pas.")
        XCTAssertEqual(fr.meta, "Dernière erreur\(nb): la page ne s’est pas chargée")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.body, "Сторінка ChatGPT не завантажується.")
        XCTAssertEqual(uk.meta, "Остання помилка: сторінка не завантажилася")
    }

    // MARK: Banner — server errors

    func testServerErrors() throws {
        let p = presentation("Work", .claude, age: threeHours, state: .stale(lastError: .server(statusCode: 503)))

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .serverErrors)
        XCTAssertEqual(en.body, "Claude has been returning errors for 3 hours; this is usually temporary on their side.")
        XCTAssertEqual(texts(en.steps), ["Refresh now.", "Still failing after a day? Report it."])
        XCTAssertEqual(en.steps.map(\.link), [nil, .reportIssue])
        XCTAssertEqual(en.actions, [.refreshNow])
        XCTAssertEqual(en.meta, "Last successful update 12:00\(pm) · last error: server errors")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.body, "Claude renvoie des erreurs depuis 3 heures\(nb); c’est généralement temporaire de son côté.")
        XCTAssertEqual(texts(fr.steps), ["Actualisez maintenant.", "Toujours en échec après un jour\(nb)? Signalez-le."])
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 12:00 · dernière erreur\(nb): erreurs du serveur")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.body, "Claude повертає помилки вже 3 години; зазвичай це тимчасова проблема на їхньому боці.")
        XCTAssertEqual(texts(uk.steps), ["Оновіть зараз.", "Досі не працює через добу? Повідомте про це."])
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 12:00 · остання помилка: помилки сервера")
    }

    // MARK: Banner — no connection

    func testConnection() throws {
        let p = presentation("Client", .chatGPT, age: threeHours, state: .stale(lastError: .offline))

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .connection(lastError: .offline))
        XCTAssertEqual(en.title, "Ration can't refresh this account")
        XCTAssertEqual(en.body, "Ration couldn't reach ChatGPT for 3 hours. Check your internet connection.")
        XCTAssertEqual(en.steps, [])
        XCTAssertEqual(en.actions, [.refreshNow])
        XCTAssertEqual(en.meta, "Last successful update 12:00\(pm) · last error: no connection")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.body, "Ration n’arrive pas à joindre ChatGPT depuis 3 heures. Vérifiez votre connexion Internet.")
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 12:00 · dernière erreur\(nb): pas de connexion")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.body, "Ration не може з’єднатися з ChatGPT вже 3 години. Перевірте з’єднання з інтернетом.")
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 12:00 · остання помилка: немає з’єднання")
    }

    /// While the header reads OFFLINE, every account it counts gets the
    /// connection guidance — a transport failure too, and one that simply
    /// aged out (no error to report).
    func testOfflineHeaderGivesConnectionGuidance() throws {
        let team = presentation("Team", .cursor, age: threeHours, state: .stale(lastError: .transport))
        let work = presentation("Work", .claude, age: threeHours, state: .current)
        let all = [team, work]

        let transport = try XCTUnwrap(AttentionGuidance.make(presentation: team, among: all, now: now, locale: L10n.en, timeZone: utc))
        XCTAssertEqual(transport.cause, .connection(lastError: .transport))
        XCTAssertEqual(transport.body, "Ration couldn't reach Cursor for 3 hours. Check your internet connection.")
        XCTAssertEqual(transport.actions, [.refreshNow])
        XCTAssertEqual(transport.meta, "Last successful update 12:00\(pm) · last error: page didn't load")

        let aged = try XCTUnwrap(AttentionGuidance.make(presentation: work, among: all, now: now, locale: L10n.en, timeZone: utc))
        XCTAssertEqual(aged.cause, .connection(lastError: nil))
        XCTAssertEqual(aged.meta, "Last successful update 12:00\(pm)")
    }

    func testCauseShortTexts() {
        XCTAssertEqual(AttentionCause.serverErrors.shortText(locale: L10n.en), "server errors")
        XCTAssertEqual(AttentionCause.serverErrors.shortText(locale: L10n.fr), "erreurs du serveur")
        XCTAssertEqual(AttentionCause.serverErrors.shortText(locale: L10n.uk), "помилки сервера")
        XCTAssertEqual(AttentionCause.connection(lastError: nil).shortText(locale: L10n.en), "no connection")
    }

    // MARK: Banner — aged out

    func testAgedOut() throws {
        let p = presentation("Personal", .claude, age: threeHours + 25 * 60, state: .current)

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .agedOut)
        XCTAssertEqual(en.title, "Ration can't refresh this account")
        XCTAssertEqual(en.body, "Ration couldn't refresh for 3 hours.")
        XCTAssertEqual(en.steps, [])
        XCTAssertEqual(en.actions, [.refreshNow])
        XCTAssertEqual(en.meta, "Last successful update 11:35\(pm.replacingOccurrences(of: "PM", with: "AM"))")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.body, "Ration n’a pas pu actualiser depuis 3 heures.")
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 11:35")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.body, "Ration не вдається оновити дані вже 3 години.")
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 11:35")
    }

    /// Past a day the age reads in days and hours, and the last update
    /// carries its date.
    func testAgedOutAcrossDays() throws {
        let p = presentation("Personal", .claude, age: 26 * 3600 + 10 * 60, state: .loading)
        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.body, "Ration couldn't refresh for 1 day, 2 hours.")
        XCTAssertEqual(en.meta, "Last successful update Sep 25 at 12:50\(pm)")
        XCTAssertEqual(try guidance(p, L10n.fr).body, "Ration n’a pas pu actualiser depuis 1 jour et 2 heures.")
        XCTAssertEqual(try guidance(p, L10n.uk).body, "Ration не вдається оновити дані вже 1 день 2 години.")
    }

    // MARK: Banner — rate limited

    func testRateLimited() throws {
        let p = presentation("Client", .chatGPT, age: tenMinutes, state: .rateLimited(retryAt: now.addingTimeInterval(40 * 60)))

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .rateLimited(retryAt: now.addingTimeInterval(40 * 60)))
        XCTAssertEqual(en.title, "Ration is waiting to refresh this account")
        XCTAssertEqual(en.body, "ChatGPT asked Ration to slow down. It retries by itself at 3:40\(pm).")
        XCTAssertEqual(en.steps, [])
        XCTAssertEqual(en.actions, [])
        XCTAssertEqual(en.meta, "Last successful update 2:50\(pm) · last error: rate limited")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.title, "Ration attend avant d’actualiser ce compte")
        XCTAssertEqual(fr.body, "ChatGPT a demandé à Ration de ralentir. Ration réessaiera de lui-même à 15:40.")
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 14:50 · dernière erreur\(nb): fréquence limitée")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.title, "Ration чекає, щоб оновити цей обліковий запис")
        XCTAssertEqual(uk.body, "ChatGPT попросив Ration сповільнитися. Ration сам повторить спробу о 15:40.")
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 14:50 · остання помилка: частоту обмежено")
    }

    func testRateLimitedWithoutRetryTime() throws {
        let p = presentation("Client", .chatGPT, age: tenMinutes, state: .rateLimited(retryAt: nil))
        XCTAssertEqual(try guidance(p, L10n.en).body, "ChatGPT asked Ration to slow down. It retries by itself.")
        XCTAssertEqual(try guidance(p, L10n.fr).body, "ChatGPT a demandé à Ration de ralentir. Ration réessaiera de lui-même.")
        XCTAssertEqual(try guidance(p, L10n.uk).body, "ChatGPT попросив Ration сповільнитися. Ration сам повторить спробу.")
    }

    // MARK: Banner — the provider changed its page

    func testIntegrationChanged() throws {
        let p = presentation("Work", .claude, age: tenMinutes, state: .integrationChanged)

        let en = try guidance(p, L10n.en)
        XCTAssertEqual(en.cause, .integrationChanged)
        XCTAssertEqual(en.title, "Ration can't read this account")
        XCTAssertEqual(en.body, "Claude changed its page; Ration needs an update.")
        XCTAssertEqual(en.actions, [.checkForUpdates, .reportIssue])
        XCTAssertEqual(en.meta, "Last successful update 2:50\(pm) · last error: page changed")

        let fr = try guidance(p, L10n.fr)
        XCTAssertEqual(fr.title, "Ration ne peut pas lire ce compte")
        XCTAssertEqual(fr.body, "Claude a modifié sa page\(nb); Ration doit être mis à jour.")
        XCTAssertEqual(fr.meta, "Dernière mise à jour réussie\(nb): 14:50 · dernière erreur\(nb): page modifiée")

        let uk = try guidance(p, L10n.uk)
        XCTAssertEqual(uk.title, "Ration не може прочитати цей обліковий запис")
        XCTAssertEqual(uk.body, "Claude змінив свою сторінку; Ration потрібно оновити.")
        XCTAssertEqual(uk.meta, "Останнє успішне оновлення: 14:50 · остання помилка: сторінку змінено")
    }

    // MARK: Banner — buttons

    func testActionTitles() {
        XCTAssertEqual(AttentionGuidance.Action.signInAgain.title(locale: L10n.en), "Sign in again")
        XCTAssertEqual(AttentionGuidance.Action.signInAgain.title(locale: L10n.fr), "Se reconnecter")
        XCTAssertEqual(AttentionGuidance.Action.signInAgain.title(locale: L10n.uk), "Увійти знову")
        XCTAssertEqual(AttentionGuidance.Action.refreshNow.title(locale: L10n.en), "Refresh now")
        XCTAssertEqual(AttentionGuidance.Action.refreshNow.title(locale: L10n.fr), "Actualiser maintenant")
        XCTAssertEqual(AttentionGuidance.Action.refreshNow.title(locale: L10n.uk), "Оновити зараз")
        XCTAssertEqual(AttentionGuidance.Action.checkForUpdates.title(locale: L10n.en), "Check for updates")
        XCTAssertEqual(AttentionGuidance.Action.checkForUpdates.title(locale: L10n.fr), "Rechercher des mises à jour")
        XCTAssertEqual(AttentionGuidance.Action.checkForUpdates.title(locale: L10n.uk), "Перевірити оновлення")
        XCTAssertEqual(AttentionGuidance.Action.reportIssue.title(locale: L10n.en), "Report it")
        XCTAssertEqual(AttentionGuidance.Action.reportIssue.title(locale: L10n.fr), "Signaler")
        XCTAssertEqual(AttentionGuidance.Action.reportIssue.title(locale: L10n.uk), "Повідомити")
    }

    // MARK: Hover card

    private func help(_ presentations: [AccountPresentation], _ locale: Locale) throws -> FreshnessHelp {
        try XCTUnwrap(FreshnessHelp.make(presentations: presentations, now: now, locale: locale))
    }

    func testHoverCardOneAccount() throws {
        let team = presentation("Team", .cursor, age: threeHours, state: .stale(lastError: .transport))
        let work = presentation("Work", .claude, age: tenMinutes, state: .current)
        let accounts = [work, team]

        let en = try help(accounts, L10n.en)
        XCTAssertEqual(en.title, "1 account isn't up to date")
        XCTAssertEqual(en.lines, ["Team (Cursor): page didn't load, 3h ago"])
        XCTAssertEqual(en.hint, "Click to see what to do.")
        XCTAssertEqual(en.target, .account(team.id))
        XCTAssertEqual(en.spokenText, "1 account isn't up to date\nTeam (Cursor): page didn't load, 3h ago\nClick to see what to do.")

        let fr = try help(accounts, L10n.fr)
        XCTAssertEqual(fr.title, "1 compte n’est pas à jour")
        XCTAssertEqual(fr.lines, ["Team (Cursor)\(nb): la page ne s’est pas chargée, il y a 3\(nb)h"])
        XCTAssertEqual(fr.hint, "Cliquez pour voir quoi faire.")

        let uk = try help(accounts, L10n.uk)
        XCTAssertEqual(uk.title, "1 обліковий запис не оновлюється")
        XCTAssertEqual(uk.lines, ["Team (Cursor): сторінка не завантажилася, 3\(nb)год тому"])
        XCTAssertEqual(uk.hint, "Натисніть, щоб дізнатися, що робити.")
    }

    /// Most actionable first: the sign-in comes before the aged-out account
    /// listed ahead of it, and the click goes to it.
    func testHoverCardTwoAccounts() throws {
        let personal = presentation("Personal", .claude, age: threeHours, state: .current)
        let client = presentation("Client", .chatGPT, age: tenMinutes, state: .reauthenticationRequired)
        let accounts = [personal, client]

        let en = try help(accounts, L10n.en)
        XCTAssertEqual(en.title, "2 accounts aren't up to date")
        XCTAssertEqual(en.lines, [
            "Client (ChatGPT): sign-in expired, 10m ago",
            "Personal (Claude): couldn't refresh, 3h ago",
        ])
        XCTAssertEqual(en.target, .account(client.id))

        let fr = try help(accounts, L10n.fr)
        XCTAssertEqual(fr.title, "2 comptes ne sont pas à jour")
        XCTAssertEqual(fr.lines, [
            "Client (ChatGPT)\(nb): connexion expirée, il y a 10\(nb)min",
            "Personal (Claude)\(nb): actualisation impossible, il y a 3\(nb)h",
        ])

        let uk = try help(accounts, L10n.uk)
        XCTAssertEqual(uk.title, "2 облікові записи не оновлюються")
        XCTAssertEqual(uk.lines, [
            "Client (ChatGPT): термін входу минув, 10\(nb)хв тому",
            "Personal (Claude): не вдалося оновити, 3\(nb)год тому",
        ])
    }

    /// Four lines at most, then "and N more".
    func testHoverCardFiveAccounts() throws {
        let accounts = (1...5).map { presentation("A\($0)", .claude, age: tenMinutes, state: .reauthenticationRequired) }

        let en = try help(accounts, L10n.en)
        XCTAssertEqual(en.title, "5 accounts aren't up to date")
        XCTAssertEqual(en.lines, [
            "A1 (Claude): sign-in expired, 10m ago",
            "A2 (Claude): sign-in expired, 10m ago",
            "A3 (Claude): sign-in expired, 10m ago",
            "A4 (Claude): sign-in expired, 10m ago",
            "and 1 more",
        ])
        XCTAssertEqual(en.target, .account(accounts[0].id))

        let fr = try help(accounts, L10n.fr)
        XCTAssertEqual(fr.title, "5 comptes ne sont pas à jour")
        XCTAssertEqual(fr.lines.last, "et 1 autre")

        let uk = try help(accounts, L10n.uk)
        XCTAssertEqual(uk.title, "5 облікових записів не оновлюються")
        XCTAssertEqual(uk.lines.count, 5)
        XCTAssertEqual(uk.lines.last, "і ще 1")
    }

    func testHoverCardMoreIsPlural() {
        XCTAssertEqual(LocalizedStringResource.freshnessHelpMore(2).string(in: L10n.en), "and 2 more")
        XCTAssertEqual(LocalizedStringResource.freshnessHelpMore(2).string(in: L10n.fr), "et 2 autres")
        for count in L10n.ukrainianCounts {
            XCTAssertEqual(LocalizedStringResource.freshnessHelpMore(count).string(in: L10n.uk), "і ще \(count)")
        }
        XCTAssertEqual(LocalizedStringResource.freshnessHelpTitle(21).string(in: L10n.uk), "21 обліковий запис не оновлюється")
        XCTAssertEqual(LocalizedStringResource.freshnessHelpTitle(22).string(in: L10n.uk), "22 облікові записи не оновлюються")
        XCTAssertEqual(LocalizedStringResource.freshnessHelpTitle(25).string(in: L10n.uk), "25 облікових записів не оновлюються")
    }

    /// An account that never loaded has no age to report.
    func testHoverCardLineWithoutAge() throws {
        let client = presentation("Client", .chatGPT, age: nil, state: .unavailable)
        XCTAssertEqual(try help([client], L10n.en).lines, ["Client (ChatGPT): page didn't load"])
        XCTAssertEqual(try help([client], L10n.fr).lines, ["Client (ChatGPT)\(nb): la page ne s’est pas chargée"])
        XCTAssertEqual(try help([client], L10n.uk).lines, ["Client (ChatGPT): сторінка не завантажилася"])
    }

    func testHoverCardOffline() throws {
        let accounts = [
            presentation("Work", .claude, age: threeHours, state: .current),
            presentation("Client", .chatGPT, age: threeHours, state: .stale(lastError: .offline)),
        ]

        let en = try help(accounts, L10n.en)
        XCTAssertEqual(en.title, "No account could refresh. Check your internet connection.")
        XCTAssertEqual(en.lines, [])
        XCTAssertEqual(en.hint, "Click to refresh.")
        XCTAssertEqual(en.target, .refreshAll)

        let fr = try help(accounts, L10n.fr)
        XCTAssertEqual(fr.title, "Aucun compte n’a pu être actualisé. Vérifiez votre connexion Internet.")
        XCTAssertEqual(fr.hint, "Cliquez pour actualiser.")

        let uk = try help(accounts, L10n.uk)
        XCTAssertEqual(uk.title, "Жоден обліковий запис не вдалося оновити. Перевірте з’єднання з інтернетом.")
        XCTAssertEqual(uk.hint, "Натисніть, щоб оновити.")
    }
}
