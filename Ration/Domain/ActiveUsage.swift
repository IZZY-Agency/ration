import Foundation

/// A per-provider "in use" detection: when the account was last observed
/// burning, and which usage window produced it. A `.weekly` source means the
/// account reports no finer window at all (the detector prefers 5h whenever a
/// 5h series exists), so weekly is that account's live signal and classifies
/// like any other — demoting it would make weekly-only providers (ChatGPT)
/// permanently unable to read as in use.
struct ActiveUsage: Equatable, Sendable {
    let lastUsedAt: Date
    let source: UsageWindowKind
}

/// Pure age → display-phase mapping for the in-use marker. Half-open ranges so
/// the boundaries never overlap; future-dated timestamps read as `.none`.
enum InUsePhase: Equatable {
    case inUse(age: TimeInterval)
    case lastUsed(age: TimeInterval)
    case none

    /// Upper bound (inclusive) of the bright IN USE phase for fine-grained
    /// (5h) sources, in seconds.
    static let inUseThreshold: TimeInterval = 900
    /// Weekly percent moves in 1% steps that land ~16–18 minutes apart even
    /// under CONTINUOUS use (live-measured on ChatGPT 2026-08-17), so a
    /// 15-minute bright phase would flicker off between steps. Weekly-sourced
    /// marks get a window comfortably wider than the step cadence.
    static let weeklyInUseThreshold: TimeInterval = 1800

    static func classify(lastUsedAt: Date?, source: UsageWindowKind, now: Date) -> InUsePhase {
        guard let lastUsedAt else { return .none }
        let age = now.timeIntervalSince(lastUsedAt)
        if age < 0 { return .none }                              // future-dated
        if age > ActiveUsageDetector.lookback { return .none }   // older than 5h
        let threshold = source == .weekly ? weeklyInUseThreshold : inUseThreshold
        if age <= threshold {
            return .inUse(age: age)
        }
        return .lastUsed(age: age)
    }

    static func classify(_ usage: ActiveUsage?, now: Date) -> InUsePhase {
        classify(
            lastUsedAt: usage?.lastUsedAt,
            source: usage?.source ?? .fiveHour,
            now: now
        )
    }
}
