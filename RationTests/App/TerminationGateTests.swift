import AppKit
import XCTest
@testable import Ration

/// `TerminationGate` sits in front of `NSApplication.terminate(_:)` in the
/// running app (the test host), so a quit made while another is being
/// decided never reaches AppKit.
@MainActor
final class TerminationGateTests: XCTestCase {
    func testTheGateIsInstalledAtStartup() {
        XCTAssertTrue(TerminationGate.isInstalled)
    }

    /// If the gate did not hold the request back, this would quit the test
    /// host — a loud failure, not a silent one.
    func testAHeldBackTerminateNeverReachesAppKit() {
        let previous = TerminationGate.shouldForward
        defer { TerminationGate.shouldForward = previous }
        var asked = 0
        TerminationGate.shouldForward = {
            asked += 1
            return false
        }

        NSApplication.shared.terminate(nil)

        XCTAssertEqual(asked, 1)
    }

    /// A forwarded request really reaches AppKit's own `terminate(_:)`: the
    /// delegate is asked exactly once per call (a cancelling delegate keeps
    /// the test host alive), including after a second `install()` — no
    /// double replacement, no recursion.
    func testAForwardedTerminateCallsThroughToAppKitOncePerCall() {
        let application = NSApplication.shared
        let previousDelegate = application.delegate
        let previousGate = TerminationGate.shouldForward
        let cancelling = CancellingDelegate()
        defer {
            application.delegate = previousDelegate
            TerminationGate.shouldForward = previousGate
        }
        TerminationGate.shouldForward = { true }
        application.delegate = cancelling

        application.terminate(nil)
        XCTAssertEqual(cancelling.asked, 1)

        TerminationGate.install()
        application.terminate(nil)
        application.terminate(nil)
        XCTAssertEqual(cancelling.asked, 3)
    }

    /// With no decision open the gate forwards, as before.
    func testTheLiveGateForwardsWhenNoQuitIsBeingDecided() {
        let relauncher = AppRelauncher.live()
        XCTAssertTrue(relauncher.shouldForwardTermination())
    }
}

@MainActor
private final class CancellingDelegate: NSObject, NSApplicationDelegate {
    private(set) var asked = 0

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        asked += 1
        return .terminateCancel
    }
}
