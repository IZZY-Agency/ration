import AppKit
import os

// Relaunching after a language change (ruling R1).
//
// The relaunch never goes around the app's quit rules. It records an
// in-memory intent and asks AppKit to terminate, exactly like Quit. The
// termination veto (`applicationShouldTerminate` defers while a sign-in or a
// profile cleanup is unresolved, and `prepareForTermination()` can refuse)
// decides as it always does:
//
// - refused → the intent is cleared and Settings explains why; nothing was
//   launched, so nothing has to be undone;
// - proceeding → `applicationWillTerminate` launches the new instance, the
//   one point where the old instance is certainly going away.
//
// Only the relaunch's OWN termination may launch. AppKit (probed on macOS
// 27.2) does not ask the delegate about a second `terminate()` made while a
// `.terminateLater` decision is pending: it goes straight to
// `applicationWillTerminate`. So "termination is proceeding" is not enough —
// the relaunch's own request must have been asked about AND approved
// (`.terminateNow`, or a `.terminateLater` answered true). Ordinary quits
// also drop the intent up front (`quitWithoutRelaunch()`), and so does a
// log out, restart or shut down (`NSWorkspace.willPowerOffNotification`).
//
// That same AppKit behaviour would let a second Quit skip an open decision
// altogether — quitting before a Settings edit is saved or a cleanup is
// answered. So a quit made while a decision is open JOINS it instead:
// `shouldForwardTermination()` (asked by `TerminationGate`, in front of
// `NSApplication.terminate(_:)`, which every Quit — menu, ⌘Q, popover — ends in) drops the relaunch
// intent and keeps the request from AppKit. Only a decision stuck for
// `forcedQuitAfter` lets a repeated quit through, so a hung cleanup can
// never make the app unquittable.
//
// The new instance then waits (at most 10 s) for the old process to exit
// before it touches the stores, WebKit, the status item or the hot keys.

/// Launches a second copy of the app. Blocks until the system confirms the
/// launch or the wait times out: it runs inside `applicationWillTerminate`,
/// and the process exits as soon as that returns.
@MainActor
protocol NewInstanceLaunching {
    func launchNewInstance(at url: URL, arguments: [String]) -> NewInstanceLaunchOutcome
}

enum NewInstanceLaunchOutcome: Equatable {
    case launched
    /// The system's reason, for the log.
    case failed(String)
    case timedOut
}

@MainActor
protocol AppTerminating {
    /// Asks the app to terminate, subject to the delegate's veto.
    func terminate()
}

@MainActor
protocol RunningApplicationLookup {
    func isRunning(processIdentifier pid: pid_t) -> Bool
}

@MainActor
protocol RelaunchClock {
    func now() -> Date
    func sleep(seconds: TimeInterval) async
}

@MainActor
final class AppRelauncher: ObservableObject {
    enum Status: Equatable {
        case idle
        /// Termination was requested for a relaunch and has not been decided.
        case pending
        /// The last relaunch was refused by the termination veto.
        case refused
    }

    static let shared = AppRelauncher.live()

    @Published private(set) var status: Status = .idle

    private let launcher: any NewInstanceLaunching
    private let terminator: any AppTerminating
    private let clock: any RelaunchClock
    private let handoff: RelaunchHandoff
    private let bundleURL: URL
    private let processID: pid_t
    private let log: (String) -> Void

    init(
        launcher: any NewInstanceLaunching,
        terminator: any AppTerminating,
        clock: any RelaunchClock,
        handoff: RelaunchHandoff,
        bundleURL: URL,
        processID: pid_t,
        powerOffNotifications: NotificationCenter? = nil,
        log: @escaping (String) -> Void
    ) {
        self.launcher = launcher
        self.terminator = terminator
        self.clock = clock
        self.handoff = handoff
        self.bundleURL = bundleURL
        self.processID = processID
        self.log = log
        if let powerOffNotifications {
            observeSystemPowerOff(in: powerOffNotifications)
        }
    }

