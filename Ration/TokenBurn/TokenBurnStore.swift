import Foundation

/// The token-burn store (spec §5.5): one SQLite file. A log file's checkpoint,
/// its usage rows and its reply keys commit in one transaction, so a crash
/// mid-file replays that file cleanly and nothing is ever counted twice. A
/// counted reply stays counted — the usage happened — whatever later becomes
/// of the file it was first read from.
/// Keeps no path, text or id: files by (device, inode, birth), replies by a
/// 64-bit hash. Not thread-safe: the scanner actor owns it.
final class TokenBurnStore {
    /// 3: usage per UTC minute, sign-in spans, organization bindings (spec §10).
    static let schemaVersion = 3

    struct FileIdentity: Hashable, Sendable {
        let device: Int64
        let inode: Int64
        /// Birth time in nanoseconds: a reused inode is a different file.
        let birth: Int64
    }

    struct FileState: Equatable, Sendable {
        var checkpoint: Int64
        var size: Int64
        var mtime: Int64 = 0
        var tail: Int64 = 0
        var gone: Bool
    }

    /// One file's pass, or one batch of it. With `rebuild` the file is being
    /// read again from the top: its line counters restart; the replies it
    /// counted stay, so re-read ones are duplicates.
    struct FilePass: Sendable {
        let identity: FileIdentity
        var rebuild = false
        var replies: [ReplyUsage] = []
        var checkpoint: Int64
        var size: Int64
        var malformed = 0
        var oversized = 0
        var mtime: Int64 = 0
        var tail: Int64 = 0
    }

    struct CommitResult: Equatable, Sendable {
        var counted = 0
        var duplicates = 0
    }

    struct UsageTotal: Equatable, Sendable {
        let priceClass: PriceClass
        var tokens: TokenCounts
        var webSearches: Int
        var replies: Int
    }

    struct Summary: Equatable, Sendable {
        var files = 0
        var goneFiles = 0
        var malformedLines = 0
        var oversizedLines = 0
        var replies = 0
        var webSearches = 0
        var tokens = TokenCounts()
    }

