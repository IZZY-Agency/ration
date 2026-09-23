import Foundation

enum ResetCreditRowState: String, Codable, Sendable {
    case inactive, active, dismissed
}

/// Per-credit alert memory, keyed by the provider's credit id.
///
/// `lastSeenCount` is the last OBSERVED count, so `3 → 2` (one used) is silent
/// and `2 → 3` (one granted) alerts. `expiryHandled` is true once the expiring
/// alert fired OR was deliberately folded into an "available" alert for a
/// credit that arrived already inside the lead window.
struct ResetCreditAlertMemory: Codable, Equatable, Sendable {
    var lastSeenCount: Int
    var availableRow: ResetCreditRowState
    var expiryHandled: Bool
    var expiringRow: ResetCreditRowState
    /// The `expiresAt` last observed for this credit id. `nil` for memory
    /// persisted before this field existed, or when the stored value had
    /// the wrong type. Compared against the CURRENT credit's `expiresAt` in
    /// `ResetCreditPolicy.evaluate`: Claude grant ids are static strings
    /// (e.g. a launch grant extended), so the same id can come back with a
    /// LATER expiry — a re-grant that must be able to fire the expiring
    /// alert again even though `expiryHandled` already latched true for the
    /// OLD expiry.
    var lastSeenExpiresAt: Date?

    init(
        lastSeenCount: Int,
        availableRow: ResetCreditRowState,
        expiryHandled: Bool,
        expiringRow: ResetCreditRowState,
        lastSeenExpiresAt: Date? = nil
    ) {
        self.lastSeenCount = lastSeenCount
        self.availableRow = availableRow
        self.expiryHandled = expiryHandled
        self.expiringRow = expiringRow
        self.lastSeenExpiresAt = lastSeenExpiresAt
    }

    /// A custom decoder ONLY to give the new `lastSeenExpiresAt` field
    /// `try?` handling: the other four fields keep their original
    /// (synthesized-equivalent) throwing decode, since a malformed entry
    /// there is already isolated to this one credit id by
    /// `AccountAlertState`'s outer per-entry `compactMapValues` — dropping
    /// the whole entry on one of THOSE fields is the existing, tested
    /// contract. A wrong-typed `lastSeenExpiresAt` alone must not cost the
    /// entry its row state too — the same per-field-blast-radius reasoning
    /// as `WindowAlertMemory.init(from:)`, one level up.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeenCount = try c.decode(Int.self, forKey: .lastSeenCount)
        availableRow = try c.decode(ResetCreditRowState.self, forKey: .availableRow)
        expiryHandled = try c.decode(Bool.self, forKey: .expiryHandled)
        expiringRow = try c.decode(ResetCreditRowState.self, forKey: .expiringRow)
        lastSeenExpiresAt = try? c.decode(Date.self, forKey: .lastSeenExpiresAt)
    }
}

/// What the policy may act on: a list READ by the snapshot's own fetch, still
/// within the evidence age bound. Built by `ResetCreditPolicy.input`.
struct ResetCreditAlertInput: Equatable, Sendable {
    let credits: ResetCredits
    let leadDays: Int
    let now: Date
}

enum ResetCreditPolicy {
    static let secondsPerDay: TimeInterval = 86_400

    /// `nil` unless the list is fresh evidence: read by THIS snapshot's fetch
    /// (a carried list keeps its older `fetchedAt`) and inside `UsageEvidence`'s
    /// age / clock-skew bound.
    static func input(snapshot: UsageSnapshot?, leadDays: Int, now: Date) -> ResetCreditAlertInput? {
        guard
            let snapshot,
            let credits = snapshot.resetCredits,
            credits.fetchedAt == snapshot.fetchedAt,
            UsageEvidence.isCurrent(snapshot: snapshot, windowResetsAt: nil, now: now)
        else { return nil }
        return ResetCreditAlertInput(credits: credits, leadDays: leadDays, now: now)
    }

    static func isWithinLeadWindow(_ credit: ResetCredit, leadDays: Int, now: Date) -> Bool {
        now >= credit.expiresAt.addingTimeInterval(-Double(leadDays) * secondsPerDay) && now < credit.expiresAt
    }

