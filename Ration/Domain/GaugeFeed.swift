import Foundation

/// One gauge with its owner's identity and the facts its ring-bar hover card
/// shows, captured at the same instant as the value.
struct GaugeEntry: Equatable, Identifiable {
    let id: UUID
    let gauge: MenuBarGauge
    let details: GaugeDetails
}

enum GaugeDetails: Equatable {
    /// A subscription account: its snapshot carries every window and reset.
    case subscription(UsageSnapshot)
    /// An API org with a monthly budget. The presentation is nil while the
    /// org is being removed (the menu bar still draws it then).
    case apiBudget(APIOrgPresentation?, thresholds: ThresholdPair)
    /// A prepaid API account (TypeSafe): the gauge's `credit` carries it.
    case credit

    var isAPIOrg: Bool { if case .apiBudget = self { true } else { false } }
}

/// What `MenuBarController.updateGauges()` gathers on the main actor, with
/// one `now`, so the pure feed never calls back into live state.
struct GaugeFeedInput {
    var accounts: [AccountRecord]
    var snapshots: [UUID: UsageSnapshot]
    var activeUsage: [UUID: ActiveUsage]
    var windowKinds: [Provider: UsageWindowKind]
    var displaysRemaining: Bool
    var apiGauges: [(id: UUID, value: MenuBarGauge)]
    var apiPresentations: [UUID: APIOrgPresentation]
    var apiThresholds: ThresholdPair
    var now: Date
}

/// A provider's gauges in the ring bar.
struct RingBarGroup: Equatable, Identifiable {
    let source: DisplaySource
    let entries: [GaugeEntry]

    var id: DisplaySource { source }
    /// API keys and prepaid API accounts: squares, after the subscriptions.
    var isAPI: Bool { source.gaugeShape == .roundedSquare }
}

/// The menu bar's and the ring bar's gauges from one capture.
enum GaugeFeed {
    static func entries(_ input: GaugeFeedInput) -> [GaugeEntry] {
        let accounts = MenuBarGaugeState.accountGauges(
            accounts: input.accounts,
            activeUsage: input.activeUsage,
            snapshots: { input.snapshots[$0] },
            windowKind: { input.windowKinds[$0] ?? AppSettingsData.defaultMenuBarWindow(for: $0) },
            displaysRemaining: input.displaysRemaining,
            now: input.now
        ).compactMap { pair -> GaugeEntry? in
            guard let snapshot = input.snapshots[pair.id] else { return nil }
            return GaugeEntry(
                id: pair.id,
                gauge: pair.value,
                details: pair.value.credit != nil ? .credit : .subscription(snapshot)
            )
        }
        let orgs = input.apiGauges.map { pair in
            GaugeEntry(
                id: pair.id,
                gauge: pair.value,
                details: .apiBudget(input.apiPresentations[pair.id], thresholds: input.apiThresholds)
            )
        }
        return accounts + orgs
    }

    /// Exactly what the status item drew before the feed existed: the saved
    /// Settings order once dragged, else provider-grouped with API last.
    static func menuBarOrder(_ entries: [GaugeEntry], savedOrder: [SidebarAccountOrder.Item]?) -> [MenuBarGauge] {
        if let savedOrder {
            return SidebarAccountOrder.ordered(entries.map { (id: $0.id, value: $0.gauge) }, by: savedOrder)
        }
        return MenuBarGaugeState.grouped(
            entries.filter { !$0.details.isAPIOrg }.map(\.gauge),
            apiOrgs: entries.filter(\.details.isAPIOrg).map(\.gauge)
        )
    }

    /// The entries one surface shows (Settings › Display › Rings); an id
    /// with no choice saved shows everywhere.
    static func visible(_ entries: [GaugeEntry], on surface: GaugeSurface, shows: (GaugeSurface, UUID) -> Bool) -> [GaugeEntry] {
        entries.filter { shows(surface, $0.id) }
    }

    /// Subscriptions by provider, then API vendors, then prepaid API accounts.
    static let groupOrder: [DisplaySource] =
        Provider.subscriptionCases.map { .subscription($0) }
        + APIVendor.allCases.map { .api($0) }
        + Provider.allCases.filter(\.isAPIAccount).map { .subscription($0) }

    /// Fixed group order; inside a group, the order the menu bar and the
    /// Settings list use once the list has been dragged (`savedOrder`, as
    /// `menuBarOrder` resolves it), else the feed's own.
    static func ringBarGroups(_ entries: [GaugeEntry], savedOrder: [SidebarAccountOrder.Item]?) -> [RingBarGroup] {
        let ordered = savedOrder.map { order in
            SidebarAccountOrder.ordered(entries.map { (id: $0.id, value: $0) }, by: order)
        } ?? entries
        return groupOrder.compactMap { source in
            let members = ordered.filter { $0.gauge.source == source }
            return members.isEmpty ? nil : RingBarGroup(source: source, entries: members)
        }
    }
}
