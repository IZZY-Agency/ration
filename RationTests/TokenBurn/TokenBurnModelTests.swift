import XCTest
@testable import Ration

/// A folder grant that is just the path, with switches for the failures the
/// real security-scoped bookmark can have.
final class FakeFolderAccess: TokenBurnFolderAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var _resolveFails = false
    private var _startFails = false
    private var _resolvesStale = false
    private var _bookmarkFails = false
    private var _bookmarksMade = 0
    private var _accessing: [URL] = []
    var resolveFails: Bool { get { lock.withLock { _resolveFails } } set { lock.withLock { _resolveFails = newValue } } }
    var startFails: Bool { get { lock.withLock { _startFails } } set { lock.withLock { _startFails = newValue } } }
    var resolvesStale: Bool { get { lock.withLock { _resolvesStale } } set { lock.withLock { _resolvesStale = newValue } } }
    var bookmarkFails: Bool { get { lock.withLock { _bookmarkFails } } set { lock.withLock { _bookmarkFails = newValue } } }
    var bookmarksMade: Int { lock.withLock { _bookmarksMade } }
    var accessing: [URL] { lock.withLock { _accessing } }

    struct Unresolvable: Error {}

    func bookmark(for folder: URL) throws -> Data {
        try lock.withLock {
            if _bookmarkFails { throw Unresolvable() }
            _bookmarksMade += 1
        }
        return Data(folder.path(percentEncoded: false).utf8)
    }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        if resolveFails { throw Unresolvable() }
        return (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true), resolvesStale)
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.withLock {
            guard !_startFails else { return false }
            _accessing.append(url)
            return true
        }
    }
    func stopAccessing(_ url: URL) { lock.withLock { _accessing.removeAll { $0 == url } } }
}

final class FakeSignInReader: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (identity: SignInIdentity, fetchedAt: Date?)?
    private var _reads = 0
    private var _next: DispatchSemaphore?
    private var _held: DispatchSemaphore?
    var value: (identity: SignInIdentity, fetchedAt: Date?)? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }
    /// The next read waits for `release()` before it looks at the file, like
    /// a read still in flight.
    func holdNext() { lock.withLock { _next = DispatchSemaphore(value: 0) } }
    var isHolding: Bool { lock.withLock { _held != nil } }
    func release() { lock.withLock { () -> DispatchSemaphore? in defer { _held = nil }; return _held }?.signal() }
    func read() -> (identity: SignInIdentity, fetchedAt: Date?)? {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            _reads += 1
            guard let next = _next else { return nil }
            _next = nil
            _held = next
            return next
        }
        gate?.wait()
        return lock.withLock { _value }
    }
}

