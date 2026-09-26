import WebKit
import XCTest
@testable import Ration

@MainActor
final class AppModelTests: XCTestCase {
    func testCompletingNewSignInVerifiesAndFetchesBeforePersistingAccount() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: sessionID,
            label: "  Personal  "
        )

        XCTAssertEqual(fixture.adapter.verifyCallCount, 1)
        XCTAssertEqual(fixture.adapter.fetchCallCount, 1)
        XCTAssertEqual(fixture.model.accounts.map(\.label), ["Personal"])
        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertNotNil(fixture.model.snapshot(for: account.id))
        XCTAssertNil(fixture.model.signInSession(for: sessionID))
    }

    /// A NEWLY added Claude account starts warm-up ON — the default a new
    /// account gets, disclosed at connect time (`WarmUpDefaults`).
    func testNewClaudeAccountStartsWithWarmUpOn() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")

        XCTAssertTrue(try XCTUnwrap(fixture.model.accounts.first).autoStartFiveHour)
    }

    /// Only Claude gets the on-by-default treatment — warm-up is a
    /// Claude-only feature.
    func testNewChatGPTAccountDoesNotGetWarmUp() async throws {
        let fixture = try makeFixture(
            adapters: [ProviderAdapterSpy(), ChatGPTAdapterStub()]
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Codex")

        XCTAssertFalse(try XCTUnwrap(fixture.model.accounts.first).autoStartFiveHour)
    }

    /// Re-authentication must never resurrect the on-by-default value: a
    /// user who turned warm-up off keeps it off across a re-auth, because
    /// `completeSignIn`'s reauth branch persists only via `accountStore
    /// .rename` (label-only) — it never re-adds the record with a freshly
    /// computed `autoStartFiveHour`.
    func testReauthenticationKeepsTheStoredWarmUpValue() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let signInID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: signInID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertTrue(account.autoStartFiveHour, "new Claude account must start with warm-up on")

        try await fixture.model.setAutoStart(accountID: account.id, enabled: false)

        let reauthenticationID = try fixture.model.beginReauthentication(accountID: account.id)
        try await fixture.model.completeSignIn(sessionID: reauthenticationID, label: "Personal")

        XCTAssertFalse(
            try XCTUnwrap(fixture.model.accounts.first).autoStartFiveHour,
            "re-authentication must not resurrect the on-by-default warm-up value"
        )
    }

    /// The static table `completeSignIn` and `AddAccountView`/onboarding
    /// copy all read from.
    func testWarmUpDefaultsTable() {
        XCTAssertTrue(WarmUpDefaults.autoStartForNewAccount(provider: .claude))
        XCTAssertFalse(WarmUpDefaults.autoStartForNewAccount(provider: .chatGPT))
        XCTAssertFalse(WarmUpDefaults.autoStartForNewAccount(provider: .cursor))
    }

    /// Passkey-only accounts: pasted cookies land in the SIGN-IN SESSION's
    /// own profile store (the exact store its fetches will read), and the web
    /// view reloads so the page reflects the session.
    func testPastedSessionCookiesLandInTheSessionProfileStore() async throws {
        let fixture = try makeFixture(
            adapters: [ProviderAdapterSpy(), ChatGPTAdapterStub()]
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)
        let session = try XCTUnwrap(fixture.model.signInSession(for: sessionID))

        try await fixture.model.applyPastedSessionCookies(
            sessionID: sessionID,
            raw: "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..fake.payload.tag"
        )

        // The cookies must land in the SESSION's store via the exact access
        // path production uses (the spy's stable configuration makes the
        // ephemeral store behave like production's identified ones).
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        var cookies: [HTTPCookie] = []
        for _ in 0..<40 where cookies.isEmpty {
            cookies = await store.allCookies()
            if cookies.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(cookies.map(\.name), ["__Secure-next-auth.session-token"])
        XCTAssertEqual(cookies.first?.domain, ".chatgpt.com")

        // The page must reload so the user can SEE the pasted session before
        // committing the account.
        let recording = try XCTUnwrap(session.webView as? RecordingWebView)
        XCTAssertEqual(recording.loadedRequests.last?.url, session.signInURL)

        fixture.profileManager.cleanUpStores()
    }

    /// A cookie application landing while verifySession is suspended means
    /// the verified credential state is no longer the installed one — the
    /// commit must be refused, even though the application COMPLETED (and
    /// removed its pending marker) before verify returned.
    func testApplyLandingDuringVerificationRefusesCommit() async throws {
        let stub = ChatGPTAdapterStub()
        let fixture = try makeFixture(adapters: [ProviderAdapterSpy(), stub])
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)
        let model = fixture.model
        stub.onVerify = {
            try? await model.applyPastedSessionCookies(
                sessionID: sessionID,
                raw: "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..mid.verify.tag"
            )
        }
        defer { stub.onVerify = nil }   // break stub→closure→model cycle

        do {
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "GPT")
            XCTFail("expected operationInProgress")
        } catch AccountStoreError.operationInProgress {
            // expected — never commit a credential state verify did not see
        }
    }

    /// The post-fetchUsage re-check is load-bearing on its own: an apply
    /// landing during the FETCH suspension (after verify already passed)
    /// must also refuse the commit.
    func testApplyLandingDuringFetchRefusesCommit() async throws {
        let stub = ChatGPTAdapterStub()
        let fixture = try makeFixture(adapters: [ProviderAdapterSpy(), stub])
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)
        let model = fixture.model
        stub.onFetch = {
            try? await model.applyPastedSessionCookies(
                sessionID: sessionID,
                raw: "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..mid.fetch.tag"
            )
        }
        defer { stub.onFetch = nil }

        do {
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "GPT")
            XCTFail("expected operationInProgress")
        } catch AccountStoreError.operationInProgress {
            // expected — the guarantee holds right up to the commit
        }
    }

    /// An apply that is IN FLIGHT when completeSignIn starts (its generation
    /// bump happened at apply entry, before the snapshot) is awaited and
    /// committed cleanly — the snapshot-before-await ordering must not
    /// false-positive on the very application it awaits.
    func testInFlightApplyAtCommitEntryIsAwaitedAndCommitted() async throws {
        let fixture = try makeFixture(
            adapters: [ProviderAdapterSpy(), ChatGPTAdapterStub()]
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)
        let model = fixture.model

        // Fire the apply WITHOUT awaiting its completion. One yield lets the
        // spawned task run to its first internal suspension — its generation
        // bump and pending registration are synchronous at entry — so
        // completeSignIn observes an IN-FLIGHT application.
        let apply = Task { @MainActor in
            try await model.applyPastedSessionCookies(
                sessionID: sessionID,
                raw: "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..fake.payload.tag"
            )
        }
        await Task.yield()
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "GPT")
        _ = try await apply.value

        XCTAssertEqual(fixture.model.accounts.map(\.label), ["GPT"])
        fixture.profileManager.cleanUpStores()
    }

    /// The guard must not false-positive on the application completeSignIn
    /// itself awaited: apply, then commit, succeeds cleanly.
    func testApplyBeforeVerificationCommitsCleanly() async throws {
        let fixture = try makeFixture(
            adapters: [ProviderAdapterSpy(), ChatGPTAdapterStub()]
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)

        try await fixture.model.applyPastedSessionCookies(
            sessionID: sessionID,
            raw: "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..fake.payload.tag"
        )
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "GPT")

        XCTAssertEqual(fixture.model.accounts.map(\.label), ["GPT"])
        fixture.profileManager.cleanUpStores()
    }

    /// A paste with cookie pairs but WITHOUT the actual credential must fail
    /// loudly instead of reporting success while installing no authentication.
    func testPasteWithoutTheSessionTokenThrowsMissingSessionToken() async throws {
        let fixture = try makeFixture(
            adapters: [ProviderAdapterSpy(), ChatGPTAdapterStub()]
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)

        do {
            try await fixture.model.applyPastedSessionCookies(
                sessionID: sessionID,
                raw: "_account=personal"
            )
            XCTFail("expected missingSessionToken")
        } catch SessionCookiePasteError.missingSessionToken {
            // expected
        }
    }

    func testPastedSessionCookiesRejectNonChatGPTSessions() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        do {
            try await fixture.model.applyPastedSessionCookies(
                sessionID: sessionID,
                raw: "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..fake.payload.tag"
            )
            XCTFail("expected unsupportedProvider")
        } catch SessionCookiePasteError.unsupportedProvider {
            // expected — only chatgpt.com sessions accept pasted cookies
        }
    }

    func testUnparseablePasteThrowsNothingToApply() async throws {
        let fixture = try makeFixture(
            adapters: [ProviderAdapterSpy(), ChatGPTAdapterStub()]
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .chatGPT)

        do {
            try await fixture.model.applyPastedSessionCookies(sessionID: sessionID, raw: "  ; ")
            XCTFail("expected nothingToApply")
        } catch SessionCookiePasteError.nothingToApply {
            // expected
        }
    }

    func testEmptyLabelDoesNotVerifyOrPersist() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        do {
            try await fixture.model.completeSignIn(
                sessionID: sessionID,
                label: "   "
            )
            XCTFail("Expected an empty-label error")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .emptyLabel)
        }

        XCTAssertEqual(fixture.adapter.verifyCallCount, 0)
        XCTAssertEqual(fixture.adapter.fetchCallCount, 0)
        XCTAssertTrue(fixture.model.accounts.isEmpty)
    }

    func testCancellingNewSignInDeletesOnlyItsWebProfile() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let profileID = try XCTUnwrap(
            fixture.model.signInSession(for: sessionID)?.webProfileID
        )

        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertEqual(fixture.profileManager.removedProfileIDs, [profileID])
        XCTAssertNil(fixture.model.signInSession(for: sessionID))
        XCTAssertTrue(fixture.model.accounts.isEmpty)
    }

    func testPreparingForTerminationCancelsActiveNewSignIn() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let profileID = try XCTUnwrap(
            fixture.model.signInSession(for: sessionID)?.webProfileID
        )

        XCTAssertTrue(fixture.model.requiresTerminationPreparation)
        let canTerminate = await fixture.model.prepareForTermination()

        XCTAssertTrue(canTerminate)
        XCTAssertNil(fixture.model.signInSession(for: sessionID))
        XCTAssertEqual(fixture.profileManager.removedProfileIDs, [profileID])
        XCTAssertFalse(fixture.model.requiresTerminationPreparation)
    }

    func testPreparingForTerminationPausesDuringSignInCommit() async throws {
        let gate = CommitGate()
        let fixture = try makeFixture(
            beforeSignInPersistence: { await gate.suspend() }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        let completion = Task { @MainActor in
            try await fixture.model.completeSignIn(
                sessionID: sessionID,
                label: "Personal"
            )
        }
        await gate.waitUntilStarted()

        let canTerminate = await fixture.model.prepareForTermination()

        XCTAssertFalse(canTerminate)
        XCTAssertNotNil(fixture.model.signInSession(for: sessionID))
        gate.resume()
        try await completion.value
        XCTAssertFalse(fixture.model.requiresTerminationPreparation)
    }

    func testCancellingDuringVerificationCannotPersistAccount() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let gate = VerificationGate()
        fixture.adapter.verificationGate = gate
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        let completion = Task { @MainActor in
            do {
                try await fixture.model.completeSignIn(
                    sessionID: sessionID,
                    label: "Personal"
                )
                return nil as Error?
            } catch {
                return error
            }
        }
        await gate.waitUntilStarted()
        await fixture.model.cancelSignIn(sessionID: sessionID)
        gate.resume()

        let completionError = await completion.value
        XCTAssertTrue(completionError is CancellationError)
        XCTAssertTrue(fixture.model.accounts.isEmpty)
        XCTAssertEqual(fixture.adapter.fetchCallCount, 0)
    }

    func testCancellationDuringCommitCannotDeleteProfile() async throws {
        let gate = CommitGate()
        let fixture = try makeFixture(
            beforeSignInPersistence: { await gate.suspend() }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        let completion = Task { @MainActor in
            try await fixture.model.completeSignIn(
                sessionID: sessionID,
                label: "Personal"
            )
        }
        await gate.waitUntilStarted()
        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertNotNil(fixture.model.signInSession(for: sessionID))
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)

        gate.resume()
        try await completion.value
        XCTAssertEqual(fixture.model.accounts.map(\.label), ["Personal"])
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
    }

    func testFailedCancelledProfileDeletionRetriesOnNextLoad() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let profileID = try XCTUnwrap(
            fixture.model.signInSession(for: sessionID)?.webProfileID
        )

        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertEqual(fixture.pendingStore.profileIDs, Set([profileID]))
        XCTAssertNil(fixture.model.signInSession(for: sessionID))

        fixture.profileManager.removeError = nil
        let restoredPendingStore = PendingProfileDeletionStore(
            fileURL: fixture.directory.appending(
                path: "pending-profile-deletions.json"
            )
        )
        let restoredModel = AppModel(
            accountStore: AccountStore(
                fileURL: fixture.directory.appending(path: "accounts.json")
            ),
            snapshotStore: UsageSnapshotStore(
                fileURL: fixture.directory.appending(path: "snapshots.json")
            ),
            pendingProfileDeletionStore: restoredPendingStore,
            historyStore: UsageHistoryStore(
                rootDirectory: fixture.directory.appending(
                    path: "history", directoryHint: .isDirectory
                )
            ),
            appSettings: AppSettings(
                fileURL: fixture.directory.appending(path: "app-settings.json")
            ),
            alertStateStore: AlertStateStore(
                fileURL: fixture.directory.appending(path: "alert-state.json")
            ),
            profileManager: fixture.profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [fixture.adapter]),
            systemPowerObserver: SystemPowerObserverStub()
        )
        try await restoredModel.load(startBackgroundRefresh: false)

        XCTAssertTrue(restoredPendingStore.profileIDs.isEmpty)
        XCTAssertEqual(fixture.profileManager.removedProfileIDs, [profileID])
    }

    func testQueueFailureStillDeletesProfileOrKeepsRetryableSession() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let profileID = try XCTUnwrap(
            fixture.model.signInSession(for: sessionID)?.webProfileID
        )

        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertEqual(fixture.profileManager.attemptedProfileIDs, [profileID])
        XCTAssertNotNil(fixture.model.signInSession(for: sessionID))
        XCTAssertTrue(fixture.model.hasPendingProfileCleanup)

        let canTerminateWhileRemovalFails = await fixture.model.prepareForTermination()
        XCTAssertFalse(canTerminateWhileRemovalFails)

        fixture.profileManager.removeError = nil
        let canTerminateAfterRetry = await fixture.model.prepareForTermination()

        XCTAssertTrue(canTerminateAfterRetry)
        XCTAssertNil(fixture.model.signInSession(for: sessionID))
        XCTAssertFalse(fixture.model.hasPendingProfileCleanup)
        XCTAssertEqual(fixture.profileManager.removedProfileIDs, [profileID])
        XCTAssertEqual(
            fixture.profileManager.attemptedProfileIDs,
            [profileID, profileID, profileID]
        )
    }

    /// The retry control lives inside the cleanup banner, so the banner must
    /// appear with the queued work and vanish with it — otherwise it outlives the
    /// button it contained and a successful retry reads as a no-op.
    func testCleanupBannerTracksTheQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertTrue(fixture.model.hasPendingProfileCleanup)
        XCTAssertEqual(fixture.model.profileCleanupBanner, ProfileCleanupCopy.pending)

        fixture.profileManager.removeError = nil
        await fixture.model.retryProfileCleanup()

        XCTAssertFalse(fixture.model.hasPendingProfileCleanup)
        XCTAssertNil(fixture.model.profileCleanupBanner)
    }

    /// The cleanup banner and `errorMessage` share no storage, so neither can
    /// retract or hide the other — an unrelated failure survives the queue
    /// draining, and the cleanup banner survives an unrelated failure.
    func testCleanupBannerAndUnrelatedErrorAreIndependent() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        await fixture.model.cancelSignIn(sessionID: sessionID)
        fixture.model.errorMessage = "Refresh failed for Ada."

        XCTAssertEqual(fixture.model.profileCleanupBanner, ProfileCleanupCopy.pending)

        fixture.profileManager.removeError = nil
        await fixture.model.retryProfileCleanup()

        XCTAssertNil(fixture.model.profileCleanupBanner)
        XCTAssertEqual(fixture.model.errorMessage, "Refresh failed for Ada.")
    }

    /// Even a message that is character-for-character one of the cleanup strings
    /// is untouchable when it was written as an `errorMessage`: ownership is
    /// storage, not text.
    func testDrainedQueueLeavesAnIdenticallyWordedErrorMessageAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        await fixture.model.cancelSignIn(sessionID: sessionID)
        fixture.model.errorMessage = ProfileCleanupCopy.pending

        fixture.profileManager.removeError = nil
        await fixture.model.retryProfileCleanup()

        XCTAssertNil(fixture.model.profileCleanupBanner)
        XCTAssertEqual(fixture.model.errorMessage, ProfileCleanupCopy.pending)
    }

    /// "Quit is paused…" is only true while VOLATILE cleanup is holding up the
    /// quit. Once the volatile entry lands in the durable journal instead, quit is
    /// no longer blocked, so the banner must fall back to the plain pending copy
    /// rather than keep claiming otherwise.
    func testQuitBlockedBannerFallsBackWhenOnlyDurableCleanupRemains() async throws {
        var failSave = true
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in
                if failSave { throw TestFailure.expected }
            }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        // Journalling fails, so the profile is only VOLATILE — which is what
        // `prepareForTermination` refuses to quit on.
        await fixture.model.cancelSignIn(sessionID: sessionID)
        XCTAssertTrue(fixture.model.hasVolatileProfileCleanup)

        let canTerminate = await fixture.model.prepareForTermination()

        XCTAssertFalse(canTerminate)
        XCTAssertEqual(
            fixture.model.profileCleanupBanner,
            ProfileCleanupCopy.blockingQuit
        )

        // Journalling now succeeds while deletion still fails: the entry becomes
        // durable-only, quit is no longer blocked by it.
        failSave = false
        await fixture.model.retryProfileCleanup()

        XCTAssertFalse(fixture.model.hasVolatileProfileCleanup)
        XCTAssertTrue(fixture.model.hasPendingProfileCleanup)
        XCTAssertEqual(fixture.model.profileCleanupBanner, ProfileCleanupCopy.pending)
    }

    /// A pending Settings edit is saved on the way out, and the
    /// cleanup veto still refuses the quit exactly as before.
    func testPendingEditIsSavedAndTheCleanupVetoStillRefuses() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        await fixture.model.cancelSignIn(sessionID: sessionID)
        XCTAssertTrue(fixture.model.hasVolatileProfileCleanup)
        let model = fixture.model
        let quietHours = QuietHoursAutosave.editor(
            stored: model.settings.quietHours,
            in: model.pendingEdits,
            save: { cells in
                try await model.setQuietHours(cells)
            },
            onError: { _ in }
        )
        quietHours.select([1, 2])
        XCTAssertTrue(model.pendingEdits.hasPendingEdits)

        let canTerminate = await model.prepareForTermination()

        XCTAssertFalse(canTerminate, "the veto is unchanged")
        XCTAssertEqual(model.profileCleanupBanner, ProfileCleanupCopy.blockingQuit)
        XCTAssertEqual(model.settings.quietHours, [1, 2], "the edit was saved anyway")
        XCTAssertFalse(model.pendingEdits.hasPendingEdits)
    }

    /// A throwing load step AFTER the queue is read must not hide the retry
    /// control: the cleanup flags have to be published before `load()` can abort.
    func testCleanupStateIsPublishedEvenWhenLoadAbortsLater() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let orphan = UUID()
        try await fixture.pendingStore.enqueue(orphan)
        // Make `appSettings.load()` — the first throwing step AFTER the deletion
        // queue is read — actually abort startup. Corrupt JSON will not do it:
        // `AppSettings.load` swallows `DecodingError` and fails closed instead. A
        // DIRECTORY where the file belongs makes `Data(contentsOf:)` throw a read
        // error, which propagates and unwinds `load()`.
        try FileManager.default.createDirectory(
            at: fixture.directory.appending(path: "app-settings.json"),
            withIntermediateDirectories: true
        )

        let restored = try makeFixture(directory: fixture.directory)
        defer { restored.removeFiles() }
        restored.profileManager.removeError = TestFailure.expected
        await restored.model.start()

        XCTAssertTrue(restored.model.hasPendingProfileCleanup)
        XCTAssertEqual(restored.model.profileCleanupBanner, ProfileCleanupCopy.pending)
    }

    /// A removal whose profile deletion AND rollback both fail leaves the profile
    /// journalled but throws straight out. The cleanup flags must still be
    /// published on that exit — they gate the only retry control there is.
    func testFailedRollbackStillPublishesTheOwedCleanup() async throws {
        var accountSaveCount = 0
        let fixture = try makeFixture(
            saveAccounts: { _ in
                accountSaveCount += 1
                // 1 = the sign-in commit, 2 = `accountStore.remove`, 3 = the
                // `accountStore.restore` rollback, which is the one that must fail.
                if accountSaveCount == 3 {
                    throw TestFailure.expected
                }
            }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        fixture.profileManager.removeError = TestFailure.expected

        do {
            try await fixture.model.removeAccount(id: account.id)
            XCTFail("Expected the failed rollback to propagate")
        } catch {
            XCTAssertEqual(error as? AccountRemovalError, .rollbackFailed)
        }

        XCTAssertTrue(fixture.pendingStore.profileIDs.contains(account.webProfileID))
        XCTAssertTrue(fixture.model.hasPendingProfileCleanup)
        XCTAssertEqual(fixture.model.profileCleanupBanner, ProfileCleanupCopy.pending)
    }

    /// A journal entry owned by an in-flight `removeAccount` is work in progress,
    /// not stuck cleanup. Surfacing it shows a warning plus a Retry control that
    /// `skipOrRevokeProfileCleanup` guarantees will do nothing.
    func testInFlightRemovalIsNotSurfacedAsStuckCleanup() async throws {
        let saveGate = SecondSnapshotSaveGate()
        let fixture = try makeFixture(
            saveSnapshots: { snapshots in await saveGate.save(snapshots) }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let removal = Task { @MainActor in
            try await fixture.model.removeAccount(id: account.id)
        }
        await saveGate.waitUntilBlocked()

        // Mid-removal: the profile IS journalled, and a concurrent cleanup pass
        // publishes state — but the entry belongs to this removal.
        XCTAssertTrue(fixture.pendingStore.profileIDs.contains(account.webProfileID))
        await fixture.model.retryProfileCleanup()

        XCTAssertFalse(fixture.model.hasPendingProfileCleanup)
        XCTAssertNil(fixture.model.profileCleanupBanner)
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
        // The invariant that makes skipping an in-flight removal SAFE: the durable
        // record must survive the skip. Dequeuing it here would strand this
        // authenticated profile with no cleanup record if the app died next.
        XCTAssertTrue(fixture.pendingStore.profileIDs.contains(account.webProfileID))

        saveGate.resume()
        try await removal.value

        XCTAssertFalse(fixture.model.hasPendingProfileCleanup)
        XCTAssertNil(fixture.model.profileCleanupBanner)
    }

    /// "Quit is paused…" belongs to the profiles that actually turned the quit
    /// away. Unrelated volatile work arriving later must not inherit the wording —
    /// and the volatile set is deliberately never empty at any publication here,
    /// so an aggregate-emptiness rule cannot pass this.
    func testQuitBlockedWordingIsNotInheritedByUnrelatedVolatileWork() async throws {
        let fixture = try makeFixture(
            // Journalling always fails, so every cancelled sign-in stays VOLATILE —
            // which is the only kind of cleanup that turns a quit away.
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected

        let blockingSession = try fixture.model.beginSignIn(provider: .claude)
        let blockingProfile = try XCTUnwrap(
            fixture.model.signInSession(for: blockingSession)?.webProfileID
        )
        await fixture.model.cancelSignIn(sessionID: blockingSession)

        let canTerminate = await fixture.model.prepareForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertEqual(
            fixture.model.profileCleanupBanner,
            ProfileCleanupCopy.blockingQuit
        )

        // A DIFFERENT profile joins the volatile set after the quit attempt.
        let laterSession = try fixture.model.beginSignIn(provider: .claude)
        let laterProfile = try XCTUnwrap(
            fixture.model.signInSession(for: laterSession)?.webProfileID
        )
        XCTAssertNotEqual(blockingProfile, laterProfile)
        await fixture.model.cancelSignIn(sessionID: laterSession)

        // Now the profile that blocked the quit becomes deletable and the newcomer
        // does not. `onRemoveProfile` runs before the spy's error check, so this
        // decides the outcome per profile.
        fixture.profileManager.onRemoveProfile = { profileID in
            fixture.profileManager.removeError = profileID == laterProfile
                ? TestFailure.expected
                : nil
        }
        await fixture.model.retryProfileCleanup()
        // Break the spy → closure → spy cycle so its `deinit` store cleanup runs.
        fixture.profileManager.onRemoveProfile = nil

        // Volatile went {blocking, later} → {later}: non-empty throughout, but the
        // profile that owned the wording is gone.
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.contains(blockingProfile))
        XCTAssertFalse(fixture.profileManager.removedProfileIDs.contains(laterProfile))
        XCTAssertTrue(fixture.model.hasVolatileProfileCleanup)
        XCTAssertEqual(fixture.model.profileCleanupBanner, ProfileCleanupCopy.pending)
    }

    /// The active-sign-in quit message must retract itself once those sessions
    /// finish. As a written-once `errorMessage` it never did, and could later sit
    /// beside the cleanup row falsely claiming quit was still blocked.
    ///
    /// A COMMITTING session is the only kind that reaches this guard —
    /// `prepareForTermination` cancels ordinary sign-ins before it gets there.
    func testSignInQuitPauseBannerRetractsWhenTheCommitFinishes() async throws {
        let gate = CommitGate()
        let fixture = try makeFixture(
            beforeSignInPersistence: { await gate.suspend() }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        let completion = Task { @MainActor in
            try await fixture.model.completeSignIn(
                sessionID: sessionID,
                label: "Personal"
            )
        }
        await gate.waitUntilStarted()

        let canTerminate = await fixture.model.prepareForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertEqual(
            fixture.model.signInQuitPauseBanner,
            ProfileCleanupCopy.blockingQuitOnSignIn
        )
        // It is NOT an `errorMessage`, so it cannot outlive its cause or collide
        // with an unrelated failure.
        XCTAssertNil(fixture.model.errorMessage)

        gate.resume()
        try await completion.value

        XCTAssertNil(fixture.model.signInQuitPauseBanner)
        let canTerminateAfterCommit = await fixture.model.prepareForTermination()
        XCTAssertTrue(canTerminateAfterCommit)
    }

    /// A journal entry a LOADED account still references is an aborted pre-commit
    /// removal, not an orphan — `skipOrRevokeProfileCleanup` revokes it rather than
    /// deleting it. The indicator must apply that same rule, or startup warns about
    /// a live authenticated session and offers a Retry that must never delete it.
    func testJournalEntryOwnedByALiveAccountIsNotSurfacedAsStuckCleanup() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // On-disk state left by a removal that rolled back but failed to dequeue:
        // a live account whose profile is still journalled for deletion.
        try await fixture.pendingStore.enqueue(account.webProfileID)
        // Abort startup after the queue is read so the publication under test is
        // the early one in `load()`, before `retryProfileCleanup` reconciles.
        try FileManager.default.createDirectory(
            at: fixture.directory.appending(path: "app-settings.json"),
            withIntermediateDirectories: true
        )

        let restored = try makeFixture(directory: fixture.directory)
        defer { restored.removeFiles() }
        await restored.model.start()

        XCTAssertTrue(restored.model.accounts.contains { $0.id == account.id })
        XCTAssertTrue(
            restored.pendingStore.profileIDs.contains(account.webProfileID),
            "the journal entry must survive — only the WARNING is suppressed"
        )
        XCTAssertFalse(restored.model.hasPendingProfileCleanup)
        XCTAssertNil(restored.model.profileCleanupBanner)
    }

    /// `completeSignIn` republishes on EVERY exit. On the exit where the account was
    /// added but the snapshot save AND its rollback both failed, the account stays
    /// live — so a journalled entry for its profile stops being actionable and must
    /// stop being reported, even though this path throws.
    func testCleanupStateIsPublishedOnTheCommitRollbackFailureExit() async throws {
        var accountSaveCount = 0
        let fixture = try makeFixture(
            saveAccounts: { _ in
                accountSaveCount += 1
                // 1 = the add; 2 = the rollback of that add, which must also fail.
                if accountSaveCount == 2 { throw TestFailure.expected }
            },
            saveSnapshots: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let profileID = try XCTUnwrap(
            fixture.model.signInSession(for: sessionID)?.webProfileID
        )

        // A journalled deletion intent for the profile this sign-in is about to
        // commit onto — the shape an interrupted earlier removal leaves behind.
        try await fixture.pendingStore.enqueue(profileID)

        // Account added, snapshot save fails, rollback of the account fails too — so
        // it throws with the account still live.
        do {
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
            XCTFail("Expected the failed rollback to propagate")
        } catch {
            // The specific error is this path's business, not this test's.
        }

        XCTAssertTrue(
            fixture.model.accounts.contains { $0.webProfileID == profileID },
            "the failed rollback must have left the account live"
        )
        XCTAssertTrue(fixture.pendingStore.profileIDs.contains(profileID))
        XCTAssertNil(
            fixture.model.profileCleanupBanner,
            "a live-referenced profile must not be reported, even on a throwing exit"
        )
    }

    /// "Cleanup owns this session" must mean the same thing in
    /// `prepareForTermination` as everywhere else. Judged on raw queue membership, a
    /// reauth session whose profile a live account already references was left
    /// uncancelled — cleanup only revokes such an entry, so the first Quit was
    /// refused for work nobody was doing, and only a second Quit succeeded.
    func testQuitCancelsAReauthSessionWhoseQueuedProfileIsLiveReferenced() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // A stale deletion intent for a LIVE account's profile — what an aborted
        // removal leaves when its dequeue fails.
        try await fixture.pendingStore.enqueue(account.webProfileID)
        _ = try fixture.model.beginReauthentication(accountID: account.id)
        XCTAssertFalse(fixture.model.signInSessions.isEmpty)

        let canTerminate = await fixture.model.prepareForTermination()

        XCTAssertTrue(
            canTerminate,
            "the reauth session is not cleanup's business, so quit must cancel it"
        )
        XCTAssertTrue(fixture.model.signInSessions.isEmpty)
    }

    /// , second half: once a sign-in is past `claimCommit` it is past its last
    /// `requireActive`, so the commit WILL land. A cleanup pass must not delete that
    /// profile's store in the meantime, or the account commits with no cookies — and
    /// no Retry control may be offered for it either.
    func testCleanupDoesNotDeleteAProfileWhoseCommitIsInFlight() async throws {
        let gate = CommitGate()
        let fixture = try makeFixture(
            beforeSignInPersistence: { await gate.suspend() }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let profileID = try XCTUnwrap(
            fixture.model.signInSession(for: sessionID)?.webProfileID
        )

        // A deletion intent already journalled for the profile this sign-in is
        // committing onto — what an earlier interrupted pass leaves behind.
        try await fixture.pendingStore.enqueue(profileID)

        let completion = Task { @MainActor in
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        }
        // `beforeSignInPersistence` runs immediately after `claimCommit`, so the
        // session is registered as committing while the gate holds it.
        await gate.waitUntilStarted()

        // This pass both exercises the deletion guard AND republishes, so the banner
        // assertion below is against freshly derived state rather than a stale nil.
        await fixture.model.retryProfileCleanup()

        XCTAssertTrue(
            fixture.profileManager.removedProfileIDs.isEmpty,
            "cleanup must not delete the store out from under an in-flight commit"
        )
        XCTAssertTrue(
            fixture.pendingStore.profileIDs.contains(profileID),
            "and must leave the intent journalled for after the commit resolves"
        )
        XCTAssertNil(
            fixture.model.profileCleanupBanner,
            "no Retry may be offered for a profile whose commit is in flight"
        )

        gate.resume()
        try await completion.value

        // Committed: the entry is now live-referenced, so it is revoked rather than
        // acted on, and nothing is reported.
        XCTAssertEqual(fixture.model.accounts.first?.webProfileID, profileID)
        XCTAssertNil(fixture.model.profileCleanupBanner)
        await fixture.model.retryProfileCleanup()
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
        XCTAssertFalse(fixture.pendingStore.profileIDs.contains(profileID))
    }

    /// A cancelled sign-in whose cleanup could not finish keeps its session so
    /// cleanup can retry — but it must NEVER commit. Otherwise a provider request
    /// that returns after the cancellation creates the account the user cancelled,
    /// onto a profile that is queued for deletion.
    func testCancelledSignInWhoseCleanupFailedCannotCommit() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        fixture.profileManager.removeError = TestFailure.expected
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        // Journalling and deletion both fail, so the session is deliberately kept
        // for a later cleanup retry (see testQueueFailureStillDeletes...).
        await fixture.model.cancelSignIn(sessionID: sessionID)
        XCTAssertNotNil(fixture.model.signInSession(for: sessionID))

        do {
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
            XCTFail("A cancelled sign-in must not be able to commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(
            fixture.model.accounts.isEmpty,
            "the cancelled sign-in must not have created an account"
        )
    }

    /// Launch purges every live profile's HTTP cache. Nothing did this before, which
    /// is how 355 MB of `NetworkCache` accumulated for five accounts.
    func testLaunchPurgesTheCacheOfEveryLiveProfile() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // Relaunch over the same files.
        let restored = try makeFixture(directory: fixture.directory)
        defer { restored.removeFiles() }
        try await restored.model.load(startBackgroundRefresh: false)

        XCTAssertEqual(restored.profileManager.purgedProfileIDs, [account.webProfileID])
    }

    /// The sweep deletes identified stores nobody owns — the residue a force quit or
    /// crash mid-sign-in leaves, which neither the deletion journal nor the
    /// dedup pass can see.
    func testLaunchSweepsStoresNoAccountOwns() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let orphan = UUID()
        let restored = try makeFixture(directory: fixture.directory)
        defer { restored.removeFiles() }
        restored.profileManager.existingIdentifiers = [account.webProfileID, orphan]

        try await restored.model.load(startBackgroundRefresh: false)

        XCTAssertEqual(
            restored.profileManager.removedProfileIDs,
            [orphan],
            "only the store nobody owns may be deleted"
        )
    }

    /// Every claim on a profile has to stop the sweep, including claims with no
    /// account behind them yet. Deleting the store under an in-progress sign-in, or
    /// one the deletion journal already owns, would be data loss.
    func testSweepSparesEveryClaimedProfile() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let journalled = UUID()
        let restored = try makeFixture(directory: fixture.directory)
        defer { restored.removeFiles() }
        try await restored.pendingStore.enqueue(journalled)
        // Deletion fails for the journalled profile only, so it is STILL journalled
        // when the sweep runs — the state where an unguarded sweep would delete it
        // behind the journal's back, leaving a stale entry.
        restored.profileManager.onRemoveProfile = { [weak spy = restored.profileManager] id in
            spy?.removeError = id == journalled ? TestFailure.expected : nil
        }
        // An in-progress sign-in: a profile with a session but no account.
        let liveSignIn = try restored.model.beginSignIn(provider: .claude)
        let signingInProfile = try XCTUnwrap(
            restored.model.signInSession(for: liveSignIn)?.webProfileID
        )
        let orphan = UUID()
        restored.profileManager.existingIdentifiers = [
            account.webProfileID, journalled, signingInProfile, orphan,
        ]

        try await restored.model.load(startBackgroundRefresh: false)

        restored.profileManager.onRemoveProfile = nil

        XCTAssertEqual(
            restored.profileManager.removedProfileIDs,
            [orphan],
            "only the store nobody claims may be deleted"
        )
        XCTAssertFalse(
            restored.profileManager.removedProfileIDs.contains(signingInProfile),
            "deleting an in-progress sign-in's store would lose the session"
        )
        // The cleanup pass attempted the journalled profile and failed. The sweep
        // must not have tried again behind the journal's back.
        XCTAssertEqual(
            restored.profileManager.attemptedProfileIDs.filter { $0 == journalled }.count,
            1,
            "a journalled profile is the deletion machinery's to drive, not the sweep's"
        )
    }

    /// With no accounts there is no live store to construct, so WebKit stays cold and
    /// the static identifier API would trap. The sweep must simply not run.
    func testHygieneIsSkippedEntirelyWithNoAccounts() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.profileManager.existingIdentifiers = [UUID(), UUID()]

        try await fixture.model.load(startBackgroundRefresh: false)

        XCTAssertTrue(fixture.profileManager.purgedProfileIDs.isEmpty)
        XCTAssertTrue(
            fixture.profileManager.removedProfileIDs.isEmpty,
            "nothing may be deleted on a launch that never warmed WebKit"
        )
    }

    /// The mid-session purge is rate-bounded, and the bound starts at the LAUNCH
    /// purge — otherwise a sleep minutes after launch would purge a cache that was
    /// just cleared, paying a full refetch for nothing.
    func testMidSessionPurgeIsRateBoundedFromTheLaunchPurge() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let fixture = try makeFixture(now: { clock })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let restored = try makeFixture(directory: fixture.directory, now: { clock })
        defer { restored.removeFiles() }
        try await restored.model.load(startBackgroundRefresh: false)
        XCTAssertEqual(restored.profileManager.purgedProfileIDs, [account.webProfileID])

        // Same instant, and any point inside the window: the launch purge holds it.
        await restored.model.purgeIdleCachesIfDue()
        clock = clock.addingTimeInterval(23 * 60 * 60)
        await restored.model.purgeIdleCachesIfDue()
        XCTAssertEqual(
            restored.profileManager.purgedProfileIDs,
            [account.webProfileID],
            "nothing may purge inside the window opened by the launch purge"
        )

        // Past the window: it fires once, and closes the window again.
        clock = clock.addingTimeInterval(2 * 60 * 60)
        await restored.model.purgeIdleCachesIfDue()
        XCTAssertEqual(
            restored.profileManager.purgedProfileIDs,
            [account.webProfileID, account.webProfileID]
        )
        await restored.model.purgeIdleCachesIfDue()
        XCTAssertEqual(
            restored.profileManager.purgedProfileIDs.count,
            2,
            "the window must re-close behind the purge that just ran"
        )
    }

    /// A profile backing in-flight work is skipped, not deferred — the next event
    /// picks it up, and the rate bound means there is no hurry.
    func testMidSessionPurgeSkipsProfilesBackingInFlightWork() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let fixture = try makeFixture(now: { clock })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // An open sign-in session on that account's profile marks it busy.
        _ = try fixture.model.beginReauthentication(accountID: account.id)
        clock = clock.addingTimeInterval(48 * 60 * 60)

        await fixture.model.purgeIdleCachesIfDue()

        XCTAssertTrue(
            fixture.profileManager.purgedProfileIDs.isEmpty,
            "a profile with an open sign-in must not have its cache pulled"
        )
    }

    func testFailedSnapshotAndAccountRollbackKeepsProfileAttached() async throws {
        var accountSaveCount = 0
        let fixture = try makeFixture(
            saveAccounts: { _ in
                accountSaveCount += 1
                if accountSaveCount == 2 {
                    throw TestFailure.expected
                }
            },
            saveSnapshots: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)

        do {
            try await fixture.model.completeSignIn(
                sessionID: sessionID,
                label: "Personal"
            )
            XCTFail("Expected commit rollback to fail")
        } catch {
            XCTAssertTrue(error is AccountCommitError)
        }
        XCTAssertNil(fixture.model.signInSession(for: sessionID))
        do {
            try await fixture.model.completeSignIn(
                sessionID: sessionID,
                label: "Personal"
            )
            XCTFail("Expected the completed session to reject retry")
        } catch {
            XCTAssertEqual(fixture.model.accounts.count, 1)
        }
        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertEqual(fixture.model.accounts.map(\.label), ["Personal"])
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
    }

    func testAccountOperationsAreRejectedDuringRemoval() async throws {
        let saveGate = SecondSnapshotSaveGate()
        let fixture = try makeFixture(
            saveSnapshots: { snapshots in
                await saveGate.save(snapshots)
            }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: sessionID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let removal = Task { @MainActor in
            try await fixture.model.removeAccount(id: account.id)
        }
        await saveGate.waitUntilBlocked()

        do {
            try await fixture.model.renameAccount(id: account.id, label: "Renamed")
            XCTFail("Expected rename to be rejected")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .operationInProgress)
        }
        XCTAssertThrowsError(
            try fixture.model.beginReauthentication(accountID: account.id)
        ) { error in
            XCTAssertEqual(error as? AccountStoreError, .operationInProgress)
        }

        saveGate.resume()
        try await removal.value
    }

    func testReauthenticationReusesExistingSessionForAccount() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let signInID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: signInID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let first = try fixture.model.beginReauthentication(accountID: account.id)
        let second = try fixture.model.beginReauthentication(accountID: account.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(fixture.model.signInSessions.count, 1)
    }

    func testReauthenticationCommitBlocksConcurrentRename() async throws {
        let gate = SecondCommitGate()
        let fixture = try makeFixture(
            beforeSignInPersistence: { await gate.reachCommit() }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let signInID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: signInID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)
        let reauthenticationID = try fixture.model.beginReauthentication(
            accountID: account.id
        )

        let completion = Task { @MainActor in
            try await fixture.model.completeSignIn(
                sessionID: reauthenticationID,
                label: "Personal"
            )
        }
        await gate.waitUntilSecondCommit()

        do {
            try await fixture.model.renameAccount(id: account.id, label: "Renamed")
            XCTFail("Expected rename to be rejected during reauthentication commit")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .operationInProgress)
        }

        gate.resumeSecondCommit()
        try await completion.value
    }

    func testRemovingAccountDeletesSnapshotAndMatchingWebProfile() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: sessionID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)

        fixture.profileManager.onRemoveProfile = { _ in
            XCTAssertTrue(fixture.model.accounts.isEmpty)
            XCTAssertNil(fixture.model.snapshot(for: account.id))
        }
        // The handler captures the fixture, which owns the spy — break the
        // cycle after use or the spy's deinit (store cleanup) never runs.
        defer { fixture.profileManager.onRemoveProfile = nil }

        try await fixture.model.removeAccount(id: account.id)

        XCTAssertTrue(fixture.model.accounts.isEmpty)
        XCTAssertNil(fixture.model.snapshot(for: account.id))
        XCTAssertEqual(
            fixture.profileManager.removedProfileIDs,
            [account.webProfileID]
        )
    }

    func testRemovalDurablyJournalsProfileBeforeDeletingAccountRecord() async throws {
        let removalSaveGate = RemovalAccountSaveGate()
        let fixture = try makeFixture(
            saveAccounts: { accounts in
                await removalSaveGate.save(accounts)
            }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: sessionID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)

        let removal = Task { @MainActor in
            try await fixture.model.removeAccount(id: account.id)
        }
        await removalSaveGate.waitUntilBlocked()

        // The web profile is durably journalled for deletion BEFORE the
        // account record is removed, so a quit/crash in this exact window
        // cannot strand its authenticated cookie store with nothing pointing
        // at it — the next launch's cleanup drains the journal.
        XCTAssertTrue(
            fixture.pendingStore.profileIDs.contains(account.webProfileID)
        )

        removalSaveGate.resume()
        try await removal.value

        // A successful removal drains the journal and deletes the profile.
        XCTAssertTrue(fixture.pendingStore.profileIDs.isEmpty)
        XCTAssertEqual(
            fixture.profileManager.removedProfileIDs,
            [account.webProfileID]
        )
    }

    func testRemovalJournaledProfileIsDeletedOnRelaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        // The on-disk state a crash mid-removal leaves: a profile queued for
        // deletion with no owning account record.
        let orphanProfileID = UUID()
        try await fixture.pendingStore.enqueue(orphanProfileID)

        // Relaunch: a fresh model over the same directory, reusing the profile
        // manager spy so the deletion is observable.
        let restoredPendingStore = PendingProfileDeletionStore(
            fileURL: fixture.directory.appending(
                path: "pending-profile-deletions.json"
            )
        )
        let restoredModel = AppModel(
            accountStore: AccountStore(
                fileURL: fixture.directory.appending(path: "accounts.json")
            ),
            snapshotStore: UsageSnapshotStore(
                fileURL: fixture.directory.appending(path: "snapshots.json")
            ),
            pendingProfileDeletionStore: restoredPendingStore,
            historyStore: UsageHistoryStore(
                rootDirectory: fixture.directory.appending(
                    path: "history", directoryHint: .isDirectory
                )
            ),
            appSettings: AppSettings(
                fileURL: fixture.directory.appending(path: "app-settings.json")
            ),
            alertStateStore: AlertStateStore(
                fileURL: fixture.directory.appending(path: "alert-state.json")
            ),
            profileManager: fixture.profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [fixture.adapter]),
            systemPowerObserver: SystemPowerObserverStub()
        )
        try await restoredModel.load(startBackgroundRefresh: false)

        XCTAssertTrue(restoredPendingStore.profileIDs.isEmpty)
        XCTAssertEqual(
            fixture.profileManager.removedProfileIDs,
            [orphanProfileID]
        )
    }

    func testPowerSignalReleasesIdleWebViewAndRecreatesOnNextUse() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // Signing in warmed (cached) the account's WebView.
        XCTAssertTrue(fixture.powerObserver.started, "observer should start on load")
        XCTAssertTrue(
            fixture.model.cachedWebViewProfileIDsForTesting().contains(account.webProfileID)
        )

        // A sleep / memory-pressure signal releases the idle WebView.
        fixture.powerObserver.fireReleaseSignal()
        XCTAssertFalse(
            fixture.model.cachedWebViewProfileIDsForTesting().contains(account.webProfileID),
            "an idle WebView should be released on the power signal"
        )

        // The cookie store survives, so the next refresh recreates the WebView
        // and fetches successfully with no re-login.
        await fixture.model.refreshAll()
        XCTAssertTrue(
            fixture.model.cachedWebViewProfileIDsForTesting().contains(account.webProfileID),
            "a released WebView should be recreated lazily on next use"
        )
    }

    func testPowerSignalKeepsWebViewDuringSignInCommit() async throws {
        // A power signal firing during the sign-in commit window (session still
        // present, account not yet persisted) must NOT release the session's
        // WebView — it backs the visible sign-in view. Guards against a refactor
        // that removes the session too early (busy coverage).
        let probe = SignInReleaseProbe()
        let fixture = try makeFixture(beforeSignInPersistence: { probe.run() })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        probe.model = fixture.model
        probe.powerObserver = fixture.powerObserver

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        probe.profileID = fixture.model.signInSession(for: sessionID)?.webProfileID
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")

        XCTAssertEqual(
            probe.webViewKeptDuringCommit, true,
            "the sign-in session's WebView must not be released during the commit"
        )
    }

    func testPowerSignalKeepsWebViewOfInFlightRefresh() async throws {
        // Gate the fetch so a refresh stays in flight while the signal fires.
        let fetchGate = VerificationGate()
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        fixture.adapter.fetchGate = fetchGate
        let refresh = Task { @MainActor in await fixture.model.refreshAll() }
        await fetchGate.waitUntilStarted()

        // While the refresh is mid-fetch, a power signal must NOT release its
        // WebView (busy guard).
        fixture.powerObserver.fireReleaseSignal()
        XCTAssertTrue(
            fixture.model.cachedWebViewProfileIDsForTesting().contains(account.webProfileID),
            "a WebView backing an in-flight refresh must not be released"
        )

        fetchGate.resume()
        await refresh.value
    }

    func testLoadJournalsOrphanedProfileFromDroppedDuplicateRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        // A mis-migrated accounts.json: two records share an id, so the second
        // is dropped on load — but it has a DISTINCT webProfileID whose cookie
        // store no live account references.
        let sharedID = UUID()
        let liveProfile = UUID()
        let orphanProfile = UUID()
        let kept = AccountRecord(
            id: sharedID, provider: .claude, label: "Kept",
            webProfileID: liveProfile, displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let dropped = AccountRecord(
            id: sharedID, provider: .claude, label: "Dropped",
            webProfileID: orphanProfile, displayOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let seedStore = JSONFileStore<[AccountRecord]>(
            fileURL: fixture.directory.appending(path: "accounts.json"),
            defaultValue: []
        )
        try await seedStore.save([kept, dropped])

        try await fixture.model.load(startBackgroundRefresh: false)

        // The kept account survives untouched; the dropped record's orphaned
        // profile is journalled and deleted, so no stranded authenticated store
        // is left on disk.
        XCTAssertEqual(fixture.model.accounts.map(\.id), [sharedID])
        XCTAssertEqual(fixture.profileManager.removedProfileIDs, [orphanProfile])
        XCTAssertFalse(
            fixture.profileManager.removedProfileIDs.contains(liveProfile)
        )
    }

    func testLoadPreservesExistingJournalWhenAddingOrphan() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        // A pre-existing deletion entry from an interrupted account removal is
        // already journalled on disk...
        let existingF2Profile = UUID()
        try await fixture.pendingStore.enqueue(existingF2Profile)

        // ...and accounts.json is also mis-migrated: a dropped duplicate record
        // leaves a distinct orphaned profile.
        let sharedID = UUID()
        let liveProfile = UUID()
        let orphanProfile = UUID()
        let seedStore = JSONFileStore<[AccountRecord]>(
            fileURL: fixture.directory.appending(path: "accounts.json"),
            defaultValue: []
        )
        try await seedStore.save([
            AccountRecord(
                id: sharedID, provider: .claude, label: "Kept",
                webProfileID: liveProfile, displayOrder: 0,
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            AccountRecord(
                id: sharedID, provider: .claude, label: "Dropped",
                webProfileID: orphanProfile, displayOrder: 1,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
        ])

        // Fresh model over the same directory.
        let restoredPending = PendingProfileDeletionStore(
            fileURL: fixture.directory.appending(
                path: "pending-profile-deletions.json"
            )
        )
        let restoredModel = AppModel(
            accountStore: AccountStore(
                fileURL: fixture.directory.appending(path: "accounts.json")
            ),
            snapshotStore: UsageSnapshotStore(
                fileURL: fixture.directory.appending(path: "snapshots.json")
            ),
            pendingProfileDeletionStore: restoredPending,
            historyStore: UsageHistoryStore(
                rootDirectory: fixture.directory.appending(
                    path: "history", directoryHint: .isDirectory
                )
            ),
            appSettings: AppSettings(
                fileURL: fixture.directory.appending(path: "app-settings.json")
            ),
            alertStateStore: AlertStateStore(
                fileURL: fixture.directory.appending(path: "alert-state.json")
            ),
            profileManager: fixture.profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [fixture.adapter]),
            systemPowerObserver: SystemPowerObserverStub()
        )
        try await restoredModel.load(startBackgroundRefresh: false)

        // BOTH the pre-existing entry and the newly-discovered orphan are
        // deleted — the orphan enqueue must not overwrite the loaded journal.
        // The live account's profile is untouched.
        XCTAssertEqual(
            Set(fixture.profileManager.removedProfileIDs),
            Set([existingF2Profile, orphanProfile])
        )
        XCTAssertFalse(
            fixture.profileManager.removedProfileIDs.contains(liveProfile)
        )
        XCTAssertTrue(restoredPending.profileIDs.isEmpty)
    }

    func testCleanupRevokesJournalForStillLiveAccountOnRelaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }

        // Reconstruct the on-disk state an interruption AFTER journaling but
        // BEFORE the account-record removal commits would leave: the account is
        // still present in accounts.json AND its profile is journalled for
        // deletion. A naive "delete every journal entry" cleanup would erase a
        // live, authenticated session here.
        let liveAccount = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Live",
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let seedAccounts = AccountStore(
            fileURL: fixture.directory.appending(path: "accounts.json")
        )
        try await seedAccounts.load()
        try await seedAccounts.add(liveAccount)
        let seedPending = PendingProfileDeletionStore(
            fileURL: fixture.directory.appending(
                path: "pending-profile-deletions.json"
            )
        )
        try await seedPending.enqueue(liveAccount.webProfileID)

        // Relaunch.
        let restoredPendingStore = PendingProfileDeletionStore(
            fileURL: fixture.directory.appending(
                path: "pending-profile-deletions.json"
            )
        )
        let restoredModel = AppModel(
            accountStore: AccountStore(
                fileURL: fixture.directory.appending(path: "accounts.json")
            ),
            snapshotStore: UsageSnapshotStore(
                fileURL: fixture.directory.appending(path: "snapshots.json")
            ),
            pendingProfileDeletionStore: restoredPendingStore,
            historyStore: UsageHistoryStore(
                rootDirectory: fixture.directory.appending(
                    path: "history", directoryHint: .isDirectory
                )
            ),
            appSettings: AppSettings(
                fileURL: fixture.directory.appending(path: "app-settings.json")
            ),
            alertStateStore: AlertStateStore(
                fileURL: fixture.directory.appending(path: "alert-state.json")
            ),
            profileManager: fixture.profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: [fixture.adapter]),
            systemPowerObserver: SystemPowerObserverStub()
        )
        try await restoredModel.load(startBackgroundRefresh: false)

        // The live account survives, its profile is NEVER passed to
        // removeProfile, and the stale deletion intent is revoked.
        XCTAssertEqual(restoredModel.accounts.map(\.id), [liveAccount.id])
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
        XCTAssertTrue(restoredPendingStore.profileIDs.isEmpty)
    }

    func testRemovalAbortsIntactWhenJournalingFails() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: sessionID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // Journaling is a hard precondition: if it fails, the
        // removal aborts before any destructive mutation — account, snapshot,
        // and profile all remain intact.
        do {
            try await fixture.model.removeAccount(id: account.id)
            XCTFail("Expected removal to abort when journaling fails")
        } catch {
            XCTAssertEqual(error as? TestFailure, .expected)
        }

        XCTAssertEqual(fixture.model.accounts.map(\.id), [account.id])
        XCTAssertNotNil(fixture.model.snapshot(for: account.id))
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
    }

    func testRemovalPreservesReauthSessionWhenJournalingFails() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let signInID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: signInID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)
        let reauthID = try fixture.model.beginReauthentication(
            accountID: account.id
        )
        XCTAssertNotNil(fixture.model.signInSession(for: reauthID))

        // Journaling is the FIRST thing removal does — before refresh cancel and
        // sign-in/reauth session teardown. When it fails, the
        // removal aborts with the account AND its in-flight reauth session both
        // intact and still usable.
        do {
            try await fixture.model.removeAccount(id: account.id)
            XCTFail("Expected removal to abort when journaling fails")
        } catch {
            XCTAssertEqual(error as? TestFailure, .expected)
        }

        XCTAssertEqual(fixture.model.accounts.map(\.id), [account.id])
        XCTAssertNotNil(fixture.model.signInSession(for: reauthID))
    }

    func testCleanupRechecksLivenessImmediatelyBeforeDeletion() async throws {
        let profileP = UUID()
        let restoredAccount = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Restored",
            webProfileID: profileP,
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let injector = CleanupRaceInjector()
        let fixture = try makeFixture(
            beforeProfileCleanupDeletion: { profileID in
                await injector.inject(profileID)
            }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        // profileP looks like an orphan at cleanup start (no account references
        // it). The injector restores an account referencing it during the
        // interleave point — i.e. AFTER the loop-start check but BEFORE the
        // deletion — simulating a concurrent removal rolling back mid-loop.
        try await fixture.pendingStore.enqueue(profileP)
        injector.configure(
            accountStore: fixture.accountStore,
            account: restoredAccount,
            targetProfileID: profileP
        )

        await fixture.model.retryProfileCleanup()

        // The final fresh re-check must observe the just-restored account and
        // REVOKE the deletion — never erase the live, authenticated profile.
        XCTAssertTrue(fixture.profileManager.removedProfileIDs.isEmpty)
        XCTAssertTrue(fixture.pendingStore.profileIDs.isEmpty)
        XCTAssertTrue(
            fixture.model.accounts.contains { $0.webProfileID == profileP }
        )
    }

    func testCorruptSettingsFailClosedInhibitsWarmUp() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        // Corrupt the settings file on disk before load.
        let settingsURL = fixture.directory.appending(path: "app-settings.json")
        try Data("{ not valid settings json ".utf8).write(to: settingsURL)

        try await fixture.model.load(startBackgroundRefresh: false)

        XCTAssertTrue(fixture.model.settings.loadFailed)

        let account = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Warmable",
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            autoStartFiveHour: true
        )
        // A fresh, unused 5h window (0% used, no reset) is normally eligible.
        let freshWindow = UsageWindow(
            kind: .fiveHour,
            remainingFraction: 1.0,
            resetsAt: nil
        )
        // With settings undecodable, warm-up fails CLOSED (every hour
        // quiet) rather than trusting empty defaults as a user opt-in.
        XCTAssertFalse(
            AutoStartPolicy.shouldAutoStart(
                account: account,
                fiveHour: freshWindow,
                now: Date(timeIntervalSince1970: 1_000),
                schedule: fixture.model.warmUpSchedule
            )
        )

        // Recovery: a successful settings save re-persists valid JSON, clears
        // the flag, and re-permits warm-up.
        try await fixture.model.setQuietHours([])

        XCTAssertFalse(fixture.model.settings.loadFailed)
        XCTAssertTrue(
            AutoStartPolicy.shouldAutoStart(
                account: account,
                fiveHour: freshWindow,
                now: Date(timeIntervalSince1970: 1_000),
                schedule: fixture.model.warmUpSchedule
            )
        )
    }

    func testProfileRemovalFailureRestoresAccountAndSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(
            sessionID: sessionID,
            label: "Personal"
        )
        let account = try XCTUnwrap(fixture.model.accounts.first)
        fixture.profileManager.removeError = TestFailure.expected

        do {
            try await fixture.model.removeAccount(id: account.id)
            XCTFail("Expected profile removal to fail")
        } catch {
            XCTAssertEqual(error as? TestFailure, .expected)
        }

        XCTAssertEqual(fixture.model.accounts.map(\.id), [account.id])
        XCTAssertNotNil(fixture.model.snapshot(for: account.id))
    }

    func testPausedAccountIsNotRefreshed() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let firstSession = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: firstSession, label: "Active")
        let secondSession = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: secondSession, label: "Paused")
        let pausedID = try XCTUnwrap(
            fixture.model.accounts.first(where: { $0.label == "Paused" })?.id
        )

        try await fixture.accountStore.setPaused(id: pausedID, paused: true)
        let fetchesBefore = fixture.adapter.fetchCallCount

        await fixture.model.refreshAll(reason: .manual)

        // Exactly one fetch: the active account. The paused one is dormant.
        XCTAssertEqual(fixture.adapter.fetchCallCount, fetchesBefore + 1)
        // Settings still sees both; the popover boundary sees one.
        XCTAssertEqual(fixture.model.presentations.count, 2)
        XCTAssertEqual(fixture.model.visibleAccounts.map(\.id).count, 1)
    }

    func testResumeTriggersImmediateRefresh() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        try await fixture.model.setPaused(accountID: account.id, paused: true)
        let fetchesWhilePaused = fixture.adapter.fetchCallCount
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(fixture.adapter.fetchCallCount, fetchesWhilePaused, "paused account must not fetch")

        try await fixture.model.setPaused(accountID: account.id, paused: false)
        XCTAssertEqual(fixture.adapter.fetchCallCount, fetchesWhilePaused + 1, "resume must refresh immediately")
        XCTAssertEqual(fixture.model.accounts.first?.isPaused, false)
    }

    /// Wedge regression: a bridge call that times out must not leave the
    /// account's cached web view permanently wedged. Reproduces the real
    /// sequence — sign-in works, a later fetch hangs and bounds out to
    /// `.stale`, and the NEXT refresh recovers by recycling the cached view
    /// and actually re-invoking the evaluator (not silently joining a hung
    /// in-flight task).
    func testHungFetchTimesOutRecyclesWebViewAndNextRefreshFetchesAgain() async throws {
        // Evaluator: resolves normally during sign-in, hangs for every
        // fetch afterwards. Controlled by a MainActor flag.
        final class EvaluatorMode { var hang = false }
        let mode = EvaluatorMode()
        final class EvaluationCounter { var count = 0 }
        let evaluationCounter = EvaluationCounter()
        let client = WebUsageClient(
            evaluator: { script, _, _ in
                evaluationCounter.count += 1
                if mode.hang {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                // Successful shapes for sign-in/verify + fetch: reuse the
                // stub payloads ClaudeProviderAdapterTests uses for a green
                // fetch (resource path + usage envelope).
                return Self.scriptedSuccess(for: script)
            },
            // When the evaluator is not hung, it is
            // the ONLY side of the `bounded` race that can ever resolve —
            // the timeout side must never resolve here, or it could win by
            // scheduling luck instead of the evaluator genuinely winning.
            // When the evaluator IS hung it can never resolve on its own,
            // so resolving the timeout immediately is unconditionally
            // correct. Neither branch depends on Task scheduling order.
            sleep: { _ in
                guard mode.hang else {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return
                }
            }
        )
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let fixture = try makeFixture(adapters: [claudeAdapter])
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        let viewsAfterSignIn = fixture.profileManager.madeProfileIDs.count

        // Explicit first-success refresh: establishes the baseline snapshot
        // the "worked → wedged → recovered" sequence below assumes, so the
        // subsequent hang reads as a regression against a real prior success
        // rather than an untested `completeSignIn` side effect.
        mode.hang = false
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertNotNil(fixture.model.snapshot(for: account.id), "baseline refresh must produce a snapshot")

        // First refresh: hang → bounded timeout → stale, NOT a wedge.
        mode.hang = true
        let evaluationsBeforeHang = evaluationCounter.count
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertGreaterThan(evaluationCounter.count, evaluationsBeforeHang, "first refresh must reach the evaluator")
        // State surfaced through the presentation pipeline:
        let state = try XCTUnwrap(
            fixture.model.presentations.first(where: { $0.account.id == account.id })?.state
        )
        guard case .stale = state else {
            return XCTFail("expected .stale after a timed-out fetch with an existing snapshot, got \(state)")
        }
        // The recycle must actually reap the abandoned bridge call, not just
        // `stopLoading()` (which does not settle a pending script callback —
        // only frame destruction does): the ORIGINAL (sign-in-time) view must
        // have been navigated to about:blank.
        let originalView = try XCTUnwrap(fixture.profileManager.madeWebViews.first)
        XCTAssertTrue(
            originalView.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "timed-out fetch's recycle must navigate the dropped view to about:blank to force-settle its pending callback"
        )

        // Recycle: the cached web view was dropped, so the NEXT refresh
        // must create a fresh one...
        let evaluationsAfterFirst = evaluationCounter.count
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertGreaterThan(
            fixture.profileManager.madeProfileIDs.count,
            viewsAfterSignIn,
            "timed-out fetch must recycle the cached web view (fresh makeWebView on next refresh)"
        )
        // ...and must actually invoke the evaluator again — the pre-fix bug
        // was every later refresh silently joining the hung inFlight task.
        XCTAssertGreaterThan(
            evaluationCounter.count,
            evaluationsAfterFirst,
            "second refresh must fetch again, not join a hung in-flight task"
        )
    }

    /// `recycleWebViewOnTimeout` must evict the
    /// cached view only when it is still the EXACT view the timed-out call
    /// operated on — not whatever happens to be cached under the profile ID
    /// when the catch finally runs. The overlap this guards against (a late
    /// timeout from an abandoned view V1 racing a view V2 a DIFFERENT,
    /// already-completed operation freshly cached) could not be staged
    /// through the public API alone: every current call path sharing a
    /// profile's timeout guard is serialized by an in-flight/busy marker
    /// (`UsageRefreshCoordinator.inFlight`, `sendingKeepAliveAccountIDs`,
    /// `isProfileProtected`) — see `replaceWebViewForTesting`'s doc. This
    /// drives the REAL `fetchUsage` -> `recycleWebViewOnTimeout` path (not a
    /// reimplementation) with a deterministic gate controlling exactly when
    /// the timeout resolves, and substitutes the cache entry — the narrower
    /// seam — in between, to force that exact sequencing without relying on
    /// Task scheduling luck.
    func testLateTimeoutFromAbandonedViewDoesNotEvictAFreshlyCachedView() async throws {
        final class EvaluatorMode { var hang = false }
        let mode = EvaluatorMode()
        let timeoutGate = TimeoutSleepGate()
        let client = WebUsageClient(
            evaluator: { script, _, _ in
                if mode.hang {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                return Self.scriptedSuccess(for: script)
            },
            sleep: { _ in
                // Not hung (sign-in, the final refresh): the evaluator answers
                // and must be the ONLY side that can resolve, so the timeout
                // never does — no reliance on which Task runs first.
                guard mode.hang else {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return
                }
                // Parks here (armed, not yet delivered) until the test
                // explicitly releases it — after the cache swap below.
                await timeoutGate.suspend()
            }
        )
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let fixture = try makeFixture(adapters: [claudeAdapter])
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        let v1 = try XCTUnwrap(fixture.profileManager.madeWebViews.first)
        let madeCountAfterSignIn = fixture.profileManager.madeProfileIDs.count

        // Op A: a fetch that hangs, then times out — but only once the gate
        // below is released. Op A resolves `operatedView` (V1) up front,
        // before it ever suspends.
        mode.hang = true
        let opA = Task { await fixture.model.refreshAll(reason: .manual) }
        await timeoutGate.waitUntilStarted()

        // While Op A's timeout is parked (armed, not yet delivered),
        // simulate a DIFFERENT, already-completed operation having recycled
        // V1 and cached a fresh V2 under the same profile — the exact
        // overlap the identity guard defends against.
        let v2 = RecordingWebView(frame: .zero)
        fixture.model.replaceWebViewForTesting(profileID: account.webProfileID, with: v2)

        // Now let Op A's timeout actually resolve.
        timeoutGate.resume()
        await opA.value

        // V1 — the view Op A actually operated on — still gets its frame
        // teardown, even though it is no longer cached.
        XCTAssertTrue(
            v1.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "the timed-out call's own view must still be torn down even though it is no longer cached"
        )
        // V2 — freshly cached by a DIFFERENT operation — must be left
        // completely alone: no eviction, no teardown.
        XCTAssertFalse(
            v2.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "a freshly cached view must never be torn down by a late timeout attributed to a different, older view"
        )

        // And the cache must still hold V2: the next refresh must reuse it,
        // not mint a fresh view.
        mode.hang = false
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(
            fixture.profileManager.madeProfileIDs.count,
            madeCountAfterSignIn,
            "a late timeout attributed to an old view must not evict a freshly cached one (no new makeWebView call)"
        )
    }

    /// Sign-in protection: an open reauth session shares its account's
    /// web profile AND its live web view (`beginReauthentication` reuses
    /// `account.webProfileID`) with the user's visible login navigation.
    /// Polls skip the account while the session is open, but a refresh that
    /// was ALREADY in flight when the session opened still runs; its timeout
    /// must NOT recycle that view out from under the user — the profile is
    /// "protected" while the session is open.
    func testHungFetchDuringOpenSignInSessionDoesNotRecycleProtectedProfile() async throws {
        final class EvaluatorMode {
            var hang = false
            /// Runs once when an evaluation starts hanging: opens the reauth
            /// session while that refresh is in flight.
            var onHang: (@MainActor () -> Void)?
        }
        let mode = EvaluatorMode()
        final class EvaluationCounter { var count = 0 }
        let evaluationCounter = EvaluationCounter()
        let client = WebUsageClient(
            evaluator: { script, _, _ in
                evaluationCounter.count += 1
                if mode.hang {
                    if let hook = mode.onHang {
                        mode.onHang = nil
                        await hook()
                    }
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                return Self.scriptedSuccess(for: script)
            },
            // See the identical gate in
            // testHungFetchTimesOutRecyclesWebViewAndNextRefreshFetchesAgain —
            // makes the intended winner deterministic instead of relying on
            // Task scheduling order.
            sleep: { _ in
                guard mode.hang else {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return
                }
            }
        )
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let fixture = try makeFixture(adapters: [claudeAdapter])
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        // Explicit first-success refresh: establishes the baseline snapshot,
        // same as the wedge-regression test above.
        mode.hang = false
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertNotNil(fixture.model.snapshot(for: account.id), "baseline refresh must produce a snapshot")

        let viewsBeforeHang = fixture.profileManager.madeProfileIDs.count
        let protectedView = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        // A refresh starts and hangs; while it is in flight a reauth session
        // opens on the SAME account (it reuses `account.webProfileID` and the
        // account's already-cached web view). The refresh bounds out to
        // `.stale` — same as the unprotected case — but must NOT touch the
        // view the open reauth session is using.
        let model = fixture.model
        final class SessionBox { var id: UUID? }
        let reauthBox = SessionBox()
        mode.onHang = {
            reauthBox.id = try? model.beginReauthentication(accountID: account.id)
        }
        mode.hang = true
        await fixture.model.refreshAll(reason: .manual)
        let reauthSessionID = try XCTUnwrap(reauthBox.id, "the reauth session must have opened mid-fetch")
        XCTAssertNotNil(fixture.model.signInSession(for: reauthSessionID), "reauth session must be open")
        let state = try XCTUnwrap(
            fixture.model.presentations.first(where: { $0.account.id == account.id })?.state
        )
        guard case .stale = state else {
            return XCTFail("expected .stale after a timed-out fetch with an existing snapshot, got \(state)")
        }

        // No recycle: the protected view must never have been navigated to
        // about:blank, and nothing minted a fresh view. (A refresh while the
        // session is open skips the account altogether.)
        let evaluationsWhileOpen = evaluationCounter.count
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(evaluationCounter.count, evaluationsWhileOpen, "no poll may run in the sign-in view")
        XCTAssertEqual(
            fixture.profileManager.madeProfileIDs.count,
            viewsBeforeHang,
            "an open sign-in session must protect its profile's web view from a timeout recycle"
        )
        XCTAssertFalse(
            protectedView.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "a protected profile's web view must never be navigated away by a timeout recycle"
        )

        // Closing the protected session must COMPLETE the deferred
        // recycle — the tainted view (still hosting the abandoned bridge
        // call from the earlier timed-out fetch) finally gets its
        // `about:blank` teardown, and the account is no longer stuck on it.
        mode.hang = false
        await fixture.model.cancelSignIn(sessionID: reauthSessionID)
        XCTAssertNil(
            fixture.model.signInSession(for: reauthSessionID),
            "the reauth session must be closed"
        )
        XCTAssertTrue(
            protectedView.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "closing the protected session must complete the deferred recycle (about:blank teardown)"
        )

        // Closing the session refreshes the account once, and that refresh
        // runs on a fresh view, not the torn-down one.
        await fixture.model.flushSignInResumeRefreshes()
        XCTAssertGreaterThan(
            fixture.profileManager.madeProfileIDs.count,
            viewsBeforeHang,
            "closing the protected session must let the next refresh recycle to a fresh view"
        )
    }

    /// A new sign-in whose fetch timed out while its session
    /// protected the profile carries a DEFERRED recycle. Cancelling it with the
    /// deletion journal failing takes `cleanUpNewSignIn`'s enqueue-failure
    /// branch, which drops the cached view in `removeProfile` BEFORE the
    /// deferred recycle completes — the tainted view must still get its
    /// `about:blank` teardown, exactly once.
    func testCancelledNewSignInWithFailedJournalTearsDownItsTimedOutView() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let view = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        fixture.adapter.fetchError = WebUsageClientError.timedOut
        do {
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
            XCTFail("the sign-in fetch was scripted to time out")
        } catch {}
        XCTAssertEqual(view.aboutBlankLoadCount, 0, "the open session protects the view: the recycle is deferred")

        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertNil(fixture.model.signInSession(for: sessionID))
        XCTAssertEqual(
            view.aboutBlankLoadCount, 1,
            "the deferred recycle must tear the tainted view down even though removeProfile dropped it first"
        )
    }

    /// `removeProfile` itself: when the profile deletion
    /// FAILS the session survives for cleanup to retry, so nothing completes
    /// the deferred recycle — the profile is being deleted either way, so
    /// `removeProfile` tears the suspect view down itself. The later
    /// successful retry must not tear it down a second time.
    func testRemoveProfileTearsDownASuspectViewWhileItsSessionSurvives() async throws {
        let fixture = try makeFixture(
            savePendingProfileIDs: { _ in throw TestFailure.expected }
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        let view = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        fixture.adapter.fetchError = WebUsageClientError.timedOut
        do {
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
            XCTFail("the sign-in fetch was scripted to time out")
        } catch {}

        fixture.profileManager.removeError = TestFailure.expected
        await fixture.model.cancelSignIn(sessionID: sessionID)

        XCTAssertNotNil(fixture.model.signInSession(for: sessionID), "the session survives a failed deletion")
        XCTAssertEqual(view.aboutBlankLoadCount, 1, "removeProfile must tear down the suspect view it drops")

        fixture.profileManager.removeError = nil
        await fixture.model.retryProfileCleanup()

        XCTAssertNil(fixture.model.signInSession(for: sessionID))
        XCTAssertEqual(view.aboutBlankLoadCount, 1, "a view is torn down once, not again on the retry")
    }

    /// Identity: the deferred recycle remembers the exact
    /// tainted view. If the cache holds a DIFFERENT view by the time the
    /// protecting session closes, the tainted one is torn down and the cached
    /// one is left alone (still cached, never navigated away).
    func testDeferredRecycleTearsDownTheTaintedViewNotTheCachedOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        let tainted = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        // The reauth completion's own fetch times out while its session
        // protects the profile (polls skip the account meanwhile).
        let reauthSessionID = try fixture.model.beginReauthentication(accountID: account.id)
        fixture.adapter.fetchError = WebUsageClientError.timedOut
        do {
            try await fixture.model.completeSignIn(sessionID: reauthSessionID, label: "Personal")
            XCTFail("the reauth fetch was scripted to time out")
        } catch {}
        XCTAssertEqual(tainted.aboutBlankLoadCount, 0, "protected: deferred, not torn down")

        let fresh = RecordingWebView(frame: .zero)
        fixture.model.replaceWebViewForTesting(profileID: account.webProfileID, with: fresh)

        fixture.adapter.fetchError = nil
        await fixture.model.cancelSignIn(sessionID: reauthSessionID)
        await fixture.model.flushSignInResumeRefreshes()

        XCTAssertEqual(tainted.aboutBlankLoadCount, 1, "the exact tainted view must be torn down")
        XCTAssertEqual(fresh.aboutBlankLoadCount, 0, "a view that never timed out must not be torn down")

        let madeBefore = fixture.profileManager.madeProfileIDs.count
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(
            fixture.profileManager.madeProfileIDs.count, madeBefore,
            "the healthy cached view must stay cached"
        )
    }

    /// A teardown that the web view never acts on (a
    /// persistently wedged WebContent process) abandons that view; each one is
    /// counted so field accumulation is visible.
    func testIgnoredTeardownCountsAnAbandonedWebView() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 0)

        fixture.adapter.fetchError = WebUsageClientError.timedOut
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushTeardownChecks()
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 1)

        // The recycle made a fresh view; it wedges too.
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushTeardownChecks()
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 2, "each abandoned view counts")
    }

    /// One wedged view reached by two teardown
    /// paths — the deferred recycle when the reauth session closes, then the
    /// late timeout of a poll that was retrying on it meanwhile — is torn down
    /// once and counted once.
    func testOverlappingTeardownsOfOneViewTearDownAndCountOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        let view = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        // A poll on the cached view hangs; it started BEFORE the reauth
        // session opened (polls skip an account whose session is open)...
        let fetchGate = VerificationGate()
        fixture.adapter.fetchGate = fetchGate
        let retry = Task { await fixture.model.refreshAll(reason: .manual) }
        await fetchGate.waitUntilStarted()
        fixture.adapter.fetchGate = nil

        // ...the reauth session opens and its own fetch times out while the
        // session protects the profile: deferred...
        let reauthSessionID = try fixture.model.beginReauthentication(accountID: account.id)
        fixture.adapter.fetchError = WebUsageClientError.timedOut
        do {
            try await fixture.model.completeSignIn(sessionID: reauthSessionID, label: "Personal")
            XCTFail("the reauth fetch was scripted to time out")
        } catch {}
        XCTAssertEqual(view.aboutBlankLoadCount, 0)
        // The fresh refresh that follows the close (after the hung poll
        // settles) is healthy: only the one wedged view is under test.
        fixture.adapter.onFetch = { _ in
            fixture.adapter.fetchError = nil
        }

        // ...the session closes (deferred teardown)...
        await fixture.model.cancelSignIn(sessionID: reauthSessionID)
        XCTAssertEqual(view.aboutBlankLoadCount, 1)

        // ...then the hung poll's timeout lands on the same view.
        fetchGate.resume()
        await retry.value
        await fixture.model.flushSignInResumeRefreshes()
        await fixture.model.flushTeardownChecks()

        XCTAssertEqual(view.aboutBlankLoadCount, 1, "one view is torn down once")
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 1, "one wedged view is counted once")
    }

    /// The other side: a teardown that finished is not an
    /// abandoned view.
    func testCompletedTeardownIsNotCountedAsAbandoned() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.profileManager.madeViewsReportLoadsFinished = true
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let view = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        fixture.adapter.fetchError = WebUsageClientError.timedOut
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushTeardownChecks()

        XCTAssertEqual(view.aboutBlankLoadCount, 1, "the recycle must have torn the view down")
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 0)
    }

    /// The check runs only after the grace period: a teardown still in
    /// progress is not judged early.
    func testTeardownIsJudgedOnlyAfterTheGracePeriod() async throws {
        let grace = VerificationGate()
        let fixture = try makeFixture(teardownGrace: { await grace.suspend() })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")

        fixture.adapter.fetchError = WebUsageClientError.timedOut
        await fixture.model.refreshAll(reason: .manual)
        // Bounded rather than `waitUntilStarted()`: a check that skips the
        // grace period must FAIL this test, not hang it.
        for _ in 0..<1_000 where !grace.hasStarted {
            await Task.yield()
        }
        XCTAssertTrue(grace.hasStarted, "the check must wait out the grace period")
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 0, "not judged before the grace period ends")

        grace.resume()
        await fixture.model.flushTeardownChecks()
        XCTAssertEqual(fixture.model.abandonedWebViewCount, 1)
    }

    /// The predicate the check relies on, against a REAL `WKWebView`: after
    /// an `about:blank` load finishes it reads as completed; before any load
    /// it does not.
    func testRealWebViewReadsAsTornDownOnceAboutBlankFinishes() async throws {
        let webView = WKWebView(frame: .zero)
        XCTAssertFalse(WebViewTeardown.hasCompleted(webView))
        WebViewTeardown.begin(webView)
        // Issued but not finished: WebKit already reports the requested URL,
        // so only the finished load counts.
        XCTAssertEqual(webView.url, WebViewTeardown.blankURL)
        XCTAssertTrue(webView.isLoading)
        XCTAssertFalse(WebViewTeardown.hasCompleted(webView))
        let deadline = Date().addingTimeInterval(10)
        while !WebViewTeardown.hasCompleted(webView), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(WebViewTeardown.hasCompleted(webView), "a healthy web view finishes about:blank")
    }

    /// Keep-alive bound: the auto-start "keep-alive" send (a `postJSON`
    /// call driven from `handleAutoStart` -> `AccountSessionManager.sendKeepAlive`
    /// -> `ClaudeMessageSender.send` -> `createConversation`) hits the exact
    /// same `bounded` race and `recycleWebViewOnTimeout` machinery as a hung
    /// fetch (Tasks 1-3) — but through a DIFFERENT call chain than
    /// `fetchUsage`. This pins that guarantee independently: a hung keep-alive
    /// send bounds out, surfaces the auto-start failure banner, still leaves
    /// the triggering snapshot saved, recycles the shared cached web view (the
    /// account's fetch and keep-alive send share ONE cached view per profile),
    /// and does not wedge the NEXT refresh's fetch.
    func testHungKeepAliveSendIsBoundedAndDoesNotWedgeRefresh() async throws {
        final class EvaluatorMode { var hangPosts = false }
        let mode = EvaluatorMode()
        final class EvaluationCounter { var total = 0; var posts = 0 }
        let counter = EvaluationCounter()
        let respond: @MainActor (String, [String: Any]) async -> Any? = { script, arguments in
            counter.total += 1
            // Distinctive substring of `WebUsageClient.postScript`'s actual
            // source (`method: "POST",`) — the only one of the three
            // scripts this test's Claude-only path can evaluate
            // (postScript / fetchScript / resourcePathsScript) that
            // contains it, so it uniquely identifies the keep-alive send.
            if script.contains("method: \"POST\"") {
                counter.posts += 1
                if mode.hangPosts {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                return ["status": 200, "retryAfter": NSNull(), "body": ""]
            }
            if script.contains("getEntriesByType") {
                return Self.scriptedSuccess(for: script)
            }
            // `fetchScript` is shared by the usage read (`ClaudeProviderAdapter
            // .fetchUsage`) AND the auto-start model-discovery read
            // (`ClaudeMessageSender.discoverModel`) — same script body, so
            // disambiguate by the `path` argument instead.
            let path = arguments["path"] as? String ?? ""
            if path.contains("chat_conversations") {
                return [
                    "status": 200,
                    "retryAfter": NSNull(),
                    "body": #"[{"model":"claude-test-model","uuid":"abc"}]"#
                ]
            }
            // Usage envelope: a fresh, unused 5h window (remainingFraction 1,
            // no scheduled reset) — the "not started" state that fires
            // auto-start (mirrors how `scriptedSuccess` encodes windows,
            // with utilization dropped to 0 instead of 5 so it actually
            // arms `AutoStartPolicy.shouldAutoStart`'s `>= 0.99` check).
            return [
                "status": 200,
                "retryAfter": NSNull(),
                "body": """
                {
                  "five_hour": { "utilization": 0, "resets_at": null },
                  "seven_day": { "utilization": 53, "resets_at": null }
                }
                """
            ]
        }
        // Two clients, as in production (`ClaudeMessageSender()` owns its
        // own). The usage client (fetch + background plan read) never hangs
        // here, so its timeout never resolves: the answer always wins.
        let client = WebUsageClient(
            evaluator: { script, arguments, _ in await respond(script, arguments) },
            sleep: { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        )
        // The sender's races run one at a time (prepare, then the two POSTs),
        // so the gate pairs each timeout with its own evaluation and resolves
        // it only for the hung POST — the other sender reads can only be won
        // by their answers, whatever order the race's two tasks run in.
        let senderGate = ScriptAwareTimeoutGate()
        let senderClient = WebUsageClient(
            evaluator: { script, arguments, _ in
                senderGate.evaluationStarted(
                    hangs: mode.hangPosts && script.contains("method: \"POST\"")
                )
                return await respond(script, arguments)
            },
            sleep: { _ in await senderGate.sleep() }
        )
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let messageSender = ClaudeMessageSender(client: senderClient)
        let fixture = try makeFixture(adapters: [claudeAdapter], messageSender: messageSender)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setAutoStart(accountID: account.id, enabled: true)

        let viewsBeforeHang = fixture.profileManager.madeProfileIDs.count
        let originalView = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        // Only the keep-alive POST hangs; fetch/resource-path scripts stay green.
        mode.hangPosts = true
        await fixture.model.refreshAll(reason: .manual)

        // Non-vacuousness: the hang must actually have been reached, or every
        // assertion below would pass trivially without exercising the bound.
        XCTAssertGreaterThan(
            counter.posts, 0,
            "the keep-alive POST must actually be attempted for this test to be meaningful"
        )
        // The refresh COMPLETED (we are past the await) — that alone is the
        // wedge assertion. Pin the failure surfacing too:
        XCTAssertNotNil(fixture.model.snapshot(for: account.id), "snapshot from the fetch must be saved")
        XCTAssertEqual(
            fixture.model.warmUpBanner?.severity,
            .critical,
            "the auto-start failure banner must surface"
        )
        // The keep-alive send shares its account's ONE cached web view with
        // `fetchUsage` — the timed-out send's recycle must have force-settled
        // the original view via `about:blank` (see the `RecordingWebView`
        // doc: `stopLoading()` alone does not settle a pending callback).
        XCTAssertTrue(
            originalView.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "the hung keep-alive send's recycle must navigate the dropped view to about:blank"
        )

        // And the account is not wedged: a second refresh recreates the
        // recycled view and actually fetches again, rather than joining a
        // hung in-flight task.
        let evaluationsBeforeSecond = counter.total
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertGreaterThan(
            fixture.profileManager.madeProfileIDs.count, viewsBeforeHang,
            "a hung keep-alive send must recycle the shared web view so the next refresh gets a fresh one"
        )
        XCTAssertGreaterThan(
            counter.total, evaluationsBeforeSecond,
            "subsequent refresh must fetch again, not join a hung in-flight task"
        )
    }

    /// Counts warm-up SENDS seen by `makeWarmUpSendClient`'s evaluator. A
    /// keep-alive send is two raw POSTs (`ClaudeMessageSender.send`:
    /// `createConversation` then `postCompletion`) — only the `.../completion`
    /// one is the actual message send, so that is what "one send" counts.
    private final class WarmUpSendCounter {
        var sends = 0
        /// Every POST (conversation create AND completion) that reached the page.
        var posts = 0
        /// Runs inside the evaluator for each POST while it is in flight —
        /// lets a test flip the switch mid-send. Synchronous on purpose: the
        /// stub clients' zero `sleep` makes any suspension here lose the
        /// `bounded` race and read as a timeout.
        var onPost: (@MainActor (String) -> Void)?
    }

    /// Same script-routing evaluator as
    /// `testHungKeepAliveSendIsBoundedAndDoesNotWedgeRefresh`, but the POST
    /// always succeeds immediately — this exercises the on-by-default FIRST
    /// send, not the timeout/recycle machinery.
    private func makeWarmUpSendClient(counter: WarmUpSendCounter) -> WebUsageClient {
        WebUsageClient(
            evaluator: { script, arguments, _ in
                if script.contains("method: \"POST\"") {
                    let path = arguments["path"] as? String ?? ""
                    counter.posts += 1
                    if path.hasSuffix("/completion") {
                        counter.sends += 1
                    }
                    counter.onPost?(path)
                    return ["status": 200, "retryAfter": NSNull(), "body": ""]
                }
                if script.contains("getEntriesByType") {
                    return Self.scriptedSuccess(for: script)
                }
                let path = arguments["path"] as? String ?? ""
                if path.contains("chat_conversations") {
                    return [
                        "status": 200,
                        "retryAfter": NSNull(),
                        "body": #"[{"model":"claude-test-model","uuid":"abc"}]"#
                    ]
                }
                // A fresh, unused 5h window (utilization 0, no scheduled reset)
                // — the "not started" state that arms
                // `AutoStartPolicy.shouldAutoStart`.
                return [
                    "status": 200,
                    "retryAfter": NSNull(),
                    "body": """
                    {
                      "five_hour": { "utilization": 0, "resets_at": null },
                      "seven_day": { "utilization": 53, "resets_at": null }
                    }
                    """
                ]
            },
            sleep: { _ in }
        )
    }

    /// A newly added Claude account gets `autoStartFiveHour = true` for
    /// free — no explicit `setAutoStart` call — and its first eligible
    /// refresh sends exactly one warm-up keep-alive.
    func testNewClaudeAccountSendsWarmUpOnFirstEligibleRefresh() async throws {
        let counter = WarmUpSendCounter()
        let client = makeWarmUpSendClient(counter: counter)
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let messageSender = ClaudeMessageSender(client: client)
        let fixture = try makeFixture(adapters: [claudeAdapter], messageSender: messageSender)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        // No explicit enable: a NEW Claude account is warm-up-eligible by
        // default.
        XCTAssertTrue(try XCTUnwrap(fixture.model.accounts.first).autoStartFiveHour)

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(
            counter.sends, 1,
            "the first eligible refresh on a newly added Claude account must send exactly one warm-up keep-alive"
        )
    }

    /// Same on-by-default account, but quiet hours cover `now`: the
    /// first-send must not fire — quiet hours are checked before any
    /// window reasoning (`AutoStartPolicy.windowSaysFire`).
    func testNewClaudeAccountDoesNotSendWarmUpDuringQuietHours() async throws {
        let counter = WarmUpSendCounter()
        let client = makeWarmUpSendClient(counter: counter)
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let messageSender = ClaudeMessageSender(client: client)
        let fixture = try makeFixture(adapters: [claudeAdapter], messageSender: messageSender)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        // The fixture's default clock (`now: Date(timeIntervalSince1970: 1_000)`),
        // expressed as the quiet cell `AutoStartPolicy` will check against
        // (same `.autoupdatingCurrent` calendar production uses) — covering
        // it blocks the send regardless of the machine's time zone.
        let now = Date(timeIntervalSince1970: 1_000)
        let calendar = Calendar.autoupdatingCurrent
        let quietCell = WarmUpQuietSchedule.cellIndex(
            weekday: calendar.component(.weekday, from: now),
            hour: calendar.component(.hour, from: now)
        )
        try await fixture.model.setQuietHours([quietCell])

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(
            counter.sends, 0,
            "quiet hours covering `now` must suppress the first send too"
        )
    }

    /// The global Claude warm-up switch off: no send, the account's own
    /// Auto-start choice untouched; back on, the next refresh sends.
    func testWarmUpSwitchOffSendsNothingAndKeepsTheAccountChoice() async throws {
        let counter = WarmUpSendCounter()
        let client = makeWarmUpSendClient(counter: counter)
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let messageSender = ClaudeMessageSender(client: client)
        let fixture = try makeFixture(adapters: [claudeAdapter], messageSender: messageSender)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        try await fixture.model.setFeature(.warmUp, enabled: false)

        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(counter.sends, 0, "warm-up off: no account warms up")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertTrue(account.autoStartFiveHour, "the per-account choice is kept")
        XCTAssertNil(account.lastAutoStartedAt, "nothing was reserved")
        XCTAssertNil(fixture.model.warmUpBanner)

        try await fixture.model.setFeature(.warmUp, enabled: true)
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(counter.sends, 1, "back on: the next eligible refresh sends")
    }

    // MARK: - The plan read runs apart from usage

    /// Claude's plan read hangs on a refresh: usage still lands, and the
    /// read's timeout reaches the recycle path (the view is torn down) instead
    /// of being swallowed; the stored plan is left alone.
    func testHungPlanReadDoesNotBlockUsageAndRecyclesTheView() async throws {
        final class Mode { var hangList = false; var clock = Date(timeIntervalSince1970: 1_000) }
        let mode = Mode()
        let organizationID = UUID().uuidString.lowercased()
        let client = WebUsageClient(
            evaluator: { script, arguments, _ in
                if script.contains("lastActiveOrg") { return organizationID }
                if arguments["path"] as? String == "/api/organizations" {
                    if mode.hangList {
                        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    }
                    return [
                        "status": 200, "retryAfter": NSNull(),
                        "body": #"[{"uuid":"\#(organizationID)","capabilities":["chat"],"rate_limit_tier":"default_claude_max_5x"}]"#
                    ]
                }
                return [
                    "status": 200, "retryAfter": NSNull(),
                    "body": #"{"five_hour":{"utilization":5,"resets_at":null},"seven_day":{"utilization":53,"resets_at":null}}"#
                ]
            },
            sleep: { _ in }
        )
        let adapter = ClaudeProviderAdapter(
            client: client,
            now: { mode.clock },
            prepareWebView: { _ in },
            organizationResolver: ClaudeOrganizationResolver(client: client, now: { mode.clock })
        )
        let fixture = try makeFixture(adapters: [adapter], now: { mode.clock })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertEqual(account.plan, .claudeMax5x, "sign-in waits for the plan read")

        mode.clock = mode.clock.addingTimeInterval(ClaudeOrganizationResolver.planCacheLifetime + 1)
        mode.hangList = true
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(
            fixture.model.snapshot(for: account.id)?.fetchedAt, mode.clock,
            "usage landed despite the hung plan read"
        )
        await fixture.model.flushPlanRefreshes()

        let view = try XCTUnwrap(fixture.profileManager.madeWebViews.first)
        XCTAssertTrue(
            view.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "the plan read's timeout recycles the view"
        )
        XCTAssertEqual(fixture.model.accounts.first?.plan, .claudeMax5x, "a timeout is not a new reading")
    }

    // MARK: - Late plan reads

    /// A Claude client whose organizations list can be HELD (then released
    /// as a timeout or as a Max 20x list) and whose active org can switch.
    @MainActor private final class PlanReadMode {
        var clock = Date(timeIntervalSince1970: 1_000)
        var org = UUID().uuidString.lowercased()
        var holdList = false
        var held: CheckedContinuation<Bool, Never>?
        var heldSignal: CheckedContinuation<Void, Never>?
        var usageFetches = 0

        func waitUntilHeld() async {
            if held != nil { return }
            await withCheckedContinuation { heldSignal = $0 }
        }

        /// `timeout`: the held read ends as a bridge timeout; else it answers.
        func release(timeout: Bool) {
            held?.resume(returning: timeout)
            held = nil
        }
    }

    private func makePlanReadFixture(_ mode: PlanReadMode) async throws -> (Fixture, AccountRecord) {
        let client = WebUsageClient(
            evaluator: { script, arguments, _ in
                if script.contains("lastActiveOrg") { return mode.org }
                let path = arguments["path"] as? String ?? ""
                if path == "/api/organizations" {
                    let listedOrg = mode.org
                    if mode.holdList {
                        mode.holdList = false
                        let timeout = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                            mode.held = continuation
                            mode.heldSignal?.resume()
                            mode.heldSignal = nil
                        }
                        if timeout { throw WebUsageClientError.timedOut }
                        return [
                            "status": 200, "retryAfter": NSNull(),
                            "body": #"[{"uuid":"\#(listedOrg)","capabilities":["chat"],"rate_limit_tier":"default_claude_max_20x"}]"#
                        ]
                    }
                    return [
                        "status": 200, "retryAfter": NSNull(),
                        "body": #"[{"uuid":"\#(listedOrg)","capabilities":["chat"],"rate_limit_tier":"default_claude_max_5x"}]"#
                    ]
                }
                mode.usageFetches += 1
                return [
                    "status": 200, "retryAfter": NSNull(),
                    "body": #"{"five_hour":{"utilization":5,"resets_at":null},"seven_day":{"utilization":53,"resets_at":null}}"#
                ]
            },
            sleep: { _ in try await Task.sleep(for: .seconds(600)) }
        )
        let adapter = ClaudeProviderAdapter(
            client: client,
            now: { mode.clock },
            prepareWebView: { _ in },
            organizationResolver: ClaudeOrganizationResolver(client: client, now: { mode.clock })
        )
        let fixture = try makeFixture(adapters: [adapter], now: { mode.clock })
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertEqual(account.plan, .claudeMax5x, "premise: sign-in read the plan")
        return (fixture, account)
    }

    /// A plan read that times out AFTER a newer usage refresh started on the
    /// same view must not tear that view down: usage stays fresh.
    func testLatePlanTimeoutDoesNotRecycleAViewANewerRefreshIsUsing() async throws {
        let mode = PlanReadMode()
        let (fixture, account) = try await makePlanReadFixture(mode)
        defer { fixture.removeFiles() }
        let view = try XCTUnwrap(fixture.profileManager.madeWebViews.first)

        mode.clock = mode.clock.addingTimeInterval(ClaudeOrganizationResolver.planCacheLifetime + 1)
        mode.holdList = true
        await fixture.model.refreshAll(reason: .manual)
        await mode.waitUntilHeld()

        mode.clock = mode.clock.addingTimeInterval(60)
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(fixture.model.snapshot(for: account.id)?.fetchedAt, mode.clock, "the newer refresh succeeded")

        mode.release(timeout: true)
        await fixture.model.flushPlanRefreshes()

        XCTAssertFalse(
            view.loadedRequests.contains { $0.url?.absoluteString == "about:blank" },
            "the view the newer refresh used is not torn down"
        )
        let viewsBefore = fixture.profileManager.madeProfileIDs.count
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(fixture.profileManager.madeProfileIDs.count, viewsBefore, "the cached view is still in use")
        let state = fixture.model.presentations.first { $0.account.id == account.id }?.state
        XCTAssertEqual(state, .current, "usage is fresh")
    }

    /// A plan read for org A that lands after the account moved to org B is
    /// dropped: it describes a workspace the account no longer reads.
    func testLatePlanReadForAPreviousOrgIsDropped() async throws {
        let mode = PlanReadMode()
        let (fixture, account) = try await makePlanReadFixture(mode)
        defer { fixture.removeFiles() }

        mode.clock = mode.clock.addingTimeInterval(ClaudeOrganizationResolver.planCacheLifetime + 1)
        mode.holdList = true
        await fixture.model.refreshAll(reason: .manual)
        await mode.waitUntilHeld()

        // Workspace switch: the next refresh reads org B.
        let orgA = mode.org
        mode.org = UUID().uuidString.lowercased()
        mode.clock = mode.clock.addingTimeInterval(60)
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertNotEqual(fixture.model.snapshot(for: account.id)?.organizationID, orgA, "premise")

        mode.release(timeout: false)   // org A's list answers Max 20x
        await fixture.model.flushPlanRefreshes()

        XCTAssertEqual(fixture.model.accounts.first?.plan, .claudeMax5x, "org A's late reading is not applied")
        XCTAssertNotEqual(fixture.model.latestPlanDetectionForTesting(accountID: account.id), .tier(.claudeMax20x))
    }

    /// Control: the same late reading IS applied when the org is unchanged.
    func testLatePlanReadForTheCurrentOrgIsApplied() async throws {
        let mode = PlanReadMode()
        let (fixture, _) = try await makePlanReadFixture(mode)
        defer { fixture.removeFiles() }

        mode.clock = mode.clock.addingTimeInterval(ClaudeOrganizationResolver.planCacheLifetime + 1)
        mode.holdList = true
        await fixture.model.refreshAll(reason: .manual)
        await mode.waitUntilHeld()
        mode.release(timeout: false)
        await fixture.model.flushPlanRefreshes()

        XCTAssertEqual(fixture.model.accounts.first?.plan, .claudeMax20x)
    }

    #if DEBUG
    /// Even the DEBUG manual send honours the global warm-up switch.
    func testDebugSendRespectsTheWarmUpSwitch() async throws {
        let counter = WarmUpSendCounter()
        let client = makeWarmUpSendClient(counter: counter)
        let fixture = try makeFixture(
            adapters: [ClaudeProviderAdapter(client: client, prepareWebView: { _ in })],
            messageSender: ClaudeMessageSender(client: client)
        )
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        try await fixture.model.setFeature(.warmUp, enabled: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)

        await fixture.model.debugSendKeepAlive(accountID: account.id)
        XCTAssertEqual(counter.posts, 0)
    }
    #endif

    // MARK: - The warm-up switch turned off mid-attempt

    /// Builds a warm-up-ready fixture whose RESERVATION save can be held
    /// (the account save that first carries `lastAutoStartedAt`).
    private func makeHeldReservationFixture(
        counter: WarmUpSendCounter,
        reservation: WarmUpHold,
        settingsSave: WarmUpHold? = nil
    ) async throws -> Fixture {
        let client = makeWarmUpSendClient(counter: counter)
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let fixture = try makeFixture(
            saveAccounts: { accounts in
                if accounts.contains(where: { $0.lastAutoStartedAt != nil }) {
                    await reservation.pass()
                }
            },
            adapters: [claudeAdapter],
            messageSender: ClaudeMessageSender(client: client),
            saveSettings: { _ in await settingsSave?.pass() }
        )
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        XCTAssertEqual(counter.posts, 0, "precondition: nothing sent during sign-in")
        return fixture
    }

    /// The attempt passed every check and is suspended in `reserveAutoStart`
    /// when the user turns warm-up off: nothing may be sent.
    func testWarmUpSwitchOffWhileReservationIsSuspendedSendsNothing() async throws {
        let counter = WarmUpSendCounter()
        let reservation = WarmUpHold()
        let fixture = try await makeHeldReservationFixture(counter: counter, reservation: reservation)
        defer { fixture.removeFiles() }

        reservation.arm()
        let refresh = Task { await fixture.model.refreshAll(reason: .manual) }
        await reservation.waitUntilHeld()
        try await fixture.model.setFeature(.warmUp, enabled: false)
        reservation.release()
        await refresh.value

        XCTAssertEqual(counter.posts, 0, "switched off mid-reservation: no POST at all")
        XCTAssertNil(fixture.model.warmUpBanner, "a vetoed attempt is not a failure")
    }

    /// OFF then ON again while the reservation is suspended: the switch reads
    /// on, but the attempt predates the "no" and must not send.
    func testWarmUpSwitchOffThenOnWhileReservationIsSuspendedSendsNothing() async throws {
        let counter = WarmUpSendCounter()
        let reservation = WarmUpHold()
        let fixture = try await makeHeldReservationFixture(counter: counter, reservation: reservation)
        defer { fixture.removeFiles() }

        reservation.arm()
        let refresh = Task { await fixture.model.refreshAll(reason: .manual) }
        await reservation.waitUntilHeld()
        try await fixture.model.setFeature(.warmUp, enabled: false)
        try await fixture.model.setFeature(.warmUp, enabled: true)
        reservation.release()
        await refresh.value

        XCTAssertEqual(counter.posts, 0, "an attempt older than the switch-off never sends")
    }

    /// The switch-off is still SAVING (not yet published) when the attempt
    /// reaches its commit point: the intent alone must stop it.
    func testWarmUpSwitchOffStillSavingBlocksTheSend() async throws {
        let counter = WarmUpSendCounter()
        let reservation = WarmUpHold()
        let settingsSave = WarmUpHold()
        let fixture = try await makeHeldReservationFixture(
            counter: counter,
            reservation: reservation,
            settingsSave: settingsSave
        )
        defer { fixture.removeFiles() }

        settingsSave.arm()
        let disable = Task { try await fixture.model.setFeature(.warmUp, enabled: false) }
        await settingsSave.waitUntilHeld()
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(counter.posts, 0, "a disable in flight already blocks new attempts")

        settingsSave.release()
        try await disable.value
    }

    /// The switch goes off while the conversation-create POST is in flight:
    /// the completion POST (the actual message) must not follow.
    func testWarmUpSwitchOffDuringConversationCreateSkipsTheCompletion() async throws {
        let counter = WarmUpSendCounter()
        let reservation = WarmUpHold()
        let fixture = try await makeHeldReservationFixture(counter: counter, reservation: reservation)
        defer { fixture.removeFiles() }
        XCTAssertNil(
            try XCTUnwrap(fixture.model.accounts.first).keepAliveConversationID,
            "precondition: no stored conversation, so a create POST runs first"
        )
        let model = fixture.model
        // The switch-off is requested while the create POST is in flight;
        // its synchronous part runs before the create's result is handed back.
        counter.onPost = { path in
            if path.hasSuffix("/chat_conversations") {
                Task { try? await model.setFeature(.warmUp, enabled: false) }
            }
        }

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(counter.posts, 1, "only the create POST was already under way")
        XCTAssertEqual(counter.sends, 0, "no completion after the switch-off")
        XCTAssertTrue(fixture.model.autoStartFailures.isEmpty, "a veto is not a failure")
    }

    /// Sanity for the stress runs: with the switch left on, the held
    /// reservation still ends in exactly one message.
    func testWarmUpHeldReservationStillSendsWhenSwitchStaysOn() async throws {
        let counter = WarmUpSendCounter()
        let reservation = WarmUpHold()
        let fixture = try await makeHeldReservationFixture(counter: counter, reservation: reservation)
        defer { fixture.removeFiles() }

        reservation.arm()
        let refresh = Task { await fixture.model.refreshAll(reason: .manual) }
        await reservation.waitUntilHeld()
        reservation.release()
        await refresh.value

        XCTAssertEqual(counter.sends, 1)
    }

    /// Per-script green-path stub payloads, copied from
    /// `ClaudeProviderAdapterTests.testFetchAcceptsRecognizedWindowsWithoutScheduledResets`.
    /// `WebUsageClient`'s resource-path and fetch scripts are `private`, so
    /// they can't be referenced directly even under `@testable import` —
    /// distinguish them by a substring unique to each script's body instead.
    private static let scriptedOrganizationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private static func scriptedSuccess(for script: String) -> Any? {
        if script.contains("getEntriesByType") {
            // resourcePathsScript: resource-path listing used for org-ID discovery.
            return ["/api/organizations/\(scriptedOrganizationID.uuidString)/usage"]
        }
        // fetchScript: the usage envelope.
        return [
            "status": 200,
            "retryAfter": NSNull(),
            "body": """
            {
              "five_hour": { "utilization": 5, "resets_at": null },
              "seven_day": { "utilization": 53, "resets_at": null }
            }
            """
        ]
    }

    // MARK: No refresh while a sign-in window is open

    /// A reauth session drives the account's OWN cached web view, and every
    /// provider's fetch preparation navigates that view. A manual refresh, a
    /// popover-open refresh and the background timer must all leave the
    /// account alone while the session is open — and still refresh the
    /// others.
    func testRefreshSkipsAnAccountWhileItsReauthSessionIsOpen() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let reauthed = try await signInAccount(fixture, label: "Personal")
        let other = try await signInAccount(fixture, label: "Work")

        _ = try fixture.model.beginReauthentication(accountID: reauthed.id)
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.refreshAll(reason: .timer)
        await fixture.model.refreshWhenOpened()

        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertFalse(fetched.contains(reauthed.id), "no fetch may navigate the sign-in view")
        XCTAssertTrue(fetched.contains(other.id), "other accounts keep refreshing")
        XCTAssertEqual(
            fixture.model.backgroundRefreshAccountIDsForTesting(),
            [other.id],
            "the background timer polls only the accounts without a sign-in window"
        )
    }

    /// Skipping is not a failure: the account keeps its snapshot and state,
    /// so the header does not count it as a problem for having been skipped.
    func testSkippingDuringSignInRecordsNoFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let account = try await signInAccount(fixture, label: "Personal")
        await fixture.model.refreshAll(reason: .manual)
        XCTAssertEqual(presentationState(fixture, account.id), .current)
        let snapshotBefore = fixture.model.snapshot(for: account.id)

        _ = try fixture.model.beginReauthentication(accountID: account.id)
        // Every fetch would fail now — a skip must not reach it.
        fixture.adapter.fetchError = ProviderError.offline
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.refreshAll(reason: .timer)

        XCTAssertEqual(presentationState(fixture, account.id), .current)
        XCTAssertEqual(fixture.model.snapshot(for: account.id), snapshotBefore)
    }

    /// Cancelling the reauth window brings the account back with one prompt
    /// refresh, and it is polled normally again afterwards.
    func testCancellingAReauthSessionRefreshesTheAccountOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let account = try await signInAccount(fixture, label: "Personal")
        let sessionID = try fixture.model.beginReauthentication(accountID: account.id)
        await fixture.model.refreshAll(reason: .timer)
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        await fixture.model.cancelSignIn(sessionID: sessionID)
        await fixture.model.flushSignInResumeRefreshes()

        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertEqual(fetched, [account.id], "exactly one refresh once the window closes")
        XCTAssertEqual(fixture.model.backgroundRefreshAccountIDsForTesting(), [account.id])
    }

    /// The sign-in completion is the session's OWN use of the view: verify
    /// runs on the session's web view and its fetch still happens, while
    /// polls around it stay away.
    func testReauthCompletionStillVerifiesOnTheSessionView() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let account = try await signInAccount(fixture, label: "Personal")
        let sessionID = try fixture.model.beginReauthentication(accountID: account.id)
        let sessionView = try XCTUnwrap(fixture.model.signInSession(for: sessionID)?.webView)
        await fixture.model.refreshAll(reason: .timer)
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")

        XCTAssertTrue(fixture.adapter.verifiedWebViews.last === sessionView)
        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertEqual(fetched, [account.id], "the completion's own fetch still runs")
        XCTAssertEqual(presentationState(fixture, account.id), .current)
        XCTAssertEqual(fixture.model.backgroundRefreshAccountIDsForTesting(), [account.id])
    }

    /// A refresh already QUEUED when the window opens (the list was built
    /// before it) is dropped at dispatch: no fetch, no state written.
    func testQueuedRefreshIsDroppedAtDispatchWhenASignInOpens() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let first = try await signInAccount(fixture, label: "Personal")
        let second = try await signInAccount(fixture, label: "Work")
        let model = fixture.model
        fixture.adapter.onFetch = { accountID in
            guard accountID == first.id else { return }
            fixture.adapter.onFetch = nil
            _ = try? model.beginReauthentication(accountID: second.id)
        }
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        await fixture.model.refreshAll(reason: .manual)

        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertEqual(fetched, [first.id], "the queued refresh for the signing-in account must not fetch")
        XCTAssertEqual(fixture.model.signInSessions.count, 1, "the hook must have opened the session")
        XCTAssertEqual(presentationState(fixture, second.id), .current, "a dropped refresh writes no state")
    }

    /// A fetch that started BEFORE the window opened is still running when
    /// the window is cancelled: the account gets one FRESH fetch after it
    /// settles, not just the tail of the old one.
    func testCancelRefreshesAfreshOnceTheOlderFetchSettles() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let account = try await signInAccount(fixture, label: "Personal")
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        let gate = VerificationGate()
        fixture.adapter.fetchGate = gate
        let olderRefresh = Task { await fixture.model.refreshAll(reason: .manual) }
        await gate.waitUntilStarted()
        fixture.adapter.fetchGate = nil

        let sessionID = try fixture.model.beginReauthentication(accountID: account.id)
        await fixture.model.cancelSignIn(sessionID: sessionID)
        // Let the resume refresh reach its wait on the older fetch.
        for _ in 0..<50 { await Task.yield() }
        gate.resume()
        await olderRefresh.value
        await fixture.model.flushSignInResumeRefreshes()

        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertEqual(fetched, [account.id, account.id], "the older fetch, then exactly one fresh one")
    }

    /// A real tick of the background timer, through the coordinator's own
    /// loop: the account with an open window never reaches the adapter.
    /// Dispatch suppression is switched off here so the test pins the
    /// timer's account supplier by itself.
    func testBackgroundTimerTickSkipsAnAccountWithAnOpenSignIn() async throws {
        let ticker = TickSleep()
        let fixture = try makeFixture(refreshSleep: { try await ticker.sleep($0) })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let reauthed = try await signInAccount(fixture, label: "Personal")
        let other = try await signInAccount(fixture, label: "Work")
        _ = try fixture.model.beginReauthentication(accountID: reauthed.id)
        fixture.model.disableDispatchSuppressionForTesting()
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        fixture.model.startBackgroundPollingForTesting()
        // The tick's refresh has finished once the loop asks to sleep again.
        for _ in 0..<500 where ticker.callCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.model.stop()

        XCTAssertGreaterThanOrEqual(ticker.callCount, 2, "the timer must have ticked once")
        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertEqual(fetched, [other.id], "the tick fetches only the account without a window")
    }

    /// The popover path: a queued refresh whose account opened a window
    /// must not even take `shouldSkipRefresh`'s "recent snapshot" shortcut,
    /// which writes `.current` — the account's state stays untouched.
    func testQueuedPopoverRefreshLeavesASuppressedAccountsStateAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let first = try await signInAccount(fixture, label: "Personal")
        let second = try await signInAccount(fixture, label: "Work")
        // Both stale, both with a snapshot young enough for the popover
        // shortcut (the fixture clock never moves).
        fixture.adapter.fetchError = ProviderError.offline
        await fixture.model.refreshAll(reason: .manual)
        fixture.adapter.fetchError = nil
        guard case .stale = presentationState(fixture, second.id) else {
            return XCTFail("setup: the second account must be stale")
        }

        // The first account's shortcut publishes its `.current` synchronously;
        // open the second account's window right then, while its refresh is
        // queued behind.
        let model = fixture.model
        var opened = false
        let subscription = fixture.model.$presentations.sink { presentations in
            guard
                !opened,
                presentations.first(where: { $0.account.id == first.id })?.state == .current
            else { return }
            opened = true
            _ = try? model.beginReauthentication(accountID: second.id)
        }
        defer { subscription.cancel() }

        await fixture.model.refreshWhenOpened()

        XCTAssertTrue(opened, "the window must have opened while the refresh was queued")
        XCTAssertEqual(presentationState(fixture, first.id), .current, "the unsuppressed account took the shortcut")
        guard case .stale = presentationState(fixture, second.id) else {
            return XCTFail("a suppressed account's state must not change, got \(String(describing: presentationState(fixture, second.id)))")
        }
    }

    /// A timer refresh that STARTED after the window closed (here, before the
    /// resume task got to run) already is the promised fresh fetch: exactly
    /// one fetch, not two.
    func testARefreshStartedAfterCloseSatisfiesTheResumeRefresh() async throws {
        final class Box {
            var model: AppModel?
            var adapter: ProviderAdapterSpy?
            var timerRefresh: Task<Void, Never>?
        }
        let box = Box()
        let gate = VerificationGate()
        let fixture = try makeFixture(beforeSignInResumeRefresh: {
            // The timer fetch starts and is held in flight.
            guard let model = box.model, let adapter = box.adapter else { return }
            adapter.fetchGate = gate
            box.timerRefresh = Task { await model.refreshAll(reason: .timer) }
            await gate.waitUntilStarted()
            adapter.fetchGate = nil
        })
        defer { fixture.removeFiles() }
        box.model = fixture.model
        box.adapter = fixture.adapter
        try await fixture.model.load(startBackgroundRefresh: false)
        let account = try await signInAccount(fixture, label: "Personal")
        let sessionID = try fixture.model.beginReauthentication(accountID: account.id)
        let fetchesBefore = fixture.adapter.fetchedAccountIDs.count

        await fixture.model.cancelSignIn(sessionID: sessionID)
        await gate.waitUntilStarted()
        gate.resume()
        await fixture.model.flushSignInResumeRefreshes()
        await box.timerRefresh?.value

        let fetched = Array(fixture.adapter.fetchedAccountIDs.dropFirst(fetchesBefore))
        XCTAssertEqual(fetched, [account.id], "one fresh fetch after the close, not two")
    }

    private func signInAccount(_ fixture: Fixture, label: String) async throws -> AccountRecord {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: label)
        return try XCTUnwrap(fixture.model.accounts.last)
    }

    private func presentationState(_ fixture: Fixture, _ accountID: UUID) -> AccountViewState? {
        fixture.model.presentations.first { $0.account.id == accountID }?.state
    }

    private func makeFixture(
        saveAccounts: AccountStore.SaveAccounts? = nil,
        saveSnapshots: UsageSnapshotStore.SaveSnapshots? = nil,
        savePendingProfileIDs: PendingProfileDeletionStore.SaveProfileIDs? = nil,
        beforeSignInPersistence: @escaping @MainActor () async -> Void = {},
        beforeProfileCleanupDeletion: @escaping @MainActor (UUID) async -> Void = { _ in },
        beforeSignInResumeRefresh: @escaping @MainActor () async -> Void = {},
        adapters: [any ProviderAdapter]? = nil,
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        // Pass an existing directory to build a SECOND model over the same files,
        // i.e. to exercise what a relaunch sees on disk.
        directory: URL? = nil,
        // A movable clock, for the rate-bounded cache purge.
        now: (@MainActor () -> Date)? = nil,
        saveSettings: AppSettings.SaveSettings? = nil,
        // No grace by default: a teardown is checked as soon as it is issued.
        teardownGrace: @escaping @MainActor () async -> Void = {},
        refreshSleep: @escaping UsageRefreshCoordinator.Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) throws -> Fixture {
        let directory = directory
            ?? FileManager.default.temporaryDirectory
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
            fileURL: directory.appending(path: "snapshots.json"),
            saveSnapshots: saveSnapshots
        )
        let pendingStore = PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending-profile-deletions.json"),
            saveProfileIDs: savePendingProfileIDs
        )
        let historyStore = UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)
        )
        let appSettings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: saveSettings
        )
        let alertStateStore = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json")
        )
        let profileManager = WebProfileManagerSpy()
        let adapter = ProviderAdapterSpy()
        let powerObserver = SystemPowerObserverStub()
        let model = AppModel(
            accountStore: accounts,
            snapshotStore: snapshots,
            pendingProfileDeletionStore: pendingStore,
            historyStore: historyStore,
            appSettings: appSettings,
            alertStateStore: alertStateStore,
            profileManager: profileManager,
            adapterRegistry: ProviderAdapterRegistry(adapters: adapters ?? [adapter]),
            messageSender: messageSender,
            now: now ?? { Date(timeIntervalSince1970: 1_000) },
            beforeSignInPersistence: beforeSignInPersistence,
            beforeSignInResumeRefresh: beforeSignInResumeRefresh,
            beforeProfileCleanupDeletion: beforeProfileCleanupDeletion,
            systemPowerObserver: powerObserver,
            refreshSleep: refreshSleep,
            teardownGrace: teardownGrace
        )
        return Fixture(
            directory: directory,
            model: model,
            accountStore: accounts,
            pendingStore: pendingStore,
            profileManager: profileManager,
            adapter: adapter,
            powerObserver: powerObserver
        )
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let model: AppModel
    let accountStore: AccountStore
    let pendingStore: PendingProfileDeletionStore
    let profileManager: WebProfileManagerSpy
    let adapter: ProviderAdapterSpy
    let powerObserver: SystemPowerObserverStub

    nonisolated func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Fires a power-release signal at the sign-in commit interleave point (via
/// `beforeSignInPersistence`) and records whether the session's WebView
/// survived — proving the sign-in session keeps its profile busy.
@MainActor
private final class SignInReleaseProbe {
    var model: AppModel?
    var powerObserver: SystemPowerObserverStub?
    var profileID: UUID?
    private(set) var webViewKeptDuringCommit: Bool?

    func run() {
        guard let model, let powerObserver, let profileID else { return }
        powerObserver.fireReleaseSignal()
        webViewKeptDuringCommit =
            model.cachedWebViewProfileIDsForTesting().contains(profileID)
    }
}

/// The coordinator's injected sleep: the first call returns at once (one
/// timer tick), every later one parks until cancelled.
private final class TickSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func sleep(_ duration: Duration) async throws {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { return }
        try await Task.sleep(for: .seconds(3_600))
    }
}

