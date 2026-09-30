import Foundation

/// The automatic switching rule (spec §4.5). Pure: the model feeds it the
/// Claude accounts and acts on its decision.
enum ClaudeCodeAutoSwitch {
    /// "When `percent`% of the `kind` limit is used." Default: 75% of the weekly.
    struct Rule: Codable, Equatable, Sendable {
        var percent = 75
        var kind: UsageWindowKind = .weekly
    }

    struct Candidate: Equatable, Sendable {
        let accountID: UUID
        let signInUUID: String
        /// The link between this Ration account and the sign-in is proven by
        /// the organization id, not only chosen by the user.
        let verified: Bool
        let isPaused: Bool
        /// Not waiting for a new sign-in or blocked (`UsageHeadroom.isUsableState`).
        let usable: Bool
        let snapshot: UsageSnapshot?
        let planUnits: Int?
        let order: Int
    }

    enum Decision: Equatable, Sendable {
        case none
        case switchTo(signInUUID: String, accountID: UUID, usedPercent: Int)
        /// Every other candidate's usage is current, and none has room.
        case noRoom(usedPercent: Int, candidates: [String])
        /// None has room that Ration can see, but some usage is not current.
        case waiting(usedPercent: Int)
    }

    /// The limits a target must have room on: always the 5-hour and weekly,
    /// plus Fable weekly for a Fable rule.
    static func consideredKinds(for rule: Rule) -> [UsageWindowKind] {
        rule.kind == .modelWeekly ? [.weekly, .fiveHour, .modelWeekly] : [.weekly, .fiveHour]
    }

    static func decide(current: Candidate, others: [Candidate], rule: Rule, now: Date) -> Decision {
        guard current.verified, current.usable, let snapshot = current.snapshot,
              let window = snapshot.window(for: rule.kind),
              UsageEvidence.isCurrent(snapshot: snapshot, windowResetsAt: window.resetsAt, now: now)
        else { return .none }
        let used = 1 - window.remainingFraction
        guard used * 100 >= Double(rule.percent) else { return .none }
        let usedPercent = Int((used * 100).rounded(.down))

        let kinds = consideredKinds(for: rule)
        let pool = others.filter { $0.verified && !$0.isPaused && $0.signInUUID != current.signInUUID }
        var eligible: [(candidate: Candidate, remaining: Double)] = []
        var unknown = false
        for candidate in pool {
            guard let snapshot = candidate.snapshot else { unknown = true; continue }
            let missing = kinds.filter { snapshot.window(for: $0) == nil }
            // A 5-hour or weekly window not reported is unknown usage; no Fable
            // window means the account has no Fable limit — ineligible.
            if missing.contains(where: { $0 != .modelWeekly }) { unknown = true; continue }
            if !missing.isEmpty { continue }
            let standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: now)
            if standing.hasUnknown { unknown = true; continue }
            guard candidate.usable, standing.known.count == kinds.count,
                  standing.known.allSatisfy({ (1 - $0.window.remainingFraction) * 100 < Double(rule.percent) }),
                  let target = snapshot.window(for: rule.kind)
            else { continue }
            eligible.append((candidate, target.remainingFraction))
        }
        if let best = eligible.min(by: { isBetter($0, than: $1) }) {
            return .switchTo(signInUUID: best.candidate.signInUUID, accountID: best.candidate.accountID, usedPercent: usedPercent)
        }
        return unknown ? .waiting(usedPercent: usedPercent) : .noRoom(usedPercent: usedPercent, candidates: pool.map(\.signInUUID).sorted())
    }

    /// Most room on the rule's limit; then the larger plan (unknown last), the
    /// sooner weekly reset (none last), the card order. An estimate: plan
    /// units are not a measured allowance, so they only break ties.
    private static func isBetter(_ a: (candidate: Candidate, remaining: Double), than b: (candidate: Candidate, remaining: Double)) -> Bool {
        if a.remaining != b.remaining { return a.remaining > b.remaining }
        if a.candidate.planUnits != b.candidate.planUnits { return (a.candidate.planUnits ?? -1) > (b.candidate.planUnits ?? -1) }
        let aReset = a.candidate.snapshot?.weekly?.resetsAt ?? .distantFuture
        let bReset = b.candidate.snapshot?.weekly?.resetsAt ?? .distantFuture
        if aReset != bReset { return aReset < bReset }
        return a.candidate.order < b.candidate.order
    }
}
