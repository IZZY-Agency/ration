import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Ration

/// Every surface of the app rendered in the run's language, dark and light,
/// at the window's MINIMUM width, for a human to check French and Ukrainian
/// (and the accented pseudolanguage) for clipped or leaked copy.
///
/// Env-gated: runs only with `RATION_L10N_SNAPSHOT_DIR` set (xcodebuild:
/// `TEST_RUNNER_RATION_L10N_SNAPSHOT_DIR=…`) and writes its PNGs there, e.g.
///
///     TEST_RUNNER_RATION_L10N_SNAPSHOT_DIR=/tmp/shots/fr make l10n-test L10N_LANG=fr
///
/// Everywhere else (CI, `make unit-test`) every test here is skipped. The
/// font check (`testRunLanguageDrawsItsOwnFace`) is not gated: the faces are
/// the one thing a picture cannot prove at a glance.
@MainActor
final class LocalizedLayoutSnapshotTests: XCTestCase {
    /// One instant for the fixture AND the views: taken when each test
    /// starts (not when XCTest builds the suite), and handed to every view —
    /// the popover's timelines through `MenuBarView.pinnedNow`.
    private var now = Date()
    private var order = 0

    override func setUp() {
        super.setUp()
        now = Date()
    }

    private var directory: URL {
        get throws {
            guard let path = ProcessInfo.processInfo.environment["RATION_L10N_SNAPSHOT_DIR"], !path.isEmpty else {
                throw XCTSkip("set RATION_L10N_SNAPSHOT_DIR (TEST_RUNNER_RATION_L10N_SNAPSHOT_DIR) to render")
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private static let schemes: [(ColorScheme, String)] = [(.dark, "dark"), (.light, "light")]

    // MARK: Faces

    /// The run language's faces are the ones actually drawn: a sample set in
    /// `Theme.display` / `Theme.mono` renders pixel-identical to the same
    /// sample in the named face, and differently from the other family.
    func testRunLanguageDrawsItsOwnFace() throws {
        AppFonts.register(in: .main)
        let ukrainian: Bool = AppLanguage.current == .ukrainian
        let display: String = ukrainian ? "Manrope-SemiBold" : "SpaceGrotesk-SemiBold"
        let otherDisplay: String = ukrainian ? "SpaceGrotesk-SemiBold" : "Manrope-SemiBold"
        let mono: String = ukrainian ? "JetBrainsMonoNL-Regular" : "SpaceMono-Regular"
        let otherMono: String = ukrainian ? "SpaceMono-Regular" : "JetBrainsMonoNL-Regular"
        let sample = "Réglages 42% limite"
        // Draw every face once first: the first render of a freshly
        // registered font can still come out in a fallback face, which made
        // this comparison fail depending on test order.
        for name in [display, otherDisplay, mono, otherMono] {
            _ = try pixels(Text(verbatim: sample).font(.custom(name, size: 16)))
        }
        _ = try pixels(Text(verbatim: sample).font(Theme.display(16, .semibold)))
        _ = try pixels(Text(verbatim: sample).font(Theme.mono(13)))

        let drawnDisplay = try pixels(Text(verbatim: sample).font(Theme.display(16, .semibold)))
        XCTAssertEqual(drawnDisplay, try pixels(Text(verbatim: sample).font(.custom(display, size: 16))), display)
        XCTAssertNotEqual(drawnDisplay, try pixels(Text(verbatim: sample).font(.custom(otherDisplay, size: 16))), otherDisplay)

        let drawnMono = try pixels(Text(verbatim: sample).font(Theme.mono(13)))
        XCTAssertEqual(drawnMono, try pixels(Text(verbatim: sample).font(.custom(mono, size: 13))), mono)
        XCTAssertNotEqual(drawnMono, try pixels(Text(verbatim: sample).font(.custom(otherMono, size: 13))), otherMono)
    }

    private func pixels(_ text: some View) throws -> Data {
        let renderer = ImageRenderer(content: text.fixedSize().padding(2).background(Color.white))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        // Compare decoded pixels, not an encoded file: encoders may differ in
        // bytes for identical images.
        let bitmap = NSBitmapImageRep(cgImage: image)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        let count: Int = bitmap.bytesPerRow * bitmap.pixelsHigh
        return Data(bytes: bytes, count: count)
    }

    // MARK: Popover

    func testPopoverStandard() async throws {
        let dir = try directory
        let accounts = sampleAccounts()
        let advice = switchAdvice(accounts)
        for (scheme, suffix) in Self.schemes {
            // NEXT RESET line, drop showing (DISMISS ALERTS), a notification banner.
            try write(render(popover(accounts, layout: .standard, dropShowing: true, problem: .needsPermission), scheme), dir, "popover-standard-\(suffix).png")
            // Two switch lines in place of NEXT RESET.
            try write(render(popover(accounts, layout: .standard, advice: advice, problem: .blocked), scheme), dir, "popover-standard-switch-\(suffix).png")
            // Empty state with paused accounts.
            try write(render(popover(accounts.filter(\.account.isPaused), layout: .standard), scheme), dir, "popover-empty-\(suffix).png")
            // The cards alone (the popover's list is a scroll view).
            let cards = VStack(spacing: 0) {
                ForEach(accounts.filter { !$0.account.isPaused }) { presentation in
                    AccountCardView(presentation: presentation, onReauthenticate: {}, now: self.now)
                }
            }
            .frame(width: 540)
            .background(Theme.ink)
            try write(render(cards, scheme), dir, "popover-cards-\(suffix).png")
            // Hosted, so the scrolling card list draws too (capped at four cards).
            try write(await renderHosted(popover(accounts, layout: .standard), width: 540, height: 1150, scheme),
                      dir, "popover-standard-hosted-\(suffix).png")
        }
    }

    func testPopoverFocus() throws {
        let dir = try directory
        let accounts = sampleAccounts()
        let advice = switchAdvice(accounts)
        let byLabel = Dictionary(uniqueKeysWithValues: accounts.map { ($0.account.label, $0.id) })
        let phases: [UUID: InUsePhase] = [
            byLabel["Personal"]!: .inUse(age: 60),
            byLabel["20x"]!: .inUse(age: 600),
            byLabel["Client"]!: .lastUsed(age: 7200),
        ]
        let auto = FocusModel.make(presentations: accounts, phases: phases, advice: advice,
                                   fableCounts: { _ in false }, now: now)
        // Pinned to the last-used account: DERNIÈRE UTILISATION next to × AUTO.
        let pinned = FocusModel.make(presentations: accounts, phases: phases, advice: advice,
                                     fableCounts: { _ in false }, pinnedHeroID: byLabel["Client"], now: now)
        for (scheme, suffix) in Self.schemes {
            try write(render(popover(accounts, layout: .focus, advice: advice, focus: auto, dropShowing: true), scheme),
                      dir, "popover-focus-\(suffix).png")
            try write(render(popover(accounts, layout: .focus, advice: advice, focus: pinned), scheme),
                      dir, "popover-focus-pinned-\(suffix).png")
        }
    }

    // MARK: Drop

    func testDrop() throws {
        let dir = try directory
        let client = UUID(), personal = UUID(), gptFrom = UUID(), gptTo = UUID()
        let advice = [
            SwitchAdvice(provider: .claude, fromAccountID: client, fromLabel: "Client",
                         toAccountID: personal, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly),
            SwitchAdvice(provider: .chatGPT, fromAccountID: gptFrom, fromLabel: "ChatGPT 20x",
                         toAccountID: gptTo, toLabel: "Agency Team", toHeadroom: 0.62, toBinding: .fiveHour),
        ]
        func row(_ id: UUID, _ label: String, _ provider: Provider, _ subject: AttentionRow.Subject, _ tier: AlertTier,
                 percent: Int? = nil, cents: Int? = nil, resets: TimeInterval, count: Int? = nil) -> AttentionRow {
            AttentionRow(
                accountID: id, accountLabel: label, provider: provider, subject: subject, tier: tier,
                usedPercent: percent, spentCents: cents,
                thresholdPercent: percent == nil ? nil : 80, thresholdCents: cents == nil ? nil : 10_000,
                resetsAt: now.addingTimeInterval(resets), resetCount: count,
                resetCreditIDs: count == nil ? [] : ["credit-1"]
            )
        }
        let model = AttentionDropModelObject()
        model.rows = [
            // The two advised rows.
            row(client, "Client", .claude, .window(.weekly), .critical, percent: 97, resets: 12 * 3600 + 30 * 60),
            row(gptFrom, "ChatGPT 20x", .chatGPT, .window(.fiveHour), .critical, percent: 96, resets: 2 * 3600 + 5 * 60),
            // The countdown column's widest values: now (a reset just due), 2 h 5 min, 12 h 30 min, 3 d 4 h.
            row(UUID(), "Agency Cursor Team", .claude, .window(.fiveHour), .warning, percent: 82, resets: -5),
            row(UUID(), "Max", .claude, .window(.modelWeekly), .critical, percent: 100, resets: 3 * 86_400 + 4 * 3600),
            row(UUID(), "Agency Cursor Team", .cursor, .cursorSpend, .warning, cents: 12_345, resets: 12 * 3600 + 30 * 60),
            row(UUID(), "Agency Team", .chatGPT, .resetCredit(id: "credit-1", kind: .available), .warning,
                resets: 29 * 86_400, count: 2),
            row(UUID(), "Personal", .claude, .resetCredit(id: "credit-2", kind: .expiring), .warning,
                resets: 23 * 3600, count: 1),
        ]
        model.switchAdvice = advice
        model.now = now
        model.showsTicker = true
        let resetsOnly = AttentionDropModelObject()
        resetsOnly.rows = Array(model.rows.suffix(2))
        resetsOnly.now = now
        for (scheme, suffix) in Self.schemes {
            let view = AttentionDropView(model: model).frame(width: AttentionDropPanel.width)
            try write(render(view, scheme), dir, "drop-\(suffix).png")
            let resets = AttentionDropView(model: resetsOnly).frame(width: AttentionDropPanel.width)
            try write(render(resets, scheme), dir, "drop-resets-\(suffix).png")
        }
    }

    // MARK: Settings

    func testSettingsPanes() async throws {
        let dir = try directory
        let fixture = try await makeModel()
        let model = fixture.model
        let accounts = model.presentations
        let claude = try XCTUnwrap(accounts.first { $0.account.label == "Personal" })
        let paused = try XCTUnwrap(accounts.first { $0.account.isPaused })
        let cursor = try XCTUnwrap(accounts.first { $0.account.provider == .cursor })
        let client = try XCTUnwrap(accounts.first { $0.account.label == "Client" })
        let activeUsage: [UUID: ActiveUsage] = [
            claude.id: ActiveUsage(lastUsedAt: now.addingTimeInterval(-120), source: .fiveHour),
            client.id: ActiveUsage(lastUsedAt: now.addingTimeInterval(-2 * 3600 - 59 * 60), source: .fiveHour),
        ]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalizedLayoutSnapshotTests-\(UUID())"))
        let launchAtLogin = LaunchAtLoginController(service: SnapshotLaunchAtLoginService())
        let appearance = AppearanceController(defaults: defaults)
        try await model.settings.addHoliday(HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24), end: LocalDate(year: 2027, month: 1, day: 2), label: "Noël"
        ))
        try await model.settings.setQuietHours([1, 2, 3, 4, 5, 6, 7, 8])

        func split(_ selection: SettingsSelection, _ detail: some View) -> some View {
            NavigationSplitView {
                SettingsSidebar(
                    presentations: accounts, activeUsage: activeUsage, selection: .constant(selection),
                    canReorder: true, onMove: { _, _ in }, onAddAccount: {}
                )
                .navigationSplitViewColumnWidth(
                    min: SettingsSidebar.minColumnWidth,
                    ideal: SettingsSidebar.idealColumnWidth,
                    max: SettingsSidebar.maxColumnWidth
                )
            } detail: {
                detail
            }
            .tint(Theme.gold)
            .background(Theme.ink)
        }
        func account(_ presentation: AccountPresentation) -> some View {
            AccountDetailView(
                presentation: presentation, activeUsage: activeUsage[presentation.id], now: now,
                onRename: { _ in }, onRenameError: { _ in }, onReauthenticate: {}, onRemove: {},
                onSetAutoStart: { _ in }, onSetBillingRenewalDay: { _ in }, onSetPlan: { _ in },
                onSetPaused: { _ in }, onDebugSend: {}
            )
        }
        let general = GeneralDetailView(
            launchAtLogin: launchAtLogin, appearance: appearance, settings: model.settings,
            notificationPermission: .denied,
            onSetSortByWeeklyReset: { _ in }, onSetUsageAlertsEnabled: { _ in }, onSetRedactNotifications: { _ in },
            onSetShowInUseInMenuBar: { _ in }, onSetMenuBarWindow: { _, _ in }, onSetMenuBarDisplaysRemaining: { _ in },
            onSetPopoverLayout: { _ in }, onOpenSetupGuide: {}, onAllowNotifications: {}
        )
        let alerts = AlertsDetailView(
            settings: model.settings, providers: [.claude, .chatGPT, .cursor], notificationPermission: .denied,
            onSetWarningPercent: { _, _, _ in }, onSetCriticalPercent: { _, _, _ in },
            onSetSpendWarningCents: { _ in }, onSetSpendCriticalCents: { _ in },
            onSetDropEnabled: { _, _ in }, onSetNotificationEnabled: { _, _ in },
            onSetResetLeadDays: { _, _ in }, onError: { _ in }
        )
        let warmUp = WarmUpDetailView(
            settings: model.settings, autoStartEnabledCount: 1,
            onSetQuietHours: { _ in }, onAddHoliday: { _ in }, onSetHolidayLabel: { _, _ in },
            onSetHolidayStart: { _, _ in }, onSetHolidayEnd: { _, _ in }, onRemoveHoliday: { _ in },
            onError: { _ in }
        )
        let width = SettingsView.minimumWindowWidth
        for (scheme, suffix) in Self.schemes {
            // Tall enough for every row of the longest pane: horizontal fit is
            // what these check; the window itself scrolls vertically.
            try write(await renderHosted(split(.general, general), width: width, height: 2300, scheme), dir, "settings-general-\(suffix).png")
            try write(await renderHosted(split(.alerts, alerts), width: width, height: 1500, scheme), dir, "settings-alerts-\(suffix).png")
            try write(await renderHosted(split(.warmUp, warmUp), width: width, height: 1100, scheme), dir, "settings-warmup-\(suffix).png")
            try write(await renderHosted(split(.account(claude.id), account(claude)), width: width, height: 1000, scheme), dir, "settings-account-inuse-\(suffix).png")
            try write(await renderHosted(split(.account(client.id), account(client)), width: width, height: 1000, scheme), dir, "settings-account-lastused-\(suffix).png")
            try write(await renderHosted(split(.account(paused.id), account(paused)), width: width, height: 1000, scheme), dir, "settings-account-paused-\(suffix).png")
            try write(await renderHosted(split(.account(cursor.id), account(cursor)), width: width, height: 1000, scheme), dir, "settings-account-cursor-\(suffix).png")
            // The real window at its minimum size, opening pane.
            let window = SettingsView(
                model: model, launchAtLogin: launchAtLogin, appearance: appearance, history: model.history,
                onAddAccount: {}, onOpenSignIn: { _ in }, onOpenSetupGuide: {}
            )
            try write(await renderHosted(window, width: width, height: 470, scheme), dir, "settings-window-min-\(suffix).png")
        }
        fixture.removeFiles()
    }

    // MARK: History

    func testHistory() async throws {
        let dir = try directory
        let fixture = try await makeModel(history: true)
        for (scheme, suffix) in Self.schemes {
            try write(await renderHosted(HistoryView(model: fixture.model), width: 680, height: 480, scheme, settle: 2.5),
                      dir, "history-patterns-\(suffix).png")
            // Six cards, one per billing state (see `recordHistory`).
            try write(await renderHosted(BillingCycleView(model: fixture.model).background(Theme.ink), width: 680, height: 1250, scheme, settle: 3),
                      dir, "history-billing-\(suffix).png")
        }
        fixture.removeFiles()
    }

    /// The Billing-cycle cards in both framings at the History window's
    /// minimum width (680 pt): v2 rolling (weekly, 5h), v2 fixed with the
    /// widest caption, a v2 Fable line, and the legacy 1.4.0 framing.
    func testBillingCycleCards() async throws {
        let dir = try directory
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let cycle = BillingCycle.current(renewalDay: 14, now: now, calendar: calendar)
        func summary(
            _ kind: UsageWindowKind, _ family: WindowFamily, _ value: Double, legacy: Bool = false
        ) -> CycleUtilizationSummary {
            CycleUtilizationSummary(
                windowKind: kind, family: family, capacityUtilization: value, isLegacyLowerBound: legacy,
                consumedAllowances: 1.46, daysUsed: 21, atCapDays: 11, observedHours: 312, elapsedHours: 330,
                observedSeconds: 312.4 * 3600, elapsedSeconds: 330 * 3600
            )
        }
        func card(_ label: String, _ provider: Provider, _ s: CycleUtilizationSummary, fable: FableSecondary? = nil) -> BillingCycleCard {
            .tracked(id: UUID(), label: label, provider: provider, cycle: cycle, summary: s, fable: fable)
        }
        let cards: [BillingCycleCard] = [
            card("Client", .claude, summary(.weekly, .rolling, 0.62),
                 fable: FableSecondary(label: "Fable", summary: summary(.modelWeekly, .rolling, 0.31))),
            card("Personal", .claude, summary(.fiveHour, .rolling, 0.47)),
            card("20x", .chatGPT, summary(.weekly, .fixed, 0.88)),
            card("5x", .chatGPT, summary(.fiveHour, .fixed, 0.35)),
            card("Legacy", .claude, summary(.weekly, .rolling, 0.424, legacy: true),
                 fable: FableSecondary(label: "Fable", summary: summary(.modelWeekly, .rolling, 0.2, legacy: true))),
        ]
        let list = VStack(alignment: .leading, spacing: 12) {
            ForEach(cards) { BillingCycleCardView(card: $0) }
        }
        .padding(16)
        .frame(width: 680, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.ink)
        for (scheme, suffix) in Self.schemes {
            try write(await renderHosted(list, width: 680, height: 1000, scheme), dir, "history-billing-cards-\(suffix).png")
        }
    }

    /// Not gated: the caption under each figure is actually
    /// drawn. Each card state with a figure (v2 rolling, v2 fixed, legacy) is
    /// rendered at the History window's minimum width and read back with
    /// on-device text recognition; the caption (drawn uppercase) must be
    /// found. The copy itself is pinned line by line in
    /// `HistoryCopyLocalizationTests.testCardTextForEveryStateInEveryLanguage`
    /// — the view draws exactly `BillingCycleCopy.cardText`. Runs in every
    /// language suite, in the run's language.
    func testBillingCycleCardCaptionsAreDrawn() async throws {
        AppFonts.register(in: .main)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let cycle = BillingCycle.current(renewalDay: 14, now: now, calendar: calendar)
        func summary(_ family: WindowFamily, _ value: Double, legacy: Bool = false,
                     kind: UsageWindowKind = .weekly) -> CycleUtilizationSummary {
            CycleUtilizationSummary(
                windowKind: kind, family: family, capacityUtilization: value, isLegacyLowerBound: legacy,
                consumedAllowances: 1.46, daysUsed: 21, atCapDays: 11, observedHours: 312, elapsedHours: 330,
                observedSeconds: 312 * 3600, elapsedSeconds: 330 * 3600
            )
        }
        let cards: [(String, BillingCycleCard)] = [
            ("v2 rolling", .tracked(id: UUID(), label: "Client", provider: .claude, cycle: cycle,
                                    summary: summary(.rolling, 0.62),
                                    fable: FableSecondary(label: "Fable", summary: summary(.rolling, 0.31, kind: .modelWeekly)))),
            ("v2 fixed", .tracked(id: UUID(), label: "20x", provider: .chatGPT, cycle: cycle,
                                  summary: summary(.fixed, 0.88, kind: .fiveHour), fable: nil)),
            ("legacy", .tracked(id: UUID(), label: "Legacy", provider: .claude, cycle: cycle,
                                summary: summary(.rolling, 0.424, legacy: true), fable: nil)),
        ]
        for (name, card) in cards {
            guard case let .figure(_, caption, _, _) = BillingCycleCopy.cardText(card).body else {
                return XCTFail("\(name): expected a figure")
            }
            let lines = try recognizedLines(BillingCycleCardView(card: card), width: 680)
            let wanted = Self.letters(caption)
            XCTAssertFalse(wanted.isEmpty, name)
            // Its own line: the v2 Fable line repeats the rolling caption.
            XCTAssertTrue(lines.contains { Self.letters($0) == wanted },
                          "\(name): caption “\(caption)” is not drawn; read: \(lines)")
        }
    }

    /// Letters and digits only, uppercased, accents folded: text recognition
    /// may read the spacing, punctuation and accents of tracked uppercase
    /// text differently.
    private static func letters(_ text: String) -> String {
        let folded: String = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Renders `view` at 3× on the dark ink and returns the recognised lines.
    private func recognizedLines(_ view: some View, width: CGFloat) throws -> [String] {
        let content = view
            .frame(width: width)
            .padding(16)
            .background(Theme.ink)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        switch AppLanguage.current {
        case .english, .system: request.recognitionLanguages = ["en-US"]
        case .french: request.recognitionLanguages = ["fr-FR"]
        case .ukrainian: request.recognitionLanguages = ["uk-UA"]
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var lines: [String] = []
        for observation in request.results ?? [] {
            if let best = observation.topCandidates(1).first { lines.append(best.string) }
        }
        return lines
    }

    // MARK: Onboarding, plan step, About, sign-in

    func testOnboardingSteps() async throws {
        let dir = try directory
        let fixture = try await makeModel(seed: false)
        let launchAtLogin = LaunchAtLoginController(service: SnapshotLaunchAtLoginService())
        func step(_ body: some View) -> some View {
            ScrollView { body.padding(22).frame(maxWidth: .infinity, alignment: .leading) }
                .background(Theme.ink)
                .tint(Theme.gold)
        }
        let plan = AccountRecord(
            id: UUID(), provider: .claude, label: "Personal", webProfileID: UUID(),
            displayOrder: 0, createdAt: now
        )
        for (scheme, suffix) in Self.schemes {
            let wizard = OnboardingView(model: fixture.model, launchAtLogin: launchAtLogin, onOpenSignIn: { _ in }, onFinish: {})
            try write(await renderHosted(wizard, width: 520, height: 480, scheme), dir, "onboarding-welcome-window-\(suffix).png")
            try write(await renderHosted(step(OnboardingWelcomeStep()), width: 520, height: 700, scheme), dir, "onboarding-1-welcome-\(suffix).png")
            try write(await renderHosted(step(OnboardingConnectStep(onSelect: { _ in }, isWaitingForSignIn: true, signInError: nil)), width: 520, height: 700, scheme),
                      dir, "onboarding-2-connect-\(suffix).png")
            try write(await renderHosted(step(OnboardingLaunchAtLoginStep(launchAtLogin: launchAtLogin)), width: 520, height: 600, scheme),
                      dir, "onboarding-3-login-\(suffix).png")
            try write(await renderHosted(step(OnboardingDoneStep(hasAccounts: true)), width: 520, height: 700, scheme), dir, "onboarding-4-done-\(suffix).png")
            try write(await renderHosted(step(OnboardingDoneStep(hasAccounts: false)), width: 520, height: 700, scheme), dir, "onboarding-4-done-empty-\(suffix).png")
            let planStep = PlanStepView(account: plan, onSave: { _, _ in }, onSkip: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ink)
            try write(await renderHosted(planStep, width: 700, height: 620, scheme), dir, "plan-step-\(suffix).png")
        }
        fixture.removeFiles()
    }

    func testAboutAndSignIn() async throws {
        let dir = try directory
        let fixture = try await makeModel(seed: false)
        let claudeID = try fixture.model.beginSignIn(provider: .claude)
        let gptID = try fixture.model.beginSignIn(provider: .chatGPT)
        let claude = try XCTUnwrap(fixture.model.signInSession(for: claudeID))
        let gpt = try XCTUnwrap(fixture.model.signInSession(for: gptID))
        for (scheme, suffix) in Self.schemes {
            try write(await renderHosted(AboutView(), width: 360, height: 286, scheme), dir, "about-\(suffix).png")
            try write(await renderHosted(SignInSessionView(model: fixture.model, session: claude), width: 700, height: 620, scheme),
                      dir, "signin-claude-\(suffix).png")
            try write(await renderHosted(SignInSessionView(model: fixture.model, session: gpt), width: 700, height: 620, scheme),
                      dir, "signin-chatgpt-\(suffix).png")
            try write(await renderHosted(AddAccountView(model: fixture.model, onOpenSignIn: { _ in }, onDismiss: {}), width: 420, height: 530, scheme),
                      dir, "add-account-\(suffix).png")
        }
        await fixture.model.cancelSignIn(sessionID: claudeID)
        await fixture.model.cancelSignIn(sessionID: gptID)
        fixture.removeFiles()
    }

    // MARK: Fixtures

    private func presentation(
        _ label: String, _ provider: Provider, paused: Bool = false, plan: PlanTier? = nil,
        fiveHour: Double? = nil, weekly: Double? = nil, fable: Double? = nil,
        fiveHourResetsIn: TimeInterval = 2 * 3600 + 5 * 60, weeklyResetsIn: TimeInterval = 3 * 86_400 + 4 * 3600,
        spentCents: Int? = nil, credits: Bool = false, state: AccountViewState = .current
    ) -> AccountPresentation {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: provider, label: label, webProfileID: UUID(), displayOrder: order,
            createdAt: now.addingTimeInterval(-40 * 86_400), billingRenewalDay: provider == .cursor ? nil : 14,
            isPaused: paused, plan: plan, planSource: plan == nil ? nil : .detected
        )
        return AccountPresentation(
            account: record,
            snapshot: snapshot(id, provider, fiveHour: fiveHour, weekly: weekly, fable: fable,
                               fiveHourResetsIn: fiveHourResetsIn, weeklyResetsIn: weeklyResetsIn,
                               spentCents: spentCents, credits: credits),
            state: state
        )
    }

    private func snapshot(
        _ id: UUID, _ provider: Provider, fiveHour: Double?, weekly: Double?, fable: Double?,
        fiveHourResetsIn: TimeInterval, weeklyResetsIn: TimeInterval, spentCents: Int?, credits: Bool
    ) -> UsageSnapshot {
        let fetched = now.addingTimeInterval(-60)
        let five: UsageWindow? = fiveHour.map {
            UsageWindow(kind: .fiveHour, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(fiveHourResetsIn))
        }
        let week: UsageWindow? = weekly.map {
            UsageWindow(kind: .weekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(weeklyResetsIn))
        }
        let model: UsageWindow? = fable.map {
            UsageWindow(kind: .modelWeekly, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(weeklyResetsIn), label: "Fable")
        }
        let spend: CursorSpend? = spentCents.map {
            CursorSpend(spentCents: $0, periodStart: now.addingTimeInterval(-10 * 86_400),
                        resetsAt: now.addingTimeInterval(20 * 86_400), planLabel: "Pro")
        }
        let resetCredits: ResetCredits? = credits ? ResetCredits(
            fetchedAt: fetched,
            items: [ResetCredit(id: "c1", title: nil, count: 2, expiresAt: now.addingTimeInterval(20 * 3600), usableNow: true)],
            complete: true
        ) : nil
        return UsageSnapshot(
            accountID: id, fetchedAt: fetched, fiveHour: five, weekly: week, modelWeekly: model,
            cursorSpend: spend, resetCredits: resetCredits
        )
    }

    private func sampleAccounts() -> [AccountPresentation] {
        [
            presentation("Client", .claude, plan: .claudeMax20x, fiveHour: 0.20, weekly: 0.99, fable: 0.40,
                         weeklyResetsIn: 12 * 3600 + 30 * 60, credits: true),
            // Half a second from its reset: still current evidence, and the
            // countdown is already the due state ("maintenant" / "зараз") —
            // deterministic because the views share the pinned `now`.
            presentation("Personal", .claude, plan: .claudePro, fiveHour: 0.70, weekly: 0.15,
                         fiveHourResetsIn: 0.5),
            presentation("Claude", .claude, paused: true, fiveHour: 0.10, weekly: 0.10),
            presentation("20x", .chatGPT, plan: .chatGPTPro20x, weekly: 0.75, weeklyResetsIn: 2 * 86_400 + 2 * 3600),
            presentation("5x", .chatGPT, weekly: 0.0, state: .stale(lastError: .offline)),
            presentation("Work", .claude, fiveHour: 0.40, weekly: 0.30, state: .reauthenticationRequired),
            presentation("Cursor", .cursor, spentCents: 12_345),
        ]
    }

    private func switchAdvice(_ accounts: [AccountPresentation]) -> [SwitchAdvice] {
        let byLabel = Dictionary(uniqueKeysWithValues: accounts.map { ($0.account.label, $0.id) })
        return [
            SwitchAdvice(provider: .claude, fromAccountID: byLabel["Client"]!, fromLabel: "Client",
                         toAccountID: byLabel["Personal"]!, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly),
            SwitchAdvice(provider: .chatGPT, fromAccountID: byLabel["20x"]!, fromLabel: "20x",
                         toAccountID: byLabel["5x"]!, toLabel: "5x", toHeadroom: 1.0, toBinding: .weekly),
        ]
    }

    private func popover(
        _ presentations: [AccountPresentation], layout: PopoverLayout, advice: [SwitchAdvice] = [],
        focus: FocusModel? = nil, dropShowing: Bool = false, problem: NotificationAccess.Problem? = nil
    ) -> some View {
        MenuBarView(
            presentations: AccountVisibility.visible(presentations),
            isRefreshing: false,
            profileCleanupBanner: nil,
            errorMessage: nil,
            activeAccounts: [:],
            pausedCount: presentations.filter(\.account.isPaused).count,
            onOpen: {}, onAddAccount: {}, onRefresh: {}, onSettings: {}, onAbout: {},
            onHistory: {}, onRetryProfileCleanup: {}, onQuit: {}, onReauthenticate: { _ in },
            notificationProblem: problem,
            attentionDropShowing: dropShowing,
            switchAdvice: advice,
            layout: layout,
            focusModel: { [focus] date in
                focus ?? FocusModel.make(presentations: [], phases: [:], advice: [],
                                         fableCounts: { _ in false }, now: date)
            },
            pinnedNow: now
        )
    }

    private struct ModelFixture {
        let directory: URL
        let model: AppModel

        func removeFiles() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A real `AppModel` over temp stores, seeded with `sampleAccounts()`
    /// (and, with `history`, five days of 5-hour burn per account).
    private func makeModel(seed: Bool = true, history: Bool = false) async throws -> ModelFixture {
        let directory = try makeTempDirectory()
        let accountStore = AccountStore(fileURL: directory.appending(path: "accounts.json"))
        let snapshotStore = UsageSnapshotStore(fileURL: directory.appending(path: "snapshots.json"))
        let historyStore = UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)
        )
        let seeded: [AccountPresentation] = seed ? sampleAccounts() : []
        // With history, the billing cycle starts a few days back whatever the
        // run date, so every card state below is reachable.
        let renewalDay: Int = historyRenewalDay()
        for presentation in seeded {
            var account = presentation.account
            if history, account.provider != .cursor {
                account.billingRenewalDay = renewalDay
            }
            try await accountStore.add(account)
            if let snapshot = presentation.snapshot {
                try await snapshotStore.save(snapshot)
            }
            if history, account.provider != .cursor {
                recordHistory(account, into: historyStore)
            }
        }
        let model = AppModel(
            accountStore: accountStore,
            snapshotStore: snapshotStore,
            pendingProfileDeletionStore: PendingProfileDeletionStore(
                fileURL: directory.appending(path: "pending-profile-deletions.json")
            ),
            historyStore: historyStore,
            appSettings: AppSettings(fileURL: directory.appending(path: "app-settings.json")),
            alertStateStore: AlertStateStore(fileURL: directory.appending(path: "alert-state.json")),
            profileManager: AlertsWebProfileManagerSpy(),
            adapterRegistry: ProviderAdapterRegistry(adapters: [
                AlertsProviderAdapterSpy(provider: .claude),
                AlertsProviderAdapterSpy(provider: .chatGPT),
                AlertsProviderAdapterSpy(provider: .cursor),
            ])
        )
        // Let the presentations pipeline publish.
        try await Task.sleep(for: .milliseconds(200))
        return ModelFixture(directory: directory, model: model)
    }

    /// A renewal day at least four days back (and ≤ 28, so no month clamps
    /// it): the cycle then has ≥ 96 elapsed hours on any run date.
    private func historyRenewalDay() -> Int {
        let calendar = Calendar.current
        var back = 4
        while true {
            let day: Int = calendar.component(.day, from: now.addingTimeInterval(-Double(back) * 86_400))
            if day <= 28 { return day }
            back += 1
        }
    }

    /// Real history shapes, one billing-card state per account (by label):
    /// - Client, Work (Claude): polled every 10 min for the last 50 h — v2
    ///   rolling figures ("average weekly load"; Client's Fable line too).
    /// - Personal (Claude): hourly since the cycle start — too sparse for v2
    ///   (every interval is over the gap limit), so the legacy "≥ N%".
    /// - 20x (ChatGPT): hourly since the cycle start, the weekly meter
    ///   refilling every 48 h — v2 fixed ("average peak per week").
    /// - Claude (paused), 5x (ChatGPT): hourly for the last 24 h only —
    ///   "Not enough data yet".
    private func recordHistory(_ account: AccountRecord, into store: UsageHistoryStore) {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let cycleStart: Date = BillingCycle.current(
            renewalDay: account.billingRenewalDay ?? 1, now: now, calendar: calendar
        ).start
        let sinceStart: TimeInterval = now.timeIntervalSince(cycleStart)
        let span: TimeInterval
        let step: TimeInterval
        switch account.label {
        case "Client", "Work":
            span = 50 * 3600
            step = 600
        case "Personal", "20x":
            span = sinceStart - 60
            step = 3600
        default:
            span = 24 * 3600
            step = 3600
        }
        let count = Int(span / step)
        for index in 0...count {
            let at: Date = now.addingTimeInterval(-span + Double(index) * step - 30)
            let hours: Double = at.timeIntervalSince(cycleStart) / 3600
            // 5-hour sawtooth, refilled every 5 h.
            let fivePhase: Double = hours.truncatingRemainder(dividingBy: 5)
            let fiveRemaining: Double = 1.0 - fivePhase * 0.17
            let fiveResets: Date = at.addingTimeInterval((5 - fivePhase) * 3600)
            let weekly: UsageWindow
            if account.provider == .chatGPT {
                // Fixed weekly meter: climbs to ~80% over 48 h, then refills.
                let phase: Double = hours.truncatingRemainder(dividingBy: 48)
                weekly = UsageWindow(kind: .weekly, remainingFraction: 1.0 - phase / 48 * 0.8,
                                     resetsAt: at.addingTimeInterval((48 - phase) * 3600))
            } else {
                // Rolling weekly load swinging around 45%.
                let load: Double = 0.45 + 0.15 * sin(hours / 9)
                weekly = UsageWindow(kind: .weekly, remainingFraction: 1.0 - load,
                                     resetsAt: at.addingTimeInterval(2 * 86_400))
            }
            let fable: UsageWindow? = account.label == "Client"
                ? UsageWindow(kind: .modelWeekly, remainingFraction: 0.7 - 0.05 * sin(hours / 7),
                              resetsAt: at.addingTimeInterval(2 * 86_400), label: "Fable")
                : nil
            store.record(
                account: account,
                snapshot: UsageSnapshot(
                    accountID: account.id, fetchedAt: at,
                    fiveHour: account.provider == .claude
                        ? UsageWindow(kind: .fiveHour, remainingFraction: fiveRemaining, resetsAt: fiveResets)
                        : nil,
                    weekly: weekly,
                    modelWeekly: fable
                )
            )
        }
    }

    // MARK: Rendering

    /// Draws a pure SwiftUI view at 2× (the popover, the drop).
    private func render(_ view: some View, _ scheme: ColorScheme) throws -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        renderer.colorMode = .nonLinear
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    /// Hosts the view in an offscreen window (`Form`, `NavigationSplitView`,
    /// pickers and `TimelineView` need AppKit) and caches its display.
    private func renderHosted(
        _ view: some View, width: CGFloat, height: CGFloat, _ scheme: ColorScheme, settle: Double = 0.4
    ) async throws -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let dark: Bool = scheme == .dark
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Suspends (rather than spinning a nested run loop) so the views'
        // `.task`s — History's rollup loads — get the main actor.
        try await Task.sleep(for: .seconds(settle))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, _ dir: URL, _ name: String) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: dir.appending(path: name))
    }
}

/// Reports "enabled" and never touches the real login-item registry.
private final class SnapshotLaunchAtLoginService: LaunchAtLoginService {
    var status: LaunchAtLoginServiceStatus { .enabled }
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettings() {}
}
