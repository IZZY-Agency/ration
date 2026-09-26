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

    /// The rollup gap limit follows the coordinator's cadence: 2 × the longest
    /// poll of the current mode, re-read per fold so Low Power Mode applies live.
    func testHistoryGapLimitFollowsLowPowerMode() throws {
        let power = NoopSystemPowerObserver()
        let fixture = try makeFixture(systemPowerObserver: power)
        defer { fixture.removeFiles() }
        XCTAssertEqual(fixture.model.history.gapLimit(), PollSchedule.rollupGapLimit(lowPowerMode: false))
        power.isLowPowerModeEnabled = true
        XCTAssertEqual(fixture.model.history.gapLimit(), PollSchedule.rollupGapLimit(lowPowerMode: true))
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

    // MARK: No warm-up or plan read through an open sign-in window

    /// A reauth window opened while the triggering refresh was in flight:
    /// the saved snapshot must not start warm-up or Claude's plan read,
    /// both of which run in the web view the user is signing in on.
    func testWarmUpAndPlanReadSkipAnAccountWhoseSignInOpenedMidFetch() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        fixture.adapter.onNextFetch = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }
        let evaluationsBefore = evaluator.evaluationCount
        let planReadsBefore = fixture.adapter.planReadCount

        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushPlanRefreshes()

        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertNil(fixture.model.accounts.first?.lastAutoStartedAt)
        XCTAssertEqual(evaluator.evaluationCount, evaluationsBefore, "warm-up must not even prepare")
        XCTAssertEqual(fixture.adapter.planReadCount, planReadsBefore, "no plan read in the sign-in view")
    }

    /// Opened while `prepareKeepAlive` was suspended: the commit-point
    /// re-check must stop the reservation and the POST.
    func testWarmUpStopsAtCommitWhenASignInOpensDuringPreparation() async throws {
        let evaluator = HookedAutoStartEval()
        final class ReservationSaves { var count = 0 }
        let reservationSaves = ReservationSaves()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate)),
            saveAccounts: { accounts in
                if accounts.contains(where: { $0.lastAutoStartedAt != nil }) {
                    reservationSaves.count += 1
                }
            }
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        evaluator.onDiscovery = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(reservationSaves.count, 0, "stopped at the commit point: not even reserved")
        XCTAssertNil(fixture.model.accounts.first?.lastAutoStartedAt, "nothing reserved")
        XCTAssertNil(fixture.model.accounts.first?.keepAliveConversationID, "nothing POSTed")
    }

    /// Opened while the completion POST was out: the send has landed, but
    /// the follow-up refetch must not run in the sign-in view.
    func testWarmUpSkipsItsRefetchWhenASignInOpensDuringTheSend() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        evaluator.onPostNumber = 2
        evaluator.onPost = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }
        let fetchesBefore = fixture.adapter.fetchCallCount

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertNotNil(fixture.model.accounts.first?.lastAutoStartedAt, "the send itself went ahead")
        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(
            fixture.adapter.fetchCallCount,
            fetchesBefore + 1,
            "only the triggering refresh fetched; the post-send refetch was skipped"
        )
        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty, "skipping the refetch is not a failure")
    }

    /// Opened after the conversation-create POST: the completion's POST
    /// gate refuses, so the window never starts. Nothing that starts a window
    /// was sent, so the reservation is handed back and no failure is shown.
    func testWarmUpPostGateRefusesAndReleasesTheReservationWhenASignInOpens() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        evaluator.onPostNumber = 1
        evaluator.onPost = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }
        let outcomesBefore = fixture.model.accounts.first?.warmUpOutcomes.count ?? 0

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(evaluator.postCount, 1, "the completion POST must not go out")
        XCTAssertNil(fixture.model.accounts.first?.lastAutoStartedAt, "the reservation is handed back")
        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty, "a skip, not a failure")
        XCTAssertNil(fixture.model.warmUpBanner)
        XCTAssertEqual(
            fixture.model.accounts.first?.warmUpOutcomes.count ?? 0,
            outcomesBefore,
            "a sign-in skip records no warm-up outcome"
        )
    }

    /// Opened while the reservation was being saved: no POST at all, and the
    /// reservation is handed back.
    func testWarmUpReleasesTheReservationWhenASignInOpensDuringItsSave() async throws {
        let evaluator = HookedAutoStartEval()
        final class Hook {
            var model: AppModel?
            var accountID: UUID?
            var fired = false
        }
        let hook = Hook()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate)),
            saveAccounts: { accounts in
                guard
                    !hook.fired,
                    let model = hook.model,
                    let accountID = hook.accountID,
                    accounts.contains(where: { $0.id == accountID && $0.lastAutoStartedAt != nil })
                else { return }
                hook.fired = true
                _ = try? model.beginReauthentication(accountID: accountID)
            }
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        hook.model = fixture.model
        hook.accountID = account.id

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertTrue(hook.fired, "the reservation save must have opened the session")
        XCTAssertEqual(evaluator.postCount, 0, "nothing may be POSTed")
        XCTAssertNil(fixture.model.accounts.first?.lastAutoStartedAt, "the reservation is handed back")
        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty)
    }

    /// Discovery fails AFTER a sign-in window opened during it: a skip, not a
    /// warm-up failure banner.
    func testPreparationFailureAfterASignInOpensIsNotReported() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        evaluator.failDiscovery = true
        evaluator.onDiscovery = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty, "a skip, not a failure")
        XCTAssertNil(fixture.model.warmUpBanner)
    }

    /// The other side: the same discovery failure WITHOUT a sign-in window
    /// is still reported.
    func testPreparationFailureWithoutASignInIsStillReported() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        _ = try await signInWithWarmUp(fixture)
        evaluator.failDiscovery = true

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertFalse(fixture.model.autoStartFailures.isEmpty)
    }

    // MARK: DEBUG send honours an open sign-in window at every boundary

    /// Opened during the send's warm-up fetch: nothing is prepared or sent.
    func testDebugSendStopsWhenASignInOpensDuringItsFetch() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        fixture.adapter.onNextFetch = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }

        await fixture.model.debugSendKeepAlive(accountID: account.id)

        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(evaluator.evaluationCount, 0, "no preparation in the sign-in view")
        XCTAssertEqual(evaluator.postCount, 0)
    }

    /// Opened during preparation: the POST gate refuses.
    func testDebugSendPostGateRefusesWhenASignInOpensDuringPreparation() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        evaluator.onDiscovery = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }

        await fixture.model.debugSendKeepAlive(accountID: account.id)

        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(evaluator.postCount, 0, "nothing may be POSTed")
    }

    /// Opened while the completion POST was out: the send lands, the refetch
    /// is skipped.
    func testDebugSendSkipsItsRefetchWhenASignInOpensDuringTheSend() async throws {
        let evaluator = HookedAutoStartEval()
        let fixture = try makeFixture(
            messageSender: ClaudeMessageSender(client: WebUsageClient(evaluator: evaluator.evaluate))
        )
        defer { fixture.removeFiles() }
        let account = try await signInWithWarmUp(fixture)
        let model = fixture.model
        evaluator.onPostNumber = 2
        evaluator.onPost = {
            _ = try? model.beginReauthentication(accountID: account.id)
        }
        let fetchesBefore = fixture.adapter.fetchCallCount

        await fixture.model.debugSendKeepAlive(accountID: account.id)

        XCTAssertEqual(evaluator.postCount, 2, "the send itself went ahead")
        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(fixture.adapter.fetchCallCount, fetchesBefore + 1, "only the warm-up fetch; no refetch")
    }

    private func signInWithWarmUp(_ fixture: Fixture) async throws -> AccountRecord {
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)
        fixture.adapter.fiveHourRemaining = 1.0
        return account
    }

    private func makeFixture(
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        beforeAutoStartCommit: @escaping @MainActor () async -> Void = {},
        saveAccounts: AccountStore.SaveAccounts? = nil,
        systemPowerObserver: NoopSystemPowerObserver = NoopSystemPowerObserver()
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
            systemPowerObserver: systemPowerObserver
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

/// `AutoStartWebEvalStub` that counts every script it is asked to run and
/// can run a hook on the first model-discovery call (inside
/// `prepareKeepAlive`) or the first POST (inside `sendKeepAlive`).
@MainActor
private final class HookedAutoStartEval {
    private(set) var evaluationCount = 0
    /// POSTs that actually reached the page (each gate already passed).
    private(set) var postCount = 0
    var onDiscovery: (@MainActor () -> Void)?
    /// Model discovery answers 500 while set, so `prepareKeepAlive` throws.
    var failDiscovery = false
    var onPost: (@MainActor () -> Void)?
    /// Which POST (1-based) runs `onPost`: 1 = conversation create for a new
    /// account, 2 = its completion.
    var onPostNumber = 1

    func evaluate(
        script: String,
        arguments: [String: Any],
        webView: WKWebView
    ) async throws -> Any? {
        evaluationCount += 1
        if script.contains("method: \"POST\"") {
            postCount += 1
            if postCount == onPostNumber, let hook = onPost {
                onPost = nil
                hook()
            }
        } else if !script.contains("performance.getEntriesByType") {
            if let hook = onDiscovery {
                onDiscovery = nil
                hook()
            }
            if failDiscovery {
                return ["status": 500, "retryAfter": NSNull(), "body": ""]
            }
        }
        return try await AutoStartWebEvalStub.evaluate(
            script: script,
            arguments: arguments,
            webView: webView
        )
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
    private(set) var planReadCount = 0
    /// Runs inside the next fetch, then clears — e.g. to open a sign-in
    /// window while a refresh is in flight.
    var onNextFetch: (@MainActor () -> Void)?

    func verifySession(in webView: WKWebView) async throws {}

    func refreshPlanDetection(
        for snapshot: UsageSnapshot,
        in webView: WKWebView
    ) async throws -> PlanDetection? {
        planReadCount += 1
        return nil
    }

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        fetchCallCount += 1
        if let hook = onNextFetch {
            onNextFetch = nil
            hook()
        }
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
