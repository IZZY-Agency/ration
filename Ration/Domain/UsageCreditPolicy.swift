import Foundation

/// What one usage-credit expiry warning says: the money that expires, when,
/// and whether claude.ai would spend it past a plan limit. Every value is
/// fixed when the policy fires; the notification and drop copy are built
/// from these alone.
struct UsageCreditExpiry: Equatable, Sendable {
    /// The soonest-expiring grant among those that fired together — a real
    /// grant id, never synthesized. The notification id is built from it.
    let grantID: String
    /// Every fired grant's remaining amount, summed.
    let amount: Money
    let expiresAt: Date
    /// claude.ai's switch is off: the credits would not be spent past a limit.
    let switchOff: Bool
    /// Every grant this warning covers (drop-row dismissal acknowledges all).
    let grantIDs: [String]
}

/// Per-grant alert memory, keyed by the grant id.
///
/// `expiryHandled` latches once the warning fired for the grant's CURRENT
/// expiry; `lastSeenExpiresAt` lets a later expiry for the same id (an
/// extended grant) re-arm it. `row` is the drop row's state.
struct UsageCreditAlertMemory: Codable, Equatable, Sendable {
    var expiryHandled: Bool
    var row: ResetCreditRowState
    var lastSeenExpiresAt: Date?

    init(expiryHandled: Bool, row: ResetCreditRowState, lastSeenExpiresAt: Date? = nil) {
        self.expiryHandled = expiryHandled
        self.row = row
        self.lastSeenExpiresAt = lastSeenExpiresAt
    }

    /// A wrong-typed `lastSeenExpiresAt` alone must not cost the entry its
    /// latch and row state (same per-field blast radius as
    /// `ResetCreditAlertMemory`).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expiryHandled = try c.decode(Bool.self, forKey: .expiryHandled)
        row = try c.decode(ResetCreditRowState.self, forKey: .row)
        lastSeenExpiresAt = try? c.decode(Date.self, forKey: .lastSeenExpiresAt)
    }
}

/// What the policy may act on: a reading young enough to speak for the
/// present. Built by `UsageCreditPolicy.input`.
struct UsageCreditAlertInput: Equatable, Sendable {
    let credits: UsageCredits
    let switchOff: Bool
    let leadDays: Int
    let now: Date
}

/// Pure expiry-warning policy for Claude usage credits, beside
/// `ResetCreditPolicy`: one warning per grant per expiry, several grants in
/// one pass merged into one event.
enum UsageCreditPolicy {
    /// `nil` unless the reading is current evidence: read within
    /// `UsageEvidence.maxAge` and not dated beyond the allowed clock skew.
    /// Unlike resets, credits have their own read (later than the snapshot's
    /// fetch), so freshness is the reading's age, not equality with the
    /// snapshot's `fetchedAt`.
    ///
    /// And only a reading this session applied for the snapshot's own
    /// organization: one restored from disk (no organization) or carried
    /// across a workspace switch is display-only.
    static func input(snapshot: UsageSnapshot?, leadDays: Int, now: Date) -> UsageCreditAlertInput? {
        guard
            let snapshot,
            snapshot.usageCreditsVerified,
            let credits = snapshot.usageCredits,
            isCurrent(credits, now: now)
        else { return nil }
        return UsageCreditAlertInput(
            credits: credits,
            switchOff: snapshot.usageCreditsEnabled == false,
            leadDays: leadDays,
            now: now
        )
    }

    static func isCurrent(_ credits: UsageCredits, now: Date) -> Bool {
        let age = now.timeIntervalSince(credits.fetchedAt)
        return age <= UsageEvidence.maxAge && age >= -UsageEvidence.allowedClockSkew
    }

    /// Inside `[expiresAt - leadDays, expiresAt)`. A grant without an expiry
    /// never is.
    static func isWithinLeadWindow(_ grant: UsageCreditGrant, leadDays: Int, now: Date) -> Bool {
        guard let expiresAt = grant.expiresAt else { return false }
        return now >= expiresAt.addingTimeInterval(-Double(leadDays) * ResetCreditPolicy.secondsPerDay) && now < expiresAt
    }

    static func evaluate(
        _ input: UsageCreditAlertInput,
        memory: inout [String: UsageCreditAlertMemory],
        events: inout [AlertEvent]
    ) {
        var fired: [UsageCreditGrant] = []
        for grant in input.credits.grants(unexpiredAt: input.now) {
            guard let expiresAt = grant.expiresAt else { continue }
            var entry = memory[grant.id] ?? UsageCreditAlertMemory(expiryHandled: false, row: .inactive)
            // A LATER expiry under the same id is an extended grant: warn
            // again for the new date. One-directional — an earlier expiry
            // (a correction) never undoes a warning already given.
            if let last = entry.lastSeenExpiresAt, expiresAt > last {
                entry.expiryHandled = false
                entry.row = .inactive
            }
            if !entry.expiryHandled, isWithinLeadWindow(grant, leadDays: input.leadDays, now: input.now) {
                fired.append(grant)
                entry.expiryHandled = true
                entry.row = .active
            }
            // The LATEST expiry ever seen: a correction to an earlier date
            // and back must not read as an extension and warn twice.
            entry.lastSeenExpiresAt = max(entry.lastSeenExpiresAt ?? expiresAt, expiresAt)
            memory[grant.id] = entry
        }
        if let event = merged(fired, switchOff: input.switchOff) {
            events.append(event)
        }
        if input.credits.complete {
            let present = Set(input.credits.grants.map(\.id))
            memory = memory.filter { present.contains($0.key) }
        }
    }

    /// One event for every grant that fired in the same pass: the amounts
    /// summed, the soonest grant's id and expiry.
    private static func merged(_ grants: [UsageCreditGrant], switchOff: Bool) -> AlertEvent? {
        guard let soonest = grants.min(by: { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }),
              let expiresAt = soonest.expiresAt
        else { return nil }
        // Same currency by construction (the decoder skips others), and far
        // below overflow; should either ever fail, the soonest grant's own
        // amount is still true, just not the whole.
        let amount = Money.sum(grants.map(\.remaining)) ?? soonest.remaining
        return .usageCreditExpiring(UsageCreditExpiry(
            grantID: soonest.id,
            amount: amount,
            expiresAt: expiresAt,
            switchOff: switchOff,
            grantIDs: grants.map(\.id)
        ))
    }
}
