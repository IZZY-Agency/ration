import XCTest
@testable import Ration

@MainActor
final class UsageHistoryRollupStoreTests: XCTestCase {
    private func account() -> AccountRecord {
        AccountRecord(id: UUID(), provider: .claude, label: "A", webProfileID: UUID(), displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))
    }
    private func snapshot(_ id: UUID, _ t: TimeInterval, five: Double) -> UsageSnapshot {
        UsageSnapshot(accountID: id, fetchedAt: Date(timeIntervalSince1970: t), fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: five, resetsAt: nil), weekly: nil)
    }
    private func modelWeeklySnapshot(_ id: UUID, _ t: TimeInterval, remaining: Double) -> UsageSnapshot {
        UsageSnapshot(
            accountID: id, fetchedAt: Date(timeIntervalSince1970: t),
            fiveHour: nil, weekly: nil,
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: remaining, resetsAt: nil)
        )
    }

    func testRollupsPersistConsumedAndReload() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 3600, five: 1.0))
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.8))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await reloaded.load(activeAccountIDs: [acc.id])
        let buckets = await reloaded.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.consumed ?? 0, 0.2, accuracy: 1e-9)
    }

    /// Third rollup kind: a `modelWeekly` (Fable) window must record
    /// and reload just like `fiveHour`/`weekly` — mirrors
    /// `testRollupsPersistConsumedAndReload` above but for the new kind.
    func testRecordsAndLoadsModelWeeklyRollups() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: modelWeeklySnapshot(acc.id, 3600, remaining: 1.0))
        store.record(account: acc, snapshot: modelWeeklySnapshot(acc.id, 3900, remaining: 0.8))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await reloaded.load(activeAccountIDs: [acc.id])
        let buckets = await reloaded.loadRollups(accountID: acc.id, kind: .modelWeekly)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.consumed ?? 0, 0.2, accuracy: 1e-9)
    }

    /// THE MIGRATION PROOF: an existing rollup file written before the
    /// `modelWeekly` (Fable) kind existed has only `fiveHour`/`weekly` keys —
    /// no `modelWeekly` key at all. Loading it (both the direct `loadRollups`
    /// decode path AND the `loadMonth` fold path, triggered by a `record()`
    /// landing in the same month) must NOT crash and must NOT lose the
    /// existing data. `modelWeekly` must default to empty rather than
    /// throwing on the missing key.
    func testLegacyRollupFileWithoutModelWeeklyLoads() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let file = accountDir.appending(path: "rollup-1970-01.json")
        // Legacy envelope shape: no "modelWeekly" key at all.
        let json = """
        {"version":1,"data":{"fiveHour":[\
        {"hourStart":"1970-01-01T01:00:00Z","tzOffsetSeconds":0,"consumed":0.2,"minRemaining":0.8,"sampleCount":2}\
        ],"weekly":[\
        {"hourStart":"1970-01-01T01:00:00Z","tzOffsetSeconds":0,"consumed":0.1,"minRemaining":0.9,"sampleCount":1}\
        ]}}
        """
        try Data(json.utf8).write(to: file)

        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])

        // Direct decode path (e.g. History window open before any new record()):
        // no crash, existing data intact, modelWeekly defaults to empty.
        let fiveHourBuckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(fiveHourBuckets.count, 1)
        XCTAssertEqual(fiveHourBuckets.first?.consumed ?? 0, 0.2, accuracy: 1e-9)
        let weeklyBuckets = await store.loadRollups(accountID: acc.id, kind: .weekly)
        XCTAssertEqual(weeklyBuckets.count, 1)
        XCTAssertEqual(weeklyBuckets.first?.consumed ?? 0, 0.1, accuracy: 1e-9)
        let modelWeeklyBuckets = await store.loadRollups(accountID: acc.id, kind: .modelWeekly)
        XCTAssertTrue(modelWeeklyBuckets.isEmpty, "modelWeekly must default to empty on a legacy file, not crash or alias another kind's data")

        // loadMonth path: a live record() first-touching the SAME legacy month
        // must decode the legacy file without throwing and fold the new sample
        // in without losing the pre-existing fiveHour/weekly data.
        store.record(account: acc, snapshot: modelWeeklySnapshot(acc.id, 3600, remaining: 1.0))
        store.record(account: acc, snapshot: modelWeeklySnapshot(acc.id, 3900, remaining: 0.8))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await reloaded.load(activeAccountIDs: [acc.id])
        let reloadedFiveHour = await reloaded.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(reloadedFiveHour.count, 1, "legacy fiveHour data must survive a fold into the same month")
        let reloadedWeekly = await reloaded.loadRollups(accountID: acc.id, kind: .weekly)
        XCTAssertEqual(reloadedWeekly.count, 1, "legacy weekly data must survive a fold into the same month")
        let newModelWeekly = await reloaded.loadRollups(accountID: acc.id, kind: .modelWeekly)
        XCTAssertEqual(newModelWeekly.count, 1)
        XCTAssertEqual(newModelWeekly.first?.consumed ?? 0, 0.2, accuracy: 1e-9)
    }

    // MARK: v2 rollup fields (billing-cycle v2, spec §3)

    func testV2FieldsPersistAndReload() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 3600, five: 1.0))
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.8))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await reloaded.load(activeAccountIDs: [acc.id])
        let bucket = await reloaded.loadRollups(accountID: acc.id, kind: .fiveHour).first
        XCTAssertEqual(bucket?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(bucket?.usedSeconds ?? -1, 300 * (0 + 0.2) / 2, accuracy: 1e-9)
        XCTAssertEqual(bucket?.resetCount, 0)
    }

    func testStoreCensorsIntervalsLongerThanTheInjectedGapLimit() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        var limit: TimeInterval = 200
        let store = UsageHistoryStore(
            rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!, gapLimit: { limit }
        )
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 3600, five: 0.5))
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.5)) // 300 s > 200: censored
        var bucket = await store.loadRollups(accountID: acc.id, kind: .fiveHour).first
        XCTAssertEqual(bucket?.observedSeconds, 0)

        limit = 400 // the limit is read per fold, so a cadence change applies at once
        store.record(account: acc, snapshot: snapshot(acc.id, 4200, five: 0.5))
        bucket = await store.loadRollups(accountID: acc.id, kind: .fiveHour).first
        XCTAssertEqual(bucket?.observedSeconds ?? -1, 300, accuracy: 1e-9)
    }

    func testStoreDefaultGapLimitIsTwiceTheLongestNormalPoll() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(rootDirectory: dir)
        XCTAssertEqual(store.gapLimit(), PollSchedule.rollupGapLimit(lowPowerMode: false))
    }

    /// Old rollup files have no v2 keys: they decode with nil v2 fields, and a
    /// v2 sample folding into such a bucket starts the fields at that sample.
    func testLegacyRollupBucketsDecodeWithNilV2FieldsAndStartOnNextFold() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let json = """
        {"version":1,"data":{"fiveHour":[\
        {"hourStart":"1970-01-01T01:00:00Z","tzOffsetSeconds":0,"consumed":0.2,"minRemaining":0.8,"sampleCount":2}\
        ],"weekly":[],"modelWeekly":[]}}
        """
        try Data(json.utf8).write(to: accountDir.appending(path: "rollup-1970-01.json"))

        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        let legacy = await store.loadRollups(accountID: acc.id, kind: .fiveHour).first
        XCTAssertEqual(legacy?.consumed ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertNil(legacy?.observedSeconds)
        XCTAssertNil(legacy?.usedSeconds)
        XCTAssertNil(legacy?.resetCount)

        // First v2 sample in the same hour: no previous raw sample, so nothing
        // is observed yet, but the fields now exist; the second adds 300 s.
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.8))
        store.record(account: acc, snapshot: snapshot(acc.id, 4200, five: 0.7))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await reloaded.load(activeAccountIDs: [acc.id])
        let bucket = await reloaded.loadRollups(accountID: acc.id, kind: .fiveHour).first
        XCTAssertEqual(bucket?.consumed ?? -1, 0.3, accuracy: 1e-9, "legacy consumed keeps accumulating")
        XCTAssertEqual(bucket?.sampleCount, 4)
        XCTAssertEqual(bucket?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(bucket?.usedSeconds ?? -1, 300 * (0.2 + 0.3) / 2, accuracy: 1e-9)
        XCTAssertEqual(bucket?.resetCount, 0)
    }

    func testOnlyActiveMonthSegmentIsRewrittenOnIngest() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        var written: [URL] = []
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!, writeObserver: { written.append($0) })
        await store.load(activeAccountIDs: [acc.id])
        // Ten samples all inside the same month (Jan 1970).
        for i in 0..<10 { store.record(account: acc, snapshot: snapshot(acc.id, Double(i) * 300, five: 1.0 - Double(i) * 0.01)) }
        await store.flush()
        let rollupWrites = Set(written.filter { $0.lastPathComponent.hasPrefix("rollup-") })
        XCTAssertEqual(rollupWrites.count, 1) // exactly one month segment, not ten
    }

    // MARK: Regression tests

    /// `loadMonth` used to build its bucket dictionary via
    /// `Dictionary(uniqueKeysWithValues:)`, which TRAPS (crashes the process)
    /// on a duplicate `hourStart` in a malformed rollup file — reachable from
    /// the record/refresh path. `loadRollups` also used to silently duplicate
    /// an hour's contribution instead of deduping. Both must now dedupe
    /// (last-wins) and never crash. RED before the fix: this test crashes the
    /// process (fatal trap) rather than failing an assertion. GREEN after.
    func testDuplicateHourStartInRollupFileDoesNotCrashAndDedupes() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let file = accountDir.appending(path: "rollup-1970-01.json")
        let json = """
        {"version":1,"data":{"fiveHour":[\
        {"hourStart":"1970-01-01T01:00:00Z","tzOffsetSeconds":0,"consumed":0.1,"minRemaining":0.9,"sampleCount":1},\
        {"hourStart":"1970-01-01T01:00:00Z","tzOffsetSeconds":0,"consumed":0.4,"minRemaining":0.6,"sampleCount":2}\
        ],"weekly":[]}}
        """
        try Data(json.utf8).write(to: file)

        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])

        // loadRollups reads the raw file directly: must not crash and must dedupe.
        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.consumed ?? 0, 0.4, accuracy: 1e-9)

        // A record() whose sample falls in the same month triggers `loadMonth`
        // on this same malformed file: must not crash either.
        store.record(account: acc, snapshot: snapshot(acc.id, 5_400, five: 0.5))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await reloaded.load(activeAccountIDs: [acc.id])
        let postRecordBuckets = await reloaded.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(
            Set(postRecordBuckets.map(\.hourStart)).count,
            postRecordBuckets.count,
            "no duplicate hourStart keys must survive a record() cycle"
        )
    }

    /// A rollup file that fails to decode used to be treated as
    /// empty and then OVERWRITTEN by the next `record()`, silently destroying
    /// that month's data. It must instead be quarantined — mirroring the raw
    /// tier — so the corrupt bytes survive under a `.corrupt-*` sibling and a
    /// fresh rollup can be rebuilt at the original path. RED before the fix:
    /// no `.corrupt-*` file appears (the corrupt file is simply overwritten).
    /// GREEN after.
    func testCorruptCurrentMonthRollupIsQuarantinedNotOverwritten() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let file = accountDir.appending(path: "rollup-1970-01.json")
        let corruptBytes = Data("not json".utf8)
        try corruptBytes.write(to: file)

        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        // A record whose sample falls in the same month as the corrupt file
        // triggers `loadMonth` for that month.
        store.record(account: acc, snapshot: snapshot(acc.id, 3_600, five: 0.9))
        await store.flush()

        let entries = try FileManager.default.contentsOfDirectory(atPath: accountDir.path(percentEncoded: false))
        let quarantined = entries.filter { $0.hasPrefix("rollup-1970-01.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "the corrupt file must be quarantined, not silently dropped")
        let quarantinedData = try Data(contentsOf: accountDir.appending(path: quarantined[0]))
        XCTAssertEqual(quarantinedData, corruptBytes, "quarantine must preserve the original bytes untouched")

        // A fresh, valid rollup now exists at the original path (from the
        // record that followed) — the corrupt file was not silently reused.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(buckets.count, 1)
    }

    /// An unsupported rollup schema version must be quarantined
    /// (like the raw tier), not silently treated as empty-then-overwritten.
    func testUnsupportedRollupVersionIsQuarantined() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        let file = accountDir.appending(path: "rollup-1970-01.json")
        try Data(#"{"version":2,"data":{"fiveHour":[],"weekly":[]}}"#.utf8).write(to: file)

        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertTrue(buckets.isEmpty)

        let entries = try FileManager.default.contentsOfDirectory(atPath: accountDir.path(percentEncoded: false))
        XCTAssertTrue(entries.contains(where: { $0.hasPrefix("rollup-1970-01.json.corrupt-") }))
    }

    /// Overlay freshness guard: with the rollup read now off the main
    /// actor, a poll's `record()` can land mid-read. `loadRollups` must
    /// overlay the in-memory current month over whatever the disk scan
    /// returned, so the History window is always at least as fresh as the
    /// call. Deterministic proxy for that window: delete the on-disk rollup
    /// out-of-band after a flush — the current month's buckets must still
    /// come back, served from the in-memory segment.
    func testLoadRollupsOverlaysInMemoryCurrentMonthOverDiskScan() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 3600, five: 1.0))
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.8))
        await store.flush()

        // Out-of-band deletion: the disk scan now finds nothing, so anything
        // returned must have come from the in-memory current-month overlay.
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: accountDir.appending(path: "rollup-1970-01.json"))

        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.consumed ?? 0, 0.2, accuracy: 1e-9)
    }

    /// Overlay last-wins: when the on-disk current-month file is STALE
    /// relative to the in-memory segment (the disk scan raced a fold), the
    /// in-memory bucket must win. Deterministic proxy: rewrite the on-disk
    /// file with an understated bucket after a flush — the returned bucket
    /// must still be the in-memory (fresher) one.
    func testLoadRollupsPrefersInMemoryBucketOverStaleDiskBucket() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 3600, five: 1.0))
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.8))
        await store.flush()

        // Out-of-band stale rewrite: same hour, understated consumption.
        let file = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
            .appending(path: "rollup-1970-01.json")
        try Data("""
        {"version":1,"data":{"fiveHour":[\
        {"hourStart":"1970-01-01T01:00:00Z","tzOffsetSeconds":0,"consumed":0.05,"minRemaining":0.95,"sampleCount":1}\
        ],"weekly":[]}}
        """.utf8).write(to: file)

        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.consumed ?? 0, 0.2, accuracy: 1e-9, "in-memory segment must win over stale disk data")
    }

    /// Month boundary, steady state: an older month lives only on disk
    /// while the current month lives in the in-memory overlay — both must
    /// appear in one `loadRollups` result.
    func testLoadRollupsMergesOlderDiskMonthWithCurrentOverlayMonth() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: TimeZone(identifier: "UTC")!)
        await store.load(activeAccountIDs: [acc.id])
        // January 1970 samples…
        store.record(account: acc, snapshot: snapshot(acc.id, 3600, five: 1.0))
        store.record(account: acc, snapshot: snapshot(acc.id, 3900, five: 0.8))
        // …then February (2_678_400 = Feb 1 1970): the segment rolls.
        store.record(account: acc, snapshot: snapshot(acc.id, 2_678_400, five: 1.0))
        store.record(account: acc, snapshot: snapshot(acc.id, 2_678_700, five: 0.9))
        await store.flush()

        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        let january = buckets.filter { $0.hourStart < Date(timeIntervalSince1970: 2_678_400) }
        let february = buckets.filter { $0.hourStart >= Date(timeIntervalSince1970: 2_678_400) }
        XCTAssertFalse(january.isEmpty, "older month must come from the disk scan")
        XCTAssertFalse(february.isEmpty, "current month must come from the overlay")
    }

    /// First-touch-then-roll race: the in-memory
    /// segment starts nil; DURING the scan a January record first-touches the
    /// month (quarantining the corrupt on-disk file and rewriting it valid)
    /// and a February record then rolls the segment away. The key changed
    /// nil → "1970-02", so the re-read barrier MUST fire: without it, the
    /// stale scan's corrupt January URL would quarantine the freshly
    /// rewritten valid file (data loss) and January's fold would be missing
    /// from the result. The `afterRollupScan` seam pins the interleaving
    /// deterministically.
    func testFirstTouchThenRollDuringScanNeitherQuarantinesValidFileNorDropsFold() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        // Corrupt January file on disk before the scan.
        try Data("not json".utf8).write(to: accountDir.appending(path: "rollup-1970-01.json"))

        var storeRef: UsageHistoryStore?
        var fired = false
        let store = UsageHistoryStore(
            rootDirectory: dir,
            timeZone: TimeZone(identifier: "UTC")!,
            afterRollupScan: {
                guard !fired, let store = storeRef else { return } // one-shot: not on the re-read
                fired = true
                // January first-touch: loadMonth quarantines the corrupt file,
                // the fold rewrites it valid; then February rolls the segment.
                store.record(account: acc, snapshot: self.snapshot(acc.id, 3600, five: 1.0))
                store.record(account: acc, snapshot: self.snapshot(acc.id, 3900, five: 0.8))
                store.record(account: acc, snapshot: self.snapshot(acc.id, 2_678_400, five: 1.0))
                await store.flush() // land the rewrites so the barrier re-read sees them
            }
        )
        storeRef = store
        await store.load(activeAccountIDs: [acc.id])

        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)

        // January's fold must be present (re-read picked it up)…
        let january = buckets.filter { $0.hourStart < Date(timeIntervalSince1970: 2_678_400) }
        XCTAssertEqual(january.first?.consumed ?? 0, 0.2, accuracy: 1e-9, "January fold must not be dropped")
        // …and the valid rewritten January file must still be on disk —
        // exactly one quarantine artifact (loadMonth's, of the ORIGINAL
        // corrupt bytes), never a second one eating the valid rewrite.
        let entries = try FileManager.default.contentsOfDirectory(atPath: accountDir.path(percentEncoded: false))
        XCTAssertTrue(entries.contains("rollup-1970-01.json"), "valid rewritten January file must survive")
        XCTAssertEqual(entries.filter { $0.hasPrefix("rollup-1970-01.json.corrupt-") }.count, 1)
    }

    // MARK: Bounded recent read

    private func weeklyAndFable(_ id: UUID, _ t: TimeInterval, weekly: Double, fable: Double) -> UsageSnapshot {
        UsageSnapshot(
            accountID: id, fetchedAt: Date(timeIntervalSince1970: t),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: weekly, resetsAt: nil),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: fable, resetsAt: nil)
        )
    }

    /// Only months intersecting `since` are read: an older month's file is
    /// never decoded (a corrupt one would otherwise be quarantined), and
    /// buckets before `since` — on disk or in the live month — are dropped.
    func testLoadRecentRollupsReadsOnlyMonthsSinceAndFiltersToSince() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        // Two months before the cutoff month (the month before is read, for
        // files captured in another time zone).
        let december = accountDir.appending(path: "rollup-1969-12.json")
        try Data("not json".utf8).write(to: december)

        let utc = TimeZone(identifier: "UTC")!
        let feb5: TimeInterval = 35 * 86_400
        let feb15: TimeInterval = 45 * 86_400
        let since = Date(timeIntervalSince1970: 40 * 86_400)
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: weeklyAndFable(acc.id, feb5, weekly: 1.0, fable: 1.0))
        store.record(account: acc, snapshot: weeklyAndFable(acc.id, feb5 + 1_800, weekly: 0.9, fable: 0.95))
        store.record(account: acc, snapshot: weeklyAndFable(acc.id, feb15, weekly: 0.85, fable: 0.9))
        store.record(account: acc, snapshot: weeklyAndFable(acc.id, feb15 + 1_800, weekly: 0.8, fable: 0.85))
        await store.flush()

        let live = await store.loadRecentRollups(accountID: acc.id, kinds: [.weekly, .modelWeekly], since: since)
        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await reloaded.load(activeAccountIDs: [acc.id])
        let disk = await reloaded.loadRecentRollups(accountID: acc.id, kinds: [.weekly, .modelWeekly], since: since)

        for result in [live, disk] {
            for kind in [UsageWindowKind.weekly, .modelWeekly] {
                let buckets = result[kind] ?? []
                XCTAssertFalse(buckets.isEmpty, "\(kind)")
                XCTAssertTrue(buckets.allSatisfy { $0.hourStart >= since }, "\(kind): \(buckets.map(\.hourStart))")
            }
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: accountDir.path(percentEncoded: false))
        XCTAssertTrue(entries.contains("rollup-1969-12.json"), "an older month must not be read")
        XCTAssertFalse(entries.contains { $0.hasPrefix("rollup-1969-12.json.corrupt-") }, "\(entries)")
    }

    /// Files are named in their CAPTURE time zone. After a zone change the
    /// month before the cutoff month (in the current zone) can still hold
    /// in-window buckets: captured in Los Angeles, read in Paris.
    func testLoadRecentRollupsReadsThePreviousMonthFileAfterATimeZoneChange() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account()
        let accountDir = dir.appending(path: acc.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        // 1970-02-01T00:00Z is Jan 31 16:00 in Los Angeles → January's file.
        let json = """
        {"version":1,"data":{"fiveHour":[],"weekly":[\
        {"hourStart":"1970-02-01T00:00:00Z","tzOffsetSeconds":-28800,"consumed":0.1,"minRemaining":0.9,"sampleCount":1}\
        ],"modelWeekly":[]}}
        """
        try Data(json.utf8).write(to: accountDir.appending(path: "rollup-1970-01.json"))

        let paris = TimeZone(identifier: "Europe/Paris")!
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: paris)
        await store.load(activeAccountIDs: [acc.id])
        // Jan 31 23:10Z = Feb 1 00:10 in Paris: the cutoff month is February.
        let since = Date(timeIntervalSince1970: 31 * 86_400 - 50 * 60)
        let result = await store.loadRecentRollups(accountID: acc.id, kinds: [.weekly], since: since)
        XCTAssertEqual(result[.weekly]?.map(\.hourStart), [Date(timeIntervalSince1970: 31 * 86_400)])
    }
}
