import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Settings regressions from the 1.2.0 (73) screenshot pass (+2 pt type).
@MainActor
final class SettingsPolishTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() {
        super.setUp()
        AppFonts.register(in: .main)
    }

    /// Height a view settles at when offered `width`.
    private func fittedHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        return host.fittingSize.height
    }

    // MARK: A1.1 — window titles never break ("FABL/E")

    func testLimitRowTitleStaysOnOneLineWhenSqueezed() {
        let window = UsageWindow(kind: .modelWeekly, remainingFraction: 0.4, resetsAt: now.addingTimeInterval(3 * 3600))
        let row = LimitRowView(title: "FABLE", window: window, now: now)
        let roomy = fittedHeight(row, width: 600)
        // Narrower than "FABLE" + "60 %": the meter must give way, not the title.
        let squeezed = fittedHeight(row, width: 70)
        XCTAssertEqual(squeezed, roomy, accuracy: 0.5, "the window title wrapped")
    }

    // MARK: A1.2 — account header: pill only, age under the name, no wrapping

    func testHeaderSubtitleCarriesTheAgeOfUse() {
        let added = Date(timeIntervalSince1970: 1_783_900_800) // 2026-07-13
        let addedText = "Added \(added.formatted(date: .abbreviated, time: .omitted))"
        let minute = UsageFormatters.relativeReset(now.addingTimeInterval(-60), relativeTo: now)
        let hours = UsageFormatters.relativeReset(now.addingTimeInterval(-7200), relativeTo: now)

        XCTAssertEqual(AccountDetailHeader.subtitle(createdAt: added, phase: .none, now: now), addedText)
        XCTAssertEqual(AccountDetailHeader.subtitle(createdAt: added, phase: .inUse(age: 60), now: now),
                       "\(addedText) · used \(minute)")
        XCTAssertEqual(AccountDetailHeader.subtitle(createdAt: added, phase: .lastUsed(age: 7200), now: now),
                       "\(addedText) · last used \(hours)")
    }

    /// Default Settings window is 720 wide: 270 sidebar + 450 detail, and the
    /// grouped Form insets its rows ≈ 30 pt a side, leaving ≈ 390 pt.
    func testHeaderDoesNotWrapAtTheDefaultSettingsWidth() {
        let account = AccountRecord(
            id: UUID(), provider: .chatGPT, label: "ChatGPT 20x", webProfileID: UUID(),
            displayOrder: 0, createdAt: Date(timeIntervalSince1970: 1_783_900_800)
        )
        // In use a minute ago, and the longest English age the header can
        // show: last used 59 minutes ago (older than the 5 h lookback → idle).
        for lastUsed in [now.addingTimeInterval(-60), now.addingTimeInterval(-59 * 60)] {
            let header = AccountDetailHeader(
                account: account,
                state: .current,
                activeUsage: ActiveUsage(lastUsedAt: lastUsed, source: .fiveHour),
                now: now
            )
            // `content(at:)`, not the view: its `TimelineView` lays out as zero
            // off-screen, which would make this test pass vacuously.
            let tick = header.content(at: now)
            let detailContent = SettingsView.minimumWindowWidth - SettingsSidebar.idealColumnWidth - 60
            XCTAssertEqual(fittedHeight(tick, width: detailContent), fittedHeight(tick, width: 2000),
                           accuracy: 0.5, "the account header wrapped at the default Settings width")
        }
    }

    // MARK: A1.3 — expiry stepper label fits

    func testExpiryWarningLabelIsShortAndPluralised() {
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 1), "Expiry warning: 1 day")
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 2), "Expiry warning: 2 days")
        XCTAssertEqual(ResetExpiryCopy.stepperLabel(leadDays: 7), "Expiry warning: 7 days")
    }

    // MARK: A1.5 — section headers are Title Case, never ALL CAPS

    func testEverySettingsSectionHeaderIsTitleCase() {
        let minor: Set = ["a", "an", "and", "of", "the", "to", "in", "on", "for"]
        XCTAssertFalse(SettingsSectionTitle.all.isEmpty)
        for title in SettingsSectionTitle.all {
            XCTAssertNotEqual(title, title.uppercased(), "\(title) is ALL CAPS")
            for (index, word) in title.split(separator: " ").enumerated() {
                if index > 0, minor.contains(String(word)) { continue }
                XCTAssertEqual(word.first.map { String($0) }, word.first.map { String($0).uppercased() },
                               "\"\(title)\": \"\(word)\" is not capitalised")
            }
        }
        XCTAssertTrue(SettingsSectionTitle.all.contains("Quiet Hours"))
        XCTAssertTrue(SettingsSectionTitle.all.contains("Identity"))
    }
}
