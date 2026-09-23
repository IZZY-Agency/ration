import SwiftUI

/// One editable cell in the thresholds grid: a provider × window pair.
struct AlertsGridRow: Equatable, Identifiable {
    let provider: Provider
    let window: UsageWindowKind
    var id: String { AppSettingsData.thresholdKey(provider: provider, window: window) }
}

/// Which threshold cells exist, given the providers the user actually has
/// accounts for. Deliberately ragged: Cursor bills by spend and has no rate
/// window, so it contributes no rows here (it gets the spend section
/// instead), and `modelWeekly` (Fable) is Claude-only.
enum AlertsGridModel {
    static func windows(for provider: Provider) -> [UsageWindowKind] {
        switch provider {
        case .claude: [.fiveHour, .weekly, .modelWeekly]
        case .chatGPT: [.fiveHour, .weekly]
        case .cursor: []
        }
    }

    static func rows(for providers: [Provider]) -> [AlertsGridRow] {
        Provider.allCases
            .filter { providers.contains($0) }
            .flatMap { provider in
                windows(for: provider).map { AlertsGridRow(provider: provider, window: $0) }
            }
    }

    /// Every channel cell that can exist, connected or not — including Cursor's
    /// spend row, which contributes no grid row of its own.
    ///
    /// Callers asking "does this setting govern anything" want the full set
    /// rather than `rows(for:)`: a provider the user has not connected yet
    /// still has stored channels, and gating on the connected list would make
    /// the answer flicker as accounts come and go.
    static var allChannelKeys: [String] {
        rows(for: Provider.allCases).map(\.id) + [AppSettingsData.cursorSpendKey]
    }
}

/// The copy used for each rate window across the app's pickers — kept local
/// to Settings rather than a `UsageWindowKind` extension, since it is a
/// presentation concern only this feature area needs.
private func windowLabel(_ window: UsageWindowKind) -> String {
    switch window {
    case .fiveHour: "5-hour"
    case .weekly: "Weekly"
    case .modelWeekly: "Fable"
    }
}

/// The "Alerts" Settings pane: per provider × window percentage thresholds,
/// plus Cursor's separate dollar-spend ladder. Channel checkboxes
/// (notification vs. Drop) are a phase-2 surface — this screen edits
/// `ThresholdPair`/`SpendThresholds` only.
///
/// Gated on `settings.usageAlertsEnabled`: thresholds configured while alerts
/// are off still take effect the moment they're turned back on in General, so
/// disabling the form (rather than hiding it) keeps that connection visible.
struct AlertsDetailView: View {
    @ObservedObject var settings: AppSettings
    /// The providers the user currently has at least one account for —
    /// determines which sections render (the grid is ragged; see
    /// `AlertsGridModel`).
    let providers: [Provider]
    // Field-level, not whole-pair: each commits ONE field against the
    // freshest stored value inside `AppSettings`'s serialized mutation, so a
    // second field's commit can never carry a stale sibling value back over
    // an edit that hasn't round-tripped yet. See `AppSettings.setWarningPercent`.
    let onSetWarningPercent: (Int, Provider, UsageWindowKind) async throws -> Void
    let onSetCriticalPercent: (Int, Provider, UsageWindowKind) async throws -> Void
    let onSetSpendWarningCents: (Int?) async throws -> Void
    let onSetSpendCriticalCents: (Int?) async throws -> Void
    let onSetDropEnabled: (Bool, String) async throws -> Void
    let onSetNotificationEnabled: (Bool, String) async throws -> Void
    let onSetResetLeadDays: (Int, Provider) async throws -> Void
    let onError: (Error) -> Void

    private var rowsByProvider: [(Provider, [AlertsGridRow])] {
        let rows = AlertsGridModel.rows(for: providers)
        return Provider.allCases.compactMap { provider in
            let providerRows = rows.filter { $0.provider == provider }
            return providerRows.isEmpty ? nil : (provider, providerRows)
        }
    }

