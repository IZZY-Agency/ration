import XCTest
@testable import Ration

final class PlanChoiceTests: XCTestCase {
    private func record(_ provider: Provider = .claude, plan: PlanTier? = nil, source: PlanSource? = nil) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: provider, label: "A", webProfileID: UUID(),
            displayOrder: 0, createdAt: .distantPast, plan: plan, planSource: source
        )
    }

    func testSelectionIsAutoUnlessTheUserChose() {
        XCTAssertEqual(PlanChoice.selection(for: record()), PlanChoice.automatic)
        XCTAssertEqual(PlanChoice.selection(for: record(plan: .claudeUltra, source: .detected)), PlanChoice.automatic)
        XCTAssertEqual(PlanChoice.selection(for: record(plan: .claudeMax, source: .user)), "claudeMax5x")
    }

    func testAutomaticTitleNamesTheDetectedPlan() {
        XCTAssertEqual(PlanChoice.automaticTitle(for: record(plan: .claudeUltra, source: .detected)), "Detect automatically (Ultra)")
        XCTAssertEqual(PlanChoice.automaticTitle(for: record()), "Detect automatically (not detected)")
        XCTAssertEqual(PlanChoice.automaticTitle(for: record(plan: .claudePro, source: .user)), "Detect automatically")
    }

    func testPlanForSelection() {
        XCTAssertNil(PlanChoice.plan(forSelection: PlanChoice.automatic))
        XCTAssertEqual(PlanChoice.plan(forSelection: "chatGPTPro20x"), .chatGPTPro20x)
        XCTAssertNil(PlanChoice.plan(forSelection: "garbage"))
    }

    func testTagForCards() {
        XCTAssertEqual(PlanChoice.tag(for: record(plan: .claudeUltra, source: .detected)), "ULTRA")
        XCTAssertNil(PlanChoice.tag(for: record()))
        XCTAssertNil(PlanChoice.tag(for: record(.chatGPT, plan: .claudeUltra, source: .user)), "a mismatched plan shows nothing")
    }

    func testSurfacesNameThePlanWhenKnown() {
        let max = record(plan: .claudeUltra, source: .detected)
        XCTAssertEqual(AccountCardView.nameAccessibilityLabel(for: max), "A, Claude Ultra")
        XCTAssertEqual(AccountCardView.nameAccessibilityLabel(for: record()), "A, Claude")
        // The plan is its own tag (`PlanTagView`), never repeated in the caption.
        XCTAssertEqual(FocusView.heroProviderCaption(max), "CLAUDE")
        XCTAssertEqual(FocusView.linePrefix(record(.chatGPT, plan: .chatGPTPro20x, source: .detected)), "ChatGPT: ")
        XCTAssertEqual(FocusView.heroProviderCaption(record(.chatGPT)), "CHATGPT")
        XCTAssertEqual(FocusView.providerAndPlan(record(.chatGPT, plan: .chatGPTPro5x, source: .detected)), "ChatGPT Pro 5x")
    }
}