    private let db: SQLiteDatabase
    private let insertFile, selectFile, insertKey, upsertUsage, updateFile, resetFile, markFileGone: SQLiteStatement

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Nothing has shipped: a store from another schema is rebuilt.
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let existing = try SQLiteDatabase(url: url)
            let version = (try? existing.prepare("SELECT value FROM meta WHERE key = 'schema'").query())?.first?.first?.text
            existing.close()
            if version != String(Self.schemaVersion) { try Self.destroy(at: url) }
        }
        db = try SQLiteDatabase(url: url)
        try db.execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files(
              id INTEGER PRIMARY KEY, device INTEGER NOT NULL, inode INTEGER NOT NULL, birth INTEGER NOT NULL,
              checkpoint INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0,
              malformed INTEGER NOT NULL DEFAULT 0, oversized INTEGER NOT NULL DEFAULT 0,
              mtime INTEGER NOT NULL DEFAULT 0, tail INTEGER NOT NULL DEFAULT 0,
              gone INTEGER NOT NULL DEFAULT 0, UNIQUE(device, inode, birth));
            CREATE TABLE IF NOT EXISTS reply_keys(hash INTEGER PRIMARY KEY, file INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS reply_keys_file ON reply_keys(file);
            CREATE TABLE IF NOT EXISTS usage(
              file INTEGER NOT NULL, minute INTEGER NOT NULL,
              model TEXT NOT NULL, speed TEXT NOT NULL, geo TEXT NOT NULL, tier TEXT NOT NULL, long_context INTEGER NOT NULL,
              input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
              cache_5m INTEGER NOT NULL, cache_1h INTEGER NOT NULL, cache_unsplit INTEGER NOT NULL,
              web_searches INTEGER NOT NULL, replies INTEGER NOT NULL,
              PRIMARY KEY(file, minute, model, speed, geo, tier, long_context));
            CREATE INDEX IF NOT EXISTS usage_minute ON usage(minute);
            CREATE TABLE IF NOT EXISTS sign_in_spans(
              id INTEGER PRIMARY KEY, account TEXT NOT NULL, organization TEXT, billing TEXT, fetched REAL,
              first_seen REAL NOT NULL, last_seen REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS org_bindings(
              account TEXT PRIMARY KEY, organization TEXT NOT NULL, verified_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS config_writes(at REAL NOT NULL);
            INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '\(Self.schemaVersion)');
            """)
        insertFile = try db.prepare("INSERT OR IGNORE INTO files(device, inode, birth) VALUES(?, ?, ?)")
        selectFile = try db.prepare("SELECT id FROM files WHERE device = ? AND inode = ? AND birth = ?")
        insertKey = try db.prepare("INSERT OR IGNORE INTO reply_keys(hash, file) VALUES(?, ?)")
        upsertUsage = try db.prepare("""
            INSERT INTO usage(file, minute, model, speed, geo, tier, long_context, input, output, cache_read,
                              cache_5m, cache_1h, cache_unsplit, web_searches, replies)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file, minute, model, speed, geo, tier, long_context) DO UPDATE SET
              input = input + excluded.input, output = output + excluded.output,
              cache_read = cache_read + excluded.cache_read, cache_5m = cache_5m + excluded.cache_5m,
              cache_1h = cache_1h + excluded.cache_1h, cache_unsplit = cache_unsplit + excluded.cache_unsplit,
              web_searches = web_searches + excluded.web_searches, replies = replies + excluded.replies
            """)
        updateFile = try db.prepare("""
            UPDATE files SET checkpoint = ?, size = ?, malformed = malformed + ?, oversized = oversized + ?,
                             mtime = ?, tail = ?, gone = 0
            WHERE id = ?
            """)
        resetFile = try db.prepare("UPDATE files SET checkpoint = 0, malformed = 0, oversized = 0 WHERE id = ?")
        markFileGone = try db.prepare("UPDATE files SET gone = 1 WHERE id = ?")
    }

    func close() { db.close() }

    /// Deletes the database and its journals (spec §5.5 Stop and forget).
    static func destroy(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path(percentEncoded: false) + suffix)
            do { try FileManager.default.removeItem(at: file) } catch CocoaError.fileNoSuchFile {}
        }
    }

    @discardableResult
    func commit(_ pass: FilePass) throws -> CommitResult {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let identity: [SQLiteValue] = [.int(pass.identity.device), .int(pass.identity.inode), .int(pass.identity.birth)]
            try insertFile.run(identity)
            let fileID = try selectFile.query(identity)[0][0].int
            if pass.rebuild { try resetFile.run([.int(fileID)]) }
            struct Bucket: Hashable { let minute: Int64; let priceClass: PriceClass }
            var buckets: [Bucket: (tokens: TokenCounts, searches: Int, replies: Int)] = [:]
            var result = CommitResult()
            for reply in pass.replies {
                try insertKey.run([.int(reply.key.hash64), .int(fileID)])
                guard db.changes == 1 else { result.duplicates += 1; continue }
                result.counted += 1
                let bucket = Bucket(minute: reply.minute, priceClass: reply.priceClass)
                buckets[bucket, default: (TokenCounts(), 0, 0)].tokens += reply.tokens
                buckets[bucket]!.searches += reply.webSearches
                buckets[bucket]!.replies += 1
            }
            for (bucket, sum) in buckets {
                let c = bucket.priceClass, t = sum.tokens
                try upsertUsage.run([.int(fileID), .int(bucket.minute), .text(c.model), .text(c.speed), .text(c.geo), .text(c.tier),
                                     .int(c.longContext ? 1 : 0), .int(Int64(t.input)), .int(Int64(t.output)),
                                     .int(Int64(t.cacheRead)), .int(Int64(t.cacheWrite5m)), .int(Int64(t.cacheWrite1h)),
                                     .int(Int64(t.cacheWriteUnsplit)), .int(Int64(sum.searches)), .int(Int64(sum.replies))])
            }
            try updateFile.run([.int(pass.checkpoint), .int(pass.size), .int(Int64(pass.malformed)),
                                .int(Int64(pass.oversized)), .int(pass.mtime), .int(pass.tail), .int(fileID)])
            try db.execute("COMMIT")
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func fileStates() throws -> [FileIdentity: FileState] {
        let rows = try db.prepare("SELECT device, inode, birth, checkpoint, size, mtime, tail, gone FROM files").query()
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (FileIdentity(device: row[0].int, inode: row[1].int, birth: row[2].int),
             FileState(checkpoint: row[3].int, size: row[4].int, mtime: row[5].int, tail: row[6].int, gone: row[7].int != 0))
        })
    }

    /// Files no longer on disk keep what they counted (spec §5.1).
    func markGone(notIn seen: Set<FileIdentity>) throws {
        let rows = try db.prepare("SELECT id, device, inode, birth FROM files WHERE gone = 0").query()
        let gone = rows.filter { !seen.contains(FileIdentity(device: $0[1].int, inode: $0[2].int, birth: $0[3].int)) }
        guard !gone.isEmpty else { return }
        try db.execute("BEGIN IMMEDIATE")
        do {
            for row in gone { try markFileGone.run([row[0]]) }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Usage in `[fromMinute, toMinute)`, summed per price class.
    func totals(fromMinute: Int64, toMinute: Int64) throws -> [UsageTotal] {
        try db.prepare("""
            SELECT model, speed, geo, tier, long_context, SUM(input), SUM(output), SUM(cache_read), SUM(cache_5m),
                   SUM(cache_1h), SUM(cache_unsplit), SUM(web_searches), SUM(replies)
            FROM usage WHERE minute >= ? AND minute < ? GROUP BY model, speed, geo, tier, long_context
            """).query([.int(fromMinute), .int(toMinute)]).map { Self.usageTotal($0, from: 0) }
    }

    /// Usage in `[fromMinute, toMinute)` per minute and price class, minutes
    /// ascending: what attribution splits between owners (spec §10).
    func minuteTotals(fromMinute: Int64, toMinute: Int64) throws -> [(minute: Int64, total: UsageTotal)] {
        try db.prepare("""
            SELECT minute, model, speed, geo, tier, long_context, SUM(input), SUM(output), SUM(cache_read), SUM(cache_5m),
                   SUM(cache_1h), SUM(cache_unsplit), SUM(web_searches), SUM(replies)
            FROM usage WHERE minute >= ? AND minute < ? GROUP BY minute, model, speed, geo, tier, long_context ORDER BY minute
            """).query([.int(fromMinute), .int(toMinute)]).map { ($0[0].int, Self.usageTotal($0, from: 1)) }
    }

    private static func usageTotal(_ r: [SQLiteValue], from i: Int) -> UsageTotal {
        UsageTotal(priceClass: PriceClass(model: r[i].text, speed: r[i + 1].text, geo: r[i + 2].text, tier: r[i + 3].text,
                                          longContext: r[i + 4].int != 0),
                   tokens: TokenCounts(input: Int(r[i + 5].int), output: Int(r[i + 6].int), cacheRead: Int(r[i + 7].int),
                                       cacheWrite5m: Int(r[i + 8].int), cacheWrite1h: Int(r[i + 9].int),
                                       cacheWriteUnsplit: Int(r[i + 10].int)),
                   webSearches: Int(r[i + 11].int), replies: Int(r[i + 12].int))
    }

    // MARK: Sign-in spans and organization bindings (spec §10)

    /// One reading of Claude Code's sign-in. It extends the latest span when
    /// the identity and `fetchedAt` are both unchanged and Ration has not
    /// written the sign-in since that span was last seen, however long ago
    /// (no login, no profile refresh and no Ration write happened in between);
    /// otherwise it starts a span (spec §10.1). No sign-in records nothing.
    func observe(_ identity: SignInIdentity?, fetchedAt: Date?, at date: Date) throws {
        guard let identity else { return }
        let latest = try db.prepare("""
            SELECT id, account, organization, billing, fetched, last_seen FROM sign_in_spans ORDER BY id DESC LIMIT 1
            """).query().first
        let writtenSince = try latest.map { row in
            try db.prepare("SELECT COUNT(*) FROM config_writes WHERE at > ? AND at <= ?")
                .query([row[5], .double(date.timeIntervalSince1970)])[0][0].int > 0
        } ?? false
        if let latest, !writtenSince, Self.identity(latest, from: 1) == identity, Self.date(latest[4]) == fetchedAt {
            try db.prepare("UPDATE sign_in_spans SET last_seen = MAX(last_seen, ?) WHERE id = ?")
                .run([.double(date.timeIntervalSince1970), latest[0]])
            return
        }
        try db.prepare("""
            INSERT INTO sign_in_spans(account, organization, billing, fetched, first_seen, last_seen) VALUES(?, ?, ?, ?, ?, ?)
            """).run([.text(identity.accountUUID), identity.organizationUUID.map { .text($0) } ?? .null,
                      identity.billingType.map { .text($0) } ?? .null,
                      fetchedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                      .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)])
    }

    func signInSpans() throws -> [SignInSpan] {
        try db.prepare("""
            SELECT account, organization, billing, fetched, first_seen, last_seen FROM sign_in_spans ORDER BY id
            """).query().map { row in
            SignInSpan(identity: Self.identity(row, from: 0), fetchedAt: Self.date(row[3]),
                       firstSeen: Self.date(row[4]) ?? .distantPast, lastSeen: Self.date(row[5]) ?? .distantPast)
        }
    }

    /// Ration wrote Claude Code's sign-in (a switch, its rollback, launch
    /// recovery), successful or not: evidence the next reading must respect.
    /// Readings and writes are recorded in the order they happened.
    func recordConfigWrite(at date: Date) throws {
        try db.prepare("INSERT INTO config_writes(at) VALUES(?)").run([.double(date.timeIntervalSince1970)])
    }

    /// A switch from the switcher's log, which keeps whole seconds: the
    /// switch finished within the second it names, so the end of that second
    /// is the boundary (never before the write). Skipped when a write within
    /// it is already recorded (heard live, or seeded before).
    func recordLoggedSwitch(at date: Date) throws {
        let second = date.timeIntervalSince1970.rounded(.down)
        try db.prepare("""
            INSERT INTO config_writes(at) SELECT ?
            WHERE NOT EXISTS (SELECT 1 FROM config_writes WHERE at >= ? AND at <= ?)
            """).run([.double(second + 1), .double(second - 1), .double(second + 1)])
    }

    func configWrites() throws -> [Date] {
        try db.prepare("SELECT at FROM config_writes ORDER BY at").query().compactMap { Self.date($0[0]) }
    }

    /// Account removal (spec §10.1): the usage in these minutes goes; the
    /// reply keys stay, so the logs are not counted again.
    func deleteUsage(minutes: some Sequence<Int64>) throws {
        let statement = try db.prepare("DELETE FROM usage WHERE minute = ?")
        try db.execute("BEGIN IMMEDIATE")
        do {
            for minute in minutes { try statement.run([.int(minute)]) }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func deleteSpans(of identities: Set<SignInIdentity>) throws {
        let statement = try db.prepare("""
            DELETE FROM sign_in_spans WHERE account = ? AND organization IS ? AND billing IS ?
            """)
        for identity in identities {
            try statement.run([.text(identity.accountUUID), identity.organizationUUID.map { .text($0) } ?? .null,
                               identity.billingType.map { .text($0) } ?? .null])
        }
    }

    /// The organization Ration last resolved for one of its Claude accounts;
    /// kept while the account is paused or not refreshed yet.
    func setOrganization(_ organization: String, for account: UUID, at date: Date) throws {
        try db.prepare("""
            INSERT INTO org_bindings(account, organization, verified_at) VALUES(?, ?, ?)
            ON CONFLICT(account) DO UPDATE SET organization = excluded.organization, verified_at = excluded.verified_at
            """).run([.text(account.uuidString), .text(organization), .double(date.timeIntervalSince1970)])
    }

    func organizationBindings() throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        for row in try db.prepare("SELECT account, organization FROM org_bindings").query() {
            if let id = UUID(uuidString: row[0].text) { result[id] = row[1].text }
        }
        return result
    }

    func removeBinding(account: UUID) throws {
        try db.prepare("DELETE FROM org_bindings WHERE account = ?").run([.text(account.uuidString)])
    }

    private static func identity(_ row: [SQLiteValue], from i: Int) -> SignInIdentity {
        SignInIdentity(accountUUID: row[i].text, organizationUUID: optionalText(row[i + 1]), billingType: optionalText(row[i + 2]))
    }

    private static func optionalText(_ value: SQLiteValue) -> String? {
        if case .text(let text) = value { text } else { nil }
    }

    private static func date(_ value: SQLiteValue) -> Date? {
        switch value {
        case .double(let seconds): Date(timeIntervalSince1970: seconds)
        case .int(let seconds): Date(timeIntervalSince1970: TimeInterval(seconds))
        default: nil
        }
    }

    func summary() throws -> Summary {
        let files = try db.prepare("SELECT COUNT(*), SUM(gone), SUM(malformed), SUM(oversized) FROM files").query()[0]
        let usage = try db.prepare("""
            SELECT SUM(replies), SUM(web_searches), SUM(input), SUM(output), SUM(cache_read), SUM(cache_5m), SUM(cache_1h), SUM(cache_unsplit) FROM usage
            """).query()[0]
        return Summary(files: Int(files[0].int), goneFiles: Int(files[1].int), malformedLines: Int(files[2].int),
                       oversizedLines: Int(files[3].int), replies: Int(usage[0].int), webSearches: Int(usage[1].int),
                       tokens: TokenCounts(input: Int(usage[2].int), output: Int(usage[3].int), cacheRead: Int(usage[4].int),
                                           cacheWrite5m: Int(usage[5].int), cacheWrite1h: Int(usage[6].int), cacheWriteUnsplit: Int(usage[7].int)))
    }
}

/// Who Claude Code was signed in as (`~/.claude.json` › `oauthAccount`): the
/// three identity fields token burn keeps (spec §4.1).
struct SignInIdentity: Hashable, Sendable {
    let accountUUID: String
    let organizationUUID: String?
    let billingType: String?
}

/// Readings of one sign-in with one `profileFetchedAt`, first to last.
struct SignInSpan: Equatable, Sendable {
    let identity: SignInIdentity
    let fetchedAt: Date?
    let firstSeen: Date
    let lastSeen: Date
}
