import SwiftUI

/// The Settings sidebar: reorderable subscription and API accounts with
/// their two Add buttons, then General, Warm-up and Alerts.
struct SettingsSidebar: View {
    let presentations: [AccountPresentation]
    let activeUsage: [UUID: ActiveUsage]
    @Binding var selection: SettingsSelection?
    let canReorder: Bool
    let onMove: (IndexSet, Int) -> Void
    let onAddAccount: () -> Void
    /// API spend's "API orgs" section. nil — snapshots — hides it.
    var apiSpend: APISpendModel? = nil
    /// Add API Account — `SettingsView` presents the sheet (never the List).
    var onAddAPIAccount: () -> Void = {}
    /// A drag in the one subscription + API list: the list before and after.
    var onMoveMerged: (_ before: [SidebarAccountOrder.Item], _ after: [SidebarAccountOrder.Item]) -> Void = { _, _ in }
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
    ///
    /// Titles resolve in the running language, which is fixed for the
    /// process (a language change relaunches the app).
    static var fixedGroups: [[FixedItem]] { fixedGroups(locale: .current) }

    /// The fixed rows' titles in display order.
    static func fixedTitles(locale: Locale) -> [String] {
        fixedGroups(locale: locale).flatMap { $0.map(\.title) }
    }

    static func fixedGroups(locale: Locale) -> [[FixedItem]] { [
        [
            FixedItem(
                selection: .general,
                title: SettingsSectionTitle.general(locale: locale),
                systemImage: "gearshape",
                accessibilityIdentifier: "generalSettingsItem"
            ),
            FixedItem(
                selection: .warmUp,
                title: LocalizedStringResource.settingsSidebarWarmUp.string(in: locale),
                systemImage: "moon.zzz",
                accessibilityIdentifier: "warmUpSettingsItem"
            ),
        ],
        [
            FixedItem(
                selection: .alerts,
                title: LocalizedStringResource.settingsSidebarAlerts.string(in: locale),
                systemImage: "bell",
                accessibilityIdentifier: "alertsSettingsItem"
            ),
            FixedItem(
                selection: .claudeCode,
                title: LocalizedStringResource.settingsSidebarClaudeCode.string(in: locale),
                systemImage: "terminal",
                accessibilityIdentifier: "claudeCodeSettingsItem"
            ),
        ],
    ] }

    /// Flattened display order, derived — never a second list to maintain.
    static var fixedSelections: [SettingsSelection] {
        fixedGroups.flatMap { $0.map(\.selection) }
    }

    var body: some View {
        List(selection: $selection) {
            Section(SettingsSectionTitle.accounts) {
                if let apiSpend {
                    MergedAccountRows(model: apiSpend, presentations: presentations, canReorder: canReorder, onMove: onMoveMerged) {
                        accountRow($0)
                    }
                } else {
                    accountsList
                }
                addButton(.settingsSidebarAddSubscriptionAccount, identifier: "addSubscriptionAccountButton", action: onAddAccount)
                if apiSpend != nil {
                    addButton(.apiSpendSettingsAdd, identifier: "addAPIAccountButton", action: onAddAPIAccount)
                }
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
    }

    /// An Add row under the accounts: not selectable (no tag), gold like the
    /// old pinned Add Account button.
    private func addButton(_ title: LocalizedStringResource, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "plus")
            }
            .foregroundStyle(Theme.gold)
        }
        .buttonStyle(.borderless)
        .listItemTint(Theme.gold)
        .accessibilityIdentifier(identifier)
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

/// Subscription and API accounts as ONE list, draggable
/// while manual ordering is in effect (Sort by weekly reset off).
private struct MergedAccountRows<Row: View>: View {
    @ObservedObject var model: APISpendModel
    let presentations: [AccountPresentation]
    let canReorder: Bool
    let onMove: (_ before: [SidebarAccountOrder.Item], _ after: [SidebarAccountOrder.Item]) -> Void
    @ViewBuilder let subscriptionRow: (AccountPresentation) -> Row

    var body: some View {
        let items = SidebarAccountOrder.merged(
            subscriptions: presentations.map(\.account.id),
            apis: model.state.orgs.sorted { $0.displayOrder < $1.displayOrder }.map(\.id),
            saved: model.state.sidebarOrder
        )
        ForEach(items, id: \.self) { item in
            switch item {
            case .subscription(let id):
                if let presentation = presentations.first(where: { $0.account.id == id }) {
                    subscriptionRow(presentation).tag(SettingsSelection.account(id))
                }
            case .api(let id):
                if let org = model.org(id) {
                    APIAccountSidebarRow(org: org).tag(SettingsSelection.apiOrg(id))
                }
            }
        }
        .onMove(perform: canReorder ? { onMove(items, SidebarAccountOrder.moved(items, from: $0, to: $1)) } : nil)
    }
}