    static func live() -> AppRelauncher {
        AppRelauncher(
            launcher: WorkspaceInstanceLauncher(),
            terminator: ApplicationTerminator(),
            clock: SystemRelaunchClock(),
            handoff: RelaunchHandoff(defaults: .standard),
            bundleURL: Bundle.main.bundleURL,
            processID: ProcessInfo.processInfo.processIdentifier,
            powerOffNotifications: NSWorkspace.shared.notificationCenter,
            log: { message in AppRelauncher.logger.error("\(message, privacy: .public)") }
        )
    }

    private static let logger = Logger(subsystem: "agency.izzy.ration", category: "relaunch")

    /// How long a relaunch waits for AppKit to consult the delegate before
    /// treating the request as dropped.
    static let unansweredRequestDelay: TimeInterval = 1

    /// A quit decision open this long is treated as stuck: a repeated quit
    /// then goes through (see `shouldForwardTermination()`).
    static let forcedQuitAfter: TimeInterval = 10

    /// Whether `applicationShouldTerminate` ran for the pending request.
    private var terminationWasAsked = false
    /// Whether the delegate let the relaunch's own request proceed
    /// (`.terminateNow`, or a `.terminateLater` answered true).
    private var ownTerminationWasApproved = false
    /// Set while `relaunch()` calls `terminator.terminate()` and consumed by
    /// the first `applicationShouldTerminate`: AppKit consults the delegate
    /// synchronously there, so that request is the relaunch's own. Consumed
    /// rather than reset on return, because a `.terminateLater` decision keeps
    /// `terminate()` inside AppKit's modal loop until it is answered.
    private var isRequestingTermination = false
    /// Quit decisions the delegate has been asked about and not yet answered.
    /// While one is open a new `terminate()` would skip the veto (AppKit goes
    /// straight to `applicationWillTerminate`), so a relaunch is refused.
    private var openTerminationDecisions = 0
    /// When the oldest open decision was asked about.
    private var oldestOpenDecisionAt: Date?
    /// The pending request's fallback check; exposed so tests can await it.
    private(set) var unansweredRequestCheck: Task<Void, Never>?

    /// Records the intent, then asks to terminate. The new instance is
    /// launched only from `terminationWillProceed()`.
    ///
    /// If AppKit never consults the delegate for this request (it can drop a
    /// terminate, e.g. inside a modal loop), the intent falls back to idle
    /// after `unansweredRequestDelay`, so Relaunch now works again. A request
    /// the delegate did see is left to its decision (`.terminateLater` can
    /// take as long as a cleanup does).
    func relaunch() {
        guard status != .pending else { return }
        guard openTerminationDecisions == 0 else {
            // A quit is still waiting for its cleanup; see the property.
            status = .refused
            return
        }
        status = .pending
        terminationWasAsked = false
        ownTerminationWasApproved = false
        unansweredRequestCheck?.cancel()
        isRequestingTermination = true
        terminator.terminate()
        isRequestingTermination = false
        let clock = clock
        unansweredRequestCheck = Task { [weak self] in
            await clock.sleep(seconds: Self.unansweredRequestDelay)
            self?.dropUnansweredRequest()
        }
    }

    /// From `applicationShouldTerminate`: AppKit is deciding a request.
    ///
    /// Only the relaunch's own request keeps the intent. Any other one — the
    /// user's Quit, a logout, restart or shutdown — supersedes it: whichever
    /// decision then lets the app terminate, no new instance is launched.
    func terminationWasRequested() {
        if openTerminationDecisions == 0 {
            oldestOpenDecisionAt = clock.now()
        }
        openTerminationDecisions += 1
        let isOwnRequest: Bool = isRequestingTermination
        isRequestingTermination = false
        guard status == .pending else { return }
        guard isOwnRequest else {
            abandonPendingRelaunch()
            return
        }
        terminationWasAsked = true
    }

    /// From the delegate: the request it was asked about may proceed
    /// (`.terminateNow`, or a `.terminateLater` decision answered true).
    func terminationWasApproved() {
        decisionClosed()
        guard status == .pending, terminationWasAsked else { return }
        ownTerminationWasApproved = true
    }