@MainActor
private final class SystemPowerObserverStub: SystemPowerObserving {
    var onShouldReleaseIdleResources: (@MainActor () -> Void)?
    var isLowPowerModeEnabled = false
    private(set) var started = false

    func start() { started = true }
    func stop() {}

    /// Simulate a system sleep / memory-pressure signal.
    func fireReleaseSignal() { onShouldReleaseIdleResources?() }
}

/// Wedge-regression: records every `load(_:)` call so a test can prove
/// the timeout recycle's `about:blank` navigation actually reached the
/// dropped view — `stopLoading()` alone does NOT settle a pending script
/// callback, only tearing down the frame (via a real navigation) does.
@MainActor
private final class RecordingWebView: WKWebView {
    private(set) var loadedRequests: [URLRequest] = []
    private let stableConfiguration: WKWebViewConfiguration

    /// `WKWebView.configuration` normally returns a fresh COPY — and copies
    /// of an EPHEMERAL data store do not converge on one cookie jar the way
    /// production's identified stores do. Returning the original makes the
    /// spy behave like production for `webView.configuration.websiteDataStore`
    /// access paths.
    override var configuration: WKWebViewConfiguration { stableConfiguration }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        stableConfiguration = configuration
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Records WITHOUT navigating: every assertion against this spy is about
    /// what the code under test ASKED to load, and a real request from a unit
    /// test (chatgpt.com, claude.ai) would be nondeterministic — a live site
    /// can even clear a test-planted session cookie via its logged-out
    /// response's Set-Cookie.
    @discardableResult
    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        return nil
    }

    /// Off by default: the spy never navigates, so a teardown looks IGNORED
    /// (still no `about:blank` URL) — the wedged-WebContent case. On, it
    /// reports its last requested load as finished, like a healthy process.
    var reportsLoadsFinished = false

    override var url: URL? {
        reportsLoadsFinished ? loadedRequests.last?.url : super.url
    }

    override var isLoading: Bool {
        reportsLoadsFinished ? false : super.isLoading
    }

    var aboutBlankLoadCount: Int {
        loadedRequests.filter { $0.url?.absoluteString == "about:blank" }.count
    }
}

