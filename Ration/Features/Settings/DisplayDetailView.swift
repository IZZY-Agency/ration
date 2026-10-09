import SwiftUI

/// Settings › Display: how the popover lays out accounts, how gauges read,
/// and where each gauge shows (menu bar, ring bar).
struct DisplayDetailView: View {
    @ObservedObject var settings: AppSettings
    /// Subscription accounts in the Settings list's order, and the API orgs,
    /// for the Rings grid.
    let accounts: [AccountRecord]
    let apiOrgs: [APIOrgRecord]
    let onSetPopoverLayout: (PopoverLayout) -> Void
    let onSetSortByWeeklyReset: (Bool) -> Void
    let onSetShowInUseInMenuBar: (Bool) -> Void
    let onSetMenuBarWindow: (Provider, UsageWindowKind) -> Void
    let onSetMenuBarDisplaysRemaining: (Bool) -> Void
    var onSetRingBarEnabled: (Bool) -> Void = { _ in }
    var onSetRingBarStyle: (RingBarStyle) -> Void = { _ in }
    var onSetRingBarEdge: (RingBarEdge) -> Void = { _ in }
    var onSetRingBarHidesAtEdge: (Bool) -> Void = { _ in }
    var onSetRingBarScale: (Double) -> Void = { _ in }
    var onSetShows: (GaugeSurface, UUID, Bool) -> Void = { _, _, _ in }

