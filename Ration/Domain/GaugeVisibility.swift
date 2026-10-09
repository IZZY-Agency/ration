import Foundation

/// Where a gauge can show.
enum GaugeSurface: String, CaseIterable, Sendable {
    case menuBar
    case ringBar
}

/// One account's choice of surfaces (Settings › Display › Rings). Both on
/// unless the user unticked one; an unreadable field reads as on.
struct GaugeVisibility: Codable, Equatable, Sendable {
    var menuBar = true
    var ringBar = true

    init(menuBar: Bool = true, ringBar: Bool = true) {
        self.menuBar = menuBar
        self.ringBar = ringBar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBar = ((try? container.decodeIfPresent(Bool.self, forKey: .menuBar)) ?? nil) ?? true
        ringBar = ((try? container.decodeIfPresent(Bool.self, forKey: .ringBar)) ?? nil) ?? true
    }

    func shows(_ surface: GaugeSurface) -> Bool {
        switch surface {
        case .menuBar: menuBar
        case .ringBar: ringBar
        }
    }

    mutating func set(_ surface: GaugeSurface, _ shown: Bool) {
        switch surface {
        case .menuBar: menuBar = shown
        case .ringBar: ringBar = shown
        }
    }

    var showsEverywhere: Bool { menuBar && ringBar }
}

/// One row of Settings › Display › Rings.
struct RingsGridRow: Equatable, Identifiable {
    enum State: Equatable {
        case available(menuBar: Bool, ringBar: Bool)
        /// Cursor: usage-based, no limit for a gauge to fill.
        case noLimit
        /// Paused accounts show nowhere until resumed.
        case paused
        /// An API org without a monthly budget has no gauge.
        case noBudget
    }

    let id: UUID
    let source: DisplaySource
    let label: String
    let state: State
}

struct RingsGridGroup: Equatable, Identifiable {
    let source: DisplaySource
    let rows: [RingsGridRow]
    var id: DisplaySource { source }
}

/// The Rings grid, grouped like the ring bar (`GaugeFeed.groupOrder`):
/// accounts in the order given (the Settings list's), API orgs by
/// `displayOrder`.
enum RingsGridModel {
    static func groups(
        accounts: [AccountRecord],
        apiOrgs: [APIOrgRecord],
        shows: (GaugeSurface, UUID) -> Bool
    ) -> [RingsGridGroup] {
        func available(_ id: UUID) -> RingsGridRow.State {
            .available(menuBar: shows(.menuBar, id), ringBar: shows(.ringBar, id))
        }
        let accountRows = accounts.map { account -> RingsGridRow in
            let state: RingsGridRow.State = account.isPaused
                ? .paused
                : account.provider == .cursor ? .noLimit : available(account.id)
            return RingsGridRow(id: account.id, source: .subscription(account.provider), label: account.label, state: state)
        }
        let orgRows = apiOrgs.sorted { $0.displayOrder < $1.displayOrder }.map { org -> RingsGridRow in
            let state: RingsGridRow.State = org.isPaused
                ? .paused
                : org.monthlyBudgetCents == nil ? .noBudget : available(org.id)
            return RingsGridRow(id: org.id, source: .api(org.vendor), label: org.label, state: state)
        }
        let rows = accountRows + orgRows
        return GaugeFeed.groupOrder.compactMap { source in
            let members = rows.filter { $0.source == source }
            return members.isEmpty ? nil : RingsGridGroup(source: source, rows: members)
        }
    }
}