    var body: some View {
        Form {
            if !settings.usageAlertsEnabled {
                Section {
                    Text("Turn on Usage alerts in General to use these thresholds.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.warn)
                }
            }

            ForEach(rowsByProvider, id: \.0) { provider, providerRows in
                Section(provider.displayName) {
                    ForEach(providerRows) { row in
                        ThresholdFieldsRow(
                            row: row,
                            pair: settings.data.thresholds(provider: row.provider, window: row.window),
                            channels: settings.data.channels(forKey: row.id),
                            onSetWarningPercent: onSetWarningPercent,
                            onSetCriticalPercent: onSetCriticalPercent,
                            onSetDropEnabled: onSetDropEnabled,
                            onSetNotificationEnabled: onSetNotificationEnabled,
                            onError: onError
                        )
                        .id(row.id)
                    }

                    if provider != .cursor {
                        ResetCreditsSettingsRow(
                            provider: provider,
                            leadDays: settings.data.resetExpiryLeadDays(provider: provider),
                            channels: settings.data.channels(forKey: AppSettingsData.resetCreditsKey(provider: provider)),
                            onSetLeadDays: onSetResetLeadDays,
                            onSetDropEnabled: onSetDropEnabled,
                            onSetNotificationEnabled: onSetNotificationEnabled,
                            onError: onError
                        )
                    }
                }
            }

            if providers.contains(.cursor) {
                CursorSpendSection(
                    spend: settings.cursorSpend,
                    channels: settings.data.channels(forKey: AppSettingsData.cursorSpendKey),
                    onSetWarningCents: onSetSpendWarningCents,
                    onSetCriticalCents: onSetSpendCriticalCents,
                    onSetDropEnabled: onSetDropEnabled,
                    onSetNotificationEnabled: onSetNotificationEnabled,
                    onError: onError
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .disabled(!settings.usageAlertsEnabled)
    }
}

/// One provider × window row: warning/critical percent fields that commit on
/// blur, following the `HolidayRow` pattern (`WarmUpDetailView.swift`) — a
/// per-keystroke write would race the store, which only publishes AFTER a
/// successful save.
///
/// `ThresholdPair.init` canonicalises (critical 2...100, warning
/// 1...critical-1), so a value the user typed can come back changed. The
/// fields must reflect that back rather than keep showing the raw entry, or
/// the UI would silently lie about what got saved — `onChange(of: pair)`
/// re-syncs from the freshly published value once the field isn't focused.
private struct ThresholdFieldsRow: View {
    let row: AlertsGridRow
    let pair: ThresholdPair
    let channels: AlertChannels
    let onSetWarningPercent: (Int, Provider, UsageWindowKind) async throws -> Void
    let onSetCriticalPercent: (Int, Provider, UsageWindowKind) async throws -> Void
    let onSetDropEnabled: (Bool, String) async throws -> Void
    let onSetNotificationEnabled: (Bool, String) async throws -> Void
    let onError: (Error) -> Void

    @State private var warningText: String
    @State private var criticalText: String
    @FocusState private var warningFocused: Bool
    @FocusState private var criticalFocused: Bool

    init(
        row: AlertsGridRow,
        pair: ThresholdPair,
        channels: AlertChannels,
        onSetWarningPercent: @escaping (Int, Provider, UsageWindowKind) async throws -> Void,
        onSetCriticalPercent: @escaping (Int, Provider, UsageWindowKind) async throws -> Void,
        onSetDropEnabled: @escaping (Bool, String) async throws -> Void,
        onSetNotificationEnabled: @escaping (Bool, String) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.row = row
        self.pair = pair
        self.channels = channels
        self.onSetWarningPercent = onSetWarningPercent
        self.onSetCriticalPercent = onSetCriticalPercent
        self.onSetDropEnabled = onSetDropEnabled
        self.onSetNotificationEnabled = onSetNotificationEnabled
        self.onError = onError
        _warningText = State(initialValue: String(pair.warningPercent))
        _criticalText = State(initialValue: String(pair.criticalPercent))
    }

    var body: some View {
        LabeledContent(windowLabel(row.window)) {
            HStack(spacing: 4) {
                Text("Warn")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)
                percentField(
                    $warningText,
                    focused: $warningFocused,
                    identifier: "alertWarningField.\(row.id)"
                )
                Text("%")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)

                Text("Crit")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)
                    .padding(.leading, 8)
                percentField(
                    $criticalText,
                    focused: $criticalFocused,
                    identifier: "alertCriticalField.\(row.id)"
                )
                Text("%")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)

                // Where a crossing is delivered. Both are offered: the panel
                // and the notification are independent surfaces, and turning
                // one off must not imply the other.
                ChannelToggles(
                    channels: channels,
                    key: row.id,
                    onSetDropEnabled: onSetDropEnabled,
                    onSetNotificationEnabled: onSetNotificationEnabled,
                    onError: onError
                )
            }
        }
        .onChange(of: pair) { _, newValue in
            if !warningFocused { warningText = String(newValue.warningPercent) }
            if !criticalFocused { criticalText = String(newValue.criticalPercent) }
        }
        .onChange(of: warningFocused) { _, focused in
            if !focused { commitWarning() }
        }
        .onChange(of: criticalFocused) { _, focused in
            if !focused { commitCritical() }
        }
    }

