import WebKit
import XCTest
@testable import Ration

/// Shared fixture plumbing for the alert-evaluation test suites
/// (`AppModelAlertsTests`, `AppModelResetCreditsTests`). Moved out of
/// `AppModelAlertsTests.swift` (where these were `private`) so a second
/// suite can build the same `AppModel` wiring without duplicating it.

// MARK: - AlertsFixture

@MainActor
struct AlertsFixture {
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

/// Builds an `AppModel` wired to fresh, isolated stores under a temp
/// directory, with test-double adapters/scheduler/profile-manager.
///
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
///   - now: The model's clock. Defaults to the fixed instant almost every
///     test relies on; a test simulating time actually passing between two
///     "sessions" (e.g. a relaunch that must see fresh evidence become
///     current, or a stored reset enter its expiry window between reads)
///     passes a different fixed instant for the second fixture.
@MainActor
func makeAlertsFixture(
    directory: URL? = nil,
    alertStateStore: AlertStateStore? = nil,
    scheduler: NotificationSchedulingSpy = NotificationSchedulingSpy(),
    hydrationGate: HydrationGate = HydrationGate(),
    appSettings: AppSettings? = nil,
    now: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 1_000) }
) throws -> AlertsFixture {
    let directory = try directory ?? makeTempDirectory()

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
        now: now,
        beforeAlertsHydrationCompletes: { await hydrationGate.hook() },
        systemPowerObserver: NoopSystemPowerObserver()
    )
    return AlertsFixture(
        directory: directory,
        model: model,
        snapshots: snapshots,
        alertStateStore: alertStateStore,
        scheduler: scheduler,
        adapter: adapter,
        chatGPTAdapter: chatGPTAdapter
    )
}

func makeTempDirectory() throws -> URL {
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
func seedUsageAlertsEnabled(in directory: URL) throws {
    try Data(#"{"usageAlertsEnabled":true}"#.utf8)
        .write(to: directory.appending(path: "app-settings.json"))
}

// MARK: - Test doubles

@MainActor
final class AlertsWebProfileManagerSpy: WebProfileManaging {
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
final class AlertsProviderAdapterSpy: ProviderAdapter {
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
final class HydrationGate {
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

/// Records every `post` call and returns configurable authorization results.
/// An `actor` (rather than a locked class) since `NotificationScheduling`
/// requires `Sendable` and its methods are called via `await` from `AppModel`.
actor NotificationSchedulingSpy: NotificationScheduling {
    private(set) var posts: [(id: String, title: String, body: String)] = []
    var authorizationResult = true
    /// Backs `authorizationStatus`: the OS-level status queried on
    /// `load()`, independent of (and not implied by) `requestAuthorization`.
    var authorizationStatusResult: NotificationPermission = .allowed

    /// Version-guard race test seam: when armed, the NEXT call to
    /// `requestAuthorization()` suspends until `releaseAuthorizationRequest`
    /// is called, instead of returning immediately. This lets a test
    /// deterministically interleave a second `setUsageAlertsEnabled` call
    /// while a first one's continuation is still pending inside its own
    /// authorization request — the exact shape of the stale-enable race —
    /// without relying on a sleep or on incidental Task-scheduling order.
    private var gateArmed = false
    private var failNextRequest = false
    private var pendingAuthorizationContinuation: CheckedContinuation<Bool, Never>?
    private var suspendedSignal: CheckedContinuation<Void, Never>?

    /// Startup-pass race seam (mirrors the requestAuthorization gate): when
    /// armed, the NEXT authorizationStatus() call suspends until
    /// releaseStatusQuery, so a test can pin taps to land while load()'s
    /// startup path sits inside its status query.
    private var statusGateArmed = false
    private var pendingStatusContinuation: CheckedContinuation<NotificationPermission, Never>?
    private var statusSuspendedSignal: CheckedContinuation<Void, Never>?
    /// I6 assertion support: counts prompt-capable authorization requests.
    private(set) var requestAuthorizationCallCount = 0
    /// Counts prompt-free status queries, so a no-op recheck can be told
    /// apart from one that queried and then discarded the answer.
    private(set) var authorizationStatusCallCount = 0

    func armStatusGate() {
        statusGateArmed = true
    }

    func waitUntilStatusQueryIsSuspended() async {
        if pendingStatusContinuation != nil { return }
        await withCheckedContinuation { continuation in
            statusSuspendedSignal = continuation
        }
    }

    func releaseStatusQuery(_ result: NotificationPermission) {
        pendingStatusContinuation?.resume(returning: result)
        pendingStatusContinuation = nil
    }

    /// Bool shorthand for the suites written before the tri-state: `false`
    /// is a refusal, never "not asked yet".
    func releaseStatusQuery(_ result: Bool = true) {
        releaseStatusQuery(result ? NotificationPermission.allowed : .denied)
    }

    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        if failNextRequest {
            // An errored request: false, and macOS records no answer.
            failNextRequest = false
            return false
        }
        let result: Bool
        if gateArmed {
            gateArmed = false
            result = await withCheckedContinuation { continuation in
                pendingAuthorizationContinuation = continuation
                suspendedSignal?.resume()
                suspendedSignal = nil
            }
        } else {
            result = authorizationResult
        }
        // Like macOS: an answered prompt is what the status reports next.
        authorizationStatusResult = result ? .allowed : .denied
        return result
    }

    /// The next `requestAuthorization()` returns false WITHOUT changing the
    /// reported status — the shape of a request that errored.
    func failNextRequestWithoutAnswer() {
        failNextRequest = true
    }

    func authorizationStatus() async -> NotificationPermission {
        authorizationStatusCallCount += 1
        guard statusGateArmed else { return authorizationStatusResult }
        statusGateArmed = false
        return await withCheckedContinuation { continuation in
            pendingStatusContinuation = continuation
            statusSuspendedSignal?.resume()
            statusSuspendedSignal = nil
        }
    }

    func setAuthorizationStatusResult(_ value: NotificationPermission) {
        authorizationStatusResult = value
    }

    /// Bool shorthand (see `releaseStatusQuery(_: Bool)`).
    func setAuthorizationStatusResult(_ value: Bool) {
        authorizationStatusResult = value ? .allowed : .denied
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
