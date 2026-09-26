import AppKit
import XCTest
@testable import Ration

/// Quitting inside the 400 ms debounce of a Settings edit must
/// save that edit. These drive the delegate's real `applicationShouldTerminate`
/// against a real `AppModel` over temporary files; only the reply to AppKit
/// is captured instead of sent to the test host's `NSApp`.
@MainActor
final class TerminationFlushTests: XCTestCase {
    private var fixture: TerminationTestModel?

    override func tearDown() async throws {
        fixture?.removeFiles()
        fixture = nil
    }

    private struct Quit {
        let delegate: RationApplicationDelegate
        let replies: ReplyRecorder
    }

    private func makeQuit(model: AppModel) -> Quit {
        let delegate = RationApplicationDelegate()
        delegate.relauncher = AppRelauncher(
            launcher: NoLaunches(),
            terminator: NoTerminate(),
            clock: InstantClock(),
            handoff: RelaunchHandoff(defaults: UserDefaults(suiteName: "TerminationFlushTests")!),
            bundleURL: URL(fileURLWithPath: "/Applications/Ration.app"),
            processID: 4242,
            log: { _ in }
        )
        delegate.model = model
        let replies = ReplyRecorder()
        delegate.replyToTermination = { _, canTerminate in
            replies.values.append(canTerminate)
        }
        return Quit(delegate: delegate, replies: replies)
    }

    func testAPendingLabelEditIsSavedWhenQuittingWithinTheDebounce() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let autosave = fixture.labelAutosave()
        let quit = makeQuit(model: fixture.model)

        autosave.text = "Personal"  // ⌘Q lands well inside the 400 ms debounce
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(quit.replies.values, [true])
        let label = try await fixture.labelOnDisk()
        XCTAssertEqual(label, "Personal")
    }

    func testAPendingQuietHoursEditIsSavedWhenQuittingWithinTheDebounce() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let autosave = fixture.quietHoursAutosave()
        let quit = makeQuit(model: fixture.model)

        autosave.select([22, 23, 0])
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(quit.replies.values, [true])
        let cells = try await fixture.quietHoursOnDisk()
        XCTAssertEqual(cells, [0, 22, 23])
    }

    func testNoPendingEditQuitsAtOnce() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        // Editors exist, but everything they hold is saved.
        let label = fixture.labelAutosave()
        let quietHours = fixture.quietHoursAutosave()
        let quit = makeQuit(model: fixture.model)

        XCTAssertFalse(fixture.model.requiresTerminationPreparation)
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertNil(quit.delegate.terminationPreparation)
        XCTAssertTrue(quit.replies.values.isEmpty)
        withExtendedLifetime((label, quietHours)) {}
    }

    func testAStuckSaveLetsTheQuitProceedAfterTheTimeout() async throws {
        let fixture = try await TerminationTestModel.make(
            pendingEdits: PendingEditRegistry(timeout: .milliseconds(100))
        )
        self.fixture = fixture
        let gate = StuckSave()
        let autosave = LabelAutosave.editor(
            accountID: fixture.account.id,
            stored: "Work",
            in: fixture.model.pendingEdits,
            save: { _ in await gate.hang() },
            onError: { _ in }
        )
        let quit = makeQuit(model: fixture.model)
        autosave.text = "Personal"
        let started = Date()

        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        await quit.delegate.terminationPreparation?.value

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(quit.replies.values, [true], "a stuck save never blocks quitting")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(gate.isHanging, "the save really was stuck")
        gate.release()
    }
}

@MainActor
private final class ReplyRecorder {
    var values: [Bool] = []
}

/// A save that never finishes until released.
@MainActor
private final class StuckSave {
    private(set) var isHanging = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hang() async {
        isHanging = true
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class NoLaunches: NewInstanceLaunching {
    func launchNewInstance(at url: URL, arguments: [String]) -> NewInstanceLaunchOutcome {
        XCTFail("an ordinary quit must not launch anything")
        return .launched
    }
}

@MainActor
private final class NoTerminate: AppTerminating {
    func terminate() {}
}

@MainActor
private final class InstantClock: RelaunchClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds: TimeInterval) async {}
}
