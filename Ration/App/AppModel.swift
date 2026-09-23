import Combine
import Foundation
import WebKit

enum AccountRemovalError: LocalizedError {
    case rollbackFailed

    var errorDescription: String? {
        "The account could not be removed safely. Its local data may need attention."
    }
}

enum AccountCommitError: LocalizedError {
    case rollbackFailed

    var errorDescription: String? {
        "The account was saved without its latest limits. Remove it or try refreshing again."
    }
}

@MainActor
final class SignInSession: ObservableObject, Identifiable {
    let id: UUID
    let provider: Provider
    let accountID: UUID
    let webProfileID: UUID
    let webView: WKWebView
    let signInURL: URL
    let isNewAccount: Bool
    let initialLabel: String

    init(
        id: UUID = UUID(),
        provider: Provider,
        accountID: UUID,
        webProfileID: UUID,
        webView: WKWebView,
        signInURL: URL,
        isNewAccount: Bool,
        initialLabel: String
    ) {
        self.id = id
        self.provider = provider
        self.accountID = accountID
        self.webProfileID = webProfileID
        self.webView = webView
        self.signInURL = signInURL
        self.isNewAccount = isNewAccount
        self.initialLabel = initialLabel
    }
}

@MainActor
private final class AccountSessionManager {
    private let profileManager: any WebProfileManaging
    private let adapterRegistry: ProviderAdapterRegistry
    private let messageSender: ClaudeMessageSender
    private var webViews: [UUID: WKWebView] = [:]

    init(
        profileManager: any WebProfileManaging,
        adapterRegistry: ProviderAdapterRegistry,
        messageSender: ClaudeMessageSender = ClaudeMessageSender()
    ) {
        self.profileManager = profileManager
        self.adapterRegistry = adapterRegistry
        self.messageSender = messageSender
    }

    /// Read-only discovery on the account's warm session (called right after a
    /// successful usage fetch, so the page's org resources are already loaded).
    func prepareKeepAlive(
        for account: AccountRecord,
        boundToOrganizationID organizationID: String?
    ) async throws -> ClaudeMessageSender.Prepared {
        try await recycleWebViewOnTimeout(profileID: account.webProfileID) { webView in
            try await messageSender.prepare(
                boundToOrganizationID: organizationID,
                in: webView
            )
        }
    }

    /// The single irreversible send.
    func sendKeepAlive(
        prepared: ClaudeMessageSender.Prepared,
        conversationID: UUID?,
        for account: AccountRecord
    ) async throws -> UUID {
        try await recycleWebViewOnTimeout(profileID: account.webProfileID) { webView in
            try await messageSender.send(
                prepared: prepared,
                conversationID: conversationID,
                in: webView
            )
        }
    }

    func makeSignInSession(
        provider: Provider,
        accountID: UUID,
        webProfileID: UUID,
        isNewAccount: Bool,
        initialLabel: String
    ) throws -> SignInSession {
        let adapter = try adapterRegistry.adapter(for: provider)
        let webView = webView(for: webProfileID)
        return SignInSession(
            provider: provider,
            accountID: accountID,
            webProfileID: webProfileID,
            webView: webView,
            signInURL: adapter.signInURL,
            isNewAccount: isNewAccount,
            initialLabel: initialLabel
        )
    }

    func verify(_ session: SignInSession) async throws {
        let adapter = try adapterRegistry.adapter(for: session.provider)
        try await adapter.verifySession(in: session.webView)
    }

    func fetchUsage(for account: AccountRecord) async throws -> UsageSnapshot {
        let adapter = try adapterRegistry.adapter(for: account.provider)
        return try await recycleWebViewOnTimeout(profileID: account.webProfileID) { webView in
            try await adapter.fetchUsage(
                accountID: account.id,
                in: webView
            )
        }
    }

    /// Best-effort predicate: true when `profileID`'s cached web view must
    /// NOT be touched by a timeout recycle — an open sign-in/reauth session
    /// shares this exact profile and its live view with the user's visible
    /// login navigation (`beginReauthentication` reuses `account.webProfileID`).
    /// Wired by `AppModel` to "any open sign-in session uses this profile";
    /// defaults to never-protected so standalone/test use is unaffected.
    var isProfileProtected: @MainActor (UUID) -> Bool = { _ in false }

    /// Profiles whose timeout recycle was deferred because the
    /// profile was protected at the time. `completeDeferredRecycles()`
    /// finishes them once protection ends.
    private var pendingRecycleProfileIDs: Set<UUID> = []

    /// A timed-out evaluation means this profile's cached web view is
    /// suspect (a wedged WebContent process reproduces the hang on every
    /// later call). Recycle it — UNLESS an open sign-in/reauth session is
    /// using this exact profile right now (`isProfileProtected`), in which
    /// case recycling would abort the user's visible auth navigation; defer
    /// it instead (`pendingRecycleProfileIDs`, completed by
    /// `completeDeferredRecycles()` once the session closes) and let the
    /// next poll retry on the same view in the meantime. Cookies live in the
    /// WKWebsiteDataStore, not the view, so a recycle never re-prompts login.
    ///
    /// `stopLoading()` alone does NOT settle a pending script-evaluation
    /// callback — pending callbacks are invalidated on FRAME DESTRUCTION,
    /// not load cancellation — so a recycle that only stopped loading would
    /// leak the abandoned `WKWebView` (and its WebContent process) for as
    /// long as the hung call never settles. Navigating the dropped view to
    /// `about:blank` tears down its current frame and force-settles the
    /// pending callback (with an error the bounded race already discards),
    /// letting the abandoned task complete and release the view. This is
    /// best-effort: a fully wedged WebContent process may still ignore the
    /// navigation, but the view is out of the cache either way.
    ///
    /// The view this call operated on is resolved
    /// ONCE, up front, and handed to `operation` — never re-read from the
    /// cache in the catch. With overlapping operations on the same profile
    /// (e.g. one hung call whose timeout is only processed after a second,
    /// already-recycled call has cached a fresh view), a late timeout must
    /// only evict the cache entry if it STILL holds the exact view this call
    /// operated on — otherwise it would drop a healthy, newly cached view out
    /// from under whichever operation is now using it. The timed-out view
    /// itself still gets its frame teardown regardless of cache identity: it
    /// still hosts the abandoned bridge call, cached or not.
    private func recycleWebViewOnTimeout<T>(
        profileID: UUID,
        _ operation: (WKWebView) async throws -> T
    ) async rethrows -> T {
        let operatedView = webView(for: profileID)
        do {
            return try await operation(operatedView)
        } catch let error as WebUsageClientError where error == .timedOut {
            if isProfileProtected(profileID) {
                pendingRecycleProfileIDs.insert(profileID)
            } else {
                if webViews[profileID] === operatedView {
                    webViews.removeValue(forKey: profileID)
                }
                tearDown(operatedView)
            }
            throw error
        }
    }

