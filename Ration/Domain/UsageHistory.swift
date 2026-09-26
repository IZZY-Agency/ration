import Foundation

/// A single observation of one usage window, at ingestion time.
struct UsageHistorySample: Codable, Equatable, Sendable {
    let ts: Date            // = UsageSnapshot.fetchedAt (the ingestion clock)
    let remaining: Double   // 0…1, mirrors UsageWindow.remainingFraction
    let resetsAt: Date?
}

/// One capture-zone clock-hour of aggregated burn for a (account, kind).
struct UsageHourlyBucket: Codable, Equatable, Sendable {
    let hourStart: Date      // absolute instant of the capture-zone clock-hour start
    let tzOffsetSeconds: Int // capture-zone offset at hourStart, for hour-of-day
    var consumed: Double     // Σ within-segment downward deltas this hour (burn)
    var minRemaining: Double // depletion low-water mark
    var sampleCount: Int
    // Billing-cycle v2 fields. Optional so rollups written before v2 decode
    // (nil = "not measured"); nil is omitted on encode. A v2 fold into a
    // bucket turns nil into a value from that sample on.
    /// Σ lengths of the sample-to-sample intervals inside this hour, excluding
    /// (censoring) intervals longer than the gap limit or crossing a reset.
    var observedSeconds: Double? = nil
    /// ∫ used(t) dt over the same intervals (used = 1 − remaining, trapezoid rule).
    var usedSeconds: Double? = nil
    /// Window-instance boundaries at samples inside this hour: every detected
    /// reset (`didReset`) and, for a fixed window only, a moved reset time
    /// (see `UsageHourlyRollup.fold`).
    var resetCount: Int? = nil
    /// Boundary hours only (`resetCount > 0`), written from the first v2.1
    /// boundary on. The low-water mark of this hour's samples BEFORE its
    /// first boundary (nil when the boundary was the hour's first sample),
    /// so the ending instance keeps its true peak.
    var preBoundaryMinRemaining: Double? = nil
    /// Boundary hours only: the low-water mark of this hour's samples from
    /// its LAST boundary on — the new instance's start. Non-nil marks a
    /// split boundary hour; nil on a boundary hour means an older bucket
    /// whose low mixes both instances.
    var postBoundaryMinRemaining: Double? = nil
}

/// Versioned wrapper so schema evolution and corruption are detectable.
struct UsageHistoryEnvelope<T: Codable & Sendable>: Codable, Sendable {
    let version: Int
    var data: T
    init(version: Int = 1, data: T) {
        self.version = version
        self.data = data
    }
}

enum UsageHistoryRetention {
    /// Max raw samples retained for the current window. 5h at ~5-min cadence is
    /// ~60; weekly needs ~2016 at 5-min so it is downsampled (see `minSpacing`).
    static func rawCap(for kind: UsageWindowKind) -> Int {
        switch kind {
        case .fiveHour: 144
        case .weekly: 700
        case .modelWeekly: 700
        }
    }

    /// Minimum spacing between retained raw samples. 0 = keep every sample (5h);
    /// weekly downsamples to ≤1 sample / 15 min so 700 samples span the full week.
    static func minSpacing(for kind: UsageWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: 0
        case .weekly: 15 * 60
        case .modelWeekly: 15 * 60
        }
    }
}

enum SeriesIngestOutcome: Equatable {
    case rejected
    case accepted(previous: UsageHistorySample?, didReset: Bool)
}

/// Reset-segmented raw ring for one (account, kind). Pure and deterministic so
/// the state machine is fully unit-tested.
struct UsageWindowSeries: Equatable, Sendable {
    let kind: UsageWindowKind
    private(set) var samples: [UsageHistorySample] = []
    private(set) var resetIdentity: Date?
    private(set) var isProjectionEligible = true
    private var bucketStart: Date?

    static let upwardJumpEpsilon = 0.05
    static let notStartedThreshold = 0.99

    init(kind: UsageWindowKind) { self.kind = kind }

