import WebKit
import XCTest
@testable import Ration

/// Verifies usage alerts are wired into `AppModel` under the SYNCHRONOUS
/// authoritative-state design: `decideAlerts` reads and commits the
/// in-memory `alertStates` map with no `await` in between, so the whole
/// class of read-evaluate-persist ordering races (evaluation vs. removal,
/// prime vs. normal eval, save-failure vs. repeat emission) is structurally
/// impossible rather than merely serialized around. Persistence and posting
/// are best-effort ASYNC SIDE EFFECTS of an already-committed decision — see
/// `AppModel.decideAlerts`/`applyAlertDecision`.
///
/// Snapshots are seeded directly on the shared `UsageSnapshotStore` (per the
/// brief: "seed snapshotStore/state directly as existing tests do") rather
/// than driven through the full refresh coordinator + adapter — this
/// exercises exactly the publisher (`snapshotStore.$snapshots`) that feeds
/// the alert-evaluation sink, without the sign-in adapter needing to know
/// about usage fractions at all.
@MainActor
final class AppModelAlertsTests: XCTestCase {
    func testRedactedNotificationOmitsLabelAndPercentThroughAppModel() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        // A label that could be an email / employer.
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "bob@acme.com")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        try await fixture.model.setRedactNotifications(true)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()

        // The posted notification (rendered at post time from the live
        // privacy flag) carries neither the account label nor the exact percent.
        let posts = await fixture.scheduler.posts
        let post = try XCTUnwrap(posts.first { $0.id == expectedID })
        XCTAssertEqual(post.title, "Ration")
        XCTAssertFalse(post.title.contains("bob@acme.com"))
        XCTAssertFalse(post.body.contains("bob@acme.com"))
        XCTAssertFalse(post.body.contains("90%"))
    }

    func testEnabledAndAuthorizedFiresCriticalThresholdOnceAtNinetyPercentUsed() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )

        // 95% used (remainingFraction 0.05) crosses the critical (90%) tier.
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()

        let postsAfterFirst = await fixture.scheduler.posts
        XCTAssertTrue(
            postsAfterFirst.contains { $0.id == expectedID },
            "expected a critical-threshold post once usage crossed 90%"
        )
        let countAfterFirst = postsAfterFirst.filter { $0.id == expectedID }.count

        // Re-saving the identical snapshot must not re-fire: the in-memory
        // authoritative state already advanced past this tier (the sink's
        // synchronous `decideAlerts` commit is the edge-trigger memory).
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()

        let postsAfterSecond = await fixture.scheduler.posts
        let countAfterSecond = postsAfterSecond.filter { $0.id == expectedID }.count
        XCTAssertEqual(
            countAfterSecond,
            countAfterFirst,
            "an identical follow-up snapshot must not post a new critical-threshold notification"
        )
    }

    // NOTE: originally titled "...OnlyAfterChangedWindowIdentity" and fired
    // `.reset` purely by changing `resetsAt` between the first and second
    // snapshot while `remainingFraction` stayed flat at 0.5 — that is
    // precisely the false-positive bug this fix removes (Claude's rolling
    // 5h/weekly windows advance `resetsAt` on essentially every poll, which
    // used to spam a false reset notification every poll). Rewritten to
    // prove the corrected behavior end-to-end through `AppModel`: a changed
    // `resetsAt` with flat `remainingFraction` must NOT post a reset
    // notification, and only an actual freed-capacity jump does.
    func testWindowResetFiresResetNotificationOnlyOnFreedCapacityNotOnResetsAtDrift() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)

        let expectedID = AlertMessage.id(
            for: .reset(kind: .fiveHour),
            accountID: account.id
        )

        // First-ever snapshot for this window: `AlertPolicy` records the
        // window identity (`resetsAt`) but must NOT fire `.reset` — there is
        // no prior sample to compare against yet.
        let firstWindowSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(
                kind: .fiveHour,
                remainingFraction: 0.5,
                resetsAt: Date(timeIntervalSince1970: 3_000)
            ),
            weekly: nil
        )
        try await fixture.snapshots.save(firstWindowSnapshot)
        await fixture.model.flushAlertEvaluations()

        let postsAfterFirst = await fixture.scheduler.posts
        XCTAssertFalse(
            postsAfterFirst.contains { $0.id == expectedID },
            "the first-ever observation of a window must not fire a reset notification"
        )

        // Subsequent snapshot with a CHANGED `resetsAt` but the SAME
        // remainingFraction (0.5) — exactly the rolling-window drift pattern
        // that caused the false-positive bug — must NOT post a reset.
        let driftedIdentitySnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 4_000),
            fiveHour: UsageWindow(
                kind: .fiveHour,
                remainingFraction: 0.5,
                resetsAt: Date(timeIntervalSince1970: 5_000)
            ),
            weekly: nil
        )
        try await fixture.snapshots.save(driftedIdentitySnapshot)
        await fixture.model.flushAlertEvaluations()

        let postsAfterDrift = await fixture.scheduler.posts
        XCTAssertFalse(
            postsAfterDrift.contains { $0.id == expectedID },
            "a changed resetsAt with unchanged remaining capacity (rolling-window drift) must NOT "
                + "fire a reset notification"
        )

        // A further snapshot where remaining capacity actually jumps up
        // (0.5 → 0.95, well past the reset epsilon) — a genuine freed
        // capacity event — must post the reset notification.
        let freedCapacitySnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 6_000),
            fiveHour: UsageWindow(
                kind: .fiveHour,
                remainingFraction: 0.95,
                resetsAt: Date(timeIntervalSince1970: 7_000)
            ),
            weekly: nil
        )
        try await fixture.snapshots.save(freedCapacitySnapshot)
        await fixture.model.flushAlertEvaluations()

        let postsAfterFreedCapacity = await fixture.scheduler.posts
        XCTAssertTrue(
            postsAfterFreedCapacity.contains { $0.id == expectedID },
            "a genuine freed-capacity jump in remainingFraction must fire a reset notification"
        )
    }

    func testDisabledAlertsNeverPostEvenAtCriticalUsage() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        // usageAlertsEnabled defaults to false — never call setUsageAlertsEnabled.

        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.02, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty, "no notification may be posted while alerts are disabled")
        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id),
            "the in-memory authoritative state must not advance while alerts are disabled (freeze)"
        )
    }

    // MARK: - Removal: tombstone makes resurrection structurally impossible

    func testRemovingAccountClearsPersistedAlertStateAndTombstonesAgainstResurrection() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        XCTAssertNotEqual(fixture.alertStateStore.state(for: account.id), AccountAlertState())
        XCTAssertNotNil(fixture.model.alertStateForTesting(accountID: account.id))

        try await fixture.model.removeAccount(id: account.id)

        // The tombstone + in-memory removal are SYNCHRONOUS (no `await`
        // before or after in `removeAccount`'s cleanup), so this must already
        // be true even before flushing the (best-effort, async) store removal.
        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id),
            "the in-memory authoritative map must drop the removed account synchronously"
        )

        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.alertStateStore.state(for: account.id), AccountAlertState())

        // A late-arriving snapshot write for the now-removed account id (e.g.
        // an in-flight fetch that started before removal completed) must not
        // resurrect any alert state: `refreshableAccounts` already excludes
        // it from the sink's loop, and `decideAlerts`'s tombstone check is
        // the structural backstop even if that ordering ever changed.
        let lateSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.01, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(lateSnapshot)
        await fixture.model.flushAlertEvaluations()

        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id),
            "a late emission after removal must not recreate alert state (tombstone)"
        )
        XCTAssertEqual(
            fixture.alertStateStore.state(for: account.id),
            AccountAlertState(),
            "a late emission after removal must not resurrect persisted alert state"
        )
    }

    // MARK: - Corrupt alert-state load must not abort startup

    func testCorruptAlertStateFileDoesNotPreventLoad() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A directory at the alert-state path forces a non-decoding read
        // error (`Data(contentsOf:)` on a directory), unlike the
        // `DecodingError` `AlertStateStore.load()` already tolerates —
        // reproducing a genuinely unreadable/corrupt file on disk.
        try FileManager.default.createDirectory(
            at: directory.appending(path: "alert-state.json"),
            withIntermediateDirectories: true
        )

        let fixture = try makeFixture(directory: directory)
        // Must not throw: startup proceeds regardless of the corrupt file.
        try await fixture.model.load(startBackgroundRefresh: false)

        // History load / sign-in still function normally after the
        // swallowed failure. `alertStates` simply seeds empty.
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        XCTAssertEqual(fixture.model.accounts.count, 1)
    }

    // MARK: - Authorization is queried fresh on load (relaunch)

    func testRelaunchQueriesAuthorizationStatusOnLoadAndAllowsPostAfterward() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // First "launch": create the account and enable alerts, persisting
        // `usageAlertsEnabled` to disk.
        let firstScheduler = NotificationSchedulingSpy()
        let firstFixture = try makeFixture(directory: directory, scheduler: firstScheduler)
        try await firstFixture.model.load(startBackgroundRefresh: false)
        let sessionID = try firstFixture.model.beginSignIn(provider: .claude)
        try await firstFixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(firstFixture.model.accounts.first)
        try await firstFixture.model.setUsageAlertsEnabled(true)
        await firstFixture.model.flushAlertEvaluations()

        // "Relaunch": a fresh `AppModel` (and fresh stores) over the SAME
        // persisted files. `usageAlertsAuthorized` starts false again (a
        // fresh in-memory default) until `load()` queries the OS, and
        // `alertStates` starts empty until `load()` seeds it from the store.
        let secondScheduler = NotificationSchedulingSpy()
        await secondScheduler.setAuthorizationStatusResult(true)
        let secondFixture = try makeFixture(directory: directory, scheduler: secondScheduler)
        XCTAssertFalse(secondFixture.model.usageAlertsAuthorized)

        try await secondFixture.model.load(startBackgroundRefresh: false)
        XCTAssertTrue(
            secondFixture.model.usageAlertsAuthorized,
            "load() must query authorizationStatus() when the persisted setting is enabled"
        )

        // A subsequent ≥90% refresh posts.
        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await secondFixture.snapshots.save(criticalSnapshot)
        await secondFixture.model.flushAlertEvaluations()

        let posts = await secondScheduler.posts
        XCTAssertTrue(
            posts.contains { $0.id == expectedID },
            "a critical crossing after a relaunch must post once authorization is confirmed"
        )
    }

    // MARK: - A failed persist can never cause a re-post — authoritative
    // state lives in memory, not in the store.

    private struct InjectedSaveFailure: Error {}

    func testSaveFailureDoesNotCauseRePostBecauseStateIsAuthoritativeInMemory() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // EVERY save to the alert-state file fails. Under the old
        // persist-then-post design this would have suppressed all posting
        // forever; under the new design it must have NO effect on posting
        // behavior at all, because `alertStates` (not the store) is what
        // `decideAlerts` reads its edge-trigger memory from.
        let alertStateStore = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json"),
            saveStates: { _ in throw InjectedSaveFailure() }
        )
        let fixture = try makeFixture(directory: directory, alertStateStore: alertStateStore)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )

        // First crossing: the save fails in the background, but the
        // decision already committed synchronously in `decideAlerts` — the
        // post fires regardless of the persistence outcome.
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        var posts = await fixture.scheduler.posts
        XCTAssertEqual(
            posts.filter { $0.id == expectedID }.count,
            1,
            "a save failure must not suppress the post for the crossing that triggered it"
        )
        // The in-memory map has the tier; the persisted mirror never does —
        // proving the two are decoupled by design.
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .critical
        )
        XCTAssertEqual(fixture.alertStateStore.state(for: account.id), AccountAlertState())

        // Repeat identical emission: even though every save attempt has
        // failed (the persisted file never reflects the critical tier), the
        // in-memory `alertStates` already advanced past this crossing — no
        // re-post. This is the key correctness property.
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        posts = await fixture.scheduler.posts
        XCTAssertEqual(
            posts.filter { $0.id == expectedID }.count,
            1,
            "a repeat crossing must not re-post even when every persist attempt has failed"
        )
    }

    func testConcurrentEmissionsForSameCrossingPostExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )

        // Three rapid, unserialized saves of the identical crossing. Each
        // completed save re-publishes `snapshotStore.$snapshots`, re-firing
        // the sink; but every `decideAlerts` call is a single synchronous
        // main-actor step, so whichever firing lands first commits the
        // critical tier and every subsequent firing sees it already
        // notified — no double-post is possible even under this concurrency.
        async let first: Void = fixture.snapshots.save(criticalSnapshot)
        async let second: Void = fixture.snapshots.save(criticalSnapshot)
        async let third: Void = fixture.snapshots.save(criticalSnapshot)
        _ = try await (first, second, third)
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertEqual(
            posts.filter { $0.id == expectedID }.count,
            1,
            "concurrent emissions for the same crossing must post exactly once"
        )
    }

    // MARK: - Enabling seeds the baseline without posting

    func testEnablingPrimesExistingCrossingWithoutPostingThenHigherTierPosts() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // The account is already past the WARNING tier while alerts are off.
        let warningSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.20, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(warningSnapshot)
        await fixture.model.flushAlertEvaluations()
        let postsWhileDisabled = await fixture.scheduler.posts
        XCTAssertTrue(
            postsWhileDisabled.isEmpty,
            "disabled alerts must not evaluate or post"
        )
        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id),
            "the sink must not silently advance in-memory state while alerts are off (freeze)"
        )
        XCTAssertEqual(
            fixture.alertStateStore.state(for: account.id),
            AccountAlertState(),
            "the sink must not silently persist state while alerts are off (freeze)"
        )

        // Enabling primes the baseline for the pre-existing crossing WITHOUT
        // posting. Priming is synchronous (the commit into `alertStates`),
        // but its persist side effect is async — flush before inspecting the
        // store.
        try await fixture.model.setUsageAlertsEnabled(true)
        let postsAfterEnable = await fixture.scheduler.posts
        XCTAssertTrue(
            postsAfterEnable.isEmpty,
            "priming a pre-existing crossing must never post"
        )
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .warning,
            "priming must synchronously commit the current tier as already notified in memory"
        )

        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(
            fixture.alertStateStore.state(for: account.id).fiveHour.notifiedTier,
            .warning,
            "priming must persist the current tier as already notified"
        )

        // A further increase to a higher tier is a NEW crossing and must
        // post.
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()

        let criticalID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let warningID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .warning, percent: 75),
            accountID: account.id
        )
        let finalPosts = await fixture.scheduler.posts
        XCTAssertTrue(
            finalPosts.contains { $0.id == criticalID },
            "the further increase to critical must post"
        )
        XCTAssertFalse(
            finalPosts.contains { $0.id == warningID },
            "the primed warning tier must never post, even after a later higher-tier post"
        )
    }

    // MARK: - AlertsActive re-checked at post EXECUTION time, not enqueue time

    func testDisablingBeforeFlushSkipsAlreadyEnqueuedPost() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        // Triggers the sink SYNCHRONOUSLY: `decideAlerts` commits the
        // critical tier and `applyAlertDecision` enqueues a post item onto
        // `alertSideEffectQueue` — but nothing has run yet, since nothing
        // has awaited the queue since.
        try await fixture.snapshots.save(criticalSnapshot)

        // Disable BEFORE flushing. `setUsageAlertsEnabled(false)` flips
        // `alertsActive = false` as its very first (synchronous) statement,
        // strictly before its own first suspension point — Swift's
        // cooperative main-actor scheduling can never interleave another
        // queued Task's body between two statements of an uninterrupted
        // synchronous run, so the already-enqueued post item cannot possibly
        // observe `alertsActive == true` by the time it actually executes.
        try await fixture.model.setUsageAlertsEnabled(false)

        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertFalse(
            posts.contains { $0.id == expectedID },
            "a post enqueued while active must be skipped if disabled lands before it executes"
        )
        // The DECISION itself is untouched — `decideAlerts` already committed
        // the critical tier synchronously, before the disable landed; only
        // the POST side effect is suppressed by the execution-time recheck.
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .critical,
            "disabling must not roll back an already-committed decision"
        )
    }

    func testRemovingAccountBeforeFlushSkipsAlreadyEnqueuedPost() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        // Enqueues the post item (not yet executed).
        try await fixture.snapshots.save(criticalSnapshot)

        // Remove BEFORE flushing: the synchronous tombstone insert lands
        // strictly before the enqueued post item can execute, for the same
        // reason as the disable case above.
        try await fixture.model.removeAccount(id: account.id)

        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertFalse(
            posts.contains { $0.id == expectedID },
            "a post enqueued for an account removed before it executes must be skipped"
        )
    }

    func testPausingAccountBeforeFlushSkipsAlreadyEnqueuedPost() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)

        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        // Enqueues the post item (not yet executed).
        try await fixture.snapshots.save(criticalSnapshot)

        // Pause BEFORE flushing. `setPaused` is fully awaited to completion —
        // including the underlying persist — before this line returns, so the
        // account's CURRENT record already has `isPaused == true` by the time
        // the enqueued post item gets its turn on the queue, exactly like the
        // disable/removal cases above.
        try await fixture.model.setPaused(accountID: account.id, paused: true)

        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertFalse(
            posts.contains { $0.id == expectedID },
            "a post enqueued for an account paused before it executes must be skipped"
        )
    }

    // MARK: - Disable then re-enable never replays a pre-enable crossing

    func testDisableThenReenableDoesNotReplayPreEnableCrossingButHigherTierPosts() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)

        try await fixture.model.setUsageAlertsEnabled(false)

        // A crossing while disabled: the sink's synchronous `alertsActive`
        // guard skips it entirely — no commit, no post, no persist.
        let warningSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.20, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(warningSnapshot)
        await fixture.model.flushAlertEvaluations()
        // NOTE: `alertStateForTesting` is already non-nil at this point — the
        // initial `setUsageAlertsEnabled(true)` above primed a (default,
        // untiered) baseline from the account's empty post-sign-in snapshot.
        // The freeze property under test is that the TIER must not advance
        // while disabled, not that the entry itself stays absent.
        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            "a crossing while disabled must not advance the in-memory tier"
        )
        let postsWhileDisabled = await fixture.scheduler.posts
        XCTAssertTrue(postsWhileDisabled.isEmpty)

        // Re-enable: authorization is re-requested (the stub still grants
        // it); `primeAllAlerts()` baselines the pre-existing warning crossing
        // silently, and only then does `alertsActive` flip back to `true`.
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .warning,
            "re-enabling must prime the pre-existing crossing as already notified"
        )

        await fixture.model.flushAlertEvaluations()
        let warningID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .warning, percent: 75),
            accountID: account.id
        )
        let postsAfterReenable = await fixture.scheduler.posts
        XCTAssertFalse(
            postsAfterReenable.contains { $0.id == warningID },
            "the pre-enable crossing must never post, even after re-enabling"
        )

        // A further, HIGHER-tier crossing is a genuinely new edge and must
        // post normally.
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        let criticalID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let finalPosts = await fixture.scheduler.posts
        XCTAssertTrue(
            finalPosts.contains { $0.id == criticalID },
            "a genuinely new, higher-tier crossing after re-enabling must post"
        )
    }

    // MARK: - Version guard: a stale enable continuation must not
    // resurrect `alertsActive` after a newer disable has already completed.

    func testStaleEnableContinuationDoesNotReactivateAfterNewerDisableCompletes() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // Establish a known ENABLED baseline first.
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.alertsActiveForTesting())

        // Arm the scheduler so the NEXT `requestAuthorization()` call
        // suspends until explicitly released.
        await fixture.scheduler.armAuthorizationGate()

        // Enable A: fires via the synchronous-intent primitive (mirroring
        // exactly how Settings' `perform(request:)` drives every toggle —
        // the claim is synchronous at the tap), and immediately suspends
        // inside `requestAuthorization()`.
        let enableTaskA = fixture.model.requestSetUsageAlerts(true)
        await fixture.scheduler.waitUntilAuthorizationRequestIsSuspended()

        // Disable B: claims synchronously (I4) while A is still suspended —
        // this is the newer, authoritative transition, matching the user's
        // actual final choice. Its own reconcile pass is chained BEHIND A's
        // (I5: passes never interleave), so it cannot be awaited to
        // completion until A's suspended pass resolves — only the
        // synchronous claim is observable here.
        let disableB = fixture.model.requestSetUsageAlerts(false)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())

        // Release A's stale continuation. Without the version guard, A
        // would now unconditionally prime + activate, resurrecting
        // `alertsActive` and stranding it `true` against the user's final
        // opt-out.
        await fixture.scheduler.releaseAuthorizationRequest()
        try await enableTaskA.value
        try await disableB.value

        XCTAssertFalse(
            fixture.model.alertsActiveForTesting(),
            "a stale enable continuation must not reactivate alerts after a newer disable completed"
        )

        // Confirm behaviorally too: a subsequent crossing must not post.
        let expectedID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertFalse(
            posts.contains { $0.id == expectedID },
            "a crossing after the stale-enable race must not post while the user's final state is disabled"
        )
    }

    /// Deterministic (gate-controlled) rather than relying on incidental
    /// `Task`-scheduling order: an `async let`-based version of this test —
    /// racing several enable/disable calls with no explicit interleave
    /// control — was empirically FLAKY (the Swift Concurrency scheduler does
    /// not guarantee `async let` children run in declaration order once
    /// other work is in flight), exactly the risk the reconciler's version
    /// guard (I5: retry-until-current supersede rule) exists to close. Every
    /// interleave point below is instead pinned via the scheduler spy's
    /// authorization gate, so the "rapid
    /// cycle" shape (several enable/disable requests racing, only the LAST
    /// one requested taking effect) is exercised with a guaranteed ordering.
    /// Both calls use `requestSetUsageAlerts` (the synchronous-intent
    /// primitive) directly rather than the `async throws` wrapper: under the
    /// reconciler's serialized chain (I5), a later request's pass runs
    /// strictly behind an earlier one still suspended on the gate, so
    /// awaiting a later call to completion before releasing the gate would
    /// deadlock — only its synchronous claim (I4) is observable before that.
    func testRapidEnableDisableCyclesEndInStateMatchingTheLastCall() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        _ = try XCTUnwrap(fixture.model.accounts.first)

        // Cycle 1: two rounds of "an enable suspends in authorization, then
        // a disable claims synchronously and its pass converges once the
        // gate releases" — each round leaves the stale enable's own pass to
        // supersede itself (version guard) once it resumes, mirroring rapid
        // toggling that settles on OFF.
        for _ in 0..<2 {
            await fixture.scheduler.armAuthorizationGate()
            let staleEnable = fixture.model.requestSetUsageAlerts(true)
            await fixture.scheduler.waitUntilAuthorizationRequestIsSuspended()

            // Claims synchronously (I4); its own pass is chained BEHIND the
            // still-suspended enable's (I5), so it can only be awaited to
            // completion after the gate releases.
            let disable = fixture.model.requestSetUsageAlerts(false)
            XCTAssertFalse(fixture.model.alertsActiveForTesting())

            await fixture.scheduler.releaseAuthorizationRequest()
            try await staleEnable.value
            try await disable.value
        }

        XCTAssertFalse(
            fixture.model.alertsActiveForTesting(),
            "after a rapid enable/disable cycle ending on disable, alertsActive must be OFF"
        )

        // Cycle 2: same shape, but the FINAL call is the enable — it must
        // not be superseded by anything and must fully activate.
        await fixture.scheduler.armAuthorizationGate()
        let staleEnable = fixture.model.requestSetUsageAlerts(true)
        await fixture.scheduler.waitUntilAuthorizationRequestIsSuspended()

        let disable = fixture.model.requestSetUsageAlerts(false)
        await fixture.scheduler.releaseAuthorizationRequest()
        try await staleEnable.value
        try await disable.value
        XCTAssertFalse(fixture.model.alertsActiveForTesting())

        try await fixture.model.setUsageAlertsEnabled(true)

        XCTAssertTrue(
            fixture.model.alertsActiveForTesting(),
            "after a rapid enable/disable cycle ending on enable, alertsActive must be ON"
        )
    }

    // MARK: - FIFO save-before-remove — persisted entry cannot be resurrected

    func testRemovalAfterEnqueuedSaveLeavesNoPersistedAlertStateOnReload() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setUsageAlertsEnabled(true)
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        // Enqueues a save item for this crossing (not yet executed).
        try await fixture.snapshots.save(criticalSnapshot)

        // Remove immediately: synchronously tombstones, then enqueues its
        // own `remove` item onto the SAME queue AFTER the already-queued
        // save (FIFO) — so even if the save's own tombstone recheck somehow
        // missed, the remove still runs last and wins.
        try await fixture.model.removeAccount(id: account.id)

        await fixture.model.flushAlertEvaluations()
        XCTAssertNil(
            fixture.alertStateStore.states[account.id],
            "no persisted alert state may survive for a removed account, even with a save in flight"
        )

        // Fresh store load over the SAME file: the removal, not the
        // in-flight save, is what's on disk.
        let freshStore = AlertStateStore(fileURL: directory.appending(path: "alert-state.json"))
        try await freshStore.load()
        XCTAssertNil(
            freshStore.states[account.id],
            "a fresh reload must not resurrect the removed account's alert state"
        )
    }

    // MARK: - The processor stays deterministic and reusable across cycles

    func testRepeatedEvaluateFlushCyclesRemainDeterministicAndProcessorIsReusable() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        // A run of distinct crossings, each driven through its own
        // evaluate → flush cycle. Every flush must complete deterministically
        // and the SAME long-lived `alertSideEffectQueue` must keep accepting
        // and draining new items on every subsequent cycle (no leaked
        // handles, no stuck barrier).
        let remainingFractions: [Double] = [0.45, 0.25, 0.15, 0.08, 0.03]
        for (index, fraction) in remainingFractions.enumerated() {
            let snapshot = UsageSnapshot(
                accountID: account.id,
                fetchedAt: Date(timeIntervalSince1970: 2_000 + Double(index) * 100),
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: fraction, resetsAt: nil),
                weekly: nil
            )
            try await fixture.snapshots.save(snapshot)
            await fixture.model.flushAlertEvaluations()
        }

        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .critical,
            "the final tier after repeated cycles must reflect the last crossing"
        )
        XCTAssertEqual(
            fixture.alertStateStore.state(for: account.id).fiveHour.notifiedTier,
            .critical,
            "the persisted mirror must catch up across repeated flush cycles"
        )

        // An idle flush (nothing new enqueued) must still complete — proving
        // the barrier mechanism doesn't require a pending item to resolve.
        await fixture.model.flushAlertEvaluations()
    }

    // MARK: - Steady-state no-change emissions enqueue no save

    func testSteadyStateNoChangeEmissionDoesNotEnqueueASave() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let saveCounter = SaveCallCounter()
        let fileStore = JSONFileStore<[UUID: AccountAlertState]>(
            fileURL: directory.appending(path: "alert-state.json"),
            defaultValue: [:]
        )
        let alertStateStore = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json"),
            saveStates: { states in
                saveCounter.increment()
                try await fileStore.save(states)
            }
        )
        let fixture = try makeFixture(directory: directory, alertStateStore: alertStateStore)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        // A genuine state change (default → critical tier) must enqueue a
        // save.
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        let countAfterRealChange = saveCounter.count
        XCTAssertGreaterThan(countAfterRealChange, 0, "a genuine state change must enqueue a save")

        // Repeated identical emissions reproduce `next == previous` for this
        // account (the edge-trigger already advanced) and must not enqueue
        // any further saves — this is what bounds `alertSideEffectQueue` in
        // steady state.
        try await fixture.snapshots.save(criticalSnapshot)
        try await fixture.snapshots.save(criticalSnapshot)
        try await fixture.snapshots.save(criticalSnapshot)
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(
            saveCounter.count,
            countAfterRealChange,
            "steady-state no-change emissions must not grow the save queue"
        )

        // A further genuine change (a window reset re-arms the memory) must
        // enqueue exactly one more save.
        let resetSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(
                kind: .fiveHour,
                remainingFraction: 0.05,
                resetsAt: Date(timeIntervalSince1970: 4_000)
            ),
            weekly: nil
        )
        try await fixture.snapshots.save(resetSnapshot)
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(
            saveCounter.count,
            countAfterRealChange + 1,
            "a real state change must enqueue exactly one more save"
        )
    }

    // MARK: - Startup readiness barrier: no activation before hydration
    // completes. See
    // `AppModel.alertsHydrated`'s doc.

    /// The launch-time race itself: `usageAlertsEnabled` is ALREADY
    /// persisted `true` on disk, and a WARNING-tier snapshot is already on
    /// disk too, but its alert-state baseline was never primed
    /// (alert-state.json is empty/default) — e.g. a prior session that
    /// persisted the setting but crashed before priming ever completed. A
    /// concurrent `setUsageAlertsEnabled(true)` call is interleaved DURING
    /// `load()`'s hydration (before `alertsHydrated` flips), pinned via
    /// `HydrationGate`. Before the fix, this call could authorize + prime
    /// (against the still-loading snapshot store) + activate BEFORE
    /// `load()` itself had finished loading the on-disk WARNING snapshot —
    /// so when `load()` then resumed and published it, the now-active sink
    /// would treat it as a fresh crossing and post a spurious notification.
    /// With the barrier, the interleaved enable is inert (it only persists
    /// — already a no-op here — and defers), so `load()`'s own tail is the
    /// sole thing that primes: no spurious post for the pre-existing
    /// crossing, though a later, genuinely NEW higher-tier crossing still
    /// posts normally.
    func testLaunchRaceEnableDuringHydrationDoesNotReplayPreExistingCrossing() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // "Prior session": create the account, persist a WARNING-tier
        // snapshot, and persist `usageAlertsEnabled = true` directly via a
        // raw `AppSettings` instance — bypassing `setUsageAlertsEnabled`
        // entirely, so alert-state.json stays empty/default (never
        // primed). This reproduces the worst case for the race: the
        // setting says "on," a crossing is already on disk, but nothing
        // has baselined it yet.
        let setupFixture = try makeFixture(directory: directory)
        try await setupFixture.model.load(startBackgroundRefresh: false)
        let sessionID = try setupFixture.model.beginSignIn(provider: .claude)
        try await setupFixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(setupFixture.model.accounts.first)
        let warningSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.20, resetsAt: nil),
            weekly: nil
        )
        try await setupFixture.snapshots.save(warningSnapshot)
        let settingsWriter = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await settingsWriter.load()
        try await settingsWriter.setUsageAlertsEnabled(true)

        // "Relaunch": a fresh `AppModel` over the same persisted files,
        // with a hydration gate wired to pin the interleave point
        // deterministically.
        let hydrationGate = HydrationGate()
        hydrationGate.arm()
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(true)
        let relaunchFixture = try makeFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate
        )

        let loadTask = Task { try await relaunchFixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()
        XCTAssertFalse(
            relaunchFixture.model.alertsHydratedForTesting(),
            "load() must still be mid-hydration at the gate"
        )

        // The interleaved enable: since `!alertsHydrated`, this only
        // persists (already `true` on disk — a no-op) and returns without
        // activating.
        try await relaunchFixture.model.setUsageAlertsEnabled(true)
        XCTAssertFalse(
            relaunchFixture.model.alertsActiveForTesting(),
            "an enable while load() is still hydrating must not activate alerts itself"
        )

        hydrationGate.release()
        try await loadTask.value

        XCTAssertTrue(relaunchFixture.model.alertsHydratedForTesting())
        XCTAssertTrue(relaunchFixture.model.alertsActiveForTesting())
        await relaunchFixture.model.flushAlertEvaluations()

        let postsAfterLoad = await relaunchFixture.scheduler.posts
        XCTAssertTrue(
            postsAfterLoad.isEmpty,
            "the pre-existing WARNING crossing must be baselined by load()'s single "
                + "post-hydration prime, not posted"
        )
        XCTAssertEqual(
            relaunchFixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .warning,
            "load()'s post-hydration prime must baseline the pre-existing crossing"
        )

        // A later, genuinely NEW higher-tier crossing must still post.
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await relaunchFixture.snapshots.save(criticalSnapshot)
        await relaunchFixture.model.flushAlertEvaluations()
        let criticalID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let finalPosts = await relaunchFixture.scheduler.posts
        XCTAssertTrue(
            finalPosts.contains { $0.id == criticalID },
            "a genuinely new, higher-tier crossing after the race must still post"
        )
    }

    /// An enable requested while `load()` is still hydrating must not
    /// activate alerts itself — it only persists the setting and defers.
    /// `load()`'s own post-hydration tail is what authorizes, primes, and
    /// activates, once hydration is genuinely complete. Distinct from the
    /// launch-race test above: here the persisted setting starts OFF, and
    /// the interleaved enable is itself what turns it on mid-hydration.
    func testEnableDuringLoadDefersActivationToLoadsPostHydrationTail() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // "Prior session": account + a WARNING-tier snapshot on disk, but
        // `usageAlertsEnabled` is still OFF (default) — the upcoming
        // enable is what turns it on.
        let setupFixture = try makeFixture(directory: directory)
        try await setupFixture.model.load(startBackgroundRefresh: false)
        let sessionID = try setupFixture.model.beginSignIn(provider: .claude)
        try await setupFixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(setupFixture.model.accounts.first)
        let warningSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.20, resetsAt: nil),
            weekly: nil
        )
        try await setupFixture.snapshots.save(warningSnapshot)

        let hydrationGate = HydrationGate()
        hydrationGate.arm()
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(true)
        let relaunchFixture = try makeFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate
        )

        let loadTask = Task { try await relaunchFixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        try await relaunchFixture.model.setUsageAlertsEnabled(true)
        XCTAssertFalse(
            relaunchFixture.model.alertsHydratedForTesting(),
            "the enable itself must not race ahead of load()'s hydration"
        )
        XCTAssertFalse(
            relaunchFixture.model.alertsActiveForTesting(),
            "an enable while !alertsHydrated must not set alertsActive"
        )

        hydrationGate.release()
        try await loadTask.value

        XCTAssertTrue(
            relaunchFixture.model.alertsActiveForTesting(),
            "load() must activate alerts once hydration completes, using the persisted enabled setting"
        )
        XCTAssertTrue(relaunchFixture.model.usageAlertsAuthorized)

        await relaunchFixture.model.flushAlertEvaluations()
        let posts = await relaunchFixture.scheduler.posts
        XCTAssertTrue(
            posts.isEmpty,
            "the pre-existing crossing must be primed as a baseline, not posted"
        )
        XCTAssertEqual(
            relaunchFixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .warning,
            "load()'s tail must prime the pre-existing crossing after activating"
        )
    }

    /// A disable requested while `load()` is still hydrating must still
    /// win: even though `usageAlertsEnabled` was persisted `true` before
    /// this launch, a disable landing mid-hydration must leave alerts OFF
    /// once `load()` completes, with no posts — ever, including for a
    /// crossing that would otherwise post.
    func testDisableDuringLoadStillWinsOverPersistedEnable() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let setupFixture = try makeFixture(directory: directory)
        try await setupFixture.model.load(startBackgroundRefresh: false)
        let sessionID = try setupFixture.model.beginSignIn(provider: .claude)
        try await setupFixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(setupFixture.model.accounts.first)
        let criticalSnapshot = UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        )
        try await setupFixture.snapshots.save(criticalSnapshot)
        let settingsWriter = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await settingsWriter.load()
        try await settingsWriter.setUsageAlertsEnabled(true)

        let hydrationGate = HydrationGate()
        hydrationGate.arm()
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(true)
        let relaunchFixture = try makeFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate
        )

        let loadTask = Task { try await relaunchFixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        try await relaunchFixture.model.setUsageAlertsEnabled(false)
        XCTAssertFalse(relaunchFixture.model.alertsActiveForTesting())

        hydrationGate.release()
        try await loadTask.value

        XCTAssertTrue(relaunchFixture.model.alertsHydratedForTesting())
        XCTAssertFalse(
            relaunchFixture.model.alertsActiveForTesting(),
            "a disable requested during load() must still win, leaving alerts OFF once hydration completes"
        )

        await relaunchFixture.model.flushAlertEvaluations()
        let postsAfterLoad = await relaunchFixture.scheduler.posts
        XCTAssertTrue(
            postsAfterLoad.isEmpty,
            "no post may occur once the final state is disabled"
        )

        // A subsequent even-higher crossing must still not post while
        // disabled.
        try await relaunchFixture.snapshots.save(
            UsageSnapshot(
                accountID: account.id,
                fetchedAt: Date(timeIntervalSince1970: 3_000),
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.01, resetsAt: nil),
                weekly: nil
            )
        )
        await relaunchFixture.model.flushAlertEvaluations()
        let postsAfterLaterCrossing = await relaunchFixture.scheduler.posts
        XCTAssertTrue(postsAfterLaterCrossing.isEmpty)
    }

    // MARK: - Suite B: scenario outcomes (reconciler)

    /// Scenario 1 — cold-start enable converges. The account has no
    /// `.userRequest` this session; a tap racing `load()`'s hydration is
    /// born `.coldStartDeferred` (persists silently, never prompts — I6) and
    /// the startup pass, not the tap, is what queries authorization/primes/
    /// activates once hydration completes.
    func testColdStartEnableConvergesViaStartupPass() async throws {
        let scheduler = NotificationSchedulingSpy()
        let hydrationGate = HydrationGate()
        let fixture = try makeFixture(scheduler: scheduler, hydrationGate: hydrationGate)
        defer { fixture.removeFiles() }

        hydrationGate.arm()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        // Born .coldStartDeferred: persists silently, never prompts (I6);
        // the startup pass converges it under query semantics.
        let enable = fixture.model.requestSetUsageAlerts(true)

        hydrationGate.release()
        try await enable.value
        try await load.value
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized, "no spurious hint")
        let promptCount = await scheduler.requestAuthorizationCallCount
        XCTAssertEqual(promptCount, 0, "I6: a cold-start tap never prompts")

        // The runtime is genuinely active: a crossing posts.
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let posts = await scheduler.posts
        XCTAssertFalse(posts.isEmpty, "scenario 1: cold-start enable must activate")

        // Idempotence: re-saving the identical critical snapshot must not
        // re-post — the reconciler preserves the edge-trigger memory.
        let countBefore = posts.count
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 4_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let countAfter = await scheduler.posts.count
        XCTAssertEqual(countAfter, countBefore)
    }

    /// Scenario 2 — a disable racing `load()`'s hydration stays down.
    /// `requestSetUsageAlerts(false)` claims synchronously and chains ahead
    /// of the startup pass (which is enqueued afterward, once hydration
    /// completes); the startup pass then reads `alertsDesired == false` (I1)
    /// and can never activate.
    func testDisableDuringHydrationNeverActivatesOrPosts() async throws {
        let scheduler = NotificationSchedulingSpy()
        let saveGate = SettingsSaveGate()
        let hydrationGate = HydrationGate()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate,
            appSettings: settings
        )
        defer { fixture.removeFiles() }

        hydrationGate.arm()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        saveGate.arm()
        let disable = fixture.model.requestSetUsageAlerts(false)
        await saveGate.waitUntilSuspended()

        // load()'s startup pass chains BEHIND the held disable and reads
        // alertsDesired == false (I1) — it can never activate.
        hydrationGate.release()
        saveGate.release()
        try await disable.value
        try await load.value
        await fixture.model.flushAlertEvaluations()

        // Direct runtime-gate assertion: the zero-posts check below can pass
        // even if a buggy startup pass wrongly reactivated the gate, because
        // `decideAlerts`'s independent persisted-OFF guard also suppresses
        // posting. Assert the gate itself stayed down.
        XCTAssertFalse(
            fixture.model.alertsActiveForTesting(),
            "the posting gate itself must stay down"
        )

        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled)
        try await driveCriticalCrossing(fixture)
        let posts = await scheduler.posts
        XCTAssertTrue(posts.isEmpty, "scenario 2: zero posts after opt-out")
    }

    /// Scenario 3 — enable/disable/enable spanning `load()`'s startup
    /// authorization query. Versions are claimed synchronously at
    /// registration: the startup pass (v0) goes stale, the disable (v1)
    /// supersedes at entry (its own pass returns before touching anything —
    /// `try?` is merely defensive here since a superseded pass returns
    /// normally, not throws), and the enable (v2) is the final claim and
    /// wins once the gate releases.
    func testDisableEnableDuringStartupQuery_FinalEnableWins() async throws {
        let scheduler = NotificationSchedulingSpy()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let fixture = try makeFixture(directory: directory, scheduler: scheduler)
        defer { fixture.removeFiles() }

        await scheduler.armStatusGate()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await scheduler.waitUntilStatusQueryIsSuspended()

        // Versions claimed synchronously at registration: startup (v0) goes
        // stale, the disable (v1) supersedes at entry, the enable (v2) wins.
        let disable = fixture.model.requestSetUsageAlerts(false)
        let enable = fixture.model.requestSetUsageAlerts(true)

        await scheduler.releaseStatusQuery(true)
        try? await disable.value
        try await enable.value
        try await load.value
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)
        try await driveCriticalCrossing(fixture)
        let posts = await scheduler.posts
        XCTAssertFalse(posts.isEmpty, "scenario 3: final requested ON means runtime ON")
    }

    /// Scenario 1 variant — a post-hydration tap during the startup
    /// authorization query. Hydration already flipped by the time this tap
    /// registers, so it is a normal `.userRequest` (not `.coldStartDeferred`):
    /// it chains behind the (now stale) startup pass and converges itself,
    /// rather than relying on the startup pass to converge it.
    func testEnableDuringStartupQueryConvergesViaUserRequestPass() async throws {
        let scheduler = NotificationSchedulingSpy()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let fixture = try makeFixture(directory: directory, scheduler: scheduler)
        defer { fixture.removeFiles() }

        await scheduler.armStatusGate()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await scheduler.waitUntilStatusQueryIsSuspended()

        // Hydration already flipped, so this tap is a normal .userRequest:
        // it chains behind the (now stale) startup pass and converges itself.
        let enable = fixture.model.requestSetUsageAlerts(true)

        await scheduler.releaseStatusQuery(true)
        try await enable.value
        try await load.value
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)
        let promptCount = await scheduler.requestAuthorizationCallCount
        XCTAssertEqual(
            promptCount,
            1,
            "a post-hydration tap converges via the prompting .userRequest path, not the query path"
        )
        try await driveCriticalCrossing(fixture)
        let posts = await scheduler.posts
        XCTAssertFalse(posts.isEmpty)
    }

    /// Regression coverage for the `.startup` pass's post-`authorizationStatus`
    /// version guard (`AppModel.reconcileAlertsPass`, the
    /// `guard version == alertsDesiredVersion else { return }` immediately
    /// after `await notificationScheduler.authorizationStatus()` in the
    /// `.startup` case). Scenario 3 above
    /// (`testDisableEnableDuringStartupQuery_FinalEnableWins`) does not
    /// meaningfully exercise this guard: its final pass is an enable that
    /// activates regardless of whether the guard fires, and its account only
    /// exists after everything has settled — so a crossing there can't tell
    /// a version-guarded return apart from a buggy unconditional activation.
    ///
    /// This test races a FINAL disable against the still-suspended startup
    /// status query instead. The disable's synchronous claim (I4) already
    /// flips `alertsActive = false` at registration — before the startup
    /// pass resumes — so a startup pass missing the guard would flip it back
    /// to `true` the instant the status query resolves, exactly the bug the
    /// guard exists to prevent. The account and a mid-usage baseline are
    /// established only AFTER releasing the status query (accounts require
    /// `load()` to have reached this point, which it has) but WHILE the
    /// disable's own persist is still held via `SettingsSaveGate` — the
    /// disable's chained pass cannot even reach that persist call until the
    /// startup pass ahead of it in the chain (I5) has fully returned, so
    /// holding it isolates the observation window to purely the startup
    /// pass's own guard behavior, not the disable's (redundant) own
    /// `alertsActive = false`. Neither `beginSignIn`/`completeSignIn` nor
    /// `snapshots.save` touch `AppSettings`, so driving them while the save
    /// is held cannot deadlock.
    func testDisableDuringStartupQueryStaleStartupNeverActivates() async throws {
        let scheduler = NotificationSchedulingSpy()
        let saveGate = SettingsSaveGate()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeFixture(
            directory: directory, scheduler: scheduler, appSettings: settings
        )
        defer { fixture.removeFiles() }

        await scheduler.armStatusGate()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await scheduler.waitUntilStatusQueryIsSuspended()

        // The final, newer claim: bumps the version past the startup pass's
        // captured value and synchronously drops `alertsActive` (I4).
        saveGate.arm()
        let disable = fixture.model.requestSetUsageAlerts(false)

        // Release the status query: the stale startup pass resumes now and
        // must fully resolve — one way or the other — before the disable's
        // own chained pass (I5: serialized) can even reach its persist call.
        await scheduler.releaseStatusQuery(true)

        // This suspension is reached only once the startup pass — and its
        // version-guard branch — has already run to completion.
        await saveGate.waitUntilSuspended()

        // Sign in and drive a mid-usage baseline now, while the disable's
        // save is still held: if the guard were missing, the wrong
        // activation would still be live to post on the crossing below.
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let postsWhileSaveHeld = await scheduler.posts
        XCTAssertTrue(
            postsWhileSaveHeld.isEmpty,
            "a stale startup pass must not have reactivated alerts to post on this crossing"
        )
        XCTAssertFalse(
            fixture.model.alertsActiveForTesting(),
            "the version guard must keep the posting gate down while the disable's own save is still held"
        )

        // Release the disable's held save and let everything settle.
        saveGate.release()
        try await disable.value
        try await load.value
        await fixture.model.flushAlertEvaluations()

        XCTAssertFalse(fixture.model.alertsActiveForTesting())
        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled)
    }

    /// Regression coverage for the concurrent-`load()` hole behind the I3
    /// edge guard (external review, resolution ). Before this fix,
    /// `didLoad` was only set at the very END of `load()`, so a second,
    /// concurrent call to `load()` could pass the `guard !didLoad` check
    /// while the first call was still suspended on its very first `await`
    /// — double-running the entire body (double store loads, double
    /// orphan-journal enqueues, double `retryProfileCleanup`, double
    /// `refreshAll`) and, per the reviewer's specific trace, spawning a
    /// second startup reconcile pass that could legally reach the
    /// `.startup` edge guard (`if !alertsActive` in `reconcileAlertsPass`)
    /// with `alertsActive == true` — refuting that guard's "structurally
    /// unreachable" doc comment. Production calls `load()` exactly once
    /// today, so the hole was latent, not live — but this test pins the
    /// concurrent-call shape directly so it can never regress silently.
    ///
    /// This test pins load A's `.startup` pass mid-`authorizationStatus()`
    /// query (via the scheduler's status gate) — the exact suspension
    /// window the finding traces — then calls `load()` a SECOND time
    /// directly while that gate is still held. With single-flight
    /// `loadStarted` claimed synchronously before any `await`, load B hits
    /// the guard and returns immediately: this `await` completing while the
    /// gate is still held IS the discriminator. Without the fix, load B
    /// would run the whole body again, including spawning its own
    /// `.startup` reconcile pass that chains behind load A's (still
    /// in-flight) pass via `alertsLifecycleChain` — and load B would
    /// deadlock right here, since only releasing the gate can ever unblock
    /// that chain.
    func testConcurrentLoadIsSingleFlight() async throws {
        let scheduler = NotificationSchedulingSpy()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let fixture = try makeFixture(directory: directory, scheduler: scheduler)
        defer { fixture.removeFiles() }

        await scheduler.armStatusGate()
        let loadA = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await scheduler.waitUntilStatusQueryIsSuspended()

        // Load B, called directly (not via a Task) while load A's startup
        // pass is still pinned mid-query. With single-flight, the guard is
        // hit before any `await`, so this returns promptly. Without the
        // fix, this line would deadlock.
        try await fixture.model.load(startBackgroundRefresh: false)

        await scheduler.releaseStatusQuery(true)
        try await loadA.value
        await fixture.model.flushAlertEvaluations()

        // Load A converged, unharmed by the concurrent load B call.
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)
    }

    // MARK: - Regression coverage — park, cancellation, moot
    // convergence, and I6/I7

    func testFailedColdStartEnableParksAndStartupRefusesToActivate() async throws {
        let scheduler = NotificationSchedulingSpy()
        let saveGate = SettingsSaveGate()
        let hydrationGate = HydrationGate()
        let directory = try Self.makeTempDirectory()
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate,
            appSettings: settings
        )
        defer { fixture.removeFiles() }

        hydrationGate.arm()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        saveGate.armFailure()
        let enable = fixture.model.requestSetUsageAlerts(true)
        do {
            try await enable.value
            XCTFail("expected the persist failure to surface")
        } catch {}

        hydrationGate.release()
        try await load.value
        await fixture.model.flushAlertEvaluations()

        // Parked + divergent (desired ON, durable OFF): startup refuses.
        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled)
        XCTAssertFalse(fixture.model.usageAlertsAuthorized)

        // One successful toggle heals everything.
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        try await driveCriticalCrossing(fixture)
        let posts = await scheduler.posts
        XCTAssertFalse(posts.isEmpty)
    }

    func testFailedDisableKeepsPostingStoppedDespiteDurableOn() async throws {
        let scheduler = NotificationSchedulingSpy()
        let saveGate = SettingsSaveGate()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeFixture(
            directory: directory, scheduler: scheduler, appSettings: settings
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        try await driveCriticalCrossing(fixture)
        let baseline = await scheduler.posts.count
        XCTAssertGreaterThan(baseline, 0, "arrange: alerts active and posting")

        saveGate.armFailure()
        let disable = fixture.model.requestSetUsageAlerts(false)
        do {
            try await disable.value
            XCTFail("expected the persist failure to surface")
        } catch {}
        await fixture.model.flushAlertEvaluations()

        // Gate dropped at the tap (I4) and stays down; toggle still shows ON.
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: try XCTUnwrap(fixture.model.accounts.first).id,
            fetchedAt: Date(timeIntervalSince1970: 5_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: try XCTUnwrap(fixture.model.accounts.first).id,
            fetchedAt: Date(timeIntervalSince1970: 6_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let after = await scheduler.posts.count
        XCTAssertEqual(after, baseline, "no post may fire after the opt-out tap")
    }

    func testEntryCancelledColdStartEnableParksAndStartupRefuses() async throws {
        let scheduler = NotificationSchedulingSpy()
        let hydrationGate = HydrationGate()
        let fixture = try makeFixture(scheduler: scheduler, hydrationGate: hydrationGate)
        defer { fixture.removeFiles() }

        hydrationGate.arm()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        // Cancel in the same synchronous span as the claim: the pass's entry
        // checkCancellation throws inside the parking catch.
        let enable = fixture.model.requestSetUsageAlerts(true)
        enable.cancel()
        do {
            try await enable.value
            XCTFail("expected CancellationError")
        } catch {}

        hydrationGate.release()
        try await load.value
        await fixture.model.flushAlertEvaluations()

        // Startup must refuse: setting OFF, nothing activated, no prompt.
        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled)
        XCTAssertFalse(fixture.model.usageAlertsAuthorized)
        let promptCount = await scheduler.requestAuthorizationCallCount
        XCTAssertEqual(promptCount, 0)

        // Heals on the next request.
        try await fixture.model.setUsageAlertsEnabled(true)
        try await driveCriticalCrossing(fixture)
        let posts = await scheduler.posts
        XCTAssertFalse(posts.isEmpty)
    }

    func testMootFailedEnableWithDurableOnStillConvergesAtStartup() async throws {
        let scheduler = NotificationSchedulingSpy()
        let saveGate = SettingsSaveGate()
        let hydrationGate = HydrationGate()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate,
            appSettings: settings
        )
        defer { fixture.removeFiles() }

        hydrationGate.arm()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()

        saveGate.armFailure()
        let enable = fixture.model.requestSetUsageAlerts(true)
        do {
            try await enable.value
            XCTFail("expected the persist failure to surface")
        } catch {}

        hydrationGate.release()
        try await load.value
        await fixture.model.flushAlertEvaluations()

        // desired ON == durable ON: the park is moot; startup converges.
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
        XCTAssertTrue(fixture.model.usageAlertsAuthorized)
        XCTAssertTrue(
            fixture.model.alertsActiveForTesting(),
            "moot convergence must actually open the posting gate"
        )
    }

    func testStartupPassNeverWritesSettings() async throws {
        let saveGate = SettingsSaveGate()
        let directory = try Self.makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(saveGate.savedValues.isEmpty, "I7: startup never persists")
    }

    /// The post-`requestAuthorization` version guard (`AppModel.reconcileAlertsPass`,
    /// the `guard version == alertsDesiredVersion else { return }` immediately
    /// after the `await`): an enable suspended inside its own authorization
    /// request must not commit `usageAlertsAuthorized` or activate once a
    /// newer disable has already claimed a later version while it was
    /// suspended. Otherwise the stale enable's continuation, on resuming,
    /// would resurrect authorization state (and potentially `alertsActive`)
    /// against the user's final, already-completed opt-out.
    func testEnableSupersededDuringAuthorizationDoesNotCommitOrActivate() async throws {
        let scheduler = NotificationSchedulingSpy()
        let fixture = try makeFixture(scheduler: scheduler)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        // Enable suspends inside its own requestAuthorization (hydrated
        // .userRequest); a disable registered meanwhile claims a newer
        // version and drops the gate at the tap (I4).
        await scheduler.armAuthorizationGate()
        let enable = fixture.model.requestSetUsageAlerts(true)
        await scheduler.waitUntilAuthorizationRequestIsSuspended()
        let disable = fixture.model.requestSetUsageAlerts(false)

        // The resumed enable is stale: the post-authorization version guard
        // must refuse to commit usageAlertsAuthorized or re-raise the gate.
        await scheduler.releaseAuthorizationRequest(returning: true)
        try await enable.value
        try await disable.value
        await fixture.model.flushAlertEvaluations()

        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled)
        XCTAssertFalse(
            fixture.model.usageAlertsAuthorized,
            "a superseded enable must not commit an authorization result"
        )
        try await driveCriticalCrossing(fixture)
        let posts = await scheduler.posts
        XCTAssertTrue(posts.isEmpty, "no post after the final opt-out")
    }

    /// Shared "prove the runtime is genuinely active/inactive" tail: signs in
    /// a fresh account and drives two snapshots that cross the critical
    /// (90%) threshold — the same shape as scenario 1's inline crossing
    /// above, factored out for reuse by scenarios 2, 3, and the scenario-1
    /// variant above. Kept as
    /// two separate `save` + `flushAlertEvaluations` calls (rather than one
    /// snapshot straight at 0.05) so a priming baseline is established by
    /// the first snapshot before the second one is evaluated as a genuine
    /// crossing, matching how `AlertPolicy` edge-triggers off a prior
    /// sample.
    private func driveCriticalCrossing(_ fixture: Fixture) async throws {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
    }

    /// Pause-accounts: a paused account is excluded from `refreshableAccounts`
    /// , so the periodic re-evaluation sweep never sees it while
    /// paused — a fresh crossing landed in `snapshotStore` while paused must
    /// not post. (Priming is the deliberate exception: `primeAllAlerts`
    /// covers paused accounts too, per — priming never posts.) Resuming
    /// must not replay a crossing that was already posted before the pause,
    /// either — pausing must not clear `AlertStateStore`'s edge-trigger memory.
    func testPausedAccountSkipsAlertEvaluationAndResumeDoesNotReplayOldCrossing() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let criticalID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let postsWhileActive = await fixture.scheduler.posts
        XCTAssertEqual(postsWhileActive.filter { $0.id == criticalID }.count, 1)

        // Pause, then land a snapshot with a NEW weekly-critical crossing — if
        // the paused account were still evaluated, this WOULD post. It must not.
        try await fixture.model.setPaused(accountID: account.id, paused: true)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()
        let postsWhilePaused = await fixture.scheduler.posts
        XCTAssertEqual(
            postsWhilePaused.count,
            postsWhileActive.count,
            "a paused account must not be evaluated for alerts"
        )

        // Resume triggers an immediate `refreshAll`, which fetches through
        // `fixture.adapter`. Make that fetch land a STILL-CRITICAL fiveHour
        // window (not the adapter's default nil) so the post-resume
        // evaluation actually re-examines the SAME crossing: with the
        // edge-trigger memory intact, `AlertPolicy.evaluate` sees no NEW
        // crossing (already critical) and emits nothing — an evaluation
        // against a nil window could never distinguish that from a
        // regression that wiped the memory on pause, which is why a fixed
        // nil/nil fetch here would make this assertion vacuous.
        fixture.adapter.fiveHourRemaining = 0.05
        try await fixture.model.setPaused(accountID: account.id, paused: false)
        await fixture.model.flushAlertEvaluations()
        let postsAfterResume = await fixture.scheduler.posts
        XCTAssertEqual(
            postsAfterResume.filter { $0.id == criticalID }.count,
            1,
            "resume must not replay the pre-pause crossing"
        )
    }

    func testEnablingWhilePausedPrimesBaselineSoResumeDoesNotPostPreEnableCrossing() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // The account is already past the CRITICAL tier while alerts are off.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        // Pause FIRST, then enable alerts: priming must still establish the
        // paused account's baseline (priming never posts, so including
        // dormant accounts is safe — excluding them is the bug).
        try await fixture.model.setPaused(accountID: account.id, paused: true)
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .critical,
            "enabling must prime the paused account's pre-existing crossing as already notified"
        )

        // Resume with the crossing still present in fresh data. The primed
        // baseline — not luck — is what must keep this silent.
        fixture.adapter.fiveHourRemaining = 0.05
        try await fixture.model.setPaused(accountID: account.id, paused: false)
        await fixture.model.flushAlertEvaluations()

        let criticalID = AlertMessage.id(
            for: .threshold(kind: .fiveHour, tier: .critical, percent: 90),
            accountID: account.id
        )
        let posts = await fixture.scheduler.posts
        XCTAssertEqual(
            posts.filter { $0.id == criticalID }.count,
            0,
            "a crossing that predates enabling must not post on resume"
        )
    }

    // MARK: - Configured thresholds resolved per-account provider

    func testAlertUsesConfiguredThresholdForItsProvider() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `AppModel.appSettings` is `private` — a directly-constructed
        // `AppSettings`, shared with the fixture via its injection point (the
        // same pattern the hydration-race tests above use), is how a test
        // reaches `setThresholds` without the model exposing an internal.
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await settings.setThresholds(
            ThresholdPair(warningPercent: 60, criticalPercent: 90),
            provider: .claude,
            window: .fiveHour
        )
        try await fixture.model.setUsageAlertsEnabled(true)

        // 65% used (remainingFraction 0.35): below the 75% default, at/above
        // the configured 60% warning threshold for this account's provider.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.35, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(posts.first).title.contains("60%"),
            "the configured 60% warning threshold, not the 75% default, must appear in the post"
        )
    }

    func testAlertDoesNotFireForAnotherProvidersThreshold() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        // The account is `.chatGPT` — a lowered threshold configured for
        // `.claude` must never apply to it, proving thresholds are resolved
        // per-account provider rather than from a single shared lookup.
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Work")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await settings.setThresholds(
            ThresholdPair(warningPercent: 60, criticalPercent: 90),
            provider: .claude, // NOT the account's provider
            window: .fiveHour
        )
        try await fixture.model.setUsageAlertsEnabled(true)

        // 65% used: at/above the misapplied 60% but below the 75% default
        // that should actually govern this `.chatGPT` account.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.35, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertTrue(
            posts.isEmpty,
            "a threshold configured for a different provider must not fire for this account"
        )
    }

    // MARK: - A threshold edit is itself a crossing

    /// A LOWERED threshold is a new crossing even though no snapshot and no
    /// refresh state changed — so the `snapshots`/`states` sink, which is the
    /// only thing that drives evaluation, never fires for it.
    ///
    /// Left undelivered this is not merely late (one poll, ~300s): if the app
    /// is relaunched inside that window, `primeAllAlerts()` evaluates the new
    /// threshold, commits `notifiedTier` as already-notified and deliberately
    /// posts nothing, so the alert the user just configured is lost for the
    /// rest of the window.
    func testLoweringAThresholdBelowCurrentUsageAlertsWithoutWaitingForTheNextPoll() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        // 68% used: under the 75% default, so the snapshot alone fires nothing.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.32, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let before = await fixture.scheduler.posts
        XCTAssertTrue(before.isEmpty, "68% must not cross the 75% default")

        // No snapshot arrives after this — the edit is the only event.
        try await fixture.model.setWarningPercent(60, provider: .claude, window: .fiveHour)
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.count, 1, "lowering the warning under current usage must alert")
        let title = try XCTUnwrap(posts.first).title
        XCTAssertTrue(
            title.contains("60%"),
            "the post must state the newly configured 60%, got \(title)"
        )
    }

    /// The edit-driven evaluation must go through the same watermark as every
    /// other evaluation, not post unconditionally.
    func testLoweringAThresholdPostsOnlyOnceAcrossLaterEvaluations() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.32, resetsAt: nil),
            weekly: nil
        ))
        try await fixture.model.setWarningPercent(60, provider: .claude, window: .fiveHour)
        await fixture.model.flushAlertEvaluations()
        let afterEdit = await fixture.scheduler.posts
        XCTAssertEqual(afterEdit.count, 1)

        // A later poll at the same usage, and a second edit that does not
        // raise the effective tier, must both stay silent.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.32, resetsAt: nil),
            weekly: nil
        ))
        try await fixture.model.setWarningPercent(55, provider: .claude, window: .fiveHour)
        await fixture.model.flushAlertEvaluations()

        let afterSecondEdit = await fixture.scheduler.posts
        XCTAssertEqual(
            afterSecondEdit.count, 1,
            "the warning already fired for this window; re-evaluating must not repost"
        )
    }

    /// Guards the design decision the edit-driven evaluation could most
    /// easily break: evaluating on every edit must NOT resurrect the
    /// lower-tier re-fire that clearing `notifiedTier` used to cause.
    ///
    /// At 95% used with critical already notified, raising critical 90 → 97
    /// drops the effective tier to `.warning`. Only the watermark
    /// (`.warning > .critical` is false) keeps that from posting a warning
    /// the user has already moved past.
    func testRaisingAThresholdDoesNotPostALowerTierForAnAlreadyNotifiedWindow() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        // 95% used crosses the 90% default critical.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let afterCritical = await fixture.scheduler.posts
        XCTAssertEqual(afterCritical.count, 1, "critical must fire once")

        try await fixture.model.setCriticalPercent(97, provider: .claude, window: .fiveHour)
        await fixture.model.flushAlertEvaluations()

        let afterRaise = await fixture.scheduler.posts
        XCTAssertEqual(
            afterRaise.count, 1,
            "raising critical above current usage must not emit the now-effective warning"
        )
    }

    /// The edit-time post must leave a PERSISTED watermark, so the relaunch
    /// prime that would otherwise have swallowed the crossing instead finds
    /// it already notified and stays silent.
    func testAThresholdEditAlertDoesNotRepostAfterRelaunch() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstScheduler = NotificationSchedulingSpy()
        let firstFixture = try makeFixture(directory: directory, scheduler: firstScheduler)
        try await firstFixture.model.load(startBackgroundRefresh: false)
        let sessionID = try firstFixture.model.beginSignIn(provider: .claude)
        try await firstFixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(firstFixture.model.accounts.first)
        try await firstFixture.model.setUsageAlertsEnabled(true)

        try await firstFixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.32, resetsAt: nil),
            weekly: nil
        ))
        try await firstFixture.model.setWarningPercent(60, provider: .claude, window: .fiveHour)
        await firstFixture.model.flushAlertEvaluations()
        let firstPosts = await firstScheduler.posts
        XCTAssertEqual(firstPosts.count, 1)

        let secondScheduler = NotificationSchedulingSpy()
        await secondScheduler.setAuthorizationStatusResult(true)
        let secondFixture = try makeFixture(directory: directory, scheduler: secondScheduler)
        try await secondFixture.model.load(startBackgroundRefresh: false)
        await secondFixture.model.flushAlertEvaluations()

        let relaunchPosts = await secondScheduler.posts
        XCTAssertTrue(
            relaunchPosts.isEmpty,
            "the crossing was already notified before the quit; a relaunch must not repost it"
        )
    }

    // MARK: - The notification channel is honoured

    /// Turning the Notification channel off for a cell must actually stop the
    /// notification — while leaving the drop row, which is the whole point of
    /// having two channels.
    func testNotificationChannelOffSuppressesThePostButKeepsTheDropRow() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        try await settings.setChannels(
            AlertChannels(notification: false, drop: true),
            forKey: AppSettingsData.thresholdKey(provider: .claude, window: .fiveHour)
        )

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty, "the notification channel is off for this cell")
        XCTAssertEqual(
            fixture.model.attentionRows(now: now).count, 1,
            "the drop channel is still on, so the row must remain"
        )
    }

    // MARK: - Evaluation is not gated on notification permission

    /// Denying notification permission must not stop alert STATE from being
    /// evaluated — it gates the notification CHANNEL only.
    ///
    /// Without this, a drop-only user is broken in a way that never heals: a
    /// dismissal is recorded, permission is denied, and the reset that should
    /// clear `dismissedTier` never runs, so that subject stays hidden for
    /// every future window rather than just the dismissed one.
    func testWindowResetClearsADismissalEvenWhenNotificationsAreDenied() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationResult(false)
        await scheduler.setAuthorizationStatusResult(false)
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, scheduler: scheduler, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertFalse(
            fixture.model.usageAlertsAuthorized,
            "this test is only meaningful while authorization is denied"
        )

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.count, 1, "the drop must work without notification permission")
        fixture.model.dismissAttentionRows(rows)
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)

        // The window resets: capacity is freed, which must clear the dismissal.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-30),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.95, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.dismissedTier,
            "the reset must clear the dismissal even with notifications denied"
        )
    }

    /// The other half: evaluation running while unauthorized must still not
    /// POST anything.
    func testNothingIsPostedWhileNotificationsAreDenied() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationResult(false)
        await scheduler.setAuthorizationStatusResult(false)
        let fixture = try makeFixture(directory: directory, scheduler: scheduler)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Date(timeIntervalSince1970: 2_940),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let posts = await scheduler.posts
        XCTAssertTrue(posts.isEmpty, "authorization denied must still suppress every post")
    }

    // MARK: - Dismissing the drop snoozes it until the next reset

    /// The ✕ is not "hide these rows" — it is "stop showing me this until
    /// something actually changes". Nothing is allowed back until a window
    /// somewhere resets, so usage merely creeping up (or a different window
    /// crossing) cannot pop the panel again minutes later.
    func testDismissingSuppressesEvenANewCrossingOnAnotherWindow() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        // Weekly over the line; 5h still well under it.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.90, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.model.attentionRows(now: now).count, 1)

        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)

        // The 5h window now crosses too — a crossing that was never dismissed.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-30),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.04, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(
            fixture.model.attentionRows(now: now).isEmpty,
            "a snoozed drop stays down until a reset, even for a brand-new crossing"
        )
    }

    /// ...and a reset anywhere brings it back.
    func testAResetOnAnyWindowEndsTheSnooze() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-90),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()
        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)

        // The 5h window resets — freed capacity — while weekly stays spent.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-30),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.95, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(
            fixture.model.attentionRows(now: now).count, 1,
            "a reset on ANY window ends the snooze; the still-spent weekly shows again"
        )
    }

    /// The snooze must survive a relaunch, or quitting the app becomes a way
    /// to un-dismiss the panel.
    func testTheSnoozeSurvivesRelaunch() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()
        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        await fixture.model.flushAlertEvaluations()

        let relaunch = try makeFixture(directory: directory)
        try await relaunch.model.load(startBackgroundRefresh: false)
        XCTAssertTrue(
            relaunch.model.attentionRows(now: now).isEmpty,
            "quitting must not un-dismiss the drop"
        )
    }

    /// The snooze must hydrate on its own. It was assigned inside the
    /// `usageAlertsEnabled` branch of `apply`, so a relaunch where that flag
    /// had NOT changed silently loaded it as false and the dismissed drop
    /// came back.
    func testSnoozeSurvivesRelaunchWhenTheAlertsFlagIsUnchanged() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))
        await fixture.model.flushAlertEvaluations()
        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        await fixture.model.flushAlertEvaluations()

        // Relaunch with alerts ALREADY enabled on disk — the flag does not
        // change, so nothing about it is re-applied.
        let relaunch = try makeFixture(directory: directory)
        try await relaunch.model.load(startBackgroundRefresh: false)
        XCTAssertTrue(
            relaunch.model.attentionRows(now: now).isEmpty,
            "the snooze must hydrate independently of the alerts flag"
        )
    }

    /// Cursor has no rate window and emits no `.reset`, so a spend-only user
    /// could snooze the drop and never get it back.
    func testCursorBillingPeriodAdvanceEndsTheSnooze() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .cursor)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Cursor")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await settings.setSpendWarningCents(5_000)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        let firstStart = now.addingTimeInterval(-86_400 * 20)
        let firstPeriod = now.addingTimeInterval(86_400)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: firstStart,
                resetsAt: firstPeriod,
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.model.attentionRows(now: now).count, 1)

        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)

        // A new invoice STARTS; spend is still over the threshold.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-30),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 9_000,
                periodStart: firstPeriod,
                resetsAt: firstPeriod.addingTimeInterval(86_400 * 30),
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(
            fixture.model.attentionRows(now: now).count, 1,
            "a Cursor rollover must lift the snooze — it is the only reset a spend-only user gets"
        )
    }

    /// The bug reported 2026-08-27: the ✕ was undone on every refresh.
    /// Cursor's `get-monthly-invoice` had started reporting `periodEndMs` as
    /// the fetch time for the open invoice, so `periodEnd` advanced on every
    /// poll and the rollover rule above — keyed on it — lifted the snooze each
    /// time. The end drifting inside the SAME cycle is not a rollover.
    func testCursorPeriodEndDriftWithinTheSameCycleDoesNotEndTheSnooze() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .cursor)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Cursor")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await settings.setSpendWarningCents(5_000)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        let cycleStart = now.addingTimeInterval(-86_400 * 20)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-360),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: cycleStart,
                resetsAt: now.addingTimeInterval(-361),
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.model.attentionRows(now: now).count, 1)

        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)

        // The next poll, five minutes later: same cycle, `periodEnd` is once
        // again "now".
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: cycleStart,
                resetsAt: now.addingTimeInterval(-61),
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(
            fixture.model.attentionRows(now: now).isEmpty,
            "a drifting period end inside the same invoice must not undo the ✕"
        )
        XCTAssertTrue(settings.data.dropSnoozed, "the snooze flag itself must be untouched")
    }

    /// The first poll after upgrading from 0.28.1 sees a
    /// memory with no `periodStart`. If the month rolled while the app was
    /// closed, that poll must still lift the snooze — the new start is past
    /// the only boundary evidence the legacy memory holds, its `periodEnd`.
    func testLegacySnoozeLiftsWhenTheFirstUpgradedPollCrossesTheBoundary() async throws {
        let (directory, fixture, _, account, now) = try await makeSnoozedLegacyCursorFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A new invoice started after the legacy poll's drifting end.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: now.addingTimeInterval(-300),
                resetsAt: now.addingTimeInterval(-61),
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(
            fixture.model.attentionRows(now: now).count, 1,
            "a boundary crossed while closed must lift the snooze on the first upgraded poll"
        )
    }

    /// And the same upgrade poll inside the SAME invoice must not: the new
    /// start lies before the legacy end, so nothing rolled.
    func testLegacySnoozeSurvivesTheFirstUpgradedPollWithinTheSamePeriod() async throws {
        let (directory, fixture, settings, account, now) = try await makeSnoozedLegacyCursorFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: now.addingTimeInterval(-86_400 * 20),
                resetsAt: now.addingTimeInterval(-61),
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)
        XCTAssertTrue(settings.data.dropSnoozed)
    }

    /// A Cursor account whose alert memory was written WITHOUT `periodStart`
    /// (0.28.1) — modelled by a snapshot that carries none, as a legacy
    /// `snapshots.json` decodes — with the drop snoozed over its spend row.
    private func makeSnoozedLegacyCursorFixture() async throws -> (
        directory: URL, fixture: Fixture, settings: AppSettings, account: AccountRecord, now: Date
    ) {
        let directory = try Self.makeTempDirectory()
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .cursor)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Cursor")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await settings.setSpendWarningCents(5_000)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-400),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: CursorSpend(
                spentCents: 7_500,
                periodStart: nil,
                resetsAt: now.addingTimeInterval(-401),
                planLabel: "Pro"
            )
        ))
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(fixture.model.attentionRows(now: now).count, 1)

        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        XCTAssertTrue(fixture.model.attentionRows(now: now).isEmpty)
        return (directory, fixture, settings, account, now)
    }

    /// Whichever transition lands last on disk must be the one that is true
    /// now, regardless of the order two in-flight persists reach the queue.
    func testRapidSnoozeThenUnsnoozePersistsTheFinalState() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await settings.load()

        settings.setDropSnoozedInMemory(true)
        async let a: Void = settings.setDropSnoozed()
        settings.setDropSnoozedInMemory(false)
        async let b: Void = settings.setDropSnoozed()
        _ = try await (a, b)

        let reloaded = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await reloaded.load()
        XCTAssertFalse(
            reloaded.data.dropSnoozed,
            "the last intent wins — a persist must write the value that is current when it runs"
        )
    }

    /// A reset that happened while the app was closed must lift the snooze on
    /// the next launch even for a user who denied notifications — the drop does
    /// not need authorization, so its lifecycle must not depend on it.
    ///
    /// CAVEAT, stated so nobody trusts this further than it goes: this test
    /// passes with OR without the `primeAllAlerts()` call in the denied branch
    /// (verified by mutation), because some other publication happens to drive
    /// an evaluation after settings hydrate. It pins the BEHAVIOUR, not that
    /// call. Reproducing the ordering Codex described — the snapshot store
    /// publishing before settings, with nothing publishing afterwards — needs
    /// control over load ordering the fixture does not expose.
    func testSnoozeLiftsOnRelaunchAfterAnOfflineResetWithNotificationsDenied() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        fixture.model.snoozeAttentionDrop(fixture.model.attentionRows(now: now))
        await fixture.model.flushAlertEvaluations()

        // While "closed", the window resets — the snapshot on disk is already
        // post-reset when the next launch reads it.
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-30),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.95, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.05, resetsAt: nil)
        ))

        let denied = NotificationSchedulingSpy()
        await denied.setAuthorizationResult(false)
        await denied.setAuthorizationStatusResult(false)
        let relaunch = try makeFixture(directory: directory, scheduler: denied)
        try await relaunch.model.load(startBackgroundRefresh: false)
        await relaunch.model.flushAlertEvaluations()

        XCTAssertFalse(
            relaunch.model.usageAlertsAuthorized,
            "this test is only meaningful while authorization is denied"
        )
        XCTAssertEqual(
            relaunch.model.attentionRows(now: now).count, 1,
            "priming must still observe the offline reset and lift the snooze"
        )
    }

    // MARK: - Attention drop: rows and dismissal

    func testAttentionRowsSurfaceACrossingForTheDropChannel() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tier, .critical)
        XCTAssertEqual(rows.first?.accountID, account.id)
    }

    /// Dismissal must persist: the panel recomputes from live state every
    /// tick, so a dismissal that lives only in memory would let the row
    /// return on the very next tick.
    func testDismissingARowRemovesItFromLaterRecomputations() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()

        let rows = fixture.model.attentionRows(now: now)
        XCTAssertEqual(rows.count, 1)

        fixture.model.dismissAttentionRows(rows)
        XCTAssertTrue(
            fixture.model.attentionRows(now: now).isEmpty,
            "a dismissed row must not come back on the next recomputation"
        )
    }

    /// The dismissal is written through `AppModel`, never straight to the
    /// store, so it obeys the same tombstone discipline as every other alert
    /// state write — and survives a relaunch.
    func testDismissalPersistsAcrossRelaunch() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        fixture.model.dismissAttentionRows(fixture.model.attentionRows(now: now))
        await fixture.model.flushAlertEvaluations()

        let relaunch = try makeFixture(directory: directory)
        try await relaunch.model.load(startBackgroundRefresh: false)
        XCTAssertEqual(
            relaunch.model.alertStateForTesting(accountID: account.id)?.fiveHour.dismissedTier,
            .critical,
            "the dismissal must be on disk, not only in memory"
        )
    }

    /// Dismissal must never resurrect state for an account being removed —
    /// the same hazard `applyAlertDecision` guards against.
    func testDismissingARowForARemovedAccountIsIgnored() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        let fixture = try makeFixture(directory: directory, appSettings: settings)
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        let now = Date(timeIntervalSince1970: 3_000)
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: now.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
        let rows = fixture.model.attentionRows(now: now)

        try await fixture.model.removeAccount(id: account.id)
        fixture.model.dismissAttentionRows(rows)

        XCTAssertNil(
            fixture.model.alertStateForTesting(accountID: account.id),
            "a removed account must not have alert state written back for it"
        )
    }

    /// - Parameters:
    ///   - directory: Reuse an existing directory (so a second fixture can
    ///     simulate a "relaunch" against the same persisted files) instead of
    ///     a fresh temp one.
    ///   - alertStateStore: Inject a custom store (e.g. one whose `save`
    ///     fails on demand) instead of the default file-backed one.
    ///   - scheduler: Inject a custom scheduler instance instead of a fresh
    ///     spy, so a test can pre-configure its authorization results before
    ///     `load()` runs.
    ///   - hydrationGate: Wired to `AppModel`'s `beforeAlertsHydrationCompletes`
    ///     hook (see `HydrationGate`'s doc). Defaults to a fresh, unarmed gate
    ///     — a no-op unless a test explicitly arms it — so this parameter is
    ///     only relevant to the startup-readiness-barrier race tests.
    private func makeFixture(
        directory: URL? = nil,
        alertStateStore: AlertStateStore? = nil,
        scheduler: NotificationSchedulingSpy = NotificationSchedulingSpy(),
        hydrationGate: HydrationGate = HydrationGate(),
        appSettings: AppSettings? = nil
    ) throws -> Fixture {
        let directory = try directory ?? Self.makeTempDirectory()

        let accounts = AccountStore(
            fileURL: directory.appending(path: "accounts.json")
        )
        let snapshots = UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json")
        )
        let pendingStore = PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending-profile-deletions.json")
        )
        let historyStore = UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)
        )
        let appSettings = appSettings ?? AppSettings(
            fileURL: directory.appending(path: "app-settings.json")
        )
        let alertStateStore = alertStateStore ?? AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json")
        )
        let profileManager = AlertsWebProfileManagerSpy()
        let adapter = AlertsProviderAdapterSpy()
        // A second, independently-provider'd adapter — needed only by the
        // per-provider threshold tests (`beginSignIn(provider: .chatGPT)`).
        // Registering it unconditionally is harmless: no other test signs in
        // as `.chatGPT`, so it is simply unused dead weight for them.
        let chatGPTAdapter = AlertsProviderAdapterSpy(provider: .chatGPT)
        // Cursor, for the spend-snooze test — unused dead weight for the rest.
        let cursorAdapter = AlertsProviderAdapterSpy(provider: .cursor)
        let model = AppModel(
            accountStore: accounts,
            snapshotStore: snapshots,
            pendingProfileDeletionStore: pendingStore,
            historyStore: historyStore,
            appSettings: appSettings,
            alertStateStore: alertStateStore,
            profileManager: profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [adapter, chatGPTAdapter, cursorAdapter]),
            notificationScheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_000) },
            beforeAlertsHydrationCompletes: { await hydrationGate.hook() },
            systemPowerObserver: NoopSystemPowerObserver()
        )
        return Fixture(
            directory: directory,
            model: model,
            snapshots: snapshots,
            alertStateStore: alertStateStore,
            scheduler: scheduler,
            adapter: adapter,
            chatGPTAdapter: chatGPTAdapter
        )
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Seeds the settings file with usage alerts durably ON, as if a prior
    /// session enabled them — decodeIfPresent supplies every other default.
    private func seedUsageAlertsEnabled(in directory: URL) throws {
        try Data(#"{"usageAlertsEnabled":true}"#.utf8)
            .write(to: directory.appending(path: "app-settings.json"))
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let model: AppModel
    let snapshots: UsageSnapshotStore
    let alertStateStore: AlertStateStore
    let scheduler: NotificationSchedulingSpy
    let adapter: AlertsProviderAdapterSpy
    let chatGPTAdapter: AlertsProviderAdapterSpy

    nonisolated func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Counts calls to an injected `AlertStateStore.saveStates` closure, so a
/// test can assert on how many saves actually reached persistence (M4
/// refinement: steady-state no-change decisions must not enqueue one).
@MainActor
private final class SaveCallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
private final class AlertsWebProfileManagerSpy: WebProfileManaging {
    func makeWebView(profileID: UUID) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func removeProfile(profileID: UUID) async throws {}
}

/// Minimal sign-in adapter: returns a snapshot with no usage windows, so the
/// account's initial (pre-alerts-enabled) fetch during `completeSignIn` never
/// risks firing an alert. Tests drive usage via `fixture.snapshots.save`
/// directly instead of through this adapter.
///
/// `fiveHourRemaining` (default `nil`, mirroring the History fixture's
/// `HistoryProviderAdapterSpy.fiveHourRemaining`) lets a test opt a fetch
/// (e.g. the resume-triggered `refreshAll` inside `setPaused`) into
/// returning a real fiveHour window instead of the default nil/nil — needed
/// so a post-resume evaluation actually re-examines the SAME crossing an
/// edge-trigger-memory regression would replay, rather than a window-less
/// snapshot no regression could ever be caught against. Every other test
/// leaves this `nil` and observes the original nil/nil behavior unchanged.
@MainActor
private final class AlertsProviderAdapterSpy: ProviderAdapter {
    let provider: Provider
    let signInURL = URL(string: "https://claude.ai/")!
    var fiveHourRemaining: Double?

    /// `provider` defaults to `.claude` (the default single-adapter fixture
    /// shape almost every test uses); the per-provider threshold tests
    /// pass `.chatGPT` to get a second, independently-provider'd account
    /// through the SAME spy shape rather than a bespoke type.
    init(provider: Provider = .claude) {
        self.provider = provider
    }

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: fiveHourRemaining.map {
                UsageWindow(kind: .fiveHour, remainingFraction: $0, resetsAt: nil)
            },
            weekly: nil
        )
    }
}

