import Foundation

/// Decides when to auto-send a keep-alive message to (re)start a Claude 5-hour
/// window. Pure and deterministic so the trigger can be unit-tested.
enum AutoStartPolicy {
    /// Minimum gap between auto-starts — just under a full 5h window, so at most
    /// one keep-alive per period and never a burst.
    static let minimumInterval: TimeInterval = 5 * 60 * 60 - 5 * 60

    /// The field-level eligibility shared by `shouldAutoStart` and
    /// `effectiveAutoStartCount`: Claude, enabled, and not paused. Paused
    /// accounts keep their stored `autoStartFiveHour` for resume but cannot
    /// fire. One predicate so the firing guard and the surfaces that
    /// describe automation (the warm-up pane's count) can never drift.
    static func isEffectivelyEnabled(_ account: AccountRecord) -> Bool {
        account.provider == .claude
            && account.autoStartFiveHour
            && !account.isPaused
    }

    /// Accounts whose warm-up automation is actually in effect.
    static func effectiveAutoStartCount(_ accounts: [AccountRecord]) -> Int {
        accounts.filter(isEffectivelyEnabled).count
    }

    /// Half of Claude's 1% reporting quantum. A weekly window reported at 0%
    /// remaining is spent; nothing smaller than a whole percent is ever
    /// reported, so this threshold means exactly "the provider said zero"
    /// without depending on the exact float that (1 - utilization/100) produces.
    static let spentRemainingFraction = 0.005

    /// Why warm-up did or did not fire. `blockedByWeeklyLimit` is deliberately
    /// distinct from `skip`: it means every other condition said fire and only
    /// the spent weekly allowance stood in the way, which is the one case the
    /// UI should explain to the user.
    enum Decision: Equatable {
        case fire
        case skip
        case blockedByWeeklyLimit(resetsAt: Date?)
    }

    static func shouldAutoStart(
        account: AccountRecord,
        fiveHour: UsageWindow?,
        weekly: UsageWindow? = nil,
        now: Date,
        schedule: WarmUpQuietSchedule = .allowAll,
        warmUpEnabled: Bool = true,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        decide(
            account: account,
            fiveHour: fiveHour,
            weekly: weekly,
            now: now,
            schedule: schedule,
            warmUpEnabled: warmUpEnabled,
            calendar: calendar
        ) == .fire
    }

    static func decide(
        account: AccountRecord,
        fiveHour: UsageWindow?,
        weekly: UsageWindow? = nil,
        now: Date,
        schedule: WarmUpQuietSchedule = .allowAll,
        warmUpEnabled: Bool = true,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Decision {
        // The global Claude warm-up switch (Settings → General → Features).
        // Off → no account fires; each account's own Auto-start choice is
        // kept untouched for when it comes back on.
        guard warmUpEnabled else { return .skip }
        guard windowSaysFire(
            account: account,
            fiveHour: fiveHour,
            now: now,
            schedule: schedule,
            calendar: calendar
        ) else {
            return .skip
        }
        // The keep-alive is a real message on a real subscription: with the
        // weekly allowance spent, Claude rejects it outright. Firing anyway
        // would spend the durable once-per-window reservation (taken BEFORE the
        // irreversible POST) on an attempt that cannot succeed, suppressing
        // warm-up for a further `minimumInterval` and leaving a failure banner
        // behind. Hold instead — the next refresh after the weekly reset fires
        // normally, since nothing was recorded.
        //
        // Deliberately NOT gated on `modelWeekly`: that caps one model, and the
        // keep-alive can be sent with another.
        //
        // Fails OPEN on a missing weekly window (unknown ≠ spent).
        if let weekly, weekly.remainingFraction < spentRemainingFraction {
            return .blockedByWeeklyLimit(resetsAt: weekly.resetsAt)
        }
        return .fire
    }

    /// Everything except the weekly-allowance gate: the account's own
    /// eligibility, the user's quiet schedule, the re-fire bound, and the state
    /// of the 5-hour window.
    private static func windowSaysFire(
        account: AccountRecord,
        fiveHour: UsageWindow?,
        now: Date,
        schedule: WarmUpQuietSchedule,
        calendar: Calendar
    ) -> Bool {
        guard isEffectivelyEnabled(account) else {
            return false
        }
        // User-configured inhibition (quiet hours / holidays). Checked after the
        // cheap field guards but before any window reasoning: while quiet the
        // answer is "no" regardless of window state. This never records a send,
        // so nothing is permanently suppressed — the next non-quiet refresh
        // fires normally.
        if schedule.isQuiet(at: now, calendar: calendar) {
            return false
        }
        // Never re-fire within a window's length of the last send.
        if
            let last = account.lastAutoStartedAt,
            now.timeIntervalSince(last) < minimumInterval
        {
            return false
        }
        // No window info at all → unknown → do not fire.
        guard let fiveHour else { return false }

        if let resetsAt = fiveHour.resetsAt {
            // A scheduled reset in the future means the window is already
            // running — leave it alone. In the past means it has ended.
            return resetsAt <= now
        }

        // No scheduled reset: this is the observed "not started" state — a fresh,
        // unused window (Claude shows 5h at 0% with no reset). Fire only when it
        // is genuinely unused, so an active window that happens to omit a reset
        // time (with usage) is never disturbed. Compare `remainingFraction`
        // directly (avoids a second subtraction that can slip the 1% boundary).
        return fiveHour.remainingFraction >= 0.99
    }
}
