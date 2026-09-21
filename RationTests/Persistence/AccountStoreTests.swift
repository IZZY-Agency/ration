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
}
