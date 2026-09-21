import Foundation
import XCTest
@testable import Ration

final class PersistenceTests: XCTestCase {
    func testJSONFileStoreLoadsFromDirectoryContainingSpaces() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "values.json")
        let store = JSONFileStore<[String]>(fileURL: fileURL, defaultValue: [])

        try await store.save(["persisted"])

        let restored = JSONFileStore<[String]>(fileURL: fileURL, defaultValue: [])
        let values = try await restored.load()

        XCTAssertEqual(values, ["persisted"])
    }

    @MainActor
    func testAccountsPersistInNormalizedUserOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "accounts.json")
        let first = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            label: "First",
            displayOrder: 9
        )
        let second = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            label: "Second",
            displayOrder: 3
        )
        let store = AccountStore(fileURL: fileURL)

        try await store.load()
        try await store.add(first)
        try await store.add(second)
        try await store.rename(id: second.id, label: "Primary")
        try await store.move(id: second.id, to: 0)

        let restored = AccountStore(fileURL: fileURL)
        try await restored.load()

        XCTAssertEqual(restored.accounts.map(\.id), [second.id, first.id])
        XCTAssertEqual(restored.accounts.map(\.label), ["Primary", "First"])
        XCTAssertEqual(restored.accounts.map(\.displayOrder), [0, 1])
    }

    @MainActor
    func testSavingSnapshotReplacesPreviousSnapshotForAccount() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "snapshots.json")
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let first = UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: nil,
            weekly: nil
        )
        let second = UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: nil,
            weekly: nil
        )
        let store = UsageSnapshotStore(fileURL: fileURL)

        try await store.load()
        try await store.save(first)
        try await store.save(second)

        let restored = UsageSnapshotStore(fileURL: fileURL)
        try await restored.load()

        XCTAssertEqual(restored.snapshot(for: accountID), second)
        XCTAssertEqual(restored.count, 1)
    }

    @MainActor
    func testRemovingAccountAndSnapshotPersistsDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountURL = directory.appending(path: "accounts.json")
        let snapshotURL = directory.appending(path: "snapshots.json")
        let account = makeAccount(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            label: "Removable",
            displayOrder: 0
        )
        let snapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: nil,
            weekly: nil
        )
        let accounts = AccountStore(fileURL: accountURL)
        let snapshots = UsageSnapshotStore(fileURL: snapshotURL)

        try await accounts.load()
        try await snapshots.load()
        try await accounts.add(account)
        try await snapshots.save(snapshot)
        try await accounts.remove(id: account.id)
        try await snapshots.remove(accountID: account.id)

        let restoredAccounts = AccountStore(fileURL: accountURL)
        let restoredSnapshots = UsageSnapshotStore(fileURL: snapshotURL)
        try await restoredAccounts.load()
        try await restoredSnapshots.load()

        XCTAssertTrue(restoredAccounts.accounts.isEmpty)
        XCTAssertNil(restoredSnapshots.snapshot(for: account.id))
    }

    @MainActor
    func testRestoringAccountReturnsItToOriginalPosition() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(
            fileURL: directory.appending(path: "accounts.json")
        )
        let first = makeAccount(id: UUID(), label: "First", displayOrder: 0)
        let middle = makeAccount(id: UUID(), label: "Middle", displayOrder: 1)
        let last = makeAccount(id: UUID(), label: "Last", displayOrder: 2)
        try await store.load()
        try await store.add(first)
        try await store.add(middle)
        try await store.add(last)
        try await store.remove(id: middle.id)

        try await store.restore(middle, at: 1)

        XCTAssertEqual(store.accounts.map(\.label), ["First", "Middle", "Last"])
        XCTAssertEqual(store.accounts.map(\.displayOrder), [0, 1, 2])
    }

    @MainActor
    func testAddingDuplicateAccountIDIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(
            fileURL: directory.appending(path: "accounts.json")
        )
        let account = makeAccount(id: UUID(), label: "Account", displayOrder: 0)
        try await store.load()
        try await store.add(account)

        do {
            try await store.add(account)
            XCTFail("Expected duplicate ID to be rejected")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .accountAlreadyExists)
        }
        XCTAssertEqual(store.accounts.count, 1)
    }

    @MainActor
    func testConcurrentAccountAddsPreserveBothRecords() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = FirstSaveGate<[AccountRecord]>()
        let store = AccountStore(
            fileURL: directory.appending(path: "accounts.json"),
            saveAccounts: { await gate.save($0) }
        )
        try await store.load()
        let first = makeAccount(id: UUID(), label: "First", displayOrder: 0)
        let second = makeAccount(id: UUID(), label: "Second", displayOrder: 1)

        let firstSave = Task { try await store.add(first) }
        await gate.waitUntilFirstSave()
        let secondSave = Task { try await store.add(second) }
        await Task.yield()
        XCTAssertEqual(gate.saveCount, 1)
        gate.resumeFirstSave()
        try await firstSave.value
        try await secondSave.value

        XCTAssertEqual(Set(store.accounts.map(\.id)), Set([first.id, second.id]))
    }

    @MainActor
    func testConcurrentSnapshotSavesPreserveDifferentAccounts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = FirstSaveGate<[UUID: UsageSnapshot]>()
        let store = UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json"),
            saveSnapshots: { await gate.save($0) }
        )
        try await store.load()
        let first = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: nil,
            weekly: nil
        )
        let second = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: nil,
            weekly: nil
        )

        let firstSave = Task { try await store.save(first) }
        await gate.waitUntilFirstSave()
        let secondSave = Task { try await store.save(second) }
        await Task.yield()
        XCTAssertEqual(gate.saveCount, 1)
        gate.resumeFirstSave()
        try await firstSave.value
        try await secondSave.value

        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.snapshot(for: first.accountID), first)
        XCTAssertEqual(store.snapshot(for: second.accountID), second)
    }

    @MainActor
    func testConcurrentPendingEnqueuesPreserveBothProfileIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = FirstSaveGate<Set<UUID>>()
        let store = PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending.json"),
            saveProfileIDs: { await gate.save($0) }
        )
        try await store.load()
        let firstID = UUID()
        let secondID = UUID()

        let firstSave = Task { try await store.enqueue(firstID) }
        await gate.waitUntilFirstSave()
        let secondSave = Task { try await store.enqueue(secondID) }
        await Task.yield()
        XCTAssertEqual(gate.saveCount, 1)
        gate.resumeFirstSave()
        try await firstSave.value
        try await secondSave.value

        XCTAssertEqual(store.profileIDs, Set([firstID, secondID]))
    }

    @MainActor
    func testLoadingDropsAccountsSharingAWebProfileID() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "accounts.json")
        let sharedProfileID = UUID()
        let first = AccountRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            provider: .claude,
            label: "First",
            webProfileID: sharedProfileID,
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = AccountRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
            provider: .claude,
            label: "Second",
            webProfileID: sharedProfileID,
            displayOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        // Seed a valid-but-corrupt accounts file: two logical accounts sharing
        // one webProfileID (a mis-migration). Written through the same
        // JSONFileStore the AccountStore reads, so the encoding matches.
        let seedStore = JSONFileStore<[AccountRecord]>(
            fileURL: fileURL,
            defaultValue: []
        )
        try await seedStore.save([first, second])

        let store = AccountStore(fileURL: fileURL)
        try await store.load()

        // First-wins: the duplicate is dropped rather than allowed to share a
        // cached WebView / cookie store with the first account.
        XCTAssertEqual(store.accounts.map(\.label), ["First"])
        XCTAssertEqual(store.accounts.map(\.webProfileID), [sharedProfileID])
    }

    @MainActor
    func testLoadingKeepsDistinctAccountAfterCrossedCollision() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "accounts.json")
        let idA = UUID()
        let idB = UUID()
        let profile1 = UUID()
        let profile2 = UUID()
        // A/profile1, then B/profile1 (dup profile), then B/profile2 (dup id but
        // a DISTINCT profile). Only an accepted record may claim identifiers, so
        // the rejected B/profile1 must NOT consume id B — otherwise the genuinely
        // distinct B/profile2 would be wrongly dropped.
        let a = AccountRecord(
            id: idA, provider: .claude, label: "A",
            webProfileID: profile1, displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let bDupProfile = AccountRecord(
            id: idB, provider: .claude, label: "B-dup-profile",
            webProfileID: profile1, displayOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let bDistinct = AccountRecord(
            id: idB, provider: .claude, label: "B-distinct",
            webProfileID: profile2, displayOrder: 2,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let seedStore = JSONFileStore<[AccountRecord]>(
            fileURL: fileURL,
            defaultValue: []
        )
        try await seedStore.save([a, bDupProfile, bDistinct])

        let store = AccountStore(fileURL: fileURL)
        try await store.load()

        XCTAssertEqual(store.accounts.map(\.label), ["A", "B-distinct"])
        XCTAssertEqual(store.accounts.map(\.webProfileID), [profile1, profile2])
    }

    private func makeAccount(
        id: UUID,
        label: String,
        displayOrder: Int
    ) -> AccountRecord {
        AccountRecord(
            id: id,
            provider: .claude,
            label: label,
            webProfileID: UUID(),
            displayOrder: displayOrder,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

@MainActor
private final class FirstSaveGate<Value> {
    private(set) var saveCount = 0
    private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ value: Value) async {
        saveCount += 1
        guard saveCount == 1 else { return }
        firstSaveWaiters.forEach { $0.resume() }
        firstSaveWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFirstSave() async {
        guard saveCount == 0 else { return }
        await withCheckedContinuation { firstSaveWaiters.append($0) }
    }

    func resumeFirstSave() {
        continuation?.resume()
        continuation = nil
    }
}
