import XCTest
@testable import Ration

/// Billing-cycle v2, end to end through `UsageHistoryStore`:
/// fixed-window boundaries from a moved reset time, both peaks of a
/// boundary hour, and an interval across a month boundary.
@MainActor
final class UsageHistoryBoundaryStoreTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    /// Jul 1 2026 00:00 UTC: the cycle start (renewal day 1).
    private var cycleStart: Date { calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))! }

    private func account(_ provider: Provider) -> AccountRecord {
        AccountRecord(id: UUID(), provider: provider, label: "A", webProfileID: UUID(), displayOrder: 0,
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    private func record(
        _ store: UsageHistoryStore, _ acc: AccountRecord, _ kind: UsageWindowKind,
        at seconds: TimeInterval, remaining: Double, resetsAt: Date
    ) {
        let window = UsageWindow(kind: kind, remainingFraction: remaining, resetsAt: resetsAt)
        let at = cycleStart.addingTimeInterval(seconds)
        let snapshot: UsageSnapshot
        switch kind {
        case .fiveHour: snapshot = UsageSnapshot(accountID: acc.id, fetchedAt: at, fiveHour: window, weekly: nil)
        default: snapshot = UsageSnapshot(accountID: acc.id, fetchedAt: at, fiveHour: nil, weekly: window)
        }
        store.record(account: acc, snapshot: snapshot)
    }

    private func summary(
        _ buckets: [UsageHourlyBucket], _ kind: UsageWindowKind, family: WindowFamily, nowHour: Int
    ) -> CycleUtilizationSummary {
        let now = cycleStart.addingTimeInterval(Double(nowHour) * 3600)
        let cycle = BillingCycle.current(renewalDay: 1, now: now, calendar: calendar)
        return BillingCycleAnalyzer.summarize(
            buckets: buckets, windowKind: kind, family: family, cycle: cycle, calendar: calendar)
    }

    /// The review's case: remaining falls to 50%, the weekly window resets
    /// (ChatGPT's reset time moves) and heavy use takes it to 40% before the
    /// next poll. `detectReset` sees no refill; the moved reset time still
    /// splits the instances: peaks 50% and 60%, mean 55% (not 60%).
    func testChatGPTMovedResetTimeSeparatesInstances() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.chatGPT)
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await store.load(activeAccountIDs: [acc.id])
        let firstReset = cycleStart.addingTimeInterval(11 * 3600)
        let secondReset = firstReset.addingTimeInterval(7 * 86_400)
        for step in 0..<132 { // 00:00 → 10:55, every 5 min, 1.0 → 0.5
            let remaining = 1 - 0.5 * Double(step) / 131
            record(store, acc, .weekly, at: Double(step) * 300, remaining: remaining, resetsAt: firstReset)
        }
        for step in 132..<240 { // 11:00 → 19:55: the new instance, already at 0.4
            record(store, acc, .weekly, at: Double(step) * 300, remaining: 0.4, resetsAt: secondReset)
        }
        let buckets = await store.loadRollups(accountID: acc.id, kind: .weekly)
        XCTAssertEqual(buckets.reduce(0) { $0 + ($1.resetCount ?? 0) }, 1)
        XCTAssertEqual(summary(buckets, .weekly, family: .fixed, nowHour: 20).capacityUtilization, 0.55, accuracy: 1e-9)
    }

    /// Claude's rolling reset time moves every poll: it never marks a boundary.
    func testClaudeMovingResetTimeIsNeverABoundary() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.claude)
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await store.load(activeAccountIDs: [acc.id])
        for step in 0..<48 {
            let at = Double(step) * 300
            let rolling = cycleStart.addingTimeInterval(at + 7 * 86_400)
            record(store, acc, .weekly, at: at, remaining: 0.6, resetsAt: rolling)
        }
        let buckets = await store.loadRollups(accountID: acc.id, kind: .weekly)
        XCTAssertEqual(buckets.reduce(0) { $0 + ($1.resetCount ?? -100) }, 0)
        let observed = buckets.reduce(0.0) { $0 + ($1.observedSeconds ?? 0) }
        XCTAssertEqual(observed, 47 * 300, accuracy: 1e-6, "every interval is integrated")
    }

    /// A 5-hour instance that reaches 100% only in the hour it resets: its
    /// peak is 100%. The new instance peaks at 20%; the mean is 60%.
    func testInstanceThatPeaksInItsResetHourKeepsItsPeak() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.chatGPT)
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await store.load(activeAccountIDs: [acc.id])
        let firstReset = cycleStart.addingTimeInterval(10 * 3600 + 3000)
        let secondReset = firstReset.addingTimeInterval(5 * 3600)
        for step in 0...120 { // 00:00 → 10:00: 1.0 → 0.4 (60% at most)
            record(store, acc, .fiveHour, at: Double(step) * 300, remaining: 1 - 0.6 * Double(step) / 120,
                   resetsAt: firstReset)
        }
        for step in 1...8 { // 10:05 → 10:40: 0.4 → 0.0 (100%)
            record(store, acc, .fiveHour, at: 36_000 + Double(step) * 300, remaining: 0.4 - 0.05 * Double(step),
                   resetsAt: firstReset)
        }
        record(store, acc, .fiveHour, at: 36_000 + 2700, remaining: 0, resetsAt: firstReset)
        record(store, acc, .fiveHour, at: 36_000 + 3000, remaining: 1.0, resetsAt: secondReset) // reset
        record(store, acc, .fiveHour, at: 36_000 + 3300, remaining: 0.95, resetsAt: secondReset)
        for step in 0..<108 { // 11:00 → 19:55: 0.95 → 0.8
            record(store, acc, .fiveHour, at: 39_600 + Double(step) * 300, remaining: 0.95 - 0.15 * Double(step) / 107,
                   resetsAt: secondReset)
        }
        let buckets = await store.loadRollups(accountID: acc.id, kind: .fiveHour)
        let resetHour = buckets.first { $0.hourStart == cycleStart.addingTimeInterval(36_000) }
        XCTAssertEqual(resetHour?.preBoundaryMinRemaining ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(resetHour?.postBoundaryMinRemaining ?? -1, 0.95, accuracy: 1e-12)
        let s = summary(buckets, .fiveHour, family: .fixed, nowHour: 20)
        XCTAssertEqual(s.capacityUtilization, (1.0 + 0.2) / 2, accuracy: 1e-9)
    }

    // MARK: Month boundary

    /// 23:55 → 00:05 across Jul 31 / Aug 1 at a steady 40% load: five minutes
    /// and 120 used-seconds land in each month's hour, nothing dropped or
    /// counted twice, and both month files hold their part after a reload.
    func testIntervalAcrossAMonthBoundaryFoldsIntoBothMonths() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.claude)
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await store.load(activeAccountIDs: [acc.id])
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let offset = midnight.timeIntervalSince(cycleStart)
        let reset = midnight.addingTimeInterval(86_400)
        record(store, acc, .weekly, at: offset - 300, remaining: 0.6, resetsAt: reset)
        record(store, acc, .weekly, at: offset + 300, remaining: 0.6, resetsAt: reset)
        try await assertSplit(store: store, acc: acc, midnight: midnight)

        await store.flush()
        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await reloaded.load(activeAccountIDs: [acc.id])
        try await assertSplit(store: reloaded, acc: acc, midnight: midnight)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: dir.appending(path: acc.id.uuidString).path(percentEncoded: false))
        XCTAssertTrue(files.contains("rollup-2026-07.json"))
        XCTAssertTrue(files.contains("rollup-2026-08.json"))
    }

    /// The same boundary when the app starts in the new month: the earlier
    /// month is only on disk and is read back to take its part.
    func testMonthBoundaryAfterARestartReadsTheEarlierMonthFromDisk() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.claude)
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let offset = midnight.timeIntervalSince(cycleStart)
        let reset = midnight.addingTimeInterval(86_400)
        let first = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await first.load(activeAccountIDs: [acc.id])
        record(first, acc, .weekly, at: offset - 300, remaining: 0.6, resetsAt: reset)
        await first.flush()

        let second = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await second.load(activeAccountIDs: [acc.id])
        record(second, acc, .weekly, at: offset + 300, remaining: 0.6, resetsAt: reset)
        try await assertSplit(store: second, acc: acc, midnight: midnight)
        await second.flush()
        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await reloaded.load(activeAccountIDs: [acc.id])
        try await assertSplit(store: reloaded, acc: acc, midnight: midnight)
    }

    /// In one poll the 5-hour window crosses July → August
    /// (its earlier part folds into July) while the model-weekly window was
    /// last sampled in June. The June interval is far over the gap limit, so
    /// June is not even loaded, and July's contribution survives persist and
    /// reload.
    func testAStaleWindowDoesNotDiscardAnotherWindowsMonthCrossing() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.claude)
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let june = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 23, minute: 50))!
        let reset = midnight.addingTimeInterval(86_400)
        func window(_ kind: UsageWindowKind) -> UsageWindow {
            UsageWindow(kind: kind, remainingFraction: 0.6, resetsAt: reset)
        }
        let store = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: UsageSnapshot(
            accountID: acc.id, fetchedAt: june, fiveHour: nil, weekly: nil, modelWeekly: window(.modelWeekly)))
        store.record(account: acc, snapshot: UsageSnapshot(
            accountID: acc.id, fetchedAt: midnight.addingTimeInterval(-300), fiveHour: window(.fiveHour), weekly: nil))
        store.record(account: acc, snapshot: UsageSnapshot(
            accountID: acc.id, fetchedAt: midnight.addingTimeInterval(300), fiveHour: window(.fiveHour), weekly: nil,
            modelWeekly: window(.modelWeekly)))
        await store.flush()

        let reloaded = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await reloaded.load(activeAccountIDs: [acc.id])
        let buckets = await reloaded.loadRollups(accountID: acc.id, kind: .fiveHour)
        let july = try XCTUnwrap(buckets.first { $0.hourStart == midnight.addingTimeInterval(-3600) })
        XCTAssertEqual(july.observedSeconds ?? -1, 300, accuracy: 1e-9, "July's part of the crossing is kept")
        XCTAssertEqual(july.usedSeconds ?? -1, 120, accuracy: 1e-9)
        let fable = await reloaded.loadRollups(accountID: acc.id, kind: .modelWeekly)
        XCTAssertEqual(fable.count, 2, "June's bucket and August's, nothing lost")
    }

    /// An interval over the gap limit folds nothing, so its earlier month is
    /// not read: a corrupt June file is left alone rather than quarantined.
    func testACrossingOverTheGapLimitDoesNotLoadTheEarlierMonth() async throws {
        let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acc = account(.claude)
        let june = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 23, minute: 50))!
        let august = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 0, minute: 5))!
        let window = UsageWindow(kind: .weekly, remainingFraction: 0.6, resetsAt: august.addingTimeInterval(86_400))
        let first = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await first.load(activeAccountIDs: [acc.id])
        first.record(account: acc, snapshot: UsageSnapshot(accountID: acc.id, fetchedAt: june, fiveHour: nil, weekly: window))
        await first.flush()
        let accountDir = dir.appending(path: acc.id.uuidString)
        try Data("not json".utf8).write(to: accountDir.appending(path: "rollup-2026-06.json"))

        let second = UsageHistoryStore(rootDirectory: dir, timeZone: utc)
        await second.load(activeAccountIDs: [acc.id])
        second.record(account: acc, snapshot: UsageSnapshot(accountID: acc.id, fetchedAt: august, fiveHour: nil, weekly: window))
        await second.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: accountDir.path(percentEncoded: false))
        XCTAssertTrue(files.contains("rollup-2026-06.json"), "June was not read: \(files)")
    }

    private func assertSplit(
        store: UsageHistoryStore, acc: AccountRecord, midnight: Date,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let buckets = await store.loadRollups(accountID: acc.id, kind: .weekly)
        XCTAssertEqual(buckets.count, 2, file: file, line: line)
        let july = try XCTUnwrap(buckets.first { $0.hourStart == midnight.addingTimeInterval(-3600) }, file: file, line: line)
        let august = try XCTUnwrap(buckets.first { $0.hourStart == midnight }, file: file, line: line)
        XCTAssertEqual(july.observedSeconds ?? -1, 300, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(july.usedSeconds ?? -1, 120, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(august.observedSeconds ?? -1, 300, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(august.usedSeconds ?? -1, 120, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(july.sampleCount, 1, file: file, line: line)
        XCTAssertEqual(august.sampleCount, 1, file: file, line: line)
    }
}
