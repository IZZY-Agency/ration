import XCTest
@testable import Ration

final class ActiveUsageDetectorTests: XCTestCase {
    private func acct(_ id: UUID, _ provider: Provider, order: Int) -> AccountRecord {
        AccountRecord(id: id, provider: provider, label: "L\(order)", webProfileID: UUID(), displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
    }
    private func s(_ t: TimeInterval, _ r: Double) -> UsageHistorySample {
        UsageHistorySample(ts: Date(timeIntervalSince1970: t), remaining: r, resetsAt: nil)
    }
    private let now = Date(timeIntervalSince1970: 10_000)
    private func run(_ accts: [AccountRecord], five: [UUID: [UsageHistorySample]] = [:], weekly: [UUID: [UsageHistorySample]] = [:]) -> [UUID: ActiveUsage] {
        ActiveUsageDetector.mostActive(accounts: accts, fiveHourSamples: five, weeklySamples: weekly, now: now)
    }

    func testPerAccountMarksEveryBurningAccountEvenWithinOneProvider() {
        // `mostActive` deliberately keeps one winner per provider (the popover
        // pill answers "which account am I on"); the menu-bar dots need the
        // un-deduped truth — two same-provider accounts burning in parallel
        // both carry their own mark.
        let a = UUID(); let b = UUID()
        let five: [UUID: [UsageHistorySample]] = [
            a: [s(9000, 0.9), s(9200, 0.6)],
            b: [s(9600, 0.9), s(9800, 0.6)],
        ]
        let r = ActiveUsageDetector.perAccount(
            accounts: [acct(a, .claude, order: 0), acct(b, .claude, order: 1)],
            fiveHourSamples: five, weeklySamples: [:], now: now
        )
        XCTAssertEqual(r[a], ActiveUsage(lastUsedAt: Date(timeIntervalSince1970: 9200), source: .fiveHour))
        XCTAssertEqual(r[b], ActiveUsage(lastUsedAt: Date(timeIntervalSince1970: 9800), source: .fiveHour))
    }

    func testPerAccountAppliesTheSameQualifyingRules() {
        // Same gap/lookback/floor gates as `mostActive`: an account whose only
        // burn crosses a too-large gap stays unmarked.
        let a = UUID()
        let five = [a: [s(6000, 0.9), s(9900, 0.5)]] // gap 3900s > maxGap
        XCTAssertTrue(ActiveUsageDetector.perAccount(
            accounts: [acct(a, .claude, order: 0)],
            fiveHourSamples: five, weeklySamples: [:], now: now
        ).isEmpty)
    }

    func testMostRecentlyUsedAccountWinsWithinProvider() {
        let a = UUID(); let b = UUID()
        // a's last burn is older than b's, though both burned in-lookback.
        let five: [UUID: [UsageHistorySample]] = [
            a: [s(9000, 0.9), s(9200, 0.6)],   // last burn @9200
            b: [s(9600, 0.9), s(9800, 0.6)],   // last burn @9800 (newer)
        ]
        let r = run([acct(a, .claude, order: 0), acct(b, .claude, order: 1)], five: five)
        XCTAssertEqual(Array(r.keys), [b])
        XCTAssertEqual(r[b], ActiveUsage(lastUsedAt: Date(timeIntervalSince1970: 9800), source: .fiveHour))
    }

    func testPersistsWellBeyondTenMinutes() {
        // Burn 40 min ago (2400s) still marks the account (old detector's 600s window would drop it).
        let a = UUID()
        let five = [a: [s(7500, 0.9), s(7600, 0.6)]] // last burn @7600, age 2400s
        let r = run([acct(a, .claude, order: 0)], five: five)
        XCTAssertEqual(r[a]?.lastUsedAt, Date(timeIntervalSince1970: 7600))
    }

    func testBurnAcrossLargeGapIsRejected() {
        // prev@6000, cur@9900: Δts = 3900s > maxGap(900) → not a qualifying burn.
        let a = UUID()
        let five = [a: [s(6000, 0.9), s(9900, 0.5)]]
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testBurnWithinMaxGapQualifies() {
        // Δts = 900s → qualifies (well inside maxGap).
        let a = UUID()
        let five = [a: [s(9000, 0.9), s(9900, 0.6)]]
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt, Date(timeIntervalSince1970: 9900))
    }

    /// Low Power Mode polls every `lowPowerSeconds + jitter` (up to 960s).
    /// Two consecutive HEALTHY samples at that cadence must still yield a
    /// qualifying burn — a maxGap below the worst-case poll interval made
    /// IN USE mathematically impossible in Low Power Mode.
    func testLowPowerModeWorstCaseCadenceStillQualifies() {
        let a = UUID()
        let gap = TimeInterval(PollSchedule.lowPowerSeconds + PollSchedule.maxJitterSeconds) // 960s
        let five = [a: [s(9900 - gap, 0.9), s(9900, 0.6)]]
        XCTAssertEqual(
            run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
            Date(timeIntervalSince1970: 9900),
            "a burn observed at the slowest healthy poll cadence must count"
        )
    }

    /// Pins the cross-module relationship so a future cadence change cannot
    /// silently starve the detector again: the gap tolerance must cover the
    /// slowest healthy poll interval plus scheduling slop.
    func testMaxGapCoversWorstCaseHealthyPollInterval() {
        XCTAssertGreaterThanOrEqual(
            ActiveUsageDetector.maxGap,
            TimeInterval(PollSchedule.lowPowerSeconds + PollSchedule.maxJitterSeconds) + 120,
            "maxGap must exceed the slowest healthy poll interval (with slop) or IN USE starves in Low Power Mode"
        )
    }

    /// The upper bound survives: a gap far beyond any healthy cadence still
    /// reads as usage accumulated across sleep, not a live burn.
    func testGapBeyondMaxGapStillRejected() {
        let a = UUID()
        let five = [a: [s(9900 - ActiveUsageDetector.maxGap - 1, 0.9), s(9900, 0.5)]]
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testBurnOlderThanLookbackIgnored() {
        // The later (cur) burning sample must be strictly older than 5h to be
        // excluded: its age here is 18100s > lookback (18000s). Exactly 18000s
        // is still included (boundary is inclusive, matching InUsePhase).
        let a = UUID()
        let t0 = 10_000 - 18_200.0
        let five = [a: [s(t0, 0.9), s(t0 + 100, 0.6)]] // cur age = 18100 > 18000
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testBurnExactlyAtLookbackBoundaryIsIncluded() {
        // cur age == 18000 (== lookback) → still marked (inclusive boundary).
        let a = UUID()
        let t0 = 10_000 - 18_100.0
        let five = [a: [s(t0, 0.9), s(t0 + 100, 0.6)]] // cur age = 18000
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
                       Date(timeIntervalSince1970: t0 + 100))
    }

    func testCumulativeSubEpsilonIsNotActive() {
        let a = UUID()
        let five = [a: [s(9700, 0.5001), s(9800, 0.5)]] // 0.0001 burn < epsilon
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testBurnExactlyAtFloorBoundaryIsRejected() {
        // A half-quantum burn lands right at the floor (± FP noise) → rejected.
        // No real meter emits one (steps are whole percents); this pins the
        // strict `> epsilon + 1e-10` arithmetic at its boundary.
        let a = UUID()
        let five = [a: [s(9700, 0.505), s(9800, 0.50)]]
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testBurnJustAboveFloorBoundaryIsActive() {
        // 0.006 sits between the floor and one quantum → accepted.
        let a = UUID()
        let five = [a: [s(9700, 0.506), s(9800, 0.50)]]
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
                       Date(timeIntervalSince1970: 9800))
    }

    func testSingleOnePercentStepIsActive() {
        // Both meters move in whole-percent quanta, so a lone 1% step is the
        // smallest REAL burn — the floor must admit it (it only filters FP dust).
        let a = UUID()
        let five = [a: [s(9700, 0.51), s(9800, 0.50)]]
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
                       Date(timeIntervalSince1970: 9800))
    }

    func testSingleWeeklyStepMarksWeeklyOnlyAccountActive() {
        // Live regression (2026-08-18): ChatGPT weekly ticked 0.80 → 0.79 once
        // within the lookback and the account read as idle, because the floor
        // demanded strictly MORE than one quantum of cumulative burn.
        let a = UUID()
        let weekly = [a: [s(8700, 0.80), s(9700, 0.79)]]
        XCTAssertEqual(run([acct(a, .chatGPT, order: 0)], weekly: weekly)[a],
                       ActiveUsage(lastUsedAt: Date(timeIntervalSince1970: 9700), source: .weekly))
    }

    /// Pins the floor below one meter quantum: a single whole-percent step must
    /// clear `epsilon + 1e-10` under any FP representation of `x - (x - 0.01)`.
    func testNoiseFloorSitsBelowOneMeterQuantum() {
        XCTAssertLessThan(
            ActiveUsageDetector.epsilon + 1e-10, 0.0099,
            "floor at (or above) one quantum makes a single real step read as noise"
        )
    }

    func testBurnClearlyAboveEpsilonToleranceIsActive() {
        // 0.02 burn is clearly above the half-quantum floor → active.
        let a = UUID()
        let five = [a: [s(9700, 0.90), s(9800, 0.88)]]
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
                       Date(timeIntervalSince1970: 9800))
    }

    func testCumulativeMultiStepBurn() {
        // Consecutive small downward steps accumulate; lastUsedAt = latest burn.
        let a = UUID()
        let five = [a: [s(9600, 0.90), s(9700, 0.85), s(9800, 0.80)]] // 0.10 total
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
                       Date(timeIntervalSince1970: 9800))
    }

