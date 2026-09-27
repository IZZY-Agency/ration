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
    static func merged(subscriptions: [UUID], apis: [UUID], saved: [UUID]) -> [Item] {
        let subscriptionIDs = Set(subscriptions), apiIDs = Set(apis)
        var subscriptionQueue = subscriptions[...], apiQueue = apis[...]
        var result: [Item] = []
        for id in saved {
            if subscriptionIDs.contains(id), let next = subscriptionQueue.popFirst() {
                result.append(.subscription(next))
            } else if apiIDs.contains(id), let next = apiQueue.popFirst() {
                result.append(.api(next))
            }
        }
        let insertAt = result.lastIndex(where: \.isSubscription).map { $0 + 1 } ?? 0
        result.insert(contentsOf: subscriptionQueue.map(Item.subscription), at: insertAt)
        result.append(contentsOf: apiQueue.map(Item.api))
        return result
    }

    /// `List.onMove` semantics: `destination` is an index in the list before the move.
    static func moved(_ items: [Item], from offsets: IndexSet, to destination: Int) -> [Item] {
        let moving = offsets.filter { items.indices.contains($0) }.map { items[$0] }
        var rest = items.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let target = destination - offsets.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(target, 0), rest.count))
        return rest
    }

    /// The one subscription whose relative order a drag changed, with its new
    /// index among subscriptions (`AccountStore.move`'s final index) — nil
    /// when the subscriptions' order is unchanged.
    static func subscriptionMove(before: [Item], after: [Item]) -> (id: UUID, index: Int)? {
        let old = before.filter(\.isSubscription).map(\.id)
        let new = after.filter(\.isSubscription).map(\.id)
        guard old != new else { return nil }
        for (index, id) in new.enumerated() where old.filter({ $0 != id }) == new.filter({ $0 != id }) {
            return (id, index)
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
