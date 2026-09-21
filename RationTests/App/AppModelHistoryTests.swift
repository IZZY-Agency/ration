import WebKit
import XCTest
@testable import Ration

@MainActor
final class AppModelHistoryTests: XCTestCase {
    func testRefreshRecordsHistoryAfterAutoStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        fixture.adapter.fiveHourRemaining = 0.8
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.history.flush()

        XCTAssertEqual(
            fixture.model.history.rawSamples(accountID: account.id, kind: .fiveHour).last?.remaining,
            0.8
        )
    }

    func testRemovedAccountHistoryIsDeleted() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        fixture.adapter.fiveHourRemaining = 0.8
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.history.flush()
        XCTAssertFalse(
            fixture.model.history.rawSamples(accountID: account.id, kind: .fiveHour).isEmpty
        )

        try await fixture.model.removeAccount(id: account.id)

        XCTAssertTrue(
            fixture.model.history.rawSamples(accountID: account.id, kind: .fiveHour).isEmpty
        )
    }

    /// Regression: `handleAutoStart` records a re-fetched, newer
    /// snapshot (S2) via its follow-up refetch. The triggering snapshot (S1,
    /// older) used to be recorded AFTER awaiting `handleAutoStart` returned,
    /// so S2 landed in history before S1 — S1 then fails the series'
    /// monotonic-order guard and permanently flips `isProjectionEligible` to
    /// false. This drives a real refresh that FIRES auto-start (a Claude
    /// account with `autoStartFiveHour` enabled and a fresh, "not started" 5h
    /// window) through a stub `ClaudeMessageSender` (so `prepare`/`send`
    /// succeed without a real network), whose re-fetch returns a
    /// strictly-newer snapshot. RED before the fix: `isProjectionEligible ==
    /// false`. GREEN after: `true`, with S1 (older) then S2 (newer) recorded
    /// in that chronological order.
    func testAutoStartFiresWithoutCorruptingHistoryOrder() async throws {
        let fixture = try makeFixture(messageSender: makeSucceedingMessageSender())
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)

        // A fresh, unused 5h window (remainingFraction 1, no scheduled reset)
        // is the observed "not started" state — it fires auto-start.
        fixture.adapter.fiveHourRemaining = 1.0
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.history.flush()

        XCTAssertNil(fixture.model.errorMessage, "auto-start must succeed against the stub message sender")
        XCTAssertNil(fixture.model.warmUpBanner, "a succeeding warm-up has nothing to report")
        let series = try XCTUnwrap(fixture.model.history.rawSeries[account.id]?[.fiveHour])
        XCTAssertTrue(
            series.isProjectionEligible,
            "the triggering snapshot must be recorded before the auto-start re-fetch, not after"
        )
        XCTAssertEqual(
            series.samples.map(\.ts.timeIntervalSince1970),
            series.samples.map(\.ts.timeIntervalSince1970).sorted(),
            "recorded samples must be in chronological order"
        )
    }

    /// Fail-closed pin: an auto-start-eligible snapshot that carries NO
    /// organization (only possible outside the real Claude adapter) must
    /// SKIP the send entirely — never fall back to live discovery. The guard
    /// exits before the durable reservation, so `lastAutoStartedAt` stays
    /// untouched.
    func testAutoStartFailsClosedWhenSnapshotCarriesNoOrganization() async throws {
        let fixture = try makeFixture(messageSender: makeSucceedingMessageSender())
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)

        fixture.adapter.fiveHourRemaining = 1.0   // the "not started" trigger state
        fixture.adapter.organizationID = nil      // …but no org provenance
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertNil(
            fixture.model.accounts.first?.lastAutoStartedAt,
            "without org provenance the attempt must be skipped before the durable reservation"
        )
    }

    /// A disable requested during handleAutoStart's mid-send suspension is
    /// honored — the synchronous marker claim beats the resuming continuation,
    /// so no keep-alive is reserved or POSTed. Also proves the claim IS
    /// synchronous (a concurrent request is rejected the instant the first
    /// returns) and that the marker is released on completion (a later mutation
    /// succeeds) — so a leaked marker cannot green this test.
    func testDisableDuringMidSendPreventsAutoStart() async throws {
        let commitGate = AutoStartCommitGate()
        let saveGate = ArmedAccountSaveGate()
        let fixture = try makeFixture(
            messageSender: makeSucceedingMessageSender(),
            beforeAutoStartCommit: { await commitGate.suspend() },
            saveAccounts: { await saveGate.save($0) }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)

        // A fresh, unused 5h window fires auto-start.
        fixture.adapter.fiveHourRemaining = 1.0
        let refreshTask = Task { await fixture.model.refreshAll(reason: .manual) }
        await commitGate.waitUntilStarted() // handleAutoStart suspended at the seam

        // Land the disable synchronously, its persist held in flight.
        saveGate.arm()
        let disable = try fixture.model.requestSetAutoStart(accountID: account.id, enabled: false)

        // The claim is synchronous: a concurrent request is rejected right now.
        XCTAssertThrowsError(
            try fixture.model.requestSetAutoStart(accountID: account.id, enabled: true)
        ) { error in
            guard case AccountStoreError.operationInProgress = error else {
                return XCTFail("expected operationInProgress, got \(error)")
            }
        }

        commitGate.resume()
        await refreshTask.value // handleAutoStart runs its commit guard and bails

        let afterRace = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertNil(afterRace.lastAutoStartedAt, "no auto-start may be reserved after a mid-send disable")
        XCTAssertNil(afterRace.keepAliveConversationID, "no keep-alive may be POSTed after a mid-send disable")

        // Let the disable finish; the marker must release cleanly.
        saveGate.resume()
        try await disable.value
        XCTAssertFalse(try XCTUnwrap(fixture.model.accounts.first).autoStartFiveHour)

        // Marker released → a later mutation succeeds (no lingering operationInProgress).
        try await fixture.model.requestSetAutoStart(accountID: account.id, enabled: true).value
        XCTAssertTrue(try XCTUnwrap(fixture.model.accounts.first).autoStartFiveHour)
    }

    /// (remove half): `requestRemoveAccount` claims its markers SYNCHRONOUSLY
    /// at the call — a concurrent account mutation is rejected the instant it
    /// returns, before the removal's async work runs. This is the property that
    /// makes a remove requested during handleAutoStart's mid-send suspension
    /// visible to the commit-point guard. The guard's actual bail is exercised
    /// under a live race by `testDisableDuringMidSendPreventsAutoStart` — its
    /// single guard statement rejects on BOTH `mutatingAccountIDs` and
    /// `removingAccountIDs`, and `requestRemoveAccount` sets both. (A live remove
    /// race can't be gated here: `removeAccount` calls
    /// `refreshCoordinator.cancel`, which awaits the very in-flight refresh a
    /// commit seam would freeze — a test-only deadlock, not a production path.)
    func testRequestRemoveAccountClaimsMarkersSynchronously() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let removal = try fixture.model.requestRemoveAccount(id: account.id)

        // The claim is synchronous: a concurrent mutation is rejected right now,
        // before the removal is awaited.
        XCTAssertThrowsError(
            try fixture.model.requestSetAutoStart(accountID: account.id, enabled: true)
        ) { error in
            guard case AccountStoreError.operationInProgress = error else {
                return XCTFail("expected operationInProgress, got \(error)")
            }
        }

        try await removal.value
        XCTAssertTrue(fixture.model.accounts.isEmpty, "the account is removed")
    }

    /// Pause-accounts race companion to `testDisableDuringMidSendPreventsAutoStart`:
    /// a pause requested during `handleAutoStart`'s mid-send suspension is
    /// honored by the SAME commit-point guard (`mutatingAccountIDs`), not a
    /// separate mechanism — `requestSetPaused` claims the marker synchronously,
    /// so the guard observes the in-flight pause the instant it re-runs the
    /// policy, before the pause's own persist has completed.
    func testPauseLandedMidFlightAbortsAutoStartCommit() async throws {
        let commitGate = AutoStartCommitGate()
        let saveGate = ArmedAccountSaveGate()
        let fixture = try makeFixture(
            messageSender: makeSucceedingMessageSender(),
            beforeAutoStartCommit: { await commitGate.suspend() },
            saveAccounts: { await saveGate.save($0) }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)

        // A fresh, unused 5h window fires auto-start.
        fixture.adapter.fiveHourRemaining = 1.0
        let refreshTask = Task { await fixture.model.refreshAll(reason: .manual) }
        await commitGate.waitUntilStarted() // handleAutoStart suspended at the seam

        // Land the pause synchronously while the send is suspended pre-commit,
        // its persist held in flight.
        saveGate.arm()
        let pause = try fixture.model.requestSetPaused(accountID: account.id, paused: true)

        commitGate.resume()
        await refreshTask.value // handleAutoStart runs its commit guard and bails

        // The commit-point guard re-ran the policy against `mutatingAccountIDs`
        // (claimed synchronously above) and bailed: no reservation, no send —
        // even though the pause's own persist has not landed yet.
        let afterRace = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertNil(afterRace.lastAutoStartedAt, "no auto-start may be reserved after a mid-send pause")
        XCTAssertNil(afterRace.keepAliveConversationID, "no keep-alive may be POSTed after a mid-send pause")

        // Let the pause finish; the marker must release cleanly and isPaused persists.
        saveGate.resume()
        try await pause.value

        let final = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertTrue(final.isPaused)
        XCTAssertNil(final.lastAutoStartedAt)
        XCTAssertNil(final.keepAliveConversationID)
    }

    /// The reported bug, end to end: an account whose weekly allowance is spent
    /// cannot accept a keep-alive, so warm-up must not spend its once-per-window
    /// reservation on a POST that is certain to be rejected. It reports the hold
    /// as a status instead, and resumes by itself once the allowance returns.
    func testWarmUpHoldsWithoutReservingWhileTheWeeklyAllowanceIsSpent() async throws {
        let fixture = try makeFixture(messageSender: makeSucceedingMessageSender())
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)

        // A fresh, unused 5h window — everything says fire — but no weekly
        // allowance is left.
        fixture.adapter.fiveHourRemaining = 1.0
        fixture.adapter.weeklyRemaining = 0
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertNil(
            fixture.model.accounts.first?.lastAutoStartedAt,
            "a warm-up that cannot succeed must not burn the once-per-window reservation"
        )
        XCTAssertNil(
            fixture.model.accounts.first?.keepAliveConversationID,
            "nothing may be POSTed while the weekly allowance is spent"
        )
        XCTAssertEqual(
            fixture.model.warmUpBanner?.severity,
            .info,
            "the hold is a status, not a failure"
        )

        // Non-vacuousness AND self-resumption: the same setup with allowance
        // left over fires normally on the very next refresh.
        fixture.adapter.weeklyRemaining = 0.5
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertNotNil(
            fixture.model.accounts.first?.lastAutoStartedAt,
            "warm-up must resume on the first refresh after the allowance returns"
        )
        XCTAssertNil(fixture.model.warmUpBanner, "the hold retracts itself once it stops being true")
    }

    /// The other half of the report: the banner used to be a written-once
    /// `errorMessage` that survived until the app was quit. A later warm-up that
    /// succeeds must take the failure back.
    func testASucceedingWarmUpClearsTheEarlierFailureBanner() async throws {
        let evaluator = ToggleableAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(
                client: WebUsageClient(evaluator: evaluator.evaluate)
            )
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)
        fixture.adapter.fiveHourRemaining = 1.0

        // Model discovery fails → the attempt dies BEFORE the reservation, so
        // the next refresh is free to try again.
        evaluator.failModelDiscovery = true
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(
            fixture.model.warmUpBanner?.severity,
            .critical,
            "a failed warm-up must surface"
        )
        XCTAssertNil(
            fixture.model.accounts.first?.lastAutoStartedAt,
            "a failure before the reservation must not consume the window"
        )

        evaluator.failModelDiscovery = false
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertNotNil(fixture.model.accounts.first?.lastAutoStartedAt, "the retry must have sent")
        XCTAssertNil(
            fixture.model.warmUpBanner,
            "the failure banner must retract once a later warm-up succeeds"
        )
    }

    /// Removing an account takes its recorded failure with it. The banner would
    /// hide the entry anyway (it renders only live, warm-up-enabled accounts),
    /// but state kept for something that no longer exists is exactly what turns
    /// into a stale banner the next time the derivation changes.
    func testRemovingAnAccountDropsItsRecordedFailure() async throws {
        let evaluator = ToggleableAutoStartEval()
        evaluator.failModelDiscovery = true
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(
                client: WebUsageClient(evaluator: evaluator.evaluate)
            )
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)
        fixture.adapter.fiveHourRemaining = 1.0
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertNotNil(
            fixture.model.autoStartFailures[account.id],
            "the failure must be recorded for this test to mean anything"
        )

        try await fixture.model.removeAccount(id: account.id)

        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty)
    }

    /// The POST is the only irreversible step: once Claude has accepted the
    /// keep-alive, the 5h window HAS started, and nothing that fails afterwards
    /// (persisting the reusable conversation id, the follow-up re-fetch) makes
    /// the attempt a failure. Reporting one would tell the user warm-up
    /// "didn't run" about a window that is demonstrably running — and the
    /// reservation means it will not run again for another 4h55m anyway.
    func testNoFailureIsReportedWhenTheKeepAliveActuallySent() async throws {
        let fixture = try makeFixture(
            messageSender: makeSucceedingMessageSender(),
            // Fails exactly the save that persists the conversation id — i.e.
            // `recordAutoStart`, which runs AFTER the POST landed.
            saveAccounts: { accounts in
                if accounts.contains(where: { $0.keepAliveConversationID != nil }) {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)
        fixture.adapter.fiveHourRemaining = 1.0
        await fixture.model.refreshAll(reason: .manual)

        // Non-vacuousness: the post-send save must really have been rejected.
        XCTAssertNil(
            fixture.model.accounts.first?.keepAliveConversationID,
            "the post-send save must have failed for this test to mean anything"
        )
        XCTAssertNotNil(
            fixture.model.accounts.first?.lastAutoStartedAt,
            "the reservation taken before the POST still stands"
        )
        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty)
        XCTAssertNil(fixture.model.warmUpBanner, "the keep-alive landed; nothing failed")
    }

    private func makeFixture(
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        beforeAutoStartCommit: @escaping @MainActor () async -> Void = {},
        saveAccounts: AccountStore.SaveAccounts? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let accounts = AccountStore(
            fileURL: directory.appending(path: "accounts.json"),
            saveAccounts: saveAccounts
        )
        let snapshots = UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json")
        )
        let pendingStore = PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending-profile-deletions.json")
        )
        let historyStore = UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let appSettings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json")
        )
        let alertStateStore = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json")
        )
        let profileManager = HistoryWebProfileManagerSpy()
        let adapter = HistoryProviderAdapterSpy()
        let model = AppModel(
            accountStore: accounts,
            snapshotStore: snapshots,
            pendingProfileDeletionStore: pendingStore,
            historyStore: historyStore,
            appSettings: appSettings,
            alertStateStore: alertStateStore,
            profileManager: profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [adapter]),
            messageSender: messageSender,
            now: { Date(timeIntervalSince1970: 1_000) },
            beforeAutoStartCommit: beforeAutoStartCommit,
            systemPowerObserver: NoopSystemPowerObserver()
        )
        return Fixture(
            directory: directory,
            model: model,
            profileManager: profileManager,
            adapter: adapter
        )
    }

    /// A `ClaudeMessageSender` wired to a stub JS evaluator (mirroring
    /// `ClaudeMessageSenderTests`' `WebEvalStub`) so `prepare`/`send` succeed
    /// without a real WebKit navigation or network call — the auto-start
    /// send path is otherwise unreachable in a unit test.
    private func makeSucceedingMessageSender() -> ClaudeMessageSender {
        ClaudeMessageSender(client: WebUsageClient(evaluator: AutoStartWebEvalStub.evaluate))
    }
}