@MainActor
private final class WebProfileManagerSpy: WebProfileManaging {
    private(set) var attemptedProfileIDs: [UUID] = []
    private(set) var removedProfileIDs: [UUID] = []
    /// Wedge-regression test: every `makeWebView` call, in order —
    /// proves a timed-out fetch recycled the cached view (a fresh entry
    /// appears here on the next refresh instead of the same view being reused).
    private(set) var madeProfileIDs: [UUID] = []
    /// Parallel to `madeProfileIDs` — the concrete `RecordingWebView` handed
    /// back for each `makeWebView` call, so a test can inspect what was
    /// later (not) loaded into a specific, already-cached view.
    private(set) var madeWebViews: [RecordingWebView] = []
    /// Applied to every view made from now on: see
    /// `RecordingWebView.reportsLoadsFinished`.
    var madeViewsReportLoadsFinished = false
    var onRemoveProfile: ((UUID) -> Void)?
    var removeError: Error?
    private(set) var purgedProfileIDs: [UUID] = []
    /// What WebKit "knows about" for the orphan sweep. Empty by default so no
    /// existing test starts sweeping.
    var existingIdentifiers: [UUID] = []

    func makeWebView(profileID: UUID) -> WKWebView {
        madeProfileIDs.append(profileID)
        // Production-shaped IDENTIFIED store per view: ephemeral stores do
        // not reliably round-trip cookies while attached to a web view on
        // this OS, and the identified topology is what the app actually
        // runs. `cleanUpStores()` best-effort removes them from disk.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileID)
        let webView = RecordingWebView(frame: .zero, configuration: configuration)
        webView.reportsLoadsFinished = madeViewsReportLoadsFinished
        madeWebViews.append(webView)
        return webView
    }