/// Startup-readiness-barrier race test seam: wired to `AppModel`'s
/// `beforeAlertsHydrationCompletes` hook (called once, unconditionally,
/// immediately before `load()` may flip `alertsHydrated = true`) so a test
/// can pin a concurrent `setUsageAlertsEnabled` call to interleave
/// deterministically DURING hydration — the exact window the startup
/// readiness barrier closes — without relying on incidental
/// `Task`-scheduling order or a sleep. Structurally the same
/// gate-with-suspension-signal mechanism as
/// `NotificationSchedulingSpy`'s authorization gate (see its doc for the
/// flakiness this pattern avoids), but generalized to a plain void
/// interleave point: unlike `authorizationStatus()` — which `load()` only
/// calls when the persisted setting is ALREADY enabled — this hook fires
/// unconditionally on every `load()`, which is required for tests where the
/// persisted setting starts OFF and the interleaved call is itself what
/// turns it on.
@MainActor
private final class HydrationGate {
    private var armed = false
    private var pending: CheckedContinuation<Void, Never>?
    private var suspendedSignal: CheckedContinuation<Void, Never>?

    /// Arms the gate so the next `hook()` call suspends. A gate that is
    /// never armed is a permanent no-op — the default for fixtures that
    /// don't care about this interleave point.
    func arm() {
        armed = true
    }

