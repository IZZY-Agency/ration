import XCTest
@testable import Ration

final class TokenBurnStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appending(path: "token-burn.sqlite") }

    override func setUpWithError() throws { directory = try makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func reply(_ id: String, input: Int = 100, hour: String = "2026-09-29T10:15:00Z", model: String = "claude-opus-5-5") -> ReplyUsage {
        ReplyUsage(key: ReplyKey(messageID: id, requestID: "r-\(id)"), timestamp: ISO8601DateFormatter().date(from: hour)!,
                   priceClass: PriceClass(model: model, speed: "standard", geo: "not_available", tier: "standard", longContext: false),
                   tokens: TokenCounts(input: input, output: 1), webSearches: 0)
    }

    private let fileA = TokenBurnStore.FileIdentity(device: 1, inode: 10, birth: 100)
    private let fileB = TokenBurnStore.FileIdentity(device: 1, inode: 11, birth: 100)

    private func pass(_ file: TokenBurnStore.FileIdentity, _ replies: [ReplyUsage], rebuild: Bool = false, checkpoint: Int64 = 50) -> TokenBurnStore.FilePass {
        TokenBurnStore.FilePass(identity: file, rebuild: rebuild, replies: replies, checkpoint: checkpoint, size: checkpoint)
    }

    /// Repeats in a file and copies across files count once.
    func testEachReplyCountsOnceAcrossRepeatsAndFiles() throws {
        let store = try TokenBurnStore(url: url)
        XCTAssertEqual(try store.commit(pass(fileA, [reply("1"), reply("1"), reply("2")])), .init(counted: 2, duplicates: 1))
        XCTAssertEqual(try store.commit(pass(fileB, [reply("2"), reply("3")])), .init(counted: 1, duplicates: 1))
        let summary = try store.summary()
        XCTAssertEqual(summary.replies, 3)
        XCTAssertEqual(summary.tokens.input, 300)
    }

    /// A counted reply stays counted (the usage happened),
    /// so re-reading a file from the top neither doubles nor forgets anything.
    func testRebuildRereadsWithoutForgettingOrDoubleCounting() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1"), reply("2")]))
        XCTAssertEqual(try store.commit(pass(fileA, [reply("1"), reply("3")], rebuild: true)), .init(counted: 1, duplicates: 1))
        XCTAssertEqual(try store.summary().replies, 3)
        XCTAssertEqual(try store.summary().tokens.input, 300)
    }

    /// A pass that fails before COMMIT leaves no trace — its
    /// keys too — so the retry counts it fully. The fault is a trigger added
    /// through a second connection; nothing in the store knows about tests.
    func testFailedPassLeavesNoKeysUsageOrCheckpoint() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [], checkpoint: 0))
        let saboteur = try SQLiteDatabase(url: url)
        try saboteur.execute("CREATE TRIGGER fail BEFORE UPDATE ON files BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        XCTAssertThrowsError(try store.commit(pass(fileA, [reply("1")], checkpoint: 90)))
        try saboteur.execute("DROP TRIGGER fail")
        saboteur.close()
        XCTAssertEqual(try store.summary().replies, 0)
        XCTAssertEqual(try store.fileStates()[fileA]?.checkpoint, 0)
        XCTAssertEqual(try store.commit(pass(fileA, [reply("1")], checkpoint: 90)), .init(counted: 1, duplicates: 0))
    }

    func testGoneFilesKeepTheirCounts() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1")]))
        try store.markGone(notIn: [])
        XCTAssertEqual(try store.fileStates()[fileA]?.gone, true)
        XCTAssertEqual(try store.summary().replies, 1)
        XCTAssertEqual(try store.commit(pass(fileB, [reply("1")])), .init(counted: 0, duplicates: 1), "keys outlive deleted logs")
    }

    private func minute(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 / 60)
    }

    /// Usage is kept per UTC minute, so a switch is placed to the minute.
    func testTotalsGroupByPriceClassWithinAMinuteRange() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1", hour: "2026-09-29T10:14:59Z"), reply("2", hour: "2026-09-29T10:15:00Z"),
                                      reply("3", hour: "2026-09-29T10:15:59Z", model: "claude-sonnet-5"),
                                      reply("4", hour: "2026-09-29T10:16:00Z")]))
        let from = minute("2026-09-29T10:15:00Z")
        let totals = try store.totals(fromMinute: from, toMinute: from + 1)
        XCTAssertEqual(Set(totals.map(\.priceClass.model)), ["claude-opus-5-5", "claude-sonnet-5"])
        XCTAssertEqual(totals.first { $0.priceClass.model == "claude-opus-5-5" }?.replies, 1)
    }

    func testMinuteTotalsKeepEachMinuteApart() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1", input: 10, hour: "2026-09-29T10:15:01Z"), reply("2", input: 20, hour: "2026-09-29T10:15:40Z"),
                                      reply("3", input: 40, hour: "2026-09-29T10:17:00Z")]))
        try store.commit(pass(fileB, [reply("4", input: 80, hour: "2026-09-29T10:15:30Z")]))
        let rows = try store.minuteTotals(fromMinute: 0, toMinute: .max)
        XCTAssertEqual(rows.map(\.minute), [minute("2026-09-29T10:15:00Z"), minute("2026-09-29T10:17:00Z")])
        XCTAssertEqual(rows.map(\.total.tokens.input), [110, 40], "files merge within a minute")
    }

    /// Nothing has shipped: a store from an older schema is rebuilt, not migrated.
    func testAnOlderSchemaIsRebuilt() throws {
        let old = try SQLiteDatabase(url: url)
        try old.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO meta VALUES('schema', '2');
            CREATE TABLE usage(file INTEGER, hour INTEGER);
            INSERT INTO usage VALUES(1, 2);
            """)
        old.close()
        let store = try TokenBurnStore(url: url)
        XCTAssertEqual(try store.summary().replies, 0)
        try store.commit(pass(fileA, [reply("1")]))
        XCTAssertEqual(try store.summary().replies, 1)
    }

    // MARK: Sign-in spans (spec §10)

    private let work = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: "stripe_subscription")
    private let home = SignInIdentity(accountUUID: "acc-H", organizationUUID: "org-H", billingType: "stripe_subscription")
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + minutes * 60) }

    /// Same identity and same profileFetchedAt: one span, whatever the gap
    /// (no login and no profile refresh happened in between).
    func testEqualObservationsExtendOneSpanAcrossAnyGap() throws {
        let store = try TokenBurnStore(url: url)
        try store.observe(work, fetchedAt: at(-30), at: at(0))
        try store.observe(work, fetchedAt: at(-30), at: at(5))
        try store.observe(work, fetchedAt: at(-30), at: at(600))
        XCTAssertEqual(try store.signInSpans(), [SignInSpan(identity: work, fetchedAt: at(-30), firstSeen: at(0), lastSeen: at(600))])
    }

    func testAChangedIdentityOrFetchTimeStartsASpan() throws {
        let store = try TokenBurnStore(url: url)
        try store.observe(work, fetchedAt: at(-30), at: at(0))
        try store.observe(work, fetchedAt: at(3), at: at(5))
        try store.observe(home, fetchedAt: at(7), at: at(10))
        try store.observe(nil, fetchedAt: nil, at: at(15))
        XCTAssertEqual(try store.signInSpans(), [
            SignInSpan(identity: work, fetchedAt: at(-30), firstSeen: at(0), lastSeen: at(0)),
            SignInSpan(identity: work, fetchedAt: at(3), firstSeen: at(5), lastSeen: at(5)),
            SignInSpan(identity: home, fetchedAt: at(7), firstSeen: at(10), lastSeen: at(10)),
        ], "signed out: nothing recorded")
    }

    func testSpansSurviveReopening() throws {
        var store: TokenBurnStore? = try TokenBurnStore(url: url)
        try store?.observe(home, fetchedAt: nil, at: at(1))
        store?.close()
        store = nil
        let reopened = try TokenBurnStore(url: url)
        try reopened.observe(home, fetchedAt: nil, at: at(2))
        XCTAssertEqual(try reopened.signInSpans(), [SignInSpan(identity: home, fetchedAt: nil, firstSeen: at(1), lastSeen: at(2))])
    }

    func testOrganizationBindingsUpsertAndRemove() throws {
        let store = try TokenBurnStore(url: url)
        let a = UUID(), b = UUID()
        try store.setOrganization("org-W", for: a, at: at(0))
        try store.setOrganization("org-H", for: b, at: at(0))
        try store.setOrganization("org-X", for: a, at: at(1))
        XCTAssertEqual(try store.organizationBindings(), [a: "org-X", b: "org-H"])
        try store.removeBinding(account: b)
        XCTAssertEqual(try store.organizationBindings(), [a: "org-X"])
    }

    func testReopeningKeepsEverything() throws {
        var store: TokenBurnStore? = try TokenBurnStore(url: url)
        try store?.commit(pass(fileA, [reply("1")], checkpoint: 77))
        store?.close()
        store = nil
        let reopened = try TokenBurnStore(url: url)
        XCTAssertEqual(try reopened.fileStates()[fileA]?.checkpoint, 77)
        XCTAssertEqual(try reopened.summary().replies, 1)
    }

    func testMalformedAndOversizedAccumulate() throws {
        let store = try TokenBurnStore(url: url)
        var first = pass(fileA, [])
        first.malformed = 2
        first.oversized = 1
        try store.commit(first)
        try store.commit(first)
        XCTAssertEqual(try store.summary().malformedLines, 4)
        XCTAssertEqual(try store.summary().oversizedLines, 2)
    }

    func testDestroyRemovesTheDatabaseAndItsJournals() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1")]))
        store.close()
        try TokenBurnStore.destroy(at: url)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        XCTAssertEqual(left, [])
    }

    /// What change detection needs, kept per file.
    func testFileStateKeepsModificationTimeAndTail() throws {
        let store = try TokenBurnStore(url: url)
        var first = pass(fileA, [])
        first.mtime = 1_700_000_000_123_456_789
        first.tail = -42
        try store.commit(first)
        XCTAssertEqual(try store.fileStates()[fileA], TokenBurnStore.FileState(checkpoint: 50, size: 50, mtime: 1_700_000_000_123_456_789, tail: -42, gone: false))
    }

    /// Text is stored byte for byte, NUL included, so an
    /// unknown model can never be shortened into a priced one.
    func testTextWithAnEmbeddedNULRoundTrips() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1", model: "claude-opus-5-5\u{0}later")]))
        let totals = try store.totals(fromMinute: 0, toMinute: .max)
        XCTAssertEqual(totals.map(\.priceClass.model), ["claude-opus-5-5\u{0}later"])
    }

    // MARK: Ration's writes to the sign-in (spec §10.1)

    /// Ration switched A→B→A between two readings and put
    /// A's old fetch time back. The readings are equal, but the writes
    /// split them, so the second one proves nothing before the last write.
    func testARationWriteSplitsEqualReadings() throws {
        let store = try TokenBurnStore(url: url)
        try store.observe(work, fetchedAt: at(-30), at: at(0))
        try store.recordConfigWrite(at: at(2))
        try store.recordConfigWrite(at: at(4))
        try store.observe(work, fetchedAt: at(-30), at: at(5))
        try store.observe(work, fetchedAt: at(-30), at: at(6))
        XCTAssertEqual(try store.signInSpans(), [
            SignInSpan(identity: work, fetchedAt: at(-30), firstSeen: at(0), lastSeen: at(0)),
            SignInSpan(identity: work, fetchedAt: at(-30), firstSeen: at(5), lastSeen: at(6)),
        ])
        XCTAssertEqual(try store.configWrites(), [at(2), at(4)])
    }

    /// Account removal (spec §10.1): its minutes and its
    /// identities' spans go; the reply keys stay, so nothing is counted again.
    func testDeletingMinutesAndSpans() throws {
        let store = try TokenBurnStore(url: url)
        try store.commit(pass(fileA, [reply("1", input: 10, hour: "2026-09-29T10:15:10Z"),
                                      reply("2", input: 20, hour: "2026-09-29T10:16:10Z")]))
        try store.observe(work, fetchedAt: nil, at: at(0))
        try store.observe(home, fetchedAt: nil, at: at(5))
        try store.deleteUsage(minutes: [minute("2026-09-29T10:15:00Z")])
        try store.deleteSpans(of: [work])
        XCTAssertEqual(try store.minuteTotals(fromMinute: 0, toMinute: .max).map(\.total.tokens.input), [20])
        XCTAssertEqual(try store.signInSpans().map(\.identity), [home])
        XCTAssertEqual(try store.commit(pass(fileB, [reply("1")])), .init(counted: 0, duplicates: 1), "keys stay")
    }
}
