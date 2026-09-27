import XCTest
@testable import Ration

final class APIAttentionRowTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private func row(lowerBound: Bool = false, percent: Int = 78) -> AttentionRow {
        AttentionRow(owner: .apiOrg(UUID()), accountLabel: "IZZY", source: .api(.anthropic), subject: .apiBudget, tier: .warning,
                     usedPercent: percent, spentCents: 46_820, thresholdPercent: 75, thresholdCents: nil, resetsAt: nil,
                     resetCount: nil, resetCreditIDs: [], budgetCents: 60_000, isLowerBound: lowerBound)
    }

    /// The drop's value column fits a subscription row's "100%" or Cursor's
    /// "$123.45" (320 pt panel): an API row shows its percent only, like a
    /// window row; the dollars are in the spoken label, the card and the
    /// notification (a 112 % row still says '112 %').
    func testValueTextIsThePercentAlone() {
        XCTAssertEqual(AttentionDropView.budgetValueText(row(), locale: en), UsageFormatters.compactPercent(78, locale: en))
        XCTAssertEqual(AttentionDropView.budgetValueText(row(lowerBound: true), locale: en), "≥" + UsageFormatters.compactPercent(78, locale: en))
        XCTAssertLessThanOrEqual(AttentionDropView.budgetValueText(row(lowerBound: true, percent: 112), locale: Locale(identifier: "fr")).count, 7)
    }

    func testSpokenValueNeverUsesTheGenericPercentPath() {
        XCTAssertEqual(AttentionDropView.budgetSpokenValue(row(), locale: en), "78 percent, $468.20 of $600")
        XCTAssertEqual(AttentionDropView.budgetSpokenValue(row(lowerBound: true), locale: en), "at least 78 percent, at least $468.20 of $600")
    }

    func testMeterFillIsCappedButTextIsNot() {
        XCTAssertEqual(AttentionDropView.meterFraction(forPercent: 112), 1)
        XCTAssertEqual(AttentionDropView.meterFraction(forPercent: 40), 0.4, accuracy: 0.0001)
        XCTAssertTrue(AttentionDropView.budgetValueText(row(percent: 112), locale: en).hasPrefix(UsageFormatters.compactPercent(112, locale: en)))
    }

    /// An API row draws its vendor's mark
    /// before the name, so two orgs both called "Work" stay apart.
    func testVendorMarkOnlyOnAPIRows() {
        XCTAssertEqual(AttentionDropView.vendorMark(for: row()), .anthropic)
        let openAI = AttentionRow(owner: .apiOrg(UUID()), accountLabel: "IZZY", source: .api(.openAI), subject: .apiBudget, tier: .warning,
                                  usedPercent: 78, spentCents: 46_820, thresholdPercent: 75, thresholdCents: nil, resetsAt: nil,
                                  resetCount: nil, resetCreditIDs: [], budgetCents: 60_000, isLowerBound: false)
        XCTAssertEqual(AttentionDropView.vendorMark(for: openAI), .openAI)
        let subscription = AttentionRow(accountID: UUID(), accountLabel: "Work", provider: .claude, subject: .window(.weekly), tier: .warning,
                                        usedPercent: 80, spentCents: nil, thresholdPercent: 75, thresholdCents: nil, resetsAt: nil,
                                        resetCount: nil, resetCreditIDs: [])
        XCTAssertNil(AttentionDropView.vendorMark(for: subscription))
    }

    func testSubjectLabels() {
        XCTAssertEqual(AttentionDropView.subjectLabel(.apiBudget, locale: en), "BUDGET")
    }
}
