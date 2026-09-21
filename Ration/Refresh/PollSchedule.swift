import Foundation

/// Pure background-poll interval policy. Lengthens the poll in Low
/// Power Mode and adds jitter so an install's polls don't wake in a perfect
/// lockstep cadence (and so many installs don't align). Kept pure so the timing
/// is unit-testable without a real clock.
enum PollSchedule {
    /// Normal cadence.
    static let baseSeconds = 300
    /// Relaxed cadence while the Mac is in Low Power Mode.
    static let lowPowerSeconds = 900
    /// Upper bound on the random jitter added to each interval.
    static let maxJitterSeconds = 60

    static func interval(lowPowerMode: Bool, jitterSeconds: Int) -> Duration {
        let base = lowPowerMode ? lowPowerSeconds : baseSeconds
        // Clamp jitter defensively so a bad random source can't shorten the poll.
        let jitter = min(max(jitterSeconds, 0), maxJitterSeconds)
        return .seconds(base + jitter)
    }
}