    /// Best-effort disk cleanup of the identified stores this spy created.
    func cleanUpStores() {
        let identifiers = madeProfileIDs
        madeWebViews.removeAll()
        Self.scheduleStoreRemoval(identifiers)
    }

    /// Every fixture's stores are cleaned up automatically when the spy dies
    /// at test end — repeated runs must not accumulate orphaned WebKit
    /// stores on disk.
    deinit {
        Self.scheduleStoreRemoval(madeProfileIDs)
    }

    private nonisolated static func scheduleStoreRemoval(_ identifiers: [UUID]) {
        guard !identifiers.isEmpty else { return }
        Task { @MainActor in
            for identifier in identifiers {
                try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
            }
        }
    }

    func removeProfile(profileID: UUID) async throws {
        attemptedProfileIDs.append(profileID)
        onRemoveProfile?(profileID)
        if let removeError {
            throw removeError
        }
        removedProfileIDs.append(profileID)
    }

    func purgeDiskCache(profileID: UUID) async {
        purgedProfileIDs.append(profileID)
    }

    func existingProfileIdentifiers() async -> [UUID] {
        existingIdentifiers
    }
}

private enum TestFailure: Error, Equatable {
    case expected
}

@MainActor
private final class ChatGPTAdapterStub: ProviderAdapter {
    let provider = Provider.chatGPT
    let signInURL = URL(string: "https://chatgpt.com/")!
    /// Test interleave hooks: run INSIDE the respective suspension windows.
    var onVerify: (@MainActor () async -> Void)?
    var onFetch: (@MainActor () async -> Void)?
    func verifySession(in webView: WKWebView) async throws {
        await onVerify?()
    }
    func fetchUsage(accountID: UUID, in webView: WKWebView) async throws -> UsageSnapshot {
        await onFetch?()
        return UsageSnapshot(accountID: accountID, fetchedAt: Date(timeIntervalSince1970: 1_000), fiveHour: nil, weekly: nil)
    }
}

