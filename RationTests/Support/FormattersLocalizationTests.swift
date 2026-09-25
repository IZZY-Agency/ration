import XCTest
@testable import Ration

/// The compact countdowns and percents in every shipped language. Each call
/// passes its locale, so these hold whatever language the run is pinned to;
/// `testDefaultLocaleFollowsThePinnedLanguage` is the one that checks the
/// `.current` default against `make unit-test` / `make l10n-test`.
final class FormattersLocalizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private let en = Locale(identifier: "en_US")
    private let fr = Locale(identifier: "fr_FR")
    private let uk = Locale(identifier: "uk_UA")

    private static let nbsp = "\u{00A0}"
    private static let narrowNbsp = "\u{202F}"

    private func remaining(_ seconds: TimeInterval, _ locale: Locale) -> String {
        UsageFormatters.remainingUntilReset(now.addingTimeInterval(seconds), relativeTo: now, locale: locale)
    }

    private func credit(_ seconds: TimeInterval, _ locale: Locale) -> String {
        UsageFormatters.resetCreditRemaining(now.addingTimeInterval(seconds), relativeTo: now, locale: locale)
    }

    // MARK: remainingUntilReset

    func testRemainingUntilResetEnglish() {
        XCTAssertEqual(remaining(-30, en), "now")
        XCTAssertEqual(remaining(0, en), "now")
        XCTAssertEqual(remaining(0.5, en), "now")
        XCTAssertEqual(remaining(22 * 60, en), "22m")
        XCTAssertEqual(remaining(3600, en), "1h")
        XCTAssertEqual(remaining(2 * 3600 + 5 * 60, en), "2h 5m")
        XCTAssertEqual(remaining(24 * 3600, en), "1d")
        XCTAssertEqual(remaining(3 * 24 * 3600 + 4 * 3600, en), "3d 4h")
    }

    func testRemainingUntilResetFrench() {
        XCTAssertEqual(remaining(-30, fr), "maintenant")
        XCTAssertEqual(remaining(0, fr), "maintenant")
        XCTAssertEqual(remaining(0.5, fr), "maintenant")
        XCTAssertEqual(remaining(22 * 60, fr), "22\(Self.nbsp)min")
        XCTAssertEqual(remaining(3600, fr), "1\(Self.nbsp)h")
        XCTAssertEqual(remaining(2 * 3600 + 5 * 60, fr), "2\(Self.nbsp)h 5\(Self.nbsp)min")
        XCTAssertEqual(remaining(24 * 3600, fr), "1\(Self.nbsp)j")
        XCTAssertEqual(remaining(3 * 24 * 3600 + 4 * 3600, fr), "3\(Self.nbsp)j 4\(Self.nbsp)h")
    }

    func testRemainingUntilResetUkrainian() {
        XCTAssertEqual(remaining(-30, uk), "зараз")
        XCTAssertEqual(remaining(0, uk), "зараз")
        XCTAssertEqual(remaining(0.5, uk), "зараз")
        XCTAssertEqual(remaining(22 * 60, uk), "22\(Self.nbsp)хв")
        XCTAssertEqual(remaining(3600, uk), "1\(Self.nbsp)год")
        XCTAssertEqual(remaining(2 * 3600 + 5 * 60, uk), "2\(Self.nbsp)год 5\(Self.nbsp)хв")
        XCTAssertEqual(remaining(24 * 3600, uk), "1\(Self.nbsp)д")
        XCTAssertEqual(remaining(3 * 24 * 3600 + 4 * 3600, uk), "3\(Self.nbsp)д 4\(Self.nbsp)год")
    }

    /// A bare language code resolves the same as a regional one.
    func testRemainingUntilResetBareLanguageCodes() {
        XCTAssertEqual(remaining(2 * 3600 + 5 * 60, Locale(identifier: "fr")), "2\(Self.nbsp)h 5\(Self.nbsp)min")
        XCTAssertEqual(remaining(2 * 3600 + 5 * 60, Locale(identifier: "uk")), "2\(Self.nbsp)год 5\(Self.nbsp)хв")
        XCTAssertEqual(remaining(2 * 3600 + 5 * 60, Locale(identifier: "en")), "2h 5m")
    }

    // MARK: resetCreditRemaining

    func testResetCreditRemainingEnglish() {
        XCTAssertEqual(credit(-30, en), "now")
        XCTAssertEqual(credit(0, en), "now")
        XCTAssertEqual(credit(30 * 60, en), "<1h")
        XCTAssertEqual(credit(3600, en), "1h")
        XCTAssertEqual(credit(23 * 3600 + 59 * 60, en), "23h")
        XCTAssertEqual(credit(24 * 3600, en), "1d")
        XCTAssertEqual(credit(29 * 24 * 3600 + 7 * 3600, en), "29d")
    }

    func testResetCreditRemainingFrench() {
        XCTAssertEqual(credit(-30, fr), "maintenant")
        XCTAssertEqual(credit(0, fr), "maintenant")
        XCTAssertEqual(credit(30 * 60, fr), "<1\(Self.nbsp)h")
        XCTAssertEqual(credit(3600, fr), "1\(Self.nbsp)h")
        XCTAssertEqual(credit(23 * 3600 + 59 * 60, fr), "23\(Self.nbsp)h")
        XCTAssertEqual(credit(24 * 3600, fr), "1\(Self.nbsp)j")
        XCTAssertEqual(credit(29 * 24 * 3600 + 7 * 3600, fr), "29\(Self.nbsp)j")
    }

    func testResetCreditRemainingUkrainian() {
        XCTAssertEqual(credit(-30, uk), "зараз")
        XCTAssertEqual(credit(0, uk), "зараз")
        XCTAssertEqual(credit(30 * 60, uk), "<1\(Self.nbsp)год")
        XCTAssertEqual(credit(3600, uk), "1\(Self.nbsp)год")
        XCTAssertEqual(credit(23 * 3600 + 59 * 60, uk), "23\(Self.nbsp)год")
        XCTAssertEqual(credit(24 * 3600, uk), "1\(Self.nbsp)д")
        XCTAssertEqual(credit(29 * 24 * 3600 + 7 * 3600, uk), "29\(Self.nbsp)д")
    }

    // MARK: isResetDue (R2: callers branch on the state, never on the text)

    func testIsResetDueUsesTheCountdownsFlooring() {
        XCTAssertTrue(UsageFormatters.isResetDue(now.addingTimeInterval(-30), relativeTo: now), "expired")
        XCTAssertTrue(UsageFormatters.isResetDue(now, relativeTo: now), "equal")
        XCTAssertTrue(UsageFormatters.isResetDue(now.addingTimeInterval(0.5), relativeTo: now), "+0.5 s floors to 0")
        XCTAssertFalse(UsageFormatters.isResetDue(now.addingTimeInterval(1), relativeTo: now), "+1 s")
        XCTAssertFalse(UsageFormatters.isResetDue(now.addingTimeInterval(3600), relativeTo: now), "future")
    }

    /// In every language, "due" is exactly when both countdowns draw their
    /// "now" word — the state and the text never disagree.
    func testIsResetDueAgreesWithTheDrawnNowInEveryLanguage() {
        let nowWords: [(Locale, String)] = [(en, "now"), (fr, "maintenant"), (uk, "зараз")]
        for (locale, word) in nowWords {
            for seconds in [-30.0, 0, 0.5, 1, 59, 3600] {
                let due = UsageFormatters.isResetDue(now.addingTimeInterval(seconds), relativeTo: now)
                let id = locale.identifier
                XCTAssertEqual(remaining(seconds, locale) == word, due, "\(id) countdown at \(seconds) s")
                XCTAssertEqual(credit(seconds, locale) == word, due, "\(id) credit at \(seconds) s")
            }
        }
    }

    /// French `many` (1 000 000 and the like) resolves to the `other` text.
    func testFrenchManyPluralReadsLikeOther() {
        let million: String = LocalizedStringResource.unitHoursSpoken(1_000_000).string(in: fr)
        XCTAssertTrue(million.hasSuffix(" heures"), million)
        XCTAssertTrue(million.hasPrefix("1"), million)
    }

    // MARK: percents

    /// Prose (VoiceOver labels): the locale's rules, with French typography's
    /// narrow no-break space before `%` whichever space the OS's data uses.
    func testUsedPercentageFollowsTheLocale() {
        XCTAssertEqual(UsageFormatters.usedPercentage(0.85, locale: en), "85%")
        XCTAssertEqual(UsageFormatters.usedPercentage(0.85, locale: fr), "85\(Self.narrowNbsp)%")
        XCTAssertEqual(UsageFormatters.usedPercentage(0.85, locale: uk), "85%")
    }

    /// Drawn percents (Space Mono has no U+202F): a plain no-break space in
    /// French, nothing in English and Ukrainian.
    func testCompactUsedPercentageUsesAFullNoBreakSpaceInFrench() {
        XCTAssertEqual(UsageFormatters.compactUsedPercentage(0.85, locale: en), "85%")
        XCTAssertEqual(UsageFormatters.compactUsedPercentage(0.85, locale: fr), "85\(Self.nbsp)%")
        XCTAssertEqual(UsageFormatters.compactUsedPercentage(0.85, locale: uk), "85%")
        XCTAssertEqual(UsageFormatters.compactUsedPercentage(0.004, locale: fr), "0\(Self.nbsp)%")
    }

    func testCompactPercentOfAWholeNumber() {
        XCTAssertEqual(UsageFormatters.compactPercent(3, locale: en), "3%")
        XCTAssertEqual(UsageFormatters.compactPercent(3, locale: fr), "3\(Self.nbsp)%")
        XCTAssertEqual(UsageFormatters.compactPercent(3, locale: uk), "3%")
        // Never grouped: "1234%", not "1,234%".
        XCTAssertEqual(UsageFormatters.compactPercent(1234, locale: en), "1234%")
        XCTAssertEqual(UsageFormatters.compactPercent(100, locale: fr), "100\(Self.nbsp)%")
    }

    /// English in a European region (the `en_150` family) must draw 1.3.0's
    /// "85%", not the region's "85 %": every whole-percent helper that
    /// Focus and the drop draw goes through the app language alone.
    func testWholePercentsIgnoreTheRegionInEnglish() {
        let europeanEnglish: [Locale] = [Locale(identifier: "en_DE"), Locale(identifier: "en_SE")]
        for locale in europeanEnglish {
            let id: String = locale.identifier
            XCTAssertEqual(UsageFormatters.compactPercent(85, locale: locale), "85%", id)
            XCTAssertEqual(UsageFormatters.compactPercent(1234, locale: locale), "1234%", id)
            XCTAssertEqual(UsageFormatters.wholePercent(85, monospaced: true, locale: locale), "85%", id)
            XCTAssertEqual(UsageFormatters.wholePercent(85, monospaced: false, locale: locale), "85%", id)
            XCTAssertEqual(FocusModel.percentText(0.85, locale: locale), "85%", id)
            XCTAssertEqual(FocusModel.lineRight(headroom: 0.25, resetsAt: nil, now: now, locale: locale), "25% left", id)
            XCTAssertEqual(
                FocusModel.warningText(label: "Client", headroom: 0.01, kind: .weekly, windowLabel: nil, locale: locale),
                "Client · 1% of the week left", id
            )
            let limits: [FocusModel.Limit] = [FocusModel.Limit(kind: .weekly, label: nil, headroom: 0.85)]
            XCTAssertEqual(
                FocusModel.limitsLine(resetsAt: now.addingTimeInterval(27 * 60), limits: limits, now: now, locale: locale),
                "resets in 27m · week 85% left", id
            )
        }
    }

    func testFocusPercentTextKeepsItsRoundingAndLocalizes() {
        XCTAssertEqual(FocusModel.percentText(0.125, locale: en), "13%")
        XCTAssertEqual(FocusModel.percentText(0.03, locale: fr), "3\(Self.nbsp)%")
        XCTAssertEqual(FocusModel.percentText(0.03, locale: uk), "3%")
    }

    // MARK: the `.current` default

    /// The default locale follows the run's pinned language: `make unit-test`
    /// draws English, `make l10n-test L10N_LANG=fr|uk` French or Ukrainian.
    func testDefaultLocaleFollowsThePinnedLanguage() throws {
        let code = try PinnedTestLanguage.require()
        let expected: [String: (String, String, String, String, String)] = [
            "en": ("2h 5m", "<1h", "85%", "85%", "3%"),
            "fr": ("2\(Self.nbsp)h 5\(Self.nbsp)min", "<1\(Self.nbsp)h", "85\(Self.nbsp)%", "85\(Self.narrowNbsp)%", "3\(Self.nbsp)%"),
            "uk": ("2\(Self.nbsp)год 5\(Self.nbsp)хв", "<1\(Self.nbsp)год", "85%", "85%", "3%"),
        ]
        let language = Locale.Language(identifier: code).languageCode?.identifier ?? code
        guard let (countdown, underHour, percent, prosePercent, wholePercent) = expected[language] else {
            throw XCTSkip("no expectations for pinned language \(code)")
        }
        let reset = now.addingTimeInterval(2 * 3600 + 5 * 60)
        XCTAssertEqual(UsageFormatters.remainingUntilReset(reset, relativeTo: now), countdown)
        XCTAssertEqual(UsageFormatters.resetCreditRemaining(now.addingTimeInterval(60), relativeTo: now), underHour)
        XCTAssertEqual(UsageFormatters.compactUsedPercentage(0.85), percent)
        XCTAssertEqual(UsageFormatters.usedPercentage(0.85), prosePercent)
        XCTAssertEqual(UsageFormatters.compactPercent(3), wholePercent)
    }
}
