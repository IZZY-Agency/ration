import XCTest
@testable import Ration

/// The account pane's "Recent warm-ups" list in every shipped language.
/// An extension of `SettingsAndErrorCopyLocalizationTests` so the l10n runs
/// (`make l10n-test`) pick it up.
extension SettingsAndErrorCopyLocalizationTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-26 15:00 UTC.
    private var warmUpNow: Date { Date(timeIntervalSince1970: 1_790_434_800) }

    private func time(_ date: Date, _ locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        style.calendar = utc
        style.timeZone = utc.timeZone
        return date.formatted(style)
    }

    /// Every kind the list can show, newest first.
    private var warmUpSamples: [WarmUpOutcome] {
        let today = warmUpNow.addingTimeInterval(-58 * 60)            // 14:02
        let yesterday = warmUpNow.addingTimeInterval(-30 * 3600)     // 09:00, the day before
        return [
            .sent(at: today, status: 200),
            .failure(ClaudeMessageSender.SendError.rejected(status: 429), at: yesterday, reserved: true),
            .rejectedInStream(at: today, status: 200, type: .rateLimit),
            .failure(ClaudeMessageSender.SendError.transport, at: today, reserved: true),
            .failure(WebUsageClientError.timedOut, at: today, reserved: true),
            .failure(ClaudeMessageSender.SendError.organizationNotFound, at: today, reserved: false),
            .failure(ClaudeMessageSender.SendError.modelNotFound, at: today, reserved: false),
            .failure(WebUsageClientError.invalidResponse, at: today, reserved: true),
            .skipped(.weeklyLimitSpent, at: today, reserved: false),
            .skipped(.organizationUnknown, at: today, reserved: false),
            .skipped(.warmUpTurnedOff, at: today, reserved: true),
        ]
    }

    private func warmUpWords(_ locale: Locale) -> [String] {
        warmUpSamples.map { WarmUpOutcomeCopy.what($0, locale: locale) }
    }

    func testWarmUpOutcomeWordsInEnglish() {
        XCTAssertEqual(WarmUpOutcomeCopy.title(locale: L10n.en), "Recent warm-ups")
        XCTAssertEqual(WarmUpOutcomeCopy.empty(locale: L10n.en), "None yet.")
        XCTAssertEqual(warmUpWords(L10n.en), [
            "sent",
            "refused (429)",
            "refused in the reply (rate_limit_error)",
            "couldn’t reach Claude",
            "no answer in time",
            "workspace not found",
            "no model found",
            "failed",
            "held: weekly limit used up",
            "skipped: workspace unknown",
            "skipped: warm-up turned off",
        ])
    }

    func testWarmUpOutcomeWordsInFrench() {
        let nb = L10n.nbsp
        XCTAssertEqual(WarmUpOutcomeCopy.title(locale: L10n.fr), "Préchauffages récents")
        XCTAssertEqual(WarmUpOutcomeCopy.empty(locale: L10n.fr), "Aucun pour l’instant.")
        XCTAssertEqual(warmUpWords(L10n.fr), [
            "envoyé",
            "refusé (429)",
            "refusé dans la réponse (rate_limit_error)",
            "Claude injoignable",
            "pas de réponse à temps",
            "espace de travail introuvable",
            "aucun modèle trouvé",
            "échec",
            "suspendu\(nb): limite hebdomadaire épuisée",
            "ignoré\(nb): espace de travail inconnu",
            "ignoré\(nb): préchauffage désactivé",
        ])
    }

    func testWarmUpOutcomeWordsInUkrainian() {
        XCTAssertEqual(WarmUpOutcomeCopy.title(locale: L10n.uk), "Останні розігріви")
        XCTAssertEqual(WarmUpOutcomeCopy.empty(locale: L10n.uk), "Поки що немає.")
        XCTAssertEqual(warmUpWords(L10n.uk), [
            "надіслано",
            "відхилено (429)",
            "відхилено у відповіді (rate_limit_error)",
            "не вдалося зв’язатися з Claude",
            "відповідь не надійшла вчасно",
            "робочий простір не знайдено",
            "модель не знайдено",
            "не вдалося",
            "відкладено: тижневий ліміт вичерпано",
            "пропущено: робочий простір невідомий",
            "пропущено: розігрів вимкнено",
        ])
    }

    func testWarmUpOutcomeLinesSayTodayAndYesterdayNewestFirst() {
        let today = warmUpNow.addingTimeInterval(-58 * 60)
        let yesterday = warmUpNow.addingTimeInterval(-30 * 3600)
        let older = warmUpNow.addingTimeInterval(-3 * 86_400)
        let ring: [WarmUpOutcome] = [
            .sent(at: older, status: 200),
            .failure(ClaudeMessageSender.SendError.rejected(status: 429), at: yesterday, reserved: true),
            .sent(at: today, status: 200),
        ]
        let expected: [Locale: (String, String, String, String)] = [
            L10n.en: ("Today", "Yesterday", "sent", "refused (429)"),
            L10n.fr: ("Aujourd’hui", "Hier", "envoyé", "refusé (429)"),
            L10n.uk: ("Сьогодні", "Учора", "надіслано", "відхилено (429)"),
        ]
        for (locale, words) in expected {
            let lines = WarmUpOutcomeCopy.lines(ring, now: warmUpNow, locale: locale, calendar: utc)
            XCTAssertEqual(lines.count, 3)
            XCTAssertEqual(lines[0], "\(words.0) \(time(today, locale)) · \(words.2)", "\(locale)")
            XCTAssertEqual(lines[1], "\(words.1) \(time(yesterday, locale)) · \(words.3)", "\(locale)")
            // Older than yesterday: the date itself, no day word.
            XCTAssertFalse(lines[2].hasPrefix(words.0), "\(locale)")
            XCTAssertFalse(lines[2].hasPrefix(words.1), "\(locale)")
            XCTAssertTrue(lines[2].hasSuffix(" · \(words.2)"), "\(locale)")
        }
        XCTAssertEqual(time(today, L10n.fr), "14:02")
    }
}
