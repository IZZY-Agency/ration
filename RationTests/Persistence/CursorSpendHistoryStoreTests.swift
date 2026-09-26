import XCTest
@testable import Ration

@MainActor
final class CursorSpendHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try makeTempDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appending(path: "cursor-spend-history.json") }

    private let cycle = CursorSpendCycle(
        periodStart: Date(timeIntervalSince1970: 1_785_542_400),
        periodEnd: Date(timeIntervalSince1970: 1_788_220_800),
        spentCents: 2410,
        isClosed: true
    )

    func testUpdatePersistsAndReloads() async throws {
        let id = UUID()
        let store = CursorSpendHistoryStore(fileURL: fileURL)
        await store.load()
        try await store.update(accountID: id) { history in
            var next = history
            next.cycles = [self.cycle]
            return next
        }
        let reloaded = CursorSpendHistoryStore(fileURL: fileURL)
        await reloaded.load()
        XCTAssertEqual(reloaded.history(for: id).cycles, [cycle])
    }

    /// Totals only: the file carries the four cycle fields and the sync
    /// bookkeeping — no event, model or id of Cursor's.
    func testFileHoldsTotalsOnly() async throws {
        let id = UUID()
        let store = CursorSpendHistoryStore(fileURL: fileURL)
        try await store.update(accountID: id) { _ in
            CursorSpendHistory(cycles: [self.cycle], syncedThrough: self.cycle.periodEnd)
        }
        // `[UUID: …]` is written as a key, value, key, value array.
        let array = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [Any])
        XCTAssertEqual(array.first as? String, id.uuidString)
        let entry = try XCTUnwrap(array.last as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["cycles", "settledEmptyMonths", "syncedThrough"])
        let stored = try XCTUnwrap((entry["cycles"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(stored.keys), ["periodStart", "periodEnd", "spentCents", "isClosed"])
    }

    func testCorruptFileLoadsEmpty() async throws {
        try Data("{not json".utf8).write(to: fileURL)
        let store = CursorSpendHistoryStore(fileURL: fileURL)
        await store.load()
        XCTAssertEqual(store.histories, [:])
    }

    /// An update queued behind a removal must not bring the entry back.
    func testUpdateForAGoneAccountIsDropped() async throws {
        let id = UUID()
        let store = CursorSpendHistoryStore(fileURL: fileURL)
        try await store.update(accountID: id, isLive: { false }) { _ in
            CursorSpendHistory(cycles: [self.cycle])
        }
        XCTAssertNil(store.histories[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    func testRemoveDropsTheAccount() async throws {
        let keep = UUID()
        let drop = UUID()
        let store = CursorSpendHistoryStore(fileURL: fileURL)
        for id in [keep, drop] {
            try await store.update(accountID: id) { _ in CursorSpendHistory(cycles: [self.cycle]) }
        }
        try await store.remove(accountID: drop)
        XCTAssertNil(store.histories[drop])
        let reloaded = CursorSpendHistoryStore(fileURL: fileURL)
        await reloaded.load()
        XCTAssertEqual(Set(reloaded.histories.keys), [keep])
    }

    private final class Switch {
        var fails = false
    }

    private struct SaveFailed: Error {}

    private func failableStore(_ failing: Switch) -> CursorSpendHistoryStore {
        let fileStore = JSONFileStore<[UUID: CursorSpendHistory]>(fileURL: fileURL, defaultValue: [:])
        return CursorSpendHistoryStore(fileURL: fileURL, saveHistories: { histories in
            if failing.fails {
                throw SaveFailed()
            }
            try await fileStore.save(histories)
        })
    }

    /// A remove whose save fails stays recorded on disk; the next launch
    /// scrubs the entry even though nothing else ever writes.
    func testFailedRemoveIsRecordedAndScrubbedOnTheNextLaunch() async throws {
        let id = UUID()
        let failing = Switch()
        let store = failableStore(failing)
        try await store.update(accountID: id) { _ in CursorSpendHistory(cycles: [self.cycle]) }
        failing.fails = true
        do {
            try await store.remove(accountID: id)
            XCTFail("expected the save to fail")
        } catch {}
        XCTAssertEqual(store.pendingDeletions, [id])

        let relaunched = CursorSpendHistoryStore(fileURL: fileURL)
        await relaunched.load()
        XCTAssertNil(relaunched.histories[id])
        XCTAssertEqual(relaunched.pendingDeletions, [])
        let onDisk = CursorSpendHistoryStore(fileURL: fileURL)
        await onDisk.load()
        XCTAssertNil(onDisk.histories[id], "gone from the file")
    }

    /// Any later write scrubs a recorded deletion too.
    func testLaterWriteScrubsARecordedDeletion() async throws {
        let gone = UUID()
        let other = UUID()
        let failing = Switch()
        let store = failableStore(failing)
        try await store.update(accountID: gone) { _ in CursorSpendHistory(cycles: [self.cycle]) }
        failing.fails = true
        try? await store.remove(accountID: gone)
        failing.fails = false
        try await store.update(accountID: other) { _ in CursorSpendHistory(cycles: [self.cycle]) }
        XCTAssertNil(store.histories[gone])
        XCTAssertEqual(store.pendingDeletions, [])
    }

    /// A file that does not decode is deleted at load: removed accounts'
    /// totals in it could otherwise linger forever.
    func testMalformedFileIsScrubbedAtLoad() async throws {
        let id = UUID()
        try Data("[\"\(id.uuidString)\", {\"cycles\": 12".utf8).write(to: fileURL)
        let store = CursorSpendHistoryStore(fileURL: fileURL)
        await store.load()
        XCTAssertEqual(store.histories, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        try await store.remove(accountID: id)
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(id.uuidString))
    }
}
