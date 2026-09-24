import SwiftUI

/// Pure derivation of the pause controls' copy and enablement, kept out of
/// the view body so it is directly testable.
struct AccountDetailPauseState {
    let isPaused: Bool

    var buttonTitle: String { isPaused ? "Resume account" : "Pause account" }
    var disablesAutomationAndBilling: Bool { isPaused }
    var explanation: String? {
        isPaused
            ? "Paused: not refreshed, excluded from warm-up, hidden from the menu bar. Sign-in is kept."
            : nil
    }
}

/// Detail pane for a single account: header + read-only usage strip, then the
/// Identity / Automation / Billing / Session sections.
struct AccountDetailView: View {
    let presentation: AccountPresentation
    var activeUsage: ActiveUsage? = nil
    /// Global feature switches: Resets hides the Resets section; Claude
    /// warm-up off locks the Auto-start toggle (its stored value is kept).
    var features: FeatureSwitches = .allOn
    var now: Date = .now
    let onReauthenticate: () -> Void
    let onRemove: () -> Void
    let onSetAutoStart: (Bool) -> Void
    let onSetBillingRenewalDay: (Int?) -> Void
    let onSetPlan: (PlanTier?) -> Void
    let onSetPaused: (Bool) -> Void
    let onDebugSend: () -> Void

    @FocusState private var labelFocused: Bool
    @StateObject private var labelAutosave: LabelAutosave

    init(
        presentation: AccountPresentation,
        activeUsage: ActiveUsage? = nil,
        features: FeatureSwitches = .allOn,
        now: Date = .now,
        onRename: @escaping @MainActor (String) async throws -> Void,
        onRenameError: @escaping @MainActor (Error?) -> Void,
        onReauthenticate: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onSetAutoStart: @escaping (Bool) -> Void,
        onSetBillingRenewalDay: @escaping (Int?) -> Void,
        onSetPlan: @escaping (PlanTier?) -> Void,
        onSetPaused: @escaping (Bool) -> Void,
        onDebugSend: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.activeUsage = activeUsage
        self.features = features
        self.now = now
        self.onReauthenticate = onReauthenticate
        self.onRemove = onRemove
        self.onSetAutoStart = onSetAutoStart
        self.onSetBillingRenewalDay = onSetBillingRenewalDay
        self.onSetPlan = onSetPlan
        self.onSetPaused = onSetPaused
        self.onDebugSend = onDebugSend
        // Created once per account: `SettingsView` gives this view `.id(id)`,
        // so the captured rename closure always targets this account.
        _labelAutosave = StateObject(
            wrappedValue: LabelAutosave(
                stored: presentation.account.label,
                save: onRename,
                onError: onRenameError
            )
        )
    }

    private var account: AccountRecord { presentation.account }

    private var pauseState: AccountDetailPauseState {
        AccountDetailPauseState(isPaused: account.isPaused)
    }

