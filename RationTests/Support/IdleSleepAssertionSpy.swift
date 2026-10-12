import Foundation
@testable import Ration

/// Records every idle-sleep hold and release instead of touching
/// `ProcessInfo`, so a test can prove exactly when the Mac would have been
/// kept awake and with which reason.
@MainActor
final class IdleSleepAssertionSpy: IdleSleepAssertionHolding {
    /// The reason of every `hold` call, in order.
    private(set) var holds: [String] = []
    /// The reasons of the holds that also kept the display awake, in order.
    private(set) var displayHolds: [String] = []
    private(set) var releases = 0
    /// Whether a hold is live right now (a hold not yet released).
    private(set) var isHeld = false
    /// Whether the live hold keeps the display awake too.
    private(set) var isDisplayHeld = false

    func hold(reason: String, display: Bool) {
        holds.append(reason)
        if display { displayHolds.append(reason) }
        isHeld = true
        isDisplayHeld = display
    }

    func release() {
        releases += 1
        isHeld = false
        isDisplayHeld = false
    }
}
