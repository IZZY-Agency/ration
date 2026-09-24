import SwiftUI
import XCTest
@testable import Ration

/// One bordered tag for every limit-window name.
@MainActor
final class WindowTagTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testTagTextNamesEachWindow() {
        XCTAssertEqual(WindowTag.text(kind: .fiveHour, label: nil), "5H")
        XCTAssertEqual(WindowTag.text(kind: .weekly, label: nil), "WK")
        XCTAssertEqual(WindowTag.text(kind: .modelWeekly, label: nil), "FABLE")
        XCTAssertEqual(WindowTag.text(kind: .modelWeekly, label: "Opus 5"), "OPUS 5")
        // The API label only names the model window.
        XCTAssertEqual(WindowTag.text(kind: .weekly, label: "ignored"), "WK")
    }

    /// Text and border use `creamFaint`, whose contrast on ink, panel and
    /// the card highlight is already asserted by the theme tests.
    func testTagUsesTheLabelToken() {
        XCTAssertEqual(WindowTag.foreground, Theme.creamFaint)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let faint: UInt32 = resolvedHex(Theme.creamFaintNS, appearance)
            XCTAssertGreaterThanOrEqual(contrast(faint, resolvedHex(Theme.inkNS, appearance)), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(faint, resolvedHex(Theme.panelNS, appearance)), 4.5)
        }
    }

    func testTagNeverWraps() {
        let host = { (width: CGFloat) -> CGFloat in
            NSHostingView(rootView: WindowTag(kind: .modelWeekly, label: "Opus 5").frame(width: width)).fittingSize.height
        }
        XCTAssertEqual(host(20), host(300), accuracy: 0.5)
    }

    /// "↻ NEXT RESET Personal [5H] 22m" — label, tag and countdown are separate.
    func testNextResetLineParts() {
        let reset = SoonestReset(accountLabel: "Personal", kind: .fiveHour, resetsAt: now.addingTimeInterval(22 * 60 + 30), label: nil)
        let parts = MenuBarView.resetLineParts(reset, now: now)
        XCTAssertEqual(parts.account, "Personal")
        XCTAssertEqual(parts.tag, "5H")
        XCTAssertEqual(parts.countdown, "22m")

        let fable = SoonestReset(accountLabel: "Client", kind: .modelWeekly, resetsAt: now.addingTimeInterval(3 * 3600), label: "Fable")
        XCTAssertEqual(MenuBarView.resetLineParts(fable, now: now).tag, "FABLE")
        // VoiceOver keeps the spoken form.
        XCTAssertFalse(reset.accessibilityLabel(now: now).contains("5H"))
    }
}