private final class ProviderAdapterSpy: ProviderAdapter {
    let provider = Provider.claude
    let signInURL = URL(string: "https://claude.ai/")!
    private(set) var verifyCallCount = 0
    private(set) var fetchCallCount = 0
    /// Every fetch's account, in order — so a test can tell WHICH account a
    /// refresh reached, not just that one did.
    private(set) var fetchedAccountIDs: [UUID] = []
    /// The web view each `verifySession` ran in.
    private(set) var verifiedWebViews: [WKWebView] = []
    /// Runs at the start of every fetch with the fetched account's id.
    var onFetch: (@MainActor (UUID) -> Void)?
    var verificationGate: VerificationGate?
    var fetchGate: VerificationGate?
    /// Thrown by every `fetchUsage` while set — e.g. `WebUsageClientError
    /// .timedOut`, which the session manager's recycle path acts on.
    var fetchError: (any Error)?

    func verifySession(in webView: WKWebView) async throws {
        verifyCallCount += 1
        verifiedWebViews.append(webView)
        if let verificationGate {
            await verificationGate.suspend()
        }
    }

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        fetchCallCount += 1
        fetchedAccountIDs.append(accountID)
        onFetch?(accountID)
        if let fetchGate {
            await fetchGate.suspend()
        }
        if let fetchError {
            throw fetchError
        }
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: nil,
            weekly: nil
        )
    }
}