    static func evaluate(
        _ input: ResetCreditAlertInput,
        memory: inout [String: ResetCreditAlertMemory],
        events: inout [AlertEvent]
    ) {
        // Collected rather than appended straight to `events`: ChatGPT is one
        // credit per entry, so a multi-credit grant (or several credits
        // crossing their expiry boundary in the same pass) would otherwise
        // post one notification and show one drop row PER CREDIT. Per-credit
        // memory below is unaffected — every credit still gets its own row
        // state — only the emitted EVENT is collapsed, after the loop.
        var availableFirings: [(credit: ResetCredit, expiringSoon: Bool)] = []
        var expiringFirings: [ResetCredit] = []

        for credit in input.credits.unexpired(at: input.now) {
            let soon = isWithinLeadWindow(credit, leadDays: input.leadDays, now: input.now)
            var entry = memory[credit.id]

            // A re-grant under the SAME id with a LATER expiry (Claude grant
            // ids are static strings, e.g. a launch grant extended) is
            // genuinely new information for the expiry alert, even though
            // `expiryHandled` may already be latched true for the OLD
            // expiry. Re-arm BEFORE the expiring check below, so a re-grant
            // that lands already inside its new lead window fires in this
            // same pass. One-directional: an EARLIER expiry (a correction,
            // not a re-grant) must never undo an already-fired alert.
            if let lastSeenExpiresAt = entry?.lastSeenExpiresAt, credit.expiresAt > lastSeenExpiresAt {
                entry?.expiryHandled = false
                entry?.expiringRow = .inactive
            }

            if entry == nil || credit.count > entry!.lastSeenCount {
                availableFirings.append((credit: credit, expiringSoon: soon))
                var next = entry ?? ResetCreditAlertMemory(lastSeenCount: 0, availableRow: .inactive, expiryHandled: false, expiringRow: .inactive)
                next.availableRow = .active
                // Mirror of the "one row per credit" retraction below: a
                // replenishment (count increase) re-activating the
                // available row after the expiring alert already fired for
                // this credit must retract that expiring row too, or the
                // same credit shows twice — one row saying available,
                // another saying it's about to expire. Only if still
                // active; an already-dismissed row is not resurrected.
                if next.expiringRow == .active { next.expiringRow = .inactive }
                if soon && !next.expiryHandled { next.expiryHandled = true }
                entry = next
            } else if soon, !entry!.expiryHandled {
                expiringFirings.append(credit)
                entry!.expiryHandled = true
                entry!.expiringRow = .active
                // One row per credit: an expiring alert supersedes the
                // "available" one for the same credit, so retract that row
                // too — but only if it is still active. A row the user
                // already dismissed stays dismissed; it must not be
                // resurrected as .inactive only to sit invisible either way.
                if entry!.availableRow == .active { entry!.availableRow = .inactive }
            }
            entry!.lastSeenCount = credit.count
            entry!.lastSeenExpiresAt = credit.expiresAt
            memory[credit.id] = entry
        }
        if let merged = mergeAvailable(availableFirings) { events.append(merged) }
        if let merged = mergeExpiring(expiringFirings) { events.append(merged) }

        if input.credits.complete {
            let present = Set(input.credits.items.map(\.id))
            memory = memory.filter { present.contains($0.key) }
        }
    }

    private static func mergeAvailable(_ firings: [(credit: ResetCredit, expiringSoon: Bool)]) -> AlertEvent? {
        guard !firings.isEmpty else { return nil }
        guard firings.count > 1 else {
            return .resetCreditAvailable(credit: firings[0].credit, expiringSoon: firings[0].expiringSoon)
        }
        let merged = mergedCredit(firings.map(\.credit))
        return .resetCreditAvailable(credit: merged, expiringSoon: firings.contains(where: \.expiringSoon))
    }

    private static func mergeExpiring(_ credits: [ResetCredit]) -> AlertEvent? {
        guard !credits.isEmpty else { return nil }
        guard credits.count > 1 else { return .resetCreditExpiring(credit: credits[0]) }
        return .resetCreditExpiring(credit: mergedCredit(credits))
    }

    /// One `ResetCredit` standing in for several that fired together — see
    /// `evaluate`'s doc. `id`/`expiresAt` come from the soonest-expiring
    /// member (a real, existing credit id — never synthesized), `count` is
    /// their sum, `title` is kept only when it isn't a guess (exactly one
    /// distinct non-nil title among them), and `usableNow` only when every
    /// member agrees.
    private static func mergedCredit(_ credits: [ResetCredit]) -> ResetCredit {
        let soonest = credits.min { $0.expiresAt < $1.expiresAt }!
        let titles = Set(credits.compactMap(\.title))
        let usableStates = Set(credits.map(\.usableNow))
        let usableNow: Bool?
        if usableStates == [true] { usableNow = true }
        else if usableStates == [false] { usableNow = false }
        else { usableNow = nil }
        return ResetCredit(
            id: soonest.id,
            title: titles.count == 1 ? titles.first : nil,
            count: credits.reduce(0) { $0 + $1.count },
            expiresAt: soonest.expiresAt,
            usableNow: usableNow
        )
    }
}
