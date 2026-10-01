import XCTest
@testable import Ration

/// Subscription and API accounts are ONE draggable list in
/// Settings. The interleaving is saved; each kind keeps its own store's order.
final class SidebarAccountOrderTests: XCTestCase {
    private typealias Item = SidebarAccountOrder.Item
    private let s1 = UUID(), s2 = UUID(), s3 = UUID(), a1 = UUID(), a2 = UUID()

    func testFirstRunListsSubscriptionsThenAPIAccounts() {
        XCTAssertEqual(SidebarAccountOrder.merged(subscriptions: [s1, s2], apis: [a1], saved: []),
                       [.subscription(s1), .subscription(s2), .api(a1)])
    }

    func testSavedInterleavingIsKept() {
        let saved = [s1, a1, s2, a2]
        XCTAssertEqual(SidebarAccountOrder.merged(subscriptions: [s1, s2], apis: [a1, a2], saved: saved),
                       [.subscription(s1), .api(a1), .subscription(s2), .api(a2)])
    }

    /// The account store owns the subscriptions' relative order (auto-sort,
    /// a move elsewhere): its order fills the subscription slots.
    func testSubscriptionOrderComesFromTheStore() {
        let saved = [s1, a1, s2]
        XCTAssertEqual(SidebarAccountOrder.merged(subscriptions: [s2, s1], apis: [a1], saved: saved),
                       [.subscription(s2), .api(a1), .subscription(s1)])
    }

    func testNewAccountsJoinTheirKindAndRemovedOnesDrop() {
        let saved = [a1, s1, UUID()]   // a removed account's id lingers
        XCTAssertEqual(SidebarAccountOrder.merged(subscriptions: [s1, s3], apis: [a1, a2], saved: saved),
                       [.api(a1), .subscription(s1), .subscription(s3), .api(a2)])
    }

    func testMoveUsesListOnMoveSemantics() {
        let items: [Item] = [.subscription(s1), .subscription(s2), .api(a1)]
        XCTAssertEqual(SidebarAccountOrder.moved(items, from: IndexSet(integer: 2), to: 0),
                       [.api(a1), .subscription(s1), .subscription(s2)])
        XCTAssertEqual(SidebarAccountOrder.moved(items, from: IndexSet(integer: 0), to: 3),
                       [.subscription(s2), .api(a1), .subscription(s1)])
    }

    /// A drag that changes the subscriptions' relative order becomes one
    /// AccountStore move (final index among subscriptions); an API-only
    /// drag, or one past API rows only, needs none.
    func testSubscriptionMoveIsDerivedFromTheDrag() {
        let before: [Item] = [.subscription(s1), .api(a1), .subscription(s2)]
        let after = SidebarAccountOrder.moved(before, from: IndexSet(integer: 2), to: 0)
        let store = [s1, s2]
        XCTAssertEqual(SidebarAccountOrder.subscriptionMove(before: before, after: after, store: store)?.id, s2)
        XCTAssertEqual(SidebarAccountOrder.subscriptionMove(before: before, after: after, store: store)?.index, 0)
        let apiOnly = SidebarAccountOrder.moved(before, from: IndexSet(integer: 1), to: 0)
        XCTAssertNil(SidebarAccountOrder.subscriptionMove(before: before, after: apiOnly, store: store))
        let pastAPI = SidebarAccountOrder.moved(before, from: IndexSet(integer: 0), to: 2)
        XCTAssertNil(SidebarAccountOrder.subscriptionMove(before: before, after: pastAPI, store: store), "s1 still precedes s2")
    }

