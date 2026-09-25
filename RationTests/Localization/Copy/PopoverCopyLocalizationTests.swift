import XCTest
@testable import Ration

/// The popover, Focus, drop and status-item copy built in code, plus the view
/// literals SwiftUI resolves itself, in every shipped language.
@MainActor
final class PopoverCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let nnb = L10n.nnbsp
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func presentation(
        _ label: String = "Work",
        _ provider: Provider = .claude,
        snapshot: UsageSnapshot? = nil
    ) -> AccountPresentation {
        let record = AccountRecord(
            id: UUID(), provider: provider, label: label, webProfileID: UUID(),
            displayOrder: 0, createdAt: now
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    // MARK: Dollars

    func testDollarsFollowTheAppLanguageNotTheRegion() {
        XCTAssertEqual(UsageFormatters.usd(cents: 1250, locale: L10n.en), "$12.50")
        XCTAssertEqual(UsageFormatters.usd(cents: 1250, locale: Locale(identifier: "en_DE")), "$12.50")
        XCTAssertEqual(UsageFormatters.usd(cents: 123_456, locale: L10n.en), "$1234.56")
        XCTAssertEqual(UsageFormatters.usd(cents: 0, locale: L10n.en), "$0.00")
        XCTAssertEqual(UsageFormatters.usd(cents: 1250, locale: L10n.fr), "12,50\(nb)$")
        XCTAssertEqual(UsageFormatters.usd(cents: 1250, locale: Locale(identifier: "fr_CH")), "12,50\(nb)$")
        XCTAssertEqual(UsageFormatters.usd(cents: 123_456, locale: L10n.fr), "1234,56\(nb)$")
        XCTAssertEqual(UsageFormatters.usd(cents: 1250, locale: L10n.uk), "12,50\(nb)$")
        XCTAssertEqual(FocusModel.dollarsText(cents: 7, locale: L10n.en), "$0.07")
        XCTAssertEqual(FocusModel.dollarsText(cents: 7, locale: L10n.fr), "0,07\(nb)$")
        XCTAssertEqual(FocusModel.dollarsText(cents: 7, locale: L10n.uk), "0,07\(nb)$")
    }

    /// Alert and drop amounts: the same `currency.usd` entry, still dropping
    /// ".00" on a whole-dollar amount ("$50", "50 $").
    func testAlertDollarsUseTheCatalogFormAndDropWholeCents() {
        XCTAssertEqual(AlertMessage.dollars(5_000, locale: L10n.en), "$50")
        XCTAssertEqual(AlertMessage.dollars(5_250, locale: L10n.en), "$52.50")
        // Grouped, as in 1.3.0's alert copy (the card's `usd` never groups).
        XCTAssertEqual(AlertMessage.dollars(123_405, locale: L10n.en), "$1,234.05")
        XCTAssertEqual(AlertMessage.dollars(123_405, locale: Locale(identifier: "en_DE")), "$1,234.05")
        XCTAssertEqual(AlertMessage.dollars(5_000, locale: Locale(identifier: "en_FR")), "$50")
        XCTAssertEqual(AlertMessage.dollars(5_000, locale: L10n.fr), "50\(nb)$")
        XCTAssertEqual(AlertMessage.dollars(5_250, locale: L10n.fr), "52,50\(nb)$")
        XCTAssertEqual(AlertMessage.dollars(5_250, locale: Locale(identifier: "fr_CA")), "52,50\(nb)$")
        XCTAssertEqual(AlertMessage.dollars(5_000, locale: L10n.uk), "50\(nb)$")
        XCTAssertEqual(AlertMessage.dollars(5_250, locale: L10n.uk), "52,50\(nb)$")
    }

    // MARK: Cursor spend row

    func testCursorSpendRow() {
        let spend = CursorSpend(
            spentCents: 1234, periodStart: nil,
            resetsAt: now.addingTimeInterval(5 * 86_400), planLabel: "Pro"
        )
        let zero = CursorSpend(spentCents: 0, periodStart: nil, resetsAt: now, planLabel: "Pro")

        let fr = CursorSpendRow.text(for: spend, now: now, locale: L10n.fr)
        XCTAssertEqual(fr.headline, "12,34\(nb)$")
        XCTAssertEqual(fr.caption, "ce cycle · réinitialisation dans 5\(nb)j")
        XCTAssertEqual(CursorSpendRow.text(for: zero, now: now, locale: L10n.fr).caption, "aucuns frais à l’usage")

        let uk = CursorSpendRow.text(for: spend, now: now, locale: L10n.uk)
        XCTAssertEqual(uk.headline, "12,34\(nb)$")
        XCTAssertEqual(uk.caption, "цей цикл · скидання через 5\(nb)д")
        XCTAssertEqual(CursorSpendRow.text(for: zero, now: now, locale: L10n.uk).caption, "без оплати за використання")

        XCTAssertEqual(
            CursorSpendRow.accessibilityDescription(for: spend, now: now, locale: L10n.en),
            "Cursor spend, $12.34, Pro, this cycle, resets in 5 days"
        )
        XCTAssertEqual(
            CursorSpendRow.accessibilityDescription(for: spend, now: now, locale: L10n.fr),
            "Dépenses Cursor, 12,34\(nb)$, Pro, ce cycle, réinitialisation dans 5 jours"
        )
        XCTAssertEqual(
            CursorSpendRow.accessibilityDescription(for: zero, now: now, locale: L10n.uk),
            "Витрати Cursor, 0,00\(nb)$, Pro, без оплати за використання"
        )
        XCTAssertEqual(CursorSpendRow.accessibilityDescription(for: nil, now: now, locale: L10n.fr), "Dépenses Cursor, indisponibles")
        XCTAssertEqual(CursorSpendRow.accessibilityDescription(for: nil, now: now, locale: L10n.uk), "Витрати Cursor, недоступно")
    }

    // MARK: Limit row

    func testLimitRowSpoken() {
        let noReset = UsageWindow(kind: .fiveHour, remainingFraction: 0.55, resetsAt: nil)
        func spoken(_ window: UsageWindow?, _ locale: Locale) -> String {
            LimitRowView.accessibilityDescription(title: "5h", kind: .fiveHour, window: window, now: now, locale: locale)
        }
        XCTAssertEqual(spoken(nil, L10n.en), "5 hour, unavailable")
        XCTAssertEqual(spoken(noReset, L10n.en), "5 hour, 45% used, reset not scheduled")
        XCTAssertEqual(spoken(nil, L10n.fr), "fenêtre de 5 heures, indisponible")
        XCTAssertEqual(spoken(noReset, L10n.fr), "fenêtre de 5 heures, 45\(nnb)% utilisés, aucune réinitialisation prévue")
        XCTAssertEqual(spoken(nil, L10n.uk), "5-годинне вікно, недоступно")
        XCTAssertEqual(spoken(noReset, L10n.uk), "5-годинне вікно, використано 45%, скидання не заплановано")

        let reset = UsageWindow(kind: .fiveHour, remainingFraction: 0.55, resetsAt: now.addingTimeInterval(3 * 3600))
        XCTAssertTrue(spoken(reset, L10n.fr).hasPrefix("fenêtre de 5 heures, 45\(nnb)% utilisés, réinitialisation dans 3 heures, le "))
        XCTAssertTrue(spoken(reset, L10n.uk).hasPrefix("5-годинне вікно, використано 45%, скидання через 3 години, "))
    }

    func testLimitRowTooltip() {
        let noReset = UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: nil)
        let reset = UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: now.addingTimeInterval(3 * 3600))
        func tip(_ window: UsageWindow?, _ locale: Locale) -> String {
            LimitRowView.tooltip(title: "wk", window: window, now: now, locale: locale)
        }
        XCTAssertEqual(tip(nil, L10n.en), "wk: unavailable")
        XCTAssertEqual(tip(noReset, L10n.en), "wk: no scheduled reset")
        XCTAssertTrue(tip(reset, L10n.en).hasPrefix("wk · resets in 3 hours · "))
        XCTAssertEqual(tip(nil, L10n.fr), "wk\(nb): indisponible")
        XCTAssertEqual(tip(noReset, L10n.fr), "wk\(nb): aucune réinitialisation prévue")
        XCTAssertTrue(tip(reset, L10n.fr).hasPrefix("wk · réinitialisation dans 3 heures · "))
        XCTAssertEqual(tip(nil, L10n.uk), "wk: недоступно")
        XCTAssertEqual(tip(noReset, L10n.uk), "wk: скидання не заплановано")
        XCTAssertTrue(tip(reset, L10n.uk).hasPrefix("wk · скидання через 3 години · "))
    }

    func testLimitRowCountdownFollowsTheLocale() {
        let resetsAt = now.addingTimeInterval(2 * 3600 + 5 * 60)
        XCTAssertEqual(LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: false, locale: L10n.en), "2h 5m")
        XCTAssertEqual(LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: false, locale: L10n.fr), "2\(nb)h 5\(nb)min")
        XCTAssertEqual(LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: false, locale: L10n.uk), "2\(nb)год 5\(nb)хв")
    }

    // MARK: In use marker

    func testInUseMarker() {
        XCTAssertEqual(InUseMarkerContent.pillText(locale: L10n.en), "IN USE")
        XCTAssertEqual(InUseMarkerContent.pillText(locale: L10n.fr), "EN COURS")
        XCTAssertEqual(InUseMarkerContent.pillText(locale: L10n.uk), "АКТИВНИЙ")
        XCTAssertEqual(InUseMarkerContent.inUseSpoken("5 minutes ago", locale: L10n.en), "in use, 5 minutes ago")
        XCTAssertEqual(InUseMarkerContent.inUseSpoken("il y a 5 minutes", locale: L10n.fr), "en cours d’utilisation, il y a 5 minutes")
        XCTAssertEqual(InUseMarkerContent.inUseSpoken("5 хвилин тому", locale: L10n.uk), "активний, 5 хвилин тому")
        XCTAssertEqual(InUseMarkerContent.lastUsedText("1 hour ago", locale: L10n.en), "last used · 1 hour ago")
        XCTAssertEqual(InUseMarkerContent.lastUsedText("il y a 1 heure", locale: L10n.fr), "dernière utilisation · il y a 1 heure")
        XCTAssertEqual(InUseMarkerContent.lastUsedText("1 годину тому", locale: L10n.uk), "останнє використання · 1 годину тому")
        XCTAssertEqual(InUseMarkerContent.lastUsedSpoken("1 hour ago", locale: L10n.en), "last used 1 hour ago")
        XCTAssertEqual(InUseMarkerContent.lastUsedSpoken("il y a 1 heure", locale: L10n.fr), "dernière utilisation il y a 1 heure")
        XCTAssertEqual(InUseMarkerContent.lastUsedSpoken("1 годину тому", locale: L10n.uk), "останнє використання 1 годину тому")
    }

    // MARK: Account state badge

    func testBadgeCompactText() {
        let retryAt = now.addingTimeInterval(5 * 60)
        func compact(_ state: AccountViewState, _ locale: Locale) -> String? {
            AccountStateBadge.compactText(for: state, now: now, locale: locale)
        }
        XCTAssertNil(compact(.loading, L10n.fr))
        XCTAssertNil(compact(.current, L10n.fr))
        XCTAssertEqual(compact(.stale(lastError: .offline), L10n.en), "stale")
        XCTAssertEqual(compact(.rateLimited(retryAt: nil), L10n.en), "rate limited")
        XCTAssertEqual(compact(.rateLimited(retryAt: retryAt), L10n.en), "retry in 5 minutes")
        XCTAssertEqual(compact(.stale(lastError: .offline), L10n.fr), "obsolète")
        XCTAssertEqual(compact(.rateLimited(retryAt: nil), L10n.fr), "requêtes limitées")
        XCTAssertEqual(compact(.rateLimited(retryAt: retryAt), L10n.fr), "nouvel essai dans 5 minutes")
        XCTAssertEqual(compact(.integrationChanged, L10n.fr), "mise à jour requise")
        XCTAssertEqual(compact(.unavailable, L10n.fr), "indisponible")
        XCTAssertEqual(compact(.stale(lastError: .offline), L10n.uk), "застаріло")
        XCTAssertEqual(compact(.rateLimited(retryAt: retryAt), L10n.uk), "повтор через 5 хвилин")
        XCTAssertEqual(compact(.integrationChanged, L10n.uk), "потрібне оновлення")
        XCTAssertEqual(compact(.unavailable, L10n.uk), "недоступно")
    }

    func testBadgeDetailedText() {
        let retryAt = now.addingTimeInterval(5 * 60)
        func detailed(_ state: AccountViewState, _ locale: Locale) -> String? {
            AccountStateBadge.detailedText(for: state, now: now, locale: locale)
        }
        XCTAssertEqual(detailed(.loading, L10n.en), "Refreshing")
        XCTAssertEqual(detailed(.current, L10n.en), "Active")
        XCTAssertEqual(detailed(.rateLimited(retryAt: retryAt), L10n.en), "Rate-limited · retry in 5 minutes")
        XCTAssertNil(detailed(.reauthenticationRequired, L10n.en))
        XCTAssertEqual(detailed(.loading, L10n.fr), "Actualisation")
        XCTAssertEqual(detailed(.current, L10n.fr), "À jour")
        XCTAssertEqual(detailed(.stale(lastError: .offline), L10n.fr), "Obsolète")
        XCTAssertEqual(detailed(.rateLimited(retryAt: nil), L10n.fr), "Requêtes limitées")
        XCTAssertEqual(detailed(.rateLimited(retryAt: retryAt), L10n.fr), "Requêtes limitées · nouvel essai dans 5 minutes")
        XCTAssertEqual(detailed(.integrationChanged, L10n.fr), "Mise à jour requise")
        XCTAssertEqual(detailed(.unavailable, L10n.fr), "Aucune donnée")
        XCTAssertEqual(detailed(.current, L10n.uk), "Актуально")
        XCTAssertEqual(detailed(.stale(lastError: .offline), L10n.uk), "Застаріло")
        XCTAssertEqual(detailed(.unavailable, L10n.uk), "Немає даних")
        XCTAssertEqual(AccountStateBadge.signInNeededText(locale: L10n.en), "Sign-in needed")
        XCTAssertEqual(AccountStateBadge.signInNeededText(locale: L10n.fr), "Connexion requise")
        XCTAssertEqual(AccountStateBadge.signInNeededText(locale: L10n.uk), "Потрібно увійти")
    }

    // MARK: Focus

    func testFocusHeroSpoken() {
        let hero = FocusModel.Hero(
            presentation: presentation(),
            headroom: 0.73, bindingKind: .fiveHour, bindingLabel: nil,
            tag: .inUse, isPinned: true, resetsAt: nil,
            otherLimits: [FocusModel.Limit(kind: .weekly, label: nil, headroom: 0.5)]
        )
        XCTAssertEqual(
            FocusView.heroAccessibilityLabel(hero, now: now, locale: L10n.en),
            "Work, in use, Claude, 73% of 5 hours left, 50 percent of the weekly limit left, chosen by you"
        )
        XCTAssertEqual(
            FocusView.heroAccessibilityLabel(hero, now: now, locale: L10n.fr),
            "Work, en cours d’utilisation, Claude, 73\(nb)% des 5 heures restant, fenêtre hebdomadaire\(nb): il reste 50 pour cent de la limite, choisi par vous"
        )
        XCTAssertEqual(
            FocusView.heroAccessibilityLabel(hero, now: now, locale: L10n.uk),
            "Work, активний, Claude, 73% з 5 годин залишилося, тижневе вікно: залишилося 50 відсотків ліміту, вибрано вами"
        )
        let lastUsed = FocusModel.Hero(
            presentation: presentation(),
            headroom: 0.73, bindingKind: .fiveHour, bindingLabel: nil,
            tag: .lastUsed, isPinned: false, resetsAt: now.addingTimeInterval(3 * 3600), otherLimits: []
        )
        XCTAssertEqual(
            FocusView.heroAccessibilityLabel(lastUsed, now: now, locale: L10n.fr),
            "Work, dernière utilisation, Claude, 73\(nb)% des 5 heures restant, réinitialisation dans 3 heures"
        )
        XCTAssertEqual(
            FocusView.heroAccessibilityLabel(lastUsed, now: now, locale: L10n.uk),
            "Work, останнє використання, Claude, 73% з 5 годин залишилося, скидання через 3 години"
        )
    }

    func testFocusLimitLeftUkrainianPlurals() {
        let expected = [1: "відсоток", 2: "відсотки", 5: "відсотків", 21: "відсоток", 22: "відсотки", 25: "відсотків"]
        for (count, word) in expected {
            XCTAssertEqual(
                FocusView.spokenValue(.headroom(Double(count) / 100, .weekly), locale: L10n.uk),
                "тижневе вікно: залишилося \(count) \(word) ліміту"
            )
        }
        XCTAssertEqual(
            FocusView.spokenValue(.headroom(0.2, .modelWeekly), snapshot: nil, locale: L10n.fr),
            "fenêtre hebdomadaire Fable\(nb): il reste 20 pour cent de la limite"
        )
    }

    func testFocusSpokenValues() {
        XCTAssertEqual(FocusView.spokenValue(.spent(cents: 1234), locale: L10n.en), "$12.34 spent")
        XCTAssertEqual(FocusView.spokenValue(.spent(cents: 1234), locale: L10n.fr), "12,34\(nb)$ dépensés")
        XCTAssertEqual(FocusView.spokenValue(.spent(cents: 1234), locale: L10n.uk), "витрачено 12,34\(nb)$")
        XCTAssertEqual(FocusView.spokenValue(.paused, locale: L10n.fr), "en pause")
        XCTAssertEqual(FocusView.spokenValue(.paused, locale: L10n.uk), "призупинено")
        XCTAssertEqual(FocusView.spokenValue(.noData, locale: L10n.fr), "aucune donnée actuelle")
        XCTAssertEqual(FocusView.spokenValue(.noData, locale: L10n.uk), "немає актуальних даних")
        let states: [(AccountViewState, String, String, String)] = [
            (.stale(lastError: .offline), "stale", "obsolète", "застаріло"),
            (.reauthenticationRequired, "sign-in needed", "connexion requise", "потрібно увійти"),
            (.rateLimited(retryAt: nil), "rate limited", "requêtes limitées", "обмеження запитів"),
            (.integrationChanged, "needs update", "mise à jour requise", "потрібне оновлення"),
            (.unavailable, "unavailable", "indisponible", "недоступно"),
            (.loading, "refreshing", "actualisation", "оновлення"),
            (.current, "current", "à jour", "актуально"),
        ]
        for (state, en, fr, uk) in states {
            XCTAssertEqual(FocusView.spokenValue(.state(state), locale: L10n.en), en)
            XCTAssertEqual(FocusView.spokenValue(.state(state), locale: L10n.fr), fr)
            XCTAssertEqual(FocusView.spokenValue(.state(state), locale: L10n.uk), uk)
        }
    }

    func testFocusLines() {
        let work = presentation()
        let line = FocusModel.Line(presentation: work, value: .paused, resetsAt: nil, canBeHero: false)
        XCTAssertEqual(FocusView.inUseLineSpoken(line, locale: L10n.en), "Claude, in use, paused")
        XCTAssertEqual(FocusView.inUseLineSpoken(line, locale: L10n.fr), "Claude, en cours d’utilisation, en pause")
        XCTAssertEqual(FocusView.inUseLineSpoken(line, locale: L10n.uk), "Claude, активний, призупинено")

        let warning = FocusModel.Warning(presentation: work, headroom: 0.01, kind: .weekly, label: nil, resetsAt: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(
            FocusView.warningSpoken(warning, now: now, locale: L10n.en),
            "nearly spent, 1 percent of the weekly limit left, resets in 3 hours"
        )
        XCTAssertEqual(
            FocusView.warningSpoken(warning, now: now, locale: L10n.fr),
            "presque épuisé, fenêtre hebdomadaire\(nb): il reste 1 pour cent de la limite, réinitialisation dans 3 heures"
        )
        XCTAssertEqual(
            FocusView.warningSpoken(warning, now: now, locale: L10n.uk),
            "майже вичерпано, тижневе вікно: залишилося 1 відсоток ліміту, скидання через 3 години"
        )

        XCTAssertEqual(FocusView.linePrefix(work.account, locale: L10n.fr), "Claude\(nb): ")
        XCTAssertEqual(FocusView.linePrefix(work.account, locale: L10n.uk), "Claude: ")
        XCTAssertEqual(FocusView.switchLineLead(.claude, locale: L10n.en), "Next Claude: ")
        XCTAssertEqual(FocusView.switchLineLead(.claude, locale: L10n.fr), "Prochain Claude\(nb): ")
        XCTAssertEqual(FocusView.switchLineLead(.chatGPT, locale: L10n.uk), "Наступний ChatGPT: ")
        XCTAssertEqual(FocusView.switchLineLeft(14, locale: L10n.en), "14% left →")
        XCTAssertEqual(FocusView.switchLineLeft(14, locale: L10n.fr), "14\(nb)% restant →")
        XCTAssertEqual(FocusView.switchLineLeft(14, locale: L10n.uk), "залишилося 14% →")
        XCTAssertEqual(FocusView.showLabel("Client", locale: L10n.en), "Show Client")
        XCTAssertEqual(FocusView.showLabel("Client", locale: L10n.fr), "Afficher Client")
        XCTAssertEqual(FocusView.showLabel("Client", locale: L10n.uk), "Показати Client")
        XCTAssertEqual(FocusView.tagText(.inUse, locale: L10n.fr), "EN COURS")
        XCTAssertEqual(FocusView.tagText(.lastUsed, locale: L10n.en), "LAST USED")
        XCTAssertEqual(FocusView.tagText(.lastUsed, locale: L10n.fr), "DERNIÈRE UTILISATION")
        XCTAssertEqual(FocusView.tagText(.lastUsed, locale: L10n.uk), "ОСТАННЄ ВИКОРИСТАННЯ")
        XCTAssertNil(FocusView.tagText(.none, locale: L10n.uk))
        XCTAssertEqual(FocusView.pausedText(locale: L10n.fr), "en pause")
        XCTAssertEqual(FocusView.pausedText(locale: L10n.uk), "призупинено")
    }

    // MARK: Sparkline

    /// The samples are REMAINING capacity: remaining falling means usage is
    /// rising, and the words say what the user spends, not how the line slopes.
    func testSparklineSpoken() {
        let draining = [
            UsageHistorySample(ts: now, remaining: 0.9, resetsAt: nil),
            UsageHistorySample(ts: now.addingTimeInterval(600), remaining: 0.5, resetsAt: nil),
        ]
        let flat = [
            UsageHistorySample(ts: now, remaining: 0.5, resetsAt: nil),
            UsageHistorySample(ts: now.addingTimeInterval(600), remaining: 0.5, resetsAt: nil),
        ]
        let refilling = [draining[1], UsageHistorySample(ts: now.addingTimeInterval(900), remaining: 0.9, resetsAt: nil)]
        func spoken(_ samples: [UsageHistorySample], _ projection: Date?, _ locale: Locale) -> String {
            UsageSparkline.accessibilityText(samples: samples, projection: projection, locale: locale)
        }
        XCTAssertEqual(spoken([], nil, L10n.en), "Usage trend unavailable")
        XCTAssertEqual(spoken(draining, nil, L10n.en), "Usage trending up")
        XCTAssertEqual(spoken(refilling, nil, L10n.en), "Usage trending down")
        XCTAssertEqual(spoken(flat, nil, L10n.en), "Usage steady")
        XCTAssertTrue(spoken(draining, now, L10n.en).hasPrefix("Usage trending up, projected to run out around "))
        XCTAssertEqual(spoken([], nil, L10n.fr), "Tendance d’utilisation indisponible")
        XCTAssertEqual(spoken(draining, nil, L10n.fr), "Utilisation en hausse")
        XCTAssertEqual(spoken(refilling, nil, L10n.fr), "Utilisation en baisse")
        XCTAssertEqual(spoken(flat, nil, L10n.fr), "Utilisation stable")
        XCTAssertTrue(spoken(draining, now, L10n.fr).hasPrefix("Utilisation en hausse, épuisement prévu vers "))
        XCTAssertEqual(spoken([], nil, L10n.uk), "Тенденція використання недоступна")
        XCTAssertEqual(spoken(draining, nil, L10n.uk), "Використання зростає")
        XCTAssertEqual(spoken(refilling, nil, L10n.uk), "Використання знижується")
        XCTAssertEqual(spoken(flat, nil, L10n.uk), "Використання стабільне")
        XCTAssertTrue(spoken(draining, now, L10n.uk).hasPrefix("Використання зростає, прогнозоване вичерпання близько "))
    }

    // MARK: Header and footer

    func testLayoutHelp() {
        XCTAssertEqual(LayoutSwitch.help(for: .focus, locale: L10n.en), "Focus layout")
        XCTAssertEqual(LayoutSwitch.help(for: .standard, locale: L10n.fr), "Disposition Standard")
        XCTAssertEqual(LayoutSwitch.help(for: .focus, locale: L10n.uk), "Макет «Фокус»")
    }

    func testFooterHelpAddsTheShortcut() {
        XCTAssertEqual(MenuBarView.footerHelp("Actualiser", shortcut: "r"), "Actualiser (⌘R)")
        XCTAssertEqual(MenuBarView.footerHelp("Історія", shortcut: nil), "Історія")
    }

    // MARK: Status item

    func testStatusItemToolTip() {
        let claude = MenuBarGauge(provider: .claude, label: "AI", fraction: 0.14, windowKind: .fiveHour, inUse: false)
        let chatGPT = MenuBarGauge(provider: .chatGPT, label: "ChatGPT", fraction: 0.21, windowKind: .weekly, inUse: true)
        let fable = MenuBarGauge(provider: .claude, label: "Max", fraction: 0.5, windowKind: .modelWeekly, inUse: false)
        XCTAssertEqual(
            StatusItemFactory.toolTip(for: [claude, chatGPT], displaysRemaining: true, locale: L10n.en),
            "Ration — Claude AI 5h 14% left · ChatGPT weekly 21% left (in use)"
        )
        XCTAssertEqual(
            StatusItemFactory.toolTip(for: [claude], displaysRemaining: true, locale: L10n.fr),
            "Ration — Claude AI 5\(nb)h\(nb): 14\(nnb)% restant"
        )
        XCTAssertEqual(
            StatusItemFactory.toolTip(for: [chatGPT, fable], displaysRemaining: false, locale: L10n.fr),
            "Ration — ChatGPT hebdo\(nb): 21\(nnb)% utilisé (en cours) · Claude Max Fable\(nb): 50\(nnb)% utilisé"
        )
        XCTAssertEqual(
            StatusItemFactory.toolTip(for: [claude], displaysRemaining: true, locale: L10n.uk),
            "Ration — Claude AI 5\(nb)год: залишилося 14%"
        )
        XCTAssertEqual(
            StatusItemFactory.toolTip(for: [chatGPT], displaysRemaining: false, locale: L10n.uk),
            "Ration — ChatGPT тижневий: використано 21% (активний)"
        )
        XCTAssertEqual(StatusItemFactory.toolTip(for: [], displaysRemaining: true, locale: L10n.uk), "Ration")
    }

    // MARK: View literals

    /// Keys SwiftUI (or `String(localized:)` in AppKit code) looks up from a
    /// literal in the popover, Focus, drop, badge and window titles. Each must
    /// have its catalog entry, or the view silently shows English.
    func testViewLiteralsResolve() {
        let expected: [(key: String, fr: String, uk: String)] = [
            ("no scheduled reset", "réinit. non prévue", "не заплановано"),
            ("Refreshing", "Actualisation", "Оновлення"),
            ("Current", "À jour", "Актуально"),
            ("Sign In", "Se connecter", "Увійти"),
            ("AUTO", "AUTO", "АВТО"),
            ("Back to the account you're using", "Revenir au compte que vous utilisez", "Повернутися до облікового запису, який ви використовуєте"),
            ("Back to the automatic account", "Revenir au compte automatique", "Повернутися до автоматичного облікового запису"),
            ("All accounts are paused", "Tous les comptes sont en pause", "Усі облікові записи призупинено"),
            ("Resume one in Settings to track it again.", "Réactivez-en un dans les Réglages pour le suivre à nouveau.", "Відновіть один із них у Параметрах, щоб знову відстежувати."),
            ("Dismiss until these limits reset", "Masquer jusqu’à la réinitialisation de ces limites", "Приховати до скидання цих лімітів"),
            ("Dismiss all", "Tout masquer", "Приховати все"),
            ("Opens Ration and dismisses this row", "Ouvre Ration et masque cette ligne", "Відкриває Ration і приховує цей рядок"),
            ("Retry Cleanup", "Relancer le nettoyage", "Повторити очищення"),
            ("Delete the leftover profile from the cancelled sign-in", "Supprimer le profil restant de la connexion annulée", "Видалити залишений профіль скасованого входу"),
            ("Notification Settings", "Réglages des notifications", "Параметри сповіщень"),
            ("Dismiss the alerts drop until these limits reset (⌘D)", "Masquer le panneau d’alertes jusqu’à la réinitialisation de ces limites (⌘D)", "Приховати панель сповіщень до скидання цих лімітів (⌘D)"),
            ("Dismiss alerts", "Masquer les alertes", "Приховати сповіщення"),
            ("NEXT RESET", "PROCHAINE RÉINITIALISATION", "НАСТУПНЕ СКИДАННЯ"),
            ("No accounts connected", "Aucun compte connecté", "Немає під’єднаних облікових записів"),
            ("Add an account to track real limits.", "Ajoutez un compte pour suivre ses limites réelles.", "Додайте обліковий запис, щоб відстежувати реальні ліміти."),
            ("Add Account", "Ajouter un compte", "Додати обліковий запис"),
            ("New here? Open the setup guide", "Nouveau\(nb)? Ouvrez le guide de configuration", "Уперше тут? Відкрийте посібник із налаштування"),
            ("Open the setup guide", "Ouvrir le guide de configuration", "Відкрити посібник із налаштування"),
            ("Refresh", "Actualiser", "Оновити"),
            ("History", "Historique", "Історія"),
            ("Settings", "Réglages", "Параметри"),
            ("About", "À propos", "Про програму"),
            ("Quit", "Quitter", "Вийти"),
            ("Layout", "Disposition", "Макет"),
            ("Details", "Détails", "Докладніше"),
            ("Hide Details", "Masquer les détails", "Згорнути"),
            ("Collapses the message", "Réduit le message", "Згортає повідомлення"),
            ("Shows the whole message", "Affiche le message en entier", "Показує повідомлення повністю"),
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

    /// With no locale passed, code-built copy and `String(localized:)`
    /// window titles follow the running language (fr under `l10n-test fr`,
    /// uk under `uk`, en under `unit-test`).
    func testDefaultsFollowTheRunningLanguage() {
        let running = Locale(identifier: AppLanguage.current.rawValue)
        let gauge = MenuBarGauge(provider: .claude, label: "AI", fraction: 0.14, windowKind: .weekly, inUse: true)
        XCTAssertEqual(
            StatusItemFactory.toolTip(for: [gauge], displaysRemaining: true),
            StatusItemFactory.toolTip(for: [gauge], displaysRemaining: true, locale: running)
        )
        XCTAssertEqual(FocusView.pausedText(), FocusView.pausedText(locale: running))
        XCTAssertEqual(String(localized: "Settings"), LocalizedStringResource("Settings").string(in: running))
        XCTAssertEqual(String(localized: "Setup Guide"), LocalizedStringResource("Setup Guide").string(in: running))
    }

    func testPausedCountLiteralResolves() {
        let count = 3
        let resource = LocalizedStringResource("\(count) paused — manage in Settings")
        XCTAssertEqual(resource.string(in: L10n.en), "3 paused — manage in Settings")
        XCTAssertEqual(resource.string(in: L10n.fr), "3 en pause — gérer dans les Réglages")
        XCTAssertEqual(resource.string(in: L10n.uk), "Призупинено: 3 — керувати в Параметрах")
    }
}
