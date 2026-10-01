import Foundation

/// The popover's card sections. Without a saved Settings order, exactly the
/// old layout: one section per provider in `Provider.allCases` order, API last.
/// With one (the user dragged the single Accounts list), the cards follow it
/// exactly and a section header starts wherever the provider changes.
///
/// API-type subscription-store accounts (TypeSafe, `Provider.isAPIAccount`)
/// are cards of the API section, never a provider section of their own.
struct PopoverRun: Equatable, Identifiable {
    enum Kind: Equatable {
        case provider(Provider)
        case api
    }

    /// One card of an API run: an API org (by id) or an API-type account.
    enum APIEntry: Equatable {
        case org(UUID)
        case account(AccountPresentation)

        var id: UUID {
            switch self {
            case .org(let id): id
            case .account(let presentation): presentation.id
            }
        }
    }

    /// The run's position: two runs of the same provider can exist.
    let id: Int
    let kind: Kind
    var subscriptions: [AccountPresentation] = []
    var apiEntries: [APIEntry] = []

    /// The API org ids among `apiEntries`, in order.
    var apiIDs: [UUID] {
        apiEntries.compactMap { if case .org(let id) = $0 { id } else { nil } }
    }
}

enum PopoverRuns {
    static func make(
        order: [SidebarAccountOrder.Item]?,
        presentations: [AccountPresentation],
        apiIDs: [UUID],
        orderingPinByProvider: [Provider: UUID]
    ) -> [PopoverRun] {
        guard let order else {
            let subscriptions = presentations.filter { !$0.account.provider.isAPIAccount }
            let apiAccounts = presentations.filter { $0.account.provider.isAPIAccount }
            var runs = AccountGrouping.grouped(subscriptions, orderingPinByProvider: orderingPinByProvider)
                .enumerated().map { PopoverRun(id: $0.offset, kind: .provider($0.element.provider), subscriptions: $0.element.presentations) }
            let entries = apiIDs.map(PopoverRun.APIEntry.org) + apiAccounts.map(PopoverRun.APIEntry.account)
            if !entries.isEmpty { runs.append(PopoverRun(id: runs.count, kind: .api, apiEntries: entries)) }
            return runs
        }
        let byID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        let known = Set(apiIDs)
        var runs: [PopoverRun] = []
        func appendAPI(_ entry: PopoverRun.APIEntry) {
            if runs.last?.kind == .api {
                runs[runs.count - 1].apiEntries.append(entry)
            } else {
                runs.append(PopoverRun(id: runs.count, kind: .api, apiEntries: [entry]))
            }
        }
        for item in order {
            switch item {
            case .subscription(let id):
                guard let presentation = byID[id] else { continue }
                if presentation.account.provider.isAPIAccount {
                    appendAPI(.account(presentation))
                    continue
                }
                let kind = PopoverRun.Kind.provider(presentation.account.provider)
                if runs.last?.kind == kind {
                    runs[runs.count - 1].subscriptions.append(presentation)
                } else {
                    runs.append(PopoverRun(id: runs.count, kind: kind, subscriptions: [presentation]))
                }
            case .api(let id):
                guard known.contains(id) else { continue }
                appendAPI(.org(id))
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
        runs.flatMap { $0.subscriptions.map(\.id) + $0.apiEntries.map(\.id) }
    }
}
