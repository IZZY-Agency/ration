import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Plan tiers on screen: the plan tag next to the provider chip on
/// cards, and the add-account "Which plan is this?" step, in both
/// appearances. With `RATION_SNAPSHOT_DIR` set the PNGs are written as
/// `plan-chip-cards-{dark,light}.png` and `addaccount-plan-step-{dark,light}.png`.
@MainActor
final class PlanTierSnapshotTests: XCTestCase {
    private let now = Date()
    private var order = 0

    private func card(_ label: String, _ provider: Provider, weekly: Double, fiveHour: Double? = nil, plan: PlanTier?) -> AccountPresentation {
        order += 1
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: provider, label: label, webProfileID: UUID(),
            displayOrder: order, createdAt: now,
            plan: plan, planSource: plan == nil ? nil : .detected
        )
        let snapshot = UsageSnapshot(
            accountID: id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: fiveHour.map { UsageWindow(kind: .fiveHour, remainingFraction: 1 - $0, resetsAt: now.addingTimeInterval(3 * 3600)) },
            weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - weekly, resetsAt: now.addingTimeInterval(4 * 86_400))
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

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
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appending(path: name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func contains(_ rep: NSBitmapImageRep, _ hex: UInt32, tolerance: Int = 12) -> Bool {
        let target: [Int] = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        var pixel = [Int](repeating: 0, count: 4)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                rep.getPixel(&pixel, atX: x, y: y)
                let d0: Int = abs(pixel[0] - target[0])
                let d1: Int = abs(pixel[1] - target[1])
                let d2: Int = abs(pixel[2] - target[2])
                if d0 + d1 + d2 <= tolerance { return true }
            }
        }
        return false
    }

    func testCardsDrawThePlanTag() throws {
        let presentations = [
            card("Client", .claude, weekly: 0.62, fiveHour: 0.27, plan: .claudeMax20x),
            card("Personal", .claude, weekly: 0.15, fiveHour: 0.05, plan: .claudeMax5x),
            card("20x", .chatGPT, weekly: 0.42, plan: .chatGPTPro20x),
            card("5x", .chatGPT, weekly: 0.10, plan: .chatGPTPro5x),
            card("Unknown", .chatGPT, weekly: 0.30, plan: nil),
        ]
        let cards = VStack(spacing: 0) {
            ForEach(presentations) { presentation in
                AccountCardView(presentation: presentation, onReauthenticate: {}, now: self.now)
            }
        }
        .frame(width: 540)
        .background(Theme.ink)
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let rep = try render(cards, scheme)
            try write(rep, "plan-chip-cards-\(suffix).png")
            XCTAssertEqual(rep.pixelsWide, 540 * 2, suffix)
        }
    }

    func testPlanStepRendersInBothAppearances() throws {
        let account = AccountRecord(
            id: UUID(), provider: .chatGPT, label: "5x", webProfileID: UUID(),
            displayOrder: 0, createdAt: now
        )
        let step = PlanStepView(account: account, onSave: { _, _ in }, onSkip: {})
        XCTAssertTrue(step.asksPlan)
        XCTAssertTrue(step.asksBillingDay)
        for (scheme, appearance) in [(ColorScheme.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            let suffix = scheme == .dark ? "dark" : "light"
            let rep = try render(step, scheme)
            try write(rep, "addaccount-plan-step-\(suffix).png")
            XCTAssertEqual(rep.pixelsWide, 460 * 2, suffix)
            XCTAssertTrue(contains(rep, resolvedHex(Theme.inkNS, appearance)), "\(suffix) ink background")
        }
    }

    func testPlanStepAsksOnlyWhatIsMissing() {
        let detected = AccountRecord(
            id: UUID(), provider: .claude, label: "A", webProfileID: UUID(),
            displayOrder: 0, createdAt: now, plan: .claudeMax20x, planSource: .detected
        )
        let step = PlanStepView(account: detected, onSave: { _, _ in }, onSkip: {})
        XCTAssertFalse(step.asksPlan)
        XCTAssertTrue(step.asksBillingDay)
    }
}
