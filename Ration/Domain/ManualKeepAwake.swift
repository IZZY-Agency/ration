import Foundation

/// The user's keep-awake override, started from the popover's Keep awake
/// button: the Mac is kept from idle sleep whether or not any account is in
/// use. In memory only — a quit, crash or relaunch ends it, and the hold it
/// backs dies with the process.
///
/// Its deadline is on the monotonic clock: "30 minutes" is 30 minutes of
/// real time, whatever happens to the wall clock meanwhile (NTP, a time
/// zone, the user setting it back an hour — which would otherwise stretch
/// the hold). The wall-clock end the banner shows is derived from what is
/// left, so it moves with the wall clock and always names the real end.
struct ManualKeepAwake: Equatable, Sendable {
    /// `MonotonicClock.now` when the override started.
    let startedAt: TimeInterval
    /// Its length in seconds; nil = until the user stops it.
    let duration: TimeInterval?

    /// Live until `duration` of monotonic time has passed (exclusive end).
    func isLive(monotonic now: TimeInterval) -> Bool {
        guard let duration else { return true }
        return now - startedAt < duration
    }

    /// The end on the wall clock as it reads now: `wall` plus what is left,
    /// to the second so repeated evaluations agree. Nil = open-ended.
    func until(wall: Date, monotonic now: TimeInterval) -> Date? {
        guard let duration else { return nil }
        let remaining = duration - (now - startedAt)
        return Date(timeIntervalSince1970: (wall.timeIntervalSince1970 + remaining).rounded())
    }
}

/// Seconds on a clock that only moves forward, keeps counting through
/// sleep, and ignores every change to the wall clock (`CLOCK_MONOTONIC`,
/// which on macOS includes time asleep — unlike `ProcessInfo.systemUptime`).
enum MonotonicClock {
    static var now: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// Which source backs the live idle-sleep hold.
enum KeepAwakeSource: Equatable, Sendable {
    /// The user's override (`ManualKeepAwake`).
    case manual
    /// An account is in use (`KeepAwakePolicy`).
    case automatic
}

/// What the popover shows about the hold: its banner and the footer button's
/// state. Derived by `AppModel` from the controller's source and the override.
enum KeepAwakeStatus: Equatable, Sendable {
    case off
    /// An account is in use and the switch is on.
    case automatic
    /// The user's override; `until` nil = until turned off.
    case manual(until: Date?)
}

/// What the glanceable surfaces — the status item and the ring bar — show
/// for Keep awake: nothing while the Features switch is off, the outline eye
/// at rest while it is on (like the popover's footer), the filled eye while
/// a hold is live.
enum KeepAwakeEye: Equatable, Sendable {
    case hidden
    case idle
    case held(KeepAwakeStatus)

    /// `enabled` is `FeatureSwitches.keepAwakeEffective`; `status` is
    /// `AppModel.keepAwakeStatus`. A status other than `.off` cannot occur
    /// while the switch is off (the model refuses it), but the switch wins
    /// regardless.
    static func forBars(enabled: Bool, status: KeepAwakeStatus) -> KeepAwakeEye {
        guard enabled else { return .hidden }
        return status == .off ? .idle : .held(status)
    }

    /// The hold behind the eye; `.off` for the idle and hidden eyes.
    var status: KeepAwakeStatus {
        if case let .held(status) = self { return status }
        return .off
    }

    var isShown: Bool { self != .hidden }
}