    var body: some View {
        Form {
            Section(SettingsSectionTitle.popover) {
                Picker(
                    "Layout",
                    selection: Self.layoutBinding(settings: settings, onSet: onSetPopoverLayout)
                ) {
                    ForEach(PopoverLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("popoverLayoutPicker")

                Text("Focus shows the account you're on as one number, where to go next, and the rest in a line. Applies to the popover and the ⌥⌘U window.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)

                Toggle(
                    "Sort by soonest reset",
                    isOn: Binding(
                        get: { settings.sortByWeeklyReset },
                        set: { enabled in
                            onSetSortByWeeklyReset(enabled)
                        }
                    )
                )
                .accessibilityIdentifier("sortByWeeklyResetToggle")

                Text("Orders accounts within each provider; manual drag is disabled while on.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
            }

            if Self.showsSharedGaugeRows(settings) {
                Section(SettingsSectionTitle.gauges) {
                    Picker(
                        "Show",
                        selection: Binding(
                            get: { settings.menuBarDisplaysRemaining },
                            set: { value in
                                onSetMenuBarDisplaysRemaining(value)
                            }
                        )
                    ) {
                        Text("Used %").tag(false)
                        Text("Remaining %").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("menuBarDisplayModePicker")

                    Picker(
                        "Claude window",
                        selection: Binding(
                            get: { settings.menuBarWindow(for: .claude) },
                            set: { kind in
                                onSetMenuBarWindow(.claude, kind)
                            }
                        )
                    ) {
                        Text(verbatim: SettingsCopy.windowLabel(.fiveHour)).tag(UsageWindowKind.fiveHour)
                        Text(verbatim: SettingsCopy.windowLabel(.weekly)).tag(UsageWindowKind.weekly)
                        Text(verbatim: SettingsCopy.windowLabel(.modelWeekly)).tag(UsageWindowKind.modelWeekly)
                    }
                    .accessibilityIdentifier("menuBarClaudeWindowPicker")

                    Text("Fable applies to Max accounts; accounts without the selected window fall back to their finest one.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)

                    LabeledContent("ChatGPT window") {
                        Text(verbatim: SettingsCopy.windowLabel(.weekly))
                            .font(Theme.mono(14))
                            .foregroundStyle(Theme.creamDim)
                    }
                    .accessibilityIdentifier("menuBarChatGPTWindowRow")

                    Text("ChatGPT reports only a weekly limit.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)

                    Text("Apply to the menu-bar rings and the ring bar.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
            }

            Section(SettingsSectionTitle.menuBar) {
                Toggle(
                    "Show usage rings in the menu bar",
                    isOn: Binding(
                        get: { settings.showInUseInMenuBar },
                        set: { enabled in
                            onSetShowInUseInMenuBar(enabled)
                        }
                    )
                )
                .accessibilityIdentifier("showInUseInMenuBarToggle")

                Text("A ring per account, filled by the window chosen under Gauges, in place of the menu bar icon (it comes back when nothing shows); accounts currently in use get a green center dot. API accounts with a monthly budget show a square. Hover for exact values. Cursor has no rate windows and never shows.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
            }

            Section(SettingsSectionTitle.ringBar) {
                Toggle(
                    "Show the ring bar",
                    isOn: Binding(
                        get: { settings.ringBarEnabled },
                        set: { onSetRingBarEnabled($0) }
                    )
                )
                .accessibilityIdentifier("ringBarToggle")

                Text("The menu bar's gauges in a glass bar at the edge of the screen, grouped by provider. It never takes focus from the app you are in.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)

                if settings.ringBarEnabled {
                    Picker(
                        "Style",
                        selection: Binding(
                            get: { settings.ringBarStyle },
                            set: { onSetRingBarStyle($0) }
                        )
                    ) {
                        ForEach(RingBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("ringBarStylePicker")

                    Picker(
                        "Position",
                        selection: Binding(
                            get: { settings.ringBarEdge },
                            set: { onSetRingBarEdge($0) }
                        )
                    ) {
                        ForEach(RingBarEdge.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("ringBarEdgePicker")

                    RingBarSizeSlider(scale: settings.ringBarScale, onCommit: onSetRingBarScale)

                    Text("Or drag empty glass on the bar, like the Dock.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)

                    Toggle(
                        "Hide until the pointer reaches the edge",
                        isOn: Binding(
                            get: { settings.ringBarHidesAtEdge },
                            set: { onSetRingBarHidesAtEdge($0) }
                        )
                    )
                    .accessibilityIdentifier("ringBarHidesAtEdgeToggle")

                    Text("Push the pointer against that edge to bring the bar back. A Dock that hides on the same edge comes back with it.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
            }

            Section(SettingsSectionTitle.rings) {
                RingsGrid(
                    groups: RingsGridModel.groups(accounts: accounts, apiOrgs: apiOrgs, shows: settings.shows),
                    onSet: onSetShows
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
    }

    /// Show and the window pickers serve the menu-bar rings AND the ring
    /// bar, so they stay while either is on.
    static func showsSharedGaugeRows(_ settings: AppSettings) -> Bool {
        settings.wantsGauges
    }

    /// The Layout picker's selection: reads the published setting, writes
    /// only through the callback (which persists via `AppModel`).
    static func layoutBinding(
        settings: AppSettings,
        onSet: @escaping (PopoverLayout) -> Void
    ) -> Binding<PopoverLayout> {
        Binding(
            get: { settings.popoverLayout },
            set: { layout in
                onSet(layout)
            }
        )
    }
}

/// The ring bar's Size: a slider that saves when you let go (the bar
/// follows the saved value; dragging the bar itself is live). The thumb keeps
/// the released value until the save comes back, so it never jumps back.
struct RingBarSizeSlider: View {
    let scale: Double
    let onCommit: (Double) -> Void
    @State private var draft: Double?
    @State private var editing = false

    var body: some View {
        LabeledContent("Size") {
            Slider(
                value: Binding(get: { draft ?? scale }, set: { draft = $0 }),
                in: AppSettingsData.ringBarScaleRange,
                step: 0.05,
                onEditingChanged: { isEditing in
                    editing = isEditing
                    guard !isEditing, let value = draft else { return }
                    onCommit(value)
                }
            )
            .frame(maxWidth: 220)
            // A saved size (this slider's, or a drag on the bar) replaces
            // the draft — unless the thumb is being moved right now.
            .onChange(of: scale) { _, _ in
                if !editing { draft = nil }
            }
            .accessibilityValue(Text(verbatim: UsageFormatters.compactPercent(Int(((draft ?? scale) * 100).rounded()))))
        }
        .accessibilityIdentifier("ringBarSizeSlider")
    }
}