    private func percentField(
        _ text: Binding<String>,
        focused: FocusState<Bool>.Binding,
        identifier: String
    ) -> some View {
        TextField("", text: text)
            .multilineTextAlignment(.trailing)
            .frame(width: 34)
            .focused(focused)
            .onSubmit { focused.wrappedValue = false }
            .accessibilityIdentifier(identifier)
    }

    /// Unparseable or unchanged input reverts the field to the current
    /// canonical value instead of submitting — a stray blur on an empty or
    /// half-typed field must not silently discard the other field's value.
    ///
    /// Submits ONLY the edited field's raw `Int`, never a `ThresholdPair`
    /// composed from the locally-held `pair` — `AppSettings.setWarningPercent`
    /// reads the freshest stored critical value inside its own serialized
    /// mutation, so this can't race a concurrent edit to the sibling field.
    private func commitWarning() {
        guard let value = Int(warningText), value != pair.warningPercent else {
            warningText = String(pair.warningPercent)
            return
        }
        submitWarning(value)
    }

    private func commitCritical() {
        guard let value = Int(criticalText), value != pair.criticalPercent else {
            criticalText = String(pair.criticalPercent)
            return
        }
        submitCritical(value)
    }

    private func submitWarning(_ value: Int) {
        Task {
            do {
                try await onSetWarningPercent(value, row.provider, row.window)
            } catch {
                onError(error)
            }
        }
    }

    private func submitCritical(_ value: Int) {
        Task {
            do {
                try await onSetCriticalPercent(value, row.provider, row.window)
            } catch {
                onError(error)
            }
        }
    }
}

/// "Resets" row: channels for the reset alerts plus how early to warn before
/// a reset expires.
private struct ResetCreditsSettingsRow: View {
    let provider: Provider
    let leadDays: Int
    let channels: AlertChannels
    let onSetLeadDays: (Int, Provider) async throws -> Void
    let onSetDropEnabled: (Bool, String) async throws -> Void
    let onSetNotificationEnabled: (Bool, String) async throws -> Void
    let onError: (Error) -> Void

