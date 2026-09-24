import SwiftUI

/// The Settings sidebar: reorderable accounts, a pinned General item, and an
/// always-visible Add Account button.
struct SettingsSidebar: View {
    let presentations: [AccountPresentation]
    let activeUsage: [UUID: ActiveUsage]
    @Binding var selection: SettingsSelection?
    let canReorder: Bool
    let onMove: (IndexSet, Int) -> Void
    let onAddAccount: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// One non-account sidebar row.
    struct FixedItem: Identifiable, Equatable {
        let selection: SettingsSelection
        let title: String
        let systemImage: String
        let accessibilityIdentifier: String
        var id: SettingsSelection { selection }
    }

    /// Column widths. The longest real row, "ChatGPT 20x" (Space Grotesk
    /// Medium 15, 93.5 pt) plus the IN USE pill (55.2 pt) plus the row's fixed
    /// parts and the list's own insets, needs ≈255 pt; `SettingsLayoutTests`
    /// measures it with the bundled fonts. 210 cut it to "ChatG…"/"IN U…".
    static let minColumnWidth: CGFloat = 256
    static let idealColumnWidth: CGFloat = 270
    static let maxColumnWidth: CGFloat = 320

    /// The non-account rows, grouped exactly as the sidebar renders them.
    ///
    /// `body` renders FROM this — it does not restate the rows — so a test
    /// asserting on it is really asserting on what ships. The previous shape
    /// (a bare `[SettingsSelection]` alongside a hand-written row list in
    /// `body`) let the two drift: deleting the Alerts row from `body` left
    /// every test green.
    ///
    /// Alerts gets its own group rather than joining General/Warm-up: it
    /// carries a growing sub-screen (thresholds now, channels later) rather
    /// than a single toggle, and deserves the visual separation.
    static let fixedGroups: [[FixedItem]] = [
        [
            FixedItem(
                selection: .general,
                title: "General",
                systemImage: "gearshape",
                accessibilityIdentifier: "generalSettingsItem"
            ),
            FixedItem(
                selection: .warmUp,
                title: "Warm-up",
                systemImage: "moon.zzz",
                accessibilityIdentifier: "warmUpSettingsItem"
            ),
        ],
        [
            FixedItem(
                selection: .alerts,
                title: "Alerts",
                systemImage: "bell",
                accessibilityIdentifier: "alertsSettingsItem"
            ),
        ],
    ]

    /// Flattened display order, derived — never a second list to maintain.
    static var fixedSelections: [SettingsSelection] {
        fixedGroups.flatMap { $0.map(\.selection) }
    }

    var body: some View {
        List(selection: $selection) {
            Section(SettingsSectionTitle.accounts) {
                accountsList
            }

            ForEach(Array(Self.fixedGroups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item.selection)
                            .accessibilityIdentifier(item.accessibilityIdentifier)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onAddAccount) {
                Label("Add Account", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    /// Reorder is only offered when manual ordering is in effect; while
    /// auto-sort is on, `.onMove` is omitted so the list can't be dragged.
    @ViewBuilder
    private var accountsList: some View {
        if canReorder {
            ForEach(presentations) { presentation in
                accountRow(presentation)
                    .tag(SettingsSelection.account(presentation.account.id))
            }
            .onMove(perform: onMove)
        } else {
            ForEach(presentations) { presentation in
                accountRow(presentation)
                    .tag(SettingsSelection.account(presentation.account.id))
            }
        }
    }

    private func accountRow(_ presentation: AccountPresentation) -> some View {
        let account = presentation.account
        let accent: Color = account.provider.markAccent
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(Theme.markFillOpacity(colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(0.4)))
                .frame(width: 22, height: 22)
                .overlay(
                    Text(account.provider.markLetter)
                        .font(Theme.mono(13, bold: true))
                        .foregroundStyle(accent)
                )
            Text(account.label)
                .font(Theme.display(15, .medium))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
            if account.isPaused {
                Text("PAUSED")
                    .font(Theme.mono(10, bold: true))
                    .tracking(0.5)
                    .foregroundStyle(Theme.creamDim)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line))
            }
            Spacer(minLength: 6)
            InUseMarker(activeUsage: activeUsage[account.id], style: .pillOnly)
            Circle()
                .fill(AccountStateBadge.tint(for: presentation.state))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }
}
