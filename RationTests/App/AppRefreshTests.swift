import XCTest
@testable import Ration

@MainActor
final class AppRefreshTests: XCTestCase {
    func testCombiningRunsEveryStepForBothActions() async {
        var calls: [String] = []
        let refreshed = expectation(description: "both refreshAll steps ran")
        refreshed.expectedFulfillmentCount = 2
        let opened = expectation(description: "both refreshWhenOpened steps ran")
        opened.expectedFulfillmentCount = 2
        let refresh = AppRefresh.combining(
            all: [{ calls.append("subscriptions"); refreshed.fulfill() }, { calls.append("api"); refreshed.fulfill() }],
            whenOpened: [{ calls.append("subscriptions-open"); opened.fulfill() }, { calls.append("api-open"); opened.fulfill() }]
        )
        refresh.refreshAll()
        refresh.refreshWhenOpened()
        await fulfillment(of: [refreshed, opened], timeout: 2)
        XCTAssertEqual(Set(calls), ["subscriptions", "api", "subscriptions-open", "api-open"])
    }
}
