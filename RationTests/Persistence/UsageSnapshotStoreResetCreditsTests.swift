import XCTest
@testable import Ration

@MainActor
final class UsageSnapshotStoreResetCreditsTests: XCTestCase {
    private let id = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func list(_ at: Date, _ ids: [String]) -> ResetCredits {
        ResetCredits(fetchedAt: at, items: ids.map {
            ResetCredit(id: $0, title: nil, count: 1, expiresAt: at.addingTimeInterval(86_400 * 30), usableNow: nil)
        }, complete: true)
    }

    private func snap(_ at: Date, _ credits: ResetCredits?, org: String? = nil) -> UsageSnapshot {
        UsageSnapshot(accountID: id, fetchedAt: at, fiveHour: nil, weekly: nil, organizationID: org, resetCredits: credits)
    }

    private func makeStore() -> UsageSnapshotStore {
        UsageSnapshotStore(fileURL: URL(fileURLWithPath: "/dev/null"), saveSnapshots: { _ in })
    }

    func testUnreadListIsCarriedForwardWithItsOriginalFetchedAt() async throws {
        let store = makeStore()
        try await store.save(snap(t0, list(t0, ["a"])))
        try await store.save(snap(t0.addingTimeInterval(300), nil))
        let stored = try XCTUnwrap(store.snapshot(for: id))
        XCTAssertEqual(stored.fetchedAt, t0.addingTimeInterval(300))
        XCTAssertEqual(stored.resetCredits, list(t0, ["a"]), "carried unchanged, old fetchedAt")
    }

    func testAuthoritativeEmptyListReplacesPrevious() async throws {
        let store = makeStore()
        try await store.save(snap(t0, list(t0, ["a"])))
        try await store.save(snap(t0.addingTimeInterval(300), list(t0.addingTimeInterval(300), [])))
        XCTAssertEqual(store.snapshot(for: id)?.resetCredits?.items, [])
    }

    func testOrganizationChangeDropsCarriedList() async throws {
        let store = makeStore()
        try await store.save(snap(t0, list(t0, ["a"]), org: "org-A"))
        try await store.save(snap(t0.addingTimeInterval(300), nil, org: "org-B"))
        XCTAssertNil(store.snapshot(for: id)?.resetCredits)
    }

    func testUnknownPreviousOrganizationStillCarries() async throws {
        // After a relaunch the org id is never persisted, so it is nil.
        let store = makeStore()
        try await store.save(snap(t0, list(t0, ["a"]), org: nil))
        try await store.save(snap(t0.addingTimeInterval(300), nil, org: "org-B"))
        XCTAssertEqual(store.snapshot(for: id)?.resetCredits?.items.map(\.id), ["a"])
    }

    func testCarryForwardSurvivesPersistenceRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "snapshots.json")
        let first = UsageSnapshotStore(fileURL: url)
        try await first.save(snap(t0, list(t0, ["a"]), org: "org-A"))
        let relaunched = UsageSnapshotStore(fileURL: url)
        try await relaunched.load()
        try await relaunched.save(snap(t0.addingTimeInterval(300), nil, org: "org-A"))
        XCTAssertEqual(relaunched.snapshot(for: id)?.resetCredits?.items.map(\.id), ["a"])
    }
}
