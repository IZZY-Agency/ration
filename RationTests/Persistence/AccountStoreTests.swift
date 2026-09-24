import XCTest
@testable import Ration

final class AccountStoreTests: XCTestCase {
    @MainActor
    private func makeStore() -> AccountStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "accounts-\(UUID().uuidString).json")
        return AccountStore(fileURL: url, saveAccounts: { _ in })
    }
    @MainActor
    private func addClaude(_ store: AccountStore) async throws -> UUID {
        let id = UUID()
        try await store.add(AccountRecord(
            id: id, provider: .claude, label: "Work",
            webProfileID: UUID(), displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0)
        ))
        return id
    }

    @MainActor
    func testSetBillingRenewalDayPersistsAndClamps() async throws {
        let store = makeStore()
        let id = try await addClaude(store)
        try await store.setBillingRenewalDay(id: id, day: 99) // clamps to 31
        XCTAssertEqual(store.accounts.first?.billingRenewalDay, 31)
        try await store.setBillingRenewalDay(id: id, day: 14)
        XCTAssertEqual(store.accounts.first?.billingRenewalDay, 14)
    }

    @MainActor
    func testSetBillingRenewalDayZeroClampsToOne() async throws {
        let store = makeStore()
        let id = try await addClaude(store)
        try await store.setBillingRenewalDay(id: id, day: 0) // clamps to 1 (lower bound)
        XCTAssertEqual(store.accounts.first?.billingRenewalDay, 1)
    }

    @MainActor
    func testSetBillingRenewalDayNilClearsIt() async throws {
        let store = makeStore()
        let id = try await addClaude(store)
        try await store.setBillingRenewalDay(id: id, day: 14)
        try await store.setBillingRenewalDay(id: id, day: nil)
        XCTAssertNil(store.accounts.first?.billingRenewalDay)
    }

    @MainActor
    func testSetBillingRenewalDayUnknownAccountThrows() async throws {
        let store = makeStore()
        do {
            try await store.setBillingRenewalDay(id: UUID(), day: 14)
            XCTFail("expected accountNotFound")
        } catch let error as AccountStoreError {
            XCTAssertEqual(error, .accountNotFound)
        }
    }

    @MainActor
    func testSetPausedPersistsAndClears() async throws {
        let store = makeStore()
        let id = try await addClaude(store)
        XCTAssertEqual(store.accounts.first?.isPaused, false)
        try await store.setPaused(id: id, paused: true)
        XCTAssertEqual(store.accounts.first?.isPaused, true)
        try await store.setPaused(id: id, paused: false)
        XCTAssertEqual(store.accounts.first?.isPaused, false)
    }

    @MainActor
    func testSetPausedUnknownAccountThrows() async throws {
        let store = makeStore()
        do {
            try await store.setPaused(id: UUID(), paused: true)
            XCTFail("expected accountNotFound")
        } catch let error as AccountStoreError {
            XCTAssertEqual(error, .accountNotFound)
        }
    }

    @MainActor
    func testApplyDetectedPlanFillsThenRespectsUserChoice() async throws {
        let store = makeStore()
        let id = try await addClaude(store)
        try await store.applyDetectedPlan(id: id, detection: .tier(.claudeMax20x))
        XCTAssertEqual(store.accounts.first?.plan, .claudeMax20x)
        XCTAssertEqual(store.accounts.first?.planSource, .detected)

        try await store.setPlan(id: id, plan: .claudeMax5x)
        XCTAssertEqual(store.accounts.first?.planSource, .user)
        try await store.applyDetectedPlan(id: id, detection: .tier(.claudeMax20x))
        XCTAssertEqual(store.accounts.first?.plan, .claudeMax5x, "detection never overwrites a user choice")
    }

    @MainActor
    func testSetPlanNilReturnsToDetection() async throws {
        let store = makeStore()
        let id = try await addClaude(store)
        try await store.setPlan(id: id, plan: .claudePro)
        try await store.setPlan(id: id, plan: nil)
        XCTAssertNil(store.accounts.first?.plan)
        XCTAssertNil(store.accounts.first?.planSource)
        try await store.applyDetectedPlan(id: id, detection: .tier(.claudeMax20x))
        XCTAssertEqual(store.accounts.first?.plan, .claudeMax20x)
    }

    @MainActor
    func testApplyDetectedPlanSkipsSaveWhenUnchanged() async throws {
        var saves = 0
        let url = FileManager.default.temporaryDirectory.appending(path: "a-\(UUID().uuidString).json")
        let store = AccountStore(fileURL: url, saveAccounts: { _ in saves += 1 })
        let id = try await addClaude(store)
        try await store.applyDetectedPlan(id: id, detection: .tier(.claudeMax20x))
        let afterFirst = saves
        try await store.applyDetectedPlan(id: id, detection: .tier(.claudeMax20x))
        XCTAssertEqual(saves, afterFirst)
    }
}