    var body: some View {
        LabeledContent("Resets") {
            HStack(spacing: 4) {
                Stepper(
                    "Warn \(leadDays) day\(leadDays == 1 ? "" : "s") before expiry",
                    value: Binding(
                        get: { leadDays },
                        set: { value in Task { do { try await onSetLeadDays(value, provider) } catch { onError(error) } } }
                    ),
                    in: AppSettingsData.resetExpiryLeadDaysRange
                )
                .font(Theme.mono(10))
                .accessibilityIdentifier("resetLeadDaysStepper.\(provider.rawValue)")
                ChannelToggles(
                    channels: channels,
                    key: AppSettingsData.resetCreditsKey(provider: provider),
                    onSetDropEnabled: onSetDropEnabled,
                    onSetNotificationEnabled: onSetNotificationEnabled,
                    onError: onError
                )
            }
        }
    }
}

/// Pure dollar-string <-> cents conversion for the Cursor spend fields,
/// pulled out of `CursorSpendSection` (mirroring `CursorSpendRow.text`) so
/// the overflow guard below is unit-testable without hosting a SwiftUI view.
enum CursorSpendFieldParsing {
    static func dollarsText(fromCents cents: Int?) -> String {
        guard let cents else { return "" }
        return String(format: "%.2f", Double(cents) / 100)
    }

    /// A Cursor bill in the hundreds of thousands of dollars is already
    /// absurd; this exists only to keep a pasted huge/garbled figure from
    /// reaching the `Int` conversion below, not to model a real ceiling.
    static let maxDollars: Double = 1_000_000

    /// Tri-state parse: outer `nil` means the text couldn't be read as a
    /// sane dollar figure at all (revert, don't submit — a typo or a pasted
    /// huge number must not silently turn a tier off, and must not reach the
    /// `Int` conversion at all: a finite `Double` at or beyond roughly 9.2e16
    /// overflows `Int` and TRAPS `Int(...)` rather than throwing, so the
    /// range check below has to run BEFORE the conversion, not after).
    /// `.some(nil)` means the field was left blank, which IS the deliberate
    /// way to turn a tier off.
    static func parsedCents(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard
            let dollars = Double(trimmed),
            dollars.isFinite,
            dollars >= 0,
            dollars < maxDollars
        else { return nil }
        return .some(Int((dollars * 100).rounded()))
    }
}

/// Cursor's spend ladder: dollars, not percent — Cursor bills usage-based
/// spend with no denominator (see `AlertThresholds.swift`), so there is
/// nothing to divide by. No default warning/critical value exists either;
/// empty means that tier is off, and this view must never invent a figure.
private struct CursorSpendSection: View {
    let spend: SpendThresholds
    // Field-level, same reasoning as `ThresholdFieldsRow`: composing a whole
    // `SpendThresholds` from the locally-held `spend` would let one field's
    // commit clobber the other's if it hasn't round-tripped yet.
    let channels: AlertChannels
    let onSetWarningCents: (Int?) async throws -> Void
    let onSetCriticalCents: (Int?) async throws -> Void
    let onSetDropEnabled: (Bool, String) async throws -> Void
    let onSetNotificationEnabled: (Bool, String) async throws -> Void
    let onError: (Error) -> Void

    @State private var warningText: String
    @State private var criticalText: String
    @FocusState private var warningFocused: Bool
    @FocusState private var criticalFocused: Bool

    init(
        spend: SpendThresholds,
        channels: AlertChannels,
        onSetWarningCents: @escaping (Int?) async throws -> Void,
        onSetCriticalCents: @escaping (Int?) async throws -> Void,
        onSetDropEnabled: @escaping (Bool, String) async throws -> Void,
        onSetNotificationEnabled: @escaping (Bool, String) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.spend = spend
        self.channels = channels
        self.onSetWarningCents = onSetWarningCents
        self.onSetCriticalCents = onSetCriticalCents
        self.onSetDropEnabled = onSetDropEnabled
        self.onSetNotificationEnabled = onSetNotificationEnabled
        self.onError = onError
        _warningText = State(initialValue: CursorSpendFieldParsing.dollarsText(fromCents: spend.warningCents))
        _criticalText = State(initialValue: CursorSpendFieldParsing.dollarsText(fromCents: spend.criticalCents))
    }