    var body: some View {
        Form {
            Section { header } footer: { usageStrip }

            Section(SettingsSectionTitle.identity) {
                HStack {
                    TextField("Account label", text: $labelAutosave.text)
                        .focused($labelFocused)
                        .onSubmit { labelFocused = false }
                        .onChange(of: labelFocused) { _, focused in
                            labelAutosave.focusChanged(focused)
                        }
                }
                LabeledContent("Provider", value: account.provider.displayName)
            }

            if account.provider == .claude {
                Section(SettingsSectionTitle.automation) {
                    Toggle(
                        "Auto-start 5h window",
                        isOn: Binding(
                            get: { account.autoStartFiveHour },
                            set: { onSetAutoStart($0) }
                        )
                    )
                    .accessibilityIdentifier("autoStartToggle")
                    .disabled(pauseState.disablesAutomationAndBilling || !features.warmUp)
                    Text("Sends a short message when the 5h window resets, so its countdown starts right away.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                    if !features.warmUp {
                        Text(FeatureSwitch.warmUpOffNote)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.warn)
                            .accessibilityIdentifier("autoStartWarmUpOffNote")
                    }
                    #if DEBUG
                    Button("Send test keep-alive now (debug)", action: onDebugSend)
                        .font(Theme.mono(12))
                        .disabled(pauseState.disablesAutomationAndBilling)
                    #endif
                }
            }

            if features.resets,
               account.provider != .cursor,
               let items = presentation.snapshot?.resetCredits?.unexpired(at: now), !items.isEmpty {
                Section(SettingsSectionTitle.resets) {
                    ForEach(items, id: \.id) { credit in
                        LabeledContent(credit.title ?? "Usage-limit reset") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("×\(credit.count) · expires \(credit.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Theme.mono(12))
                                    .monospacedDigit()
                                if let usable = credit.usableNow {
                                    Text(usable ? "usable now" : "not usable yet")
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.creamDim)
                                }
                            }
                        }
                    }
                    Text("Use a reset on the provider's usage page. Ration only shows them.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
            }

            // Hidden for providers the Billing-cycle window excludes: Cursor
            // reports its cycle natively on the account card, so a renewal day
            // entered here would feed nothing. Any value already stored on such
            // an account is retained untouched — it is simply not consulted.
            if BillingCycleEligibility.supports(account.provider) {
            Section(SettingsSectionTitle.billing) {
                if !PlanTier.options(for: account.provider).isEmpty {
                    Picker(
                        "Plan",
                        selection: Binding(
                            get: { PlanChoice.selection(for: account) },
                            set: { onSetPlan(PlanChoice.plan(forSelection: $0)) }
                        )
                    ) {
                        Text(PlanChoice.automaticTitle(for: account)).tag(PlanChoice.automatic)
                        ForEach(PlanTier.options(for: account.provider), id: \.self) { tier in
                            Text(tier.displayName).tag(tier.rawValue)
                        }
                    }
                    .accessibilityIdentifier("planPicker")
                    Text("Plans differ in size, so switch advice compares what's left in absolute terms, not just percentages.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
                Picker(
                    "Renewal day",
                    selection: Binding(
                        get: { account.billingRenewalDay ?? 0 },     // 0 = "Not set"
                        set: { onSetBillingRenewalDay($0 == 0 ? nil : $0) }
                    )
                ) {
                    Text("Not set").tag(0)
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
                .accessibilityIdentifier("billingRenewalDayPicker")
                .disabled(pauseState.disablesAutomationAndBilling)
                Text("The day your plan renews each month. Used for per-cycle utilisation in History. Days 29–31 fall back to the month's last day.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
            }
            }

            Section(SettingsSectionTitle.session) {
                Button(pauseState.buttonTitle) { onSetPaused(!account.isPaused) }
                    .accessibilityIdentifier("pauseResumeButton")
                if let explanation = pauseState.explanation {
                    Text(explanation)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
                Button("Sign in again", action: onReauthenticate)
                Button("Remove from this Mac", role: .destructive, action: onRemove)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .onChange(of: account.label) { _, newValue in
            labelAutosave.storeDidChange(newValue)
        }
        .onDisappear { labelAutosave.focusChanged(false) }
    }

    private var header: some View {
        AccountDetailHeader(
            account: account,
            state: presentation.state,
            activeUsage: activeUsage,
            now: now
        )
    }

    @ViewBuilder
    private var usageStrip: some View {
        let kinds = AccountLimitLayout.kinds(
            for: account.provider,
            snapshot: presentation.snapshot
        )
        if presentation.snapshot != nil {
            TimelineView(.periodic(from: now, by: 60)) { context in
                // Cursor has no rolling windows, so `kinds` is empty for it and a
                // window strip would render as an empty row. Its usage is the
                // dollar-spend card instead — the same content the menu-bar card
                // shows, so a refreshed Cursor account is never blank here.
                if account.provider == .cursor {
                    CursorSpendRowView(
                        spend: presentation.snapshot?.cursorSpend,
                        now: context.date
                    )
                    .padding(.top, 6)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(kinds, id: \.self) { kind in
                            LimitRowView(
                                title: AccountLimitLayout.title(for: kind, snapshot: presentation.snapshot),
                                window: presentation.snapshot?.window(for: kind),
                                now: context.date,
                                kind: kind
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            Text("No usage yet — it appears after the first refresh.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .padding(.top, 6)
        }
    }
}

/// The account detail pane's header: provider mark; the label with the IN USE
/// pill and the state badge on one row; under it one line carrying when the
/// account was added and how recently it was used.
///
/// The age used to sit beside the pill (`InUseMarker(style: .full)`), which at
/// the +2 pt type left the label column so little room at the default 720 pt
/// window that "· 1 minute ago" broke over three lines. The age line now spans
/// the full width under the name (≈ 345 pt; the longest English form,
/// "Added Sep 13, 2026 · last used 59 minutes ago", is 330 pt).
struct AccountDetailHeader: View {
    let account: AccountRecord
    let state: AccountViewState
    var activeUsage: ActiveUsage? = nil
    var now: Date = .now

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { account.provider.markAccent }

    /// "Added Jul 13, 2026", plus " · used 1 minute ago" while in use or
    /// " · last used 2 hours ago" in the tail; nothing more when idle.
    static func subtitle(createdAt: Date, phase: InUsePhase, now: Date) -> String {
        let added = "Added \(createdAt.formatted(date: .abbreviated, time: .omitted))"
        switch phase {
        case let .inUse(age):
            return "\(added) · used \(relative(age, at: now))"
        case let .lastUsed(age):
            return "\(added) · last used \(relative(age, at: now))"
        case .none:
            return added
        }
    }

    private static func relative(_ age: TimeInterval, at date: Date) -> String {
        UsageFormatters.relativeReset(date.addingTimeInterval(-age), relativeTo: date)
    }

    var body: some View {
        // One tick drives both the pill and the age line, so they can never
        // disagree about the phase.
        TimelineView(.periodic(from: now, by: 60)) { context in
            content(at: context.date)
        }
    }

    /// The header at one tick. Exposed (rather than inlined into `body`) so
    /// tests can lay it out: a `TimelineView` measures as zero off-screen.
    func content(at date: Date) -> some View {
        let phase = InUsePhase.classify(activeUsage, now: date)
        return HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(Theme.markFillOpacity(colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.4)))
                .frame(width: 34, height: 34)
                .overlay(
                    Text(account.provider.markLetter)
                        .font(Theme.mono(16, bold: true))
                        .foregroundStyle(accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.label)
                        .font(Theme.display(18, .semibold))
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                    InUseMarkerContent(phase: phase, date: date, style: .pillOnly)
                    Spacer(minLength: 8)
                    // A long name truncates before the status badge does.
                    AccountStateBadge(state: state, style: .detailed, now: date)
                        .layoutPriority(1)
                }
                Text(Self.subtitle(createdAt: account.createdAt, phase: phase, now: date))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamFaint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
