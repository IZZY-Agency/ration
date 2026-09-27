import XCTest
@testable import Ration

final class PriorityCoverageTests: XCTestCase {
    private let month = UTCMonth(year: 2026, month: 9)
    private func cost(startedAt: TimeInterval) -> APICostReport {
        APICostReport(month: month, fetchedAt: Date(timeIntervalSince1970: startedAt + 5), refreshStartedAt: Date(timeIntervalSince1970: startedAt), days: [], byModel: [], otherCharges: [], byLineItem: [])
    }
    private func tokens(startedAt: TimeInterval, priority: Bool = false) -> APITokenReport {
        APITokenReport(month: month, fetchedAt: Date(timeIntervalSince1970: startedAt + 6), refreshStartedAt: Date(timeIntervalSince1970: startedAt), byModel: [], hasPriorityTierUsage: priority)
    }

    func testOpenAIHasNoCoverageState() {
        XCTAssertNil(PriorityCoverage.resolve(vendor: .openAI, cost: cost(startedAt: 0), tokens: nil, presentMonth: nil))
    }

    func testNoneOnlyWhenTokensAreFromTheSameOrALaterRefresh() {
        XCTAssertEqual(PriorityCoverage.resolve(vendor: .anthropic, cost: cost(startedAt: 100), tokens: tokens(startedAt: 100), presentMonth: nil), PriorityCoverage.none)
        XCTAssertEqual(PriorityCoverage.resolve(vendor: .anthropic, cost: cost(startedAt: 100), tokens: tokens(startedAt: 200), presentMonth: nil), PriorityCoverage.none)
        XCTAssertEqual(PriorityCoverage.resolve(vendor: .anthropic, cost: cost(startedAt: 200), tokens: tokens(startedAt: 100), presentMonth: nil), .unknown)
        XCTAssertEqual(PriorityCoverage.resolve(vendor: .anthropic, cost: cost(startedAt: 100), tokens: nil, presentMonth: nil), .unknown)
    }

    func testPresentIsStickyForTheMonth() {
        XCTAssertEqual(PriorityCoverage.resolve(vendor: .anthropic, cost: cost(startedAt: 300), tokens: tokens(startedAt: 300), presentMonth: month), .present)
        XCTAssertEqual(PriorityCoverage.resolve(vendor: .anthropic, cost: cost(startedAt: 300), tokens: tokens(startedAt: 300), presentMonth: UTCMonth(year: 2026, month: 8)), PriorityCoverage.none)
    }
}
