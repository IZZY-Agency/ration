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
    var now: Date = .now
    let onReauthenticate: () -> Void
    let onRemove: () -> Void
    let onSetAutoStart: (Bool) -> Void
    let onSetBillingRenewalDay: (Int?) -> Void
    let onSetPaused: (Bool) -> Void
    let onDebugSend: () -> Void

    @FocusState private var labelFocused: Bool
    @StateObject private var labelAutosave: LabelAutosave

    init(
        presentation: AccountPresentation,
        activeUsage: ActiveUsage? = nil,
        now: Date = .now,
        onRename: @escaping @MainActor (String) async throws -> Void,
        onRenameError: @escaping @MainActor (Error?) -> Void,
        onReauthenticate: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onSetAutoStart: @escaping (Bool) -> Void,
        onSetBillingRenewalDay: @escaping (Int?) -> Void,
        onSetPaused: @escaping (Bool) -> Void,
        onDebugSend: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.activeUsage = activeUsage
        self.now = now
        self.onReauthenticate = onReauthenticate
        self.onRemove = onRemove
        self.onSetAutoStart = onSetAutoStart
        self.onSetBillingRenewalDay = onSetBillingRenewalDay
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

    private var accent: Color {
        account.provider.markAccent
    }

    var body: some View {
        Form {
            Section { header } footer: { usageStrip }

            Section("IDENTITY") {
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
                Section("AUTOMATION") {
                    Toggle(
                        "Auto-start 5h window",
                        isOn: Binding(
                            get: { account.autoStartFiveHour },
                            set: { onSetAutoStart($0) }
                        )
                    )
                    .accessibilityIdentifier("autoStartToggle")
                    .disabled(pauseState.disablesAutomationAndBilling)
                    Text("Sends a short message when the 5h window resets, so its countdown starts right away.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.creamDim)
                    #if DEBUG
                    Button("Send test keep-alive now (debug)", action: onDebugSend)
                        .font(Theme.mono(10))
                        .disabled(pauseState.disablesAutomationAndBilling)
                    #endif
                }
            }

            if account.provider != .cursor,
               let items = presentation.snapshot?.resetCredits?.unexpired(at: now), !items.isEmpty {
                Section("RESETS") {
                    ForEach(items, id: \.id) { credit in
                        LabeledContent(credit.title ?? "Usage-limit reset") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("×\(credit.count) · expires \(credit.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Theme.mono(10))
                                    .monospacedDigit()
                                if let usable = credit.usableNow {
                                    Text(usable ? "usable now" : "not usable yet")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(Theme.creamDim)
                                }
                            }
                        }
                    }
                    Text("Use a reset on the provider's usage page. Ration only shows them.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.creamDim)
                }
            }

            // Hidden for providers the Billing-cycle window excludes: Cursor
            // reports its cycle natively on the account card, so a renewal day
            // entered here would feed nothing. Any value already stored on such
            // an account is retained untouched — it is simply not consulted.
            if BillingCycleEligibility.supports(account.provider) {
            Section("BILLING") {
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
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)
            }
            }

            Section("SESSION") {
                Button(pauseState.buttonTitle) { onSetPaused(!account.isPaused) }
                    .accessibilityIdentifier("pauseResumeButton")
                if let explanation = pauseState.explanation {
                    Text(explanation)
                        .font(Theme.mono(10))
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
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.4)))
                .frame(width: 34, height: 34)
                .overlay(
                    Text(account.provider.markLetter)
                        .font(Theme.mono(14, bold: true))
                        .foregroundStyle(accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.cream)
                Text("Added \(account.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamFaint)
            }
            Spacer(minLength: 8)
            InUseMarker(activeUsage: activeUsage, style: .full, now: now)
            AccountStateBadge(state: presentation.state, style: .detailed, now: now)
        }
        .padding(.vertical, 4)
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
                                now: context.date
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            Text("No usage yet — it appears after the first refresh.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.creamDim)
                .padding(.top, 6)
        }
    }
}
