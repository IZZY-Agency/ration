import Foundation

/// The Settings sidebar's ONE list of subscription and API accounts.
/// Only the interleaving is saved here (`APISpendState.sidebarOrder`);
/// each kind's relative order stays with its own store — `AccountStore` for
/// subscriptions (manual order or auto-sort), `displayOrder` for API accounts.
enum SidebarAccountOrder {
    enum Item: Hashable, Sendable {
        case subscription(UUID)
        case api(UUID)

        var id: UUID {
            switch self {
            case .subscription(let id), .api(let id): id
            }
        }

        var isSubscription: Bool { if case .subscription = self { true } else { false } }
    }

    /// Fills the saved list's subscription slots with `subscriptions` and its
    /// API slots with `apis`, each in its own order. New subscriptions join
    /// after the last subscription row, new API accounts go last, and ids
    /// that no longer exist drop out. An empty `saved` lists subscriptions,
    /// then API accounts.
    ///
    /// `apiAccounts`: the subscription-store accounts that are APIs
    /// (TypeSafe, `Provider.isAPIAccount`). They stay `.subscription` items —
    /// their store owns their order and their drags — but sit with the API
    /// accounts: their slots fill from their own queue, and a new one goes
    /// last, after the API orgs, never among the subscriptions.
    static func merged(subscriptions: [UUID], apis: [UUID], saved: [UUID], apiAccounts: Set<UUID> = []) -> [Item] {
        let plain = subscriptions.filter { !apiAccounts.contains($0) }
        let webAPIs = subscriptions.filter { apiAccounts.contains($0) }
        let plainIDs = Set(plain), webAPIIDs = Set(webAPIs), apiIDs = Set(apis)
        var plainQueue = plain[...], webAPIQueue = webAPIs[...], apiQueue = apis[...]
        var result: [Item] = []
        for id in saved {
            if plainIDs.contains(id), let next = plainQueue.popFirst() {
                result.append(.subscription(next))
            } else if webAPIIDs.contains(id), let next = webAPIQueue.popFirst() {
                result.append(.subscription(next))
            } else if apiIDs.contains(id), let next = apiQueue.popFirst() {
                result.append(.api(next))
            }
        }
        let insertAt = result.lastIndex { item in
            if case .subscription(let id) = item { plainIDs.contains(id) } else { false }
        }.map { $0 + 1 } ?? 0
        result.insert(contentsOf: plainQueue.map(Item.subscription), at: insertAt)
        result.append(contentsOf: apiQueue.map(Item.api))
        result.append(contentsOf: webAPIQueue.map(Item.subscription))
        return result
    }

    /// The accounts `merged` places with the API accounts.
    static func apiAccountIDs(_ presentations: [AccountPresentation]) -> Set<UUID> {
        Set(presentations.filter { $0.account.provider.isAPIAccount }.map(\.account.id))
    }

    /// `List.onMove` semantics: `destination` is an index in the list before the move.
    static func moved(_ items: [Item], from offsets: IndexSet, to destination: Int) -> [Item] {
        let moving = offsets.filter { items.indices.contains($0) }.map { items[$0] }
        var rest = items.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let target = destination - offsets.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(target, 0), rest.count))
        return rest
    }

    /// The one subscription-store account whose relative order a drag
    /// changed, with its destination in `store` (the account store's order,
    /// `AccountStore.move`'s final index) — nil when no relative order did.
    ///
    /// Compared within each kind (`apiAccounts` or not), because `merged`
    /// fills each kind's slots from its own queue: the list shows TypeSafe
    /// after the API orgs while the store may keep it between subscriptions,
    /// so a position among the LIST's subscriptions means nothing in the
    /// store. The dragged account lands next to its same-kind neighbour.
    static func subscriptionMove(
        before: [Item], after: [Item], store: [UUID], apiAccounts: Set<UUID> = []
    ) -> (id: UUID, index: Int)? {
        for isAPI in [false, true] {
            let old = before.filter(\.isSubscription).map(\.id).filter { apiAccounts.contains($0) == isAPI }
            let new = after.filter(\.isSubscription).map(\.id).filter { apiAccounts.contains($0) == isAPI }
            guard old != new else { continue }
            guard let (position, id) = new.enumerated().first(where: { _, id in
                old.filter { $0 != id } == new.filter { $0 != id }
            }) else { return nil }
            let rest = store.filter { $0 != id }
            if position + 1 < new.count, let next = rest.firstIndex(of: new[position + 1]) {
                return (id, next)
            }
            if position > 0, let previous = rest.firstIndex(of: new[position - 1]) {
                return (id, previous + 1)
            }
            return nil
        }
        return nil
    }

    /// Values in the list's order (stable; ids the list lacks keep their place after).
    static func ordered<Value>(_ entries: [(id: UUID, value: Value)], by order: [Item]) -> [Value] {
        let position = Dictionary(order.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated()
            .sorted { (position[$0.element.id] ?? Int.max, $0.offset) < (position[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element.value)
    }
}
