import XCTest
@testable import Ration

/// Switch advice in every shipped language: header (one catalog entry per
/// binding, uppercase in the catalog, never uppercased at runtime), its
/// split for colouring, the spoken header, the notification line and its
/// redacted form, and the drop's spoken suffix.
final class SwitchAdviceCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let nn = L10n.nnbsp

    private func advice(
        _ provider: Provider = .claude,
        to label: String = "Personal",
        headroom: Double = 0.85,
        binding: UsageWindowKind = .weekly
    ) -> SwitchAdvice {
        SwitchAdvice(
            provider: provider, fromAccountID: UUID(), fromLabel: "Client",
            toAccountID: UUID(), toLabel: label, toHeadroom: headroom, toBinding: binding
        )
    }

    // MARK: Header

    func testHeaderTextEnglishWithExplicitLocale() {
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(), locale: L10n.en),
            "→ SWITCH CLAUDE TO Personal · 85% OF WEEK LEFT"
        )
    }

    func testHeaderTextFrench() {
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(), locale: L10n.fr),
            "→ CLAUDE\(nb): PASSER À Personal · IL RESTE 85\(nb)% DE LA SEMAINE"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(binding: .fiveHour), locale: L10n.fr),
            "→ CLAUDE\(nb): PASSER À Personal · IL RESTE 85\(nb)% DES 5\(nb)HEURES"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(.chatGPT, to: "Work 20x", binding: .modelWeekly), locale: L10n.fr),
            "→ CHATGPT\(nb): PASSER À Work 20x · IL RESTE 85\(nb)% DE FABLE"
        )
    }

    func testHeaderTextUkrainian() {
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(), locale: L10n.uk),
            "→ CLAUDE: ПЕРЕЙТИ НА Personal · ЗАЛИШИЛОСЯ 85% ТИЖНЯ"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(binding: .fiveHour), locale: L10n.uk),
            "→ CLAUDE: ПЕРЕЙТИ НА Personal · ЗАЛИШИЛОСЯ 85% З 5 ГОДИН"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(binding: .modelWeekly), locale: L10n.uk),
            "→ CLAUDE: ПЕРЕЙТИ НА Personal · ЗАЛИШИЛОСЯ 85% FABLE"
        )
    }

    /// The label is a placeholder: it is never uppercased, whatever the language.
    func testHeaderKeepsTheAccountLabelAsTyped() {
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            XCTAssertTrue(
                SwitchAdviceCopy.headerText(advice(to: "bob@acme.com"), locale: locale).contains("bob@acme.com"),
                locale.identifier
            )
        }
    }

    func testHeaderPartsSplitAroundTheTargetInEveryLanguage() {
        let fr = SwitchAdviceCopy.headerParts(advice(), locale: L10n.fr)
        XCTAssertEqual(fr.lead, "CLAUDE\(nb): PASSER À")
        XCTAssertEqual(fr.target, "Personal")
        XCTAssertEqual(fr.tail, "· IL RESTE 85\(nb)% DE LA SEMAINE")

        let uk = SwitchAdviceCopy.headerParts(advice(), locale: L10n.uk)
        XCTAssertEqual(uk.lead, "CLAUDE: ПЕРЕЙТИ НА")
        XCTAssertEqual(uk.target, "Personal")
        XCTAssertEqual(uk.tail, "· ЗАЛИШИЛОСЯ 85% ТИЖНЯ")

        let en = SwitchAdviceCopy.headerParts(advice(), locale: L10n.en)
        XCTAssertEqual(en.lead, "SWITCH CLAUDE TO")
        XCTAssertEqual(en.tail, "· 85% OF WEEK LEFT")
    }

    // MARK: Spoken header

    func testSpokenHeaderFrench() {
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(), locale: L10n.fr),
            "Claude\(nb): passer à Personal, il reste 85 pour cent de la semaine"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(binding: .fiveHour), locale: L10n.fr),
            "Claude\(nb): passer à Personal, il reste 85 pour cent des 5 heures"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(binding: .modelWeekly), locale: L10n.fr),
            "Claude\(nb): passer à Personal, il reste 85 pour cent de Fable"
        )
    }

    func testSpokenHeaderUkrainianPlurals() {
        let expected: [Int: String] = [
            1: "1 відсоток", 2: "2 відсотки", 5: "5 відсотків",
            21: "21 відсоток", 22: "22 відсотки", 25: "25 відсотків",
        ]
        for (percent, phrase) in expected {
            XCTAssertEqual(
                SwitchAdviceCopy.spokenHeader(advice(headroom: Double(percent) / 100), locale: L10n.uk),
                "Claude: перейти на Personal, залишилося \(phrase) тижня",
                "\(percent)"
            )
        }
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(binding: .fiveHour), locale: L10n.uk),
            "Claude: перейти на Personal, залишилося 85 відсотків з 5 годин"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(binding: .modelWeekly), locale: L10n.uk),
            "Claude: перейти на Personal, залишилося 85 відсотків Fable"
        )
    }

    func testSpokenHeaderEnglishSingularPercentIsUnchanged() {
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(headroom: 0.01), locale: L10n.en),
            "Switch Claude to Personal, 1 percent of the week left"
        )
    }

    // MARK: Notification line

    func testNotificationLineFrench() {
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(), redacted: false, locale: L10n.fr),
            "Passez à Personal — il lui reste 85\(nn)% de sa semaine."
        )
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(binding: .fiveHour), redacted: false, locale: L10n.fr),
            "Passez à Personal — il lui reste 85\(nn)% de ses 5 heures."
        )
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(binding: .modelWeekly), redacted: false, locale: L10n.fr),
            "Passez à Personal — il lui reste 85\(nn)% de Fable."
        )
    }

    func testNotificationLineUkrainian() {
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(), redacted: false, locale: L10n.uk),
            "Перейдіть на Personal — там залишилося 85% тижня."
        )
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(binding: .fiveHour), redacted: false, locale: L10n.uk),
            "Перейдіть на Personal — там залишилося 85% з 5 годин."
        )
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(binding: .modelWeekly), redacted: false, locale: L10n.uk),
            "Перейдіть на Personal — там залишилося 85% Fable."
        )
    }

    func testRedactedNotificationLineIsLocalizedAndCarriesNoLabelOrNumber() {
        let fr = SwitchAdviceCopy.notificationLine(advice(to: "bob@acme.com"), redacted: true, locale: L10n.fr)
        XCTAssertEqual(fr, "Un autre compte Claude a plus de marge.")
        let uk = SwitchAdviceCopy.notificationLine(advice(.chatGPT, to: "bob@acme.com"), redacted: true, locale: L10n.uk)
        XCTAssertEqual(uk, "Інший обліковий запис ChatGPT має більший запас.")
        for line in [fr, uk] {
            XCTAssertFalse(line.contains("bob@acme.com"))
            XCTAssertFalse(line.contains("Client"))
            XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits))
        }
    }

    // MARK: Drop

    func testDropSpokenSuffix() {
        XCTAssertEqual(SwitchAdviceCopy.dropSpokenSuffix(advice(), locale: L10n.en), ", switch to Personal")
        XCTAssertEqual(SwitchAdviceCopy.dropSpokenSuffix(advice(), locale: L10n.fr), ", passer à Personal")
        XCTAssertEqual(SwitchAdviceCopy.dropSpokenSuffix(advice(), locale: L10n.uk), ", перейти на Personal")
    }
}
