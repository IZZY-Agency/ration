import Foundation

/// The popover's card sections. Without a saved Settings order, exactly the
/// old layout: one section per provider in `Provider.allCases` order, API last.
/// With one (the user dragged the single Accounts list), the cards follow it
/// exactly and a section header starts wherever the provider changes.
struct PopoverRun: Equatable, Identifiable {
    enum Kind: Equatable {
        case provider(Provider)
        case api
    }

    /// The run's position: two runs of the same provider can exist.
    let id: Int
    let kind: Kind
    var subscriptions: [AccountPresentation] = []
    var apiIDs: [UUID] = []
}

enum PopoverRuns {
    static func make(
        order: [SidebarAccountOrder.Item]?,
        presentations: [AccountPresentation],
        apiIDs: [UUID],
        orderingPinByProvider: [Provider: UUID]
    ) -> [PopoverRun] {
        guard let order else {
            var runs = AccountGrouping.grouped(presentations, orderingPinByProvider: orderingPinByProvider)
                .enumerated().map { PopoverRun(id: $0.offset, kind: .provider($0.element.provider), subscriptions: $0.element.presentations) }
            if !apiIDs.isEmpty { runs.append(PopoverRun(id: runs.count, kind: .api, apiIDs: apiIDs)) }
            return runs
        }
        let byID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        let known = Set(apiIDs)
        var runs: [PopoverRun] = []
        for item in order {
            switch item {
            case .subscription(let id):
                guard let presentation = byID[id] else { continue }
                let kind = PopoverRun.Kind.provider(presentation.account.provider)
                if runs.last?.kind == kind {
                    runs[runs.count - 1].subscriptions.append(presentation)
                } else {
                    runs.append(PopoverRun(id: runs.count, kind: kind, subscriptions: [presentation]))
                }
            case .api(let id):
                guard known.contains(id) else { continue }
                if runs.last?.kind == .api {
                    runs[runs.count - 1].apiIDs.append(id)
                } else {
                    runs.append(PopoverRun(id: runs.count, kind: .api, apiIDs: [id]))
                }
            }
        }
        // The in-use pin lifts an account to the top of its own run only.
        for index in runs.indices {
            guard case .provider(let provider) = runs[index].kind,
                  let pinned = orderingPinByProvider[provider],
                  let at = runs[index].subscriptions.firstIndex(where: { $0.id == pinned }) else { continue }
            runs[index].subscriptions.insert(runs[index].subscriptions.remove(at: at), at: 0)
        }
        return runs
    }

    /// Every card, top to bottom (the popover's four-card height cap).
    static func cardIDs(_ runs: [PopoverRun]) -> [UUID] {
        runs.flatMap { $0.subscriptions.map(\.id) + $0.apiIDs }
    }
}
