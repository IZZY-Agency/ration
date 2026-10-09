import XCTest
@testable import Ration

/// What the ring bar writes: the capsule labels and numbers, the hover card,
/// and the VoiceOver value.
final class RingBarTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let en = Locale(identifier: "en")

    private func claudeEntry(weeklyLeft: Double, fiveLeft: Double, fetched: Date) -> GaugeEntry {
        let id = UUID()
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: fetched,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: fiveLeft, resetsAt: now.addingTimeInterval(3 * 3600 + 43 * 60)),
            weekly: UsageWindow(kind: .weekly, remainingFraction: weeklyLeft, resetsAt: now.addingTimeInterval(4 * 3600 + 43 * 60)),
            modelWeekly: nil)
        let gauge = MenuBarGauge(provider: .claude, label: "Personal", fraction: weeklyLeft, windowKind: .weekly, inUse: false)
        return GaugeEntry(id: id, gauge: gauge, details: .subscription(snapshot))
    }

    func testShortLabelDropsTheProviderPrefixOnly() {
        XCTAssertEqual(RingBarText.shortLabel("ChatGPT 20x", in: .subscription(.chatGPT)), "20x")
        XCTAssertEqual(RingBarText.shortLabel("chatgpt 5x", in: .subscription(.chatGPT)), "5x")
        XCTAssertEqual(RingBarText.shortLabel("ChatGPT", in: .subscription(.chatGPT)), "ChatGPT")
        XCTAssertEqual(RingBarText.shortLabel("Studio API", in: .api(.anthropic)), "Studio API")
        XCTAssertEqual(RingBarText.shortLabel("ChatGPT 20x", in: .subscription(.claude)), "ChatGPT 20x")
    }

    func testPercentFollowsDisplayModeAndBudgetRounding() {
        let ring = MenuBarGauge(provider: .claude, label: "Client", fraction: 0.894, windowKind: .weekly, inUse: false)
        XCTAssertEqual(RingBarText.percent(for: ring, displaysRemaining: true), 89)
        let budget = MenuBarGauge(source: .api(.anthropic), label: "Studio", fraction: 0.98, windowKind: nil, inUse: false,
                                  budget: BudgetGaugeFacts(exactPercent: 1.52, isLowerBound: false))
        XCTAssertEqual(RingBarText.percent(for: budget, displaysRemaining: true), 98)
        XCTAssertEqual(RingBarText.percent(for: budget, displaysRemaining: false), 2)
        let over = MenuBarGauge(source: .api(.openAI), label: "Over", fraction: 1, windowKind: nil, inUse: false,
                                budget: BudgetGaugeFacts(exactPercent: 137.5, isLowerBound: false))
        XCTAssertEqual(RingBarText.percent(for: over, displaysRemaining: false), 138, "an overspend reads as one")
        XCTAssertEqual(RingBarText.percent(for: over, displaysRemaining: true), 0)
    }

    func testSubscriptionCardListsEveryWindowWithReset() {
        let card = RingBarText.card(for: claudeEntry(weeklyLeft: 0.3, fiveLeft: 1, fetched: now), displaysRemaining: true, now: now, locale: en)
        XCTAssertEqual(card.provider, "Claude")
        XCTAssertEqual(card.title, "Personal")
        XCTAssertEqual(card.lines.map(\.text), ["5h 100% left", "wk 30% left"])
        let five = UsageFormatters.shortReset(now.addingTimeInterval(3 * 3600 + 43 * 60), locale: en)
        let week = UsageFormatters.shortReset(now.addingTimeInterval(4 * 3600 + 43 * 60), locale: en)
        XCTAssertEqual(card.lines.map(\.detail), ["resets in 3h 43m · \(five)", "resets in 4h 43m · \(week)"])
        XCTAssertEqual(card.lines.map(\.isStale), [false, false])
    }

    func testStaleSnapshotIsFlagged() {
        let old = now.addingTimeInterval(-UsageEvidence.maxAge - 60)
        let card = RingBarText.card(for: claudeEntry(weeklyLeft: 0.3, fiveLeft: 1, fetched: old), displaysRemaining: false, now: now, locale: en)
        XCTAssertEqual(card.lines.first?.text, "5h 0% used")
        XCTAssertTrue(card.lines.allSatisfy(\.isStale))
    }

    func testUsedRoundsLikeTheGauge() {
        let card = RingBarText.card(for: claudeEntry(weeklyLeft: 0.3, fiveLeft: 0.125, fetched: now), displaysRemaining: false, now: now, locale: en)
        XCTAssertEqual(card.lines.first?.text, "5h 88% used", "the capsule draws 88 for a 0.875 used fraction")
    }

    func testAccessibilityDetailsCarryEveryLineAndStaleness() {
        let old = now.addingTimeInterval(-UsageEvidence.maxAge - 60)
        let card = RingBarText.card(for: claudeEntry(weeklyLeft: 0.3, fiveLeft: 1, fetched: old), displaysRemaining: true, now: now, locale: en)
        let details = RingBarText.accessibilityDetails(for: card, locale: en)
        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(details[0].hasPrefix("5h 100% left"), details[0])
        XCTAssertTrue(details[0].contains("Stale"), details[0])
        XCTAssertTrue(details[1].contains("resets in 4h 43m"), details[1])
    }

    func testAccessibilityLabelSpeaksTheDrawnValue() {
        let entry = claudeEntry(weeklyLeft: 0.3, fiveLeft: 1, fetched: now)
        XCTAssertEqual(RingBarText.accessibilityLabel(for: entry, displaysRemaining: true, locale: en), "Claude Personal weekly 30% left")
    }

    func testCardLinesAreTranslated() {
        let fr = RingBarText.card(for: claudeEntry(weeklyLeft: 0.3, fiveLeft: 1, fetched: now), displaysRemaining: true, now: now,
                                  locale: Locale(identifier: "fr"))
        XCTAssertEqual(fr.lines.last?.text, "wk\u{00A0}: 30\u{202F}% restant")
        let uk = RingBarText.card(for: claudeEntry(weeklyLeft: 0.3, fiveLeft: 1, fetched: now), displaysRemaining: false, now: now,
                                  locale: Locale(identifier: "uk"))
        XCTAssertEqual(uk.lines.last?.text, "wk: використано 70%")
    }
}
