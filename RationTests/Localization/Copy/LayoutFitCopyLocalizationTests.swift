import XCTest
@testable import Ration

/// The shorter drawn forms that French and Ukrainian use where the full copy
/// clipped at the minimum window sizes (Task 8 snapshots). English draws the
/// same text as before; the full forms stay in tooltips and VoiceOver.
@MainActor
final class LayoutFitCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFocusHeroDrawsTheCompactLimitsLine() {
        let limits = [
            FocusModel.Limit(kind: .weekly, label: nil, headroom: 0.85),
            FocusModel.Limit(kind: .modelWeekly, label: "Fable", headroom: 0.6),
        ]
        let resetsAt = now.addingTimeInterval(12 * 3600 + 29 * 60)
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            // Same reset text and names; only the per-limit form differs.
            XCTAssertEqual(
                FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, compact: true, locale: locale)
                    .components(separatedBy: " · ").count,
                3
            )
        }
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, compact: true, locale: L10n.en),
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, locale: L10n.en),
            "English draws the full line"
        )
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, compact: true, locale: L10n.fr),
            "réinitialisation dans 12\(nb)h 29\(nb)min · semaine\(nb): 85\(nb)% · Fable\(nb): 60\(nb)%"
        )
        XCTAssertEqual(
            FocusModel.limitsLine(resetsAt: resetsAt, limits: limits, now: now, compact: true, locale: L10n.uk),
            "скидання через 12\(nb)год 29\(nb)хв · тиждень: 85% · Fable: 60%"
        )
    }

    func testHeaderDismissButtonIsOneShortWord() {
        XCTAssertEqual(LocalizedStringResource.headerDismissAlerts.string(in: L10n.en), "Dismiss Alerts")
        XCTAssertEqual(LocalizedStringResource.headerDismissAlerts.string(in: L10n.fr), "Masquer")
        XCTAssertEqual(LocalizedStringResource.headerDismissAlerts.string(in: L10n.uk), "Приховати")
    }

    func testHistoryModeSegments() {
        XCTAssertEqual(LocalizedStringResource.historyModePatterns.string(in: L10n.en), "Patterns")
        XCTAssertEqual(LocalizedStringResource.historyModeBillingCycle.string(in: L10n.en), "Billing cycle")
        XCTAssertEqual(LocalizedStringResource.historyModePatterns.string(in: L10n.fr), "Tendances")
        XCTAssertEqual(LocalizedStringResource.historyModeBillingCycle.string(in: L10n.fr), "Facturation")
        XCTAssertEqual(LocalizedStringResource.historyModePatterns.string(in: L10n.uk), "Тенденції")
        XCTAssertEqual(LocalizedStringResource.historyModeBillingCycle.string(in: L10n.uk), "Цикл оплати")
    }

    /// VoiceOver names each segment with the same words the segment draws:
    /// the drawn title may only shorten the spoken name ("Facturation" of
    /// "Cycle de facturation"), never use a different word for it, so a
    /// sighted helper and a VoiceOver user name the control the same way.
    func testHistoryModeSpokenNamesUseTheDrawnWords() {
        let segments: [(drawn: LocalizedStringResource, spokenKey: String)] = [
            (.historyModePatterns, "Patterns"),
            (.historyModeBillingCycle, "Billing cycle"),
        ]
        for locale in [L10n.en, L10n.fr, L10n.uk] {
            for segment in segments {
                let drawn: String = segment.drawn.string(in: locale)
                let spokenResource = LocalizedStringResource(String.LocalizationValue(segment.spokenKey))
                let spoken: String = spokenResource.string(in: locale)
                XCTAssertTrue(
                    spoken.localizedCaseInsensitiveContains(drawn),
                    "\(locale.identifier): VoiceOver says “\(spoken)”, the segment shows “\(drawn)”"
                )
            }
        }
    }

    /// The drop's fallback when the full countdown does not fit its column.
    func testLeadingUnitCountdown() {
        func leading(_ seconds: TimeInterval, _ locale: Locale) -> String {
            UsageFormatters.remainingUntilResetLeadingUnit(now.addingTimeInterval(seconds), relativeTo: now, locale: locale)
        }
        XCTAssertEqual(leading(12 * 3600 + 30 * 60, L10n.fr), "12\(nb)h")
        XCTAssertEqual(leading(3 * 86_400 + 4 * 3600, L10n.fr), "3\(nb)j")
        XCTAssertEqual(leading(-5, L10n.fr), "0\(nb)min")
        XCTAssertEqual(leading(2 * 3600 + 5 * 60, L10n.uk), "2\(nb)год")
        XCTAssertEqual(leading(22 * 60, L10n.uk), "22\(nb)хв")
        XCTAssertEqual(leading(12 * 3600 + 30 * 60, L10n.en), "12h")
    }

    /// The Cursor spend field keeps its 70 pt in English and grows by the
    /// extra width of a longer "off".
    func testSpendFieldWidth() {
        XCTAssertEqual(CursorSpendFieldLayout.width(locale: L10n.en), 70)
        XCTAssertGreaterThan(CursorSpendFieldLayout.width(locale: L10n.fr), 70)
        XCTAssertGreaterThan(CursorSpendFieldLayout.width(locale: L10n.uk), 70)
    }
}
