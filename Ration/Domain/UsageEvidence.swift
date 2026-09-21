import Foundation

/// Whether a usage observation still describes the present.
///
/// Extracted from `WarmUpBanner`, which owned this rule alone, so that every
/// surface asserting "you are near a limit" answers the question the same way.
/// The attention drop and the warm-up banner both derive from it; keeping two
/// copies would let them disagree about whether a number is still true.
enum UsageEvidence {
    /// How long an observation may keep speaking for the present. Two of the
    /// longest normal poll gaps (`PollSchedule.lowPowerSeconds` plus its
    /// jitter), so a slow fetch or one missed tick never blanks a row, while an
    /// app that has been asleep or offline stops asserting what it last saw.
    /// Derived from the cadence rather than picked, so the two cannot drift.
    static let maxAge = 2 * Double(
        PollSchedule.lowPowerSeconds + PollSchedule.maxJitterSeconds
    )

    /// How far in the FUTURE an observation may be dated and still be
    /// believed. Clocks disagree by seconds routinely — between the provider's
    /// and this machine's — and treating that as stale would blank rows for no
    /// reason. Beyond it, the timestamp is not credible.
    static let allowedClockSkew: TimeInterval = 120

    /// Two ways an observation stops describing the present, and one trap
    /// between them:
    ///
    /// - **Too old.** Past `maxAge` the app has been asleep, offline, or
    ///   otherwise not looking; it no longer knows what the number is.
    /// - **Overtaken by its own reset.** A snapshot taken BEFORE a reset that
    ///   has since passed says nothing about now — the allowance may well be
    ///   back, and the next poll will say so. Age alone misses this: a snapshot
    ///   taken minutes before a reset is still well inside the age bound
    ///   afterwards, and would assert a limit that has already renewed.
    /// - **But** a snapshot taken AFTER its own reported reset that still shows
    ///   the window spent IS current evidence: the provider had every chance to
    ///   roll the counter and did not.
    ///
    /// `windowResetsAt` is the boundary of the window being asked about — a
    /// rate window's `resetsAt`. `nil` (no scheduled reset) leaves only the
    /// age bound; Cursor passes `nil`, since the open invoice's `periodEndMs`
    /// is the fetch time rather than a boundary (see `CursorSpend`).
    static func isCurrent(
        snapshot: UsageSnapshot,
        windowResetsAt: Date?,
        now: Date
    ) -> Bool {
        // A future-dated snapshot has a NEGATIVE age, which a bare
        // `age <= maxAge` check accepts. If the system clock jumps backwards,
        // that would keep asserting a limit for the size of the jump PLUS the
        // whole age bound instead of retracting normally — so the window is
        // bounded at both ends.
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age >= -allowedClockSkew, age <= maxAge else { return false }
        guard let windowResetsAt, windowResetsAt <= now else { return true }
        return snapshot.fetchedAt > windowResetsAt
    }
}
