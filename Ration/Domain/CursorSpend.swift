import Foundation

/// Cursor's usage-based spend for the current billing cycle. Dollars, not a
/// fraction — Cursor's web API exposes spend + the invoice period, never a
/// percentage (see the re-scope design). Both period fields are copied from
/// the API (`periodStartMs` / `periodEndMs`), never inferred.
///
/// `periodStart` is the cycle's IDENTITY (live-verified 2026-08-27 as the
/// calendar boundary, `2026-08-01T00:00:00Z`). `resetsAt` is the API's
/// `periodEndMs`, which for the OPEN invoice is the observation cutoff — the
/// fetch time, advancing on every poll — not a boundary; it was one before
/// 2026-08-27, which is why the field keeps its name. Only the start says
/// whether two observations belong to the same invoice. `periodStart` is
/// optional because a `snapshots.json` written before 0.28.2 has no value for
/// it; `nil` means "unknown", never a guessed date.
struct CursorSpend: Codable, Equatable, Sendable {
    let spentCents: Int
    let periodStart: Date?
    let resetsAt: Date
    let planLabel: String

    var spentDollars: Double { Double(spentCents) / 100 }

    /// The reported end, if it is still ahead — the one rule for "is there a
    /// countdown to show", shared by the card and the drop row so the two
    /// cannot disagree. The open invoice's `periodEndMs` is the fetch time, so
    /// this is `nil` for it: an end already behind us is not a countdown.
    func futureReset(relativeTo now: Date) -> Date? {
        resetsAt > now ? resetsAt : nil
    }
}

extension CursorSpend {
    private enum CodingKeys: String, CodingKey {
        case spentCents, periodStart, resetsAt, planLabel
    }

    /// In an extension so the memberwise initializer survives. `periodStart`
    /// is `decodeIfPresent`: absent in older snapshot files, and its absence
    /// must not throw the whole store away.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spentCents = try c.decode(Int.self, forKey: .spentCents)
        periodStart = try c.decodeIfPresent(Date.self, forKey: .periodStart)
        resetsAt = try c.decode(Date.self, forKey: .resetsAt)
        planLabel = try c.decode(String.self, forKey: .planLabel)
    }
}