    /// Restore path: assigns persisted samples directly instead of replaying
    /// them through `ingest`. Replaying re-runs the downsample/reset state
    /// machine with a fresh `bucketStart`, which silently collapses a
    /// persisted multi-sample weekly series (e.g. `[600,900]` → `[900]`) on
    /// every reload. Restoration must be a pure assignment, not a re-derivation.
    init(kind: UsageWindowKind, restoredSamples: [UsageHistorySample]) {
        self.kind = kind
        let sorted = restoredSamples.sorted { $0.ts < $1.ts }
        let cap = UsageHistoryRetention.rawCap(for: kind)
        self.samples = sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
        // Restore the LATEST KNOWN reset identity, mirroring the live ingest
        // path: a trailing sample that omits `resetsAt` (a transient metadata
        // gap) must not erase a known identity, or the projector loses its ETA
        // bound (`series.resetIdentity ?? last.resetsAt`) across a restart.
        self.resetIdentity = samples.last(where: { $0.resetsAt != nil })?.resetsAt
        self.isProjectionEligible = true
    }

    mutating func ingest(
        _ sample: UsageHistorySample,
        isClaudeFiveHour: Bool
    ) -> SeriesIngestOutcome {
        // 1. Monotonic guard: reject duplicate/out-of-order (e.g. clock rollback).
        if let last = samples.last, sample.ts <= last.ts {
            if sample.ts < last.ts { isProjectionEligible = false }
            return .rejected
        }

        let previous = samples.last
        let didReset = detectReset(for: sample, isClaudeFiveHour: isClaudeFiveHour)

        // Track the LATEST reset time on every accepted ingest carrying one
        // (not just on reset/first-adopt). Claude's 5h/7d windows are
        // ROLLING: `resets_at` advances every poll, so the stable-identity
        // fast-path in `detectReset` must compare against the previous
        // poll's value, and the projector's ETA bound must use the current
        // rolling reset time. `detectReset` above already read the prior
        // identity, so overwriting it here is safe. A sample that omits
        // `resetsAt` (transient metadata gap) does NOT clear a known
        // identity on the non-reset path — it just leaves the last-known
        // value in place (see BurnRateProjectorTests
        // testETABoundedByResetIdentityEvenWhenLatestSampleOmitsResetsAt).
        if didReset {
            samples = []
            bucketStart = nil
            isProjectionEligible = true
            resetIdentity = sample.resetsAt
        } else if let incoming = sample.resetsAt {
            resetIdentity = incoming
        }

        // 2. Downsample by per-kind spacing (replace the last sample in-bucket).
        let spacing = UsageHistoryRetention.minSpacing(for: kind)
        if !didReset, spacing > 0, let start = bucketStart,
           sample.ts.timeIntervalSince(start) < spacing {
            // Still within bucket window, replace last sample
            samples[samples.count - 1] = sample
        } else {
            // Outside bucket window or no spacing, append and update bucket start
            samples.append(sample)
            if spacing > 0 {
                bucketStart = sample.ts
            }
        }

        // 3. Cap (drop oldest).
        let cap = UsageHistoryRetention.rawCap(for: kind)
        if samples.count > cap { samples.removeFirst(samples.count - cap) }

        return .accepted(previous: previous, didReset: didReset)
    }

    private func detectReset(
        for sample: UsageHistorySample,
        isClaudeFiveHour: Bool
    ) -> Bool {
        guard let last = samples.last else { return false } // first sample: no reset
        // Same reset time as the previous sample → definitely the same window;
        // ignore small `remaining` corrections (fixed-window providers).
        if let incoming = sample.resetsAt, let identity = resetIdentity, incoming == identity {
            return false
        }
        // `resetsAt` absent, drifted, or not yet adopted. A CHANGED reset time
        // is NOT itself a reset — Claude's 5h/7d limits are ROLLING windows
        // whose `resets_at` advances every poll; that drift must not clear the
        // series (which would zero every `consumed` delta). Require evidence
        // of freed capacity instead.
        if sample.remaining - last.remaining >= Self.upwardJumpEpsilon - 1e-10 { return true }
        if isClaudeFiveHour,
           sample.remaining >= Self.notStartedThreshold - 1e-10,
           last.remaining < Self.notStartedThreshold - 1e-10 {
            return true
        }
        return false
    }
}