    /// Files written before the combined order existed still load.
    func testStateWithoutASidebarOrderStillDecodes() throws {
        var current = APISpendState()
        current.memory[UUID()] = BudgetAlertMemory()
        current.pendingKeyDeletions = [UUID()]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "sidebarOrder"), "the field exists today")
        let old = try JSONSerialization.data(withJSONObject: json)
        let state = try JSONDecoder().decode(APISpendState.self, from: old)
        XCTAssertEqual(state.sidebarOrder, [])
        XCTAssertEqual(state.memory.count, 1)
        XCTAssertEqual(state.pendingKeyDeletions, current.pendingKeyDeletions)
    }

    // MARK: API-type accounts (TypeSafe)

    /// TypeSafe is an API: by default it sits after the API orgs, never
    /// among the subscriptions.
    func testAnAPIAccountListsAfterTheAPIOrgs() {
        let typeSafe = UUID()
        XCTAssertEqual(
            SidebarAccountOrder.merged(subscriptions: [s1, typeSafe, s2], apis: [a1], saved: [], apiAccounts: [typeSafe]),
            [.subscription(s1), .subscription(s2), .api(a1), .subscription(typeSafe)]
        )
    }

    /// Its slot fills from its own queue: a subscription the store orders
    /// after it never lands in the API region, and TypeSafe never among the
    /// subscriptions.
    func testAnAPIAccountsSlotFillsFromItsOwnQueue() {
        let typeSafe = UUID()
        let saved = [s1, s2, a1, typeSafe]
        XCTAssertEqual(
            SidebarAccountOrder.merged(subscriptions: [s1, typeSafe, s2], apis: [a1], saved: saved, apiAccounts: [typeSafe]),
            [.subscription(s1), .subscription(s2), .api(a1), .subscription(typeSafe)]
        )
    }

    /// A new TypeSafe account joins at the end even with a saved order;
    /// a new subscription still joins after the last subscription row.
    func testNewAccountsOfEachKindJoinTheirRegion() {
        let typeSafe = UUID()
        let saved = [s1, a1]
        XCTAssertEqual(
            SidebarAccountOrder.merged(subscriptions: [s1, typeSafe, s2], apis: [a1], saved: saved, apiAccounts: [typeSafe]),
            [.subscription(s1), .subscription(s2), .api(a1), .subscription(typeSafe)]
        )
    }

    /// Dragged above the subscriptions, it stays where the user put it.
    func testADraggedAPIAccountKeepsItsPlace() {
        let typeSafe = UUID()
        let saved = [typeSafe, s1, a1]
        XCTAssertEqual(
            SidebarAccountOrder.merged(subscriptions: [typeSafe, s1], apis: [a1], saved: saved, apiAccounts: [typeSafe]),
            [.subscription(typeSafe), .subscription(s1), .api(a1)]
        )
    }

    /// The store keeps TypeSafe accounts between subscriptions while the list
    /// shows them after the API orgs: a drag must land in the STORE next to
    /// its same-kind neighbour, or the list snaps back.
    func testADragAmongTypeSafeAccountsMovesThemInTheStore() {
        let t1 = UUID(), t2 = UUID()
        let store = [s1, t1, s2, t2]
        let apiAccounts: Set<UUID> = [t1, t2]
        let before = SidebarAccountOrder.merged(subscriptions: store, apis: [a1], saved: [], apiAccounts: apiAccounts)
        XCTAssertEqual(before, [.subscription(s1), .subscription(s2), .api(a1), .subscription(t1), .subscription(t2)])
        let after = SidebarAccountOrder.moved(before, from: IndexSet(integer: 4), to: 3)   // t2 above t1
        let move = SidebarAccountOrder.subscriptionMove(before: before, after: after, store: store, apiAccounts: apiAccounts)
        XCTAssertEqual(move?.id, t2)
        XCTAssertEqual(move?.index, 1, "just before t1 in the store")

        var moved = store
        moved.removeAll { $0 == t2 }
        moved.insert(t2, at: move!.index)
        let shown = SidebarAccountOrder.merged(subscriptions: moved, apis: [a1], saved: after.map(\.id), apiAccounts: apiAccounts)
        XCTAssertEqual(shown, after, "the list keeps the drag")
    }

    /// A subscription dragged among subscriptions still lands by its
    /// same-kind neighbour when a TypeSafe account sits between them.
    func testASubscriptionDragSkipsInterleavedTypeSafeAccounts() {
        let t1 = UUID()
        let store = [s1, t1, s2]
        let before = SidebarAccountOrder.merged(subscriptions: store, apis: [a1], saved: [], apiAccounts: [t1])
        let after = SidebarAccountOrder.moved(before, from: IndexSet(integer: 1), to: 0)   // s2 above s1
        let move = SidebarAccountOrder.subscriptionMove(before: before, after: after, store: store, apiAccounts: [t1])
        XCTAssertEqual(move?.id, s2)
        XCTAssertEqual(move?.index, 0)
        XCTAssertNil(SidebarAccountOrder.subscriptionMove(
            before: before, after: SidebarAccountOrder.moved(before, from: IndexSet(integer: 3), to: 0), store: store, apiAccounts: [t1]
        ), "moving TypeSafe above everything changes no same-kind order")
    }
}