/// Parks `WebUsageClient`'s injected `sleep` at the point it would
/// otherwise deliver `.timedOut`, so a test can deterministically control
/// exactly when a timeout resolves relative to other actions — instead of
/// relying on Task scheduling order.
/// Holds the next armed pass until released (one-shot per `arm()`).
@MainActor
private final class WarmUpHold {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldSignal: CheckedContinuation<Void, Never>?
    private var isHeld = false

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        armed = false
        isHeld = true
        await withCheckedContinuation { continuation in
            held = continuation
            heldSignal?.resume()
            heldSignal = nil
        }
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldSignal = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
private final class TimeoutSleepGate {
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

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// Makes one `WebUsageClient`'s bridge race deterministic when only SOME of
/// its evaluations hang. The n-th `sleep` (the timeout side of the n-th race)
/// is paired with the n-th evaluation — valid because that client's races run
/// one at a time — and resolves only if that evaluation hangs. A race whose
/// evaluation answers can then only be won by the answer, in whichever order
/// its two tasks happen to be scheduled.
@MainActor
private final class ScriptAwareTimeoutGate {
    /// Per evaluation, in order: does it hang?
    private var hangs: [Bool] = []
    private var sleeps = 0
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]

    func evaluationStarted(hangs willHang: Bool) {
        let index = hangs.count
        hangs.append(willHang)
        if willHang, let sleeper = parked.removeValue(forKey: index) {
            sleeper.resume()
        }
    }

