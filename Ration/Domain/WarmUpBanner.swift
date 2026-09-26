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

        /// A refusal carried inside a 2xx completion stream.
        init(streamError: WarmUpOutcome.StreamErrorKind) {
            self = streamError.meansSignedOut ? .authenticationRequired : .transient
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
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .current
    ) -> WarmUpBanner? {
        // Warm-up switched off globally: nothing is attempted, so there is no
        // failure or hold to report.
        guard warmUpEnabled else { return nil }
        // A failure is the more urgent statement, and it is about an attempt
        // that already happened — it outranks a hold.
        if let banner = failureBanner(
            presentations: presentations,
            failures: failures,
            now: now,
            locale: locale
        ) {
            return banner
        }
        return holdBanner(
            presentations: presentations,
            schedule: schedule,
            now: now,
            calendar: calendar,
            locale: locale
        )
    }

    private static func failureBanner(
        presentations: [AccountPresentation],
        failures: [UUID: AutoStartFailure],
        now: Date,
        locale: Locale
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
        let message: LocalizedStringResource = switch failure.kind {
        case .authenticationRequired: .warmUpBannerSignInAgain(label)
        case .transient: .warmUpBannerWillRetry(label)
        }
        return WarmUpBanner(
            message: message.string(in: locale) + more(than: live.count, locale: locale),
            severity: .critical
        )
    }

    private static func holdBanner(
        presentations: [AccountPresentation],
        schedule: WarmUpQuietSchedule,
        now: Date,
        calendar: Calendar,
        locale: Locale
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
        let resumption: LocalizedStringResource
        if let resetsAt, resetsAt > now {
            if UsageFormatters.isResetDue(resetsAt, relativeTo: now) {
                // Under a second away: the countdown would be the "now" unit.
                resumption = .warmUpBannerResumesNow
            } else {
                let countdown: String = UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now, locale: locale)
                resumption = .warmUpBannerResumesIn(countdown)
            }
        } else {
            resumption = .warmUpBannerResumesAtReset
        }
        let message: LocalizedStringResource = .warmUpBannerPaused(
            label,
            more(than: blocked.count, locale: locale),
            resumption.string(in: locale)
        )
        return WarmUpBanner(message: message.string(in: locale), severity: .info)
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

    /// " (+N more)" for the accounts a one-line banner does not name.
    private static func more(than count: Int, locale: Locale) -> String {
        guard count > 1 else { return "" }
        return LocalizedStringResource.warmUpBannerMore(count - 1).string(in: locale)
    }
}
