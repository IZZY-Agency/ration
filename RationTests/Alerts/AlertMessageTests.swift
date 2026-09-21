import XCTest
@testable import Ration

final class AlertMessageTests: XCTestCase {
    private let accountID = UUID()
    private let label = "Claude (Work)"

    private var allEvents: [AlertEvent] {
        [
            .threshold(kind: .fiveHour, tier: .warning, percent: 75),
            .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            .threshold(kind: .weekly, tier: .warning, percent: 75),
            .threshold(kind: .weekly, tier: .critical, percent: 90),
            .threshold(kind: .modelWeekly, tier: .warning, percent: 75),
            .threshold(kind: .modelWeekly, tier: .critical, percent: 90),
            .reset(kind: .fiveHour),
            .reset(kind: .weekly),
            .reset(kind: .modelWeekly),
            .reauthRequired,
            .rateLimited,
            // Cursor's spend ladder. Both tiers, and a threshold/spend pair
            // that is NOT a round dollar amount so the fraction-digit branch
            // of the currency formatting is exercised by every property test
            // below (notably the redaction invariant, which has to keep the
            // one event carrying a dollar figure from leaking it).
            .spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_250),
            .spendThreshold(tier: .critical, thresholdCents: 10_000, spentCents: 10_075),
        ]
    }

    // MARK: - text(for:accountLabel:)

    func testTextIsNonEmptyAndIncludesAccountLabelForEveryEvent() {
        for event in allEvents {
            let (title, body) = AlertMessage.text(for: event, accountLabel: label)
            XCTAssertFalse(title.isEmpty, "title empty for \(event)")
            XCTAssertFalse(body.isEmpty, "body empty for \(event)")
            XCTAssertTrue(
                title.contains(label) || body.contains(label),
                "account label missing from text for \(event)"
            )
        }
    }

    func testRedactedTextOmitsLabelAndExactUsageForEveryEvent() {
        // A label that could be an email/employer, and the exact percentages.
        let sensitive = "bob@acme.com"
        for event in allEvents {
            let (title, body) = AlertMessage.text(
                for: event,
                accountLabel: sensitive,
                redacted: true
            )
            XCTAssertFalse(title.isEmpty, "title empty for \(event)")
            XCTAssertFalse(body.isEmpty, "body empty for \(event)")
            XCTAssertFalse(
                title.contains(sensitive) || body.contains(sensitive),
                "redacted copy leaked the account label for \(event)"
            )
            XCTAssertFalse(
                title.contains("75%") || body.contains("75%")
                    || title.contains("90%") || body.contains("90%"),
                "redacted copy leaked an exact percentage for \(event)"
            )
            // The spend events carry money, not a percentage — the exact
            // figure is just as identifying, so it must not survive redaction
            // either. Asserted for EVERY event, not just the spend ones, so a
            // future event that starts quoting an amount is caught here too.
            XCTAssertFalse(
                title.contains("$") || body.contains("$"),
                "redacted copy leaked a dollar figure for \(event)"
            )
            // The general form of both checks above, and the one that does not
            // depend on the reader's locale: no redacted string quotes a
            // FIGURE of any kind. "US$52,50" defeats a `contains("$52.50")`
            // check but not this one.
            XCTAssertNil(
                (title + body).rangeOfCharacter(from: .decimalDigits),
                "redacted copy leaked a figure for \(event)"
            )
        }
    }

    func testFiveHourCriticalWording() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountLabel: label
        )
        XCTAssertEqual(title, "\(label): 5h limit at 90%")
        XCTAssertTrue(body.contains("90%"))
        XCTAssertTrue(body.contains(label))
    }

    func testFiveHourWarningWording() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .fiveHour, tier: .warning, percent: 75),
            accountLabel: label
        )
        XCTAssertEqual(title, "\(label): 5h limit at 75%")
        XCTAssertTrue(body.contains("75%"))
        XCTAssertTrue(body.contains(label))
    }

    func testWeeklyCriticalWording() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .weekly, tier: .critical, percent: 90),
            accountLabel: label
        )
        XCTAssertEqual(title, "\(label): weekly limit at 90%")
        XCTAssertTrue(body.contains("90%"))
        XCTAssertTrue(body.contains(label))
    }

    func testWeeklyWarningWording() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .weekly, tier: .warning, percent: 75),
            accountLabel: label
        )
        XCTAssertEqual(title, "\(label): weekly limit at 75%")
        XCTAssertTrue(body.contains("75%"))
        XCTAssertTrue(body.contains(label))
    }

    func testFiveHourResetWording() {
        let (title, body) = AlertMessage.text(for: .reset(kind: .fiveHour), accountLabel: label)
        XCTAssertEqual(title, "\(label): 5h limit reset")
        XCTAssertTrue(body.contains(label))
    }

    func testWeeklyResetWording() {
        let (title, body) = AlertMessage.text(for: .reset(kind: .weekly), accountLabel: label)
        XCTAssertEqual(title, "\(label): weekly limit reset")
        XCTAssertEqual(body, "Fresh weekly capacity is available for \(label).")
    }

    // MARK: - modelWeekly (Fable) API label

    /// A `.modelWeekly` threshold event carrying the window's API
    /// label ("Fable") must use that label in the notification text instead
    /// of the generic static kind wording ("model"/"model weekly").
    func testModelWeeklyAlertUsesApiLabel() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .modelWeekly, tier: .critical, percent: 90, label: "Fable"),
            accountLabel: label
        )
        XCTAssertTrue(title.contains("Fable"), "title should use the API label: \(title)")
        XCTAssertTrue(body.contains("Fable"), "body should use the API label: \(body)")
        XCTAssertFalse(title.contains("model"), "title should not fall back to the generic wording: \(title)")
        XCTAssertFalse(body.contains("model "), "body should not fall back to the generic wording: \(body)")
    }

    /// Without an API label (e.g. the field was absent), `.modelWeekly` falls
    /// back to "Fable" rather than the generic "model"/"model weekly" wording.
    func testModelWeeklyAlertFallsBackToFableWithoutApiLabel() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .modelWeekly, tier: .warning, percent: 75, label: nil),
            accountLabel: label
        )
        XCTAssertTrue(title.contains("Fable"))
        XCTAssertTrue(body.contains("Fable"))
    }

    /// 5h/weekly messages must stay byte-identical to before this task: their
    /// events never carry a label, so the static "5-hour"/"weekly" wording
    /// must still be used verbatim.
    func testFiveHourAndWeeklyWordingUnaffectedByLabelThread() {
        let (fhTitle, fhBody) = AlertMessage.text(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountLabel: label
        )
        XCTAssertEqual(fhTitle, "\(label): 5h limit at 90%")
        XCTAssertTrue(fhBody.contains("5-hour"))

        let (wkTitle, wkBody) = AlertMessage.text(for: .reset(kind: .weekly), accountLabel: label)
        XCTAssertEqual(wkTitle, "\(label): weekly limit reset")
        XCTAssertTrue(wkBody.contains("weekly"))
    }

    func testReauthRequiredWording() {
        let (title, body) = AlertMessage.text(for: .reauthRequired, accountLabel: label)
        XCTAssertEqual(title, "\(label): sign in again")
        XCTAssertTrue(body.contains(label))
    }

    func testRateLimitedWording() {
        let (title, body) = AlertMessage.text(for: .rateLimited, accountLabel: label)
        XCTAssertEqual(title, "\(label): rate-limited")
        XCTAssertTrue(body.contains(label))
    }

    // MARK: - Cursor spend copy

    func testSpendCopyStatesBothTheThresholdAndTheAmountSpent() {
        // Round amounts so the integer part is unambiguous in any locale that
        // uses Western digits; the symbol form is asserted separately below.
        let (title, body) = AlertMessage.text(
            for: .spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 7_500),
            accountLabel: label
        )
        XCTAssertTrue(title.contains(label), "spend title dropped the account label")
        XCTAssertTrue(title.contains("50"), "spend title omitted the configured threshold: \(title)")
        XCTAssertTrue(body.contains("75"), "spend body omitted the amount spent: \(body)")
        XCTAssertTrue(body.contains("50"), "spend body omitted the configured threshold: \(body)")
    }

    func testSpendCopyQuotesTheConfiguredThresholdNotTheTierRawValue() {
        // `AlertTier`'s raw values (75/90) are persistence tokens, not
        // percentages, and spend has no percentage at all — a $30 threshold
        // must read as $30 and must not pick up "75" from the warning tier.
        let (title, body) = AlertMessage.text(
            for: .spendThreshold(tier: .warning, thresholdCents: 3_000, spentCents: 3_100),
            accountLabel: label
        )
        XCTAssertTrue(title.contains("30"), "spend title omitted the $30 threshold: \(title)")
        XCTAssertFalse(title.contains("75"), "spend title leaked the tier raw value: \(title)")
        XCTAssertFalse(body.contains("75"), "spend body leaked the tier raw value: \(body)")
        XCTAssertFalse(body.contains("%"), "spend copy invented a percentage: \(body)")
    }

    /// `AlertPolicy` fires the spend ladder on `>=`, so the exact-boundary
    /// case is reachable and must not claim the user is "past" a threshold
    /// they have only just reached.
    func testSpendCopySaysReachedAtTheExactThresholdAndPastOnlyAboveIt() {
        let (atTitle, atBody) = AlertMessage.text(
            for: .spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_000),
            accountLabel: label
        )
        XCTAssertFalse(atTitle.contains("past"), "spent exactly the threshold is not past it: \(atTitle)")
        XCTAssertFalse(atBody.contains("past"), "spent exactly the threshold is not past it: \(atBody)")
        XCTAssertTrue(atTitle.contains("reached"), "expected 'reached' at the boundary: \(atTitle)")

        let (overTitle, _) = AlertMessage.text(
            for: .spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 5_001),
            accountLabel: label
        )
        XCTAssertTrue(overTitle.contains("past"), "one cent over the threshold is past it: \(overTitle)")
    }

    // MARK: - dollars(_:locale:)

    func testDollarsDropsFractionOnlyForWholeDollarAmounts() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(AlertMessage.dollars(5_000, locale: us), "$50")
        XCTAssertEqual(AlertMessage.dollars(5_250, locale: us), "$52.50")
        XCTAssertEqual(AlertMessage.dollars(10_075, locale: us), "$100.75")
        // A whole-dollar amount whose cents are zero but value is not round in
        // hundreds — still no fraction.
        XCTAssertEqual(AlertMessage.dollars(1_00, locale: us), "$1")
    }

    func testDollarsFollowsTheReadersLocaleButAlwaysBillsInUSD() {
        // Cursor bills in dollars regardless of where the reader is, so the
        // currency is pinned to USD while symbol placement and the decimal
        // separator follow the locale. This is why copy assertions elsewhere
        // must not pattern-match a bare "$50".
        // Note the NON-BREAKING space (U+00A0) before the symbol — a plain
        // " $US" literal does not match. Concrete proof of why copy assertions
        // must not pattern-match formatted currency.
        XCTAssertEqual(
            AlertMessage.dollars(5_250, locale: Locale(identifier: "fr_FR")),
            "52,50\u{00A0}$US"
        )
        XCTAssertEqual(AlertMessage.dollars(5_000, locale: Locale(identifier: "en_FR")), "US$50")
    }

    // MARK: - id(for:accountID:)

    func testIDsDifferAcrossEventKindsAndTiers() {
        let ids = allEvents.map { AlertMessage.id(for: $0, accountID: accountID) }
        XCTAssertEqual(ids.count, Set(ids).count, "expected all ids distinct, got \(ids)")
    }

    func testIDIsStableForSameEvent() {
        let event = AlertEvent.threshold(kind: .fiveHour, tier: .critical, percent: 90)
        let id1 = AlertMessage.id(for: event, accountID: accountID)
        let id2 = AlertMessage.id(for: event, accountID: accountID)
        XCTAssertEqual(id1, id2)
    }

    func testIDContainsAccountID() {
        for event in allEvents {
            let id = AlertMessage.id(for: event, accountID: accountID)
            XCTAssertTrue(id.contains(accountID.uuidString), "id missing account id for \(event)")
        }
    }

    func testIDsDifferAcrossDifferentAccountsForSameEvent() {
        let otherAccountID = UUID()
        let event = AlertEvent.reauthRequired
        let id1 = AlertMessage.id(for: event, accountID: accountID)
        let id2 = AlertMessage.id(for: event, accountID: otherAccountID)
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Configured percent, not the tier's raw value

    func testThresholdCopyUsesConfiguredPercentNotTierRawValue() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .weekly, tier: .warning, percent: 60),
            accountLabel: "work"
        )
        XCTAssertTrue(title.contains("60%"), title)
        XCTAssertTrue(body.contains("60%"), body)
        XCTAssertFalse(title.contains("75%"), title)
    }

    // Identifiers must stay tier-keyed: if they embedded the percentage, every
    // threshold edit would mint a new notification identity and the OS would
    // stop coalescing repeats of the same logical alert.
    func testThresholdIdentifierIgnoresConfiguredPercent() {
        let accountID = UUID()
        let a = AlertMessage.id(
            for: .threshold(kind: .weekly, tier: .warning, percent: 60),
            accountID: accountID
        )
        let b = AlertMessage.id(
            for: .threshold(kind: .weekly, tier: .warning, percent: 80),
            accountID: accountID
        )
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".threshold.weekly.warning"))
    }

    func testRedactedThresholdCopyOmitsPercent() {
        let (title, body) = AlertMessage.text(
            for: .threshold(kind: .weekly, tier: .warning, percent: 60),
            accountLabel: "work@example.com",
            redacted: true
        )
        XCTAssertFalse(title.contains("60"), title)
        XCTAssertFalse(body.contains("60"), body)
        XCTAssertFalse(body.contains("work@example.com"), body)
    }
}