    /// Every ordinary Quit (the popover footer, its ⌘Q hot key): drops a
    /// pending relaunch, then asks to terminate under the usual veto. A quit
    /// the user chose never starts a new instance.
    func quitWithoutRelaunch() {
        if status == .pending {
            abandonPendingRelaunch()
        }
        guard shouldForwardTermination() else { return }
        terminator.terminate()
    }

    /// Asked before any terminate request reaches AppKit
    /// (`TerminationGate`). While a quit decision is open, a
    /// new request joins it: it drops a pending relaunch and is kept from
    /// AppKit, which would otherwise terminate at once without asking the
    /// delegate — before the open decision's saves and cleanup are done.
    /// That decision's answer then quits (or keeps) the app for both.
    func shouldForwardTermination() -> Bool {
        guard openTerminationDecisions > 0 else { return true }
        if status == .pending {
            abandonPendingRelaunch()
        }
        guard let oldestOpenDecisionAt else { return false }
        let openFor: TimeInterval = clock.now().timeIntervalSince(oldestOpenDecisionAt)
        return openFor >= Self.forcedQuitAfter
    }

    private func decisionClosed() {
        openTerminationDecisions = max(0, openTerminationDecisions - 1)
        if openTerminationDecisions == 0 {
            oldestOpenDecisionAt = nil
        }
    }

    /// Log out, restart or shut down: the app quits with the session, and no
    /// new instance is started into it.
    func systemWillPowerOff() {
        guard status == .pending else { return }
        abandonPendingRelaunch()
    }

    private func observeSystemPowerOff(in center: NotificationCenter) {
        // The token lives as long as the center; the block holds `self` weakly.
        _ = center.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemWillPowerOff()
            }
        }
    }

    private func abandonPendingRelaunch() {
        status = .idle
        terminationWasAsked = false
        ownTerminationWasApproved = false
        unansweredRequestCheck?.cancel()
        unansweredRequestCheck = nil
    }

    private func dropUnansweredRequest() {
        guard status == .pending, !terminationWasAsked else { return }
        status = .idle
    }

    /// The termination veto refused (a `.terminateLater` answered false).
    /// An ordinary quit being refused is not a relaunch failure.
    func terminationWasCancelled() {
        decisionClosed()
        guard status == .pending else { return }
        status = .refused
        terminationWasAsked = false
        ownTerminationWasApproved = false
    }

    /// From `applicationWillTerminate`: termination is really proceeding.
    func terminationWillProceed() {
        // Only the termination the relaunch itself requested, asked about and
        // approved may launch the new instance. Any other one that reaches
        // here — e.g. a second terminate() while the relaunch's own decision
        // is still open — launches nothing.
        guard status == .pending, terminationWasAsked, ownTerminationWasApproved else { return }
        status = .idle
        // The sandbox drops launch arguments, so the PID also travels through
        // the app's own defaults; written first, so the new process finds it.
        handoff.record(pid: processID, at: clock.now())
        let arguments: [String] = [RelaunchHandoff.argument, String(processID)]
        let outcome = launcher.launchNewInstance(at: bundleURL, arguments: arguments)
        switch outcome {
        case .launched:
            break
        case let .failed(reason):
            handoff.clear()
            log("Ration: relaunch failed, the new instance did not launch: \(reason)")
        case .timedOut:
            // It may still start; the handoff expires on its own.
            log("Ration: relaunch not confirmed before quitting; the new instance may not start.")
        }
    }

    nonisolated static func refusedMessage(locale: Locale = .current) -> String {
        LocalizedStringResource.relaunchRefused.string(in: locale)
    }
}

/// Carries "wait for PID n to exit" from the old instance to the new one:
/// `--await-exit <pid>`, and, because a sandboxed launch ignores arguments,
/// the same PID in the app's own defaults with the time it was written.
struct RelaunchHandoff {
    static let argument = "--await-exit"
    static let pidKey = "RelaunchAwaitExitPID"
    static let recordedAtKey = "RelaunchAwaitExitRecordedAt"
    /// A handoff older than this belongs to a relaunch that never happened.
    static let maximumAge: TimeInterval = 30
    /// How far in the future a handoff may be dated (clock adjustments).
    static let clockSkewTolerance: TimeInterval = 2