    /// Force-settle a dropped view's abandoned bridge call — see
    /// `recycleWebViewOnTimeout`'s doc for why `about:blank`, not just
    /// `stopLoading()`, is required.
    private func tearDown(_ webView: WKWebView) {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Finishes every timeout recycle that was deferred because its
    /// profile was protected at the time (an open sign-in/reauth session).
    /// Called by `AppModel` at every point a sign-in session is removed from
    /// `signInSessions` — the tainted view otherwise stays cached with only
    /// `stopLoading()` ever applied to it (the idle release), which never
    /// settles the abandoned callback and leaks the view/WebContent process
    /// indefinitely. Snapshots the pending set first since it mutates it.
    func completeDeferredRecycles() {
        for profileID in Array(pendingRecycleProfileIDs) where !isProfileProtected(profileID) {
            if let webView = webViews.removeValue(forKey: profileID) {
                tearDown(webView)
            }
            pendingRecycleProfileIDs.remove(profileID)
        }
    }

    func removeProfile(profileID: UUID) async throws {
        webViews.removeValue(forKey: profileID)?.stopLoading()
        try await profileManager.removeProfile(profileID: profileID)
    }

    /// Drop this profile's cached WebView first: purging the store underneath a live
    /// view would have it re-fetch everything it just lost anyway.
    func purgeDiskCache(profileID: UUID) async {
        webViews.removeValue(forKey: profileID)?.stopLoading()
        await profileManager.purgeDiskCache(profileID: profileID)
    }

    func existingProfileIdentifiers() async -> [UUID] {
        await profileManager.existingProfileIdentifiers()
    }

    /// Drop every cached WebView whose profile is NOT in `busyProfileIDs`,
    /// freeing its WebKit process memory. The persistent session (cookies) lives
    /// in the `WKWebsiteDataStore`, not the view, so a released profile is
    /// simply recreated by the next `webView(for:)` with no re-login. Snapshots
    /// the keys first since it mutates the dictionary.
    func releaseIdleWebViews(keeping busyProfileIDs: Set<UUID>) {
        for profileID in Array(webViews.keys) where !busyProfileIDs.contains(profileID) {
            guard let webView = webViews.removeValue(forKey: profileID) else { continue }
            // A view still awaiting its deferred recycle carries an
            // abandoned bridge call — `stopLoading()` alone never settles
            // it (see `recycleWebViewOnTimeout`'s doc), so it needs the same
            // `about:blank` teardown `completeDeferredRecycles()` would have
            // applied.
            if pendingRecycleProfileIDs.remove(profileID) != nil {
                tearDown(webView)
            } else {
                webView.stopLoading()
            }
        }
    }

    var cachedProfileIDs: Set<UUID> { Set(webViews.keys) }

    private func webView(for profileID: UUID) -> WKWebView {
        if let webView = webViews[profileID] {
            return webView
        }

        let webView = profileManager.makeWebView(profileID: profileID)
        webViews[profileID] = webView
        return webView
    }

    #if DEBUG
    /// Test-only seam. Every current call path that shares a
    /// profile's `recycleWebViewOnTimeout` guard is serialized by an
    /// in-flight/busy marker (`UsageRefreshCoordinator.inFlight`,
    /// `sendingKeepAliveAccountIDs`, `isProfileProtected`), so the exact
    /// overlap the identity guard defends against — a late timeout from an
    /// abandoned view racing a view a DIFFERENT, already-completed
    /// operation freshly cached — cannot be staged through the public API
    /// alone. This substitutes the cache entry directly so a test can force
    /// that overlap deterministically and drive the real recycle path
    /// against it.
    func replaceWebViewForTesting(profileID: UUID, with webView: WKWebView) {
        webViews[profileID] = webView
    }
    #endif
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var presentations: [AccountPresentation] = []
    @Published private(set) var signInSessions: [UUID: SignInSession] = [:]
    /// In-flight pasted-cookie writes per sign-in session, awaited by
    /// `completeSignIn` before verification — verify must never observe a
    /// half-written credential.
    private var pendingCookieApplications: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Monotonic per-session count of cookie applications EVER started.
    /// Unlike the pending-task marker (which completed applies remove), this
    /// can only grow, so `completeSignIn` comparing it before and after
    /// verification catches even an apply that started AND finished while
    /// verify ran — and never false-positives on the apply it itself awaited.
    private var cookieApplicationGenerations: [UUID: Int] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasPendingProfileCleanup = false
    @Published private(set) var hasVolatileProfileCleanup = false
    /// The volatile entries the cleanup pass would actually act on. Stored, not
    /// recomputed at each read, so `requiresTerminationPreparation`,
    /// `prepareForTermination`'s own guard and the banner cannot disagree about
    /// whether a quit is blocked — the delegate skips preparation entirely when the
    /// flag is false (`RationApp.swift:99`), so a guard reading the RAW set
    /// could refuse a quit that never gets explained, or be bypassed for one that
    /// should have been.
    private var stuckVolatileProfileIDs: Set<UUID> = []

    /// How rarely a mid-session cache purge may fire. The bound is on the TRIGGER,
    /// not the size: every purge is paid for by re-downloading the provider web apps
    /// on the next poll — measured at roughly 57 MB across five accounts — so firing
    /// on each sleep or memory-pressure event would trade disk for bandwidth all day.
    /// Once per day caps both: a day's cache accumulation, and a day's refetch.
    private static let idleCachePurgeInterval: TimeInterval = 24 * 60 * 60

    /// When a purge last ran, seeded by the launch purge so the first idle purge is a
    /// full interval after launch rather than minutes later.
    private var lastCachePurgeAt: Date?

    /// The cleanup queue's own banner, carrying the retry control. Derived in
    /// `updateProfileCleanupState`; deliberately NOT part of `errorMessage`, so
    /// neither can retract or overwrite the other.
    @Published private(set) var profileCleanupBanner: String?
    /// The volatile profiles that actually turned a quit attempt away, captured by
    /// identity so the "quit is paused" wording belongs to that work and cannot be
    /// inherited by unrelated cleanup that enters the volatile set later. Pruned to
    /// whatever is still volatile on every publish, so the wording lasts exactly as
    /// long as the statement stays true.
    private var profileIDsBlockingQuit: Set<UUID> = []
    /// The sign-in sessions that turned a quit attempt away, captured by identity
    /// for the same reason as `profileIDsBlockingQuit`. `@Published` so claiming
    /// them refreshes the view, and read back through `signInQuitPauseBanner`,
    /// which re-derives from live `signInSessions` — so the message retracts on its
    /// own the moment those sessions finish, rather than lingering as a stale
    /// `errorMessage` nothing ever cleared.
    @Published private(set) var sessionIDsBlockingQuit: Set<UUID> = []

    /// "Quit is paused" for the sign-in case. Computed, not stored: `signInSessions`
    /// is `@Published`, so this cannot outlive the sessions it describes.
    var signInQuitPauseBanner: String? {
        signInSessions.keys.contains(where: sessionIDsBlockingQuit.contains)
            ? ProfileCleanupCopy.blockingQuitOnSignIn
            : nil
    }
    @Published private(set) var usageAlertsAuthorized = false

    /// The last warm-up attempt per account, recorded ONLY when it failed and
    /// removed the moment a later attempt succeeds. Facts, not copy: the banner
    /// is derived from these through `warmUpBanner`, so it retracts itself when
    /// the account is removed, paused, has warm-up turned off, or simply gets a
    /// successful attempt — none of which the written-once `errorMessage` it
    /// replaced could do (nothing in the app ever cleared that, so an auto-start
    /// failure stayed on screen until the app was quit).
    @Published private(set) var autoStartFailures: [UUID: AutoStartFailure] = [:]

    /// Warm-up's own banner row. Computed on every read from live accounts,
    /// snapshots and `autoStartFailures`; it shares no storage with
    /// `errorMessage`, so neither can retract or overwrite the other.
    ///
    /// Takes the moment to describe rather than reading the clock itself: two of
    /// its inputs — the failure TTL and the countdown to a weekly reset — move
    /// with time alone, and `@Published` has nothing to publish when only the
    /// clock has advanced. The popover drives this from a `TimelineView`, so an
    /// open window keeps telling the truth instead of freezing at whatever was
    /// true when the last snapshot landed.
    func warmUpBanner(at date: Date) -> WarmUpBanner? {
        WarmUpBannerModel.banner(
            presentations: presentations,
            failures: autoStartFailures,
            schedule: warmUpSchedule,
            now: date
        )
    }

    var warmUpBanner: WarmUpBanner? { warmUpBanner(at: now()) }

    @Published var errorMessage: String?

    private let accountStore: AccountStore
    private let snapshotStore: UsageSnapshotStore
    private let pendingProfileDeletionStore: PendingProfileDeletionStore
    private let historyStore: UsageHistoryStore
    private let appSettings: AppSettings
    private let alertStateStore: AlertStateStore
    private let notificationScheduler: any NotificationScheduling
    private let sessionManager: AccountSessionManager
    private let refreshCoordinator: UsageRefreshCoordinator
    private let systemPowerObserver: any SystemPowerObserving
    private let now: @MainActor () -> Date
    private let beforeSignInPersistence: @MainActor () async -> Void
    /// Test-only interleave seam for the startup readiness barrier (see
    /// `alertsHydrated`'s doc): a no-op in production. `load()` awaits this
    /// exactly once, at the point right after accounts, snapshots, settings,
    /// and the one-time `alertStates` seed have all loaded but BEFORE alerts
    /// are permitted to activate — the precise boundary the launch-time race
    /// exploited. Tests wire a controllable gate here to
    /// deterministically pause `load()` at that boundary and interleave a
    /// concurrent `setUsageAlertsEnabled` call, without relying on
    /// incidental `Task`-scheduling order or a sleep — mirroring the
    /// existing `NotificationSchedulingSpy` authorization-gate pattern.
    private let beforeAlertsHydrationCompletes: @MainActor () async -> Void
    /// Test-only interleave seam: `handleAutoStart` awaits this exactly once,
    /// right after `prepareKeepAlive` returns and BEFORE the commit-point
    /// guard — the precise window the disable/remove race exploits. A
    /// no-op in production; tests pin a deterministic interleave here.
    private let beforeAutoStartCommit: @MainActor () async -> Void
    /// Test-only interleave seam: `retryProfileCleanup` awaits this once per
    /// profile, right after the durable-journal step and BEFORE the final
    /// liveness re-check + deletion — the precise window a rollback-vs-cleanup
    /// race exploits. A no-op in production; tests pin a deterministic
    /// interleave (e.g. restore an account) here.
    private let beforeProfileCleanupDeletion: @MainActor (UUID) async -> Void
    private var cancellables: Set<AnyCancellable> = []
    /// Synchronous single-flight claim for `load()`. Set on `load()`'s very
    /// first line, before any `await`, so a concurrent second call to
    /// `load()` — e.g. two overlapping launch paths — observes it already
    /// `true` and returns immediately instead of double-running the whole
    /// body (double store loads, double orphan-journal enqueues, double
    /// `retryProfileCleanup`, double `refreshAll` — and, per the I3 edge
    /// guard's doc in `reconcileAlertsPass`'s `.startup` case, a second
    /// concurrent startup reconcile pass that could legally reach that
    /// guard with `alertsActive == true`). Reset only when `load()` throws,
    /// so a failed launch can still be retried by a subsequent call —
    /// matches the prior `didLoad`-stays-`false`-on-throw semantics this
    /// property replaces.
    private var loadStarted = false
    private var removingAccountIDs: Set<UUID> = []
    /// Web-profile IDs owned by an account-removal Task currently in flight.
    /// Claimed synchronously in `requestRemoveAccount` (before any await) so
    /// `retryProfileCleanup` — which can run concurrently on launch or manual
    /// retry — never deletes or revoke-races a profile an active removal is
    /// still driving. Keyed by profile ID, not account ID,
    /// because cleanup enumerates profile IDs.
    private var profileIDsBeingRemoved: Set<UUID> = []
    private var mutatingAccountIDs: Set<UUID> = []
    /// Account IDs with a pause currently being persisted. Claimed
    /// SYNCHRONOUSLY in `requestSetPaused` (before any `await`, only when
    /// `paused == true`) and released once `AccountStore.setPaused`'s
    /// persist completes — the same synchronous-claim shape as
    /// `removingAccountIDs`, so `applyAlertDecision`'s post guard gets the
    /// same "cooperative scheduling can't interleave mid-synchronous-run"
    /// guarantee for pause that `removingAccountIDs` gives for removal.
    /// Deliberately its OWN marker rather than a re-read of the generic
    /// `mutatingAccountIDs` — that one is shared by unrelated mutations
    /// (rename, auto-start toggle, billing day) whose in-flight state must
    /// NOT suppress a legitimate alert.
    private var pausingAccountIDs: Set<UUID> = []
    private var committingSessionIDs: Set<UUID> = []
    private var cancellingSessionIDs: Set<UUID> = []
    private var cancelRequestedSessionIDs: Set<UUID> = []
    /// Sessions the user cancelled whose cleanup could not finish. They are kept
    /// deliberately — the profile is still queued, and a kept session lets cleanup
    /// retry — but they must NEVER commit.
    ///
    /// Without this, `requireActive` cannot tell a session kept for cleanup
    /// from a live one. `cancellingSessionIDs` is released by a `defer` as soon as
    /// `cancelSignIn` returns, so a provider request that resumes afterwards passed
    /// every guard and committed the account the user had just cancelled — onto a
    /// profile queued for deletion.
    private var cancelledSessionIDsPendingCleanup: Set<UUID> = []
    private var volatileProfileDeletionIDs: Set<UUID> = []
    private var sendingKeepAliveAccountIDs: Set<UUID> = []
    /// Authoritative in-memory alert-evaluation state for this session — NOT
    /// `alertStateStore`. Seeded from the store once in `load()`, then owned
    /// exclusively by `decideAlerts`, which commits to it SYNCHRONOUSLY (no
    /// `await` anywhere in that function). Because `AppModel` is `@MainActor`
    /// (single-threaded) and the commit has no suspension point, two
    /// evaluations — for the same or different accounts, including a prime
    /// racing a normal eval, or an eval racing a removal — can never
    /// interleave. This is what makes the whole class of read-evaluate-
    /// persist ordering races structurally impossible, rather than merely
    /// patched around with a serialization queue. Persistence to
    /// `alertStateStore` is a best-effort ASYNC SIDE EFFECT of an already-
    /// committed decision (see `applyAlertDecision`); it never feeds back
    /// into this map, so a failed save can never cause a re-post.
    private var alertStates: [UUID: AccountAlertState] = [:]
    /// Accounts whose alert state has been permanently removed (via
    /// `removeAccount`). Checked synchronously at the top of `decideAlerts`
    /// so a late-arriving sink emission for a just-removed account can never
    /// resurrect an entry — there is no suspension point between the
    /// tombstone insert and any subsequent `decideAlerts` call, so this
    /// check can never observe a stale "not yet removed" world. New accounts
    /// always get a fresh UUID, so this set only grows.
    private var alertTombstones: Set<UUID> = []
    /// Synchronous posting gate. `true` means "alerts are enabled,
    /// authorized, AND primed — safe to POST." Flipped ONLY synchronously,
    /// never inside an `await`ed span:
    /// - `true` at the end of a current-version `.userRequest` reconcile
    ///   pass's enable path (after authorization is granted AND
    ///   `primeAllAlerts()` has run), and at the end of a current-version
    ///   `.startup` pass on its OFF→ON edge (same authorize-then-prime
    ///   sequence, run once per activation).
    /// - `false` synchronously at the tap in `requestSetUsageAlerts(false)`
    ///   (I4), and whenever authorization resolves denied in either pass.
    /// - Starts `false`.
    ///
    /// This is the single mechanism that closes the async side-effect races
    /// the hardening pass left open: because both the sink's guard
    /// And every enqueued post's execution-time recheck read
    /// this SAME synchronously-flipped flag, there is no suspension window
    /// in which a disable/remove can land without being observed by either
    /// the evaluation or the post it guards.
    private var alertsActive = false
    /// STARTUP READINESS BARRIER. `false` until `load()` has fully hydrated
    /// the app's initial state — accounts, snapshots, and the one-time
    /// `alertStates` seed from `alertStateStore` — then flipped to `true`
    /// exactly once, synchronously, by `load()` itself. Stays `true` for the
    /// rest of the process's life after that — never reset back to `false`.
    ///
    /// INVARIANT: `alertsActive` may become `true` only after
    /// `alertsHydrated == true`.
    ///
    /// Closes a launch-time race the generation token alone did not:
    /// `load()` used to recheck its
    /// captured generation only AFTER its LATE authorization-status await,
    /// not after each of its EARLIER awaits (accounts/snapshots/settings/
    /// alert-state loads). A concurrent `setUsageAlertsEnabled(true)`
    /// landing during one of those earlier awaits could authorize, prime —
    /// against the still-loading (possibly still-empty) snapshot store —
    /// and activate BEFORE `load()`'s own snapshot load had even completed.
    /// When `load()` then resumed and published the just-loaded, genuinely
    /// HIGH-usage snapshot, the now-active sink treated it as a fresh
    /// crossing and posted a spurious notification for a crossing that
    /// predates enabling — violating the priming guarantee.
    ///
    /// With this barrier, a request born before hydration
    /// (`.coldStartDeferred`, see `AlertsReconcileMode`) persists its
    /// desired setting only — no authorization query, prime, or
    /// `alertsActive` touch — deferring activation to the startup reconcile
    /// pass that `load()` chains once hydration completes. That pass, not
    /// `load()` itself, is now the SOLE startup activation authority: it
    /// queries authorization / primes / activates only once hydration is
    /// complete, reading `alertsDesired` rather than the persisted setting
    /// (spec I1). A disable is exempt from
    /// deferral — it still flips `alertsActive = false` synchronously at
    /// request time, regardless of hydration, so a disable requested
    /// mid-launch always wins.
    private var alertsHydrated = false
    /// Reconciler mode, captured SYNCHRONOUSLY at request time (spec I6): a
    /// request born before hydration can never prompt, no matter when its
    /// pass actually runs. `.startup` passes never write settings (I7).
    private enum AlertsReconcileMode { case userRequest, coldStartDeferred, startup }
    /// Last user-requested alerts state this session — the ONLY input to
    /// lifecycle activation decisions (spec I1). The persisted setting is
    /// read by the lifecycle only for the version-0 seed and the parked
    /// moot-convergence check.
    private var alertsDesired = false
    /// Bumped synchronously per request; 0 = no explicit request yet this
    /// session (load()'s seed rule keys off this).
    private var alertsDesiredVersion = 0
    /// Terminal park: set when a request fails or is cancelled before its
    /// desired value is durably established; cleared synchronously by every
    /// new request. Property that matters: at a startup
    /// pass's execution, passing its guards (version current AND !parked)
    /// implies the desired value it reads was durably established.
    private var alertsLifecycleParked = false
    /// Serialization chain: every reconcile pass runs as a link, so whole
    /// passes never interleave (spec I5). Links are error-erased so a
    /// throwing pass never poisons its successors.
    private var alertsLifecycleChain: Task<Void, Never>?
    /// The single long-lived serial processor for ALL alert persistence/
    /// posting side effects (save, post, remove) — replaces the old
    /// per-event detached `Task`s and the unbounded `alertSideEffects` array.
    /// `SerializedMutationQueue.enqueue` chains an item onto the tail
    /// SYNCHRONOUSLY (the capture-and-schedule happens with no suspension),
    /// so callers on the main actor (`applyAlertDecision`, `removeAccount`)
    /// get a guaranteed FIFO ordering: a save enqueued for a decision always
    /// runs before a later `remove` enqueued for the same account (the
    /// persisted entry can never be resurrected by a late-running save).
    /// Each item re-checks the state it depends on (`alertsActive` for
    /// posts, `alertTombstones` for saves) AT EXECUTION TIME, not at enqueue
    /// time, since the queue only guarantees ordering, not that state hasn't
    /// changed between enqueue and execution. `flushAlertEvaluations`
    /// (test hook) awaits an empty barrier op chained onto the same queue —
    /// no retained `Task` handle array, bounded, and reusable across
    /// repeated flush cycles.
    ///
    /// `applyAlertDecision` only enqueues a save when
    /// `decideAlerts` actually changed the account's persisted-relevant
    /// state (`next != previous`). In steady state — the overwhelming
    /// majority of sink emissions, since most refresh cycles don't cross a
    /// new tier/window/reauth/rate-limit edge — the decision reproduces the
    /// same state and enqueues nothing, which bounds this queue's growth
    /// without needing a separate per-account coalescing map. Posts are only
    /// ever enqueued when `decideAlerts` actually returns events, which is
    /// already rare/edge-triggered, so no analogous change was needed there.
    private let alertSideEffectQueue = SerializedMutationQueue()

    var accounts: [AccountRecord] { accountStore.accounts }
    /// Usage history store, exposed read-only for the UI (charts/rollups).
    var history: UsageHistoryStore { historyStore }
    /// App settings, exposed read-only for the UI (e.g. the sort toggle).
    var settings: AppSettings { appSettings }

    /// Whether a first-run wizard is owed for this launch.
    ///
    /// DECIDED ONCE, and only at the instant the decision is unraceable:
    /// immediately after `accountStore` and `appSettings` load, at the very top
    /// of `load()`. Every later sampling point is wrong, in two different ways:
    ///
    /// - Sampling *before* the stores load reads an empty account list that
    ///   means "not read yet", not "no accounts" — so a user whose
    ///   `accounts.json` was momentarily unreadable (a throw `start()` swallows
    ///   into `errorMessage`) would present as a fresh install.
    /// - Sampling *after* `start()` returns races the account transient:
    ///   `start()` stays suspended through the launch refresh while the menu
    ///   bar is already interactive, and `completeSignIn` publishes an account
    ///   BEFORE saving its snapshot, rolling it back if that save fails. A
    ///   sample landing in that window reads `1` for a sign-in that never
    ///   committed and silently cancels a genuine first run.
    ///
    /// At the capture point neither is possible: both files have just been
    /// read, and no sign-in can have reached its commit in the microseconds
    /// between the two awaits.
    ///
    /// Cleared only by `markOnboardingCompleted()`, so it can never be
    /// invalidated by transient data — only by the user actually dismissing the
    /// wizard, including a manually opened one.
    private(set) var isOnboardingOwed = false

    var requiresTerminationPreparation: Bool {
        hasVolatileProfileCleanup || !signInSessions.isEmpty
    }

    /// Accounts eligible for a usage refresh. Paused accounts are excluded
    /// (dormant: no fetch, no alert evaluation — see `AccountVisibility`).
    /// Accounts mid-removal are also excluded so a concurrent refresh
    /// (including the background timer, which fetches directly through the
    /// coordinator) cannot resurrect a snapshot for an account whose data is
    /// being torn down.
    private var refreshableAccounts: [AccountRecord] {
        AccountVisibility.visible(accounts)
            .filter { !removingAccountIDs.contains($0.id) }
    }

    /// The accounts the popover surfaces render and reason over. Settings and
    /// History intentionally use `accounts`/`presentations` instead.
    var visibleAccounts: [AccountRecord] {
        AccountVisibility.visible(accounts)
    }

    init(
        accountStore: AccountStore,
        snapshotStore: UsageSnapshotStore,
        pendingProfileDeletionStore: PendingProfileDeletionStore,
        historyStore: UsageHistoryStore,
        appSettings: AppSettings,
        alertStateStore: AlertStateStore,
        profileManager: any WebProfileManaging,
        adapterRegistry: ProviderAdapterRegistry,
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        notificationScheduler: any NotificationScheduling = UserNotificationScheduler(),
        now: @escaping @MainActor () -> Date = { .now },
        beforeSignInPersistence: @escaping @MainActor () async -> Void = {},
        beforeAlertsHydrationCompletes: @escaping @MainActor () async -> Void = {},
        beforeAutoStartCommit: @escaping @MainActor () async -> Void = {},
        beforeProfileCleanupDeletion: @escaping @MainActor (UUID) async -> Void = { _ in },
        systemPowerObserver: any SystemPowerObserving = SystemPowerObserver()
    ) {
        self.accountStore = accountStore
        self.snapshotStore = snapshotStore
        self.pendingProfileDeletionStore = pendingProfileDeletionStore
        self.historyStore = historyStore
        self.appSettings = appSettings
        self.alertStateStore = alertStateStore
        self.notificationScheduler = notificationScheduler
        self.now = now
        self.beforeSignInPersistence = beforeSignInPersistence
        self.beforeAlertsHydrationCompletes = beforeAlertsHydrationCompletes
        self.beforeAutoStartCommit = beforeAutoStartCommit
        self.beforeProfileCleanupDeletion = beforeProfileCleanupDeletion
        self.systemPowerObserver = systemPowerObserver

        let sessionManager = AccountSessionManager(
            profileManager: profileManager,
            adapterRegistry: adapterRegistry,
            messageSender: messageSender
        )
        self.sessionManager = sessionManager
        refreshCoordinator = UsageRefreshCoordinator(
            snapshotStore: snapshotStore,
            now: now,
            pollInterval: {
                // Base cadence + jitter, relaxed in Low Power Mode.
                PollSchedule.interval(
                    lowPowerMode: systemPowerObserver.isLowPowerModeEnabled,
                    jitterSeconds: Int.random(in: 0...PollSchedule.maxJitterSeconds)
                )
            },
            fetchUsage: { account in
                try await sessionManager.fetchUsage(for: account)
            }
        )

        // An open sign-in/reauth session shares its account's web
        // profile (and live view) with a concurrent timer refresh; protect
        // it from a timed-out fetch's recycle so a wedged poll never aborts
        // the user's visible auth navigation.
        sessionManager.isProfileProtected = { [weak self] profileID in
            self?.signInSessions.values.contains { $0.webProfileID == profileID } ?? false
        }

        Publishers.CombineLatest4(
            accountStore.$accounts,
            snapshotStore.$snapshots,
            refreshCoordinator.$states,
            appSettings.$sortByWeeklyReset
        )
        .map { accounts, snapshots, states, sortByWeeklyReset in
            let mapped = accounts.map { account in
                let snapshot = snapshots[account.id]
                let state = states[account.id]
                    ?? (snapshot == nil ? .unavailable : .current)
                return AccountPresentation(
                    account: account,
                    snapshot: snapshot,
                    state: state
                )
            }
            return AccountDisplaySort.sorted(mapped, sortByWeeklyReset: sortByWeeklyReset)
        }
        .sink { [weak self] presentations in
            self?.presentations = presentations
        }
        .store(in: &cancellables)

        // Best-effort usage-alert evaluation. Triggered on BOTH a snapshot
        // change (threshold/reset) and a state-only change (reauth/rate-
        // limited), since either publisher firing satisfies CombineLatest.
        // The decision (`decideAlerts`) is fully SYNCHRONOUS — it reads and
        // commits `alertStates` with no `await` in between — so this closure
        // can loop every refreshable account and commit each one's decision
        // before the next Combine emission (or a concurrent `removeAccount`)
        // can possibly interleave. Only the side effects (persist/post) are
        // enqueued onto `alertSideEffectQueue`; they read the already-
        // committed decision and never feed back into `alertStates`.
        //
        // Gated on `usageAlertsEnabled`, the MASTER switch — deliberately NOT
        // on `alertsActive`, which additionally requires notification
        // authorization.
        //
        // Authorization gates the notification CHANNEL, not alert evaluation.
        // Gating evaluation on it broke the drop for anyone who denied
        // notifications, in a way that never healed: a dismissal was
        // recorded, and the window reset that should clear `dismissedTier`
        // never ran, so that subject stayed hidden for every FUTURE window
        // rather than just the dismissed one.
        //
        // Posting is still fully gated: `applyAlertDecision` re-checks
        // `alertsActive` at side-effect EXECUTION time, so a crossing
        // observed while unauthorized (or mid-enable) advances the watermark
        // and posts nothing — the same outcome `primeAllAlerts()` produces,
        // which is what the old gate was really buying.
        //
        // IMPORTANT: uses the `snapshots`/`states` dictionaries DELIVERED BY
        // THE PUBLISHER, not `self.snapshotStore.snapshot(for:)` /
        // `self.refreshCoordinator.state(for:)`. `@Published` publishes from
        // `willSet` — i.e. BEFORE its backing storage is actually updated —
        // so re-reading the live store synchronously from within this very
        // sink would observe the STALE, pre-update value one emission late.
        // The delivered parameters are already the up-to-date value; this
        // mirrors the `presentations` pipeline's `.map` above, which uses
        // the same delivered-parameter pattern for the same reason.
        Publishers.CombineLatest(
            snapshotStore.$snapshots,
            refreshCoordinator.$states
        )
        .sink { [weak self] snapshots, states in
            guard let self, self.appSettings.usageAlertsEnabled else { return }
            // `refreshableAccounts` (not `accounts`) excludes accounts currently
            // being removed: `removeAccount` sets `removingAccountIDs` BEFORE
            // its teardown (`refreshCoordinator.cancel` / `snapshotStore.remove`)
            // fires this very sink, so evaluating over the full account list
            // would decide for an account mid-removal. `decideAlerts`'s
            // tombstone check is the structural backstop even if that
            // ordering ever changed.
            for account in self.refreshableAccounts {
                let snapshot = snapshots[account.id]
                let state = states[account.id] ?? (snapshot == nil ? .unavailable : .current)
                let decision = self.decideAlerts(
                    accountID: account.id,
                    provider: account.provider,
                    snapshot: snapshot,
                    state: state,
                    prime: false
                )
                self.applyAlertDecision(
                    accountID: account.id,
                    label: account.label,
                    events: decision.events,
                    changed: decision.changed
                )
            }
        }
        .store(in: &cancellables)

        refreshCoordinator.onSnapshotSaved = { [weak self] account, snapshot in
            // Record the triggering snapshot BEFORE awaiting auto-start.
            // `record` is a synchronous enqueue-and-return, so this does not
            // delay auto-start. `handleAutoStart` may itself record a re-fetched,
            // strictly-newer snapshot — that must land chronologically after
            // this one, or the history series' monotonic guard rejects it and
            // permanently flips `isProjectionEligible` to false.
            self?.historyStore.record(account: account, snapshot: snapshot)
            await self?.handleAutoStart(account: account, snapshot: snapshot)
        }

        // On system sleep or memory pressure, release WebViews not backing
        // in-flight work. Started in `load()`, stopped in `stop()`.
        systemPowerObserver.onShouldReleaseIdleResources = { [weak self] in
            self?.releaseIdleWebViews()
            // Fire-and-forget: the purge is best-effort hygiene, and nothing in this
            // event's contract waits on it. `purgeIdleCachesIfDue` claims its own
            // rate-limit window synchronously, so overlapping events cannot stack.
            Task { @MainActor [weak self] in await self?.purgeIdleCachesIfDue() }
        }
    }

    /// Release every cached WebView except those backing in-flight work
    /// (refresh / auto-start send / removal / open sign-in). Safe to call
    /// anytime — released profiles are recreated lazily on next use with no
    /// re-login. Invoked by the power observer (sleep / memory pressure).
    func releaseIdleWebViews() {
        sessionManager.releaseIdleWebViews(keeping: idleReleaseBusyProfileIDs())
    }

    /// The profiles backing in-flight work, so both the view release and the cache
    /// purge agree on what must not be touched.
    private func idleReleaseBusyProfileIDs() -> Set<UUID> {
        WebViewReleasePolicy.busyProfileIDs(
            accounts: accounts,
            inFlightRefreshAccountIDs: refreshCoordinator.inFlightAccountIDs,
            sendingKeepAliveAccountIDs: sendingKeepAliveAccountIDs,
            removingAccountIDs: removingAccountIDs,
            profileIDsBeingRemoved: profileIDsBeingRemoved,
            signInProfileIDs: Set(signInSessions.values.map(\.webProfileID))
        )
    }

    /// Mid-session cache purge, rate-bounded to `idleCachePurgeInterval`.
    ///
    /// Launch hygiene bounds accumulation ACROSS launches; this bounds it *within* a
    /// launch, which is the dominant term for a menu-bar app that runs for weeks. It
    /// rides the same sleep / memory-pressure event that already drops idle web
    /// views, so a profile whose view was just released is the one whose cache goes —
    /// nothing in use is disturbed, and the refetch lands on a poll that was going to
    /// recreate the view regardless.
    ///
    /// Busy profiles are skipped rather than deferred: the next event picks them up,
    /// and the rate bound means there is no hurry.
    func purgeIdleCachesIfDue() async {
        let idleProfileIDs = Set(accounts.map(\.webProfileID))
            .subtracting(idleReleaseBusyProfileIDs())
        guard !idleProfileIDs.isEmpty else { return }

        let moment = now()
        if let lastCachePurgeAt,
            moment.timeIntervalSince(lastCachePurgeAt) < Self.idleCachePurgeInterval {
            return
        }
        // Claimed BEFORE the awaits below, so a second event arriving mid-purge sees
        // the window as closed rather than starting a concurrent pass.
        lastCachePurgeAt = moment

        for profileID in idleProfileIDs {
            await sessionManager.purgeDiskCache(profileID: profileID)
        }
    }

    /// Runs the auto-start policy after a fresh usage snapshot. Discovers, then
    /// durably RESERVES the attempt before the one irreversible send, so a failed
    /// or lost send can never retry-storm the account. Re-reads the current
    /// account so a toggle turned off mid-refresh is honored.
    private func handleAutoStart(
        account: AccountRecord,
        snapshot: UsageSnapshot
    ) async {
        guard AutoStartPolicy.shouldAutoStart(
            account: account,
            fiveHour: snapshot.fiveHour,
            weekly: snapshot.weekly,
            now: now(),
            schedule: warmUpSchedule
        ) else {
            return
        }
        // Re-check the current stored account: it may have been disabled or
        // removed while the usage fetch was suspended.
        guard
            let current = accounts.first(where: { $0.id == account.id }),
            current.provider == .claude,
            current.autoStartFiveHour,
            !removingAccountIDs.contains(current.id),
            !sendingKeepAliveAccountIDs.contains(current.id)
        else {
            return
        }
        // FAIL CLOSED: the irreversible send is bound to the org the
        // triggering snapshot's data actually came from. A snapshot without
        // one (only possible outside the real Claude adapter) must skip
        // rather than let discovery pick whatever workspace is active now.
        guard let snapshotOrganizationID = snapshot.organizationID else {
            return
        }
        sendingKeepAliveAccountIDs.insert(current.id)
        defer { sendingKeepAliveAccountIDs.remove(current.id) }

        do {
            // Model discovery is read-only and safe to retry on later
            // refreshes; the org itself comes bound from the snapshot.
            let prepared = try await sessionManager.prepareKeepAlive(
                for: current,
                boundToOrganizationID: snapshotOrganizationID
            )
            try Task.checkCancellation()
            // Test-only interleave point (no-op in production): lets a test pin
            // handleAutoStart at the commit window and land a synchronous
            // disable/remove before the guard below runs.
            await beforeAutoStartCommit()
            // Commit-point re-check. `prepareKeepAlive` suspended, so since the
            // decision above the user may have turned auto-start off, the
            // account may be gone, the clock may have crossed into a quiet hour,
            // or the schedule may have been edited. Re-read the account and
            // re-run the FULL policy — one captured `commitNow`, the CURRENT
            // schedule — before the reservation and the irreversible POST.
            //
            // An attempt already past `reserveAutoStart` is allowed to finish
            // across a quiet boundary: aborting after reservation would leave
            // `lastAutoStartedAt` set and wrongly suppress warm-up for
            // `minimumInterval`.
            let commitNow = now()
            guard
                let atCommit = accounts.first(where: { $0.id == current.id }),
                !removingAccountIDs.contains(atCommit.id),
                // A disable/remove in flight publishes its record only after its
                // save completes, so `atCommit` can still read `enabled` while the
                // user has already opted out. `mutatingAccountIDs` is claimed
                // SYNCHRONOUSLY at the top of `setAutoStart`/`removeAccount`
                // (before any await), so it reflects that intent immediately —
                // bail rather than reserve behind an opt-out and POST.
                !mutatingAccountIDs.contains(atCommit.id),
                // `weekly` here is the TRIGGERING snapshot's, exactly as
                // `fiveHour` is: the refresh is single-flight, so no newer local
                // observation can exist yet, and re-reading the store would
                // return this same one. It is passed so this really is the FULL
                // policy — the allowance cannot silently stop being checked if
                // this commit point ever gains a fresher source. What it cannot
                // catch is another Claude client spending the last percent while
                // `prepareKeepAlive` was suspended; that
                // degrades to the ordinary rejected-send path it always was.
                AutoStartPolicy.shouldAutoStart(
                    account: atCommit,
                    fiveHour: snapshot.fiveHour,
                    weekly: snapshot.weekly,
                    now: commitNow,
                    schedule: warmUpSchedule
                )
            else {
                return
            }
            // Reserve BEFORE the irreversible POST: even if the send fails or its
            // result is lost, the policy will not re-fire within this window.
            try await accountStore.reserveAutoStart(id: current.id, at: commitNow)
            let conversationID = try await sessionManager.sendKeepAlive(
                prepared: prepared,
                conversationID: current.keepAliveConversationID,
                for: current
            )
            // The POST landed — the 5h window HAS started. This attempt is now
            // the latest word on the account, so it takes back any earlier
            // failure rather than leaving both statements standing, and NOTHING
            // below may turn it back into one: reporting
            // "auto-start didn't run" about a window that is demonstrably
            // running is a lie, and the reservation above means it will not run
            // again this window regardless.
            autoStartFailures.removeValue(forKey: current.id)
            // Best-effort from here. A failed record costs only the REUSABLE
            // conversation id: `lastAutoStartedAt` is already reserved, so the
            // sole consequence is that the next window creates a fresh
            // conversation instead of reusing this one.
            try? await accountStore.recordAutoStart(
                id: current.id,
                conversationID: conversationID,
                at: now()
            )
            // Reflect the freshly-started window immediately, instead of waiting
            // for the next refresh cycle. only record history for this
            // re-fetched snapshot after a SUCCESSFUL save — an unconditional
            // record here (regardless of save outcome) previously let the
            // history series record this newer snapshot even when it never
            // (or not yet) landed in `snapshotStore`.
            if let refreshed = try? await sessionManager.fetchUsage(for: current) {
                do {
                    try await snapshotStore.save(refreshed)
                    historyStore.record(account: current, snapshot: refreshed)
                } catch {}
            }
        } catch is CancellationError {
            return
        } catch {
            autoStartFailures[current.id] = AutoStartFailure(
                at: now(),
                kind: AutoStartFailure.Kind(error: error)
            )
        }
    }

    /// Synchronously claims the account-mutation marker (throws if a mutation
    /// is already in flight), then returns an already-started Task that
    /// persists the change and releases the marker. The marker is visible the
    /// instant this returns — before the Task runs — so a concurrently
    /// suspended `handleAutoStart` continuation always observes an in-flight
    /// disable at its commit-point guard. Callers that need the tap-time
    /// claim (the Settings UI) MUST call this synchronously in the SwiftUI
    /// action, not inside a `Task`.
    @MainActor
    func requestSetAutoStart(accountID: UUID, enabled: Bool) throws -> Task<Void, Error> {
        try claimAccountMutation(accountID)
        return Task { [self] in
            defer { mutatingAccountIDs.remove(accountID) }
            try await accountStore.setAutoStart(id: accountID, enabled: enabled)
        }
    }

    @MainActor
    func requestSetBillingRenewalDay(accountID: UUID, day: Int?) throws -> Task<Void, Error> {
        try claimAccountMutation(accountID)
        return Task { [self] in
            defer { mutatingAccountIDs.remove(accountID) }
            try await accountStore.setBillingRenewalDay(id: accountID, day: day)
        }
    }

    /// Compatibility wrapper. Forwards caller cancellation into the unstructured
    /// request Task (an unstructured Task is not a child of its awaiter, so
    /// `await task.value` alone would not cancel it) so this stays behavior-
    /// preserving vs. the pre-split inline `async` method.
    func setAutoStart(accountID: UUID, enabled: Bool) async throws {
        let task = try requestSetAutoStart(accountID: accountID, enabled: enabled)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Synchronously claims the account-mutation marker (throws if a mutation
    /// is already in flight), then returns an already-started Task that
    /// persists the change and releases the marker. The marker is visible the
    /// instant this returns — before the Task runs — so a concurrently
    /// suspended `handleAutoStart` continuation always observes an in-flight
    /// pause/resume at its commit-point guard. When pausing, this also
    /// synchronously claims `pausingAccountIDs` — see its doc — so the
    /// alert-post-suppression guard in `applyAlertDecision` gets the same
    /// race-free guarantee for pause that `removingAccountIDs` gives
    /// removal. On resume, the Task intentionally holds the account-mutation
    /// marker across the triggered `refreshAll` — concurrent mutations see
    /// `operationInProgress` for that window, and auto-start cannot commit
    /// during the resume refresh. Callers that need the tap-time claim (the
    /// Settings UI) MUST call this synchronously in the SwiftUI action, not
    /// inside a `Task`.
    @MainActor
    func requestSetPaused(accountID: UUID, paused: Bool) throws -> Task<Void, Error> {
        try claimAccountMutation(accountID)
        // Synchronous claim (before any await) — see `pausingAccountIDs`'s
        // doc: gives the post-suppression guard in `applyAlertDecision` the
        // same race-free guarantee `removingAccountIDs` gives removal. Only
        // relevant for pausing (dormancy); resuming needs no such guard.
        if paused {
            pausingAccountIDs.insert(accountID)
        }
        return Task { [self] in
            defer {
                mutatingAccountIDs.remove(accountID)
                pausingAccountIDs.remove(accountID)
            }
            try await accountStore.setPaused(id: accountID, paused: paused)
            // Resume: refresh immediately so the card and data reappear now,
            // not at the next poll tick. (Pause needs nothing — the account
            // simply drops out of `refreshableAccounts`.)
            if !paused {
                await refreshAll(reason: .manual)
            }
        }
    }

    /// Compatibility wrapper mirroring `setAutoStart`'s cancellation forwarding.
    func setPaused(accountID: UUID, paused: Bool) async throws {
        let task = try requestSetPaused(accountID: accountID, paused: paused)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func setSortByWeeklyReset(_ value: Bool) async throws {
        try await appSettings.setSortByWeeklyReset(value)
    }

    func setRedactNotifications(_ value: Bool) async throws {
        try await appSettings.setRedactNotifications(value)
    }

    func setShowInUseInMenuBar(_ value: Bool) async throws {
        try await appSettings.setShowInUseInMenuBar(value)
    }

    func setMenuBarWindow(_ kind: UsageWindowKind, for provider: Provider) async throws {
        try await appSettings.setMenuBarWindow(kind, for: provider)
    }

    func setMenuBarDisplaysRemaining(_ value: Bool) async throws {
        try await appSettings.setMenuBarDisplaysRemaining(value)
    }

    // Field-level pass-throughs (not the whole-pair `setThresholds`/
    // `setCursorSpend`): the Alerts pane commits one field at a time on blur,
    // and composing a whole value from a locally-held copy would let a second
    // field's commit carry a stale sibling value back over an edit that
    // hasn't round-tripped yet. See `AppSettings.setWarningPercent`.
    /// Each setter re-evaluates AFTER the settings have actually persisted —
    /// `decideAlerts` reads `appSettings.data` synchronously, so evaluating
    /// before the await would resolve the OLD thresholds. A throw skips the
    /// re-evaluation, which is correct: nothing changed.
    /// See `evaluateAlertsAfterThresholdChange()`.
    func setWarningPercent(_ value: Int, provider: Provider, window: UsageWindowKind) async throws {
        try await appSettings.setWarningPercent(value, provider: provider, window: window)
        evaluateAlertsAfterThresholdChange()
    }

    func setCriticalPercent(_ value: Int, provider: Provider, window: UsageWindowKind) async throws {
        try await appSettings.setCriticalPercent(value, provider: provider, window: window)
        evaluateAlertsAfterThresholdChange()
    }

    func setNotificationEnabled(_ enabled: Bool, forKey key: String) async throws {
        try await appSettings.setNotificationEnabled(enabled, forKey: key)
    }

    func setDropEnabled(_ enabled: Bool, forKey key: String) async throws {
        try await appSettings.setDropEnabled(enabled, forKey: key)
        // Turning the drop ON for a cell already over its threshold should
        // show the panel now, not up to a minute later on the next tick.
        evaluateAlertsAfterThresholdChange()
    }

    func setResetExpiryLeadDays(_ days: Int, provider: Provider) async throws {
        try await appSettings.setResetExpiryLeadDays(days, provider: provider)
        // A longer lead can put a stored, still-current list inside the
        // window right now.
        evaluateAlertsAfterThresholdChange()
    }

    func setSpendWarningCents(_ value: Int?) async throws {
        try await appSettings.setSpendWarningCents(value)
        evaluateAlertsAfterThresholdChange()
    }

    func setSpendCriticalCents(_ value: Int?) async throws {
        try await appSettings.setSpendCriticalCents(value)
        evaluateAlertsAfterThresholdChange()
    }

    /// Records that the first-run wizard has been seen.
    ///
    /// Clears the owed flag FIRST and synchronously, so a wizard the user
    /// opened manually and dismissed also consumes an auto-presentation owed
    /// from launch — otherwise an aborted quit could reopen a wizard they had
    /// already closed, breaking the shown-once contract.
    ///
    /// The persisted write is best-effort by design: a failure means the wizard
    /// may reappear next launch, which is a far better outcome than a window
    /// that refuses to close.
    func markOnboardingCompleted() async {
        isOnboardingOwed = false
        try? await appSettings.setHasCompletedOnboarding(true)
    }

    /// The user's warm-up inhibition config (quiet hours + holidays), rebuilt
    /// from settings on demand so it always reflects the latest edit.
    ///
    /// FAIL CLOSED: when the settings file could not be decoded
    /// (`appSettings.loadFailed`), the empty quiet-hours/holidays defaults are
    /// substituted values, NOT the user's choices — trusting them would let
    /// warm-up fire every hour against a schedule the user may have configured
    /// to inhibit it. In that state every hour is treated as quiet, so warm-up
    /// never fires until settings are repaired (any successful save clears the
    /// flag). A one-time inhibition of an opt-in convenience is the safe
    /// default; silently sending real messages on an unknown schedule is not.
    var warmUpSchedule: WarmUpQuietSchedule {
        guard !appSettings.loadFailed else {
            return WarmUpQuietSchedule(
                quietCells: Set(AppSettingsData.cellRange)
            )
        }
        return WarmUpQuietSchedule(
            quietCells: Set(appSettings.quietHours),
            holidays: appSettings.holidays
        )
    }

    func setQuietHours(_ cells: [Int]) async throws {
        try await appSettings.setQuietHours(cells)
    }

    func setHolidays(_ holidays: [HolidayRange]) async throws {
        try await appSettings.setHolidays(holidays)
    }

    /// Atomic, field-specific holiday deltas — see `AppSettings` for why the UI
    /// must not read-modify-write the whole published array.
    func addHoliday(_ holiday: HolidayRange) async throws {
        try await appSettings.addHoliday(holiday)
    }

    func setHolidayLabel(id: UUID, _ label: String) async throws {
        try await appSettings.setHolidayLabel(id: id, label)
    }

    func setHolidayStart(id: UUID, _ start: LocalDate) async throws {
        try await appSettings.setHolidayStart(id: id, start)
    }

    func setHolidayEnd(id: UUID, _ end: LocalDate) async throws {
        try await appSettings.setHolidayEnd(id: id, end)
    }

    func removeHoliday(id: UUID) async throws {
        try await appSettings.removeHoliday(id: id)
    }

    /// Synchronous-intent request (sibling of `requestSetAutoStart`): claims
    /// desired state, version, park-clear, the I4 gate drop, and the pass
    /// mode (I6) in the caller's synchronous context — the SwiftUI tap —
    /// then chains an already-started reconcile pass behind any predecessor.
    func requestSetUsageAlerts(_ enabled: Bool) -> Task<Void, Error> {
        alertsDesiredVersion += 1
        let version = alertsDesiredVersion
        alertsDesired = enabled
        alertsLifecycleParked = false
        if !enabled { alertsActive = false }
        let mode: AlertsReconcileMode = alertsHydrated ? .userRequest : .coldStartDeferred
        let prev = alertsLifecycleChain
        let task = Task { [self] in
            _ = await prev?.value
            try await reconcileAlertsPass(version: version, mode: mode)
        }
        alertsLifecycleChain = Task { _ = try? await task.value }
        return task
    }

    /// Compatibility wrapper — same shape as `setAutoStart`'s: forwards
    /// caller cancellation into the unstructured request Task.
    func setUsageAlertsEnabled(_ enabled: Bool) async throws {
        let task = requestSetUsageAlerts(enabled)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// One reconcile pass. Retry-until-current: a superseded pass returns
    /// silently — the newer request's own pass converges. See the spec's
    /// "The reconcile pass" section for the invariant-by-invariant walk.
    private func reconcileAlertsPass(version: Int, mode: AlertsReconcileMode) async throws {
        guard version == alertsDesiredVersion else { return }
        let desired = alertsDesired

        switch mode {
        case .userRequest, .coldStartDeferred:
            do {
                // Entry cancellation must PARK (spec v3/v4): parked is the
                // marker that keeps a startup pass from activating a desired
                // value that was never durably established.
                try Task.checkCancellation()
                try await appSettings.setUsageAlertsEnabled(desired)
            } catch {
                if version == alertsDesiredVersion {
                    alertsLifecycleParked = true
                }
                throw error
            }
            guard version == alertsDesiredVersion else { return }
            guard mode == .userRequest else { return }
            guard desired else {
                alertsActive = false
                return
            }
            let authorized = await notificationScheduler.requestAuthorization()
            guard version == alertsDesiredVersion else { return }
            usageAlertsAuthorized = authorized
            guard authorized else {
                alertsActive = false
                // Authorization gates POSTING, not evaluation. Prime anyway so
                // alert memory has a baseline from the moment alerts are
                // switched on, allowed to notify or not: the attention drop
                // does not need authorization, so its lifecycle must not
                // depend on it. `primeAllAlerts` posts nothing by
                // construction, so this cannot leak a notification.
                primeAllAlerts()
                return
            }
            primeAllAlerts()
            alertsActive = true

        case .startup:
            // I7: never writes the alerts setting. Parked converges only
            // when moot (desired agrees with the durable published value).
            // Priming below may still persist a snooze that a reset lifted.
            guard !alertsLifecycleParked || alertsDesired == appSettings.usageAlertsEnabled else { return }
            guard desired else {
                alertsActive = false
                return
            }
            let authorized = await notificationScheduler.authorizationStatus()
            guard version == alertsDesiredVersion else { return }
            usageAlertsAuthorized = authorized
            guard authorized else {
                alertsActive = false
                // Same rule as the denied branch above, and this is the pass
                // where it matters most. At launch the snapshot store has
                // already published, while the master switch still read off,
                // so the sink evaluated nothing. Without a prime here a reset
                // that happened while the app was closed goes unobserved until
                // a later refresh happens to publish, and a snooze it should
                // have lifted stays on. Posts nothing, by construction.
                primeAllAlerts()
                return
            }
            // I3 defense-in-depth: reaching this line means `version ==
            // alertsDesiredVersion` still held after the `authorizationStatus()`
            // await above, i.e. no request has claimed a newer version since
            // this pass captured its own. The only way `alertsActive` could
            // already be `true` here is a concurrent `.userRequest` pass
            // activating it — but claiming a request bumps
            // `alertsDesiredVersion` synchronously, at the tap, which would
            // have failed that very guard. This argument depends on there
            // being exactly ONE `.startup` pass per process: `load()` is
            // single-flight (see `loadStarted`), so a concurrent second
            // `load()` call returns immediately instead of spawning a
            // second startup reconcile pass that could otherwise legally
            // reach this line with `alertsActive` already `true` from the
            // first pass. Given that premise, `alertsActive` is structurally
            // guaranteed `false` on this line in the shipped wiring, and the
            // `if !alertsActive` check's "already active" (skip re-prime)
            // branch can never actually trigger — it is kept anyway as
            // defense-in-depth mandated by spec I3
            // ("startup-after-converged-enable does not re-prime") in case
            // future reordering ever reopens the window.
            if !alertsActive {
                primeAllAlerts()
                alertsActive = true
            }
        }
    }

    /// Test-support: awaits every alert side-effect (persist/post/remove)
    /// enqueued onto `alertSideEffectQueue` so far, so tests can
    /// deterministically assert on posted notifications / persisted state
    /// without polling. Implemented as a no-op barrier item chained onto the
    /// SAME queue — it only resolves once every item enqueued before it has
    /// run, per the queue's FIFO ordering — so there is no retained `Task`
    /// handle array to leak or clear; the queue itself is reused indefinitely
    /// across repeated flush cycles. No production caller needs this —
    /// the evaluation pipeline is intentionally fire-and-forget.
    func flushAlertEvaluations() async {
        try? await alertSideEffectQueue.run {}
    }

    /// Establishes the alert baseline for every account not mid-removal
    /// (paused accounts included — see the loop comment) WITHOUT
    /// posting: a SYNCHRONOUS loop over `decideAlerts(_, prime: true)` (see
    /// its doc — the loop has no `await` in it, so the sink cannot interleave
    /// a normal evaluation between prime-A and prime-B, and a concurrent
    /// removal cannot land mid-loop either), followed by the same best-effort
    /// persist side effect as a normal decision. Never posts, since
    /// `decideAlerts` always returns `[]` when priming. Called once
    /// authorization is confirmed — on enabling (`setUsageAlertsEnabled(true)`)
    /// and on `load()` when alerts are already enabled+authorized — so
    /// re-enabling or relaunching never replays a crossing that happened
    /// while alerts were off. Both call sites flip `alertsActive = true`
    /// themselves, synchronously, immediately AFTER this call returns — not
    /// inside this function — so the baseline is fully committed (and, best-
    /// effort, its persist enqueued) before the posting gate opens.
    private func primeAllAlerts() {
        // Deliberately NOT `refreshableAccounts`: priming never posts, so
        // paused accounts are safe to include — and they MUST be, or an
        // account paused at enable time gets no baseline and its pre-enable
        // crossing would post on resume. Only mid-removal accounts are
        // excluded (their state is being torn down).
        let primableAccounts = accounts.filter {
            !removingAccountIDs.contains($0.id)
        }
        for account in primableAccounts {
            // Not sink-driven — direct reads from the stores are accurate
            // here (no `willSet`-timing hazard; see the sink's doc comment).
            let decision = decideAlerts(
                accountID: account.id,
                provider: account.provider,
                snapshot: snapshotStore.snapshot(for: account.id),
                state: refreshCoordinator.state(for: account.id),
                prime: true
            )
            applyAlertDecision(
                accountID: account.id,
                label: account.label,
                events: decision.events,
                changed: decision.changed
            )
        }
    }

    /// Re-evaluates every refreshable account against the settings as they
    /// are RIGHT NOW, posting anything that newly qualifies.
    ///
    /// Alert evaluation is otherwise driven exclusively by the
    /// `snapshots`/`states` sink, but a threshold edit changes what counts as
    /// a crossing without touching either — so lowering a threshold below an
    /// account's current usage produced no evaluation at all. That is not
    /// merely a delay until the next poll: `primeAllAlerts()` runs on every
    /// `load()` where alerts are already enabled, and it COMMITS
    /// `notifiedTier` while deliberately posting nothing. A user who lowered
    /// a threshold and quit inside the poll window came back to a watermark
    /// that says "already notified" and never got the alert they configured.
    ///
    /// Deliberately NOT a watermark reset: this goes through the ordinary
    /// `decideAlerts` path, so the fire-once rule still applies. Lowering a
    /// threshold under current usage posts; raising one above current usage
    /// drops the effective tier but cannot re-post a lower tier the user has
    /// already moved past (`.warning > .critical` is false).
    ///
    /// Mirrors `primeAllAlerts()`'s direct store reads rather than the sink's
    /// delivered parameters: this is not sink-driven, so there is no
    /// `willSet`-timing hazard and the live stores are accurate. Uses
    /// `refreshableAccounts` (as the sink does, unlike priming) because this
    /// one DOES post, and a paused account must not alert.
    private func evaluateAlertsAfterThresholdChange() {
        guard alertsActive else { return }
        for account in refreshableAccounts {
            let decision = decideAlerts(
                accountID: account.id,
                provider: account.provider,
                snapshot: snapshotStore.snapshot(for: account.id),
                state: refreshCoordinator.state(for: account.id),
                prime: false
            )
            applyAlertDecision(
                accountID: account.id,
                label: account.label,
                events: decision.events,
                changed: decision.changed
            )
        }
    }

    /// Fully SYNCHRONOUS decision step: reads the current snapshot/state,
    /// evaluates the pure `AlertPolicy`, and COMMITS the result into
    /// `alertStates` before returning — no `await` anywhere in this function.
    /// Because `AppModel` is `@MainActor` (single-threaded) and this function
    /// has no suspension point, no other call to `decideAlerts` — for this
    /// account or any other, from the sink, `primeAllAlerts()`, or a
    /// concurrent `removeAccount` — can ever observe or interleave with a
    /// partially-applied decision. This is the structural property that
    /// eliminates the whole class of read-evaluate-persist ordering races the
    /// old `alertQueue` serialization patched around instead of removing.
    ///
    /// `prime` establishes the baseline (advances `alertStates` to the
    /// current tier/identity as already-notified) without ever returning
    /// events to post.
    ///
    /// Takes `snapshot`/`state` as PARAMETERS rather than reading
    /// `snapshotStore`/`refreshCoordinator` internally: when called from the
    /// sink, the caller must pass the values Combine just DELIVERED (see the
    /// sink's doc comment for why re-reading the live store there would
    /// observe a stale, pre-update value); when called from `primeAllAlerts`
    /// (not sink-driven), the caller passes a direct, accurate store read.
    ///
    /// The returned `changed` flag (`next != previous`, computed BEFORE the
    /// commit overwrites `alertStates`) tells `applyAlertDecision` whether
    /// this decision has any persisted-relevant effect at all — steady-state
    /// emissions (no new tier/window/reauth/rate-limit edge) reproduce the
    /// same state and should not enqueue a save (this bounds
    /// `alertSideEffectQueue` growth without a separate coalescing map; see
    /// its doc comment).
    private func decideAlerts(
        accountID: UUID,
        provider: Provider,
        snapshot: UsageSnapshot?,
        state: AccountViewState,
        prime: Bool
    ) -> (events: [AlertEvent], changed: Bool) {
        guard !alertTombstones.contains(accountID), appSettings.usageAlertsEnabled else {
            return ([], false)
        }
        let previous = alertStates[accountID] ?? AccountAlertState()
        // Synchronous property reads only — no suspension point may appear
        // between this read and the commit below (see this function's doc:
        // the whole read-evaluate-persist ordering guarantee depends on it).
        let settings = appSettings.data
        // Resets: never while priming (a primed baseline would mark a reset
        // "handled" without the user having been told — e.g. one that entered
        // its expiry window while Ration was closed), and only on a list the
        // snapshot's own fetch read. See `ResetCreditPolicy.input`.
        let resetInput = prime ? nil : ResetCreditPolicy.input(
            snapshot: snapshot,
            leadDays: settings.resetExpiryLeadDays(provider: provider),
            now: now()
        )
        let (events, next) = AlertPolicy.evaluate(
            previous: previous,
            snapshot: snapshot,
            state: state,
            thresholds: { window in settings.thresholds(provider: provider, window: window) },
            spendThresholds: settings.cursorSpend,
            resetCredits: resetInput
        )
        // Authoritative commit — synchronous, no suspension before or after
        // this line within this function.
        alertStates[accountID] = next
        // Checked against `events`, not the returned value: priming returns []
        // but still observes a reset, and a reset that happened while the app
        // was closed must lift the snooze on the next launch.
        endAttentionSnoozeIfNeeded(events: events, previous: previous, next: next, provider: provider)
        return (prime ? [] : events, next != previous)
    }

    /// Whether the per-cell Notification channel permits posting this event.
    ///
    /// An account that has since been removed resolves to `true`: the other
    /// guards in the post path already drop those, and defaulting to "allow"
    /// here keeps this function about channels only.
    private func notificationChannelAllows(_ event: AlertEvent, accountID: UUID) -> Bool {
        guard let provider = accounts.first(where: { $0.id == accountID })?.provider else {
            return true
        }
        guard let key = AlertChannelKey.forEvent(event, provider: provider) else { return true }
        return appSettings.data.channels(forKey: key).notification
    }

    // MARK: - Attention drop

    /// What is over a configured threshold right now, for the menu-bar drop.
    ///
    /// DERIVED on every call rather than held: the panel asks on each tick, so
    /// a window that resets, a threshold the user edits, or quiet hours
    /// starting all take effect without anything having to invalidate a cached
    /// row set. See `AttentionDropModel`.
    func attentionRows(now: Date = Date()) -> [AttentionRow] {
        // Snoozed by the ✕ until something actually changes — see
        // `snoozeAttentionDrop`.
        guard !appSettings.data.dropSnoozed else { return [] }
        return AttentionDropModel.rows(
            presentations: presentations,
            settings: appSettings.data,
            alertStates: alertStates,
            schedule: warmUpSchedule,
            now: now
        )
    }

    /// Dismisses rows from the drop until their window resets.
    ///
    /// SYNCHRONOUS, and routed through `AppModel` rather than letting the panel
    /// write `AlertStateStore` directly: a direct write races account removal
    /// and can resurrect state for an account that no longer exists. This
    /// commits in memory with no `await` between read and write — the same
    /// discipline as `decideAlerts` — then enqueues the save on
    /// `alertSideEffectQueue`, which re-checks the tombstone at EXECUTION time.
    ///
    /// Records the dismissal at the row's own tier, so a later escalation
    /// (`critical > warning`) still raises a fresh row.
    /// The ✕: stop showing the drop until something actually changes.
    ///
    /// Deliberately NOT "hide these rows" for LIMIT rows (window/Cursor
    /// spend). Per-row dismissal alone let the panel come back minutes later
    /// the moment a different window crossed — which reads as the ✕ not
    /// working. Those stay governed purely by the global snooze, lifted only
    /// by a reset on any window of any account, which is the point at which
    /// the picture is genuinely different.
    ///
    /// Reset-credit rows are the deliberate exception: they ARE acknowledged
    /// per-row here (by reusing `dismissAttentionRows`), because they are
    /// informational rather than a limit. Left ungoverned, a dismissed reset
    /// row would come straight back the instant ANY window on ANY account
    /// reset — which happens routinely — and would keep coming back for as
    /// long as ~30 days, until the credit itself expires or is used. A later
    /// count increase or the expiring alert still re-activates the row, same
    /// as any other dismissal (see `ResetCreditPolicy.evaluate`).
    ///
    /// The flag is committed to the in-memory settings snapshot SYNCHRONOUSLY
    /// so the panel closes on this turn of the run loop; the persist is the
    /// usual best-effort side effect.
    func snoozeAttentionDrop(_ rows: [AttentionRow]) {
        dismissAttentionRows(rows.filter(\.isResetCredit))
        appSettings.setDropSnoozedInMemory(true)
        Task { [weak self] in
            try? await self?.appSettings.setDropSnoozed()
        }
    }

    /// Lifts the snooze. Called when any account reports a window reset or a
    /// new/expiring usage-limit reset — genuinely new information.
    ///
    /// A window `.reset` always qualifies: it has no delivery-channel cell
    /// (see `AlertChannelKey`) and the ✕ contract already promises it ends
    /// the snooze unconditionally. A `.resetCreditAvailable`/
    /// `.resetCreditExpiring` event, though, IS governed by a cell — this
    /// account's provider's "Resets" drop channel — so it may only lift the
    /// snooze when that channel is on; otherwise a user who silenced resets
    /// on the drop would see their ✕ undone by an event they asked not to
    /// hear about on the drop at all.
    private func endAttentionSnoozeIfNeeded(
        events: [AlertEvent],
        previous: AccountAlertState,
        next: AccountAlertState,
        provider: Provider
    ) {
        guard appSettings.data.dropSnoozed else { return }
        let resetCreditsDropOn = appSettings.data.channels(
            forKey: AppSettingsData.resetCreditsKey(provider: provider)
        ).drop
        let somethingNew = events.contains { event in
            switch event {
            case .reset: true
            case .resetCreditAvailable, .resetCreditExpiring: resetCreditsDropOn
            default: false
            }
        }
        // Cursor has no rate window and emits no `.reset` — its rollover only
        // clears spend memory. Without this a spend-only user could dismiss the
        // drop and never see it again: the one reset they ever get would not
        // count, and there is no manual un-snooze. Decided by `AlertPolicy`,
        // the same rule the re-arm uses — keying on `periodEnd` here undid the
        // ✕ on every poll once Cursor started reporting it as "now".
        let spendRollover = AlertPolicy.spendPeriodAdvanced(
            from: previous.spend,
            toStart: next.spend.periodStart
        )
        guard somethingNew || spendRollover else { return }
        appSettings.setDropSnoozedInMemory(false)
        Task { [weak self] in
            try? await self?.appSettings.setDropSnoozed()
        }
    }

    func dismissAttentionRows(_ rows: [AttentionRow]) {
        var touched: Set<UUID> = []
        for row in rows where !alertTombstones.contains(row.accountID) {
            guard accounts.contains(where: { $0.id == row.accountID }) else { continue }
            var state = alertStates[row.accountID] ?? AccountAlertState()
            switch row.subject {
            case .window(.fiveHour): state.fiveHour.dismissedTier = row.tier
            case .window(.weekly): state.weekly.dismissedTier = row.tier
            case .window(.modelWeekly): state.modelWeekly.dismissedTier = row.tier
            case .cursorSpend: state.spend.dismissedTier = row.tier
            case let .resetCredit(id, kind):
                // A grouped row (see `AttentionDropModel.rows`) folds several
                // credits into one; `subject`'s id is only the soonest-
                // expiring MEMBER. Acknowledge every id the row actually
                // shows, falling back to the subject id for a row built
                // directly with an empty list (the pre-grouping shape).
                let ids = row.resetCreditIDs.isEmpty ? [id] : row.resetCreditIDs
                for creditID in ids {
                    guard var entry = state.resetCredits[creditID] else { continue }
                    switch kind {
                    case .available: entry.availableRow = .dismissed
                    case .expiring: entry.expiringRow = .dismissed
                    }
                    state.resetCredits[creditID] = entry
                }
            }
            alertStates[row.accountID] = state
            touched.insert(row.accountID)
        }

        for accountID in touched {
            let committed = alertStates[accountID] ?? AccountAlertState()
            alertSideEffectQueue.enqueue { [weak self] in
                guard let self, !self.alertTombstones.contains(accountID) else { return }
                try? await self.alertStateStore.save(committed, for: accountID)
            }
        }
    }

    /// Best-effort SIDE EFFECTS of an already-committed `decideAlerts`
    /// decision: persisting the new authoritative state and posting any
    /// events. Both are enqueued onto `alertSideEffectQueue` — items that
    /// only ever READ the already-committed decision — neither can feed back
    /// into `alertStates`, so a failed save or a slow post can never cause a
    /// duplicate or missed evaluation. Because the in-memory commit already
    /// happened synchronously in `decideAlerts` (which always ran
    /// immediately before this call, with no suspension in between), a
    /// repeat emission for the same unchanged crossing produces
    /// `events == []` (the edge-trigger already advanced) → no re-post even
    /// if an earlier save failed. This is the key correctness property: a
    /// failed persist cannot cause a re-post, because authoritative state
    /// does not live in the store.
    ///
    /// Both items re-check the state they depend on AT EXECUTION TIME (i.e.
    /// after `await previous.value` inside the queue, not at the moment this
    /// function enqueues them), since enqueue time and execution time can be
    /// separated by an arbitrary suspension window in which a disable, a
    /// removal, or a pause lands:
    /// - The save item skips if `alertTombstones` has since gained this
    ///   `accountID` — belt-and-suspenders on top of the FIFO-ordering
    /// guarantee that `removeAccount`'s own enqueued `remove` always
    ///   runs after any save enqueued before it.
    /// - The post item skips unless `alertsActive` is (still) `true` AND the
    ///   account is neither tombstoned NOR CURRENTLY BEING REMOVED. The
    ///   `removingAccountIDs` check matters because `removeAccount` only
    ///   tombstones at its very END — after several `await`s (cancel
    ///   refresh, remove snapshot/account/profile, remove history) — each of
    ///   which is a suspension point where this already-enqueued post could
    ///   otherwise get its turn on the main actor and post for an account
    ///   that's mid-removal, before the tombstone lands. `removingAccountIDs`
    ///   is inserted SYNCHRONOUSLY as `removeAccount`'s very first statement
    ///   (before any `await`), so — exactly like `alertsActive` for a
    ///   disable — there is no suspension window in which a removal can be
    ///   "in flight" without this check observing it. (If the removal later
    ///   rolls back, the suppressed post simply never fires — the underlying
    ///   decision remains correctly recorded in `alertStates`; an
    ///   acceptable, deliberate trade-off for an already-narrow edge case.)
    /// - The post item ALSO skips when the account is being paused: either
    ///   `pausingAccountIDs` contains it (a pause is in flight — see that
    ///   property's doc) OR its CURRENT record (re-read from `accounts`, not
    ///   captured at enqueue time) already has `isPaused == true` (a pause
    ///   completed some time ago). A paused account must be fully dormant,
    ///   no exceptions for a post that was already in flight when the pause
    ///   landed. `pausingAccountIDs` is what actually closes the race —
    ///   inserted SYNCHRONOUSLY as `requestSetPaused`'s first statement
    ///   (before any `await`), exactly like `removingAccountIDs` for
    ///   removal, so there is no suspension window in which a pause can be
    ///   "in flight" without this check observing it; the `isPaused` re-read
    ///   is belt-and-suspenders for the (already dormant, so harmless)
    ///   case where the marker has since been cleared. This deliberately
    ///   does NOT test the generic `mutatingAccountIDs` marker — that one is
    ///   shared with unrelated mutations (rename, auto-start toggle, billing
    ///   day), and using it here would wrongly swallow a legitimate alert
    ///   for an in-flight mutation that isn't a pause at all.
    ///
    /// `changed` (from `decideAlerts`) gates the save: it is
    /// enqueued only when the decision actually altered the account's
    /// persisted-relevant state. A steady-state emission (`changed == false`)
    /// enqueues nothing at all for the save — not even a skipped/no-op item —
    /// so repeated identical emissions cannot grow the queue. This is safe
    /// precisely because `changed` is derived from the SAME synchronous
    /// commit `applyAlertDecision` is always called with — there is no
    /// suspension between `decideAlerts` computing it and this call reading
    /// it, so it can never be stale relative to `alertStates`.
    private func applyAlertDecision(
        accountID: UUID,
        label: String,
        events: [AlertEvent],
        changed: Bool
    ) {
        if changed {
            let committed = alertStates[accountID] ?? AccountAlertState()
            alertSideEffectQueue.enqueue { [weak self] in
                guard let self, !self.alertTombstones.contains(accountID) else { return }
                try? await self.alertStateStore.save(committed, for: accountID)
            }
        }

        for event in events {
            let notificationID = AlertMessage.id(for: event, accountID: accountID)
            alertSideEffectQueue.enqueue { [weak self] in
                guard
                    let self,
                    self.alertsActive,
                    // The per-cell notification channel. Resolved at EXECUTION
                    // time like every other gate here, so toggling the checkbox
                    // while an item waits behind earlier side effects is
                    // honoured. `nil` key = no cell governs this event (reset,
                    // reauth, rate-limit) — those always deliver.
                    self.notificationChannelAllows(event, accountID: accountID),
                    !self.alertTombstones.contains(accountID),
                    !self.removingAccountIDs.contains(accountID),
                    !self.pausingAccountIDs.contains(accountID),
                    self.accounts.first(where: { $0.id == accountID })?.isPaused != true
                else { return }
                // Read the privacy flag and render the copy HERE, at post
                // time — not at enqueue time. A user who enables "hide account
                // details" while this item waits behind earlier side effects
                // must not have the already-rendered label/percentage posted.
                let (title, body) = AlertMessage.text(
                    for: event,
                    accountLabel: label,
                    redacted: self.appSettings.redactNotifications
                )
                await self.notificationScheduler.post(
                    id: notificationID,
                    title: title,
                    body: body
                )
            }
        }
    }

    #if DEBUG
    /// Test-only: exposes the committed authoritative alert state for the
    /// given account, so tests can assert directly on the in-memory source
    /// of truth — e.g. proving `removeAccount`'s tombstone makes resurrection
    /// structurally impossible (`alertStateForTesting(accountID:) == nil`
    /// even after a subsequent sink emission), not just empirically absent
    /// from the persisted mirror.
    func alertStateForTesting(accountID: UUID) -> AccountAlertState? {
        alertStates[accountID]
    }

    /// Test-only: exposes the synchronous posting/activation gate so tests
    /// can assert directly on the reconciler's version-guarded pass outcome
    /// (e.g. that a stale enable pass did NOT reactivate alerts after a
    /// newer disable completed), not just its downstream posting behavior.
    func alertsActiveForTesting() -> Bool {
        alertsActive
    }

    /// Test-only: exposes the startup readiness barrier (see
    /// `alertsHydrated`'s doc) so tests can assert directly that it is still
    /// closed at a given interleave point (e.g. immediately after an enable
    /// that deferred to `load()`'s tail), not just infer it from
    /// `alertsActiveForTesting()` staying `false`.
    func alertsHydratedForTesting() -> Bool {
        alertsHydrated
    }

    /// Test-only: profile IDs whose WebView is currently cached, so a test
    /// can assert an idle WebView was released and a busy one was kept.
    func cachedWebViewProfileIDsForTesting() -> Set<UUID> {
        sessionManager.cachedProfileIDs
    }

    /// Test-only: see `AccountSessionManager.replaceWebViewForTesting`.
    func replaceWebViewForTesting(profileID: UUID, with webView: WKWebView) {
        sessionManager.replaceWebViewForTesting(profileID: profileID, with: webView)
    }

    /// Development-only: fire the keep-alive send on demand (bypassing the reset
    /// policy) to validate the real completion request against Claude. Reports
    /// the exact outcome via `errorMessage`.
    func debugSendKeepAlive(accountID: UUID) async {
        guard
            let account = accounts.first(where: { $0.id == accountID }),
            account.provider == .claude
        else {
            errorMessage = "Debug send: not a Claude account."
            return
        }
        guard !sendingKeepAliveAccountIDs.contains(account.id) else {
            errorMessage = "Debug send: already sending for this account."
            return
        }
        sendingKeepAliveAccountIDs.insert(account.id)
        defer { sendingKeepAliveAccountIDs.remove(account.id) }
        errorMessage = "Debug send: warming session…"
        do {
            // Bind the debug send to the warm-up snapshot's org when it
            // succeeded; a failed warm-up falls back to live discovery (nil),
            // which matches the user's manual send-now intent.
            let warmUpSnapshot = try? await sessionManager.fetchUsage(for: account)
            let prepared = try await sessionManager.prepareKeepAlive(
                for: account,
                boundToOrganizationID: warmUpSnapshot?.organizationID
            )
            let conversationID = try await sessionManager.sendKeepAlive(
                prepared: prepared,
                conversationID: account.keepAliveConversationID,
                for: account
            )
            try await accountStore.recordAutoStart(
                id: account.id,
                conversationID: conversationID,
                at: now()
            )
            if let refreshed = try? await sessionManager.fetchUsage(for: account) {
                try? await snapshotStore.save(refreshed)
            }
            errorMessage = "Debug send OK · model \(prepared.model) · conv "
                + "\(conversationID.uuidString.prefix(8)). Check Claude for the message."
        } catch let error as ClaudeMessageSender.SendError {
            errorMessage = "Debug send FAILED: \(error)"
        } catch {
            errorMessage = "Debug send FAILED: \(error.localizedDescription)"
        }
    }
    #endif

    static func live(
        adapters: [any ProviderAdapter] = [],
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        contractRecorder: ProviderContractRecorder? = nil,
        baseDirectory: URL? = nil
    ) -> AppModel {
        let baseDirectory = baseDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appending(path: "Ration", directoryHint: .isDirectory)

        let captureErrorRelay = ProviderContractCaptureErrorRelay()
        let model = AppModel(
            accountStore: AccountStore(
                fileURL: baseDirectory.appending(path: "accounts.json")
            ),
            snapshotStore: UsageSnapshotStore(
                fileURL: baseDirectory.appending(path: "snapshots.json")
            ),
            pendingProfileDeletionStore: PendingProfileDeletionStore(
                fileURL: baseDirectory.appending(path: "pending-profile-deletions.json")
            ),
            historyStore: UsageHistoryStore(
                rootDirectory: baseDirectory.appending(path: "history", directoryHint: .isDirectory)
            ),
            appSettings: AppSettings(
                fileURL: baseDirectory.appending(path: "app-settings.json")
            ),
            alertStateStore: AlertStateStore(
                fileURL: baseDirectory.appending(path: "alert-state.json")
            ),
            profileManager: WebProfileManager(
                contractRecorder: contractRecorder,
                onContractRecordingError: { message in
                    captureErrorRelay.report(message)
                }
            ),
            adapterRegistry: ProviderAdapterRegistry(adapters: adapters),
            messageSender: messageSender
        )
        captureErrorRelay.model = model
        return model
    }

    func load(startBackgroundRefresh: Bool = true) async throws {
        guard !loadStarted else { return }
        loadStarted = true
        do {
            try await accountStore.load()
            try await snapshotStore.load()
            try await pendingProfileDeletionStore.load()
            // Journal any web profiles orphaned by dedup on load (a
            // mis-migrated accounts.json dropped their owning record) so
            // `retryProfileCleanup` below deletes their stranded, authenticated
            // cookie stores. These are, by construction, referenced by no live
            // account, so the cleanup live-reference guard will not revoke them.
            //
            // MUST run AFTER `pendingProfileDeletionStore.load()`: enqueue merges
            // into the store's in-memory set and rewrites the whole file, so
            // enqueueing onto a not-yet-loaded (empty) store would overwrite — and
            // permanently strand — any existing journal entry from an interrupted
            // account removal.
            for profileID in accountStore.orphanedProfileIDsFromLoad {
                try? await pendingProfileDeletionStore.enqueue(profileID)
            }
            // Publish the queue the moment it is final for startup, BEFORE any
            // further throwing load step. `retryProfileCleanup` below would
            // publish it too, but a failure in between (a corrupt settings file,
            // say) aborts `load()` and would otherwise leave the flags false —
            // hiding the retry control while cleanup is genuinely owed.
            updateProfileCleanupState()
            try await appSettings.load()
            // The one unraceable instant for the first-run decision: both files
            // have just been read, and nothing the user could have done since
            // launch can yet have committed an account. See `isOnboardingOwed`.
            isOnboardingOwed = OnboardingFlow.shouldPresentAtLaunch(
                hasCompletedOnboarding: appSettings.hasCompletedOnboarding,
                accountCount: accounts.count,
                settingsLoadFailed: appSettings.loadFailed
            )
            // Non-fatal. A corrupt/unreadable alert-state file must never
            // abort startup — history load, background refresh, and launch
            // refresh must all proceed regardless. Worst case, `alertStates`
            // seeds empty and every account restarts from a blank baseline
            // (re-primed below when alerts are already enabled+authorized).
            try? await alertStateStore.load()
            // Seed the in-memory authoritative map from whatever the store
            // managed to load (empty on a fresh install or after a swallowed
            // load failure above), filtered to currently-active accounts. This
            // is the ONE-TIME, WHOLESALE seed of `alertStates` for this
            // session — it happens here, strictly before `alertsHydrated` can
            // ever become `true` (see its doc), so no concurrent prime (from a
            // deferred enable, or from this very function's own tail below) can
            // ever be clobbered by it: nothing else in this class assigns to
            // `alertStates` wholesale again — `decideAlerts` only ever merges a
            // single account's entry (`alertStates[accountID] = next`). From
            // this point on, `alertStateStore` is read-only for evaluation
            // purposes — `alertStates` is the source of truth for the rest of
            // the session.
            let activeAccountIDs = Set(accountStore.accounts.map(\.id))
            alertStates = alertStateStore.states.filter { activeAccountIDs.contains($0.key) }
            // Self-heal any persisted alert-state entry
            // left orphaned by a session that ended between `removeAccount`'s
            // synchronous tombstone and its (best-effort, async) store removal
            // completing — e.g. a crash or force-quit mid-flush. Mirrors how
            // `UsageHistoryStore.load` prunes orphan account directories on
            // startup. Best-effort: a failure here just leaves a harmless orphan
            // entry in the store for the next launch to retry.
            for orphanID in alertStateStore.states.keys where !activeAccountIDs.contains(orphanID) {
                try? await alertStateStore.remove(accountID: orphanID)
            }

            // STARTUP READINESS BARRIER (see `alertsHydrated`'s doc). Everything
            // the alert pipeline depends on — accounts, snapshots, and the
            // one-time `alertStates` seed above — has now loaded, with alerts
            // fully inert throughout: `alertsHydrated` is still `false`, so any
            // concurrent `setUsageAlertsEnabled(true)` racing this function
            // could only persist its desired setting and defer (see that
            // function's doc), never prime or activate against this
            // not-yet-fully-loaded state. `beforeAlertsHydrationCompletes` is a
            // no-op in production; tests use it to pin a deterministic
            // interleave exactly at this boundary.
            await beforeAlertsHydrationCompletes()

            // Seed-and-kick (spec: "load() tail"): load() no longer owns
            // activation — the startup reconcile pass does. Seed the desired
            // state from the loaded setting only if no tap claimed it first.
            if alertsDesiredVersion == 0 {
                alertsDesired = appSettings.usageAlertsEnabled
            }
            alertsHydrated = true
            let version = alertsDesiredVersion
            let prev = alertsLifecycleChain
            let startup = Task { [self] in
                _ = await prev?.value
                try? await reconcileAlertsPass(version: version, mode: .startup)
            }
            alertsLifecycleChain = Task { _ = await startup.value }
            // The baseline must be primed before launch refresh can drive
            // the sink. Everything ahead of this pass in the chain is
            // .coldStartDeferred (persist-only, prompt-free), so this await is
            // bounded by settings-save round-trips.
            _ = await startup.value

            await historyStore.load(activeAccountIDs: Set(accountStore.accounts.map(\.id)))
            await retryProfileCleanup()
            await performLaunchProfileHygiene()
            // Begin observing sleep / memory-pressure to release idle WebViews.
            systemPowerObserver.start()

            guard startBackgroundRefresh else { return }
            refreshCoordinator.startBackgroundRefresh { [weak self] in
                self?.refreshableAccounts ?? []
            }
            await refreshAll(reason: .launch)
        } catch {
            // A thrown launch failure means this attempt never completed —
            // release the single-flight claim so a subsequent `load()` call
            // (e.g. a user-triggered retry after a startup error) can run
            // the body again instead of being silently swallowed by the
            // guard above.
            loadStarted = false
            throw error
        }
    }

    func start() async {
        do {
            try await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        refreshCoordinator.stopBackgroundRefresh()
        systemPowerObserver.stop()
    }

    func snapshot(for accountID: UUID) -> UsageSnapshot? {
        snapshotStore.snapshot(for: accountID)
    }

    /// Passkey-only OpenAI accounts cannot complete WebAuthn inside the
    /// embedded sign-in web view (restricted Apple entitlement — see
    /// `ChatGPTSessionCookiePaste`), so the sign-in window accepts the
    /// session cookie pasted from the user's real browser. Cookies land in
    /// the SESSION's own isolated profile store — the exact store its
    /// fetches read — and the page reloads so the user can SEE the session
    /// before committing; `completeSignIn`'s `verifySession` remains the
    /// authority on whether it actually works.
    func applyPastedSessionCookies(sessionID: UUID, raw: String) async throws {
        guard let session = signInSessions[sessionID] else {
            throw ProviderError.integrationChanged
        }
        guard session.provider == .chatGPT else {
            throw SessionCookiePasteError.unsupportedProvider
        }
        let parsed = ChatGPTSessionCookiePaste.parse(raw)
        guard !parsed.isEmpty else {
            throw SessionCookiePasteError.nothingToApply
        }
        // A paste that carries pairs but not the actual credential would
        // otherwise report success while installing no authentication at all.
        // Chunked session tokens (`…session-token.0/.1`) count — the server
        // reassembles them.
        guard parsed.contains(where: { ChatGPTSessionCookiePaste.isSessionTokenName($0.name) }) else {
            throw SessionCookiePasteError.missingSessionToken
        }
        // Serialized per session and awaited by `completeSignIn`, so a verify
        // can never race a half-written token: whatever verify validates is
        // exactly what was installed.
        let token = UUID()
        let previous = pendingCookieApplications[sessionID]?.task
        cookieApplicationGenerations[sessionID, default: 0] += 1
        // Deliberately the REAL clock, not the injected one: cookie-jar
        // expiry is compared against wall-clock time inside WebKit, so a
        // synthetic test clock would build pre-expired cookies that
        // `setCookie` silently drops.
        let cookies = ChatGPTSessionCookiePaste.cookies(from: parsed, now: Date.now)
        let application = Task { @MainActor in
            await previous?.value
            let cookieStore = session.webView.configuration.websiteDataStore.httpCookieStore
            for cookie in cookies {
                await cookieStore.setCookie(cookie)
            }
            session.webView.load(URLRequest(url: session.signInURL))
        }
        pendingCookieApplications[sessionID] = (token: token, task: application)
        await application.value
        if pendingCookieApplications[sessionID]?.token == token {
            pendingCookieApplications.removeValue(forKey: sessionID)
        }
    }

    func signInSession(for sessionID: UUID) -> SignInSession? {
        signInSessions[sessionID]
    }

    func beginSignIn(provider: Provider) throws -> UUID {
        let session = try sessionManager.makeSignInSession(
            provider: provider,
            accountID: UUID(),
            webProfileID: UUID(),
            isNewAccount: true,
            initialLabel: provider.displayName
        )
        signInSessions[session.id] = session
        return session.id
    }

    func beginReauthentication(accountID: UUID) throws -> UUID {
        guard !removingAccountIDs.contains(accountID) else {
            throw AccountStoreError.operationInProgress
        }
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountStoreError.accountNotFound
        }
        if let existing = signInSessions.values.first(where: {
            !$0.isNewAccount && $0.accountID == accountID
        }) {
            return existing.id
        }

        let session = try sessionManager.makeSignInSession(
            provider: account.provider,
            accountID: account.id,
            webProfileID: account.webProfileID,
            isNewAccount: false,
            initialLabel: account.label
        )
        signInSessions[session.id] = session
        return session.id
    }

    func completeSignIn(sessionID: UUID, label: String) async throws {
        // EVERY exit republishes. The cleanup indicator is derived partly from
        // `accounts`, and a commit changes `accounts` without any cleanup path
        // running: a cancelled sign-in that failed to journal AND failed to delete
        // keeps its session, so the profile this account ends up referencing may
        // still be queued. That applies to the failure exits too — notably the one
        // where the account was added but the snapshot save AND its rollback both
        // failed, leaving the account live. The queue entry itself is revoked by the
        // next cleanup pass, exactly as `skipOrRevokeProfileCleanup` already does
        // for live references; this only drops the stale warning.
        defer { updateProfileCleanupState() }

        guard let session = signInSessions[sessionID] else {
            throw ProviderError.integrationChanged
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            throw AccountStoreError.emptyLabel
        }

        // A pasted-cookie write still in flight must land before verification
        // — verify decides on exactly the credential state the user created.
        // The GENERATION snapshot (taken after the await, so it includes the
        // awaited apply) is re-checked after every later suspension: any
        // apply landing mid-verification means the verified credential state
        // is no longer the installed one, and the commit is refused. The UI
        // disables Apply during verification; this is the model-side
        // guarantee if that gate is ever bypassed.
        // Snapshot BEFORE the await: an application registering behind the
        // awaited one has already bumped the generation, and counting it into
        // the snapshot would whitewash its still-in-flight write. Any bump
        // after this line — whenever it lands — refuses the commit.
        let cookieGeneration = cookieApplicationGenerations[session.id]
        await pendingCookieApplications[session.id]?.task.value
        // The await suspended: the session may have been canceled meanwhile.
        try requireActive(session)
        try await sessionManager.verify(session)
        guard cookieApplicationGenerations[session.id] == cookieGeneration else {
            throw AccountStoreError.operationInProgress
        }
        try requireActive(session)
        let account = AccountRecord(
            id: session.accountID,
            provider: session.provider,
            label: trimmedLabel,
            webProfileID: session.webProfileID,
            displayOrder: session.isNewAccount ? accounts.count : existingOrder(session),
            createdAt: session.isNewAccount ? now() : existingCreatedAt(session),
            autoStartFiveHour: session.isNewAccount
                && WarmUpDefaults.autoStartForNewAccount(provider: session.provider)
        )
        let snapshot = try await sessionManager.fetchUsage(for: account)
        try requireActive(session)
        // fetchUsage suspended too — the same no-apply-since-verification
        // guarantee must hold right up to the commit.
        guard cookieApplicationGenerations[session.id] == cookieGeneration else {
            throw AccountStoreError.operationInProgress
        }
        guard snapshot.accountID == account.id else {
            throw ProviderError.integrationChanged
        }
        try claimCommit(session)
        await beforeSignInPersistence()

        do {
            if session.isNewAccount {
                try await accountStore.add(account)
                do {
                    try await snapshotStore.save(snapshot)
                    historyStore.record(account: account, snapshot: snapshot)
                } catch {
                    let snapshotError = error
                    do {
                        try await accountStore.remove(id: account.id)
                    } catch {
                        throw AccountCommitError.rollbackFailed
                    }
                    throw snapshotError
                }
            } else {
                try await snapshotStore.save(snapshot)
                historyStore.record(account: account, snapshot: snapshot)
                try await accountStore.rename(id: account.id, label: trimmedLabel)
            }
        } catch {
            committingSessionIDs.remove(sessionID)
            if !session.isNewAccount {
                mutatingAccountIDs.remove(session.accountID)
            }
            if
                error is AccountCommitError,
                session.isNewAccount,
                accounts.contains(where: { $0.id == session.accountID })
            {
                cancelRequestedSessionIDs.remove(sessionID)
                signInSessions.removeValue(forKey: sessionID)
                pruneSessionBookkeeping()
                // This session may have been protecting a profile
                // whose timeout recycle was deferred.
                sessionManager.completeDeferredRecycles()
                errorMessage = error.localizedDescription
            } else if cancelRequestedSessionIDs.remove(sessionID) != nil {
                await cancelSignIn(sessionID: sessionID)
            }
            throw error
        }

        committingSessionIDs.remove(sessionID)
        if !session.isNewAccount {
            mutatingAccountIDs.remove(session.accountID)
        }
        cancelRequestedSessionIDs.remove(sessionID)
        signInSessions.removeValue(forKey: sessionID)
        pruneSessionBookkeeping()
        // This session may have been protecting a profile whose
        // timeout recycle was deferred.
        sessionManager.completeDeferredRecycles()
        await refreshCoordinator.cancel(accountID: account.id)
    }

    /// Drops per-session bookkeeping for sessions that no longer exist. Entries are
    /// keyed by one-shot session UUIDs, so stale ones are inert — a fresh session can
    /// never collide with one. Hygiene, not correctness.
    private func pruneSessionBookkeeping() {
        pendingCookieApplications = pendingCookieApplications.filter {
            signInSessions[$0.key] != nil
        }
        cookieApplicationGenerations = cookieApplicationGenerations.filter {
            signInSessions[$0.key] != nil
        }
        cancelledSessionIDsPendingCleanup = cancelledSessionIDsPendingCleanup.filter {
            signInSessions[$0] != nil
        }
    }

    func cancelSignIn(sessionID: UUID) async {
        guard let session = signInSessions[sessionID] else { return }
        if committingSessionIDs.contains(sessionID) {
            cancelRequestedSessionIDs.insert(sessionID)
            return
        }
        guard !cancellingSessionIDs.contains(sessionID) else { return }
        cancellingSessionIDs.insert(sessionID)
        defer { cancellingSessionIDs.remove(sessionID) }

        guard session.isNewAccount else {
            signInSessions.removeValue(forKey: sessionID)
            pruneSessionBookkeeping()
            // This session may have been protecting a profile whose
            // timeout recycle was deferred (e.g. the reauth case).
            sessionManager.completeDeferredRecycles()
            return
        }

        if accounts.contains(where: { $0.id == session.accountID }) {
            signInSessions.removeValue(forKey: sessionID)
            pruneSessionBookkeeping()
            sessionManager.completeDeferredRecycles()
            return
        }

        await cleanUpNewSignIn(session)
        pruneSessionBookkeeping()
    }

    /// Launch hygiene for the WebKit profiles, run once per launch after the
    /// deletion journal has been reconciled and BEFORE any web view exists.
    ///
    /// Two jobs, both of which nothing else in the app ever did:
    ///
    /// - **The HTTP cache is per-session, not forever.** Nothing purged it, so it
    ///   accumulated across every launch — measured at 355 MB of `NetworkCache` for
    ///   five accounts whose entire job is fetching a small usage document. Purging
    ///   here rather than on a size threshold keeps this free of WebKit's on-disk
    ///   layout, and caching still works normally *within* a session, which is where
    ///   the repeated polls are.
    /// - **A store no account owns is dead weight.** Cancelled and interrupted
    ///   sign-ins leave identified stores behind whenever the deletion intent does
    ///   not survive (a force quit, a crash), and neither the journal nor the
    ///   dedup pass can see them: they are known to WebKit and to nothing else.
    ///
    /// Ordering matters. The purge runs first because it constructs each live store,
    /// which is what warms WebKit for the static identifier APIs the sweep needs —
    /// those trap when called from a cold process. With no accounts there is nothing
    /// to construct, so the sweep is skipped rather than risk that trap; the next
    /// launch with an account picks up any orphans.
    private func performLaunchProfileHygiene() async {
        let liveProfileIDs = Set(accounts.map(\.webProfileID))
        guard !liveProfileIDs.isEmpty else { return }

        for profileID in liveProfileIDs {
            await sessionManager.purgeDiskCache(profileID: profileID)
        }
        lastCachePurgeAt = now()

        for profileID in await sessionManager.existingProfileIdentifiers() {
            // Re-evaluated fresh on every iteration, never from a snapshot taken
            // before this suspending loop: the user can start a sign-in or a removal
            // while it runs, and either would make a profile un-sweepable.
            guard isSweepableProfile(profileID) else { continue }
            try? await sessionManager.removeProfile(profileID: profileID)
        }
    }

    /// Whether this store belongs to nobody at all. Every claim on a profile counts,
    /// including ones with no account yet (an in-progress sign-in) and ones already
    /// spoken for by the deletion machinery, which must drive its own deletion so its
    /// journal and rollback stay consistent.
    private func isSweepableProfile(_ profileID: UUID) -> Bool {
        !accounts.contains { $0.webProfileID == profileID }
            && !signInSessions.values.contains { $0.webProfileID == profileID }
            && !profileIDsBeingRemoved.contains(profileID)
            && !pendingProfileDeletionStore.profileIDs.contains(profileID)
            && !volatileProfileDeletionIDs.contains(profileID)
    }

    func retryProfileCleanup() async {
        let profileIDs = pendingProfileDeletionStore.profileIDs
            .union(volatileProfileDeletionIDs)

        for profileID in profileIDs {
            // Liveness/ownership are re-evaluated FRESH on every iteration and
            // AGAIN immediately before the irreversible delete below — never
            // from a snapshot taken before this suspending loop. A concurrent
            // account removal can roll back mid-loop (restoring an account,
            // re-making its profile live, and releasing its in-flight marker)
            // during one of this loop's `await`s; acting on a stale snapshot
            // would then delete that restored, authenticated profile.
            if await skipOrRevokeProfileCleanup(profileID) {
                continue
            }

            var isDurable = pendingProfileDeletionStore.profileIDs.contains(profileID)
            if !isDurable {
                do {
                    try await pendingProfileDeletionStore.enqueue(profileID)
                    isDurable = true
                    volatileProfileDeletionIDs.remove(profileID)
                } catch {
                    volatileProfileDeletionIDs.insert(profileID)
                }
            }

            if isDurable {
                removeSignInSessions(profileID: profileID)
            }

            // Test-only interleave point (no-op in production): lets a test land
            // a rollback that restores this profile's account right here, so the
            // FINAL re-check below is exercised deterministically.
            await beforeProfileCleanupDeletion(profileID)

            // FINAL fresh re-check, after every `await` above, immediately
            // before the irreversible deletion.
            if await skipOrRevokeProfileCleanup(profileID) {
                continue
            }

            do {
                try await sessionManager.removeProfile(profileID: profileID)
                removeSignInSessions(profileID: profileID)
                volatileProfileDeletionIDs.remove(profileID)
                if pendingProfileDeletionStore.profileIDs.contains(profileID) {
                    try await pendingProfileDeletionStore.remove(profileID)
                }
            } catch {
                // No message written here: the failure leaves this profile in the
                // durable journal or in `volatileProfileDeletionIDs`, and the
                // banner below is derived from exactly that.
            }
        }

        updateProfileCleanupState()
    }

    /// FRESH (synchronous-read) liveness/ownership decision for a profile about
    /// to be cleaned up. Returns `true` — caller must `continue` — when the
    /// profile must NOT be deleted:
    /// - owned by an in-flight account-removal Task (`profileIDsBeingRemoved`):
    ///   leave it entirely alone; that Task drives its own deletion/rollback;
    /// - referenced by a LOADED account: an aborted pre-commit removal, not an
    ///   orphan — revoke the stale deletion intent rather than destroying a
    ///   live, authenticated session.
    ///
    /// Both reads are synchronous on the `@MainActor`, so the decision reflects
    /// the world at the exact call site — the caller invokes this again right
    /// before the irreversible delete, after all intervening `await`s.
    private func skipOrRevokeProfileCleanup(_ profileID: UUID) async -> Bool {
        if profileIDsBeingRemoved.contains(profileID) {
            return true
        }
        if isCommittingProfile(profileID) {
            return true
        }
        if accounts.contains(where: { $0.webProfileID == profileID }) {
            try? await pendingProfileDeletionStore.remove(profileID)
            volatileProfileDeletionIDs.remove(profileID)
            return true
        }
        return false
    }

    func refreshAll(reason: RefreshReason = .manual) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshCoordinator.refreshAll(
            accounts: refreshableAccounts,
            reason: reason
        )
    }

    func prepareForTermination() async -> Bool {
        let sessionIDs = signInSessions.values.compactMap { session in
            // "Cleanup owns this session" must mean the SAME thing here as
            // everywhere else, so `isStuckCleanup` has the final say. Raw queue
            // membership alone once skipped cancelling a session whose profile a
            // live account already referenced — cleanup would revoke that entry
            // rather than act on it, leaving the session open and the first Quit
            // refused for work nobody was doing.
            let isOwnedByCleanup = (
                volatileProfileDeletionIDs.contains(session.webProfileID)
                    || pendingProfileDeletionStore.profileIDs.contains(
                        session.webProfileID
                    )
            ) && isStuckCleanup(session.webProfileID)
            return isOwnedByCleanup ? nil : session.id
        }
        for sessionID in sessionIDs {
            await cancelSignIn(sessionID: sessionID)
        }
        await retryProfileCleanup()
        // The SAME predicate `requiresTerminationPreparation` and the banner use —
        // `retryProfileCleanup` above just refreshed it. A raw-set guard would
        // refuse to quit for an entry the rest of the app considers settled: one
        // owned by an in-flight removal is never drained from the volatile set by
        // `skipOrRevokeProfileCleanup`, so quitting would be refused with no banner
        // to explain it until that removal happened to finish.
        guard stuckVolatileProfileIDs.isEmpty else {
            profileIDsBlockingQuit = stuckVolatileProfileIDs
            updateProfileCleanupState()
            return false
        }
        guard signInSessions.isEmpty else {
            sessionIDsBlockingQuit = Set(signInSessions.keys)
            return false
        }
        return true
    }

    func refreshWhenOpened() async {
        await refreshAll(reason: .popoverOpened)
    }

    func renameAccount(id: UUID, label: String) async throws {
        try claimAccountMutation(id)
        defer { mutatingAccountIDs.remove(id) }
        try await accountStore.rename(id: id, label: label)
    }

    func moveAccount(id: UUID, to destination: Int) async throws {
        try claimAccountMutation(id)
        defer { mutatingAccountIDs.remove(id) }
        try await accountStore.move(id: id, to: destination)
    }

    /// Synchronously validates and claims the removal markers, then returns an
    /// already-started Task running the removal. Markers are visible the instant
    /// this returns: a concurrently suspended auto-start commit bails at
    /// its guard. Callers that need the tap-time claim (the Settings UI) MUST
    /// call this synchronously in the SwiftUI action, not inside a `Task`.
    @MainActor
    func requestRemoveAccount(id: UUID) throws -> Task<Void, Error> {
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.accountNotFound
        }
        guard
            !removingAccountIDs.contains(id),
            !mutatingAccountIDs.contains(id),
            !signInSessions.values.contains(where: {
                $0.accountID == id && committingSessionIDs.contains($0.id)
            })
        else {
            throw AccountStoreError.operationInProgress
        }

        mutatingAccountIDs.insert(id)
        removingAccountIDs.insert(id)
        // Claim the profile synchronously so a concurrent `retryProfileCleanup`
        // observes this removal as in-flight and stays off its profile.
        profileIDsBeingRemoved.insert(account.webProfileID)
        // No publish needed here, and none is a no-op by accident: a profile is
        // only claimable while a LIVE account references it, and the indicator
        // already suppresses those. Suppression then passes from the live-account
        // rule to the in-flight rule when `accountStore.remove` commits, and the
        // Task's defer publishes once the marker drops — so this profile is never
        // shown as stuck at any point in between.
        return Task { [self] in
            defer {
                removingAccountIDs.remove(id)
                profileIDsBeingRemoved.remove(account.webProfileID)
                mutatingAccountIDs.remove(id)
                // Republish on EVERY exit, and only here — AFTER the markers
                // above are released. Two reasons it belongs at this exact spot:
                //
                // - A removal whose profile deletion AND rollback both failed
                //   throws straight out of the body leaving the profile
                //   journalled; without a publish the cached flags stay stale and
                //   hide the only retry control there is.
                // - Inside the body the profile is still marked in-flight, and an
                //   in-flight removal must never be surfaced as stuck cleanup, so
                //   a publish there could only ever be filtered back out.
                updateProfileCleanupState()
            }

            try await removeAccountBody(id: id, account: account)
        }
    }

    /// Compatibility wrapper. Forwards caller cancellation into the unstructured
    /// removal Task so a cancelled caller still cancels the destructive work —
    /// e.g. cancellation-aware profile deletion — and triggers the same rollback
    /// the pre-split inline `async` method did.
    func removeAccount(id: UUID) async throws {
        let task = try requestRemoveAccount(id: id)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The async removal body, extracted so `requestRemoveAccount` can claim its
    /// markers synchronously and run this inside the returned Task. `throws` so
    /// rollback failures propagate exactly as before.
    private func removeAccountBody(id: UUID, account: AccountRecord) async throws {

        // HARD PRECONDITION, before ANY destructive or observable mutation —
        // refresh cancel, sign-in/reauth session teardown, snapshot/account
        // removal. If journaling the profile for deletion
        // fails, abort with EVERYTHING intact: account, snapshot, profile, and
        // any in-flight reauthentication session for this account. (An enqueue
        // placed after the session teardown would already have discarded a
        // reauth session by the time it failed.) A best-effort (`try?`) enqueue
        // could instead let account deletion proceed with no durable cleanup
        // record, reintroducing the original orphan-profile vulnerability.
        //
        // SAFETY OF THE JOURNAL WHILE THE ACCOUNT IS STILL LIVE: between this
        // enqueue and the `accountStore.remove` commit below, the account
        // record still references this profile, and this removal holds the
        // profile's `profileIDsBeingRemoved` marker. `retryProfileCleanup`
        // therefore treats the entry as owned/aborted-pre-commit and REVOKES it
        // (never deletes) — so an interruption in this window can never delete a
        // live session. Not surfaced in the UI cleanup
        // indicator: this is an in-flight removal, not a stuck one.
        try await pendingProfileDeletionStore.enqueue(account.webProfileID)

        await refreshCoordinator.cancel(accountID: id)
        signInSessions = signInSessions.filter { $0.value.accountID != id }
        pruneSessionBookkeeping()
        // A reauth session on this account may have been protecting
        // its profile's timeout recycle.
        sessionManager.completeDeferredRecycles()
        let snapshot = snapshotStore.snapshot(for: id)

        do {
            try await snapshotStore.remove(accountID: id)
        } catch {
            // Pre-commit failure: the account record is still live. Revoke the
            // deletion intent so cleanup has nothing stale to reconcile, then
            // propagate — nothing destructive committed.
            try? await pendingProfileDeletionStore.remove(account.webProfileID)
            throw error
        }
        do {
            try await accountStore.remove(id: id)
        } catch {
            let removalError = error
            // The account record survived — it is still live, so un-journal its
            // profile. Best-effort here: even if this dequeue fails, the startup
            // live-reference reconciliation in `retryProfileCleanup` revokes any
            // journal entry whose profile a loaded account still references, so a
            // failed dequeue can never cause a live session to be deleted.
            try? await pendingProfileDeletionStore.remove(account.webProfileID)
            updateProfileCleanupState()
            if let snapshot {
                do {
                    try await snapshotStore.save(snapshot)
                } catch {
                    throw AccountRemovalError.rollbackFailed
                }
            }
            throw removalError
        }

        do {
            try await sessionManager.removeProfile(profileID: account.webProfileID)
        } catch {
            let profileError = error
            do {
                try await accountStore.restore(account, at: account.displayOrder)
                // The account is live again — un-journal so a later cleanup pass
                // does not delete the restored account's still-valid session.
                // Best-effort: the startup live-reference reconciliation revokes
                // the entry anyway (the restored account references this
                // profile), so a failed dequeue cannot delete a live session.
                try? await pendingProfileDeletionStore.remove(account.webProfileID)
                updateProfileCleanupState()
                if let snapshot {
                    try await snapshotStore.save(snapshot)
                }
            } catch {
                throw AccountRemovalError.rollbackFailed
            }
            throw profileError
        }

        // Profile store removed successfully — clear the durable journal entry, and
        // any volatile duplicate for the same profile. A cancelled sign-in that
        // failed to journal can have left one behind; without this it outlives the
        // deletion, and once the in-flight marker drops it reads as stuck again —
        // offering Retry for a profile that no longer exists.
        try? await pendingProfileDeletionStore.remove(account.webProfileID)
        volatileProfileDeletionIDs.remove(account.webProfileID)
        updateProfileCleanupState()

        // Only after both the account-persistence and web-profile removal have
        // succeeded — a rolled-back removal (either branch above) must keep
        // history, since the account is still live.
        await historyStore.remove(accountID: id)
        // SYNCHRONOUS tombstone + in-memory removal, with no suspension
        // before or after: `decideAlerts` checks `alertTombstones`
        // synchronously too, so no evaluation — in this call stack (the
        // `refreshCoordinator.cancel`/`snapshotStore.remove` teardown above
        // already excluded this account from `refreshableAccounts` via
        // `removingAccountIDs`) or triggered by any later sink emission —
        // can ever resurrect an entry for this account again. The store
        // removal is a best-effort async side effect, tracked so
        // `flushAlertEvaluations()` can await it too.
        alertTombstones.insert(id)
        alertStates.removeValue(forKey: id)
        // Same reasoning, smaller scope: warm-up's recorded failure describes an
        // account that no longer exists.
        autoStartFailures.removeValue(forKey: id)
        // Enqueued onto the SAME `alertSideEffectQueue` as every save/post
        // item, AFTER the synchronous tombstone insert above. FIFO ordering
        // guarantees this `remove` runs after any save already enqueued for
        // this account by an earlier `applyAlertDecision` call — so the
        // persisted entry cannot be resurrected by a save that was in flight
        // when removal began, even if that save's own tombstone recheck
        // somehow missed.
        alertSideEffectQueue.enqueue { [weak self] in
            try? await self?.alertStateStore.remove(accountID: id)
        }
    }

    private func requireActive(_ session: SignInSession) throws {
        guard
            signInSessions[session.id] === session,
            !cancellingSessionIDs.contains(session.id),
            // Cancelled, cleanup unfinished. Present in `signInSessions`, but
            // only so cleanup can retry — never to be committed.
            !cancelledSessionIDsPendingCleanup.contains(session.id),
            !removingAccountIDs.contains(session.accountID)
        else {
            throw CancellationError()
        }
    }

    private func claimCommit(_ session: SignInSession) throws {
        try requireActive(session)
        if !session.isNewAccount && mutatingAccountIDs.contains(session.accountID) {
            throw AccountStoreError.operationInProgress
        }
        committingSessionIDs.insert(session.id)
        if !session.isNewAccount {
            mutatingAccountIDs.insert(session.accountID)
        }
    }

    private func claimAccountMutation(_ accountID: UUID) throws {
        guard
            !removingAccountIDs.contains(accountID),
            !mutatingAccountIDs.contains(accountID)
        else {
            throw AccountStoreError.operationInProgress
        }
        mutatingAccountIDs.insert(accountID)
    }

    private func cleanUpNewSignIn(_ session: SignInSession) async {
        var isDurable = false
        do {
            try await pendingProfileDeletionStore.enqueue(session.webProfileID)
            isDurable = true
            signInSessions.removeValue(forKey: session.id)
            sessionManager.completeDeferredRecycles()
        } catch {
            volatileProfileDeletionIDs.insert(session.webProfileID)
        }

        do {
            try await sessionManager.removeProfile(profileID: session.webProfileID)
            signInSessions.removeValue(forKey: session.id)
            sessionManager.completeDeferredRecycles()
            volatileProfileDeletionIDs.remove(session.webProfileID)
            if isDurable {
                try await pendingProfileDeletionStore.remove(session.webProfileID)
            }
        } catch {
            // See `retryProfileCleanup`: the queued profile IS the banner's
            // condition, so there is nothing to write here.
        }

        // If the session survived its own cancellation, it is here for cleanup
        // to retry and for nothing else. Marked at the single point where that can
        // be true, rather than at each failing branch.
        if signInSessions[session.id] != nil {
            cancelledSessionIDsPendingCleanup.insert(session.id)
        }

        updateProfileCleanupState()
    }

    private func removeSignInSessions(profileID: UUID) {
        signInSessions = signInSessions.filter {
            $0.value.webProfileID != profileID
        }
        pruneSessionBookkeeping()
        // Cover the retryProfileCleanup call sites too.
        sessionManager.completeDeferredRecycles()
    }

    /// Whether a sign-in is mid-commit on this profile — past `claimCommit`, and so
    /// past its last `requireActive`. The commit will land regardless, so deleting
    /// the store now yields an account with no cookies.
    ///
    /// Deliberately keyed on `committingSessionIDs` rather than on session existence:
    /// a session kept for cleanup to retry (`cancelledSessionIDsPendingCleanup`) is
    /// exactly what cleanup is FOR, and blocking on that would strand it forever —
    /// the state this whole banner feature exists to prevent.
    private func isCommittingProfile(_ profileID: UUID) -> Bool {
        signInSessions.contains { sessionID, session in
            session.webProfileID == profileID
                && committingSessionIDs.contains(sessionID)
        }
    }

    /// Whether the cleanup pass would actually ACT on this profile — i.e. whether
    /// it is stuck rather than merely queued. Deliberately the exact inverse of
    /// `skipOrRevokeProfileCleanup`'s two refusals:
    ///
    /// - owned by an in-flight `removeAccount`: work in progress, not stuck. That
    ///   removal republishes from its own marker-releasing `defer`.
    /// - referenced by a LOADED account: an aborted pre-commit removal, which the
    ///   cleanup pass REVOKES rather than deletes.
    ///
    /// Surfacing either would warn about a live, authenticated session and offer a
    /// Retry that must never delete it. Startup makes the second reachable —
    /// `load()` publishes the queue several awaits before `retryProfileCleanup`
    /// reconciles it.
    private func isStuckCleanup(_ profileID: UUID) -> Bool {
        !profileIDsBeingRemoved.contains(profileID)
            && !isCommittingProfile(profileID)
            && !accounts.contains { $0.webProfileID == profileID }
    }

    /// Sole publisher of the cleanup queue's observable state — including its
    /// banner, which is DERIVED here rather than written at the failure sites.
    ///
    /// The retry control lives inside that banner, so the banner must mean exactly
    /// "there is work here the user can actually retry" — see `isStuckCleanup` for
    /// what that excludes. Deriving it gets two things for free: it cannot outlive
    /// the work the way a written-once `errorMessage` did (nothing in the app ever
    /// cleared that), and it shares no storage with `errorMessage`, so the two can
    /// never retract or clobber one another.
    private func updateProfileCleanupState() {
        // BOTH queues are filtered by the same rule, because the volatile queue can
        // hold a live-referenced profile too: a cancelled sign-in whose journal
        // enqueue AND profile deletion both failed keeps its session, so a
        // verification request that returns afterwards can still commit an account
        // onto that very profile.
        stuckVolatileProfileIDs = volatileProfileDeletionIDs.filter(isStuckCleanup)
        let stuckDurableProfileIDs = pendingProfileDeletionStore.profileIDs
            .filter(isStuckCleanup)

        hasVolatileProfileCleanup = !stuckVolatileProfileIDs.isEmpty
        hasPendingProfileCleanup = hasVolatileProfileCleanup
            || !stuckDurableProfileIDs.isEmpty

        // The quit-blocked wording holds only while the SPECIFIC volatile
        // profiles that turned the quit away are still volatile. Volatile cleanup
        // is the only thing that blocks termination (see
        // `requiresTerminationPreparation`), so once they drain — or are merely
        // replaced by unrelated volatile work — the claim stops being true.
        profileIDsBlockingQuit.formIntersection(stuckVolatileProfileIDs)
        profileCleanupBanner = hasPendingProfileCleanup
            ? (profileIDsBlockingQuit.isEmpty
                ? ProfileCleanupCopy.pending
                : ProfileCleanupCopy.blockingQuit)
            : nil
    }

    private func existingOrder(_ session: SignInSession) -> Int {
        accounts.first(where: { $0.id == session.accountID })?.displayOrder ?? 0
    }

    private func existingCreatedAt(_ session: SignInSession) -> Date {
        accounts.first(where: { $0.id == session.accountID })?.createdAt ?? now()
    }
}

/// The two wordings the profile-cleanup banner can take, chosen in
/// `AppModel.updateProfileCleanupState`: `blockingQuit` while volatile cleanup is
/// actually holding up a quit the user asked for, `pending` otherwise. Named
/// rather than inlined so the tests assert against the same literals the model
/// publishes.
enum ProfileCleanupCopy {
    static let pending = "A cancelled sign-in profile still needs cleanup."
    static let blockingQuit =
        "Quit is paused until the cancelled sign-in profile is removed."
    static let blockingQuitOnSignIn =
        "Quit is paused until the active sign-in finishes."
}

@MainActor
private final class ProviderContractCaptureErrorRelay {
    weak var model: AppModel?

    func report(_ message: String) {
        model?.errorMessage = message
    }
}
