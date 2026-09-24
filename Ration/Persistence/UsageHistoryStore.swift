import Combine
import Foundation

/// Off-main-actor file I/O for the store. `persistTail` stays `@MainActor`
/// for ordering, but the actual `createDirectory`/`Data.write` syscalls
/// happen here so they cannot block refresh/UI (FIX 3). The read side
/// serves `loadRollups`' unbounded directory scan for the same reason: with
/// unlimited rollup retention the History-window read grows with app
/// lifetime and must not run on the main actor.
actor HistoryFileIO {
    func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Lists `dir` and reads every `prefix…suffix` file, sorted by name.
    /// An unreadable file is skipped (matching the old inline
    /// `guard let data = try? …` behavior) — unreadable is not corrupt.
    /// Writes are atomic, so a read concurrent with a persist sees an
    /// old-or-new complete file, never a torn one.
    /// `minimumName`, when set, skips every entry that sorts before it —
    /// with `rollup-YYYY-MM.json` names, "only this month and later".
    func readFiles(
        inDirectory dir: URL,
        prefix: String,
        suffix: String,
        minimumName: String? = nil
    ) -> [HistoryFilePayload] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else { return [] }
        var result: [HistoryFilePayload] = []
        for entry in entries.sorted() where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            if let minimumName, entry < minimumName { continue }
            let url = dir.appending(path: entry)
            guard let data = try? Data(contentsOf: url) else { continue }
            result.append(HistoryFilePayload(url: url, data: data))
        }
        return result
    }
}

struct HistoryFilePayload: Sendable {
    let url: URL
    let data: Data
}

@MainActor
final class UsageHistoryStore: ObservableObject {
    @Published private(set) var rawSeries: [UUID: [UsageWindowKind: UsageWindowSeries]] = [:]

    private let rootDirectory: URL
    private let timeZone: TimeZone
    private let now: () -> Date
    private let writeObserver: ((URL) -> Void)?
    /// Test-only interleave seam: awaited once per `loadRollups` call, right
    /// after the FIRST off-main directory scan returns and before the decode
    /// and month-key re-check. Lets a test deterministically land `record()`
    /// calls in the window the scan cannot see — the first-touch/month-roll
    /// races the re-read defends against. Nil (no-op) in production.
    private let afterRollupScan: (@MainActor () async -> Void)?
    private let writer = HistoryFileIO()
    private var persistTail = Task<Void, Never> {}

    /// In-memory current-month rollup segment per account. Holds only
    /// the *active* capture-zone month; older months live on disk and are read
    /// back on demand by `loadRollups`.
    private var currentMonths: [UUID: RollupMonth] = [:]

    private struct RollupMonth {
        let key: String // "YYYY-MM" in the capture zone
        var fiveHour: [Date: UsageHourlyBucket]
        var weekly: [Date: UsageHourlyBucket]
        var modelWeekly: [Date: UsageHourlyBucket]

        func buckets(for kind: UsageWindowKind) -> [Date: UsageHourlyBucket] {
            switch kind {
            case .fiveHour: fiveHour
            case .weekly: weekly
            case .modelWeekly: modelWeekly
            }
        }
        mutating func set(_ buckets: [Date: UsageHourlyBucket], for kind: UsageWindowKind) {
            switch kind {
            case .fiveHour: fiveHour = buckets
            case .weekly: weekly = buckets
            case .modelWeekly: modelWeekly = buckets
            }
        }
    }

    struct RollupMonthData: Codable, Sendable {
        var fiveHour: [UsageHourlyBucket]
        var weekly: [UsageHourlyBucket]
        var modelWeekly: [UsageHourlyBucket]

        init(fiveHour: [UsageHourlyBucket], weekly: [UsageHourlyBucket], modelWeekly: [UsageHourlyBucket]) {
            self.fiveHour = fiveHour
            self.weekly = weekly
            self.modelWeekly = modelWeekly
        }

