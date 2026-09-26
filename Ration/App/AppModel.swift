import Combine
import Foundation
import os
import WebKit

enum AccountRemovalError: LocalizedError {
    case rollbackFailed

    var errorDescription: String? { message(locale: .current) }

    func message(locale: Locale) -> String {
        LocalizedStringResource.accountErrorRemovalRollbackFailed.string(in: locale)
    }
}

enum AccountCommitError: LocalizedError {
    case rollbackFailed

    var errorDescription: String? { message(locale: .current) }

    func message(locale: Locale) -> String {
        LocalizedStringResource.accountErrorCommitRollbackFailed.string(in: locale)
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
    /// How long a torn-down view gets to finish its `about:blank` navigation
    /// before it is judged abandoned (`watchTeardown`).
    private let teardownGrace: @MainActor () async -> Void

    init(
        profileManager: any WebProfileManaging,
        adapterRegistry: ProviderAdapterRegistry,
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        teardownGrace: @escaping @MainActor () async -> Void = {
            try? await Task.sleep(for: .seconds(30))
        }
    ) {
        self.profileManager = profileManager
        self.adapterRegistry = adapterRegistry
        self.messageSender = messageSender
        self.teardownGrace = teardownGrace
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
    /// `mayPost` runs immediately before each POST is dispatched and throws
    /// to veto it (see `ClaudeMessageSender.send`).
    func sendKeepAlive(
        prepared: ClaudeMessageSender.Prepared,
        conversationID: UUID?,
        for account: AccountRecord,
        mayPost: ClaudeMessageSender.PostGate? = nil
    ) async throws -> ClaudeMessageSender.Receipt {
        try await recycleWebViewOnTimeout(profileID: account.webProfileID) { webView in
            try await messageSender.sendReporting(
                prepared: prepared,
                conversationID: conversationID,
                mayPost: mayPost,
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

    /// The adapter's separate plan read (nil for providers without one),
    /// through the same timeout recovery as every other bridge call.
    ///
    /// Background and optional, so it YIELDS the view: if another evaluation
    /// started on the same view after this read began (a usage refresh that
    /// may well be healthy), a late plan timeout abandons the read instead of
    /// tearing that view down under it.
    func refreshPlanDetection(
        for account: AccountRecord,
        snapshot: UsageSnapshot
    ) async throws -> PlanDetection? {
        let adapter = try adapterRegistry.adapter(for: account.provider)
        return try await recycleWebViewOnTimeout(
            profileID: account.webProfileID,
            yieldsToNewerEvaluations: true
        ) { webView in
            try await adapter.refreshPlanDetection(for: snapshot, in: webView)
        }
    }

    /// Cursor's past-cycle read. Background and optional like the plan read,
    /// so it YIELDS the view to a newer evaluation (a usage poll) on timeout.
    func fetchCursorSpendHistory(
        for account: AccountRecord,
        request: CursorHistoryRequest,
        isSuppressed: @escaping @MainActor () -> Bool
    ) async throws -> CursorHistoryFetch? {
        let adapter = try adapterRegistry.adapter(for: account.provider)
        let profileID = account.webProfileID
        // Checked at the last native moment before the script reaches the
        // page: an open sign-in/reauth session shares this account's view,
        // and the history read must never run under the user's visible login.
        // `isSuppressed` is the same rule the refresh coordinator checks at
        // its dispatch (`AppModel.hasOpenSignInSession`).
        let mayDispatch: @MainActor () throws -> Void = {
            if isSuppressed() {
                throw CursorHistoryReadVetoed()
            }
        }
        return try await recycleWebViewOnTimeout(
            profileID: profileID,
            yieldsToNewerEvaluations: true,
            reapsOnCancellation: true
        ) { webView in
            try await adapter.fetchCursorSpendHistory(request, mayDispatch: mayDispatch, in: webView)
        }
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

    /// Timeout recycles deferred because the profile was protected at the
    /// time, keyed by profile, holding the EXACT view that timed out.
    /// `completeDeferredRecycles()` finishes them once protection ends. The
    /// view, not just the profile, is kept: by then the cache may have dropped
    /// it (`removeProfile`) or hold a different, healthy view, and the teardown
    /// belongs to the view that hosts the abandoned bridge call.
    private var pendingRecycles: [UUID: WKWebView] = [:]

    /// Views whose `about:blank` teardown had not finished after
    /// `teardownGrace`: a persistently wedged WebContent process ignores even
    /// that, and each such view is abandoned with its process. Nothing caps
    /// this in-app, so it is counted and logged to make field accumulation
    /// visible.
    private(set) var abandonedWebViewCount = 0
    private var teardownChecks: [UUID: Task<Void, Never>] = [:]

    /// Every view already torn down, held weakly. Several paths can reach the
    /// same wedged view (a deferred recycle at session close, then the late
    /// timeout of a poll that was retrying on it); it is torn down, watched
    /// and counted once. Weak so the registry never keeps a view alive, and
    /// compared by `===` (not a bare `ObjectIdentifier`, which a new view can
    /// reuse once the old one is gone).
    private final class WeakView {
        weak var view: WKWebView?
        init(_ view: WKWebView) { self.view = view }
    }
    private var tornDownViews: [WeakView] = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.izzy.ration",
        category: "webview"
    )

    /// Monotonic count of evaluations started through
    /// `recycleWebViewOnTimeout`, and the latest one per profile with the view
    /// it ran on — lets a yielding call see that a newer one started on its view.
    private var evaluationSerial: UInt64 = 0
    private var latestEvaluation: [UUID: (serial: UInt64, view: ObjectIdentifier)] = [:]

    /// A timed-out evaluation means this profile's cached web view is
    /// suspect (a wedged WebContent process reproduces the hang on every
    /// later call). Recycle it — UNLESS an open sign-in/reauth session is
    /// using this exact profile right now (`isProfileProtected`), in which
    /// case recycling would abort the user's visible auth navigation; defer
    /// it instead (`pendingRecycles`, completed by
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
        yieldsToNewerEvaluations: Bool = false,
        reapsOnCancellation: Bool = false,
        _ operation: (WKWebView) async throws -> T
    ) async rethrows -> T {
        let operatedView = webView(for: profileID)
        evaluationSerial &+= 1
        let serial = evaluationSerial
        latestEvaluation[profileID] = (serial, ObjectIdentifier(operatedView))
        do {
            return try await operation(operatedView)
        } catch let error as WebUsageClientError where error == .timedOut {
            recycle(operatedView, profileID: profileID, serial: serial, yielding: yieldsToNewerEvaluations)
            throw error
        } catch is CancellationError where reapsOnCancellation && Task.isCancelled {
            // The caller gave up (account removed, app stopping): the
            // abandoned in-page script may still be issuing requests, and
            // only frame destruction stops it — the same reap as a timeout.
            recycle(operatedView, profileID: profileID, serial: serial, yielding: yieldsToNewerEvaluations)
            throw CancellationError()
        }
    }

    private func recycle(_ operatedView: WKWebView, profileID: UUID, serial: UInt64, yielding: Bool) {
        if yielding,
           let latest = latestEvaluation[profileID],
           latest.serial != serial,
           latest.view == ObjectIdentifier(operatedView) {
            // A newer evaluation is using this view; leave it be.
            return
        }
        if isProfileProtected(profileID) {
            deferRecycle(of: operatedView, profileID: profileID)
        } else {
            if webViews[profileID] === operatedView {
                webViews.removeValue(forKey: profileID)
            }
            tearDown(operatedView, profileID: profileID)
        }
    }

    private func deferRecycle(of webView: WKWebView, profileID: UUID) {
        // One entry per profile. A different view already waiting here is
        // out of the cache (a protected profile's cached view is never
        // evicted by a recycle), so no poll can reach it any more: tear it
        // down now rather than overwrite, and so lose, the only reference
        // that would.
        if let displaced = pendingRecycles[profileID], displaced !== webView {
            tearDown(displaced, profileID: profileID)
        }
        pendingRecycles[profileID] = webView
    }

    /// Force-settle a dropped view's abandoned bridge call (see
    /// `WebViewTeardown` for why `about:blank`, not just `stopLoading()`),
    /// then check later that the view acted on it.
    private func tearDown(_ webView: WKWebView, profileID: UUID) {
        tornDownViews.removeAll { $0.view == nil }
        guard !tornDownViews.contains(where: { $0.view === webView }) else { return }
        tornDownViews.append(WeakView(webView))
        WebViewTeardown.begin(webView)
        watchTeardown(of: webView, profileID: profileID)
    }

    /// After `teardownGrace`, a view that is gone was released (its abandoned
    /// call settled) and one showing a finished `about:blank` was torn down.
    /// Anything else ignored the teardown and is abandoned: counted and
    /// logged. Holds the view weakly, so the check never keeps it alive.
    private func watchTeardown(of webView: WKWebView, profileID: UUID) {
        let checkID = UUID()
        let grace = teardownGrace
        teardownChecks[checkID] = Task { @MainActor [weak self, weak webView] in
            await grace()
            guard let self else { return }
            self.teardownChecks.removeValue(forKey: checkID)
            guard let webView, !WebViewTeardown.hasCompleted(webView) else { return }
            self.abandonedWebViewCount += 1
            Self.logger.error(
                "web view ignored its about:blank teardown; abandoned profile=\(profileID.uuidString, privacy: .public) abandonedTotal=\(self.abandonedWebViewCount, privacy: .public)"
            )
        }
    }

    /// Drops `profileID`'s cached view. The suspect view, the one waiting on
    /// a deferred recycle, gets the full teardown when `tearDownSuspect`;
    /// otherwise it stays pending so `completeDeferredRecycles()` still
    /// reaches it by identity. Any other dropped view only stops loading.
    private func dropCachedView(profileID: UUID, tearDownSuspect: Bool) {
        let cached = webViews.removeValue(forKey: profileID)
        var tornDown: WKWebView?
        if tearDownSuspect, let suspect = pendingRecycles.removeValue(forKey: profileID) {
            tearDown(suspect, profileID: profileID)
            tornDown = suspect
        }
        if let cached, cached !== tornDown {
            cached.stopLoading()
        }
    }

    /// Finishes every timeout recycle that was deferred because its
    /// profile was protected at the time (an open sign-in/reauth session).
    /// Called by `AppModel` at every point a sign-in session is removed from
    /// `signInSessions` — the tainted view otherwise stays cached with only
    /// `stopLoading()` ever applied to it (the idle release), which never
    /// settles the abandoned callback and leaks the view/WebContent process
    /// indefinitely. Snapshots the pending entries first since it mutates them.
    ///
    /// Tears down the EXACT view that timed out, and evicts the cache entry
    /// only while it still holds that view: a healthy view cached since then
    /// is left alone.
    ///
    /// Known and accepted behavior: while the session was open,
    /// polls kept retrying on the protected (still cached) view. If it has
    /// recovered and a healthy poll is mid-evaluation on it right now, this
    /// teardown invalidates that evaluation, so that one poll fails and the
    /// next one runs on a fresh view.
    func completeDeferredRecycles() {
        for (profileID, webView) in Array(pendingRecycles) where !isProfileProtected(profileID) {
            pendingRecycles.removeValue(forKey: profileID)
            if webViews[profileID] === webView {
                webViews.removeValue(forKey: profileID)
            }
            tearDown(webView, profileID: profileID)
        }
    }

    /// The profile is being deleted, which ends any sign-in on it, so a
    /// suspect view is torn down now whether or not a session still protects
    /// it: if the deletion fails, the session survives for cleanup to retry
    /// and nothing else would complete its deferred recycle meanwhile.
    func removeProfile(profileID: UUID) async throws {
        dropCachedView(profileID: profileID, tearDownSuspect: true)
        try await profileManager.removeProfile(profileID: profileID)
    }

    /// Drop this profile's cached WebView first: purging the store underneath a live
    /// view would have it re-fetch everything it just lost anyway.
    func purgeDiskCache(profileID: UUID) async {
        dropCachedView(profileID: profileID, tearDownSuspect: !isProfileProtected(profileID))
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
            // A view still awaiting its deferred recycle carries an
            // abandoned bridge call — `stopLoading()` alone never settles
            // it (see `WebViewTeardown`), so it needs the same `about:blank`
            // teardown `completeDeferredRecycles()` would have applied.
            dropCachedView(profileID: profileID, tearDownSuspect: !isProfileProtected(profileID))
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

    /// Test barrier: resolves once every issued teardown has been judged.
    func flushTeardownChecks() async {
        while let check = teardownChecks.values.first {
            await check.value
        }
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
    /// What macOS last said about Ration's notifications. `nil` = not read
    /// yet (launch, or a startup pass that returned early — parked, load
    /// failed, superseded). Surfaces show a problem only on a known answer,
    /// so nothing flashes or sticks on a guess; `.notDetermined` offers to
    /// ask rather than pointing at a System Settings list Ration isn't in.
    @Published private(set) var notificationPermission: NotificationPermission? = nil

    /// Posting-gate view of `notificationPermission`: `true` only when
    /// allowed; `false` for denied AND not-yet-asked.
    var usageAlertsAuthorized: Bool? { notificationPermission.map { $0 == .allowed } }

    /// The last warm-up attempt per account, recorded ONLY when it failed and
    /// removed the moment a later attempt succeeds. Facts, not copy: the banner
    /// is derived from these through `warmUpBanner`, so it retracts itself when
    /// the account is removed, paused, has warm-up turned off, or simply gets a
    /// successful attempt — none of which the written-once `errorMessage` it
    /// replaced could do (nothing in the app ever cleared that, so an auto-start
    /// failure stayed on screen until the app was quit).
    @Published private(set) var autoStartFailures: [UUID: AutoStartFailure] = [:]
    /// "Switch to this account next", per advised provider (`SwitchAdvisor`).
    /// Assigned only when it changes, so subscribers see real transitions.
    @Published private(set) var switchAdvice: [SwitchAdvice] = []

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
            warmUpEnabled: appSettings.featureWarmUpEnabled,
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
    private let cursorHistoryStore: CursorSpendHistoryStore
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
    /// Test-only interleave point at the start of the post-sign-in refresh.
    private let beforeSignInResumeRefresh: @MainActor () async -> Void
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
    /// Latest plan reading per account this launch, with the moment
    /// it was read, so "Detect automatically" can re-apply it at once and
    /// switch advice can use it before the store has saved it. In memory only;
    /// purged on removal.
    private var latestPlanDetections: [UUID: (detection: PlanDetection, at: Date)] = [:]
    /// Background plan reads in flight (`refreshPlanInBackground`); a test
    /// barrier awaits them.
    private var planRefreshTasks: [UUID: Task<Void, Never>] = [:]
    /// Background Cursor history reads in flight, one per account at most.
    private var cursorHistoryTasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped per background plan read; a read applies only if still latest.
    private var planRequestRevision: [UUID: UInt64] = [:]
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
    /// Bumped SYNCHRONOUSLY the instant the global warm-up switch is asked to
    /// turn off (before its save suspends). A warm-up attempt captures it up
    /// front and re-checks it — with the live switch — after the reservation
    /// and immediately before every POST, so an attempt that was already
    /// past its commit guard can never send once the user has said no.
    private var warmUpGeneration: UInt64 = 0
    /// Disables of the global warm-up switch whose save has not landed yet:
    /// `featureWarmUpEnabled` is published only after the save, so an attempt
    /// STARTING inside that window would otherwise capture the new generation
    /// and still read the switch as on.
    private var warmUpDisablesInFlight = 0
    /// Same shape for the Resets switch: bumped synchronously on every
    /// switch-off, captured when a reset notification is queued, and checked
    /// when it runs — so an ON→OFF→ON flip while the post waits behind earlier
    /// side effects cannot release it. `resetsDisablesInFlight` covers the
    /// save window before `featureResetsEnabled` publishes.
    private var resetsDeliveryGeneration: UInt64 = 0
    private var resetsDisablesInFlight = 0
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
    ///   pass's enable path (after the re-read status is allowed AND
    ///   `primeAllAlerts()` has run), and at the end of a current-version
    ///   `.startup` pass on its OFF→ON edge (same authorize-then-prime
    ///   sequence, run once per activation).
    /// - `false` synchronously at the tap in `requestSetUsageAlerts(false)`
    ///   (I4), and whenever authorization resolves denied in either pass.
    /// - Either way by a current-version `recheckNotificationAuthorization()`
    ///   pass, when the OS permission changed mid-session, and by a
    ///   current-version `requestNotificationPermission()` (Allow
    ///   Notifications) pass, per the status macOS reports after its prompt
    ///   (prime first on the way to `true`, in both).
    /// - Starts `false`.
    ///
    /// This is the single mechanism that closes the async side-effect races
    /// the hardening pass left open: because both the sink's guard
    /// And every enqueued post's execution-time recheck read
    /// this SAME synchronously-flipped flag, there is no suspension window
    /// in which a disable/remove can land without being observed by either
    /// the evaluation or the post it guards.
    private var alertsActive = false {
        didSet {
            if oldValue != alertsActive { alertsActivationGeneration += 1 }
        }
    }
    /// Bumped on every `alertsActive` edge (open or close). A post captures it
    /// at enqueue time and runs only if it still matches, so a post born in
    /// one activation can never be delivered in a later one — e.g. a crossing
    /// observed while notifications were denied, still queued behind a slow
    /// save when a recheck opens the gate. Priming cannot catch that: it
    /// guards future decisions, not posts already in the queue.
    private var alertsActivationGeneration = 0
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

    /// Settings edits not on disk yet (label, quiet hours). A quit saves them
    /// first — see `prepareForTermination()`.
    let pendingEdits: PendingEditRegistry

    var requiresTerminationPreparation: Bool {
        hasVolatileProfileCleanup || !signInSessions.isEmpty || pendingEdits.hasPendingEdits
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

    /// Accounts a usage FETCH may run for: `refreshableAccounts` minus any
    /// account an open sign-in/reauth session owns.
    ///
    /// The session uses the account's own cached web view — the one the
    /// user is signing in through — and every provider's fetch preparation
    /// navigates that view (Cursor loads its dashboard, Claude and ChatGPT
    /// load their usage page when the view is off their domain). A poll
    /// mid sign-in would pull the user off the login page. Skipping is not a
    /// failure: no state is written, so the account keeps its last state and
    /// snapshot, and closing the session brings it back with one refresh
    /// (`refreshAfterSignInClosed`).
    ///
    /// Alert evaluation stays on `refreshableAccounts`: it reads stored data
    /// and never touches a web view.
    private var pollableAccounts: [AccountRecord] {
        refreshableAccounts.filter { !hasOpenSignInSession($0) }
    }

    /// Whether an open sign-in/reauth session uses this account's web view.
    /// Matched by account AND profile: a new account's commit adds the
    /// record before its session closes, and that record already names the
    /// session's profile.
    private func hasOpenSignInSession(_ account: AccountRecord) -> Bool {
        signInSessions.values.contains { session in
            session.accountID == account.id || session.webProfileID == account.webProfileID
        }
    }

    /// The accounts each background poll fetches. The timer asks for this
    /// on every tick, so a session opened or closed between ticks is honored.
    private func backgroundRefreshAccounts() -> [AccountRecord] {
        pollableAccounts
    }

    /// Starts the background timer. Each tick asks for its accounts afresh.
    private func startBackgroundPolling() {
        refreshCoordinator.startBackgroundRefresh { [weak self] in
            self?.backgroundRefreshAccounts() ?? []
        }
    }

    /// One prompt refresh for an account whose sign-in/reauth session just
    /// closed without its own fetch landing (a cancel, or a commit whose
    /// snapshot save failed). Polls skipped it while the session was open,
    /// so waiting for the next tick would leave it behind for a whole poll.
    /// Fire-and-forget: closing the window must not wait on a fetch.
    private func refreshAfterSignInClosed(accountID: UUID) {
        guard pollableAccounts.contains(where: { $0.id == accountID }) else {
            return
        }
        let token = UUID()
        // Every fetch dispatched from here on started after the close.
        let dispatchesAtClose = refreshCoordinator.dispatchCount(for: accountID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.signInResumeRefreshes[accountID]?.token == token {
                    self.signInResumeRefreshes.removeValue(forKey: accountID)
                }
            }
            await self.beforeSignInResumeRefresh()
            // A fetch that started before the window opened may still be
            // running; `refresh` would only join it. Let it settle, then
            // fetch afresh.
            await self.refreshCoordinator.settle(accountID: accountID)
            // A timer or manual refresh that started after the close already
            // is the fresh fetch this promised; a second would be a duplicate.
            guard self.refreshCoordinator.dispatchCount(for: accountID) == dispatchesAtClose else {
                return
            }
            // Re-read: the account may be gone, paused, or back in a window.
            guard let current = self.pollableAccounts.first(where: { $0.id == accountID }) else {
                return
            }
            await self.refreshCoordinator.refresh(account: current, reason: .manual)
        }
        signInResumeRefreshes[accountID] = (token: token, task: task)
    }

    /// Refreshes started by `refreshAfterSignInClosed`, so tests can await them.
    private var signInResumeRefreshes: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

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
        cursorSpendHistoryStore: CursorSpendHistoryStore? = nil,
        profileManager: any WebProfileManaging,
        adapterRegistry: ProviderAdapterRegistry,
        messageSender: ClaudeMessageSender = ClaudeMessageSender(),
        notificationScheduler: any NotificationScheduling = UserNotificationScheduler(),
        now: @escaping @MainActor () -> Date = { .now },
        beforeSignInPersistence: @escaping @MainActor () async -> Void = {},
        beforeAlertsHydrationCompletes: @escaping @MainActor () async -> Void = {},
        beforeAutoStartCommit: @escaping @MainActor () async -> Void = {},
        beforeSignInResumeRefresh: @escaping @MainActor () async -> Void = {},
        beforeProfileCleanupDeletion: @escaping @MainActor (UUID) async -> Void = { _ in },
        systemPowerObserver: any SystemPowerObserving = SystemPowerObserver(),
        pendingEdits: PendingEditRegistry = PendingEditRegistry(),
        refreshSleep: @escaping UsageRefreshCoordinator.Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        teardownGrace: @escaping @MainActor () async -> Void = {
            try? await Task.sleep(for: .seconds(30))
        }
    ) {
        self.accountStore = accountStore
        self.pendingEdits = pendingEdits
        self.snapshotStore = snapshotStore
        self.pendingProfileDeletionStore = pendingProfileDeletionStore
        self.historyStore = historyStore
        self.appSettings = appSettings
        self.alertStateStore = alertStateStore
        let cursorHistoryStore = cursorSpendHistoryStore ?? CursorSpendHistoryStore(fileURL: nil)
        self.cursorHistoryStore = cursorHistoryStore
        self.notificationScheduler = notificationScheduler
        self.now = now
        self.beforeSignInPersistence = beforeSignInPersistence
        self.beforeAlertsHydrationCompletes = beforeAlertsHydrationCompletes
        self.beforeAutoStartCommit = beforeAutoStartCommit
        self.beforeSignInResumeRefresh = beforeSignInResumeRefresh
        self.beforeProfileCleanupDeletion = beforeProfileCleanupDeletion
        self.systemPowerObserver = systemPowerObserver

        let sessionManager = AccountSessionManager(
            profileManager: profileManager,
            adapterRegistry: adapterRegistry,
            messageSender: messageSender,
            teardownGrace: teardownGrace
        )
        self.sessionManager = sessionManager
        // Rollup gap limit tracks the coordinator's cadence below: 2 × the
        // longest poll of the current (Low Power or normal) mode.
        historyStore.gapLimit = {
            PollSchedule.rollupGapLimit(lowPowerMode: systemPowerObserver.isLowPowerModeEnabled)
        }
        refreshCoordinator = UsageRefreshCoordinator(
            snapshotStore: snapshotStore,
            now: now,
            sleep: refreshSleep,
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
        // profile (and live view). Polls skip such an account
        // (`pollableAccounts`), but a fetch already in flight when the
        // session opened still runs; protect the view from that fetch's
        // timeout recycle so a wedged poll never aborts the user's visible
        // auth navigation.
        sessionManager.isProfileProtected = { [weak self] profileID in
            self?.signInSessions.values.contains { $0.webProfileID == profileID } ?? false
        }
        // Re-checked at each refresh's dispatch: a refresh queued before a
        // sign-in window opened must not reach that window's view. The
        // session's own verify and fetch go straight to `sessionManager`, not
        // through the coordinator, so they are never suppressed.
        refreshCoordinator.isDispatchSuppressed = { [weak self] account in
            self?.hasOpenSignInSession(account) ?? false
        }

        Publishers.CombineLatest4(
            accountStore.$accounts,
            snapshotStore.$snapshots,
            refreshCoordinator.$states,
            appSettings.$sortByWeeklyReset
        )
        .map { accounts, snapshots, states, sortByWeeklyReset in
            Self.makePresentations(
                accounts: accounts,
                snapshots: snapshots,
                states: states,
                sortByWeeklyReset: sortByWeeklyReset
            )
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
            guard let self else { return }
            // Switch advice for THIS revision, before its alert decision, so
            // a crossing's notification is composed against it. Ungated:
            // advice is presentation, not an alert.
            self.recomputeSwitchAdvice(snapshots: snapshots, states: states, now: self.now())
            guard self.appSettings.usageAlertsEnabled else { return }
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
            self?.refreshFableVerdict(accountID: account.id, snapshot: snapshot)
            await self?.applyDetectedPlan(
                accountID: account.id,
                detection: snapshot.planDetection,
                at: snapshot.fetchedAt
            )
            self?.refreshPlanInBackground(account: account, snapshot: snapshot)
            self?.refreshCursorHistoryInBackground(account: account, snapshot: snapshot)
            await self?.retryPendingCursorHistoryRemovals()
            await self?.handleAutoStart(account: account, snapshot: snapshot)
        }

        cursorHistoryStore.$histories
            .sink { [weak self] histories in
                guard let self else { return }
                self.cursorSpendHistories = histories
            }
            .store(in: &cancellables)

        // Everything else switch advice reads — the account list (pause,
        // removal, order) and settings (thresholds, sort) — recomputes on the
        // next turn, once the published storage has actually been written.
        accountStore.$accounts
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleSwitchAdviceRecompute()
            }
            .store(in: &cancellables)
        appSettings.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleSwitchAdviceRecompute()
            }
            .store(in: &cancellables)

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
        // Captured before anything suspends: a warm-up switch-off from here on
        // invalidates this attempt (see `warmUpStillAllowed`).
        let warmUpGenerationAtStart = warmUpGeneration
        guard warmUpStillAllowed(warmUpGenerationAtStart) else { return }
        let decision = AutoStartPolicy.decide(
            account: account,
            fiveHour: snapshot.fiveHour,
            weekly: snapshot.weekly,
            now: now(),
            schedule: warmUpSchedule,
            warmUpEnabled: appSettings.featureWarmUpEnabled
        )
        if case .blockedByWeeklyLimit = decision {
            // Every other condition said fire: a warm-up was due and held.
            // Folded while it lasts (`WarmUpOutcome.recording`).
            await recordWarmUpOutcome(
                .skipped(.weeklyLimitSpent, at: now(), reserved: false),
                accountID: account.id
            )
            return
        }
        guard decision == .fire else {
            return
        }
        // Re-check the current stored account: it may have been disabled or
        // removed while the usage fetch was suspended.
        guard
            let current = accounts.first(where: { $0.id == account.id }),
            current.provider == .claude,
            current.autoStartFiveHour,
            !removingAccountIDs.contains(current.id),
            !sendingKeepAliveAccountIDs.contains(current.id),
            // A sign-in window on this account's web view: warm-up would
            // navigate it (see `pollableAccounts`). The next poll after the
            // session closes decides again.
            !hasOpenSignInSession(current)
        else {
            return
        }
        // FAIL CLOSED: the irreversible send is bound to the org the
        // triggering snapshot's data actually came from. A snapshot without
        // one (only possible outside the real Claude adapter) must skip
        // rather than let discovery pick whatever workspace is active now.
        guard let snapshotOrganizationID = snapshot.organizationID else {
            await recordWarmUpOutcome(
                .skipped(.organizationUnknown, at: now(), reserved: false),
                accountID: current.id
            )
            return
        }
        sendingKeepAliveAccountIDs.insert(current.id)
        defer { sendingKeepAliveAccountIDs.remove(current.id) }
        var reservation: (reservedAt: Date, previous: Date?)?
        let signInVeto = SignInVeto()

        // Whether `lastAutoStartedAt` has been taken for this attempt — what
        // each recorded outcome says it cost.
        var reserved = false
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
                // A sign-in window opened while `prepareKeepAlive` was suspended.
                !hasOpenSignInSession(atCommit),
                // A disable/remove in flight publishes its record only after its
                // save completes, so `atCommit` can still read `enabled` while the
                // user has already opted out. `mutatingAccountIDs` is claimed
                // SYNCHRONOUSLY at the top of `setAutoStart`/`removeAccount`
                // (before any await), so it reflects that intent immediately —
                // bail rather than reserve behind an opt-out and POST.
                !mutatingAccountIDs.contains(atCommit.id),
                warmUpStillAllowed(warmUpGenerationAtStart),
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
                    schedule: warmUpSchedule,
                    warmUpEnabled: appSettings.featureWarmUpEnabled
                )
            else {
                return
            }
            // Reserve BEFORE the irreversible POST: even if the send fails or its
            // result is lost, the policy will not re-fire within this window.
            try await accountStore.reserveAutoStart(id: current.id, at: commitNow)
            reserved = true
            reservation = (reservedAt: commitNow, previous: atCommit.lastAutoStartedAt)
            // The reservation suspended: the global switch may have gone off
            // meanwhile. The reservation stays (harmless — warm-up is off), but
            // nothing is sent. The same check runs again right before EVERY
            // POST inside the send (conversation create, completion, retry),
            // down to the moment the script is dispatched.
            guard warmUpStillAllowed(warmUpGenerationAtStart) else {
                await recordWarmUpOutcome(
                    .skipped(.warmUpTurnedOff, at: now(), reserved: true),
                    accountID: current.id
                )
                return
            }
            // A sign-in window may also have opened during the save. Nothing
            // was sent, so the reservation is handed back: the next eligible
            // poll after the window closes may try again. A skip, not an
            // outcome: nothing was attempted against Claude.
            if hasOpenSignInSession(current) {
                await releaseReservation(accountID: current.id, reservation)
                return
            }
            let receipt = try await sessionManager.sendKeepAlive(
                prepared: prepared,
                conversationID: current.keepAliveConversationID,
                for: current,
                mayPost: { [weak self] in
                    guard let self, self.warmUpStillAllowed(warmUpGenerationAtStart) else {
                        throw CancellationError()
                    }
                    if self.hasOpenSignInSession(current) {
                        signInVeto.fired = true
                        throw CancellationError()
                    }
                }
            )
            // The POST landed, but its stream carried an error event: Claude
            // refused the message inside a 2xx. It did NOT start the window,
            // so this is a failure on every surface — the popover row and the
            // Settings list agree — and nothing claims a started window (no
            // `recordAutoStart`, no refresh). The reservation taken above
            // stands exactly as for any other post-reservation failure.
            let landed = WarmUpOutcome.landed(receipt, at: now(), reserved: true)
            if let streamError = landed.streamErrorType {
                autoStartFailures[current.id] = AutoStartFailure(
                    at: now(),
                    kind: AutoStartFailure.Kind(streamError: streamError)
                )
                await recordWarmUpOutcome(landed, accountID: current.id)
                return
            }
            // The POST landed — the 5h window HAS started. This attempt is now
            // the latest word on the account, so it takes back any earlier
            // failure rather than leaving both statements standing, and NOTHING
            // below may turn it back into one: reporting
            // "auto-start didn't run" about a window that is demonstrably
            // running is a lie, and the reservation above means it will not run
            // again this window regardless.
            autoStartFailures.removeValue(forKey: current.id)
            let conversationID = receipt.conversationID
            // Best-effort from here. A failed record costs only the REUSABLE
            // conversation id: `lastAutoStartedAt` is already reserved, so the
            // sole consequence is that the next window creates a fresh
            // conversation instead of reusing this one.
            try? await accountStore.recordAutoStart(
                id: current.id,
                conversationID: conversationID,
                at: now()
            )
            await recordWarmUpOutcome(landed, accountID: current.id)
            // Reflect the freshly-started window immediately, instead of waiting
            // for the next refresh cycle. only record history for this
            // re-fetched snapshot after a SUCCESSFUL save — an unconditional
            // record here (regardless of save outcome) previously let the
            // history series record this newer snapshot even when it never
            // (or not yet) landed in `snapshotStore`.
            //
            // Skipped when a sign-in window opened on this account meanwhile:
            // the fetch would navigate the view the user is signing in on.
            guard !hasOpenSignInSession(current) else { return }
            if let refreshed = try? await sessionManager.fetchUsage(for: current) {
                do {
                    try await snapshotStore.save(refreshed)
                    historyStore.record(account: current, snapshot: refreshed)
                    refreshFableVerdict(accountID: current.id, snapshot: refreshed)
                } catch {}
            }
        } catch is CancellationError {
            // Vetoed at a POST gate by a sign-in window: that POST, and so
            // the completion that starts the window, never went out. The
            // reservation is handed back, as in the post-save check above,
            // and no outcome is recorded. (The gate checks the warm-up switch
            // first, so a sign-in veto means the switch was still on.)
            if signInVeto.fired {
                await releaseReservation(accountID: current.id, reservation)
            } else if reserved, !warmUpStillAllowed(warmUpGenerationAtStart) {
                // A veto from the send's `mayPost` gate after the reservation:
                // the switch went off mid-send. Any other cancellation
                // (removal, shutdown) is not a warm-up outcome.
                await recordWarmUpOutcome(
                    .skipped(.warmUpTurnedOff, at: now(), reserved: true),
                    accountID: current.id
                )
            }
            return
        } catch {
            // A sign-in window opened mid-attempt: whatever failed ran in (or
            // raced) the view the user is signing in on. A skip, not a
            // warm-up failure to report.
            guard !hasOpenSignInSession(current) else { return }
            autoStartFailures[current.id] = AutoStartFailure(
                at: now(),
                kind: AutoStartFailure.Kind(error: error)
            )
            await recordWarmUpOutcome(
                .failure(error, at: now(), reserved: reserved),
                accountID: current.id
            )
        }
    }

    /// Set by a warm-up POST gate that refused because a sign-in window
    /// opened, so the catch can tell it from the warm-up switch going off.
    private final class SignInVeto {
        var fired = false
    }

    /// Hands back a reservation whose attempt sent nothing. Best effort: a
    /// failed save only means this window is not retried.
    private func releaseReservation(
        accountID: UUID,
        _ reservation: (reservedAt: Date, previous: Date?)?
    ) async {
        guard let reservation else { return }
        try? await accountStore.releaseAutoStartReservation(
            id: accountID,
            reservedAt: reservation.reservedAt,
            restoring: reservation.previous
        )
    }

    /// Best-effort: a lost record never affects the warm-up itself, and
    /// an account removed meanwhile simply has nowhere to keep it.
    private func recordWarmUpOutcome(_ outcome: WarmUpOutcome, accountID: UUID) async {
        try? await accountStore.recordWarmUpOutcome(id: accountID, outcome: outcome)
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

    /// A user plan choice; nil = "Detect automatically", which
    /// re-applies this launch's latest reading at once instead of leaving the
    /// plan blank until the next poll.
    @MainActor
    func requestSetPlan(accountID: UUID, plan: PlanTier?) throws -> Task<Void, Error> {
        try claimAccountMutation(accountID)
        return Task { [self] in
            defer { mutatingAccountIDs.remove(accountID) }
            try await accountStore.setPlan(id: accountID, plan: plan)
            if plan == nil, let latest = latestPlanDetections[accountID] {
                try await accountStore.applyDetectedPlan(id: accountID, detection: latest.detection)
            }
        }
    }

    /// Whether the add-account flow should ask "Which plan is this?" for this
    /// freshly signed-in account.
    func needsPlanStep(accountID: UUID) -> Bool {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return false }
        return PlanStep.isNeeded(for: account)
    }

    /// One fetch's plan reading. Remembered (for "Detect automatically") and
    /// applied through the store's serialized queue, which re-judges it
    /// against the CURRENT record — a user choice that landed first wins.
    /// Best effort: a removed account or a failed save just drops it.
    func applyDetectedPlan(accountID: UUID, detection: PlanDetection?, at moment: Date) async {
        guard
            let detection,
            notePlanDetection(accountID: accountID, detection: detection, at: moment),
            let account = accounts.first(where: { $0.id == accountID }),
            account.applyingDetectedPlan(detection) != account
        else { return }
        try? await accountStore.applyDetectedPlan(id: accountID, detection: detection)
    }

    /// Remembers a reading for a live account, unless a newer one is already
    /// known. False = dropped (account gone or going, or an older reading).
    @discardableResult
    private func notePlanDetection(accountID: UUID, detection: PlanDetection, at moment: Date) -> Bool {
        guard
            !removingAccountIDs.contains(accountID),
            !alertTombstones.contains(accountID),
            accounts.contains(where: { $0.id == accountID })
        else { return false }
        if let known = latestPlanDetections[accountID], known.at > moment { return false }
        latestPlanDetections[accountID] = (detection, moment)
        return true
    }

    /// `account` as switch advice should size it: the newest plan reading
    /// (this revision's snapshot or a later background read) applied on the
    /// fly — a `.user` choice still wins — so a notification composed while
    /// the plan save is suspended does not use the previous plan.
    private func withLatestDetectedPlan(
        _ account: AccountRecord,
        snapshot: UsageSnapshot?
    ) -> AccountRecord {
        var newest = latestPlanDetections[account.id]
        if let snapshot, let detection = snapshot.planDetection,
           newest.map({ snapshot.fetchedAt >= $0.at }) ?? true {
            newest = (detection, snapshot.fetchedAt)
        }
        guard let newest else { return account }
        return account.applyingDetectedPlan(newest.detection)
    }

    /// Claude reads its plan with a request of its own; it runs here, apart
    /// from the usage fetch, so a slow list never holds usage up. The read
    /// goes through the session manager, so a timeout recycles the view like
    /// any other bridge call; the result is applied through the store.
    private func refreshPlanInBackground(account: AccountRecord, snapshot: UsageSnapshot) {
        guard
            account.provider == .claude,
            snapshot.organizationID != nil,
            planRefreshTasks[account.id] == nil,
            !hasOpenSignInSession(account)
        else { return }
        let organizationID = snapshot.organizationID
        let revision: UInt64 = (planRequestRevision[account.id] ?? 0) &+ 1
        planRequestRevision[account.id] = revision
        planRefreshTasks[account.id] = Task { @MainActor [weak self] in
            defer { self?.planRefreshTasks[account.id] = nil }
            guard let self else { return }
            // The task starts on a later turn: a sign-in window may have
            // opened on this account's web view since it was scheduled.
            guard !self.hasOpenSignInSession(account) else { return }
            let detection = try? await self.sessionManager.refreshPlanDetection(
                for: account,
                snapshot: snapshot
            )
            // The reading describes the org it was read for: drop it if the
            // account has since moved to another workspace (its current
            // snapshot names a different org) or a newer read superseded it.
            guard
                !Task.isCancelled,
                self.planRequestRevision[account.id] == revision,
                let current = self.snapshotStore.snapshot(for: account.id)?.organizationID,
                current == organizationID
            else { return }
            await self.applyDetectedPlan(accountID: account.id, detection: detection, at: self.now())
        }
    }

    /// Cursor's per-account history as last persisted (mirrors the store so
    /// views observing `AppModel` redraw when it changes).
    @Published private(set) var cursorSpendHistories: [UUID: CursorSpendHistory] = [:]

    /// The account's stored closed cycles, oldest first.
    func cursorSpendCycles(for accountID: UUID) -> [CursorSpendCycle] {
        cursorSpendHistories[accountID]?.cycles ?? []
    }

    /// Reads Cursor's past cycles in the background when some are owed: the
    /// one-time backfill (12 cycles), or the cycle that just closed after a
    /// rollover. Never awaited by the poll that triggered it, and at most one
    /// per account at a time; `CursorSpendHistoryPlanner` limits a failed read
    /// to one retry per day. A read that fails leaves the cycles untouched.
    private func refreshCursorHistoryInBackground(account: AccountRecord, snapshot: UsageSnapshot) {
        guard
            account.provider == .cursor,
            let currentStart = snapshot.cursorSpend?.periodStart,
            cursorHistoryTasks[account.id] == nil,
            isLiveAccount(account.id),
            // Never while a sign-in/reauth session uses this account's view —
            // the same rule the refresh coordinator applies at dispatch.
            !hasOpenSignInSession(account)
        else { return }
        let moment = now()
        let accountID = account.id
        let rollback = pendingAttemptRollbacks[accountID]
        let planned = CursorSpendHistoryPlanner.request(
            history: cursorHistoryStore.history(for: accountID),
            currentPeriodStart: currentStart,
            now: moment
        )
        guard rollback != nil || planned != nil else { return }
        cursorHistoryTasks[accountID] = Task { @MainActor [weak self] in
            defer { self?.cursorHistoryTasks[accountID] = nil }
            guard let self else { return }
            var request = planned
            if let rollback {
                // A hand-back that failed earlier goes first, so its stamp
                // does not block today's retry; the plan is then re-made.
                let handedBack = await self.handBackAttempt(
                    accountID: accountID, stamp: rollback.stamp, previous: rollback.previous
                )
                guard handedBack else { return }
                request = CursorSpendHistoryPlanner.request(
                    history: self.cursorHistoryStore.history(for: accountID),
                    currentPeriodStart: currentStart,
                    now: moment
                )
            }
            guard let request else { return }
            let isLive: @MainActor () -> Bool = { [weak self] in
                self?.isLiveAccount(accountID) ?? false
            }
            let isSuppressed: @MainActor () -> Bool = { [weak self] in
                guard let self else { return true }
                return self.hasOpenSignInSession(account)
            }
            // A session that opened since the poll: skip, consuming nothing.
            guard !isSuppressed() else { return }
            let previous = self.cursorHistoryStore.history(for: accountID)
            // Recorded BEFORE the read, so a read that hangs, crashes the page
            // or is cut short by quitting still counts as today's attempt. If
            // the stamp cannot be saved there is no daily limit to rely on:
            // skip the read rather than let every poll start another one.
            let stamped: Bool
            do {
                stamped = try await self.cursorHistoryStore.update(accountID: accountID, isLive: isLive) { history in
                    CursorSpendHistoryPlanner.recordingAttempt(history, at: moment, currentPeriodStart: currentStart)
                }
            } catch {
                return
            }
            guard stamped, !Task.isCancelled else { return }
            let fetched: CursorHistoryFetch?
            do {
                fetched = try await self.sessionManager.fetchCursorSpendHistory(
                    for: account, request: request, isSuppressed: isSuppressed
                )
            } catch is CursorHistoryReadVetoed {
                // Suppressed at dispatch by a sign-in session: nothing reached
                // the page, so the attempt is handed back — the read runs on
                // the next poll after the session closes, not a day later. A
                // failed hand-back stays pending and is retried first.
                _ = await self.handBackAttempt(accountID: accountID, stamp: moment, previous: previous)
                return
            } catch {
                return
            }
            guard let fetched, !Task.isCancelled else { return }
            let landedAt = self.now()
            _ = try? await self.cursorHistoryStore.update(accountID: accountID, isLive: isLive) { history in
                CursorSpendHistoryPlanner.merged(history, fetch: fetched, request: request, now: landedAt)
            }
        }
    }

    /// TEST seam: the account's in-flight history read, if any.
    func cursorHistoryTaskForTesting(accountID: UUID) -> Task<Void, Never>? {
        cursorHistoryTasks[accountID]
    }

    /// Accounts whose history entry is recorded for deletion but not yet
    /// confirmed gone from disk. The record is itself on disk
    /// (`CursorSpendHistoryStore`), so it survives a relaunch; every later
    /// write, every saved poll and every launch retries it.
    var pendingCursorHistoryRemovals: Set<UUID> { cursorHistoryStore.pendingDeletions }

    private static let cursorHistoryLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.izzy.ration",
        category: "cursor-history"
    )

    private func removeCursorHistory(accountID: UUID) async {
        do {
            try await cursorHistoryStore.remove(accountID: accountID)
        } catch {
            Self.cursorHistoryLogger.error("cursor history deletion failed; recorded for retry")
        }
    }

    /// Retries every recorded deletion.
    func retryPendingCursorHistoryRemovals() async {
        do {
            try await cursorHistoryStore.retryPendingDeletions()
        } catch {
            Self.cursorHistoryLogger.error("cursor history deletion retry failed")
        }
    }

    /// Attempt stamps a sign-in veto could not hand back (a failed save),
    /// with the stamp they replaced. Retried before the account's next
    /// attempt check, so a transient failure never spends the day.
    private var pendingAttemptRollbacks: [UUID: (stamp: Date, previous: CursorSpendHistory)] = [:]

    /// Puts back the attempt stamp `stamp` replaced, unless a later attempt
    /// has already overwritten it. True once nothing is left to hand back.
    private func handBackAttempt(accountID: UUID, stamp: Date, previous: CursorSpendHistory) async -> Bool {
        let isLive: @MainActor () -> Bool = { [weak self] in
            self?.isLiveAccount(accountID) ?? false
        }
        do {
            try await cursorHistoryStore.update(accountID: accountID, isLive: isLive) { history in
                guard history.lastAttemptAt == stamp else { return history }
                var restored = history
                restored.lastAttemptAt = previous.lastAttemptAt
                restored.lastAttemptCycleStart = previous.lastAttemptCycleStart
                return restored
            }
            pendingAttemptRollbacks.removeValue(forKey: accountID)
            return true
        } catch {
            pendingAttemptRollbacks[accountID] = (stamp, previous)
            return false
        }
    }

    /// An account that exists and is not being removed.
    private func isLiveAccount(_ accountID: UUID) -> Bool {
        !removingAccountIDs.contains(accountID)
            && !alertTombstones.contains(accountID)
            && accounts.contains { $0.id == accountID }
    }

    /// TEST barrier: resolves once every background Cursor history read has landed.
    func flushCursorHistoryRefreshes() async {
        while let pending = cursorHistoryTasks.values.first {
            await pending.value
        }
    }

    /// TEST barrier: resolves once every post-sign-in refresh has finished.
    func flushSignInResumeRefreshes() async {
        while let pending = signInResumeRefreshes.values.first {
            await pending.task.value
        }
    }

    /// Test-only: starts the background timer through the same wiring
    /// `load()` uses, without running the rest of `load()`.
    func startBackgroundPollingForTesting() {
        startBackgroundPolling()
    }

    /// Test-only: turns off the coordinator's dispatch-time check, so a test
    /// can pin the timer's account supplier on its own.
    func disableDispatchSuppressionForTesting() {
        refreshCoordinator.isDispatchSuppressed = { _ in false }
    }

    /// Test-only: the accounts the background timer would fetch right now.
    func backgroundRefreshAccountIDsForTesting() -> [UUID] {
        backgroundRefreshAccounts().map(\.id)
    }

    /// TEST barrier: resolves once every background plan read has applied.
    func flushPlanRefreshes() async {
        while let pending = planRefreshTasks.values.first {
            await pending.value
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
            scheduleSwitchAdviceRecompute()
        }
        return Task { [self] in
            defer {
                mutatingAccountIDs.remove(accountID)
                pausingAccountIDs.remove(accountID)
                scheduleSwitchAdviceRecompute()
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

    func setPopoverLayout(_ value: PopoverLayout) async throws {
        try await appSettings.setPopoverLayout(value)
    }

    /// Settings → General → Features. Presentation/gating only: nothing is
    /// re-evaluated or re-primed here — switch advice recomputes through the
    /// existing settings subscription, everything else reads the switch live.
    ///
    /// Turning warm-up OFF is the one exception to "read live": an attempt
    /// may already be past its checks, so the intent is recorded
    /// synchronously here (`warmUpGeneration`, `warmUpDisablesInFlight`)
    /// before the save suspends — see `warmUpStillAllowed`.
    func setFeature(_ feature: FeatureSwitch, enabled: Bool) async throws {
        if feature == .warmUp, !enabled {
            warmUpGeneration &+= 1
            warmUpDisablesInFlight += 1
            defer { warmUpDisablesInFlight -= 1 }
            try await appSettings.setFeature(feature, enabled: enabled)
            return
        }
        if feature == .resets, !enabled {
            resetsDeliveryGeneration &+= 1
            resetsDisablesInFlight += 1
            defer { resetsDisablesInFlight -= 1 }
            try await appSettings.setFeature(feature, enabled: enabled)
            return
        }
        try await appSettings.setFeature(feature, enabled: enabled)
    }

    /// True while a warm-up attempt that captured `generation` may still send:
    /// the switch is on, no disable is mid-save, and no disable happened since
    /// the capture (an OFF→ON flip in between still invalidates it).
    private func warmUpStillAllowed(_ generation: UInt64) -> Bool {
        appSettings.featureWarmUpEnabled
            && warmUpDisablesInFlight == 0
            && warmUpGeneration == generation
    }

    // Draft pass-throughs (not the whole-pair `setThresholds(_:…)`/
    // `setCursorSpend(_:)`): the Alerts pane commits a row's edited fields as
    // one draft, and the unedited field is read from the store inside the
    // serialized mutation, never from a copy the pane held. They return the
    // pair as saved, which the pane shows. See
    // `AppSettings.setThresholds(warning:critical:…)`.
    /// Each setter re-evaluates AFTER the settings have actually persisted —
    /// `decideAlerts` reads `appSettings.data` synchronously, so evaluating
    /// before the await would resolve the OLD thresholds. A throw skips the
    /// re-evaluation, which is correct: nothing changed.
    /// See `evaluateAlertsAfterThresholdChange()`.
    @discardableResult
    func setThresholds(
        warning: FieldEdit<Int>,
        critical: FieldEdit<Int>,
        provider: Provider,
        window: UsageWindowKind
    ) async throws -> ThresholdPair {
        let pair = try await appSettings.setThresholds(
            warning: warning,
            critical: critical,
            provider: provider,
            window: window
        )
        evaluateAlertsAfterThresholdChange()
        return pair
    }

    @discardableResult
    func setWarningPercent(_ value: Int, provider: Provider, window: UsageWindowKind) async throws -> ThresholdPair {
        try await setThresholds(warning: .set(value), critical: .keep, provider: provider, window: window)
    }

    @discardableResult
    func setCriticalPercent(_ value: Int, provider: Provider, window: UsageWindowKind) async throws -> ThresholdPair {
        try await setThresholds(warning: .keep, critical: .set(value), provider: provider, window: window)
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

    @discardableResult
    func setCursorSpend(
        warning: FieldEdit<Int?>,
        critical: FieldEdit<Int?>
    ) async throws -> SpendThresholds {
        let spend = try await appSettings.setCursorSpend(warning: warning, critical: critical)
        evaluateAlertsAfterThresholdChange()
        return spend
    }

    @discardableResult
    func setSpendWarningCents(_ value: Int?) async throws -> SpendThresholds {
        try await setCursorSpend(warning: .set(value), critical: .keep)
    }

    @discardableResult
    func setSpendCriticalCents(_ value: Int?) async throws -> SpendThresholds {
        try await setCursorSpend(warning: .keep, critical: .set(value))
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

    /// Also drops the holiday's label editor: a label edit whose save failed
    /// is otherwise kept for a quit to retry, which is pointless once the
    /// holiday is gone.
    func removeHoliday(id: UUID) async throws {
        try await appSettings.removeHoliday(id: id)
        pendingEdits.removeEditor(forKey: HolidayLabelEditor.registryKey(holidayID: id))
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

    /// Re-reads the OS notification permission mid-session — called when the
    /// app becomes active or one of its windows (popover included) becomes
    /// key. Without it the posting gate was decided once per process (the
    /// `.startup` pass) or per toggle tap, so allowing notifications in
    /// System Settings kept posts dropped until relaunch, and revoking left
    /// `alertsActive == true` with posts vanishing and no banner.
    ///
    /// A pass on `alertsLifecycleChain` like any other (I5), but it does NOT
    /// claim a version: it is an observation, not a request, so it must never
    /// supersede a tap. It captures the current version and yields to any
    /// request claimed while it waits. Prompt-free (status query only), never
    /// writes settings, and does nothing unless alerts are hydrated, desired
    /// and not divergently parked — the startup pass's own preconditions.
    @discardableResult
    func recheckNotificationAuthorization() -> Task<Void, Never> {
        let version = alertsDesiredVersion
        let prev = alertsLifecycleChain
        let task = Task { [self] in
            _ = await prev?.value
            await recheckAuthorizationPass(version: version)
        }
        alertsLifecycleChain = task
        return task
    }

    private func recheckAuthorizationPass(version: Int) async {
        // Parked is rejected only when divergent — the startup pass's own
        // moot-convergence predicate. A park whose desired value already
        // matches the durable setting converged at startup without clearing
        // the flag; refusing it here would disable rechecks for the session.
        guard version == alertsDesiredVersion,
              alertsHydrated, alertsDesired,
              !alertsLifecycleParked || alertsDesired == appSettings.usageAlertsEnabled
        else { return }
        let permission = await notificationScheduler.authorizationStatus()
        guard version == alertsDesiredVersion else { return }
        // Only on change: this runs on every focus change, and each
        // assignment would re-publish the model.
        if notificationPermission != permission { notificationPermission = permission }
        if permission == .allowed {
            // Same authorize-then-prime-then-open order as the other passes.
            // The sink kept evaluating while unauthorized (it gates on the
            // master switch, not on this gate), so the prime normally finds
            // nothing new — and it posts nothing by construction either way.
            if !alertsActive {
                primeAllAlerts()
                alertsActive = true
            }
        } else if alertsActive {
            alertsActive = false
        }
    }

    /// The **Allow Notifications** click — the ONLY path that may show the
    /// macOS permission prompt without a Usage-alerts toggle. For the
    /// never-asked case: startup and rechecks only read the status, and an
    /// app appears in System Settings › Notifications only once it has asked,
    /// so pointing a never-asked user there strands them.
    ///
    /// Shaped like `recheckNotificationAuthorization()`: a link on
    /// `alertsLifecycleChain` that claims NO version (it changes no desired
    /// state and never writes settings), so a toggle landing while the
    /// prompt is up supersedes it and its late answer is dropped. Same
    /// preconditions too — a stale button with alerts off does nothing.
    @discardableResult
    func requestNotificationPermission() -> Task<Void, Never> {
        let version = alertsDesiredVersion
        let prev = alertsLifecycleChain
        let task = Task { [self] in
            _ = await prev?.value
            await notificationPermissionRequestPass(version: version)
        }
        alertsLifecycleChain = task
        return task
    }

    private func notificationPermissionRequestPass(version: Int) async {
        // The recheck's preconditions. Known gap, kept on purpose: after a
        // toggle-off whose write failed (desired OFF, durable still ON) the
        // UI — which reads the durable setting — still shows Allow, but the
        // click is a no-op here: the session's last request was "off", and
        // prompting for it would contradict that.
        guard version == alertsDesiredVersion,
              alertsHydrated, alertsDesired,
              !alertsLifecycleParked || alertsDesired == appSettings.usageAlertsEnabled
        else { return }
        _ = await notificationScheduler.requestAuthorization()
        guard version == alertsDesiredVersion else { return }
        // Publish what macOS reports, not the request's Bool: an errored
        // request returns false while the status is still `.notDetermined`,
        // and `.denied` would swap Allow for a Settings link that can't help.
        let permission = await notificationScheduler.authorizationStatus()
        guard version == alertsDesiredVersion else { return }
        notificationPermission = permission
        if permission == .allowed {
            // Authorize-then-prime-then-open, as in every pass. The flip bumps
            // the activation generation, so a crossing queued while not asked
            // can't post in this activation either.
            if !alertsActive {
                primeAllAlerts()
                alertsActive = true
            }
        } else if alertsActive {
            alertsActive = false
        }
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
            _ = await notificationScheduler.requestAuthorization()
            guard version == alertsDesiredVersion else { return }
            // What macOS reports, not the request's Bool — see
            // `notificationPermissionRequestPass`.
            let permission = await notificationScheduler.authorizationStatus()
            guard version == alertsDesiredVersion else { return }
            notificationPermission = permission
            guard permission == .allowed else {
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
            // Status only: a launch never prompts, `.notDetermined` included
            // — asking takes an explicit click (`requestNotificationPermission`).
            let permission = await notificationScheduler.authorizationStatus()
            guard version == alertsDesiredVersion else { return }
            notificationPermission = permission
            guard permission == .allowed else {
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
            // I3: startup-after-converged-enable does not re-prime. Reaching
            // this line means no request claimed a newer version since this
            // pass captured its own, so no `.userRequest` pass can have opened
            // the gate meanwhile (claiming bumps the version synchronously, at
            // the tap). `load()` is single-flight (`loadStarted`), so there is
            // no second startup pass either. The one thing that CAN have
            // opened it is `recheckNotificationAuthorization()`: it claims no
            // version, and one requested before hydration completes may still
            // be queued AHEAD of this pass (behind a slow deferred persist)
            // when `alertsHydrated` flips — it then runs first, finds alerts
            // desired and authorized, primes and opens the gate. Then this
            // branch is live and must not prime twice.
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

    /// Reset-credit alerts are suppressed while the Resets feature is off.
    private func featureAllowsDelivery(_ event: AlertEvent) -> Bool {
        switch event {
        case .resetCreditAvailable, .resetCreditExpiring:
            appSettings.featureResetsEnabled && resetsDisablesInFlight == 0
        default: true
        }
    }

    /// A reset notification queued before a Resets switch-off is dead, even
    /// if the switch has been turned back on since. Other events pass.
    private func resetsGenerationAllows(_ event: AlertEvent, queuedAt generation: UInt64) -> Bool {
        switch event {
        case .resetCreditAvailable, .resetCreditExpiring: resetsDeliveryGeneration == generation
        default: true
        }
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
        // A reset row that the Resets feature hides must not lift the snooze
        // either — the panel would come back with nothing new on it.
        let resetCreditsDropOn = appSettings.featureResetsEnabled && appSettings.data.channels(
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

        // Posting eligibility is decided at ENQUEUE time too: a decision made
        // while the gate is shut advances the watermark and posts nothing
        // (the same outcome priming produces), rather than queueing a post
        // that a later activation could release.
        guard alertsActive else { return }
        let activation = alertsActivationGeneration
        let resetsGeneration = resetsDeliveryGeneration
        // A feature that is off right now never queues a post: re-enabling it
        // later must not release what was decided while it was off.
        for event in events where featureAllowsDelivery(event) {
            let notificationID = AlertMessage.id(for: event, accountID: accountID)
            alertSideEffectQueue.enqueue { [weak self] in
                guard
                    let self,
                    self.alertsActive,
                    self.alertsActivationGeneration == activation,
                    // The per-cell notification channel. Resolved at EXECUTION
                    // time like every other gate here, so toggling the checkbox
                    // while an item waits behind earlier side effects is
                    // honoured. `nil` key = no cell governs this event (reset,
                    // reauth, rate-limit) — those always deliver.
                    self.notificationChannelAllows(event, accountID: accountID),
                    // Global feature switches gate DELIVERY only; the event was
                    // still evaluated and recorded, so re-enabling a feature
                    // does not replay what happened while it was off.
                    self.featureAllowsDelivery(event),
                    // …and no switch-off since this was queued (ON→OFF→ON).
                    self.resetsGenerationAllows(event, queuedAt: resetsGeneration),
                    !self.alertTombstones.contains(accountID),
                    !self.removingAccountIDs.contains(accountID),
                    !self.pausingAccountIDs.contains(accountID),
                    self.accounts.first(where: { $0.id == accountID })?.isPaused != true
                else { return }
                // Read the privacy flag and render the copy HERE, at post
                // time — not at enqueue time. A user who enables "hide account
                // details" while this item waits behind earlier side effects
                // must not have the already-rendered label/percentage posted.
                // Switch advice is recomputed at the same moment from the
                // stores, the pause/removal markers and the clock — not read
                // from the published value, which only refreshes on a pass or
                // tick and can still name a target that has since started
                // pausing or had its window overtaken by a reset.
                // Only limit crossings use it.
                let advice: SwitchAdvice? = self.currentAdvice(forAccount: accountID)
                let (title, body) = AlertMessage.text(
                    for: event,
                    accountLabel: label,
                    redacted: self.appSettings.redactNotifications,
                    advice: advice
                )
                await self.notificationScheduler.post(
                    id: notificationID,
                    title: title,
                    body: body
                )
            }
        }
    }

    /// Web views abandoned since launch because they ignored their
    /// `about:blank` teardown. Diagnostic only: no UI reads it.
    var abandonedWebViewCount: Int { sessionManager.abandonedWebViewCount }

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

    /// Test-only: the remembered plan reading for `accountID`.
    func latestPlanDetectionForTesting(accountID: UUID) -> PlanDetection? {
        latestPlanDetections[accountID]?.detection
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

    /// TEST barrier: resolves once every issued teardown has been judged.
    func flushTeardownChecks() async {
        await sessionManager.flushTeardownChecks()
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
        guard !hasOpenSignInSession(account) else {
            errorMessage = "Debug send: a sign-in window is open for this account."
            return
        }
        sendingKeepAliveAccountIDs.insert(account.id)
        defer { sendingKeepAliveAccountIDs.remove(account.id) }
        errorMessage = "Debug send: warming session…"
        // Even a manual debug send honours the global warm-up switch.
        let warmUpGenerationAtStart = warmUpGeneration
        guard warmUpStillAllowed(warmUpGenerationAtStart) else {
            errorMessage = "Debug send: Claude warm-up is turned off."
            return
        }
        do {
            // Bind the debug send to the warm-up snapshot's org when it
            // succeeded; a failed warm-up falls back to live discovery (nil),
            // which matches the user's manual send-now intent.
            let warmUpSnapshot = try? await sessionManager.fetchUsage(for: account)
            // Every await below can see a sign-in window open on this view.
            guard !hasOpenSignInSession(account) else {
                errorMessage = "Debug send: a sign-in window opened; skipped."
                return
            }
            let prepared = try await sessionManager.prepareKeepAlive(
                for: account,
                boundToOrganizationID: warmUpSnapshot?.organizationID
            )
            let receipt = try await sessionManager.sendKeepAlive(
                prepared: prepared,
                conversationID: account.keepAliveConversationID,
                for: account,
                mayPost: { [weak self] in
                    guard let self, self.warmUpStillAllowed(warmUpGenerationAtStart) else {
                        throw CancellationError()
                    }
                    guard !self.hasOpenSignInSession(account) else {
                        throw CancellationError()
                    }
                }
            )
            // Same classification as the automatic warm-up: a refusal inside
            // the stream is reported as one and records no started window.
            // Nothing was reserved before this manual send.
            let landed = WarmUpOutcome.landed(receipt, at: now(), reserved: false)
            await recordWarmUpOutcome(landed, accountID: account.id)
            if let streamError = landed.streamErrorType {
                errorMessage = "Debug send REFUSED in the reply (\(streamError.rawValue)). "
                    + "Nothing recorded as started."
                return
            }
            let conversationID = receipt.conversationID
            try await accountStore.recordAutoStart(
                id: account.id,
                conversationID: conversationID,
                at: now()
            )
            if hasOpenSignInSession(account) {
                errorMessage = "Debug send OK; refetch skipped (a sign-in window is open)."
                return
            }
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
            cursorSpendHistoryStore: CursorSpendHistoryStore(
                fileURL: baseDirectory.appending(path: "cursor-spend-history.json")
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
            // Cursor's past-cycle totals: non-fatal like the alert state, and
            // pruned the same way — an entry left by a removal that did not
            // finish (crash, force-quit) belongs to no account.
            await cursorHistoryStore.load()
            for orphanID in cursorHistoryStore.histories.keys where !activeAccountIDs.contains(orphanID) {
                try? await cursorHistoryStore.remove(accountID: orphanID)
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
            // the sink. Everything ahead of this pass in the chain is either
            // .coldStartDeferred (persist-only) or a notification recheck
            // (one status query) — both prompt-free — so this await is
            // bounded by settings-save and status-query round-trips.
            _ = await startup.value

            await historyStore.load(activeAccountIDs: Set(accountStore.accounts.map(\.id)))
            await retryProfileCleanup()
            await performLaunchProfileHygiene()
            // Begin observing sleep / memory-pressure to release idle WebViews.
            systemPowerObserver.start()
            startSwitchAdviceTimer()

            guard startBackgroundRefresh else { return }
            startBackgroundPolling()
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

    // MARK: Switch advice

    /// Clock tick that ages IN USE into "last used" — nothing else changes
    /// when the user simply stops working. Started in `load()`, stopped in
    /// `stop()`.
    private var switchAdviceTimer: Timer?
    /// The pending coalesced recompute, if any: a burst of triggers in one
    /// run-loop turn yields one recompute (and at most one publication).
    private var switchAdviceRecompute: Task<Void, Never>?
    static let switchAdviceTickInterval: TimeInterval = 60

    /// The advice whose in-use account is `id` (the account a Warn names).
    func advice(forAccount id: UUID) -> SwitchAdvice? {
        switchAdvice.first { $0.fromAccountID == id }
    }

    /// Advice for `id` as of right now, computed synchronously from the
    /// stores' current state, the markers and the injected clock — without
    /// publishing. For consumers that must not act on a value up to a tick old.
    func currentAdvice(forAccount id: UUID) -> SwitchAdvice? {
        computeSwitchAdvice(
            snapshots: snapshotStore.snapshots,
            states: refreshCoordinator.states,
            now: now()
        ).first { $0.fromAccountID == id }
    }

    /// Recomputes from the stores' current state. The injected clock by default.
    func recomputeSwitchAdvice(now date: Date? = nil) {
        recomputeSwitchAdvice(
            snapshots: snapshotStore.snapshots,
            states: refreshCoordinator.states,
            now: date ?? now()
        )
    }

    /// The 60 s tick's body (internal so tests can drive it without a timer).
    func switchAdviceTick() {
        scheduleSwitchAdviceRecompute()
    }

    /// TEST barrier: resolves once a scheduled recompute has run.
    func flushSwitchAdvice() async {
        while let pending = switchAdviceRecompute {
            await pending.value
        }
    }

    private func scheduleSwitchAdviceRecompute() {
        guard switchAdviceRecompute == nil else { return }
        switchAdviceRecompute = Task { @MainActor [weak self] in
            guard let self else { return }
            self.switchAdviceRecompute = nil
            self.recomputeSwitchAdvice()
        }
    }

    private func startSwitchAdviceTimer() {
        guard switchAdviceTimer == nil else { return }
        let timer = Timer(timeInterval: Self.switchAdviceTickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.switchAdviceTick()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        switchAdviceTimer = timer
    }

    /// One pass over the given revision. `snapshots` / `states` are passed in
    /// because the alert sink runs from `@Published`'s `willSet`, before the
    /// stores' storage holds them. History is read as it will be once this
    /// revision's snapshots are recorded (`record` runs after the save), so a
    /// crossing and the account's first activity in the same refresh are
    /// seen together. In-memory reads only — no disk on a tick.
    private func recomputeSwitchAdvice(
        snapshots: [UUID: UsageSnapshot],
        states: [UUID: AccountViewState],
        now date: Date
    ) {
        let advice: [SwitchAdvice] = computeSwitchAdvice(snapshots: snapshots, states: states, now: date)
        if advice != switchAdvice {
            switchAdvice = advice
        }
    }

    private func computeSwitchAdvice(
        snapshots: [UUID: UsageSnapshot],
        states: [UUID: AccountViewState],
        now date: Date
    ) -> [SwitchAdvice] {
        // Off (or in-use detection off, which advice is built on): nothing is
        // advised anywhere — header, notification line, drop arrow, Focus.
        guard appSettings.features.switchAdviceEffective else { return [] }
        let advisable: [AccountRecord] = AccountVisibility.visible(accounts).filter { account in
            !removingAccountIDs.contains(account.id) && !pausingAccountIDs.contains(account.id)
        }.map { withLatestDetectedPlan($0, snapshot: snapshots[$0.id]) }
        let presentations: [AccountPresentation] = Self.makePresentations(
            accounts: advisable,
            snapshots: snapshots,
            states: states,
            sortByWeeklyReset: appSettings.sortByWeeklyReset
        )
        // With the lookahead: this pass may run before `record` has seen
        // the revision's snapshots.
        let activity: [UUID: ActiveUsage] = ActiveUsageMap.computePerAccount(
            accounts: advisable,
            history: historyStore,
            now: date,
            including: snapshots
        )
        let phases: [UUID: InUsePhase] = Self.inUsePhases(activity, now: date)
        let settings: AppSettingsData = appSettings.data
        return SwitchAdvisor.advice(
            presentations: presentations,
            phases: phases,
            thresholds: { provider, kind in settings.thresholds(provider: provider, window: kind) },
            fableCounts: fableCounter(snapshots: snapshots),
            now: date
        )
    }

    /// Per-account phases (every burning account, not the popover's one
    /// winner per provider) — the one rule for switch advice and Focus.
    static func inUsePhases(_ activity: [UUID: ActiveUsage], now date: Date) -> [UUID: InUsePhase] {
        var phases: [UUID: InUsePhase] = [:]
        for (id, usage) in activity {
            phases[id] = InUsePhase.classify(usage, now: date)
        }
        return phases
    }

    /// "Does Fable count for this account": the cached history verdict,
    /// else the snapshot fallback. In-memory only.
    private func fableCounter(snapshots: [UUID: UsageSnapshot]) -> (UUID) -> Bool {
        let verdicts: [UUID: FableUsage.Verdict] = fableVerdicts
        return { id in
            FableUsage.counts(verdict: verdicts[id] ?? .unknown, snapshot: snapshots[id])
        }
    }

    /// The Focus layout's content as of `date`, from the same inputs switch
    /// advice uses: per-account phases over non-paused accounts, the cached
    /// Fable verdicts, the published advice, the alert thresholds (for the
    /// nearly-spent lines). All presentations — paused ones included — so
    /// Focus can list them. `pinnedHeroID`: the surface's picked hero.
    /// In-memory reads only.
    func focusModel(now date: Date, pinnedHeroID: UUID? = nil) -> FocusModel {
        let active: [AccountRecord] = visibleAccounts
        // In-use detection off: no phases, so no IN USE tags and the hero
        // falls back to the least-headroom account.
        let activity: [UUID: ActiveUsage] = appSettings.featureInUseEnabled
            ? ActiveUsageMap.computePerAccount(accounts: active, history: historyStore, now: date)
            : [:]
        return FocusModel.make(
            presentations: presentations,
            phases: Self.inUsePhases(activity, now: date),
            advice: switchAdvice,
            fableCounts: fableCounter(snapshots: snapshotStore.snapshots),
            thresholds: { [settings = appSettings.data] provider, kind in
                settings.thresholds(provider: provider, window: kind)
            },
            pinnedHeroID: pinnedHeroID,
            now: date
        )
    }

    /// The popover's account list for one revision: store order, then the
    /// display sort. Shared by `presentations` and switch advice so ties
    /// resolve in the order the user sees.
    static func makePresentations(
        accounts: [AccountRecord],
        snapshots: [UUID: UsageSnapshot],
        states: [UUID: AccountViewState],
        sortByWeeklyReset: Bool
    ) -> [AccountPresentation] {
        let mapped: [AccountPresentation] = accounts.map { account in
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

    // MARK: Fable verdict cache

    /// Per-account `FableUsage` verdict from rollup history, hydrated off the
    /// UI path after each history ingestion so switch advice never reads disk
    /// on a tick. Deliberately NOT `@Published`: consumers are recomputed via
    /// `fableVerdictsDidChange()`. A missing entry means "not hydrated yet",
    /// which `FableUsage.counts` treats like `.unknown`.
    private(set) var fableVerdicts: [UUID: FableUsage.Verdict] = [:]

    /// The latest in-flight hydration per account. Only the newest generation
    /// may commit, so an older, slower read can't overwrite a newer verdict.
    private var fableVerdictRefreshes: [UUID: (generation: Int, task: Task<Void, Never>)] = [:]
    private var fableVerdictGeneration = 0

    /// Re-derives the account's verdict from history. Called right after
    /// `historyStore.record` for that snapshot, so the rollup the read sees
    /// includes it (`loadRecentRollups` overlays the in-memory month).
    private func refreshFableVerdict(accountID: UUID, snapshot: UsageSnapshot) {
        guard snapshot.modelWeekly != nil else {
            // No Fable window → `counts` is false whatever history says; skip
            // the disk read and forget any verdict from an older shape.
            fableVerdictRefreshes.removeValue(forKey: accountID)
            if fableVerdicts.removeValue(forKey: accountID) != nil {
                fableVerdictsDidChange()
            }
            return
        }
        fableVerdictGeneration += 1
        let generation = fableVerdictGeneration
        let store = historyStore
        // Only the months that can hold the lookback, both kinds in one pass,
        // filtered off the main actor — not every retained month twice.
        let since: Date = now().addingTimeInterval(-FableUsage.lookback)
        let task = Task { @MainActor [weak self] in
            let recent = await store.loadRecentRollups(
                accountID: accountID,
                kinds: [.weekly, .modelWeekly],
                since: since
            )
            self?.commitFableVerdict(
                accountID: accountID,
                generation: generation,
                weekly: recent[.weekly] ?? [],
                fable: recent[.modelWeekly] ?? []
            )
        }
        fableVerdictRefreshes[accountID] = (generation, task)
    }

    private func commitFableVerdict(
        accountID: UUID,
        generation: Int,
        weekly: [UsageHourlyBucket],
        fable: [UsageHourlyBucket]
    ) {
        guard fableVerdictRefreshes[accountID]?.generation == generation else { return }
        fableVerdictRefreshes.removeValue(forKey: accountID)
        // The account may have been removed or paused while the read was off
        // the main actor; a verdict for it would describe nothing advisable.
        guard
            let account = accounts.first(where: { $0.id == accountID }),
            !account.isPaused,
            !removingAccountIDs.contains(accountID)
        else { return }
        let verdict = FableUsage.verdict(weekly: weekly, fable: fable, now: now())
        guard fableVerdicts[accountID] != verdict else { return }
        fableVerdicts[accountID] = verdict
        fableVerdictsDidChange()
    }

    /// Hook run after every `fableVerdicts` change. Switch advice recomputes
    /// from here.
    func fableVerdictsDidChange() {
        scheduleSwitchAdviceRecompute()
    }

    /// TEST-ONLY barrier (no production caller): resolves once every
    /// in-flight verdict hydration has committed or been discarded.
    func flushFableVerdicts() async {
        while let pending = fableVerdictRefreshes.values.first {
            await pending.task.value
            // A task that lost its generation leaves the newer entry in place;
            // one whose owner is gone can't clear itself — drop it here.
            if fableVerdictRefreshes.values.contains(where: { $0.generation == pending.generation }) {
                fableVerdictRefreshes = fableVerdictRefreshes.filter { $0.value.generation != pending.generation }
            }
        }
    }

    func stop() {
        refreshCoordinator.stopBackgroundRefresh()
        for task in planRefreshTasks.values { task.cancel() }
        for task in cursorHistoryTasks.values { task.cancel() }
        systemPowerObserver.stop()
        switchAdviceTimer?.invalidate()
        switchAdviceTimer = nil
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
        let baseAccount = AccountRecord(
            id: session.accountID,
            provider: session.provider,
            label: trimmedLabel,
            webProfileID: session.webProfileID,
            displayOrder: session.isNewAccount ? accounts.count : existingOrder(session),
            createdAt: session.isNewAccount ? now() : existingCreatedAt(session),
            autoStartFiveHour: session.isNewAccount
                && WarmUpDefaults.autoStartForNewAccount(provider: session.provider)
        )
        let snapshot = try await sessionManager.fetchUsage(for: baseAccount)
        // A new account starts with whatever plan its first fetch read.
        // Sign-in is the one place that WAITS for Claude's separate plan read
        // (so the add-account plan step can be prefilled); polling never does.
        let signInDetection: PlanDetection? = await signInPlanDetection(
            for: baseAccount,
            snapshot: snapshot
        )
        let account: AccountRecord = signInDetection.map { detection in
            baseAccount.applyingDetectedPlan(detection)
        } ?? baseAccount
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
                    refreshFableVerdict(accountID: account.id, snapshot: snapshot)
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
                refreshFableVerdict(accountID: account.id, snapshot: snapshot)
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
                // The account is live but its snapshot never landed.
                refreshAfterSignInClosed(accountID: session.accountID)
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
        // Re-auth keeps the stored record: apply the reading through the
        // store (never over a user choice). New accounts got it at creation;
        // this call then only remembers it for "Detect automatically".
        await applyDetectedPlan(
            accountID: account.id,
            detection: signInDetection,
            at: snapshot.fetchedAt
        )
    }

    /// The sign-in fetch's reading, else Claude's separate plan read. Best
    /// effort: any failure reads as "not read".
    private func signInPlanDetection(
        for account: AccountRecord,
        snapshot: UsageSnapshot
    ) async -> PlanDetection? {
        if let detection = snapshot.planDetection { return detection }
        return (try? await sessionManager.refreshPlanDetection(for: account, snapshot: snapshot)) ?? nil
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
            // Polls skipped this account while the window was open.
            refreshAfterSignInClosed(accountID: session.accountID)
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
            accounts: pollableAccounts,
            reason: reason
        )
    }

    func prepareForTermination() async -> Bool {
        // First, and whatever the veto below decides: a Settings edit still in
        // its debounce or being saved lands before the process can exit. At
        // most `PendingEditRegistry.terminationTimeout`, so a stuck save never
        // blocks quitting. Runs on the main actor, which AppKit keeps serving
        // while a `.terminateLater` decision is open (probed; see
        // `applicationShouldTerminate` for the one exception).
        //
        // The 2 s bound is INTENTIONAL, and a false result (timed out) does
        // not hold the quit: Settings writes are local files and finish in
        // milliseconds, so a save still running after 2 s is stuck, and a
        // log out or restart must never hang on it. The edit can be lost
        // only when its save has been stuck for more than 2 s.
        await pendingEdits.flushAll()
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
                // The account left the advisable set while its marker was
                // held; a failed / rolled-back removal must bring its advice
                // back now, not at the next tick.
                scheduleSwitchAdviceRecompute()
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
        // Any Cursor history read in flight: cancelled before the profile is
        // touched, which reaps its page (its stored totals go last, below).
        cursorHistoryTasks.removeValue(forKey: id)?.cancel()
        pendingAttemptRollbacks.removeValue(forKey: id)
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
        // Its plan readings and any background plan read.
        latestPlanDetections.removeValue(forKey: id)
        planRefreshTasks.removeValue(forKey: id)?.cancel()
        planRequestRevision.removeValue(forKey: id)
        // Its Fable verdict too; an in-flight hydration for it is discarded at
        // commit (the account is gone).
        if fableVerdicts.removeValue(forKey: id) != nil {
            fableVerdictsDidChange()
        }
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
        // Its Cursor spend history. Last, so the synchronous run above stays
        // unbroken. The store's queue runs this after any update already
        // queued; a later update sees the tombstone (`isLiveAccount`) and
        // drops itself, so nothing can bring the entry back. A failed delete
        // is kept pending and retried (see `removeCursorHistory`).
        await removeCursorHistory(accountID: id)
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
/// rather than inlined so the tests assert against the same text the model
/// publishes. Resolved in the running language on every read.
enum ProfileCleanupCopy {
    static var pending: String { pending(locale: .current) }
    static var blockingQuit: String { blockingQuit(locale: .current) }
    static var blockingQuitOnSignIn: String { blockingQuitOnSignIn(locale: .current) }

    static func pending(locale: Locale) -> String {
        LocalizedStringResource.profileCleanupPending.string(in: locale)
    }

    static func blockingQuit(locale: Locale) -> String {
        LocalizedStringResource.profileCleanupBlockingQuit.string(in: locale)
    }

    static func blockingQuitOnSignIn(locale: Locale) -> String {
        LocalizedStringResource.profileCleanupBlockingQuitOnSignIn.string(in: locale)
    }
}

@MainActor
private final class ProviderContractCaptureErrorRelay {
    weak var model: AppModel?

    func report(_ message: String) {
        model?.errorMessage = message
    }
}

/// The history read was refused at dispatch (a sign-in session holds the view).
struct CursorHistoryReadVetoed: Error {}
