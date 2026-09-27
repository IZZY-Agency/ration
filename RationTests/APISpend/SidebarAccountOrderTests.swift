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
        XCTAssertEqual(SidebarAccountOrder.subscriptionMove(before: before, after: after)?.id, s2)
        XCTAssertEqual(SidebarAccountOrder.subscriptionMove(before: before, after: after)?.index, 0)
        let apiOnly = SidebarAccountOrder.moved(before, from: IndexSet(integer: 1), to: 0)
        XCTAssertNil(SidebarAccountOrder.subscriptionMove(before: before, after: apiOnly))
        let pastAPI = SidebarAccountOrder.moved(before, from: IndexSet(integer: 0), to: 2)
        XCTAssertNil(SidebarAccountOrder.subscriptionMove(before: before, after: pastAPI), "s1 still precedes s2")
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
}
