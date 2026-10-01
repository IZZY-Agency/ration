import XCTest
@testable import Ration

@MainActor
final class UsageSnapshotStoreUsageCreditsTests: XCTestCase {
    private let id = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func credits(_ at: Date) -> UsageCredits { UsageCreditsModelTests.credits(at: at) }

    private func snap(_ at: Date, org: String? = "org-1", credits: UsageCredits? = nil, enabled: Bool? = nil) -> UsageSnapshot {
        UsageSnapshot(accountID: id, fetchedAt: at, fiveHour: nil, weekly: nil, organizationID: org,
                      usageCredits: credits, usageCreditsEnabled: enabled)
    }

    private func makeStore() -> UsageSnapshotStore {
        UsageSnapshotStore(fileURL: URL(fileURLWithPath: "/dev/null"), saveSnapshots: { _ in })
    }

    func testAppliedReadingSurvivesTheNextUsageFetch() async throws {
        let store = makeStore()
        try await store.save(snap(t0, enabled: false))
        let written = try await store.applyUsageCredits(credits(t0.addingTimeInterval(2)), accountID: id, organizationID: "org-1")
        XCTAssertTrue(written)
        try await store.save(snap(t0.addingTimeInterval(300)))
        let stored = try XCTUnwrap(store.snapshot(for: id))
        XCTAssertEqual(stored.fetchedAt, t0.addingTimeInterval(300))
        XCTAssertEqual(stored.usageCredits, credits(t0.addingTimeInterval(2)).applied(for: "org-1"), "carried with its own fetchedAt")
        XCTAssertEqual(stored.usageCredits?.organizationID, "org-1", "tagged with the organization it was read for")
        XCTAssertEqual(stored.usageCreditsEnabled, false, "the switch is carried while a fetch does not read it")
    }

    func testAFetchThatReadsTheSwitchReplacesIt() async throws {
        let store = makeStore()
        try await store.save(snap(t0, enabled: false))
        try await store.save(snap(t0.addingTimeInterval(300), enabled: true))
        XCTAssertEqual(store.snapshot(for: id)?.usageCreditsEnabled, true)
    }

    func testOrganizationChangeDropsTheBalanceButNotTheNewSwitch() async throws {
        let store = makeStore()
        try await store.save(snap(t0, org: "org-1", enabled: false))
        try await store.applyUsageCredits(credits(t0.addingTimeInterval(2)), accountID: id, organizationID: "org-1")
        try await store.save(snap(t0.addingTimeInterval(300), org: "org-2", enabled: true))
        let stored = try XCTUnwrap(store.snapshot(for: id))
        XCTAssertNil(stored.usageCredits, "one org's balance never shows under another")
        XCTAssertEqual(stored.usageCreditsEnabled, true)
    }

    func testOrganizationChangeDoesNotCarryTheOldSwitch() async throws {
        let store = makeStore()
        try await store.save(snap(t0, org: "org-1", enabled: false))
        try await store.save(snap(t0.addingTimeInterval(300), org: "org-2", enabled: nil))
        XCTAssertNil(store.snapshot(for: id)?.usageCreditsEnabled)
    }

    func testApplyRefusesAReadingForAnotherOrganization() async throws {
        let store = makeStore()
        try await store.save(snap(t0, org: "org-2"))
        let written = try await store.applyUsageCredits(credits(t0.addingTimeInterval(2)), accountID: id, organizationID: "org-1")
        XCTAssertFalse(written)
        XCTAssertNil(store.snapshot(for: id)?.usageCredits)
    }

    /// Reads never overlap, so the latest applied is the latest read, even
    /// when the clock was set back in between.
    func testALaterReadAppliesEvenIfTheClockWentBack() async throws {
        let store = makeStore()
        try await store.save(snap(t0))
        try await store.applyUsageCredits(credits(t0.addingTimeInterval(20)), accountID: id, organizationID: "org-1")
        let written = try await store.applyUsageCredits(credits(t0.addingTimeInterval(10)), accountID: id, organizationID: "org-1")
        XCTAssertTrue(written)
        XCTAssertEqual(store.snapshot(for: id)?.usageCredits?.fetchedAt, t0.addingTimeInterval(10))
    }

    /// The organization tag lives in memory only: a file never carries it.
    func testTheOrganizationTagIsNeverWritten() throws {
        let tagged = credits(t0).applied(for: "org-1")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(tagged)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("org-1"))
        XCTAssertNil(try decoder.decode(UsageCredits.self, from: data).organizationID)
    }

    func testApplyRefusesAnAccountWithoutASnapshot() async throws {
        let store = makeStore()
        let written = try await store.applyUsageCredits(credits(t0), accountID: id, organizationID: "org-1")
        XCTAssertFalse(written)
        XCTAssertNil(store.snapshot(for: id))
    }

    /// After a relaunch the org is unknown (never persisted): the read is
    /// refused, and the next fetch, which knows its org, lets the one after
    /// it through.
    func testApplyRefusesWhenTheSnapshotDoesNotKnowItsOrganization() async throws {
        let store = makeStore()
        try await store.save(snap(t0, org: nil))
        let written = try await store.applyUsageCredits(credits(t0.addingTimeInterval(2)), accountID: id, organizationID: "org-1")
        XCTAssertFalse(written)
    }
}
