import XCTest
@testable import Ration

/// Notification copy in every shipped language. The copy is composed when a
/// notification is posted (`AppModel` calls `AlertMessage.text` at post
/// time), so the same event reads in whatever language the app runs in;
/// these tests compose one event in fr and uk with explicit locales.
final class AlertMessageLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let nn = L10n.nnbsp
    private let label = "Work"
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(_ event: AlertEvent, _ locale: Locale, redacted: Bool = false, advice: SwitchAdvice? = nil) -> (title: String, body: String) {
        AlertMessage.text(for: event, accountLabel: label, redacted: redacted, advice: advice, locale: locale)
    }

    private func credit(count: Int = 1, title: String? = nil) -> ResetCredit {
        ResetCredit(id: "c1", title: title, count: count, expiresAt: expiry, usableNow: true)
    }

    // MARK: Thresholds

    func testThresholdFrench() {
        let fiveHour = text(.threshold(kind: .fiveHour, tier: .warning, percent: 75), L10n.fr)
        XCTAssertEqual(fiveHour.title, "Work\(nb): limite de 5\(nb)h à 75\(nn)%")
        XCTAssertEqual(fiveHour.body, "Vous avez utilisé 75\(nn)% de la limite de 5 heures pour Work.")
        let weekly = text(.threshold(kind: .weekly, tier: .critical, percent: 90), L10n.fr)
        XCTAssertEqual(weekly.title, "Work\(nb): limite hebdomadaire à 90\(nn)%")
        XCTAssertEqual(weekly.body, "Vous avez utilisé 90\(nn)% de la limite hebdomadaire pour Work.")
        let model = text(.threshold(kind: .modelWeekly, tier: .warning, percent: 75, label: "Fable"), L10n.fr)
        XCTAssertEqual(model.title, "Work\(nb): limite Fable à 75\(nn)%")
        XCTAssertEqual(model.body, "Vous avez utilisé 75\(nn)% de la limite Fable pour Work.")
    }

    func testThresholdUkrainian() {
        let fiveHour = text(.threshold(kind: .fiveHour, tier: .warning, percent: 75), L10n.uk)
        XCTAssertEqual(fiveHour.title, "Work: 5-годинний ліміт — 75%")
        XCTAssertEqual(fiveHour.body, "Ви використали 75% 5-годинного ліміту для Work.")
        let weekly = text(.threshold(kind: .weekly, tier: .critical, percent: 90), L10n.uk)
        XCTAssertEqual(weekly.title, "Work: тижневий ліміт — 90%")
        XCTAssertEqual(weekly.body, "Ви використали 90% тижневого ліміту для Work.")
        let model = text(.threshold(kind: .modelWeekly, tier: .warning, percent: 75), L10n.uk)
        XCTAssertEqual(model.title, "Work: ліміт Fable — 75%")
        XCTAssertEqual(model.body, "Ви використали 75% ліміту Fable для Work.")
    }

    func testThresholdWithSwitchAdviceAppendsTheLocalizedLine() {
        let advice = SwitchAdvice(
            provider: .claude, fromAccountID: UUID(), fromLabel: label,
            toAccountID: UUID(), toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
        let event = AlertEvent.threshold(kind: .weekly, tier: .critical, percent: 90)
        XCTAssertEqual(
            text(event, L10n.fr, advice: advice).body,
            "Vous avez utilisé 90\(nn)% de la limite hebdomadaire pour Work.\nPassez à Personal — il lui reste 85\(nn)% de sa semaine."
        )
        XCTAssertEqual(
            text(event, L10n.uk, redacted: true, advice: advice).body,
            "Обліковий запис наближається до ліміту використання.\nІнший обліковий запис Claude має більший запас."
        )
    }

    // MARK: Reset, reauth, rate limit

    func testResetReauthRateLimitedFrench() {
        let reset = text(.reset(kind: .fiveHour), L10n.fr)
        XCTAssertEqual(reset.title, "Work\(nb): limite de 5\(nb)h réinitialisée")
        XCTAssertEqual(reset.body, "Une nouvelle capacité de 5 heures est disponible pour Work.")
        XCTAssertEqual(text(.reset(kind: .weekly), L10n.fr).title, "Work\(nb): limite hebdomadaire réinitialisée")
        XCTAssertEqual(text(.reset(kind: .weekly), L10n.fr).body, "Une nouvelle capacité hebdomadaire est disponible pour Work.")
        let model = text(.reset(kind: .modelWeekly, label: "Fable"), L10n.fr)
        XCTAssertEqual(model.title, "Work\(nb): limite Fable réinitialisée")
        XCTAssertEqual(model.body, "Une nouvelle capacité Fable est disponible pour Work.")

        let reauth = text(.reauthRequired, L10n.fr)
        XCTAssertEqual(reauth.title, "Work\(nb): reconnectez-vous")
        XCTAssertEqual(reauth.body, "Ration ne peut pas lire les limites de Work tant que vous ne vous reconnectez pas.")
        let rate = text(.rateLimited, L10n.fr)
        XCTAssertEqual(rate.title, "Work\(nb): requêtes limitées")
        XCTAssertEqual(rate.body, "Le fournisseur limite la fréquence des vérifications d’utilisation pour Work.")
    }

    func testResetReauthRateLimitedUkrainian() {
        let reset = text(.reset(kind: .fiveHour), L10n.uk)
        XCTAssertEqual(reset.title, "Work: 5-годинний ліміт скинуто")
        XCTAssertEqual(reset.body, "Для Work знову доступний повний 5-годинний ліміт.")
        XCTAssertEqual(text(.reset(kind: .weekly), L10n.uk).title, "Work: тижневий ліміт скинуто")
        XCTAssertEqual(text(.reset(kind: .weekly), L10n.uk).body, "Для Work знову доступний повний тижневий ліміт.")
        let model = text(.reset(kind: .modelWeekly, label: "Fable"), L10n.uk)
        XCTAssertEqual(model.title, "Work: ліміт Fable скинуто")
        XCTAssertEqual(model.body, "Для Work знову доступний повний ліміт Fable.")

        let reauth = text(.reauthRequired, L10n.uk)
        XCTAssertEqual(reauth.title, "Work: увійдіть знову")
        XCTAssertEqual(reauth.body, "Ration не може прочитати ліміти Work, доки ви не ввійдете знову.")
        let rate = text(.rateLimited, L10n.uk)
        XCTAssertEqual(rate.title, "Work: обмеження запитів")
        XCTAssertEqual(rate.body, "Постачальник обмежує частоту перевірок використання для Work.")
    }

    // MARK: Cursor spend

    func testSpendFrenchAndUkrainianUseTheLocaleCurrencyFormat() {
        for locale in [L10n.fr, L10n.uk] {
            let limit = AlertMessage.dollars(5_000, locale: locale)
            let spent = AlertMessage.dollars(5_250, locale: locale)
            let past = text(.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_250), locale)
            let reached = text(.spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_000), locale)
            if locale == L10n.fr {
                XCTAssertEqual(past.title, "Work\(nb): dépenses Cursor au-delà de \(limit)")
                XCTAssertEqual(past.body, "Work a dépensé \(spent) sur ce cycle de facturation, au-delà de votre alerte à \(limit).")
                XCTAssertEqual(reached.title, "Work\(nb): seuil de dépenses Cursor de \(limit) atteint")
                XCTAssertEqual(reached.body, "Work a dépensé \(limit) sur ce cycle de facturation et atteint votre alerte à \(limit).")
            } else {
                XCTAssertEqual(past.title, "Work: витрати Cursor перевищили \(limit)")
                XCTAssertEqual(past.body, "Work: витрачено \(spent) за цей платіжний цикл — понад поріг сповіщення \(limit).")
                XCTAssertEqual(reached.title, "Work: витрати Cursor досягли \(limit)")
                XCTAssertEqual(reached.body, "Work: витрачено \(limit) за цей платіжний цикл — досягнуто порогу сповіщення \(limit).")
            }
        }
    }

    // MARK: Usage-limit resets

    func testResetCreditAvailableFrench() {
        let when = AlertMessage.expiryText(expiry, locale: L10n.fr)
        let single = text(.resetCreditAvailable(credit: credit(), expiringSoon: false), L10n.fr)
        XCTAssertEqual(single.title, "Work\(nb): réinitialisation disponible")
        XCTAssertEqual(single.body, "Une réinitialisation de limite est disponible pour Work jusqu’au \(when).")
        let soon = text(.resetCreditAvailable(credit: credit(title: "Weekly reset"), expiringSoon: true), L10n.fr)
        XCTAssertEqual(soon.title, "Work\(nb): réinitialisation disponible — expire bientôt")
        XCTAssertEqual(soon.body, "«\(nb)Weekly reset\(nb)» est disponible pour Work jusqu’au \(when).")
        let many = text(.resetCreditAvailable(credit: credit(count: 3), expiringSoon: false), L10n.fr)
        XCTAssertEqual(many.title, "Work\(nb): 3 réinitialisations disponibles")
        XCTAssertEqual(many.body, "3 réinitialisations de limite sont disponibles pour Work jusqu’au \(when).")
        let manySoon = text(.resetCreditAvailable(credit: credit(count: 2), expiringSoon: true), L10n.fr)
        XCTAssertEqual(manySoon.title, "Work\(nb): 2 réinitialisations disponibles — expire bientôt")
    }

    func testResetCreditAvailableUkrainianPlurals() {
        let when = AlertMessage.expiryText(expiry, locale: L10n.uk)
        let single = text(.resetCreditAvailable(credit: credit(), expiringSoon: false), L10n.uk)
        XCTAssertEqual(single.title, "Work: доступне скидання")
        XCTAssertEqual(single.body, "Для Work доступне скидання ліміту до \(when).")
        XCTAssertEqual(
            text(.resetCreditAvailable(credit: credit(title: "Weekly reset"), expiringSoon: true), L10n.uk).title,
            "Work: доступне скидання — термін дії скоро спливає"
        )
        XCTAssertEqual(
            text(.resetCreditAvailable(credit: credit(title: "Weekly reset"), expiringSoon: false), L10n.uk).body,
            "«Weekly reset» доступне для Work до \(when)."
        )
        let nouns: [Int: String] = [2: "скидання", 5: "скидань", 21: "скидання", 22: "скидання", 25: "скидань"]
        for (count, noun) in nouns {
            let event = AlertEvent.resetCreditAvailable(credit: credit(count: count), expiringSoon: false)
            XCTAssertEqual(text(event, L10n.uk).title, "Work: доступно \(count) \(noun)", "\(count)")
            XCTAssertEqual(text(event, L10n.uk).body, "Для Work до \(when) доступно \(count) \(noun) ліміту.", "\(count)")
            let soon = AlertEvent.resetCreditAvailable(credit: credit(count: count), expiringSoon: true)
            XCTAssertEqual(text(soon, L10n.uk).title, "Work: доступно \(count) \(noun) — термін дії скоро спливає", "\(count)")
        }
    }

    func testResetCreditExpiringFrench() {
        let when = AlertMessage.expiryText(expiry, locale: L10n.fr)
        let single = text(.resetCreditExpiring(credit: credit()), L10n.fr)
        XCTAssertEqual(single.title, "Work\(nb): réinitialisation expirant bientôt")
        XCTAssertEqual(single.body, "Une réinitialisation de limite pour Work expire le \(when). Utilisez-la avant, sinon elle sera perdue.")
        XCTAssertEqual(
            text(.resetCreditExpiring(credit: credit(title: "Weekly reset")), L10n.fr).body,
            "«\(nb)Weekly reset\(nb)» pour Work expire le \(when). Utilisez cette réinitialisation avant, sinon elle sera perdue."
        )
        XCTAssertEqual(
            text(.resetCreditExpiring(credit: credit(count: 2)), L10n.fr).body,
            "2 réinitialisations de limite expirent pour Work le \(when). Utilisez-les avant, sinon elles seront perdues."
        )
    }

    func testResetCreditExpiringUkrainianPlurals() {
        let when = AlertMessage.expiryText(expiry, locale: L10n.uk)
        XCTAssertEqual(text(.resetCreditExpiring(credit: credit()), L10n.uk).title, "Work: термін дії скидання скоро спливає")
        XCTAssertEqual(
            text(.resetCreditExpiring(credit: credit()), L10n.uk).body,
            "Скидання ліміту для Work діє до \(when). Використайте його раніше, інакше його буде втрачено."
        )
        XCTAssertEqual(
            text(.resetCreditExpiring(credit: credit(title: "Weekly reset")), L10n.uk).body,
            "«Weekly reset» для Work діє до \(when). Використайте скидання раніше, інакше його буде втрачено."
        )
        let phrases: [Int: String] = [
            2: "2 скидання ліміту діють", 5: "5 скидань ліміту діє",
            21: "21 скидання ліміту діє", 22: "22 скидання ліміту діють",
            25: "25 скидань ліміту діє",
        ]
        for (count, phrase) in phrases {
            XCTAssertEqual(
                text(.resetCreditExpiring(credit: credit(count: count)), L10n.uk).body,
                "\(phrase) для Work до \(when). Використайте їх раніше, інакше їх буде втрачено.",
                "\(count)"
            )
        }
    }

    // MARK: Redacted

    func testRedactedCopyIsLocalizedAndCarriesNoLabelOrNumber() {
        let events: [AlertEvent] = [
            .threshold(kind: .weekly, tier: .warning, percent: 75), .reset(kind: .weekly),
            .reauthRequired, .rateLimited,
            .spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_250),
            .resetCreditAvailable(credit: credit(count: 3), expiringSoon: true),
            .resetCreditExpiring(credit: credit(count: 3)),
        ]
        let fr = [
            "Un compte approche d’une limite d’utilisation.", "La limite d’un compte a été réinitialisée.",
            "Un compte vous demande de vous reconnecter.", "Les requêtes d’un compte sont limitées.",
            "Un compte approche d’une limite de dépenses.", "Un compte dispose d’une réinitialisation de limite.",
            "La réinitialisation de limite d’un compte expire bientôt.",
        ]
        let uk = [
            "Обліковий запис наближається до ліміту використання.", "Ліміт облікового запису скинуто.",
            "Обліковий запис просить вас увійти знову.", "Для облікового запису діє обмеження запитів.",
            "Обліковий запис наближається до ліміту витрат.", "Для облікового запису доступне скидання ліміту.",
            "Термін дії скидання ліміту облікового запису скоро спливає.",
        ]
        for (index, event) in events.enumerated() {
            for (locale, expected) in [(L10n.fr, fr[index]), (L10n.uk, uk[index])] {
                let copy = text(event, locale, redacted: true)
                XCTAssertEqual(copy.title, "Ration")
                XCTAssertEqual(copy.body, expected)
                XCTAssertFalse(copy.body.contains(label))
                XCTAssertNil(copy.body.rangeOfCharacter(from: .decimalDigits))
            }
        }
    }

    // MARK: Composition

    /// The same event composes each language's text; its identifier (what the
    /// notification centre dedupes on) is language-independent.
    func testOneEventComposesEachLanguageAndKeepsOneIdentifier() {
        let event = AlertEvent.threshold(kind: .weekly, tier: .critical, percent: 90)
        let titles = [L10n.en, L10n.fr, L10n.uk].map { text(event, $0).title }
        XCTAssertEqual(titles, [
            "Work: weekly limit at 90%",
            "Work\(nb): limite hebdomadaire à 90\(nn)%",
            "Work: тижневий ліміт — 90%",
        ])
        let accountID = UUID()
        XCTAssertEqual(AlertMessage.id(for: event, accountID: accountID), "\(accountID.uuidString).threshold.weekly.critical")
    }

    /// Without a locale the copy follows the running language: French in
    /// `make l10n-test L10N_LANG=fr`, Ukrainian under uk, English otherwise.
    func testDefaultLocaleIsTheRunningLanguage() {
        let event = AlertEvent.reauthRequired
        let composed = AlertMessage.text(for: event, accountLabel: label)
        switch Locale.current.language.languageCode {
        case .french?: XCTAssertEqual(composed.title, "Work\(nb): reconnectez-vous")
        case .ukrainian?: XCTAssertEqual(composed.title, "Work: увійдіть знову")
        default: XCTAssertEqual(composed.title, "Work: sign in again")
        }
    }
}
