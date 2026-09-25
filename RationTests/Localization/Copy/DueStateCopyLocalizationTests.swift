import XCTest
@testable import Ration

/// Every "in <countdown>" wrapper switches to its own due-state entry when the
/// countdown would be the "now" unit (`UsageFormatters.isResetDue`: at or past
/// the reset, and under a second before it — the same flooring). English keeps
/// every language reads naturally: English "resets now" (1.3.0 printed "resets
/// in now"), French "réinitialisation maintenant", Ukrainian "скидання зараз".
@MainActor
final class DueStateCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Past, due this instant, and under a second away: all the due form.
    private let dueOffsets: [TimeInterval] = [-5, 0, 0.5]
    private let future: TimeInterval = 2 * 3600 + 5 * 60

    // MARK: Focus hero / warning line

    func testFocusResetText() {
        for offset in dueOffsets {
            let at = now.addingTimeInterval(offset)
            XCTAssertEqual(FocusModel.resetText(at, now: now, locale: L10n.en), "resets now", "\(offset)")
            XCTAssertEqual(FocusModel.resetText(at, now: now, locale: L10n.fr), "réinitialisation maintenant", "\(offset)")
            XCTAssertEqual(FocusModel.resetText(at, now: now, locale: L10n.uk), "скидання зараз", "\(offset)")
        }
        let later = now.addingTimeInterval(future)
        XCTAssertEqual(FocusModel.resetText(later, now: now, locale: L10n.en), "resets in 2h 5m")
        XCTAssertEqual(FocusModel.resetText(later, now: now, locale: L10n.fr), "réinitialisation dans 2\(nb)h 5\(nb)min")
        XCTAssertEqual(FocusModel.resetText(later, now: now, locale: L10n.uk), "скидання через 2\(nb)год 5\(nb)хв")
    }

    // MARK: Drop, spoken

    private func row(_ subject: AttentionRow.Subject, resets offset: TimeInterval) -> AttentionRow {
        let credit: Bool = if case .resetCredit = subject { true } else { false }
        return AttentionRow(
            accountID: UUID(), accountLabel: "Max", provider: .claude, subject: subject,
            tier: .critical, usedPercent: credit ? nil : 97, spentCents: nil,
            thresholdPercent: credit ? nil : 90, thresholdCents: nil,
            resetsAt: now.addingTimeInterval(offset), resetCount: credit ? 1 : nil,
            resetCreditIDs: credit ? ["c"] : []
        )
    }

    func testDropSpokenResetsIn() {
        for offset in dueOffsets {
            let limit = row(.window(.weekly), resets: offset)
            XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(limit, now: now, locale: L10n.en).hasSuffix(", resets now"))
            XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(limit, now: now, locale: L10n.fr).hasSuffix(", réinitialisation maintenant"))
            XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(limit, now: now, locale: L10n.uk).hasSuffix(", скидання зараз"))
        }
        let later = row(.window(.weekly), resets: future)
        XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(later, now: now, locale: L10n.en).hasSuffix(", resets in 2 hours, 5 minutes"))
        XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(later, now: now, locale: L10n.fr).contains(", réinitialisation dans 2"))
        XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(later, now: now, locale: L10n.uk).contains(", скидання через 2"))
    }

    func testDropSpokenExpiresIn() {
        for offset in dueOffsets {
            let credit = row(.resetCredit(id: "c", kind: .expiring), resets: offset)
            XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(credit, now: now, locale: L10n.en).hasSuffix(", expires now"))
            XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(credit, now: now, locale: L10n.fr).hasSuffix(", expire maintenant"))
            XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(credit, now: now, locale: L10n.uk).hasSuffix(", термін дії спливає зараз"))
        }
        let later = row(.resetCredit(id: "c", kind: .expiring), resets: future)
        XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(later, now: now, locale: L10n.fr).contains(", expire dans 2"))
        XCTAssertTrue(AttentionDropView.rowAccessibilityLabel(later, now: now, locale: L10n.uk).contains(", термін дії спливає через 2"))
    }

    // MARK: Reset-credit card line

    private func credits(count: Int, expires offset: TimeInterval) -> ResetCreditsSummary {
        ResetCreditsSummary(
            totalCount: count, soonestExpiry: now.addingTimeInterval(offset),
            withinLeadWindow: true, noneUsable: false
        )
    }

    func testResetCreditsLineAndSpoken() {
        for offset in dueOffsets {
            let one = credits(count: 1, expires: offset)
            let two = credits(count: 2, expires: offset)
            XCTAssertEqual(one.text(now: now, locale: L10n.en), "↻ 1 reset · expires now")
            XCTAssertEqual(two.text(now: now, locale: L10n.en), "↻ 2 resets · next expires now")
            XCTAssertEqual(one.text(now: now, locale: L10n.fr), "↻ 1 réinitialisation · expire maintenant")
            XCTAssertEqual(two.text(now: now, locale: L10n.fr), "↻ 2 réinitialisations · la prochaine expire maintenant")
            XCTAssertEqual(one.text(now: now, locale: L10n.uk), "↻ 1 скидання · спливає зараз")
            XCTAssertEqual(two.text(now: now, locale: L10n.uk), "↻ 2 скидання · наступне спливає зараз")

            XCTAssertEqual(one.accessibilityText(now: now, locale: L10n.en), "Usage-limit resets: 1, expires now")
            XCTAssertEqual(two.accessibilityText(now: now, locale: L10n.en), "Usage-limit resets: 2, next expires now")
            XCTAssertEqual(one.accessibilityText(now: now, locale: L10n.fr), "Réinitialisations de limite\(nb): 1, expire maintenant")
            XCTAssertEqual(two.accessibilityText(now: now, locale: L10n.uk), "Скидання ліміту: 2, наступне спливає зараз")
        }
        let later = credits(count: 2, expires: 18 * 3600)
        XCTAssertEqual(later.text(now: now, locale: L10n.en), "↻ 2 resets · next expires in 18h")
        XCTAssertEqual(later.text(now: now, locale: L10n.fr), "↻ 2 réinitialisations · la prochaine expire dans 18\(nb)h")
        XCTAssertEqual(later.text(now: now, locale: L10n.uk), "↻ 2 скидання · наступне діє ще 18\(nb)год")
    }

    // MARK: NEXT RESET, spoken

    func testSoonestResetSpoken() {
        for offset in dueOffsets {
            let next = SoonestReset(accountLabel: "Max", kind: .weekly, resetsAt: now.addingTimeInterval(offset), label: nil)
            XCTAssertEqual(next.accessibilityLabel(now: now, locale: L10n.en), "Next reset, Max weekly, now")
            XCTAssertEqual(next.accessibilityLabel(now: now, locale: L10n.fr), "Prochaine réinitialisation\(nb): Max, fenêtre hebdomadaire, maintenant")
            XCTAssertEqual(next.accessibilityLabel(now: now, locale: L10n.uk), "Наступне скидання: Max, тижневе вікно, зараз")
        }
        let later = SoonestReset(accountLabel: "Max", kind: .weekly, resetsAt: now.addingTimeInterval(future), label: nil)
        XCTAssertEqual(later.accessibilityLabel(now: now, locale: L10n.en), "Next reset, Max weekly, in 2 hours, 5 minutes")
        XCTAssertTrue(later.accessibilityLabel(now: now, locale: L10n.fr).contains(", dans 2"))
    }

    // MARK: Cursor spend row (a reset still ahead only)

    func testCursorSpendResetsIn() {
        func spend(_ offset: TimeInterval) -> CursorSpend {
            CursorSpend(spentCents: 1_234, periodStart: nil, resetsAt: now.addingTimeInterval(offset), planLabel: "Pro")
        }
        // Under a second ahead: still a "future" reset, but the countdown is "now".
        let soon = spend(0.5)
        XCTAssertTrue(CursorSpendRow.text(for: soon, now: now, locale: L10n.en).caption.hasSuffix(" · resets now"))
        XCTAssertTrue(CursorSpendRow.text(for: soon, now: now, locale: L10n.fr).caption.hasSuffix(" · réinitialisation maintenant"))
        XCTAssertTrue(CursorSpendRow.text(for: soon, now: now, locale: L10n.uk).caption.hasSuffix(" · скидання зараз"))
        XCTAssertTrue(CursorSpendRow.accessibilityDescription(for: soon, now: now, locale: L10n.en).hasSuffix(", resets now"))
        XCTAssertTrue(CursorSpendRow.accessibilityDescription(for: soon, now: now, locale: L10n.uk).hasSuffix(", скидання зараз"))
        // At or past the reset there is no countdown at all.
        XCTAssertFalse(CursorSpendRow.text(for: spend(-5), now: now, locale: L10n.fr).caption.contains("réinitialisation"))
        let later = spend(future)
        XCTAssertTrue(CursorSpendRow.text(for: later, now: now, locale: L10n.fr).caption.hasSuffix(" · réinitialisation dans 2\(nb)h 5\(nb)min"))
        XCTAssertTrue(CursorSpendRow.accessibilityDescription(for: later, now: now, locale: L10n.uk).contains(", скидання через 2"))
    }

    // MARK: Warm-up hold banner

    private func heldBanner(resetsIn offset: TimeInterval, locale: Locale) -> String? {
        let account = AccountRecord(
            id: UUID(), provider: .claude, label: "AI", webProfileID: UUID(),
            displayOrder: 0, createdAt: .distantPast, autoStartFiveHour: true
        )
        let presentation = AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id, fetchedAt: now,
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
                weekly: UsageWindow(kind: .weekly, remainingFraction: 0, resetsAt: now.addingTimeInterval(offset))
            ),
            state: .current
        )
        return WarmUpBannerModel.banner(
            presentations: [presentation], failures: [:], schedule: .allowAll, now: now, locale: locale
        )?.message
    }

    func testWarmUpBannerResumes() {
        // Under a second ahead: the only due case the banner can reach.
        XCTAssertEqual(heldBanner(resetsIn: 0.5, locale: L10n.en), "Warm-up paused for AI — weekly limit reached; resumes now.")
        XCTAssertEqual(
            heldBanner(resetsIn: 0.5, locale: L10n.fr),
            "Préchauffage en pause pour AI — limite hebdomadaire atteinte\(nb); reprise maintenant."
        )
        XCTAssertEqual(
            heldBanner(resetsIn: 0.5, locale: L10n.uk),
            "Розігрів призупинено для AI — тижневий ліміт вичерпано; відновиться зараз."
        )
        XCTAssertEqual(
            heldBanner(resetsIn: future, locale: L10n.uk),
            "Розігрів призупинено для AI — тижневий ліміт вичерпано; відновиться через 2\(nb)год 5\(nb)хв."
        )
    }
}
