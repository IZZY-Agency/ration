import AppKit
import XCTest
@testable import Ration

/// The `drop` log line is what live placement checks are read from, so its
/// format is pinned: frames in screen points with one decimal, flags as 0/1.
final class AttentionDropPlacementLogTests: XCTestCase {
    private func report(
        event: AttentionDropPlacementReport.Event = .present,
        buttonFrame: NSRect? = NSRect(x: 1402.5, y: 1095, width: 54, height: 22),
        anchor: AttentionDropGeometry.Anchor = .statusItem(NSRect(x: 1402.5, y: 1095, width: 54, height: 22))
    ) -> AttentionDropPlacementReport {
        AttentionDropPlacementReport(
            event: event,
            isTestDrop: true,
            buttonFrame: buttonFrame,
            screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1080),
            isMainScreen: true,
            hasNotch: true,
            screenCount: 3,
            anchor: anchor,
            panelFrame: NSRect(x: 1269.5, y: 900, width: 320, height: 174),
            appIsActive: false,
            panelIsKey: false,
            rationIsFrontmost: false
        )
    }

    func testLineCarriesEveryFrameAndFlag() {
        XCTAssertEqual(
            report().line,
            "event=present test=1 button=(1402.5,1095.0 54.0x22.0) "
                + "screen=(0.0,0.0 1728.0x1117.0) visible=(0.0,0.0 1728.0x1080.0) "
                + "main=1 notch=1 screens=3 "
                + "anchor=statusItem panel=(1269.5,900.0 320.0x174.0) "
                + "active=0 key=0 frontRation=0"
        )
    }

    /// The overflow-chevron case: no usable button frame, trailing fallback,
    /// and every optional field says `none` rather than disappearing.
    func testMissingInputsReadAsNone() {
        let line = report(
            event: .reposition,
            buttonFrame: nil,
            anchor: .screenTrailing
        ).line
        XCTAssertTrue(line.hasPrefix("event=reposition "), line)
        XCTAssertTrue(line.contains(" button=none "), line)
        XCTAssertTrue(line.contains(" anchor=screenTrailing "), line)
    }

    /// Negative origins are ordinary on a display left of or below the main
    /// one, and must survive formatting with their sign.
    func testFrameTextKeepsNegativeOrigins() {
        XCTAssertEqual(
            AttentionDropPlacementReport.frameText(NSRect(x: -1920, y: -0.5, width: 1920, height: 1080)),
            "(-1920.0,-0.5 1920.0x1080.0)"
        )
        XCTAssertEqual(AttentionDropPlacementReport.frameText(nil), "none")
    }

    /// The line is logged `.public`, which is only safe while it cannot carry
    /// free text: no display name, no bundle id, no label. Enforced on the
    /// type, so adding a `String` field fails here rather than in a log.
    func testReportHasNoFreeTextFields() {
        for child in Mirror(reflecting: report()).children {
            let type = type(of: child.value)
            XCTAssertFalse(type == String.self || type == String?.self, "\(child.label ?? "?") is free text")
        }
        XCTAssertFalse(report().line.contains("com."), "no bundle id")
    }

    /// VoiceOver must never announce sample crossings as real.
    func testTestDropAnnouncementSaysTest() {
        let en = Locale(identifier: "en")
        let rows = AttentionDropSample.rows(now: Date(timeIntervalSince1970: 0), locale: en)
        let test = AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: [], isTestDrop: true, locale: en)
        XCTAssertEqual(test.announcement?.hasPrefix("Test drop, sample data, "), true, test.announcement ?? "nil")
        let real = AttentionDropAnnouncement.evaluate(rows: rows, previouslySeen: [], locale: en)
        XCTAssertEqual(real.announcement?.hasPrefix("Test drop"), false)
    }

    func testLogAddress() {
        XCTAssertEqual(AttentionDropPlacementLog.subsystem, "agency.izzy.ration")
        XCTAssertEqual(AttentionDropPlacementLog.category, "drop")
    }

    /// The sample rows are the only thing a test drop shows; none of them may
    /// name a real account or carry a real label.
    func testSampleRowsAreFakeAndLabelledSo() {
        let rows = AttentionDropSample.rows(now: Date(timeIntervalSince1970: 0), locale: Locale(identifier: "en"))
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.accountLabel == "SAMPLE" })
        XCTAssertTrue(rows.allSatisfy { AttentionDropSample.accountIDs.contains($0.accountID) })
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "row ids must be distinct for ForEach")
    }
}