    let defaults: UserDefaults

    func record(pid: pid_t, at date: Date) {
        defaults.set(Int(pid), forKey: Self.pidKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.recordedAtKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.pidKey)
        defaults.removeObject(forKey: Self.recordedAtKey)
    }

    /// The recorded PID while it is fresh; nil otherwise.
    func storedPID(now: Date) -> pid_t? {
        guard let recordedAt = defaults.object(forKey: Self.recordedAtKey) as? Double,
              let pid = defaults.object(forKey: Self.pidKey) as? Int
        else { return nil }
        let age: TimeInterval = now.timeIntervalSince1970 - recordedAt
        guard age >= -Self.clockSkewTolerance, age <= Self.maximumAge else { return nil }
        return pid_t(clamping: pid)
    }

    /// The PID this launch must wait for, read once: the stored handoff is
    /// removed whatever it held.
    func consumeAwaitedPID(arguments: [String], ownPID: pid_t, now: Date) -> pid_t? {
        let stored: pid_t? = storedPID(now: now)
        clear()
        let candidate: pid_t? = Self.pid(fromArguments: arguments) ?? stored
        guard let candidate, candidate > 0, candidate != ownPID else { return nil }
        return candidate
    }

    static func pid(fromArguments arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1),
              let value = Int32(arguments[index + 1])
        else { return nil }
        return value
    }
}

/// Holds a relaunched instance back until the previous one has exited.
@MainActor
struct PreviousInstanceWaiter {
    enum Outcome: Equatable {
        case exited
        case timedOut
    }

    static let timeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.1

    let lookup: any RunningApplicationLookup
    let clock: any RelaunchClock

    static func live() -> PreviousInstanceWaiter {
        PreviousInstanceWaiter(lookup: WorkspaceRunningApplicationLookup(), clock: SystemRelaunchClock())
    }

    /// Returns once `pid` is gone, or after `timeout` — then startup proceeds
    /// anyway, as a normal launch would.
    func waitForExit(of pid: pid_t) async -> Outcome {
        let deadline: Date = clock.now().addingTimeInterval(Self.timeout)
        while lookup.isRunning(processIdentifier: pid) {
            if clock.now() >= deadline { return .timedOut }
            await clock.sleep(seconds: Self.pollInterval)
        }
        return .exited
    }
}

// MARK: - Live implementations

struct WorkspaceInstanceLauncher: NewInstanceLaunching {
    /// The new instance does not block before it checks in (it waits for the
    /// old one asynchronously), so confirmation normally takes well under this.
    var timeout: TimeInterval = 5

    func launchNewInstance(at url: URL, arguments: [String]) -> NewInstanceLaunchOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        let result = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        // AppKit calls this on a concurrent queue, so waiting on the main
        // thread below cannot deadlock it.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                let reason: String = Self.failureReason(for: error)
                result.withLock { $0 = reason }
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        let reason: String? = result.withLock { $0 }
        if let reason { return .failed(reason) }
        return .launched
    }
}

extension WorkspaceInstanceLauncher {
    /// The failure as the log records it. Logs are never localized, so the
    /// line is only the error's domain and code (and its underlying error's,
    /// when there is one). `localizedDescription` and `String(describing:)`
    /// both carry text in the app language.
    nonisolated static func failureReason(for error: any Error) -> String {
        let nsError = error as NSError
        var reason: String = "\(nsError.domain) \(nsError.code)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            reason += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return reason
    }
}

struct ApplicationTerminator: AppTerminating {
    func terminate() {
        NSApp.terminate(nil)
    }
}

struct WorkspaceRunningApplicationLookup: RunningApplicationLookup {
    func isRunning(processIdentifier pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return !application.isTerminated
    }
}

struct SystemRelaunchClock: RelaunchClock {
    func now() -> Date { Date() }

    func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
