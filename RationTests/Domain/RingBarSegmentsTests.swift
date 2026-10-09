import XCTest
@testable import Ration

/// Subscriptions and API keys each get their own glass, in both styles, so
/// the kinds read at a glance.
final class RingBarSegmentsTests: XCTestCase {
    func testOneGlassPerKindPlansFirst() {
        XCTAssertEqual(RingBarSegments.byKind([.subscription(.claude), .subscription(.chatGPT), .api(.anthropic), .api(.openAI)]),
                       [[.subscription(.claude), .subscription(.chatGPT)], [.api(.anthropic), .api(.openAI)]])
    }

    func testOrderWithinAKindIsKept() {
        XCTAssertEqual(RingBarSegments.byKind([.api(.openAI), .subscription(.chatGPT), .api(.anthropic), .subscription(.claude)]),
                       [[.subscription(.chatGPT), .subscription(.claude)], [.api(.openAI), .api(.anthropic)]])
    }

    func testAKindWithNothingHasNoGlass() {
        XCTAssertEqual(RingBarSegments.byKind([.subscription(.claude)]), [[.subscription(.claude)]])
        XCTAssertEqual(RingBarSegments.byKind([.api(.openAI)]), [[.api(.openAI)]])
        XCTAssertEqual(RingBarSegments.byKind([]), [])
    }

    func testTypeSafeIsAnAPIAccount() {
        XCTAssertEqual(RingBarSegments.byKind([.subscription(.typeSafe), .subscription(.claude)]),
                       [[.subscription(.claude)], [.subscription(.typeSafe)]])
    }
}
