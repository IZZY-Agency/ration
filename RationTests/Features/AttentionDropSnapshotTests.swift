import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Renders the attention drop with a representative set of real row kinds at
/// the panel's real width, in both appearances, so the +2 pt type pass can be
/// checked for clipping. With `RATION_SNAPSHOT_DIR` set (xcodebuild:
/// `TEST_RUNNER_RATION_SNAPSHOT_DIR=…`) the PNGs are written there for a human
/// to inspect; CI never writes files.
@MainActor
final class AttentionDropSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rows() -> [AttentionRow] {
        func row(
            _ label: String, _ provider: Provider, _ subject: AttentionRow.Subject, _ tier: AlertTier,
            percent: Int? = nil, cents: Int? = nil, resets: TimeInterval?, count: Int? = nil
        ) -> AttentionRow {
            AttentionRow(
                accountID: UUID(), accountLabel: label, provider: provider, subject: subject, tier: tier,
                usedPercent: percent, spentCents: cents,
                thresholdPercent: percent == nil ? nil : 80, thresholdCents: cents == nil ? nil : 10_000,
                resetsAt: resets.map { now.addingTimeInterval($0) }, resetCount: count,
                resetCreditIDs: count == nil ? [] : ["credit-1"]
            )
        }
        return [
            row("Agency Cursor Team", .claude, .window(.fiveHour), .warning,
                percent: 82, resets: 23 * 3600 + 59 * 60),
            row("ChatGPT 20x", .chatGPT, .window(.weekly), .critical,
                percent: 96, resets: 6 * 86_400 + 23 * 3600),
            row("Max", .claude, .window(.modelWeekly), .critical,
                percent: 100, resets: 23 * 3600 + 59 * 60),
            row("Agency Cursor Team", .cursor, .cursorSpend, .warning,
                cents: 12_345, resets: 30 * 86_400 + 23 * 3600),
            row("Agency Cursor Team", .chatGPT, .resetCredit(id: "credit-1", kind: .available), .warning,
                resets: 29 * 86_400, count: 2),
            row("Personal", .claude, .resetCredit(id: "credit-2", kind: .expiring), .warning,
                resets: 23 * 3600, count: 1),
        ]
    }

    private func render(_ scheme: ColorScheme) throws -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let model = AttentionDropModelObject()
        model.rows = rows()
        model.now = now
        model.showsTicker = true
        let view = AttentionDropView(model: model)
            .frame(width: AttentionDropPanel.width)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.colorMode = .nonLinear
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    /// The header's title can leave the drawn tree (ViewThatFits falls back
    /// to counts alone), so the spoken label must carry it regardless.
    func testHeaderAccessibilityLabelAlwaysNamesThePanel() {
        XCTAssertEqual(
            AttentionDropView.headerAccessibilityLabel(critical: 2, warning: 2, resets: 2, hasLimitRows: true),
            "Nearing limits, 2 critical, 2 warning, 2 resets"
        )
        XCTAssertEqual(
            AttentionDropView.headerAccessibilityLabel(critical: 0, warning: 1, resets: 1, hasLimitRows: true),
            "Nearing limits, 1 warning, 1 reset"
        )
        XCTAssertEqual(
            AttentionDropView.headerAccessibilityLabel(critical: 0, warning: 0, resets: 3, hasLimitRows: false),
            "Resets"
        )
    }

    func testDropRendersInBothAppearancesAtPanelWidth() throws {
        for (scheme, suffix, panelHex) in [
            (ColorScheme.dark, "dark", UInt32(0x1D1F24)), (.light, "light", 0xF8F7F3)
        ] {
            let rep = try render(scheme)
            XCTAssertEqual(rep.pixelsWide, Int(AttentionDropPanel.width * 2), suffix)
            // Ticker 7 + ONE-line header (the 22 pt ✕ + 6 pt padding above
            // and below = 34) + divider 1 + 6 fixed-height rows. A header
            // that wraps — "NEARING / LIMITS" with three counts beside it —
            // makes the panel taller than this.
            let expectedHeight = 7 + 34 + 1 + 6 * AttentionDropGeometry.rowHeight
            XCTAssertEqual(CGFloat(rep.pixelsHigh) / 2, expectedHeight, accuracy: 1, "\(suffix) height")

            // The panel ground resolves for the appearance rendered: sample
            // just inside the bottom-left corner, clear of the rounded edge.
            // Raw sample values (the renderer draws sRGB); converting via
            // `colorAt(…).usingColorSpace` routes through the host display's
            // profile and reads a different number.
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: 40, y: rep.pixelsHigh - 12)
            let hex = UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
            XCTAssertEqual(contrast(hex, panelHex), 1, accuracy: 0.05, "\(suffix) ground \(String(hex, radix: 16))")

            // Row 1 ("Agency Cursor Team", 82 % of 5H): the long label must
            // not squeeze the meter to a dot. Its 82 % fill is the longest
            // run of the warn colour across the row's centre line.
            let warnHex = resolvedHex(Theme.warnNS, scheme == .dark ? .darkAqua : .aqua)
            let rowCentre = Int((7 + 34 + 1 + AttentionDropGeometry.rowHeight / 2) * 2)
            var longest = 0, run = 0
            for x in 0..<rep.pixelsWide {
                rep.getPixel(&pixel, atX: x, y: rowCentre)
                let px = UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
                run = contrast(px, warnHex) < 1.1 ? run + 1 : 0
                longest = max(longest, run)
            }
            XCTAssertGreaterThanOrEqual(
                CGFloat(longest) / 2, AttentionDropGeometry.meterMinWidth * 0.82 - 2, "\(suffix) meter fill"
            )

            if let dir = ProcessInfo.processInfo.environment["RATION_SNAPSHOT_DIR"], !dir.isEmpty {
                let url = URL(fileURLWithPath: dir).appending(path: "drop-\(suffix).png")
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
                if scheme == .dark {
                    // The rows' window names drawn as `WindowTag`s.
                    let tags = URL(fileURLWithPath: dir).appending(path: "drop-window-tags-dark.png")
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: tags)
                }
            }
        }
    }
}
