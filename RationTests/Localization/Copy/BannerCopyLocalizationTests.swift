import XCTest
@testable import Ration

/// The popover's banners and header status in every shipped language: the
/// warm-up banner, the notification-permission copy and LIVE / STALE /
/// OFFLINE.
final class BannerCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Warm-up banner fixtures

    private func account(label: String) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: .claude, label: label, webProfileID: UUID(),
            displayOrder: 0, createdAt: .distantPast, autoStartFiveHour: true,
            keepAliveConversationID: nil, lastAutoStartedAt: nil, isPaused: false
        )
    }

    private func presentation(
        _ account: AccountRecord,
        weeklyRemaining: Double,
        resetsIn: TimeInterval = 6 * 3600,
        fetchedAgo: TimeInterval = 0
    ) -> AccountPresentation {
        AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id,
                fetchedAt: now.addingTimeInterval(-fetchedAgo),
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
                weekly: UsageWindow(kind: .weekly, remainingFraction: weeklyRemaining, resetsAt: now.addingTimeInterval(resetsIn))
            ),
            state: .current
        )
    }

    private func banner(
        _ presentations: [AccountPresentation],
        failures: [UUID: AutoStartFailure] = [:],
        locale: Locale
    ) -> String? {
        WarmUpBannerModel.banner(
            presentations: presentations, failures: failures,
            schedule: .allowAll, now: now, locale: locale
        )?.message
    }

    // MARK: Warm-up banner

    func testHoldBannerInEveryLanguage() {
        let ai = account(label: "AI")
        let held = [presentation(ai, weeklyRemaining: 0)]
        XCTAssertEqual(banner(held, locale: L10n.en), "Warm-up paused for AI — weekly limit reached; resumes in 6h.")
        XCTAssertEqual(
            banner(held, locale: L10n.fr),
            "Préchauffage en pause pour AI — limite hebdomadaire atteinte\(nb); reprise dans 6\(nb)h."
        )
        XCTAssertEqual(
            banner(held, locale: L10n.uk),
            "Розігрів призупинено для AI — тижневий ліміт вичерпано; відновиться через 6\(nb)год."
        )
    }

    func testHoldBannerWithoutACountdown() {
        let held = [presentation(account(label: "AI"), weeklyRemaining: 0, resetsIn: -120, fetchedAgo: 60)]
        XCTAssertEqual(
            banner(held, locale: L10n.fr),
            "Préchauffage en pause pour AI — limite hebdomadaire atteinte\(nb); reprise à la réinitialisation de la limite."
        )
        XCTAssertEqual(
            banner(held, locale: L10n.uk),
            "Розігрів призупинено для AI — тижневий ліміт вичерпано; відновиться після скидання ліміту."
        )
    }

    func testFailureBannersInEveryLanguage() {
        let ada = account(label: "Ada")
        let fine = [presentation(ada, weeklyRemaining: 0.5)]
        let auth = [ada.id: AutoStartFailure(at: now, kind: .authenticationRequired)]
        let transient = [ada.id: AutoStartFailure(at: now, kind: .transient)]
        XCTAssertEqual(banner(fine, failures: auth, locale: L10n.fr), "Préchauffage de Ada\(nb): Claude vous demande de vous reconnecter.")
        XCTAssertEqual(banner(fine, failures: auth, locale: L10n.uk), "Розігрів для Ada: Claude просить вас увійти знову.")
        XCTAssertEqual(
            banner(fine, failures: transient, locale: L10n.fr),
            "Le préchauffage de Ada n’a pas eu lieu cette fois\(nb); il sera relancé automatiquement."
        )
        XCTAssertEqual(
            banner(fine, failures: transient, locale: L10n.uk),
            "Розігрів для Ada цього разу не відбувся; його буде повторено автоматично."
        )
        XCTAssertEqual(
            banner(fine, failures: transient, locale: L10n.en),
            "Auto-start for Ada didn’t run this time; it will retry automatically."
        )
    }

    /// "(+N more)" counts the OTHER accounts, so N accounts show N − 1.
    func testMoreCountPluralsInEveryLanguage() {
        let expectedUK: [Int: String] = [
            1: " (+1 інший)", 2: " (+2 інші)", 5: " (+5 інших)",
            21: " (+21 інший)", 22: " (+22 інші)", 25: " (+25 інших)",
        ]
        for (others, suffix) in expectedUK {
            // Distinct resets so A0 (the soonest) is the one named.
            let held = (0...others).map { index in
                presentation(account(label: "A\(index)"), weeklyRemaining: 0, resetsIn: 6 * 3600 + Double(index) * 60)
            }
            XCTAssertEqual(
                banner(held, locale: L10n.uk),
                "Розігрів призупинено для A0\(suffix) — тижневий ліміт вичерпано; відновиться через 6\(nb)год.",
                "\(others)"
            )
            let french = others == 1 ? " (+1 autre)" : " (+\(others) autres)"
            XCTAssertEqual(
                banner(held, locale: L10n.fr),
                "Préchauffage en pause pour A0\(french) — limite hebdomadaire atteinte\(nb); reprise dans 6\(nb)h.",
                "\(others)"
            )
            XCTAssertEqual(
                banner(held, locale: L10n.en),
                "Warm-up paused for A0 (+\(others) more) — weekly limit reached; resumes in 6h.",
                "\(others)"
            )
        }
    }

    // MARK: Notification access

    func testNotificationAccessCopyFrench() {
        let fr = L10n.fr
        XCTAssertEqual(NotificationAccess.popoverBanner(locale: fr), "Les alertes ne peuvent pas envoyer de notifications — macOS bloque les notifications de Ration")
        XCTAssertEqual(NotificationAccess.alertsPaneNote(locale: fr), "macOS bloque les notifications — le panneau sous la barre des menus fonctionne toujours.")
        XCTAssertEqual(NotificationAccess.generalBlockedNote(locale: fr), "Autorisez les notifications de Ration dans Réglages Système › Notifications.")
        XCTAssertEqual(NotificationAccess.openSettingsTitle(locale: fr), "Ouvrir les réglages des notifications")
        XCTAssertEqual(NotificationAccess.needsPermissionBanner(locale: fr), "Ration n’a pas encore demandé l’autorisation d’envoyer des notifications.")
        XCTAssertEqual(
            NotificationAccess.needsPermissionAlertsNote(locale: fr),
            "Autorisez Ration à envoyer des notifications pour recevoir les alertes — le panneau sous la barre des menus fonctionne toujours."
        )
        XCTAssertEqual(NotificationAccess.allowTitle(locale: fr), "Autoriser les notifications")
        XCTAssertEqual(NotificationAccess.allowHelp(locale: fr), "Demander à macOS d’autoriser Ration à envoyer des notifications")
        XCTAssertEqual(NotificationAccess.Problem.blocked.popoverBanner(locale: fr), NotificationAccess.popoverBanner(locale: fr))
        XCTAssertEqual(NotificationAccess.Problem.needsPermission.generalNote(locale: fr), NotificationAccess.needsPermissionBanner(locale: fr))
        XCTAssertEqual(NotificationAccess.Problem.needsPermission.alertsPaneNote(locale: fr), NotificationAccess.needsPermissionAlertsNote(locale: fr))
    }

    func testNotificationAccessCopyUkrainian() {
        let uk = L10n.uk
        XCTAssertEqual(NotificationAccess.popoverBanner(locale: uk), "Сповіщення не надходять — macOS блокує сповіщення Ration")
        XCTAssertEqual(NotificationAccess.alertsPaneNote(locale: uk), "macOS блокує сповіщення — панель під рядком меню працює й надалі.")
        XCTAssertEqual(NotificationAccess.generalBlockedNote(locale: uk), "Дозвольте сповіщення для Ration у Системних параметрах › Сповіщення.")
        XCTAssertEqual(NotificationAccess.openSettingsTitle(locale: uk), "Відкрити параметри сповіщень")
        XCTAssertEqual(NotificationAccess.needsPermissionBanner(locale: uk), "Ration ще не запитав дозволу на сповіщення.")
        XCTAssertEqual(
            NotificationAccess.needsPermissionAlertsNote(locale: uk),
            "Дозвольте сповіщення, щоб отримувати їх від Ration, — панель під рядком меню працює й надалі."
        )
        XCTAssertEqual(NotificationAccess.allowTitle(locale: uk), "Дозволити сповіщення")
        XCTAssertEqual(NotificationAccess.allowHelp(locale: uk), "Попросити macOS дозволити Ration надсилати сповіщення")
        XCTAssertEqual(NotificationAccess.Problem.blocked.generalNote(locale: uk), NotificationAccess.generalBlockedNote(locale: uk))
        XCTAssertEqual(NotificationAccess.Problem.blocked.alertsPaneNote(locale: uk), NotificationAccess.alertsPaneNote(locale: uk))
    }

    // MARK: Header freshness

    func testHeaderFreshnessWords() {
        XCTAssertEqual(HeaderFreshness.live.text(locale: L10n.fr), "EN DIRECT")
        XCTAssertEqual(HeaderFreshness.offline.text(locale: L10n.fr), "HORS LIGNE")
        XCTAssertEqual(HeaderFreshness.stale(count: 2).text(locale: L10n.fr), "OBSOLÈTE · 2")
        XCTAssertEqual(HeaderFreshness.live.text(locale: L10n.uk), "НАЖИВО")
        XCTAssertEqual(HeaderFreshness.offline.text(locale: L10n.uk), "ОФЛАЙН")
        XCTAssertEqual(HeaderFreshness.stale(count: 21).text(locale: L10n.uk), "ЗАСТАРІЛО · 21")
        XCTAssertEqual(HeaderFreshness.stale(count: 3).text(locale: L10n.en), "STALE · 3")
    }

    func testHeaderFreshnessSpokenPlurals() {
        XCTAssertEqual(HeaderFreshness.live.accessibilityLabel(locale: L10n.fr), "En direct")
        XCTAssertEqual(HeaderFreshness.offline.accessibilityLabel(locale: L10n.uk), "Офлайн")
        XCTAssertEqual(HeaderFreshness.stale(count: 1).accessibilityLabel(locale: L10n.en), "1 account stale")
        XCTAssertEqual(HeaderFreshness.stale(count: 2).accessibilityLabel(locale: L10n.en), "2 accounts stale")
        XCTAssertEqual(HeaderFreshness.stale(count: 1).accessibilityLabel(locale: L10n.fr), "1 compte obsolète")
        XCTAssertEqual(HeaderFreshness.stale(count: 2).accessibilityLabel(locale: L10n.fr), "2 comptes obsolètes")
        let uk: [Int: String] = [
            1: "1 застарілий обліковий запис", 2: "2 застарілі облікові записи",
            5: "5 застарілих облікових записів", 21: "21 застарілий обліковий запис",
            22: "22 застарілі облікові записи", 25: "25 застарілих облікових записів",
        ]
        for (count, expected) in uk {
            XCTAssertEqual(HeaderFreshness.stale(count: count).accessibilityLabel(locale: L10n.uk), expected)
        }
    }
}
