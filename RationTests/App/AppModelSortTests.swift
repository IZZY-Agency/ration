import WebKit
import XCTest
@testable import Ration

/// Verifies the weekly-reset display-sort is wired into the live
/// `presentations` pipeline: applied by default (toggle ON), and re-emitted
/// live when the toggle flips off (back to persisted `displayOrder`).
@MainActor
final class AppModelSortTests: XCTestCase {
    func testPresentationsSortBySoonestWeeklyResetByDefaultThenTogglesOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        // Account A: displayOrder 0, weekly reset FARTHER out (later).
        let sessionA = try fixture.model.beginSignIn(provider: .claude)
        let accountIDA = try XCTUnwrap(
            fixture.model.signInSession(for: sessionA)?.accountID
        )
        fixture.adapter.weeklyResetsAt[accountIDA] = Date(timeIntervalSince1970: 2_000_000)
        try await fixture.model.completeSignIn(sessionID: sessionA, label: "A")

        // Account B: displayOrder 1, weekly reset SOONER (earlier) — reverse
        // of displayOrder, per the brief.
        let sessionB = try fixture.model.beginSignIn(provider: .claude)
        let accountIDB = try XCTUnwrap(
            fixture.model.signInSession(for: sessionB)?.accountID
        )
        fixture.adapter.weeklyResetsAt[accountIDB] = Date(timeIntervalSince1970: 1_000_000)
        try await fixture.model.completeSignIn(sessionID: sessionB, label: "B")

        XCTAssertEqual(fixture.model.accounts.map(\.displayOrder), [0, 1])

        // Default: sortByWeeklyReset == true → soonest weekly reset first.
        XCTAssertEqual(
            fixture.model.presentations.map(\.account.id),
            [accountIDB, accountIDA],
            "with sorting on, the account whose weekly window resets soonest must lead"
        )

        // Toggle off → live re-sort back to persisted displayOrder.
        try await fixture.model.setSortByWeeklyReset(false)

        XCTAssertEqual(
            fixture.model.presentations.map(\.account.id),
            [accountIDA, accountIDB],
            "with sorting off, presentations must return to persisted displayOrder"
        )
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let accounts = AccountStore(
            fileURL: directory.appending(path: "accounts.json")
        )
        let snapshots = UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json")
        )
        let pendingStore = PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending-profile-deletions.json")
        )
        let historyStore = UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)
        )
        let appSettings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json")
        )
        let alertStateStore = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json")
        )
        let profileManager = SortWebProfileManagerSpy()
        let adapter = SortProviderAdapterSpy()
        let model = AppModel(
            accountStore: accounts,
            snapshotStore: snapshots,
            pendingProfileDeletionStore: pendingStore,
            historyStore: historyStore,
            appSettings: appSettings,
            alertStateStore: alertStateStore,
            profileManager: profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [adapter]),
            now: { Date(timeIntervalSince1970: 1_000) },
            systemPowerObserver: NoopSystemPowerObserver()
        )
        return Fixture(
            directory: directory,
            model: model,
            adapter: adapter
        )
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let model: AppModel
    let adapter: SortProviderAdapterSpy

    nonisolated func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class SortWebProfileManagerSpy: WebProfileManaging {
    func makeWebView(profileID: UUID) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func removeProfile(profileID: UUID) async throws {}
}

/// Returns a `UsageSnapshot` whose weekly reset is controllable per-account
/// via `weeklyResetsAt`, so a test can drive two accounts with independently
/// known weekly reset times.
@MainActor
private final class SortProviderAdapterSpy: ProviderAdapter {
    let provider = Provider.claude
    let signInURL = URL(string: "https://claude.ai/")!
    var weeklyResetsAt: [UUID: Date] = [:]
    private(set) var fetchCallCount = 0

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        fetchCallCount += 1
        let weekly = weeklyResetsAt[accountID].map {
            UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: $0)
        }
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1_000 + Double(fetchCallCount)),
            fiveHour: nil,
            weekly: weekly
        )
    }
}
