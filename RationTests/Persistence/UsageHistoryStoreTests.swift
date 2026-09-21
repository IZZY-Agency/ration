import XCTest
@testable import Ration

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    private func account(_ id: UUID = UUID(), provider: Provider = .claude) -> AccountRecord {
        AccountRecord(id: id, provider: provider, label: "A", webProfileID: UUID(), displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))
    }
    private func snapshot(_ id: UUID, _ t: TimeInterval, five: Double?, weekly: Double?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: id, fetchedAt: Date(timeIntervalSince1970: t),
            fiveHour: five.map { UsageWindow(kind: .fiveHour, remainingFraction: $0, resetsAt: nil) },
            weekly: weekly.map { UsageWindow(kind: .weekly, remainingFraction: $0, resetsAt: nil) }
        )
    }

    func testRecordThenReloadPersistsRawSamples() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 0, five: 1.0, weekly: 0.9))
        store.record(account: acc, snapshot: snapshot(acc.id, 300, five: 0.8, weekly: 0.9))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir)
        await reloaded.load(activeAccountIDs: [acc.id])
        XCTAssertEqual(reloaded.rawSamples(accountID: acc.id, kind: .fiveHour).map(\.remaining), [1.0, 0.8])
    }

    func testRecordCoalescesToOneRawAndOneRollupWritePerSnapshot() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        // Count writes by destination filename.
        final class Counter: @unchecked Sendable { var urls: [URL] = [] }
        let counter = Counter()
        let store = UsageHistoryStore(
            rootDirectory: dir,
            writeObserver: { counter.urls.append($0) }
        )
        await store.load(activeAccountIDs: [acc.id])

        // A snapshot carrying BOTH windows must produce exactly two writes —
        // one raw.json and one monthly rollup — not four. Each file holds
        // both windows, so a per-kind rewrite was pure duplication.
        store.record(account: acc, snapshot: snapshot(acc.id, 0, five: 1.0, weekly: 0.9))
        await store.flush()

        XCTAssertEqual(counter.urls.count, 2, "expected 1 raw + 1 rollup write, got \(counter.urls.map(\.lastPathComponent))")
        XCTAssertEqual(counter.urls.filter { $0.lastPathComponent == "raw.json" }.count, 1)
        XCTAssertEqual(counter.urls.filter { $0.lastPathComponent.hasPrefix("rollup-") }.count, 1)
    }

    func testCorruptRawFileIsQuarantinedAndDoesNotThrow() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bad = account(); let good = account()
        let badFile = dir.appending(path: bad.id.uuidString, directoryHint: .isDirectory).appending(path: "raw.json")
        try FileManager.default.createDirectory(at: badFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: badFile)

        let store = UsageHistoryStore(rootDirectory: dir)
        await store.load(activeAccountIDs: [bad.id, good.id]) // must not throw
        XCTAssertTrue(store.rawSamples(accountID: bad.id, kind: .fiveHour).isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: badFile.deletingLastPathComponent().path)
        XCTAssertTrue(quarantined.contains(where: { $0.hasPrefix("raw.json.corrupt-") }))
    }

    func testRemoveDeletesAccountDirectory() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 0, five: 1.0, weekly: nil))
        await store.flush()
        await store.remove(accountID: acc.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: acc.id.uuidString).path))
        XCTAssertTrue(store.rawSamples(accountID: acc.id, kind: .fiveHour).isEmpty)
    }

    func testLoadPrunesOrphanDirectories() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = UUID()
        let orphanDir = dir.appending(path: orphan.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let store = UsageHistoryStore(rootDirectory: dir)
        await store.load(activeAccountIDs: []) // no active accounts
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path))
    }

    // MARK: Regression tests

    /// FIX 1 (High): `loadRaw` used to replay persisted samples through
    /// `series.ingest(...)`, re-running the downsample/reset state machine
    /// with a fresh `bucketStart` and silently collapsing a persisted
    /// multi-sample weekly series on every reload. This test records a weekly
    /// sequence at a 300s cadence spanning one 900s bucket (weekly's
    /// `minSpacing` is 900s), so the downsample logic replaces within the
    /// bucket and then appends at t=900, producing a 2-sample series shaped
    /// `[t=600, t=900]` pre-reload; it must round-trip unchanged, not collapse
    /// to `[t=900]`. RED before FIX 1 (post-reload count == 1, data loss);
    /// GREEN after.
    func testWeeklyReplayRoundTripsWithoutLoss() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 0, five: nil, weekly: 0.90))
        store.record(account: acc, snapshot: snapshot(acc.id, 300, five: nil, weekly: 0.85))
        store.record(account: acc, snapshot: snapshot(acc.id, 600, five: nil, weekly: 0.80))
        store.record(account: acc, snapshot: snapshot(acc.id, 900, five: nil, weekly: 0.75))
        await store.flush()

        let preReload = store.rawSamples(accountID: acc.id, kind: .weekly)
        XCTAssertEqual(preReload.map(\.ts.timeIntervalSince1970), [600, 900], "pre-reload series must be the downsampled [600,900] shape")

        let reloaded = UsageHistoryStore(rootDirectory: dir)
        await reloaded.load(activeAccountIDs: [acc.id])
        let postReload = reloaded.rawSamples(accountID: acc.id, kind: .weekly)

        XCTAssertEqual(postReload.count, preReload.count, "reload must not collapse the persisted weekly series")
        XCTAssertEqual(postReload.map(\.ts.timeIntervalSince1970), preReload.map(\.ts.timeIntervalSince1970))
        for (before, after) in zip(preReload, postReload) {
            XCTAssertEqual(after.remaining, before.remaining, accuracy: 1e-9)
        }
    }

    /// FIX 7 (Low): `load` used to decode the envelope but ignore `version`,
    /// silently importing unknown-schema data as if it were v1. An unknown
    /// version must be treated like a corrupt file: quarantined, empty result.
    func testUnsupportedEnvelopeVersionIsQuarantined() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let file = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory).appending(path: "raw.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":2,"data":{}}"#.utf8).write(to: file)

        let store = UsageHistoryStore(rootDirectory: dir)
        await store.load(activeAccountIDs: [acc.id])
        XCTAssertTrue(store.rawSamples(accountID: acc.id, kind: .fiveHour).isEmpty)
        XCTAssertTrue(store.rawSamples(accountID: acc.id, kind: .weekly).isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertTrue(quarantined.contains(where: { $0.hasPrefix("raw.json.corrupt-") }))
    }

    /// FIX 4 (High): a `record()` landing while `remove(accountID:)` is
    /// suspended at its `persistTail` barrier must not resurrect the
    /// directory being deleted. This test uses `writeObserver` — invoked
    /// synchronously on the MainActor from inside the in-flight persist
    /// Task, i.e. exactly during `remove`'s barrier suspension — to trigger
    /// a second `record()` deterministically at that point, without a
    /// separate gating mechanism. `remove` is called with no prior
    /// `flush()`, so it must perform its own barrier.
    func testRemoveBarrierWaitsForGatedWriteAndDoesNotResurrect() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let reentrantSnapshot = snapshot(acc.id, 1, five: 0.5, weekly: nil)
        var store: UsageHistoryStore!
        var reentrantRecordFired = false
        var remainingSeenAfterReentrantRecord: [Double] = []
        store = UsageHistoryStore(rootDirectory: dir, writeObserver: { _ in
            guard !reentrantRecordFired else { return }
            reentrantRecordFired = true
            // The observer fires synchronously on the MainActor from inside the
            // in-flight persist Task — i.e. exactly while `remove` is suspended
            // at its `persistTail` barrier. A well-behaved store must gate this
            // record so it neither mutates memory nor enqueues a new write.
            store.record(account: acc, snapshot: reentrantSnapshot)
            // Directly prove the reentrant record was gated: it must NOT have
            // appended its (remaining: 0.5) sample. (If the gate were broken
            // this would be [1.0, 0.5]; only the pre-remove 1.0 sample survives.)
            remainingSeenAfterReentrantRecord = store.rawSamples(accountID: acc.id, kind: .fiveHour).map(\.remaining)
        })
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 0, five: 1.0, weekly: nil))
        await store.remove(accountID: acc.id) // no flush() first: remove() must barrier itself
        await store.flush() // drain any write a broken gate might have sneaked past the barrier

        let dirURL = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        XCTAssertTrue(reentrantRecordFired, "the gated record should have attempted to land during the remove barrier")
        XCTAssertEqual(remainingSeenAfterReentrantRecord.count, 1, "reentrant record must be gated, not appended")
        XCTAssertEqual(remainingSeenAfterReentrantRecord.first ?? -1, 1.0, accuracy: 1e-9, "the surviving sample must be the pre-remove 1.0 sample")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirURL.path), "directory must not be resurrected")
        XCTAssertTrue(store.rawSamples(accountID: acc.id, kind: .fiveHour).isEmpty, "in-memory state must be cleared")
    }
}