    func testBurnThenTinyUpwardCorrectionRetainsBurnTimestamp() {
        // A burn, then a tiny upward correction (remaining ticks back up): the
        // correction is not a burn, so lastUsedAt stays at the burn sample.
        let a = UUID()
        let five = [a: [s(9600, 0.90), s(9700, 0.60), s(9800, 0.61)]]
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.lastUsedAt,
                       Date(timeIntervalSince1970: 9700))
    }

    func testUpwardMovesDoNotCountAsBurn() {
        // remaining went UP (window reset) → not a burn.
        let a = UUID()
        let five = [a: [s(9500, 0.5), s(9800, 0.9)]]
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testFutureDatedSampleRejected() {
        let a = UUID()
        let five = [a: [s(9800, 0.9), s(10_500, 0.6)]] // cur@10500 > now(10000)
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five).isEmpty)
    }

    func testSeparateActivePerProvider() {
        let a = UUID(); let g = UUID()
        let five: [UUID: [UsageHistorySample]] = [
            a: [s(9500, 0.8), s(9800, 0.6)], // claude burns
        ]
        let weekly: [UUID: [UsageHistorySample]] = [
            g: [s(9500, 0.7), s(9800, 0.5)], // chatgpt burns (weekly-only)
        ]
        let r = run([acct(a, .claude, order: 0), acct(g, .chatGPT, order: 1)], five: five, weekly: weekly)
        XCTAssertEqual(Set(r.keys), [a, g]) // one active in EACH provider
        XCTAssertEqual(r[a]?.source, .fiveHour)
        XCTAssertEqual(r[g]?.source, .weekly)
    }

    func testTieBreakByBurnThenDisplayOrder() {
        let a = UUID(); let b = UUID()
        // identical lastUsedAt; b burns more → b wins.
        let five: [UUID: [UsageHistorySample]] = [
            a: [s(9700, 0.95), s(9800, 0.90)], // burn 0.05
            b: [s(9700, 0.95), s(9800, 0.80)], // burn 0.15
        ]
        let r = run([acct(a, .claude, order: 0), acct(b, .claude, order: 1)], five: five)
        XCTAssertEqual(Array(r.keys), [b])
    }

    func testTieBreakByDisplayOrderWhenBurnAndTimeEqual() {
        let a = UUID(); let b = UUID()
        // identical lastUsedAt and burn → lowest displayOrder (a, order 0) wins.
        let five: [UUID: [UsageHistorySample]] = [
            a: [s(9700, 0.9), s(9800, 0.7)],
            b: [s(9700, 0.9), s(9800, 0.7)],
        ]
        let r = run([acct(a, .claude, order: 0), acct(b, .claude, order: 1)], five: five)
        XCTAssertEqual(Array(r.keys), [a])
    }

    func testFiveHourIsAuthoritativeSingleSampleYieldsNoWeeklyFallback() {
        // Post-reset 5h has one sample → no delta; weekly present but must NOT be used.
        let a = UUID()
        let five = [a: [s(9900, 1.0)]]
        let weekly = [a: [s(9600, 0.9), s(9800, 0.6)]]
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: five, weekly: weekly).isEmpty)
    }

    func testWeeklyFallbackOnlyWhenNoFiveHourSeries() {
        // No 5h series at all (e.g. ChatGPT) → weekly is used, source == .weekly.
        let a = UUID()
        let weekly = [a: [s(9600, 0.9), s(9800, 0.6)]]
        let r = run([acct(a, .chatGPT, order: 0)], weekly: weekly)
        XCTAssertEqual(r[a], ActiveUsage(lastUsedAt: Date(timeIntervalSince1970: 9800), source: .weekly))
    }

    func testSingleAccountProviderStillMarked() {
        let a = UUID()
        let five = [a: [s(9600, 0.9), s(9800, 0.6)]]
        XCTAssertEqual(run([acct(a, .claude, order: 0)], five: five)[a]?.source, .fiveHour)
    }

    func testEmptyAndSingleSampleAccountsAreInactive() {
        let a = UUID()
        XCTAssertTrue(run([], five: [:]).isEmpty)
        XCTAssertTrue(run([acct(a, .claude, order: 0)], five: [a: [s(9700, 0.5)]]).isEmpty)
    }
}
