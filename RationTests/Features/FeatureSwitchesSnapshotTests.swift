import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The Features section in Settings → General (both appearances), and the
/// card-level Resets gate. With `RATION_SNAPSHOT_DIR` set the PNGs are
/// written as `settings-features-{dark,light}.png`.
@MainActor
final class FeatureSwitchesSnapshotTests: XCTestCase {
    private let now = Date()

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["RATION_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appending(path: name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// `Form` is AppKit-backed, which `ImageRenderer` cannot draw — host it in
    /// an offscreen window and cache the view's display instead.
    private func renderHosted<V: View>(_ view: V, size: NSSize, dark: Bool) -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    func testSettingsFeaturesSection() async throws {
        for dark in [true, false] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let settings = AppSettings(fileURL: directory.appending(path: "settings.json"))
            try await settings.load()
            // In-use off: shows the locked Switch suggestions row and its note.
            try await settings.setFeature(.inUse, enabled: false)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "FeatureSwitchesSnapshotTests-\(UUID())"))
            let view = GeneralDetailView(
                launchAtLogin: LaunchAtLoginController(service: StaticLaunchAtLoginService()),
                appearance: AppearanceController(defaults: defaults),
                settings: settings,
                notificationPermission: .allowed,
                onSetSortByWeeklyReset: { _ in },
                onSetUsageAlertsEnabled: { _ in },
                onSetRedactNotifications: { _ in },
                onSetShowInUseInMenuBar: { _ in },
                onSetMenuBarWindow: { _, _ in },
                onSetMenuBarDisplaysRemaining: { _ in },
                onSetPopoverLayout: { _ in },
                onOpenSetupGuide: {},
                onAllowNotifications: {}
            )
            .frame(width: 560, height: 1500)

            let rep = renderHosted(view, size: NSSize(width: 560, height: 1500), dark: dark)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            try write(rep, "settings-features-\(dark ? "dark" : "light").png")
        }
    }

    // MARK: Cards

    private func creditCard() -> AccountPresentation {
        let id = UUID()
        let record = AccountRecord(
            id: id, provider: .claude, label: "Work", webProfileID: UUID(),
            displayOrder: 0, createdAt: now
        )
        let snapshot = UsageSnapshot(
            accountID: id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.7, resetsAt: now.addingTimeInterval(3 * 3600)),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: now.addingTimeInterval(4 * 86_400)),
            resetCredits: ResetCredits(
                fetchedAt: now.addingTimeInterval(-60),
                items: [ResetCredit(id: "c1", title: "Launch reset", count: 1, expiresAt: now.addingTimeInterval(20 * 86_400), usableNow: true)],
                complete: true
            )
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    private func height(_ view: some View) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 480).background(Theme.ink))
        let image = try XCTUnwrap(renderer.cgImage)
        return CGFloat(image.height)
    }

    func testResetsOffDropsTheCardsResetLine() throws {
        let presentation = creditCard()
        XCTAssertNotNil(ResetCreditsSummary.make(credits: presentation.snapshot?.resetCredits, leadDays: 1, now: now), "premise")
        let on = try height(AccountCardView(presentation: presentation, onReauthenticate: {}, now: now))
        let off = try height(AccountCardView(presentation: presentation, onReauthenticate: {}, showsResetCredits: false, now: now))
        XCTAssertLessThan(off, on, "the reset line takes space only while Resets is on")
    }
}

/// Reports "enabled" and never touches the real login-item registry.
private final class StaticLaunchAtLoginService: LaunchAtLoginService {
    var status: LaunchAtLoginServiceStatus { .enabled }
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettings() {}
}