    func sleep() async {
        let index = sleeps
        sleeps += 1
        if index < hangs.count, hangs[index] { return }
        // Undecided: wait for the evaluation's verdict. Answered: park for
        // good — the answer has already won.
        await withCheckedContinuation { parked[index] = $0 }
    }
}

@MainActor
private final class VerificationGate {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    var hasStarted: Bool { didStart }

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

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CommitGate {
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

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SecondSnapshotSaveGate {
    private var saveCount = 0
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ snapshots: [UUID: UsageSnapshot]) async {
        saveCount += 1
        guard saveCount == 2 else { return }
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        guard saveCount < 2 else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SecondCommitGate {
    private var commitCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func reachCommit() async {
        commitCount += 1
        guard commitCount == 2 else { return }
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSecondCommit() async {
        guard commitCount < 2 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeSecondCommit() {
        continuation?.resume()
        continuation = nil
    }
}

/// Restores an account referencing a target profile at the cleanup interleave
/// point, exactly once, to simulate a concurrent account-removal rollback
/// landing mid-`retryProfileCleanup` — proving the final liveness re-check
/// revokes rather than deletes the now-live profile.
@MainActor
private final class CleanupRaceInjector {
    private var accountStore: AccountStore?
    private var account: AccountRecord?
    private var targetProfileID: UUID?
    private var didInject = false

    func configure(
        accountStore: AccountStore,
        account: AccountRecord,
        targetProfileID: UUID
    ) {
        self.accountStore = accountStore
        self.account = account
        self.targetProfileID = targetProfileID
    }

    func inject(_ profileID: UUID) async {
        guard
            !didInject,
            profileID == targetProfileID,
            let accountStore,
            let account
        else {
            return
        }
        didInject = true
        try? await accountStore.restore(account, at: 0)
    }
}

/// Gates the SECOND `saveAccounts` call. Call is the account add during
/// `completeSignIn`; call is the removal's persist of the filtered list —
/// blocking there lets a test inspect state (e.g. the pending-deletion journal)
/// at the precise moment the account record is about to disappear.
@MainActor
private final class RemovalAccountSaveGate {
    private var saveCount = 0
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ accounts: [AccountRecord]) async {
        saveCount += 1
        guard saveCount == 2 else { return }
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        guard saveCount < 2 else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Warm-up outcomes

/// How the stubbed completion POST answers in `makeOutcomeClient`.
@MainActor
private final class CompletionScript {
    enum Answer {
        case status(Int, streamError: String? = nil)
        case transportFailure
    }
    var answer: Answer = .status(200)
    /// The model-discovery GET's status (a 403 here is a PRE-reservation auth
    /// failure).
    var discoveryStatus = 200
    /// Weekly utilization reported by the usage read (100 = spent).
    var weeklyUtilization = 53
    var completions = 0
}

private struct CompletionScriptFailure: Error {}

@MainActor
private final class MovableClock {
    var date = Date(timeIntervalSince1970: 1_000)
}

extension AppModelTests {
    /// Same routing as `makeWarmUpSendClient`, with the completion POST's
    /// answer scripted. Never touches a network: every script is stubbed.
    private func makeOutcomeClient(_ script: CompletionScript) -> WebUsageClient {
        WebUsageClient(
            evaluator: { source, arguments, _ in
                let path = arguments["path"] as? String ?? ""
                if source.contains("method: \"POST\"") {
                    guard path.hasSuffix("/completion") else {
                        return ["status": 200, "retryAfter": NSNull(), "body": ""]
                    }
                    script.completions += 1
                    switch script.answer {
                    case let .status(status, streamError):
                        let stream: Any = streamError ?? NSNull()
                        return [
                            "status": status,
                            "retryAfter": NSNull(),
                            "body": "",
                            "streamError": stream
                        ]
                    case .transportFailure:
                        throw CompletionScriptFailure()
                    }
                }
                if source.contains("getEntriesByType") {
                    return Self.scriptedSuccess(for: source)
                }
                if path.contains("chat_conversations") {
                    return [
                        "status": script.discoveryStatus,
                        "retryAfter": NSNull(),
                        "body": #"[{"model":"claude-test-model","uuid":"abc"}]"#
                    ]
                }
                return [
                    "status": 200,
                    "retryAfter": NSNull(),
                    "body": """
                    {
                      "five_hour": { "utilization": 0, "resets_at": null },
                      "seven_day": { "utilization": \(script.weeklyUtilization), "resets_at": null }
                    }
                    """
                ]
            },
            sleep: { _ in }
        )
    }

    /// A signed-in Claude account (warm-up on by default) over `directory`.
    private func makeOutcomeFixture(
        _ script: CompletionScript,
        clock: MovableClock = MovableClock(),
        directory: URL? = nil
    ) async throws -> Fixture {
        let client = makeOutcomeClient(script)
        let claudeAdapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let fixture = try makeFixture(
            adapters: [claudeAdapter],
            messageSender: ClaudeMessageSender(client: client),
            directory: directory,
            now: { clock.date }
        )
        try await fixture.model.load(startBackgroundRefresh: false)
        if fixture.model.accounts.isEmpty {
            let sessionID = try fixture.model.beginSignIn(provider: .claude)
            try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        }
        return fixture
    }

    private func outcomes(_ fixture: Fixture) throws -> [WarmUpOutcome] {
        try XCTUnwrap(fixture.model.accounts.first).warmUpOutcomes
    }

    func testWarmUpOutcomeRecordsASentKeepAliveWithItsStatus() async throws {
        let script = CompletionScript()
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(try outcomes(fixture), [
            WarmUpOutcome(
                at: Date(timeIntervalSince1970: 1_000),
                kind: .sent,
                httpStatus: 200,
                reserved: true
            )
        ])
    }

    func testWarmUpOutcomeRecordsARejectedCompletionWithItsStatus() async throws {
        let script = CompletionScript()
        script.answer = .status(429)
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        let outcome = try XCTUnwrap(try outcomes(fixture).last)
        XCTAssertEqual(outcome.kind, .rejected)
        XCTAssertEqual(outcome.httpStatus, 429)
        XCTAssertEqual(outcome.errorKind, .http)
        XCTAssertTrue(outcome.reserved, "a refused completion has already spent the reservation")
    }

    func testWarmUpOutcomeRecordsAnAuthRejectionOfTheCompletion() async throws {
        let script = CompletionScript()
        script.answer = .status(401)
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        let outcome = try XCTUnwrap(try outcomes(fixture).last)
        XCTAssertEqual(outcome.kind, .rejected)
        XCTAssertEqual(outcome.httpStatus, 401)
        XCTAssertEqual(outcome.errorKind, .authentication)
        XCTAssertTrue(outcome.reserved)
    }

    func testWarmUpOutcomeRecordsAnAuthFailureBeforeTheReservation() async throws {
        let script = CompletionScript()
        script.discoveryStatus = 403
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        let outcome = try XCTUnwrap(try outcomes(fixture).last)
        XCTAssertEqual(outcome.kind, .rejected)
        XCTAssertEqual(outcome.httpStatus, 403)
        XCTAssertEqual(outcome.errorKind, .authentication)
        XCTAssertFalse(outcome.reserved, "model discovery fails before anything is reserved")
        XCTAssertEqual(script.completions, 0)
    }

    func testWarmUpOutcomeRecordsATransportFailure() async throws {
        let script = CompletionScript()
        script.answer = .transportFailure
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        let outcome = try XCTUnwrap(try outcomes(fixture).last)
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.errorKind, .transport)
        XCTAssertNil(outcome.httpStatus)
        XCTAssertTrue(outcome.reserved)
    }

    /// A refusal inside a 2xx stream did not start the window: the popover
    /// and the Settings list both say so, nothing records a started window,
    /// and the reservation stands as for any other refused send.
    func testAnErrorCarriedInsideA200StreamIsARefusalOnEverySurface() async throws {
        let script = CompletionScript()
        script.answer = .status(200, streamError: "rate_limit_error")
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        let account = try XCTUnwrap(fixture.model.accounts.first)
        let outcome = try XCTUnwrap(account.warmUpOutcomes.last)
        XCTAssertEqual(outcome.kind, .rejectedInStream)
        XCTAssertEqual(outcome.httpStatus, 200)
        XCTAssertEqual(outcome.errorKind, .stream)
        XCTAssertEqual(outcome.streamErrorType, .rateLimit)
        XCTAssertTrue(outcome.reserved)
        // Popover: a failure, not a started window.
        XCTAssertEqual(fixture.model.autoStartFailures[account.id]?.kind, .transient)
        XCTAssertEqual(fixture.model.warmUpBanner?.severity, .critical)
        // No successful auto-start recorded: the reservation (commit time)
        // stands, and no conversation is kept as if the send had worked.
        XCTAssertEqual(account.lastAutoStartedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(account.keepAliveConversationID)
        // Settings says the same thing.
        let line = WarmUpOutcomeCopy.what(outcome, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(line, "refused in the reply (rate_limit_error)")
        XCTAssertEqual(script.completions, 1, "one POST, no retry")
    }

    func testASignedOutRefusalInsideTheStreamAsksToSignIn() async throws {
        let script = CompletionScript()
        script.answer = .status(200, streamError: "authentication_error")
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertEqual(fixture.model.autoStartFailures[account.id]?.kind, .authenticationRequired)
        XCTAssertEqual(account.warmUpOutcomes.last?.streamErrorType, .authentication)
    }

    /// A type outside the documented set never reaches accounts.json.
    func testAnUnrecognisedStreamTypeIsStoredAsUnknown() async throws {
        let script = CompletionScript()
        script.answer = .status(200, streamError: "org_2f9c1a7e")
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(try outcomes(fixture).last?.streamErrorType, .unknown)
        let data = try Data(contentsOf: fixture.directory.appending(path: "accounts.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("org_2f9c1a7e"))
    }

    /// A spent weekly allowance holds warm-up on every poll; the ring keeps
    /// ONE entry for the whole hold instead of a copy per poll.
    func testWarmUpOutcomeRecordsAWeeklyHoldOnceWhileItLasts() async throws {
        let script = CompletionScript()
        script.weeklyUtilization = 100
        let clock = MovableClock()
        let fixture = try await makeOutcomeFixture(script, clock: clock)
        defer { fixture.removeFiles() }

        await fixture.model.refreshAll(reason: .manual)
        clock.date += 300
        await fixture.model.refreshAll(reason: .manual)

        XCTAssertEqual(try outcomes(fixture), [
            .skipped(.weeklyLimitSpent, at: Date(timeIntervalSince1970: 1_000), reserved: false)
        ])
        XCTAssertEqual(script.completions, 0)
    }

    /// One send per window; seven windows leave the newest five.
    func testWarmUpOutcomeRingKeepsTheLastFive() async throws {
        let script = CompletionScript()
        let clock = MovableClock()
        let fixture = try await makeOutcomeFixture(script, clock: clock)
        defer { fixture.removeFiles() }
        let step = AutoStartPolicy.minimumInterval + 60

        for _ in 0..<7 {
            await fixture.model.refreshAll(reason: .manual)
            clock.date += step
        }

        let ring = try outcomes(fixture)
        XCTAssertEqual(script.completions, 7)
        XCTAssertEqual(ring.count, WarmUpOutcome.capacity)
        XCTAssertEqual(ring.first?.at, Date(timeIntervalSince1970: 1_000 + 2 * step))
        XCTAssertEqual(ring.last?.at, Date(timeIntervalSince1970: 1_000 + 6 * step))
    }

    /// The outcomes live in accounts.json: a relaunch reads them back, and
    /// what is on disk carries statuses and kinds — not the org, the
    /// conversation, or the model.
    func testWarmUpOutcomesSurviveARelaunchWithoutIdsOrBodies() async throws {
        let script = CompletionScript()
        let clock = MovableClock()
        let fixture = try await makeOutcomeFixture(script, clock: clock)
        defer { fixture.removeFiles() }
        await fixture.model.refreshAll(reason: .manual)
        clock.date += AutoStartPolicy.minimumInterval + 60
        script.answer = .status(429)
        await fixture.model.refreshAll(reason: .manual)
        let recorded = try outcomes(fixture)
        XCTAssertEqual(recorded.map(\.kind), [.sent, .rejected])

        let relaunched = try await makeOutcomeFixture(
            CompletionScript(),
            directory: fixture.directory
        )
        XCTAssertEqual(try outcomes(relaunched), recorded)

        let data = try Data(contentsOf: fixture.directory.appending(path: "accounts.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let stored = try XCTUnwrap(json.first?["warmUpOutcomes"] as? [[String: Any]])
        let storedData = try JSONSerialization.data(withJSONObject: stored)
        let storedText = String(decoding: storedData, as: UTF8.self).lowercased()
        let conversation = try XCTUnwrap(fixture.model.accounts.first?.keepAliveConversationID)
        XCTAssertFalse(storedText.contains(conversation.uuidString.lowercased()))
        XCTAssertFalse(storedText.contains(Self.scriptedOrganizationID.uuidString.lowercased()))
        XCTAssertFalse(storedText.contains("claude-test-model"))
        let allowedKeys: Set<String> = [
            "at", "kind", "httpStatus", "errorKind", "skipReason", "streamErrorType", "reserved"
        ]
        for entry in stored {
            XCTAssertTrue(Set(entry.keys).isSubset(of: allowedKeys), "\(entry.keys)")
        }
    }

    #if DEBUG
    /// The debug send classifies a landed POST exactly like the automatic
    /// warm-up: a refusal in the stream is reported, recorded as refused,
    /// and nothing is recorded as a started window.
    func testDebugSendReportsARefusalInsideTheStreamAndRecordsNoStart() async throws {
        let script = CompletionScript()
        script.answer = .status(200, streamError: "rate_limit_error")
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }
        try await fixture.model.setFeature(.warmUp, enabled: true)
        let accountID = try XCTUnwrap(fixture.model.accounts.first).id

        await fixture.model.debugSendKeepAlive(accountID: accountID)

        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertEqual(script.completions, 1)
        XCTAssertNil(account.lastAutoStartedAt)
        XCTAssertNil(account.keepAliveConversationID)
        XCTAssertEqual(account.warmUpOutcomes.last?.kind, .rejectedInStream)
        XCTAssertEqual(account.warmUpOutcomes.last?.streamErrorType, .rateLimit)
        XCTAssertEqual(account.warmUpOutcomes.last?.reserved, false)
        let message = try XCTUnwrap(fixture.model.errorMessage)
        XCTAssertTrue(message.contains("REFUSED"), message)
        XCTAssertFalse(message.contains("OK"), message)
    }

    func testDebugSendThatLandsRecordsTheStartAsBefore() async throws {
        let script = CompletionScript()
        let fixture = try await makeOutcomeFixture(script)
        defer { fixture.removeFiles() }
        let accountID = try XCTUnwrap(fixture.model.accounts.first).id

        await fixture.model.debugSendKeepAlive(accountID: accountID)

        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertNotNil(account.lastAutoStartedAt)
        XCTAssertNotNil(account.keepAliveConversationID)
        XCTAssertEqual(account.warmUpOutcomes.last?.kind, .sent)
        XCTAssertTrue(try XCTUnwrap(fixture.model.errorMessage).contains("Debug send OK"))
    }
    #endif
}
