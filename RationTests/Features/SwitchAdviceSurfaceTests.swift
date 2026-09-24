import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Switch advice on the popover header and the attention drop. With
/// `RATION_SNAPSHOT_DIR` set (xcodebuild: `TEST_RUNNER_RATION_SNAPSHOT_DIR=…`)
/// the header and drop PNGs are written there for a human to inspect; CI
/// never writes files.
@MainActor
final class SwitchAdviceSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let client = UUID()
    private let personal = UUID()
    private let gptFrom = UUID()
    private let gptTo = UUID()

    private var claudeAdvice: SwitchAdvice {
        SwitchAdvice(
            provider: .claude, fromAccountID: client, fromLabel: "Client",
            toAccountID: personal, toLabel: "Personal", toHeadroom: 0.85, toBinding: .weekly
        )
    }

    private var chatGPTAdvice: SwitchAdvice {
        SwitchAdvice(
            provider: .chatGPT, fromAccountID: gptFrom, fromLabel: "ChatGPT 20x",
            toAccountID: gptTo, toLabel: "Agency Team", toHeadroom: 0.62, toBinding: .fiveHour
        )
    }

    private func row(
        _ accountID: UUID, _ label: String, _ provider: Provider, _ subject: AttentionRow.Subject,
        percent: Int? = 97, cents: Int? = nil, count: Int? = nil
    ) -> AttentionRow {
        AttentionRow(
            accountID: accountID, accountLabel: label, provider: provider, subject: subject,
            tier: .critical, usedPercent: percent, spentCents: cents,
            thresholdPercent: percent == nil ? nil : 90, thresholdCents: cents == nil ? nil : 10_000,
            resetsAt: now.addingTimeInterval(11 * 3600 + 18 * 60), resetCount: count,
            resetCreditIDs: count == nil ? [] : ["credit-1"]
        )
    }

    // MARK: Drop row

    func testDropRowAdviceMatchesOnlyTheFromAccountsLimitRows() {
        let advice = [claudeAdvice, chatGPTAdvice]
        let limit = row(client, "Client", .claude, .window(.weekly))
        let other = row(personal, "Personal", .claude, .window(.weekly))
        let gpt = row(gptFrom, "ChatGPT 20x", .chatGPT, .window(.fiveHour))
        let reset = row(client, "Client", .claude, .resetCredit(id: "credit-1", kind: .available), percent: nil, count: 1)

        XCTAssertEqual(AttentionDropView.switchAdvice(for: limit, in: advice), claudeAdvice)
        XCTAssertEqual(AttentionDropView.switchAdvice(for: gpt, in: advice), chatGPTAdvice)
        XCTAssertNil(AttentionDropView.switchAdvice(for: other, in: advice))
        XCTAssertNil(AttentionDropView.switchAdvice(for: reset, in: advice), "reset rows stay unchanged")
        XCTAssertNil(AttentionDropView.switchAdvice(for: limit, in: []))
    }

    func testDropRowAccessibilityGainsTheSwitchSuffix() {
        let limit = row(client, "Client", .claude, .window(.weekly))
        let gpt = row(gptFrom, "ChatGPT 20x", .chatGPT, .window(.fiveHour))
        let plain = AttentionDropView.rowAccessibilityLabel(limit, now: now)

        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(limit, now: now, advice: claudeAdvice),
            plain + ", switch to Personal"
        )
        XCTAssertEqual(
            AttentionDropView.rowAccessibilityLabel(gpt, now: now, advice: chatGPTAdvice),
            AttentionDropView.rowAccessibilityLabel(gpt, now: now) + ", switch to Agency Team"
        )
        XCTAssertEqual(AttentionDropView.rowAccessibilityLabel(limit, now: now, advice: nil), plain)
    }

    // MARK: Layout splits

    func testHeaderTailOutlivesALongTarget() {
        // 514 pt of line, 200 pt of arrow + lead, a 180 pt tail, a 400 pt target.
        let split = SwitchAdviceLineLayout.split(
            available: 514, spacing: 6, fixed: 200, targetIdeal: 400, tailIdeal: 180
        )
        XCTAssertEqual(split.tail, 180, "the percent is never dropped for the name")
        XCTAssertEqual(split.target, 514 - 200 - 18 - 180)
        // Squeezed past the floor: the target keeps its floor, the tail yields.
        let tight = SwitchAdviceLineLayout.split(
            available: 300, spacing: 6, fixed: 200, targetIdeal: 400, tailIdeal: 180
        )
        XCTAssertEqual(tight.target, SwitchAdviceLineLayout.targetFloor)
        XCTAssertEqual(tight.tail, 300 - 200 - 18 - SwitchAdviceLineLayout.targetFloor)
        // A short target keeps its own width, not the floor.
        let short = SwitchAdviceLineLayout.split(
            available: 300, spacing: 6, fixed: 200, targetIdeal: 14, tailIdeal: 180
        )
        XCTAssertEqual(short.target, 14)
        // Room for everything: ideal sizes.
        let roomy = SwitchAdviceLineLayout.split(
            available: 900, spacing: 6, fixed: 200, targetIdeal: 40, tailIdeal: 180
        )
        XCTAssertEqual(roomy.target, 40)
        XCTAssertEqual(roomy.tail, 180)
    }

    func testDropNameTakesTheWholeSpanWhenTheTargetGetsNothing() {
        // Only the name's floor fits: no target, and no gap reserved for it.
        let none = AdvisedNameLayout.split(available: 40, spacing: 5, nameIdeal: 120, targetIdeal: 60)
        XCTAssertEqual(none.target, 0)
        XCTAssertEqual(none.name, 40)
        // Room for both: target at ideal, name gets the rest after the gap.
        let both = AdvisedNameLayout.split(available: 120, spacing: 5, nameIdeal: 120, targetIdeal: 30)
        XCTAssertEqual(both.target, 30)
        XCTAssertEqual(both.name, 85)
        // Target truncates past the name's floor.
        let squeezed = AdvisedNameLayout.split(available: 80, spacing: 5, nameIdeal: 120, targetIdeal: 60)
        XCTAssertEqual(squeezed.name, AdvisedNameLayout.nameFloor)
        XCTAssertEqual(squeezed.target, 80 - 5 - AdvisedNameLayout.nameFloor)
    }

    /// A name truncated at the floor draws a little narrower (it cuts at
    /// a glyph); reclaiming that slack must not push it below the floor.
    func testReclaimNeverTakesTheNameBelowTheFloor() {
        let offered = AdvisedNameLayout.split(available: 80, spacing: 5, nameIdeal: 120, targetIdeal: 60)
        XCTAssertEqual(offered.name, AdvisedNameLayout.nameFloor)
        let placed = AdvisedNameLayout.reclaim(
            available: 80, spacing: 5, offered: offered,
            drawnName: AdvisedNameLayout.nameFloor - 6, nameIdeal: 120, targetIdeal: 60
        )
        XCTAssertEqual(placed.name, AdvisedNameLayout.nameFloor)
        XCTAssertEqual(placed.target, 80 - 5 - AdvisedNameLayout.nameFloor)

        // Above the floor the slack still goes to the target.
        let roomy = AdvisedNameLayout.split(available: 160, spacing: 5, nameIdeal: 120, targetIdeal: 60)
        let reclaimed = AdvisedNameLayout.reclaim(
            available: 160, spacing: 5, offered: roomy,
            drawnName: roomy.name - 4, nameIdeal: 120, targetIdeal: 60
        )
        XCTAssertEqual(reclaimed.name, roomy.name - 4)
        XCTAssertEqual(reclaimed.target, min(60, 160 - 5 - (roomy.name - 4)))

        // A name shorter than the floor keeps its own (drawn) width.
        let short = AdvisedNameLayout.split(available: 60, spacing: 5, nameIdeal: 30, targetIdeal: 60)
        let shortPlaced = AdvisedNameLayout.reclaim(
            available: 60, spacing: 5, offered: short,
            drawnName: 30, nameIdeal: 30, targetIdeal: 60
        )
        XCTAssertEqual(shortPlaced.name, 30)
    }

    func testHeaderIdentifierIsPerProvider() {
        XCTAssertEqual(SwitchAdviceCopy.headerIdentifier(claudeAdvice), "headerSwitchAdvice.claude")
        XCTAssertEqual(SwitchAdviceCopy.headerIdentifier(chatGPTAdvice), "headerSwitchAdvice.chatGPT")
    }

    // MARK: Snapshots

    private func render<V: View>(_ view: V, _ scheme: ColorScheme) throws -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        renderer.colorMode = .nonLinear
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["RATION_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appending(path: name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func header(_ advice: [SwitchAdvice]) -> some View {
        MenuBarView(
            presentations: [],
            isRefreshing: false,
            profileCleanupBanner: nil,
            errorMessage: nil,
            activeAccounts: [:],
            onOpen: {}, onAddAccount: {}, onRefresh: {}, onSettings: {}, onAbout: {},
            onHistory: {}, onRetryProfileCleanup: {}, onQuit: {}, onReauthenticate: { _ in },
            switchAdvice: advice
        )
    }

    /// Whether any pixel in the top `rows` points is the active green.
    private func hasActive(_ rep: NSBitmapImageRep, _ scheme: ColorScheme, topPoints: Int) -> Bool {
        let activeHex = resolvedHex(Theme.activeNS, scheme == .dark ? .darkAqua : .aqua)
        let target: [Int] = [Int(activeHex >> 16 & 0xFF), Int(activeHex >> 8 & 0xFF), Int(activeHex & 0xFF)]
        var pixel = [Int](repeating: 0, count: 4)
        for y in 0..<min(rep.pixelsHigh, topPoints * 2) {
            for x in 0..<rep.pixelsWide {
                rep.getPixel(&pixel, atX: x, y: y)
                // Per-channel, not luminance: antialiased cream text can share
                // the green's luminance while being a different hue.
                let distance: Int = abs(pixel[0] - target[0]) + abs(pixel[1] - target[1]) + abs(pixel[2] - target[2])
                if distance <= 12 { return true }
            }
        }
        return false
    }

    func testHeaderRendersOneLinePerAdviceInBothAppearances() throws {
        for (scheme, suffix) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let none = try render(header([]), scheme)
            let one = try render(header([claudeAdvice]), scheme)
            let two = try render(header([claudeAdvice, chatGPTAdvice]), scheme)

            XCTAssertGreaterThan(one.pixelsHigh, none.pixelsHigh, suffix)
            XCTAssertGreaterThan(two.pixelsHigh, one.pixelsHigh, "\(suffix): two advices stack")
            XCTAssertFalse(hasActive(none, scheme, topPoints: 60), suffix)
            XCTAssertTrue(hasActive(one, scheme, topPoints: 60), "\(suffix): advice line drawn in active green")

            let longTarget = SwitchAdvice(
                provider: .claude, fromAccountID: client, fromLabel: "Client", toAccountID: personal,
                toLabel: "Agency Research Team — Shared Max Subscription (EU)", toHeadroom: 0.85, toBinding: .weekly
            )
            let long = try render(header([longTarget]), scheme)
            XCTAssertEqual(long.pixelsHigh, one.pixelsHigh, "\(suffix): a long target stays on one line")
            try write(long, "header-switch-long-\(suffix).png")
            try write(one, "header-switch-one-\(suffix).png")
            try write(two, "header-switch-two-\(suffix).png")
        }
    }

    func testDropWithTwoAdvisedRowsRendersAtRowHeight() throws {
        let model = AttentionDropModelObject()
        model.rows = [
            row(client, "Client", .claude, .window(.weekly)),
            row(gptFrom, "ChatGPT 20x Agency Long Name", .chatGPT, .window(.fiveHour)),
            row(personal, "Personal", .claude, .window(.modelWeekly)),
        ]
        model.switchAdvice = [claudeAdvice, chatGPTAdvice]
        model.now = now
        model.showsTicker = true
        for (scheme, suffix) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let rep = try render(
                AttentionDropView(model: model).frame(width: AttentionDropPanel.width), scheme
            )
            // Row height unchanged by the suffix: ticker 7 + header 34 + divider 1 + 3 rows.
            let expected = 7 + 34 + 1 + 3 * AttentionDropGeometry.rowHeight
            XCTAssertEqual(CGFloat(rep.pixelsHigh) / 2, expected, accuracy: 1, suffix)
            try write(rep, "drop-switch-\(suffix).png")
        }
    }
}
