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

    /// Which windows a target must have room on (Codex switch spec §4.5):
    /// the weekly always (plus Fable for a Claude Code Fable rule), the
    /// 5-hour only when the account reports one. ChatGPT often reports only a
    /// weekly limit, and since Anthropic's 2026-10-30 change a verified Claude
    /// Ultra account has no 5-hour limit at all. A reported-but-invalid
    /// window fails the fetch, and one reported without its numbers is named
    /// in `UsageSnapshot.unreadableWindowKinds` and counts as unknown, so an
    /// absent window is truly absent.
    struct Policy: Equatable, Sendable {
        /// Missing → unknown usage (Fable: no Fable limit → ineligible).
        let required: [UsageWindowKind]
        /// Considered only when reported; then current and below the threshold like a required one.
        let optional: [UsageWindowKind]

        static func claudeCode(for rule: Rule) -> Policy {
            Policy(required: rule.kind == .modelWeekly ? [.weekly, .modelWeekly] : [.weekly], optional: [.fiveHour])
        }
        static let codex = Policy(required: [.weekly], optional: [.fiveHour])

        /// The windows `snapshot` must have room on: every required one and
        /// each optional one it reports.
        func kinds(reportedBy snapshot: UsageSnapshot) -> [UsageWindowKind] {
            required + optional.filter { snapshot.window(for: $0) != nil }
        }
    }

    /// The limit the rule is measured on for the account Claude Code uses:
    /// the rule's own, or, for a 5-hour rule on an account with no 5-hour
    /// limit (a verified Ultra since Anthropic's 2026-10-30 change), its
    /// weekly. Nil when the account reports neither — including a 5-hour
    /// window it has but that could not be read: no stand-in for unknown.
    static func measuredKind(for rule: Rule, in snapshot: UsageSnapshot) -> UsageWindowKind? {
        if snapshot.window(for: rule.kind) != nil { return rule.kind }
        if rule.kind == .fiveHour, snapshot.hasNoFiveHourLimit { return .weekly }
        return nil
    }

    static func decide(current: Candidate, others: [Candidate], rule: Rule, now: Date) -> Decision {
        decide(current: current, others: others, rule: rule, policy: .claudeCode(for: rule), now: now)
    }

    static func decide(current: Candidate, others: [Candidate], rule: Rule, policy: Policy, now: Date) -> Decision {
        guard current.verified, current.usable, let snapshot = current.snapshot,
              let kind = measuredKind(for: rule, in: snapshot),
              let window = snapshot.window(for: kind),
              UsageEvidence.isCurrent(snapshot: snapshot, windowResetsAt: window.resetsAt, now: now)
        else { return .none }
        let used = 1 - window.remainingFraction
        guard used * 100 >= Double(rule.percent) else { return .none }
        let usedPercent = Int((used * 100).rounded(.down))

        let pool = others.filter { $0.verified && !$0.isPaused && $0.signInUUID != current.signInUUID }
        var eligible: [(candidate: Candidate, remaining: Double)] = []
        var unknown = false
        for candidate in pool {
            guard let snapshot = candidate.snapshot else { unknown = true; continue }
            // Reported but unreadable: unknown, never "optional and absent".
            if !snapshot.unreadableWindowKinds.isDisjoint(with: policy.required + policy.optional) { unknown = true; continue }
            let missing = policy.required.filter { snapshot.window(for: $0) == nil }
            // A required 5-hour or weekly window not reported is unknown usage;
            // no Fable window means the account has no Fable limit — ineligible.
            if missing.contains(where: { $0 != .modelWeekly }) { unknown = true; continue }
            if !missing.isEmpty { continue }
            let kinds = policy.kinds(reportedBy: snapshot)
            let standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: now)
            if standing.hasUnknown { unknown = true; continue }
            guard candidate.usable, standing.known.count == kinds.count,
                  standing.known.allSatisfy({ (1 - $0.window.remainingFraction) * 100 < Double(rule.percent) })
            else { continue }
            // Room on the rule's limit. A target that does not report that
            // (optional) window has no such limit — an Ultra account under a
            // 5-hour rule — so its room is its tightest window instead.
            guard let room = snapshot.window(for: rule.kind)?.remainingFraction
                    ?? standing.known.map(\.window.remainingFraction).min()
            else { continue }
            eligible.append((candidate, room))
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
