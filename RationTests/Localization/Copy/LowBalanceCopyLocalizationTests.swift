import XCTest
@testable import Ration

/// TypeSafe's low-balance alert and the Add API Account sheet's
/// provider step, in every shipped language.
final class LowBalanceCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let event = AlertEvent.lowBalance(LowBalanceAlert(balance: Money(minorUnits: 412, currency: "USD", exponent: 2)!, thresholdCents: 500))

    func testTheNotification() {
        let en = AlertMessage.text(for: event, accountLabel: "Lab", locale: L10n.en)
        XCTAssertEqual(en.title, "Lab: balance low")
        XCTAssertEqual(en.body, "$4.12 left on Lab, below your $5.00 alert. API calls stop when the balance runs out.")
        let fr = AlertMessage.text(for: event, accountLabel: "Lab", locale: L10n.fr)
        XCTAssertEqual(fr.title, "Lab\(nb): solde bas")
        XCTAssertEqual(fr.body, "Il reste 4,12\(nb)$US sur Lab, sous votre seuil d’alerte de 5,00\(nb)$US. Les appels d’API s’arrêtent quand le solde est épuisé.")
        let uk = AlertMessage.text(for: event, accountLabel: "Lab", locale: L10n.uk)
        XCTAssertEqual(uk.title, "Lab: низький залишок")
        XCTAssertEqual(uk.body, "В обліковому записі Lab залишилося 4,12\(nb)USD — менше за ваш поріг сповіщення 5,00\(nb)USD. Коли кошти закінчаться, виклики API зупиняться.")
    }

    func testPrivacyMode() {
        XCTAssertEqual(AlertMessage.text(for: event, accountLabel: "Lab", redacted: true, locale: L10n.en).body, "An account's balance is low.")
        XCTAssertEqual(AlertMessage.text(for: event, accountLabel: "Lab", redacted: true, locale: L10n.fr).body, "Le solde d’un compte est bas.")
        XCTAssertEqual(AlertMessage.text(for: event, accountLabel: "Lab", redacted: true, locale: L10n.uk).body, "Залишок коштів облікового запису низький.")
    }

    func testTheDropRow() {
        var row = AttentionRow(
            accountID: UUID(), accountLabel: "Lab", provider: .typeSafe, subject: .lowBalance, tier: .warning,
            usedPercent: nil, spentCents: nil, thresholdPercent: nil, thresholdCents: 500,
            resetsAt: nil, resetCount: nil, resetCreditIDs: []
        )
        row.creditAmount = Money(minorUnits: 412, currency: "USD", exponent: 2)
        XCTAssertEqual(AttentionDropView.subjectLabel(.lowBalance, locale: L10n.en), "BALANCE")
        XCTAssertEqual(AttentionDropView.subjectLabel(.lowBalance, locale: L10n.fr), "SOLDE")
        XCTAssertEqual(AttentionDropView.subjectLabel(.lowBalance, locale: L10n.uk), "ЗАЛИШОК")
        XCTAssertEqual(AttentionDropView.rowAccessibilityLabel(row, now: .now, locale: L10n.en), "Lab, balance $4.12, below your $5.00 alert")
        XCTAssertEqual(AttentionDropView.rowAccessibilityLabel(row, now: .now, locale: L10n.fr), "Lab, solde de 4,12\(nb)$US, sous votre seuil d’alerte de 5,00\(nb)$US")
        XCTAssertTrue(row.isLimitRow, "counted as a warning in the header")
        XCTAssertTrue(row.isAcknowledgedPerRow, "the ✕ acknowledges it until a top-up")
        XCTAssertEqual(AttentionDropView.headerAccessibilityLabel(rows: [row], locale: L10n.en), "Nearing limits, 1 warning")
    }

    func testTheSettingsRow() {
        XCTAssertEqual(LowBalanceAlertsCopy.title(locale: L10n.en), "Low balance")
        XCTAssertEqual(LowBalanceAlertsCopy.title(locale: L10n.fr), "Solde bas")
        XCTAssertEqual(LowBalanceAlertsCopy.title(locale: L10n.uk), "Низький залишок")
        XCTAssertEqual(LowBalanceAlertsCopy.below(locale: L10n.fr), "Sous")
        XCTAssertEqual(LowBalanceAlertsCopy.offPrompt(locale: L10n.uk), "вимк.")
    }

    func testTheAddAPIAccountProviderStep() {
        Provider.switchedOff = []
        defer { Provider.switchedOff = [.typeSafe] }
        XCTAssertEqual(APIAccountChoice.all.map { $0.methodLine(locale: L10n.en) },
                       ["Admin key from the Claude Console", "Admin key from the OpenAI Platform", "Sign in to the console"])
        XCTAssertEqual(APIAccountChoice.all.map { $0.methodLine(locale: L10n.fr) },
                       ["Clé administrateur depuis Claude Console", "Clé administrateur depuis OpenAI Platform", "Connexion à la console"])
        XCTAssertEqual(APIAccountChoice.all.map { $0.methodLine(locale: L10n.uk) },
                       ["Ключ адміністратора з Claude Console", "Ключ адміністратора з OpenAI Platform", "Вхід у консоль"])
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            XCTAssertTrue(AddAPIOrgSheet.signInNote(.typeSafe, locale: locale).contains("TypeSafe"))
        }
    }
}
