import AppKit
import XCTest
@testable import Ration

/// Relaunch after a language change (ruling R1): the new instance is launched
/// only once termination really proceeds, a vetoed quit launches nothing, and
/// the new instance waits for the old one to exit. Nothing here relaunches or
/// quits the test host — every system call goes through a fake.
@MainActor
final class AppRelauncherTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var launcher: LauncherSpy!
    private var terminator: TerminatorSpy!
    private var clock: ClockFake!
    private var logged: [String] = []

    private let bundleURL = URL(fileURLWithPath: "/Applications/Ration.app")
    private let ownPID: pid_t = 4242

    override func setUp() {
        super.setUp()
        suiteName = "AppRelauncherTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        launcher = LauncherSpy()
        terminator = TerminatorSpy()
        clock = ClockFake()
        logged = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// `answered`: AppKit consults the delegate inside `terminate()`, as it
    /// does for a request it does not drop. A test may replace the hook.
    private func makeRelauncher(answered: Bool = true) -> AppRelauncher {
        let defaults = defaults!
        let clock = clock!
        launcher.handoffReader = { RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()) }
        let relauncher = AppRelauncher(
            launcher: launcher,
            terminator: terminator,
            clock: clock,
            handoff: RelaunchHandoff(defaults: defaults),
            bundleURL: bundleURL,
            processID: ownPID,
            log: { [weak self] message in self?.logged.append(message) }
        )
        if answered {
            // What the delegate does when nothing needs preparing: it is asked,
            // and answers `.terminateNow`.
            terminator.onTerminate = { [weak relauncher] in
                relauncher?.terminationWasRequested()
                relauncher?.terminationWasApproved()
            }
        }
        return relauncher
    }

    // MARK: Requesting

    func testRelaunchAsksToTerminateAndLaunchesNothingYet() {
        let relauncher = makeRelauncher()

        relauncher.relaunch()

        XCTAssertEqual(terminator.calls, 1)
        XCTAssertTrue(launcher.launches.isEmpty, "the new instance starts only from applicationWillTerminate")
        XCTAssertEqual(relauncher.status, .pending)
    }

    func testASecondRequestWhileOneIsPendingDoesNotTerminateAgain() {
        let relauncher = makeRelauncher()
        relauncher.relaunch()
        relauncher.relaunch()
        XCTAssertEqual(terminator.calls, 1)
    }

    // MARK: Unanswered request

    /// AppKit can drop a terminate request without consulting the delegate:
    /// the button must not stay disabled for the rest of the session.
    func testATerminateRequestNobodyAnswersFallsBackToIdle() async {
        let relauncher = makeRelauncher(answered: false)
        relauncher.relaunch()
        XCTAssertEqual(relauncher.status, .pending)

        await relauncher.unansweredRequestCheck?.value

        XCTAssertEqual(relauncher.status, .idle)
        XCTAssertEqual(clock.sleeps, [AppRelauncher.unansweredRequestDelay])
        relauncher.relaunch()
        XCTAssertEqual(terminator.calls, 2, "Relaunch now works again")
    }

    func testADeferredDecisionKeepsTheRequestPending() async {
        let relauncher = makeRelauncher()
        terminator.onTerminate = { relauncher.terminationWasRequested() }
        relauncher.relaunch()

        await relauncher.unansweredRequestCheck?.value

        XCTAssertEqual(relauncher.status, .pending, "a .terminateLater decision is still outstanding")
        relauncher.terminationWasApproved()
        relauncher.terminationWillProceed()
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testDelegateReportsThatTerminationWasAsked() async {
        let relauncher = makeRelauncher()
        let delegate = RationApplicationDelegate()
        delegate.relauncher = relauncher
        terminator.onTerminate = { _ = delegate.applicationShouldTerminate(NSApplication.shared) }
        relauncher.relaunch()

        await relauncher.unansweredRequestCheck?.value

        XCTAssertEqual(relauncher.status, .pending)
    }

    // MARK: Someone else's termination

    /// Defensive: should an AppKit ever consult the delegate for a second
    /// request (macOS 27.2 does not — see the lifecycle tests below), that
    /// request is not the relaunch's and it gives up the intent.
    func testAnotherRequestTheDelegateIsAskedAboutAbandonsTheRelaunch() {
        let relauncher = makeRelauncher()
        terminator.onTerminate = { relauncher.terminationWasRequested() }
        relauncher.relaunch()
        XCTAssertEqual(relauncher.status, .pending)

        relauncher.terminationWasRequested()
        relauncher.terminationWasApproved()
        relauncher.terminationWillProceed()

        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNil(RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()))
        XCTAssertEqual(relauncher.status, .idle, "no refusal message: nothing was refused")
    }

    /// AppKit dropped the relaunch's own request, then a later Quit
    /// proceeds (before the fallback fired): still no new instance.
    func testAnotherTerminationAfterADroppedRequestLaunchesNothing() {
        let relauncher = makeRelauncher(answered: false)
        relauncher.relaunch()

        relauncher.terminationWasRequested()
        relauncher.terminationWasApproved()
        relauncher.terminationWillProceed()

        XCTAssertTrue(launcher.launches.isEmpty)
    }

    // MARK: Veto

    func testVetoedTerminationLaunchesNothingAndExplainsWhy() {
        let relauncher = makeRelauncher()
        relauncher.relaunch()

        relauncher.terminationWasCancelled()

        XCTAssertEqual(relauncher.status, .refused)
        XCTAssertEqual(
            AppRelauncher.refusedMessage(locale: L10n.en),
            "Ration couldn't relaunch because it is still finishing a task. Try again in a moment."
        )
        // The intent is gone: a later ordinary quit must not relaunch.
        relauncher.terminationWillProceed()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNil(RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()))
    }

    func testCancelledOrdinaryQuitShowsNoRelaunchMessage() {
        let relauncher = makeRelauncher()
        relauncher.terminationWasCancelled()
        XCTAssertEqual(relauncher.status, .idle)
    }

    func testRetryAfterARefusalTerminatesAgain() {
        let relauncher = makeRelauncher()
        relauncher.relaunch()
        relauncher.terminationWasCancelled()

        relauncher.relaunch()

        XCTAssertEqual(terminator.calls, 2)
        XCTAssertEqual(relauncher.status, .pending, "a new attempt clears the old refusal")
    }

    // MARK: Proceeding

    func testWillTerminateLaunchesANewInstanceThatAwaitsThisPID() {
        let relauncher = makeRelauncher()
        relauncher.relaunch()

        relauncher.terminationWillProceed()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches.first?.url, bundleURL)
        XCTAssertEqual(launcher.launches.first?.arguments, ["--await-exit", "4242"])
        // The sandbox drops launch arguments, so the PID also travels through
        // the app's own defaults, written BEFORE the launch.
        XCTAssertEqual(launcher.handoffPIDAtLaunch, 4242)
        XCTAssertTrue(logged.isEmpty)
    }

    func testOrdinaryQuitLaunchesNothing() {
        let relauncher = makeRelauncher()
        relauncher.terminationWillProceed()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNil(RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()))
    }

    func testLaunchFailureIsLoggedAndLeavesNoHandoff() {
        launcher.outcome = .failed("The application could not be launched.")
        let relauncher = makeRelauncher()
        relauncher.relaunch()

        relauncher.terminationWillProceed()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("could not be launched"), logged[0])
        XCTAssertNil(
            RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()),
            "a stale handoff must not make a later manual launch wait"
        )
    }

    /// Logs are never localized: the launch failure is logged by its
    /// domain and code, not by the user's-language `localizedDescription`.
    func testLaunchFailureReasonIsNotTheLocalizedDescription() {
        let error = NSError(
            domain: "NSOSStatusErrorDomain",
            code: -10810,
            userInfo: [NSLocalizedDescriptionKey: "L’application n’a pas pu être ouverte."]
        )

        let reason: String = WorkspaceInstanceLauncher.failureReason(for: error)

        XCTAssertEqual(reason, "NSOSStatusErrorDomain -10810")
        XCTAssertFalse(reason.contains("application"), reason)
    }

    func testLaunchFailureReasonNamesTheUnderlyingErrorWithoutItsText() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Opération non autorisée"]
        )
        let error = NSError(
            domain: "NSOSStatusErrorDomain",
            code: -10810,
            userInfo: [
                NSLocalizedDescriptionKey: "L’application n’a pas pu être ouverte.",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let reason: String = WorkspaceInstanceLauncher.failureReason(for: error)

        XCTAssertEqual(reason, "NSOSStatusErrorDomain -10810 (underlying NSPOSIXErrorDomain 1)")
    }

    func testLaunchTimeoutIsLogged() {
        launcher.outcome = .timedOut
        let relauncher = makeRelauncher()
        relauncher.relaunch()
        relauncher.terminationWillProceed()
        XCTAssertEqual(logged.count, 1)
    }

    // MARK: Delegate wiring

    func testDeferredThenRefusedQuitClearsTheIntentThroughTheDelegate() {
        let relauncher = makeRelauncher()
        let delegate = RationApplicationDelegate()
        delegate.relauncher = relauncher
        relauncher.relaunch()

        // The production path a `.terminateLater` decision takes when
        // `prepareForTermination()` answers false.
        delegate.resolveTerminationForTesting(canTerminate: false)

        XCTAssertEqual(relauncher.status, .refused)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testDeferredThenAllowedQuitDoesNotClearTheIntent() {
        let relauncher = makeRelauncher()
        let delegate = RationApplicationDelegate()
        delegate.relauncher = relauncher
        relauncher.relaunch()

        delegate.resolveTerminationForTesting(canTerminate: true)
        XCTAssertEqual(relauncher.status, .pending)
    }

    func testDelegateWillTerminateLaunchesTheNewInstance() {
        let relauncher = makeRelauncher()
        let delegate = RationApplicationDelegate()
        delegate.relauncher = relauncher
        relauncher.relaunch()

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(launcher.launches.first?.arguments, ["--await-exit", "4242"])
    }

    // MARK: AppKit's real termination lifecycle

    /// The sequence an isolated AppKit probe recorded on macOS 27.2: once
    /// the delegate answered `.terminateLater`, a second `terminate()` goes
    /// STRAIGHT to `applicationWillTerminate` — the delegate is not asked
    /// again — and the first `terminate()` has not returned yet.
    private struct Lifecycle {
        let relauncher: AppRelauncher
        let delegate: RationApplicationDelegate
        let appKit: AppKitTerminationFake
        let powerOff: NotificationCenter
    }

    /// `deferred`: the delegate answers `.terminateLater` (a sign-in or a
    /// profile cleanup is unresolved); otherwise `.terminateNow`, through
    /// the delegate's own `applicationShouldTerminate`.
    private func makeLifecycle(deferred: Bool) -> Lifecycle {
        let defaults = defaults!
        let clock = clock!
        launcher.handoffReader = { RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()) }
        let appKit = AppKitTerminationFake()
        let powerOff = NotificationCenter()
        let relauncher = AppRelauncher(
            launcher: launcher,
            terminator: appKit,
            clock: clock,
            handoff: RelaunchHandoff(defaults: defaults),
            bundleURL: bundleURL,
            processID: ownPID,
            powerOffNotifications: powerOff,
            log: { [weak self] message in self?.logged.append(message) }
        )
        let delegate = RationApplicationDelegate()
        delegate.relauncher = relauncher
        appKit.shouldTerminate = { [weak delegate, weak relauncher] in
            guard deferred else {
                let reply = delegate?.applicationShouldTerminate(NSApplication.shared)
                return reply == .terminateNow ? .now : .later
            }
            // The delegate's `.terminateLater` branch, minus the Task that
            // would reply to the real NSApp from the test host.
            relauncher?.terminationWasRequested()
            return .later
        }
        appKit.resolveDecision = { [weak delegate] canTerminate in
            delegate?.resolveTerminationForTesting(canTerminate: canTerminate)
        }
        appKit.willTerminate = { [weak delegate] in
            delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        // `TerminationGate`: every terminate request passes
        // this gate before AppKit sees it.
        appKit.gate = { [weak relauncher] in
            relauncher?.shouldForwardTermination() ?? true
        }
        return Lifecycle(relauncher: relauncher, delegate: delegate, appKit: appKit, powerOff: powerOff)
    }

    /// Footer Quit / popover ⌘Q while the relaunch waits for a cleanup: the
    /// quit joins the open decision instead of reaching AppKit, which would
    /// go straight to `applicationWillTerminate` and skip the cleanup.
    func testOrdinaryQuitDuringAPendingRelaunchJoinsTheOpenDecision() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.relaunch()
        XCTAssertTrue(life.appKit.isDecisionPending)

        life.relauncher.quitWithoutRelaunch()

        XCTAssertFalse(life.appKit.didTerminate, "the cleanup is still awaited")
        XCTAssertEqual(life.appKit.terminateCalls, 1, "AppKit never saw the second quit")
        XCTAssertEqual(life.relauncher.status, .idle, "the relaunch intent is dropped")

        life.appKit.reply(canTerminate: true)
        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertEqual(life.appKit.shouldTerminateCalls, 1)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNil(RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()))
    }

    /// The app menu's Quit (and ⌘Q while a Ration window is key) call
    /// `NSApp.terminate` without clearing anything first. The `TerminationGate`
    /// still holds it back and drops the
    /// relaunch.
    func testUnclearedQuitDuringAPendingRelaunchJoinsTheOpenDecision() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.relaunch()

        life.appKit.terminate()

        XCTAssertFalse(life.appKit.didTerminate)
        XCTAssertEqual(life.appKit.forwardedTerminateCalls, 1)
        XCTAssertEqual(life.relauncher.status, .idle)
        life.appKit.reply(canTerminate: true)
        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    /// A refused decision refuses the joined quit too; the next quit asks
    /// the delegate again.
    func testAJoinedQuitIsRefusedWithTheDecision() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.quitWithoutRelaunch()
        life.relauncher.quitWithoutRelaunch()

        life.appKit.reply(canTerminate: false)
        XCTAssertFalse(life.appKit.didTerminate)

        life.relauncher.quitWithoutRelaunch()
        XCTAssertEqual(life.appKit.shouldTerminateCalls, 2)
        life.appKit.reply(canTerminate: true)
        XCTAssertTrue(life.appKit.didTerminate)
    }

    /// Escape hatch: a decision stuck for `forcedQuitAfter` seconds no longer
    /// holds a repeated quit back, so a hung cleanup can't make the app
    /// unquittable.
    func testARepeatedQuitGoesThroughOnceTheDecisionIsStuck() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.quitWithoutRelaunch()
        clock.advance(by: AppRelauncher.forcedQuitAfter - 1)
        life.relauncher.quitWithoutRelaunch()
        XCTAssertFalse(life.appKit.didTerminate)

        clock.advance(by: 1)
        life.relauncher.quitWithoutRelaunch()

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testPowerOffDuringAPendingRelaunchLaunchesNothing() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.relaunch()

        life.powerOff.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        life.appKit.terminate()  // the system's quit
        life.appKit.reply(canTerminate: true)

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(life.relauncher.status, .idle)
    }

    /// Log out began, then the relaunch's own cleanup finished first: the app
    /// quits with the session, and nothing is started into a logout.
    func testPowerOffThenTheRelaunchsOwnApprovalLaunchesNothing() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.relaunch()

        life.powerOff.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        life.appKit.reply(canTerminate: true)

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testDeferredRelaunchThatProceedsLaunchesExactlyOnce() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.relaunch()
        XCTAssertTrue(launcher.launches.isEmpty)

        life.appKit.reply(canTerminate: true)

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches.first?.arguments, ["--await-exit", "4242"])
        XCTAssertEqual(launcher.handoffPIDAtLaunch, 4242)
    }

    func testImmediateRelaunchThatProceedsLaunchesExactlyOnce() {
        let life = makeLifecycle(deferred: false)

        life.relauncher.relaunch()

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    // MARK: Quitting with a Settings edit still being saved

    /// The delegate's REAL `.terminateLater` path: `applicationShouldTerminate`
    /// defers because an edit is pending, its Task flushes the edit, then
    /// replies — to this fake instead of the test host's `NSApp`.
    private func makeFlushingLifecycle(model: AppModel) -> Lifecycle {
        let defaults = defaults!
        let clock = clock!
        launcher.handoffReader = { RelaunchHandoff(defaults: defaults).storedPID(now: clock.now()) }
        let appKit = AppKitTerminationFake()
        let powerOff = NotificationCenter()
        let relauncher = AppRelauncher(
            launcher: launcher,
            terminator: appKit,
            clock: clock,
            handoff: RelaunchHandoff(defaults: defaults),
            bundleURL: bundleURL,
            processID: ownPID,
            powerOffNotifications: powerOff,
            log: { [weak self] message in self?.logged.append(message) }
        )
        let delegate = RationApplicationDelegate()
        delegate.relauncher = relauncher
        delegate.model = model
        appKit.shouldTerminate = { [weak delegate] in
            let reply = delegate?.applicationShouldTerminate(NSApplication.shared)
            return reply == .terminateNow ? .now : .later
        }
        // The delegate's Task resolves its own decision before replying.
        appKit.resolveDecision = { _ in }
        delegate.replyToTermination = { [weak appKit] _, canTerminate in
            appKit?.reply(canTerminate: canTerminate)
        }
        appKit.willTerminate = { [weak delegate] in
            delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        // `TerminationGate`: every terminate request passes
        // this gate before AppKit sees it.
        appKit.gate = { [weak relauncher] in
            relauncher?.shouldForwardTermination() ?? true
        }
        return Lifecycle(relauncher: relauncher, delegate: delegate, appKit: appKit, powerOff: powerOff)
    }

    /// The label field's model, recording when each save lands.
    private func recordingLabelAutosave(
        _ fixture: TerminationTestModel,
        events: EventLog,
        hold: StuckGate? = nil
    ) -> LabelAutosave {
        let model = fixture.model
        let id = fixture.account.id
        return LabelAutosave.editor(
            accountID: id,
            stored: fixture.account.label,
            in: model.pendingEdits,
            save: { label in
                if let hold { await hold.wait() }
                try await model.renameAccount(id: id, label: label)
                events.append("saved \(label)")
            },
            onError: { _ in }
        )
    }

    func testRelaunchWithAPendingSaveFlushesItThenLaunchesExactlyOnce() async throws {
        let fixture = try await TerminationTestModel.make()
        defer { fixture.removeFiles() }
        let events = EventLog()
        launcher.onLaunch = { events.append("launch") }
        let life = makeFlushingLifecycle(model: fixture.model)
        let autosave = recordingLabelAutosave(fixture, events: events)

        autosave.text = "Personal"
        life.relauncher.relaunch()

        XCTAssertTrue(life.appKit.isDecisionPending, "the pending edit deferred the quit")
        XCTAssertTrue(launcher.launches.isEmpty)
        await life.delegate.terminationPreparation?.value

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertEqual(life.appKit.shouldTerminateCalls, 1)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches.first?.arguments, ["--await-exit", "4242"])
        XCTAssertEqual(events.entries, ["saved Personal", "launch"], "saved before the new instance starts")
        let label = try await fixture.labelOnDisk()
        XCTAssertEqual(label, "Personal")
    }

    func testOrdinaryQuitWithAPendingSaveFlushesItAndLaunchesNothing() async throws {
        let fixture = try await TerminationTestModel.make()
        defer { fixture.removeFiles() }
        let events = EventLog()
        let life = makeFlushingLifecycle(model: fixture.model)
        let autosave = recordingLabelAutosave(fixture, events: events)

        autosave.text = "Personal"
        life.relauncher.quitWithoutRelaunch()
        XCTAssertTrue(life.appKit.isDecisionPending)
        await life.delegate.terminationPreparation?.value

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertEqual(events.entries, ["saved Personal"])
        XCTAssertTrue(launcher.launches.isEmpty)
        let label = try await fixture.labelOnDisk()
        XCTAssertEqual(label, "Personal")
    }

    /// Quit while a relaunch waits for its flush: the quit joins the open
    /// decision. The save lands and the decision is answered BEFORE the app
    /// terminates, and nothing launches.
    func testOrdinaryQuitDuringARelaunchFlushWaitsForTheSaveAndLaunchesNothing() async throws {
        let fixture = try await TerminationTestModel.make()
        defer { fixture.removeFiles() }
        let events = EventLog()
        let gate = StuckGate()
        launcher.onLaunch = { events.append("launch") }
        let life = makeFlushingLifecycle(model: fixture.model)
        life.appKit.willTerminate = { [weak delegate = life.delegate] in
            events.append("willTerminate")
            delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        let autosave = recordingLabelAutosave(fixture, events: events, hold: gate)
        autosave.text = "Personal"
        life.relauncher.relaunch()
        XCTAssertTrue(life.appKit.isDecisionPending)

        life.relauncher.quitWithoutRelaunch()
        XCTAssertFalse(life.appKit.didTerminate, "the save is still running")
        XCTAssertEqual(life.relauncher.status, .idle)

        gate.open()
        await life.delegate.terminationPreparation?.value

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertEqual(events.entries, ["saved Personal", "willTerminate"])
        XCTAssertTrue(launcher.launches.isEmpty)
        let label = try await fixture.labelOnDisk()
        XCTAssertEqual(label, "Personal")
    }

    func testVetoedRelaunchLaunchesNothingAndExplainsWhy() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.relaunch()

        life.appKit.reply(canTerminate: false)

        XCTAssertFalse(life.appKit.didTerminate)
        XCTAssertEqual(life.relauncher.status, .refused)
        XCTAssertEqual(
            AppRelauncher.refusedMessage(locale: L10n.en),
            "Ration couldn't relaunch because it is still finishing a task. Try again in a moment."
        )
        XCTAssertTrue(launcher.launches.isEmpty)

        // The veto still guards the next, ordinary quit; it launches nothing.
        life.relauncher.quitWithoutRelaunch()
        XCTAssertEqual(life.appKit.shouldTerminateCalls, 2, "a fresh quit asks the delegate again")
        life.appKit.reply(canTerminate: true)
        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    /// Relaunch now while an ordinary quit waits for its cleanup: a second
    /// `terminate()` would skip the veto and quit on the spot, so the
    /// relaunch is refused instead.
    func testRelaunchWhileAQuitIsBeingDecidedIsRefused() {
        let life = makeLifecycle(deferred: true)
        life.relauncher.quitWithoutRelaunch()
        XCTAssertTrue(life.appKit.isDecisionPending)

        life.relauncher.relaunch()

        XCTAssertEqual(life.appKit.terminateCalls, 1, "no second terminate")
        XCTAssertFalse(life.appKit.didTerminate)
        XCTAssertEqual(life.relauncher.status, .refused)

        // The quit is vetoed; Relaunch now works again.
        life.appKit.reply(canTerminate: false)
        life.relauncher.relaunch()
        XCTAssertEqual(life.relauncher.status, .pending)
        life.appKit.reply(canTerminate: true)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testOrdinaryQuitWithNothingPendingJustTerminates() {
        let life = makeLifecycle(deferred: false)

        life.relauncher.quitWithoutRelaunch()

        XCTAssertTrue(life.appKit.didTerminate)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(life.relauncher.status, .idle)
    }

    // MARK: Handoff

    func testArgumentNamesThePIDToAwait() {
        let handoff = RelaunchHandoff(defaults: defaults)
        XCTAssertEqual(
            handoff.consumeAwaitedPID(arguments: ["/x/Ration", "--await-exit", "77"], ownPID: ownPID, now: clock.now()),
            77
        )
    }

    func testMalformedOrOwnPIDIsIgnored() {
        let handoff = RelaunchHandoff(defaults: defaults)
        XCTAssertNil(handoff.consumeAwaitedPID(arguments: ["x", "--await-exit"], ownPID: ownPID, now: clock.now()))
        XCTAssertNil(handoff.consumeAwaitedPID(arguments: ["x", "--await-exit", "abc"], ownPID: ownPID, now: clock.now()))
        XCTAssertNil(handoff.consumeAwaitedPID(arguments: ["x", "--await-exit", "0"], ownPID: ownPID, now: clock.now()))
        XCTAssertNil(handoff.consumeAwaitedPID(arguments: ["x", "--await-exit", "4242"], ownPID: ownPID, now: clock.now()))
    }

    func testStoredHandoffIsReadOnceThenRemoved() {
        let handoff = RelaunchHandoff(defaults: defaults)
        handoff.record(pid: 99, at: clock.now())

        XCTAssertEqual(handoff.consumeAwaitedPID(arguments: ["x"], ownPID: ownPID, now: clock.now().addingTimeInterval(2)), 99)
        XCTAssertNil(handoff.consumeAwaitedPID(arguments: ["x"], ownPID: ownPID, now: clock.now().addingTimeInterval(3)))
    }

    func testFutureHandoffIsIgnoredBeyondClockSkew() {
        let handoff = RelaunchHandoff(defaults: defaults)
        let now = clock.now()
        handoff.record(pid: 99, at: now.addingTimeInterval(RelaunchHandoff.clockSkewTolerance + 1))
        XCTAssertNil(handoff.storedPID(now: now))

        handoff.record(pid: 99, at: now.addingTimeInterval(1))
        XCTAssertEqual(handoff.storedPID(now: now), 99, "within the skew tolerance")
    }

    func testStaleHandoffIsIgnoredAndRemoved() {
        let handoff = RelaunchHandoff(defaults: defaults)
        handoff.record(pid: 99, at: clock.now())

        let later = clock.now().addingTimeInterval(RelaunchHandoff.maximumAge + 1)
        XCTAssertNil(handoff.consumeAwaitedPID(arguments: ["x"], ownPID: ownPID, now: later))
        XCTAssertNil(handoff.storedPID(now: clock.now()), "removed, not just ignored")
    }

    // MARK: Awaiting the previous instance

    func testAwaitExitWaitsUntilThePreviousInstanceIsGone() async {
        let lookup = LookupFake(runningAnswers: [true, true, false])
        let waiter = PreviousInstanceWaiter(lookup: lookup, clock: clock)

        let outcome = await waiter.waitForExit(of: 55)

        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(lookup.queries, [55, 55, 55])
        XCTAssertEqual(clock.sleeps.count, 2)
    }

    func testAwaitExitDoesNotSleepWhenAlreadyGone() async {
        let lookup = LookupFake(runningAnswers: [false])
        let outcome = await PreviousInstanceWaiter(lookup: lookup, clock: clock).waitForExit(of: 55)
        XCTAssertEqual(outcome, .exited)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testAwaitExitGivesUpAfterTenSecondsAndProceeds() async {
        let lookup = LookupFake(runningAnswers: [])  // always running
        let start = clock.now()

        let outcome = await PreviousInstanceWaiter(lookup: lookup, clock: clock).waitForExit(of: 55)

        XCTAssertEqual(outcome, .timedOut)
        let waited = clock.now().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 10)
        XCTAssertLessThan(waited, 10.5)
    }

    // MARK: Startup hold

    func testHeldStartupStartsTheMenuBarOnlyOnRelease() {
        let delegate = RationApplicationDelegate()
        let model = AppModel.live(
            adapters: [],
            baseDirectory: FileManager.default.temporaryDirectory.appending(
                path: UUID().uuidString,
                directoryHint: .isDirectory
            )
        )
        let launchAtLogin = LaunchAtLoginController()
        delegate.holdStartupForPreviousInstance()
        delegate.configure(model: model, launchAtLogin: launchAtLogin, hotKeyRegistrar: HotKeyRegistrarSpy())
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }

        XCTAssertNil(delegate.menuBarController, "the old instance still owns the status item and hot keys")

        delegate.releaseStartup()

        XCTAssertNotNil(delegate.menuBarController)
    }
}

// MARK: - Fakes

/// AppKit's termination as probed on macOS 27.2 (see the lifecycle tests).
@MainActor
private final class AppKitTerminationFake: AppTerminating {
    enum Reply { case now, later }

    var shouldTerminate: () -> Reply = { .now }
    /// The delegate's own bookkeeping for a `.terminateLater` reply.
    var resolveDecision: (Bool) -> Void = { _ in }
    var willTerminate: () -> Void = {}
    /// `TerminationGate`: false keeps the request
    /// from AppKit.
    var gate: () -> Bool = { true }
    private(set) var terminateCalls = 0
    /// Requests that got past the gate to AppKit.
    private(set) var forwardedTerminateCalls = 0
    private(set) var shouldTerminateCalls = 0
    private(set) var isDecisionPending = false
    private(set) var didTerminate = false

    func terminate() {
        terminateCalls += 1
        guard gate() else { return }
        forwardedTerminateCalls += 1
        guard !didTerminate else { return }
        guard !isDecisionPending else {
            // Not asked again: straight to applicationWillTerminate.
            proceed()
            return
        }
        shouldTerminateCalls += 1
        switch shouldTerminate() {
        case .now: proceed()
        case .later: isDecisionPending = true
        }
    }

    /// `reply(toApplicationShouldTerminate:)`, as the delegate's Task sends it.
    func reply(canTerminate: Bool) {
        guard isDecisionPending, !didTerminate else { return }
        resolveDecision(canTerminate)
        isDecisionPending = false
        if canTerminate { proceed() }
    }

    private func proceed() {
        isDecisionPending = false
        didTerminate = true
        willTerminate()
    }
}

@MainActor
private final class LauncherSpy: NewInstanceLaunching {
    struct Launch: Equatable {
        let url: URL
        let arguments: [String]
    }

    var outcome: NewInstanceLaunchOutcome = .launched
    private(set) var launches: [Launch] = []
    private(set) var handoffPIDAtLaunch: pid_t?
    /// Reads the handoff at the moment of the launch, as the new process would.
    var handoffReader: (() -> pid_t?)?
    var onLaunch: (() -> Void)?

    func launchNewInstance(at url: URL, arguments: [String]) -> NewInstanceLaunchOutcome {
        launches.append(Launch(url: url, arguments: arguments))
        handoffPIDAtLaunch = handoffReader?()
        onLaunch?()
        return outcome
    }
}

@MainActor
private final class EventLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// Holds a save until opened.
@MainActor
private final class StuckGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class TerminatorSpy: AppTerminating {
    private(set) var calls = 0
    /// What the app delegate would do synchronously inside `terminate`.
    var onTerminate: (() -> Void)?
    func terminate() {
        calls += 1
        onTerminate?()
    }
}

@MainActor
private final class ClockFake: RelaunchClock {
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [TimeInterval] = []

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    func sleep(seconds: TimeInterval) async {
        sleeps.append(seconds)
        current = current.addingTimeInterval(seconds)
    }
}

@MainActor
private final class LookupFake: RunningApplicationLookup {
    private var runningAnswers: [Bool]
    private(set) var queries: [pid_t] = []

    init(runningAnswers: [Bool]) { self.runningAnswers = runningAnswers }

    func isRunning(processIdentifier pid: pid_t) -> Bool {
        queries.append(pid)
        guard !runningAnswers.isEmpty else { return true }
        return runningAnswers.removeFirst()
    }
}
