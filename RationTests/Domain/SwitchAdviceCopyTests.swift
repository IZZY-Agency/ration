import XCTest
@testable import Ration

final class SwitchAdviceCopyTests: XCTestCase {
    private func advice(
        _ provider: Provider = .claude,
        to label: String = "Personal",
        headroom: Double = 0.85,
        binding: UsageWindowKind = .weekly
    ) -> SwitchAdvice {
        SwitchAdvice(
            provider: provider, fromAccountID: UUID(), fromLabel: "Client",
            toAccountID: UUID(), toLabel: label, toHeadroom: headroom, toBinding: binding
        )
    }

    // MARK: Header

    func testHeaderTextPerBindingKind() {
        XCTAssertEqual(SwitchAdviceCopy.headerText(advice()), "→ SWITCH CLAUDE TO Personal · 85% OF WEEK LEFT")
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(binding: .fiveHour)),
            "→ SWITCH CLAUDE TO Personal · 85% OF 5 HOURS LEFT"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(binding: .modelWeekly)),
            "→ SWITCH CLAUDE TO Personal · 85% OF FABLE LEFT"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.headerText(advice(.chatGPT, to: "Work 20x", headroom: 0.4)),
            "→ SWITCH CHATGPT TO Work 20x · 40% OF WEEK LEFT"
        )
    }

    func testHeaderPartsSplitLeadTargetTail() {
        let parts = SwitchAdviceCopy.headerParts(advice())
        XCTAssertEqual(parts.lead, "SWITCH CLAUDE TO")
        XCTAssertEqual(parts.target, "Personal")
        XCTAssertEqual(parts.tail, "· 85% OF WEEK LEFT")
    }

    func testPercentIsRoundedHeadroom() {
        XCTAssertEqual(SwitchAdviceCopy.percent(advice(headroom: 0.845)), 85)
        XCTAssertEqual(SwitchAdviceCopy.percent(advice(headroom: 0.844)), 84)
        XCTAssertEqual(SwitchAdviceCopy.percent(advice(headroom: 1)), 100)
        XCTAssertEqual(SwitchAdviceCopy.percent(advice(headroom: 0.204)), 20)
    }

    func testSpokenHeader() {
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice()),
            "Switch Claude to Personal, 85 percent of the week left"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(binding: .fiveHour)),
            "Switch Claude to Personal, 85 percent of the 5 hours left"
        )
        XCTAssertEqual(
            SwitchAdviceCopy.spokenHeader(advice(binding: .modelWeekly)),
            "Switch Claude to Personal, 85 percent of Fable left"
        )
    }

    // MARK: Notification

    func testNotificationLine() {
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(), redacted: false),
            "Switch to Personal — 85% of its week left."
        )
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(binding: .fiveHour), redacted: false),
            "Switch to Personal — 85% of its 5 hours left."
        )
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(binding: .modelWeekly), redacted: false),
            "Switch to Personal — 85% of its Fable left."
        )
    }

    func testRedactedNotificationLineHasNoLabelsOrNumbers() {
        let line = SwitchAdviceCopy.notificationLine(advice(to: "bob@acme.com"), redacted: true)
        XCTAssertEqual(line, "Another Claude account has more room.")
        XCTAssertFalse(line.contains("bob@acme.com"))
        XCTAssertFalse(line.contains("Client"))
        XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits))
        XCTAssertEqual(
            SwitchAdviceCopy.notificationLine(advice(.chatGPT), redacted: true),
            "Another ChatGPT account has more room."
        )
    }

    // MARK: Drop

    func testDropSuffix() {
        XCTAssertEqual(SwitchAdviceCopy.dropSuffix(advice()), "→ Personal")
        XCTAssertEqual(SwitchAdviceCopy.dropSpokenSuffix(advice()), ", switch to Personal")
    }
}