    var body: some View {
        Section("Cursor spend") {
            LabeledContent("Warning") {
                dollarField($warningText, focused: $warningFocused, identifier: "cursorSpendWarningField")
            }
            LabeledContent("Critical") {
                dollarField($criticalText, focused: $criticalFocused, identifier: "cursorSpendCriticalField")
            }
            LabeledContent("Deliver to") {
                ChannelToggles(
                    channels: channels,
                    key: AppSettingsData.cursorSpendKey,
                    onSetDropEnabled: onSetDropEnabled,
                    onSetNotificationEnabled: onSetNotificationEnabled,
                    onError: onError
                )
            }
            Text("Cursor bills by usage-based spend, not a rate window. Leave these empty for no spend alerts.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.creamDim)
        }
        .onChange(of: spend) { _, newValue in
            if !warningFocused { warningText = CursorSpendFieldParsing.dollarsText(fromCents: newValue.warningCents) }
            if !criticalFocused { criticalText = CursorSpendFieldParsing.dollarsText(fromCents: newValue.criticalCents) }
        }
        .onChange(of: warningFocused) { _, focused in
            if !focused { commitWarning() }
        }
        .onChange(of: criticalFocused) { _, focused in
            if !focused { commitCritical() }
        }
    }

    private func dollarField(
        _ text: Binding<String>,
        focused: FocusState<Bool>.Binding,
        identifier: String
    ) -> some View {
        TextField("off", text: text)
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            .focused(focused)
            .onSubmit { focused.wrappedValue = false }
            .accessibilityIdentifier(identifier)
    }

    private func commitWarning() {
        guard let parsed = CursorSpendFieldParsing.parsedCents(warningText) else {
            warningText = CursorSpendFieldParsing.dollarsText(fromCents: spend.warningCents)
            return
        }
        guard parsed != spend.warningCents else { return }
        submitWarning(parsed)
    }

    private func commitCritical() {
        guard let parsed = CursorSpendFieldParsing.parsedCents(criticalText) else {
            criticalText = CursorSpendFieldParsing.dollarsText(fromCents: spend.criticalCents)
            return
        }
        guard parsed != spend.criticalCents else { return }
        submitCritical(parsed)
    }

    private func submitWarning(_ value: Int?) {
        Task {
            do {
                try await onSetWarningCents(value)
            } catch {
                onError(error)
            }
        }
    }

    private func submitCritical(_ value: Int?) {
        Task {
            do {
                try await onSetCriticalCents(value)
            } catch {
                onError(error)
            }
        }
    }
}

/// The two delivery checkboxes shared by every threshold row and by Cursor's
/// spend section.
///
/// Field-level commits, like the percent fields: `notification` and `drop` are
/// two fields of ONE stored value, so each checkbox submits only its own flag
/// and the setter reads the sibling inside its serialized mutation.
private struct ChannelToggles: View {
    let channels: AlertChannels
    let key: String
    let onSetDropEnabled: (Bool, String) async throws -> Void
    let onSetNotificationEnabled: (Bool, String) async throws -> Void
    let onError: (Error) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Notify", isOn: Binding(
                get: { channels.notification },
                set: { submit($0, using: onSetNotificationEnabled) }
            ))
            .accessibilityIdentifier("alertNotifyToggle.\(key)")
            .help("Send a system notification when this is crossed")

            Toggle("Drop", isOn: Binding(
                get: { channels.drop },
                set: { submit($0, using: onSetDropEnabled) }
            ))
            .accessibilityIdentifier("alertDropToggle.\(key)")
            .help("Show this in the menu-bar drop")
        }
        .toggleStyle(.checkbox)
        .font(Theme.mono(10))
        .padding(.leading, 10)
    }

    private func submit(
        _ enabled: Bool,
        using set: @escaping (Bool, String) async throws -> Void
    ) {
        Task {
            do {
                try await set(enabled, key)
            } catch {
                onError(error)
            }
        }
    }
}