    func hook() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            pending = continuation
            suspendedSignal?.resume()
            suspendedSignal = nil
        }
    }

    /// Suspends the caller until `hook()` has actually registered itself as
    /// suspended (i.e. `load()` has reached the gate and is now waiting) —
    /// the deterministic signal a test needs before it's safe to run the
    /// concurrent call that must interleave with the still-pending one.
    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { continuation in
            suspendedSignal = continuation
        }
    }

    /// Releases the suspended `hook()` call, letting `load()` proceed.
    func release() {
        pending?.resume()
        pending = nil
    }
}

/// AppSettings persistence seam: injected as the AppSettings saveSettings:
/// closure so a test can hold a save mid-flight (publish-after-save means
/// the published value stays stale while held), fail a save on demand, and
/// count every save that reached persistence (I7 assertions).
@MainActor
private final class SettingsSaveGate {
    struct SaveFailed: Error {}
    private var armed = false
    private var failNext = false
    private var pending: CheckedContinuation<Void, Never>?
    private var suspendedSignal: CheckedContinuation<Void, Never>?
    private(set) var savedValues: [AppSettingsData] = []

    func arm() { armed = true }
    func armFailure() { failNext = true }

    func gate(_ settings: AppSettingsData) async throws {
        if failNext {
            failNext = false
            throw SaveFailed()
        }
        if armed {
            armed = false
            await withCheckedContinuation { continuation in
                pending = continuation
                suspendedSignal?.resume()
                suspendedSignal = nil
            }
        }
        savedValues.append(settings)
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { continuation in
            suspendedSignal = continuation
        }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

/// Records every `post` call and returns configurable authorization results.
/// An `actor` (rather than a locked class) since `NotificationScheduling`
/// requires `Sendable` and its methods are called via `await` from `AppModel`.
private actor NotificationSchedulingSpy: NotificationScheduling {
    private(set) var posts: [(id: String, title: String, body: String)] = []
    var authorizationResult = true
    /// Backs `authorizationStatus`: the OS-level status queried on
    /// `load()`, independent of (and not implied by) `requestAuthorization`.
    var authorizationStatusResult = true

    /// Version-guard race test seam: when armed, the NEXT call to
    /// `requestAuthorization()` suspends until `releaseAuthorizationRequest`
    /// is called, instead of returning immediately. This lets a test
    /// deterministically interleave a second `setUsageAlertsEnabled` call
    /// while a first one's continuation is still pending inside its own
    /// authorization request — the exact shape of the stale-enable race —
    /// without relying on a sleep or on incidental Task-scheduling order.
    private var gateArmed = false
    private var pendingAuthorizationContinuation: CheckedContinuation<Bool, Never>?
    private var suspendedSignal: CheckedContinuation<Void, Never>?

    /// Startup-pass race seam (mirrors the requestAuthorization gate): when
    /// armed, the NEXT authorizationStatus() call suspends until
    /// releaseStatusQuery, so a test can pin taps to land while load()'s
    /// startup path sits inside its status query.
    private var statusGateArmed = false
    private var pendingStatusContinuation: CheckedContinuation<Bool, Never>?
    private var statusSuspendedSignal: CheckedContinuation<Void, Never>?
    /// I6 assertion support: counts prompt-capable authorization requests.
    private(set) var requestAuthorizationCallCount = 0

    func armStatusGate() {
        statusGateArmed = true
    }

    func waitUntilStatusQueryIsSuspended() async {
        if pendingStatusContinuation != nil { return }
        await withCheckedContinuation { continuation in
            statusSuspendedSignal = continuation
        }
    }

    func releaseStatusQuery(_ result: Bool = true) {
        pendingStatusContinuation?.resume(returning: result)
        pendingStatusContinuation = nil
    }

    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        guard gateArmed else { return authorizationResult }
        gateArmed = false
        return await withCheckedContinuation { continuation in
            pendingAuthorizationContinuation = continuation
            suspendedSignal?.resume()
            suspendedSignal = nil
        }
    }

    func authorizationStatus() async -> Bool {
        guard statusGateArmed else { return authorizationStatusResult }
        statusGateArmed = false
        return await withCheckedContinuation { continuation in
            pendingStatusContinuation = continuation
            statusSuspendedSignal?.resume()
            statusSuspendedSignal = nil
        }
    }

    func setAuthorizationStatusResult(_ value: Bool) {
        authorizationStatusResult = value
    }

    func setAuthorizationResult(_ value: Bool) {
        authorizationResult = value
    }

    func post(id: String, title: String, body: String) async {
        posts.append((id: id, title: title, body: body))
    }

    /// Arms the gate so the next `requestAuthorization()` call suspends.
    func armAuthorizationGate() {
        gateArmed = true
    }

    /// Suspends the caller until a `requestAuthorization()` call has
    /// actually registered itself as suspended on the gate (i.e. the armed
    /// call has been made and is now waiting) — the deterministic signal a
    /// test needs before it's safe to run the "newer" transition that must
    /// interleave with the still-pending one.
    func waitUntilAuthorizationRequestIsSuspended() async {
        if pendingAuthorizationContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspendedSignal = continuation
        }
    }

    /// Releases the suspended `requestAuthorization()` call, letting its
    /// continuation resume with `authorizationResult` (or an explicit
    /// override).
    func releaseAuthorizationRequest(returning value: Bool? = nil) {
        pendingAuthorizationContinuation?.resume(returning: value ?? authorizationResult)
        pendingAuthorizationContinuation = nil
    }
}