        // BACKWARD-COMPAT DECODE: rollup files written before the modelWeekly
        // (Fable) kind existed have NO "modelWeekly" key at all. A synthesized
        // decode would throw on the missing key and (via `loadMonth`'s
        // catch → quarantine-and-treat-as-empty path) destroy that month's
        // fiveHour/weekly data too. `decodeIfPresent(...) ?? []` instead
        // defaults modelWeekly to empty while leaving the existing keys intact.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try c.decode([UsageHourlyBucket].self, forKey: .fiveHour)
            weekly = try c.decode([UsageHourlyBucket].self, forKey: .weekly)
            modelWeekly = try c.decodeIfPresent([UsageHourlyBucket].self, forKey: .modelWeekly) ?? []
        }
    }

    /// Account ids currently mid-`remove(accountID:)`. Guards against a
    /// `record()` landing during the `remove` barrier suspension and
    /// resurrecting a directory that is being deleted (FIX 4).
    private var removingAccountIDs: Set<UUID> = []

    /// `load(activeAccountIDs:)` is a one-time startup operation; a later
    /// call must not clobber in-memory state recorded since (FIX 4).
    private var didLoad = false

    init(
        rootDirectory: URL,
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = { .now },
        writeObserver: ((URL) -> Void)? = nil,
        afterRollupScan: (@MainActor () async -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.timeZone = timeZone
        self.now = now
        self.writeObserver = writeObserver
        self.afterRollupScan = afterRollupScan
    }

    // MARK: Load

    func load(activeAccountIDs: Set<UUID>) async {
        guard !didLoad else { return }
        didLoad = true
        pruneOrphans(activeAccountIDs: activeAccountIDs)
        var loaded: [UUID: [UsageWindowKind: UsageWindowSeries]] = [:]
        for id in activeAccountIDs {
            loaded[id] = loadRaw(accountID: id)
        }
        rawSeries = loaded
    }

    private func loadRaw(accountID: UUID) -> [UsageWindowKind: UsageWindowSeries] {
        let url = rawFileURL(accountID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try Self.decoder().decode(UsageHistoryEnvelope<[String: [UsageHistorySample]]>.self, from: data)
            guard envelope.version == 1 else { // FIX 7: unknown schema version, don't import as v1
                quarantine(url)
                return [:]
            }
            var result: [UsageWindowKind: UsageWindowSeries] = [:]
            for (rawKind, samples) in envelope.data {
                guard let kind = UsageWindowKind(rawValue: rawKind) else { continue }
                // FIX 1: assign persisted samples directly; do NOT replay through
                // `ingest`, which would re-run the downsample/reset state machine
                // with a fresh `bucketStart` and silently drop weekly samples.
                result[kind] = UsageWindowSeries(kind: kind, restoredSamples: samples)
            }
            return result
        } catch {
            quarantine(url)
            return [:]
        }
    }

    private func quarantine(_ url: URL) {
        let stamp = Int(now().timeIntervalSince1970)
        let uuidPrefix = UUID().uuidString.prefix(8) // FIX 5: avoid same-second collisions clobbering the move
        let target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).corrupt-\(stamp)-\(uuidPrefix)")
        try? FileManager.default.moveItem(at: url, to: target)
    }

    private func pruneOrphans(activeAccountIDs: Set<UUID>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path(percentEncoded: false)) else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry), !activeAccountIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: rootDirectory.appending(path: entry, directoryHint: .isDirectory))
        }
    }

    // MARK: Record (synchronous, enqueue-and-return, nonthrowing)

    func record(account: AccountRecord, snapshot: UsageSnapshot) {
        // FIX 4: don't resurrect a deleting account. Checked ONCE here — `record`
        // runs synchronously on the main actor with no suspension before the
        // enqueues below, so a single guard covers all windows (equivalent to
        // the old per-ingest check).
        guard !removingAccountIDs.contains(account.id) else { return }

        // Ingest all windows into the in-memory series + current-month
        // rollup FIRST, then persist ONCE. `raw.json` and the monthly rollup
        // file each hold ALL windows, so the old per-kind persist rewrote each
        // file twice per snapshot (up to 4 atomic writes/poll). All windows
        // share the snapshot timestamp, so they fold into the same month —
        // publish once, encode `raw.json` once, persist the one changed rollup
        // once (down to 2 writes/poll).
        // Driven by the canonical `allWindows` collection rather than a
        // hand-listed slot per kind: a newly added kind is ingested here
        // automatically instead of being silently skipped by this one
        // subsystem while every other subsystem handled it.
        var didAccept = false
        for (kind, window) in snapshot.allWindows {
            let accepted = ingestSample(
                account: account, kind: kind, window: window, ts: snapshot.fetchedAt
            )
            didAccept = didAccept || accepted
        }
        guard didAccept else { return }

        enqueueRawPersist(accountID: account.id)
        if let month = currentMonths[account.id] {
            enqueueRollupPersist(accountID: account.id, month: month)
        }
    }

    /// Ingests one window into the in-memory raw series and current-month
    /// rollup, WITHOUT enqueuing any file write (the caller coalesces the writes
    /// across all windows). Returns whether the sample was accepted.
    @discardableResult
    private func ingestSample(account: AccountRecord, kind: UsageWindowKind, window: UsageWindow?, ts: Date) -> Bool {
        guard let window else { return false }
        let sample = UsageHistorySample(ts: ts, remaining: window.remainingFraction, resetsAt: window.resetsAt)
        var series = rawSeries[account.id]?[kind] ?? UsageWindowSeries(kind: kind)
        let isClaudeFiveHour = account.provider == .claude && kind == .fiveHour
        let outcome = series.ingest(sample, isClaudeFiveHour: isClaudeFiveHour)
        // FIX 2: write the mutated series back unconditionally — a rejected
        // sample still flips `isProjectionEligible` to false, and that flag
        // flip must not be lost just because the sample itself was rejected.
        rawSeries[account.id, default: [:]][kind] = series
        guard case let .accepted(previous, didReset) = outcome else { return false }
        foldRollup(accountID: account.id, kind: kind, previous: previous, sample: sample, didReset: didReset)
        return true
    }

    private func enqueueRawPersist(accountID: UUID) {
        let url = rawFileURL(accountID)
        let payload: [String: [UsageHistorySample]] = Dictionary(
            uniqueKeysWithValues: (rawSeries[accountID] ?? [:]).map { ($0.key.rawValue, $0.value.samples) }
        )
        let data = try? Self.encoder().encode(UsageHistoryEnvelope(data: payload))
        let observer = writeObserver
        let writer = writer
        let previous = persistTail
        persistTail = Task { @MainActor in
            await previous.value
            guard let data else { return }
            let ok = await writer.write(data, to: url) // FIX 3: actual I/O runs off the main actor
            if ok {
                observer?(url) // FIX 6: only fire the observer on a successful write
            } else {
                print("UsageHistoryStore: failed to persist raw history to \(url.path(percentEncoded: false))")
            }
        }
    }

    /// Folds one accepted sample into the account's in-memory current-month
    /// rollup. Persistence is enqueued ONCE by `record` after each window folds
    /// — all windows share the snapshot's month, so they land in the same
    /// `currentMonths[accountID]` segment.
    private func foldRollup(accountID: UUID, kind: UsageWindowKind, previous: UsageHistorySample?, sample: UsageHistorySample, didReset: Bool) {
        let key = monthKey(for: sample.ts)
        if currentMonths[accountID]?.key != key {
            // Roll to (or first-touch) the sample's month segment, loading it if on disk.
            currentMonths[accountID] = loadMonth(accountID: accountID, key: key)
        }
        var month = currentMonths[accountID] ?? RollupMonth(key: key, fiveHour: [:], weekly: [:], modelWeekly: [:])
        var buckets = month.buckets(for: kind)
        UsageHourlyRollup.fold(previous: previous, sample: sample, didReset: didReset, into: &buckets, timeZone: timeZone)
        month.set(buckets, for: kind)
        currentMonths[accountID] = month
    }

    private func enqueueRollupPersist(accountID: UUID, month: RollupMonth) {
        let url = rollupFileURL(accountID, key: month.key)
        let data = try? Self.encoder().encode(UsageHistoryEnvelope(data: RollupMonthData(
            fiveHour: month.fiveHour.values.sorted { $0.hourStart < $1.hourStart },
            weekly: month.weekly.values.sorted { $0.hourStart < $1.hourStart },
            modelWeekly: month.modelWeekly.values.sorted { $0.hourStart < $1.hourStart }
        )))
        let observer = writeObserver
        let writer = writer
        let previous = persistTail
        persistTail = Task { @MainActor in
            await previous.value
            guard let data else { return }
            let ok = await writer.write(data, to: url) // FIX 3: actual I/O runs off the main actor
            if ok {
                observer?(url) // FIX 6: only fire the observer on a successful write
            } else {
                print("UsageHistoryStore: failed to persist rollup history to \(url.path(percentEncoded: false))")
            }
        }
    }

    /// History-window read. The directory scan, file reads, and JSON decode
    /// all run OFF the main actor: with unlimited rollup retention the
    /// scan grows with app lifetime, and this is called from the History
    /// window on every open and kind toggle.
    func loadRollups(accountID: UUID, kind: UsageWindowKind) async -> [UsageHourlyBucket] {
        await persistTail.value // ensure pending writes are on disk
        let dir = rootDirectory.appending(path: accountID.uuidString, directoryHint: .isDirectory)
        let monthKeyBeforeRead = currentMonths[accountID]?.key
        let files = await writer.readFiles(inDirectory: dir, prefix: "rollup-", suffix: ".json")
        await afterRollupScan?() // test-only interleave seam; nil in production
        var decoded = await Self.decodeRollups(files, kind: kind)

        // Month-segment change: if a `record()` landing mid-read FOLDED into a
        // month this scan may have missed (or captured stale/corrupt) and the
        // in-memory segment key CHANGED — including from nil, the first-touch
        // case: fold into month A, then a second sample rolls to month B, all
        // during one read — then the captured files can miss month A's fold
        // AND hold a since-rewritten version of its file. Every such fold's
        // persist was enqueued by its own `record()`, so one barrier + one
        // re-read makes both the fold and the rewritten file visible. Two
        // month boundaries inside the RETRY's read are not defended.
        if currentMonths[accountID]?.key != monthKeyBeforeRead {
            await persistTail.value
            let refreshed = await writer.readFiles(inDirectory: dir, prefix: "rollup-", suffix: ".json")
            decoded = await Self.decodeRollups(refreshed, kind: kind)
        }

        // Corrupt / unknown-version files are quarantined, mirroring
        // the raw tier, rather than silently skipped (and later overwritten
        // by the next record, destroying that month). The move stays on the
        // main actor (rare path, `now()` lives here) — EXCEPT the account's
        // live in-memory month: `record()` rewrites exactly that file, so a
        // valid replacement may have landed between our read and this point,
        // and quarantining the path now could move fresh valid data away.
        // Skipping it is safe: the overlay below serves that month's data,
        // and the next rollup persist rewrites the file wholesale (self-heal)
        // — while `loadMonth` already quarantines it on the record path
        // if the corruption survives until the next month-touch.
        let liveMonthURL = currentMonths[accountID].map { rollupFileURL(accountID, key: $0.key) }
        for url in decoded.corruptURLs where url != liveMonthURL {
            quarantine(url)
        }

        var byHourStart = decoded.byHourStart
        // Freshness overlay: a `record()` can land while the read above is
        // off-main. The in-memory current-month segment is a superset of its
        // file at all times (`loadMonth` seeds it FROM the file before the
        // first fold), so overlaying it last-wins makes the result at least
        // as fresh as this call for that month.
        if let month = currentMonths[accountID] {
            for bucket in month.buckets(for: kind).values {
                byHourStart[bucket.hourStart] = bucket
            }
        }
        return byHourStart.values.sorted { $0.hourStart < $1.hourStart }
    }

    /// Bounded read for the Fable verdict: `kinds` from only the rollup
    /// months that can hold a bucket at or after `since` — the cutoff month
    /// and the one before it, for files captured in another time zone (older
    /// months are neither read nor decoded), filtered to `since` off the main actor.
    /// Same barrier, month-change re-read, quarantine and live-month overlay
    /// as `loadRollups`. Each kind's buckets are sorted by `hourStart`.
    func loadRecentRollups(
        accountID: UUID,
        kinds: [UsageWindowKind],
        since: Date
    ) async -> [UsageWindowKind: [UsageHourlyBucket]] {
        await persistTail.value // ensure pending writes are on disk
        let dir = rootDirectory.appending(path: accountID.uuidString, directoryHint: .isDirectory)
        // Files are named in their CAPTURE time zone, which may differ from
        // today's: after a zone change the month before the cutoff month can
        // still hold in-window buckets. Start one month earlier; the
        // absolute-time `since` filter drops what is too old.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let monthBefore: Date = calendar.date(byAdding: .month, value: -1, to: since) ?? since
        let minimumName = "rollup-\(monthKey(for: monthBefore)).json"
        let monthKeyBeforeRead = currentMonths[accountID]?.key
        let files = await writer.readFiles(
            inDirectory: dir, prefix: "rollup-", suffix: ".json", minimumName: minimumName
        )
        await afterRollupScan?() // test-only interleave seam; nil in production
        var decoded = await Self.decodeRecentRollups(files, kinds: kinds, since: since)
        if currentMonths[accountID]?.key != monthKeyBeforeRead {
            await persistTail.value
            let refreshed = await writer.readFiles(
                inDirectory: dir, prefix: "rollup-", suffix: ".json", minimumName: minimumName
            )
            decoded = await Self.decodeRecentRollups(refreshed, kinds: kinds, since: since)
        }

        let liveMonthURL = currentMonths[accountID].map { rollupFileURL(accountID, key: $0.key) }
        for url in decoded.corruptURLs where url != liveMonthURL {
            quarantine(url)
        }

        var result: [UsageWindowKind: [UsageHourlyBucket]] = [:]
        for kind in kinds {
            var byHourStart = decoded.byKind[kind] ?? [:]
            if let month = currentMonths[accountID] {
                for bucket in month.buckets(for: kind).values where bucket.hourStart >= since {
                    byHourStart[bucket.hourStart] = bucket
                }
            }
            result[kind] = byHourStart.values.sorted { $0.hourStart < $1.hourStart }
        }
        return result
    }

    /// Off-main decode for `loadRecentRollups`: every file decoded once for
    /// all `kinds`, buckets before `since` dropped.
    nonisolated static func decodeRecentRollups(
        _ files: [HistoryFilePayload],
        kinds: [UsageWindowKind],
        since: Date
    ) async -> (byKind: [UsageWindowKind: [Date: UsageHourlyBucket]], corruptURLs: [URL]) {
        let decoder = Self.decoder()
        var byKind: [UsageWindowKind: [Date: UsageHourlyBucket]] = [:]
        var corrupt: [URL] = []
        for file in files {
            do {
                let env = try decoder.decode(UsageHistoryEnvelope<RollupMonthData>.self, from: file.data)
                guard env.version == 1 else {
                    corrupt.append(file.url)
                    continue
                }
                for kind in kinds {
                    let bucketsForKind: [UsageHourlyBucket]
                    switch kind {
                    case .fiveHour: bucketsForKind = env.data.fiveHour
                    case .weekly: bucketsForKind = env.data.weekly
                    case .modelWeekly: bucketsForKind = env.data.modelWeekly
                    }
                    for bucket in bucketsForKind where bucket.hourStart >= since {
                        byKind[kind, default: [:]][bucket.hourStart] = bucket
                    }
                }
            } catch {
                corrupt.append(file.url)
            }
        }
        return (byKind, corrupt)
    }

    /// Off-main decode + merge of rollup files (following the
    /// off-main-decode pattern: `nonisolated async` so it executes off the
    /// caller's actor, `Sendable` payloads only).
    nonisolated static func decodeRollups(
        _ files: [HistoryFilePayload],
        kind: UsageWindowKind
    ) async -> (byHourStart: [Date: UsageHourlyBucket], corruptURLs: [URL]) {
        let decoder = Self.decoder()
        // Dedupe by `hourStart` (last-wins) instead of trusting each
        // file's array to have unique keys — a malformed rollup file must not
        // duplicate an hour's contribution.
        var byHourStart: [Date: UsageHourlyBucket] = [:]
        var corrupt: [URL] = []
        for file in files {
            do {
                let env = try decoder.decode(UsageHistoryEnvelope<RollupMonthData>.self, from: file.data)
                guard env.version == 1 else {
                    corrupt.append(file.url)
                    continue
                }
                let bucketsForKind: [UsageHourlyBucket]
                switch kind {
                case .fiveHour: bucketsForKind = env.data.fiveHour
                case .weekly: bucketsForKind = env.data.weekly
                case .modelWeekly: bucketsForKind = env.data.modelWeekly
                }
                for bucket in bucketsForKind {
                    byHourStart[bucket.hourStart] = bucket
                }
            } catch {
                corrupt.append(file.url)
            }
        }
        return (byHourStart, corrupt)
    }

    private func loadMonth(accountID: UUID, key: String) -> RollupMonth {
        let url = rollupFileURL(accountID, key: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return RollupMonth(key: key, fiveHour: [:], weekly: [:], modelWeekly: [:])
        }
        do {
            let data = try Data(contentsOf: url)
            let env = try Self.decoder().decode(UsageHistoryEnvelope<RollupMonthData>.self, from: data)
            // Unsupported schema version → quarantine, don't treat as
            // empty-then-overwrite.
            guard env.version == 1 else {
                quarantine(url)
                return RollupMonth(key: key, fiveHour: [:], weekly: [:], modelWeekly: [:])
            }
            // `uniqueKeysWithValues` TRAPS on a duplicate `hourStart` in a
            // malformed rollup file. Last-wins dedupe instead, on this
            // record/refresh path where a crash is unacceptable.
            func map(_ b: [UsageHourlyBucket]) -> [Date: UsageHourlyBucket] {
                Dictionary(b.map { ($0.hourStart, $0) }, uniquingKeysWith: { _, latest in latest })
            }
            return RollupMonth(key: key, fiveHour: map(env.data.fiveHour), weekly: map(env.data.weekly), modelWeekly: map(env.data.modelWeekly))
        } catch {
            // Corrupt current-month rollup → quarantine, don't treat as
            // empty-then-overwrite (which would destroy the file's contents on
            // the next persisted write).
            quarantine(url)
            return RollupMonth(key: key, fiveHour: [:], weekly: [:], modelWeekly: [:])
        }
    }

    private func rollupFileURL(_ accountID: UUID, key: String) -> URL {
        rootDirectory.appending(path: accountID.uuidString, directoryHint: .isDirectory).appending(path: "rollup-\(key).json")
    }

    private func monthKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    // MARK: Reads / lifecycle

    func rawSamples(accountID: UUID, kind: UsageWindowKind) -> [UsageHistorySample] {
        rawSeries[accountID]?[kind]?.samples ?? []
    }

    /// The raw samples as they WILL read once `snapshot` is recorded, without
    /// recording it: the same ingest rules as `record`, applied to a copy.
    /// A snapshot already recorded (or older than the series) leaves the
    /// samples unchanged. Lets a pass that runs between a snapshot's save and
    /// its `record` (the alert sink) see that snapshot's activity.
    func rawSamples(
        accountID: UUID,
        kind: UsageWindowKind,
        provider: Provider,
        including snapshot: UsageSnapshot?
    ) -> [UsageHistorySample] {
        var series = rawSeries[accountID]?[kind] ?? UsageWindowSeries(kind: kind)
        guard let snapshot, let window = snapshot.window(for: kind) else { return series.samples }
        let sample = UsageHistorySample(
            ts: snapshot.fetchedAt,
            remaining: window.remainingFraction,
            resetsAt: window.resetsAt
        )
        let isClaudeFiveHour: Bool = provider == .claude && kind == .fiveHour
        _ = series.ingest(sample, isClaudeFiveHour: isClaudeFiveHour)
        return series.samples
    }

    func remove(accountID: UUID) async {
        removingAccountIDs.insert(accountID) // FIX 4: block record() before the barrier suspends
        await persistTail.value // barrier: let pending writes finish first
        rawSeries.removeValue(forKey: accountID)
        currentMonths.removeValue(forKey: accountID)
        try? FileManager.default.removeItem(at: rootDirectory.appending(path: accountID.uuidString, directoryHint: .isDirectory))
        removingAccountIDs.remove(accountID)
    }

    func flush() async { await persistTail.value }

    // MARK: Paths / codec

    private func rawFileURL(_ accountID: UUID) -> URL {
        rootDirectory.appending(path: accountID.uuidString, directoryHint: .isDirectory).appending(path: "raw.json")
    }

    nonisolated static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    nonisolated static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