/// The switcher's log of the switches it made.
final class FakeSwitchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _times: [Date] = []
    var times: [Date] {
        get { lock.withLock { _times } }
        set { lock.withLock { _times = newValue } }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

@MainActor
final class TokenBurnModelTests: XCTestCase {
    private var base: URL!
    private var projects: URL!
    private var access: FakeFolderAccess!
    private var signIn: FakeSignInReader!
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private var clock: TestClock!
    private var switchLog: FakeSwitchLog!
    private var links: [String: UUID] = [:]
    private let work = SignInIdentity(accountUUID: "acc-W", organizationUUID: "org-W", billingType: "stripe_subscription")

    private var databaseURL: URL { base.appending(path: "token-burn.sqlite") }
    private var settingsURL: URL { base.appending(path: "token-burn.json") }

    override func setUp() async throws {
        base = try makeTempDirectory()
        projects = base.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects.appending(path: "-Users-me-app"), withIntermediateDirectories: true)
        try Data((TokenBurnFixtures.line(id: "m1", request: "r1") + "\n").utf8)
            .write(to: projects.appending(path: "-Users-me-app/s1.jsonl"))
        access = FakeFolderAccess()
        clock = TestClock(now)
        switchLog = FakeSwitchLog()
        signIn = FakeSignInReader()
        signIn.value = (work, now.addingTimeInterval(-600))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func makeModel(readingInterval: TimeInterval = .infinity) -> TokenBurnModel {
        let model = TokenBurnModel(dependencies: .init(
            folderAccess: access,
            settings: JSONFileStore(fileURL: settingsURL, defaultValue: TokenBurnSettings()),
            databaseURL: databaseURL,
            readSignIn: { [signIn] in signIn!.read() },
            loadSwitchTimes: { [switchLog] in switchLog!.times },
            scanInterval: 300,
            readingInterval: readingInterval
        ), now: { [clock] in clock!.now })
        model.linksProvider = { [unowned self] in self.links }
        return model
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A reply `minutesAgo` before the clock, in its own log.
    private func reply(_ id: String, minutesAgo: Double, input: Int = 1_000) throws {
        let line = TokenBurnFixtures.line(id: id, request: "r-\(id)", timestamp: iso(clock.now.addingTimeInterval(-minutesAgo * 60)),
                                          input: input, output: 0, cacheRead: 0, cacheWrite: 0, split5m: 0)
        try Data((line + "\n").utf8).write(to: projects.appending(path: "-Users-me-app/\(id).jsonl"))
    }

    private let accountW = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private var personalWork: TokenBurnAccount {
        TokenBurnAccount(id: accountW, label: "Work", organizationID: "org-W", personalPlanDetected: true,
                         plan: .claudeMax20x, renewalDay: nil)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Spec §4.1: nothing is opened before consent and the folder grant.
    func testNothingIsReadWhileOff() async {
        let model = makeModel()
        await model.start()
        await model.scanNow()
        XCTAssertEqual(model.phase, .off)
        XCTAssertEqual(signIn.reads, 0, "the sign-in file is not read")
        XCTAssertFalse(exists(databaseURL), "no store")
        XCTAssertEqual(access.accessing, [])
    }

    func testEnablingCountsAndRemembersTheGrant() async throws {
        let model = makeModel()
        let granted = await model.enable(folder: projects)
        XCTAssertTrue(granted)
        await model.scanNow()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.summary?.replies, 1)
        XCTAssertEqual(model.countedThrough, now)
        XCTAssertEqual(model.folderName, "projects", "the last path component, for Settings")
        XCTAssertGreaterThan(signIn.reads, 0)
        let saved = try await JSONFileStore(fileURL: settingsURL, defaultValue: TokenBurnSettings()).load()
        XCTAssertTrue(saved.enabled)
        XCTAssertNotNil(saved.bookmark)
        XCTAssertEqual(saved.grantedAt, now)
        await model.stop()
    }

    /// After a relaunch the grant is resolved again and counting carries on.
    func testARelaunchResolvesTheGrant() async throws {
        let first = makeModel()
        _ = await first.enable(folder: projects)
        await first.scanNow()
        await first.stop()
        let relaunched = makeModel()
        await relaunched.start()
        await relaunched.scanNow()
        XCTAssertEqual(relaunched.phase, .ready)
        XCTAssertEqual(relaunched.summary?.replies, 1)
        await relaunched.stop()
    }

    /// Spec §6: a lost grant pauses counting; nothing counted is lost.
    func testALostGrantPausesAndKeepsTheCounts() async throws {
        let first = makeModel()
        _ = await first.enable(folder: projects)
        await first.scanNow()
        await first.stop()
        access.resolveFails = true
        let relaunched = makeModel()
        await relaunched.start()
        XCTAssertEqual(relaunched.phase, .grantLost)
        XCTAssertTrue(exists(databaseURL), "counts kept")
        XCTAssertEqual(relaunched.summary?.replies, 1, "still shown")
        await relaunched.stop()
    }

    func testAMovedFolderPausesCounting() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        try FileManager.default.moveItem(at: projects, to: base.appending(path: "moved"))
        await model.scanNow()
        XCTAssertEqual(model.phase, .grantLost)
        XCTAssertEqual(model.summary?.replies, 1)
        await model.stop()
    }

    /// Spec §5.5: Stop and forget deletes the store and the grant.
    func testStopAndForgetDeletesEverything() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        let deleted = await model.stopAndForget()
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.phase, .off)
        XCTAssertNil(model.summary)
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(exists(URL(fileURLWithPath: databaseURL.path(percentEncoded: false) + suffix)), "no \(suffix)")
        }
        XCTAssertEqual(access.accessing, [], "access given back")
        let saved = try await JSONFileStore(fileURL: settingsURL, defaultValue: TokenBurnSettings()).load()
        XCTAssertEqual(saved, TokenBurnSettings(), "grant forgotten")
        await model.scanNow()
        XCTAssertFalse(exists(databaseURL), "a later pass writes nothing")
    }

    /// Stop and forget while a pass is running leaves no
    /// file behind — the pass is cancelled and awaited before the delete.
    func testStopAndForgetDuringAPassLeavesNothingBehind() async throws {
        for index in 0..<300 {
            try Data((TokenBurnFixtures.line(id: "x\(index)", request: "q\(index)") + "\n").utf8)
                .write(to: projects.appending(path: "-Users-me-app/f\(index).jsonl"))
        }
        let model = makeModel()
        _ = await model.enable(folder: projects)
        let pass = Task { await model.scanNow() }
        await Task.yield()
        let deleted = await model.stopAndForget()
        await pass.value
        XCTAssertTrue(deleted)
        XCTAssertFalse(exists(databaseURL))
        XCTAssertEqual(model.phase, .off)
    }

    /// Each pass reads the sign-in once and records it (spec §5.2).
    func testEachPassRecordsTheSignIn() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        let spans = await model.signInSpansForTesting()
        XCTAssertEqual(spans.map(\.identity), [work])
        XCTAssertEqual(spans.first?.fetchedAt, now.addingTimeInterval(-600))
        await model.stop()
    }

    // MARK: Lifecycle queue (spec §10.1)

    /// Enabling while Stop and forget is still deleting waits for it, so the
    /// delete can never take the new store with it.
    /// The pass is provably in flight — held at its
    /// sign-in reading — when Stop and forget and the new enable arrive.
    func testEnablingWaitsForAStopAndForgetInProgress() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        signIn.holdNext()
        clock.now = now.addingTimeInterval(600)
        let pass = Task { await model.scanNow() }
        while !signIn.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        let forget = Task { await model.stopAndForget() }
        let enable = Task { await model.enable(folder: projects) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(exists(databaseURL), "nothing is deleted while the pass holds")
        signIn.release()
        _ = await forget.value
        let enabled = await enable.value
        await pass.value
        XCTAssertTrue(enabled)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(exists(databaseURL), "the new store survived the delete")
        await model.scanNow()
        XCTAssertEqual(model.summary?.replies, 1, "counted again from nothing")
        await model.stop()
    }

    // MARK: Cadence (spec §10.1: readings every minute, logs every 5)

    func testReadingsAreFrequentAndLogCountingIsNot() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        let readsAfterFirst = signIn.reads
        try reply("late", minutesAgo: 0)
        clock.now = now.addingTimeInterval(60)
        await model.tick()
        XCTAssertEqual(signIn.reads, readsAfterFirst + 1, "read the sign-in")
        XCTAssertEqual(model.summary?.replies, 1, "logs not counted yet")
        clock.now = now.addingTimeInterval(300)
        await model.tick()
        XCTAssertEqual(model.summary?.replies, 2, "counted after 5 minutes")
        await model.stop()
    }

    // MARK: Values (spec §5.2, §10.1)

    func testAProvenMinuteLandsOnItsAccount() async throws {
        signIn.value = (work, now.addingTimeInterval(-3_600))
        try reply("a", minutesAgo: 30, input: 1_000_000)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()
        let value = try XCTUnwrap(model.values[accountW]?.current)
        XCTAssertEqual(value.value.replies, 1)
        XCTAssertGreaterThan(value.value.cents, 0)
        XCTAssertEqual(value.planPriceUSD, 200)
        XCTAssertEqual(value.period.kind, .days(30), "the default: the last 30 days")
        XCTAssertEqual(model.values[accountW]?.previous.count, 3)
        await model.stop()
    }

    /// Before the sign-in's fetch time nothing is proven.
    func testUsageBeforeTheFirstProvenTimeIsPooled() async throws {
        signIn.value = (work, now.addingTimeInterval(-600))
        try reply("old", minutesAgo: 60)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 0)
        XCTAssertEqual(model.pooled[.beforeTracking]?.replies, 1)
        await model.stop()
    }

    /// The switcher's writes are evidence: equal
    /// readings around a write prove nothing between them.
    func testASwitcherWriteLeavesTheTimeBeforeItUnproven() async throws {
        signIn.value = (work, now.addingTimeInterval(-3_600))
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()                              // reading at now
        clock.now = now.addingTimeInterval(10 * 60)
        await model.claudeCodeWillWrite()                  // reading at +10
        clock.now = now.addingTimeInterval(10 * 60 + 5)
        await model.claudeCodeDidWrite(at: now.addingTimeInterval(10 * 60 + 5))
        clock.now = now.addingTimeInterval(20 * 60)
        try reply("between", minutesAgo: 15)               // +5: proven by the span that ends at +10
        try reply("after", minutesAgo: 5)                  // +15: after the write, proven by the next span
        try reply("boundary", minutesAgo: 9.5)             // +10:30: its minute holds the write
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 2)
        XCTAssertEqual(model.pooled[.notObserved]?.replies, 1, "the minute that straddles the write")
        let writes = await model.configWritesForTesting()
        XCTAssertEqual(writes, [now.addingTimeInterval(10 * 60 + 5)])
        await model.stop()
    }

    /// A reading still in flight when the switcher writes could see the new
    /// account while stamped before the switch: the write
    /// waits for it, and no reading starts until the write is done.
    func testASwitcherWriteWaitsForAReadingInFlight() async throws {
        let other = SignInIdentity(accountUUID: "acc-B", organizationUUID: "org-B", billingType: "stripe_subscription")
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        signIn.holdNext()
        clock.now = now.addingTimeInterval(60)
        let tick = Task { await model.tick() }
        while !signIn.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        let releaser = Task { [signIn] in
            try await Task.sleep(for: .milliseconds(200))
            signIn!.release()
        }
        await model.claudeCodeWillWrite()
        signIn.value = (other, now.addingTimeInterval(-86_400))    // the remembered copy: an older P
        await tick.value
        let write = now.addingTimeInterval(65)
        clock.now = write
        await model.claudeCodeDidWrite(at: write)
        try await releaser.value
        await model.recompute()
        let spans = await model.signInSpansForTesting()
        XCTAssertEqual(spans.last?.identity, other)
        XCTAssertEqual(spans.filter { $0.identity == other }.map(\.firstSeen), [write],
                       "the new account is first seen after the write")
        await model.stop()
    }

    /// A switch Ration made while plan value was off (spec §10: the switch
    /// log is evidence). The switch wrote the remembered copy, whose P is a
    /// day old: that P proves nothing before the switch.
    func testASwitchFromTheLogBoundsTheFirstSpan() async throws {
        let switched = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 20 * 60).rounded(.down))
        switchLog.times = [switched]
        signIn.value = (work, now.addingTimeInterval(-86_400))
        try reply("before", minutesAgo: 30)
        try reply("after", minutesAgo: 10)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 1, "only the reply after the switch")
        XCTAssertEqual(model.pooled[.beforeTracking]?.replies, 1)
        var writes = await model.configWritesForTesting()
        XCTAssertEqual(writes, [switched.addingTimeInterval(1)], "the end of the second the log names")

        await model.stop()
        await model.start()
        writes = await model.configWritesForTesting()
        XCTAssertEqual(writes, [switched.addingTimeInterval(1)], "not recorded twice")
        await model.stop()
    }

    /// A switch token burn heard is in the log too, to the second: kept once.
    func testASwitchHeardAndLoggedIsKeptOnce() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        let write = now.addingTimeInterval(65.4)
        await model.claudeCodeWillWrite()
        await model.claudeCodeDidWrite(at: write)
        switchLog.times = [Date(timeIntervalSince1970: write.timeIntervalSince1970.rounded(.down))]
        await model.stop()
        await model.start()
        let writes = await model.configWritesForTesting()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.timeIntervalSince1970 ?? 0, write.timeIntervalSince1970, accuracy: 0.001)
        await model.stop()
    }

    /// Launch recovery with nothing to recover wrote nothing: no evidence,
    /// and readings carry on.
    func testAnAttemptThatWroteNothingEndsTheWrite() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        await model.claudeCodeWillWrite()
        await model.claudeCodeDidWrite(at: nil)
        let reads = signIn.reads
        clock.now = now.addingTimeInterval(60)
        await model.tick()
        XCTAssertEqual(signIn.reads, reads + 1, "readings carry on")
        let writes = await model.configWritesForTesting()
        XCTAssertEqual(writes, [])
        await model.stop()
    }

    // MARK: The chosen period

    func testThePeriodIsKeptAppliedAndRestored() async throws {
        signIn.value = (work, now.addingTimeInterval(-3_600))
        try reply("a", minutesAgo: 30)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()
        await model.setPeriod(.last7Days)
        XCTAssertEqual(model.period, .last7Days)
        XCTAssertEqual(model.values[accountW]?.current.period.kind, .days(7))
        XCTAssertEqual(model.days.count, 7)
        await model.stop()

        let relaunched = makeModel()
        await relaunched.start()
        XCTAssertEqual(relaunched.period, .last7Days)
        let settings = try await JSONFileStore(fileURL: settingsURL, defaultValue: TokenBurnSettings()).load()
        XCTAssertTrue(settings.enabled, "the grant is kept")
        await relaunched.stop()
    }

    func testStopAndForgetForgetsThePeriod() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.setPeriod(.thisMonth)
        _ = await model.stopAndForget()
        XCTAssertEqual(model.period, .last30Days)
        let settings = try await JSONFileStore(fileURL: settingsURL, defaultValue: TokenBurnSettings()).load()
        XCTAssertEqual(settings, TokenBurnSettings())
    }

    /// While off nothing is written: the switch is the only way to turn it on.
    func testChoosingAPeriodWhileOffWritesNothing() async throws {
        let model = makeModel()
        await model.setPeriod(.last7Days)
        XCTAssertEqual(model.period, .last30Days)
        XCTAssertFalse(exists(settingsURL))
    }

    // MARK: Grants, store failures and account removal

    /// A stale bookmark is replaced, and saved, before counting.
    func testAStaleGrantIsRenewedBeforeCounting() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        await model.stop()
        access.resolvesStale = true
        let made = access.bookmarksMade
        let relaunched = makeModel()
        await relaunched.start()
        XCTAssertEqual(access.bookmarksMade, made + 1, "a fresh bookmark")
        XCTAssertEqual(relaunched.phase, .ready)
        await relaunched.stop()
    }

    func testAStaleGrantThatCannotBeRenewedAsksAgainAndKeepsTheCounts() async throws {
        let model = makeModel()
        _ = await model.enable(folder: projects)
        await model.scanNow()
        await model.stop()
        access.resolvesStale = true
        access.bookmarkFails = true
        let relaunched = makeModel()
        await relaunched.start()
        XCTAssertEqual(relaunched.phase, .grantLost)
        XCTAssertEqual(relaunched.summary?.replies, 1, "counts kept")
        await relaunched.stop()
    }

    /// A store that cannot open is failed, never ready.
    func testAStoreThatCannotOpenIsFailedNotReady() async throws {
        let blocked = base.appending(path: "blocked")
        try Data("x".utf8).write(to: blocked)
        let model = TokenBurnModel(dependencies: .init(
            folderAccess: access,
            settings: JSONFileStore(fileURL: settingsURL, defaultValue: TokenBurnSettings()),
            databaseURL: blocked.appending(path: "token-burn.sqlite"),
            readSignIn: { [signIn] in signIn!.read() },
            scanInterval: 300, readingInterval: .infinity), now: { [clock] in clock!.now })
        let enabled = await model.enable(folder: projects)
        XCTAssertFalse(enabled)
        XCTAssertEqual(model.phase, .failed)
        await model.stop()
        await model.start()
        XCTAssertEqual(model.phase, .failed, "also at launch")
        await model.stop()
    }

    /// Spec §6: with no Claude Code sign-in the setting explains
    /// and stays off.
    func testEnablingWithoutAClaudeCodeSignInStaysOff() async throws {
        signIn.value = nil
        let model = makeModel()
        let enabled = await model.enable(folder: projects)
        XCTAssertFalse(enabled)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.enableProblem, .noSignIn)
        XCTAssertFalse(exists(settingsURL))
        XCTAssertFalse(exists(databaseURL))
    }

    /// Removal runs after the refresh that dropped the account; a
    /// sign-in bound by its organization alone is still recognised as its.
    func testRemovingAnAccountBoundByItsOrganizationDeletesItsUsage() async throws {
        signIn.value = (work, now.addingTimeInterval(-3_600))
        try reply("a", minutesAgo: 30)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 1)
        model.accountsDidChange([])
        await model.accountRemoved(accountW, links: [:])
        model.accountsDidChange([personalWork])
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies ?? 0, 0)
        XCTAssertEqual(model.summary?.replies, 1, "its usage rows are gone; setUp's stays")
        await model.stop()
    }

    /// A link learned later re-attributes past usage (no re-read).
    func testALinkLearnedLaterReattributes() async throws {
        signIn.value = (work, now.addingTimeInterval(-3_600))
        try reply("a", minutesAgo: 30)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        var notPersonal = personalWork
        notPersonal = TokenBurnAccount(id: accountW, label: "Work", organizationID: "org-W", personalPlanDetected: false,
                                       plan: nil, renewalDay: nil)
        model.accountsDidChange([notPersonal])
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 0)
        XCTAssertEqual(model.pooled[.unassigned]?.replies, 1)
        links = ["acc-W": accountW]
        await model.recompute()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 1)
        XCTAssertNil(model.values[accountW]?.current.ratio, "no plan tier, no ratio")
        await model.stop()
    }

    /// Removing an account deletes its minutes and spans; a
    /// later link cannot bring them back, and the logs are not counted again.
    func testRemovingAnAccountDeletesItsUsage() async throws {
        signIn.value = (work, now.addingTimeInterval(-3_600))
        try reply("a", minutesAgo: 30)
        let model = makeModel()
        _ = await model.enable(folder: projects)
        model.accountsDidChange([personalWork])
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies, 1)
        XCTAssertEqual(model.summary?.replies, 2, "with setUp's reply, dated after the clock")
        await model.accountRemoved(accountW, links: [:])
        model.accountsDidChange([personalWork])            // added back with the same organization
        links = ["acc-W": accountW]
        await model.scanNow()
        XCTAssertEqual(model.values[accountW]?.current.value.replies ?? 0, 0)
        XCTAssertEqual(model.summary?.replies, 1, "its usage rows are gone; setUp's stays")
        await model.stop()
    }
}