/// Suspends `handleAutoStart` at its commit-point seam until released.
@MainActor
private final class AutoStartCommitGate {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func suspend() async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

/// A pass-through `AccountStore.saveAccounts` that blocks the FIRST save after
/// `arm()`, so a mutation's persist can be held in flight (marker still claimed).
@MainActor
private final class ArmedAccountSaveGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }
    func save(_ accounts: [AccountRecord]) async {
        guard armed else { return }
        armed = false
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilBlocked() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

/// Stub JS evaluator for `WebUsageClient`: answers the exact scripts
/// `ClaudeMessageSender` issues (resource-path discovery, model discovery,
/// and the create-conversation / completion POSTs) so a full auto-start send
/// can succeed deterministically in a unit test.
@MainActor
private enum AutoStartWebEvalStub {
    static let organizationID = "123e4567-e89b-12d3-a456-426614174000"

    static func evaluate(
        script: String,
        arguments: [String: Any],
        webView: WKWebView
    ) async throws -> Any? {
        if script.contains("performance.getEntriesByType") {
            return ["/api/organizations/\(organizationID)/usage"]
        }
        if script.contains("method: \"POST\"") {
            return ["status": 200, "retryAfter": NSNull(), "body": ""]
        }
        // Model discovery: list of chat conversations.
        return [
            "status": 200,
            "retryAfter": NSNull(),
            "body": #"[{"model":"claude-test-model","uuid":"abc"}]"#,
        ]
    }
}

/// `AutoStartWebEvalStub` with a switch: model discovery can be made to fail
/// (and un-fail) between refreshes, so one test can drive a failed warm-up
/// followed by a succeeding one. Discovery fails BEFORE the durable
/// reservation, which is what leaves the next refresh free to retry.
@MainActor
private final class ToggleableAutoStartEval {
    var failModelDiscovery = false

    func evaluate(
        script: String,
        arguments: [String: Any],
        webView: WKWebView
    ) async throws -> Any? {
        if script.contains("performance.getEntriesByType") {
            return ["/api/organizations/\(AutoStartWebEvalStub.organizationID)/usage"]
        }
        if script.contains("method: \"POST\"") {
            return ["status": 200, "retryAfter": NSNull(), "body": ""]
        }
        if failModelDiscovery {
            return ["status": 500, "retryAfter": NSNull(), "body": ""]
        }
        return [
            "status": 200,
            "retryAfter": NSNull(),
            "body": #"[{"model":"claude-test-model","uuid":"abc"}]"#,
        ]
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let model: AppModel
    let profileManager: HistoryWebProfileManagerSpy
    let adapter: HistoryProviderAdapterSpy

    nonisolated func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class HistoryWebProfileManagerSpy: WebProfileManaging {
    private(set) var removedProfileIDs: [UUID] = []

    func makeWebView(profileID: UUID) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func removeProfile(profileID: UUID) async throws {
        removedProfileIDs.append(profileID)
    }
}

/// Returns a `UsageSnapshot` whose five-hour remaining fraction is
/// controllable via `fiveHourRemaining`, so tests can assert on a known
/// history sample. `fetchedAt` advances on every call so the history
/// store's monotonic-timestamp guard never rejects a sample.
@MainActor
private final class HistoryProviderAdapterSpy: ProviderAdapter {
    let provider = Provider.claude
    let signInURL = URL(string: "https://claude.ai/")!
    var fiveHourRemaining: Double?
    /// Weekly allowance left. nil (the default) models a provider that reports
    /// no weekly window at all — the warm-up gate must fail open on it.
    var weeklyRemaining: Double?
    /// Org provenance for produced snapshots; nil models a snapshot source
    /// that cannot vouch for its org (auto-start must then fail closed).
    var organizationID: String? = "11111111-2222-4333-8444-555555555555"
    private(set) var fetchCallCount = 0

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        fetchCallCount += 1
        let fiveHour = fiveHourRemaining.map {
            UsageWindow(kind: .fiveHour, remainingFraction: $0, resetsAt: nil)
        }
        let weekly = weeklyRemaining.map {
            UsageWindow(kind: .weekly, remainingFraction: $0, resetsAt: nil)
        }
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1_000 + Double(fetchCallCount)),
            fiveHour: fiveHour,
            weekly: weekly,
            organizationID: organizationID
        )
    }
}
