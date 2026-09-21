import Foundation

enum ActiveUsageDetector {
    /// Activity older than this is not "currently using" (aligns with the 5h window).
    static let lookback: TimeInterval = 5 * 3600
    /// A downward delta only counts when its sample pair is at most this far
    /// apart — otherwise usage accumulated across sleep / missed refreshes would
    /// read as "just now" (the timestamp is observation time, not usage time).
    ///
    /// Must exceed the SLOWEST healthy poll interval or the detector starves on
    /// perfectly good data: Low Power Mode polls every
    /// `PollSchedule.lowPowerSeconds + maxJitterSeconds` (960s), which the old
    /// 900s bound sat below — IN USE was mathematically impossible in Low Power
    /// Mode. 1200s = worst-case cadence + scheduling slop, still tight enough
    /// that sleep-accumulated usage cannot read as a live burn.
    /// (Relationship pinned by `testMaxGapCoversWorstCaseHealthyPollInterval`.)
    static let maxGap: TimeInterval = 1200
    /// Noise floor on cumulative burn (float tolerance `epsilon + 1e-10`).
    /// Both meters move in whole-percent quanta, so the floor sits at HALF a
    /// quantum: a lone 1% step — the only signal a weekly-only account emits
    /// within the lookback under light use — always clears it regardless of FP
    /// representation, while representation dust still fails. A full-quantum
    /// floor silently demanded TWO steps and kept ChatGPT dark for hours.
    /// (Pinned by `testNoiseFloorSitsBelowOneMeterQuantum`.)
    static let epsilon = 0.005

    private struct Candidate {
        let id: UUID
        let provider: Provider
        let lastUsedAt: Date
        let burn: Double
        let order: Int
        let source: UsageWindowKind
    }

    /// One candidate per account with a qualifying burn: the newest qualifying
    /// downward step within the 5h lookback. 5h is authoritative when a 5h
    /// series exists (even a single sample); weekly is used only when there is
    /// no 5h series at all. `fiveHourSamples[id]` / `weeklySamples[id]` are
    /// that account's raw samples, ascending `ts`.
    private static func candidates(
        accounts: [AccountRecord],
        fiveHourSamples: [UUID: [UsageHistorySample]],
        weeklySamples: [UUID: [UsageHistorySample]],
        now: Date
    ) -> [Candidate] {
        let nowTs = now.timeIntervalSince1970
        var result: [Candidate] = []

        for account in accounts {
            // 5h authoritative when a series exists; weekly only when absent.
            let hasFiveHour = !(fiveHourSamples[account.id]?.isEmpty ?? true)
            let source: UsageWindowKind = hasFiveHour ? .fiveHour : .weekly
            let samples = (hasFiveHour ? fiveHourSamples[account.id] : weeklySamples[account.id]) ?? []
            guard samples.count >= 2 else { continue }

            var burn = 0.0
            var lastUsedAt: Date?
            for i in 1..<samples.count {
                let prev = samples[i - 1], cur = samples[i]
                let curTs = cur.ts.timeIntervalSince1970
                let prevTs = prev.ts.timeIntervalSince1970
                let delta = prev.remaining - cur.remaining
                guard delta > 0,                       // downward burn
                      curTs - prevTs <= maxGap,        // bounded inter-sample gap
                      curTs <= nowTs,                  // reject future-dated
                      nowTs - curTs <= lookback        // within 5h lookback
                else { continue }
                burn += delta
                lastUsedAt = cur.ts
            }

            guard burn > epsilon + 1e-10, let lastUsedAt else { continue }
            result.append(Candidate(
                id: account.id,
                provider: account.provider,
                lastUsedAt: lastUsedAt,
                burn: burn,
                order: account.displayOrder,
                source: source
            ))
        }
        return result
    }

    /// EVERY account with a qualifying burn — no per-provider winner
    /// selection. Two same-provider accounts burning in parallel both carry
    /// their own mark; the menu-bar gauges draw each one's in-use dot from
    /// this. Same gap/lookback/floor rules as `mostActive`.
    static func perAccount(
        accounts: [AccountRecord],
        fiveHourSamples: [UUID: [UsageHistorySample]],
        weeklySamples: [UUID: [UsageHistorySample]],
        now: Date
    ) -> [UUID: ActiveUsage] {
        candidates(
            accounts: accounts,
            fiveHourSamples: fiveHourSamples,
            weeklySamples: weeklySamples,
            now: now
        ).reduce(into: [:]) { result, candidate in
            result[candidate.id] = ActiveUsage(
                lastUsedAt: candidate.lastUsedAt, source: candidate.source
            )
        }
    }

    /// Per provider, the account most-recently *used* — the winner among that
    /// provider's candidates. This is the popover pill / pin-capture answer to
    /// "which account am I on"; gauges use `perAccount` instead.
    static func mostActive(
        accounts: [AccountRecord],
        fiveHourSamples: [UUID: [UsageHistorySample]],
        weeklySamples: [UUID: [UsageHistorySample]],
        now: Date
    ) -> [UUID: ActiveUsage] {
        func beats(_ x: Candidate, _ y: Candidate) -> Bool {
            if x.lastUsedAt != y.lastUsedAt { return x.lastUsedAt > y.lastUsedAt }
            if x.burn != y.burn { return x.burn > y.burn }
            return x.order < y.order
        }

        var bestByProvider: [Provider: Candidate] = [:]
        for candidate in candidates(
            accounts: accounts,
            fiveHourSamples: fiveHourSamples,
            weeklySamples: weeklySamples,
            now: now
        ) {
            if let best = bestByProvider[candidate.provider], !beats(candidate, best) { continue }
            bestByProvider[candidate.provider] = candidate
        }

        return bestByProvider.values.reduce(into: [:]) { result, best in
            result[best.id] = ActiveUsage(lastUsedAt: best.lastUsedAt, source: best.source)
        }
    }
}
