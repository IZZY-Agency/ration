import Foundation

/// A recorded warm-up (auto-start) failure. Stores the FACTS — when, and which
/// kind — never the rendered sentence: the label is read live at render time, so
/// a renamed account cannot be described by a stale string.
struct AutoStartFailure: Equatable {
    /// The two outcomes that read differently to a user. Only a genuine auth
    /// rejection (401/403) should ask them to sign in again — every other
    /// failure (transport, a rejected model, an org that couldn't be discovered
    /// this cycle, a 429) retries on a later poll, so "Sign in again" would be
    /// a misdiagnosis. That misdiagnosis was the visible symptom of an earlier
    /// bug: a heavy account whose conversation list overflowed the 1 MB cap
    /// failed model discovery every poll and was told, wrongly, to
    /// re-authenticate while its session was perfectly valid.
    enum Kind: Equatable {
        case authenticationRequired
        case transient

        init(error: Error) {
            if
                case let ClaudeMessageSender.SendError.rejected(status) = error,
                status == 401 || status == 403
            {
                self = .authenticationRequired
            } else {
                self = .transient
            }
        }
    }

    let at: Date
    let kind: Kind
}

/// One line of warm-up status for the popover.
struct WarmUpBanner: Equatable {
    enum Severity: Equatable {
        /// Something went wrong and the user may need to act.
        case critical
        /// Warm-up is deliberately holding off; nothing is broken.
        case info
    }

    let message: String
    let severity: Severity
}

/// Derives the warm-up banner from live state. Nothing here is stored: the
/// banner exists exactly as long as the thing it describes is still true.
///
/// Its predecessor was a written-once `AppModel.errorMessage`, which nothing in
/// the app ever cleared — an auto-start failure stayed on screen until the app
/// was quit, and outlived even a later warm-up that succeeded.
enum WarmUpBannerModel {
    /// How long a usage observation may keep speaking for the present.
    /// Delegates to `UsageEvidence`, which owns this rule for every surface
    /// that asserts "you are near a limit" — kept as an alias so existing
    /// call sites and tests continue to read naturally here.
    static let maxEvidenceAge = UsageEvidence.maxAge

    static func banner(
        presentations: [AccountPresentation],
        failures: [UUID: AutoStartFailure],
        schedule: WarmUpQuietSchedule,
        warmUpEnabled: Bool = true,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> WarmUpBanner? {
        // Warm-up switched off globally: nothing is attempted, so there is no
        // failure or hold to report.
        guard warmUpEnabled else { return nil }
        // A failure is the more urgent statement, and it is about an attempt
        // that already happened — it outranks a hold.
        if let banner = failureBanner(
            presentations: presentations,
            failures: failures,
            now: now
        ) {
            return banner
        }
        return holdBanner(
            presentations: presentations,
            schedule: schedule,
            now: now,
            calendar: calendar
        )
    }

    private static func failureBanner(
        presentations: [AccountPresentation],
        failures: [UUID: AutoStartFailure],
        now: Date
    ) -> WarmUpBanner? {
        let live = presentations
            .filter { AutoStartPolicy.isEffectivelyEnabled($0.account) }
            .compactMap { presentation -> (AccountPresentation, AutoStartFailure)? in
                guard let failure = failures[presentation.id] else { return nil }
                // One warm-up window is the whole life of the statement "the
                // last attempt failed": past it the policy has had another
                // chance to fire, so a still-standing banner would be asserting
                // something it can no longer know.
                guard
                    now.timeIntervalSince(failure.at) < AutoStartPolicy.minimumInterval
                else { return nil }
                return (presentation, failure)
            }
            // Priority, then recency: one row speaks for the whole group, so it
            // has to be the one that asks the user to DO something. A newer
            // transient failure must not hide an account that needs signing in
            // again.
            .sorted { first, second in
                let firstNeedsAction = first.1.kind == .authenticationRequired
                let secondNeedsAction = second.1.kind == .authenticationRequired
                if firstNeedsAction != secondNeedsAction {
                    return firstNeedsAction
                }
                return first.1.at > second.1.at
            }

        guard let (presentation, failure) = live.first else { return nil }
        let label = presentation.account.label
        let message = switch failure.kind {
        case .authenticationRequired:
            "Auto-start for \(label): Claude needs you to sign in again."
        case .transient:
            "Auto-start for \(label) didn’t run this time; it will retry automatically."
        }
        return WarmUpBanner(
            message: message + more(than: live.count),
            severity: .critical
        )
    }

    private static func holdBanner(
        presentations: [AccountPresentation],
        schedule: WarmUpQuietSchedule,
        now: Date,
        calendar: Calendar
    ) -> WarmUpBanner? {
        let blocked = presentations
            .compactMap { presentation -> (String, Date?)? in
                guard
                    let snapshot = presentation.snapshot,
                    case let .blockedByWeeklyLimit(resetsAt) = AutoStartPolicy.decide(
                        account: presentation.account,
                        fiveHour: snapshot.fiveHour,
                        weekly: snapshot.weekly,
                        now: now,
                        schedule: schedule,
                        calendar: calendar
                    ),
                    isCurrentEvidence(snapshot: snapshot, resetsAt: resetsAt, now: now)
                else { return nil }
                return (presentation.account.label, resetsAt)
            }
            // Soonest to recover first, so the countdown shown is the one that
            // ends the hold for at least one account. Unknown (and already
            // passed) resets last — they carry no countdown to show.
            .sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }

        guard let (label, resetsAt) = blocked.first else { return nil }
        // Only a reset still ahead of us can be counted down to. A spent
        // allowance observed AFTER its own reported reset is real (see
        // `isCurrentEvidence`) but its next reset is unknown until the provider
        // publishes one.
        let resumption = resetsAt.map { $0 > now
            ? "resumes in \(UsageFormatters.remainingUntilReset($0, relativeTo: now))"
            : "resumes when the limit resets"
        } ?? "resumes when the limit resets"
        return WarmUpBanner(
            message: "Warm-up paused for \(label)"
                + more(than: blocked.count)
                + " — weekly limit reached; \(resumption).",
            severity: .info
        )
    }

    /// Whether an observation still describes the present — the shared
    /// `UsageEvidence` predicate (age bound plus not-overtaken-by-its-own-reset).
    /// The warm-up banner and the attention drop must never disagree about
    /// whether a number is still true, so the rule lives in one place.
    private static func isCurrentEvidence(
        snapshot: UsageSnapshot,
        resetsAt: Date?,
        now: Date
    ) -> Bool {
        UsageEvidence.isCurrent(snapshot: snapshot, windowResetsAt: resetsAt, now: now)
    }

    private static func more(than count: Int) -> String {
        count > 1 ? " (+\(count - 1) more)" : ""
    }
}
