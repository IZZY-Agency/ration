import XCTest
@testable import Ration

final class InUsePhaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)
    private func at(_ agoSeconds: TimeInterval) -> Date { now.addingTimeInterval(-agoSeconds) }

    func testNilIsNone() {
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: nil, source: .fiveHour, now: now), .none)
    }

    func testFiveHourWithinThresholdIsInUse() {
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: at(120), source: .fiveHour, now: now), .inUse(age: 120))
    }

    func testInUseUpperBoundaryInclusive() {
        // exactly 900s → still IN USE (half-open: 0...900)
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: at(900), source: .fiveHour, now: now), .inUse(age: 900))
    }

    func testJustOverThresholdIsLastUsed() {
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: at(901), source: .fiveHour, now: now), .lastUsed(age: 901))
    }

    func testLookbackUpperBoundaryIsLastUsed() {
        // exactly 5h → last-used (age <= 18000)
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: at(18_000), source: .fiveHour, now: now), .lastUsed(age: 18_000))
    }

    func testBeyondLookbackIsNone() {
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: at(18_001), source: .fiveHour, now: now), .none)
    }

    func testFutureDatedIsNone() {
        XCTAssertEqual(InUsePhase.classify(lastUsedAt: now.addingTimeInterval(60), source: .fiveHour, now: now), .none)
    }

    func testWeeklySourcedUsageClassifiesAsInUseWhenFresh() {
        // A weekly source means the account reports NO finer window at all
        // (the detector prefers 5h whenever any 5h series exists), so weekly
        // is that account's live signal — a fresh weekly burn IS "in use now".
        // Demoting it (pre-0.25.0 behavior) made weekly-only providers like
        // ChatGPT permanently unable to show the IN USE pill or menu bar ring.
        let usage = ActiveUsage(lastUsedAt: at(120), source: .weekly)
        XCTAssertEqual(InUsePhase.classify(usage, now: now), .inUse(age: 120))
    }

    func testWeeklySourceGetsWiderBrightWindow() {
        // Weekly percent moves in 1% steps that land ~16–18 minutes apart even
        // under CONTINUOUS use (live-measured on ChatGPT), so a 15-minute
        // bright phase guarantees the ring flickers off between steps. Weekly
        // gets a 30-minute window; the boundary is inclusive like the fine one.
        let atTwentyMinutes = ActiveUsage(lastUsedAt: at(1200), source: .weekly)
        XCTAssertEqual(InUsePhase.classify(atTwentyMinutes, now: now), .inUse(age: 1200))

        let atBoundary = ActiveUsage(lastUsedAt: at(1800), source: .weekly)
        XCTAssertEqual(InUsePhase.classify(atBoundary, now: now), .inUse(age: 1800))

        let pastBoundary = ActiveUsage(lastUsedAt: at(1801), source: .weekly)
        XCTAssertEqual(InUsePhase.classify(pastBoundary, now: now), .lastUsed(age: 1801))
    }

    func testFineSourceKeepsTightBrightWindow() {
        // The wider window is weekly-only: a 5h-sourced mark at 20 minutes is
        // still merely "last used".
        let usage = ActiveUsage(lastUsedAt: at(1200), source: .fiveHour)
        XCTAssertEqual(InUsePhase.classify(usage, now: now), .lastUsed(age: 1200))
    }

    func testConvenienceOverloadForwardsUsage() {
        let usage = ActiveUsage(lastUsedAt: at(1000), source: .fiveHour)
        XCTAssertEqual(InUsePhase.classify(usage, now: now), .lastUsed(age: 1000))
        XCTAssertEqual(InUsePhase.classify(nil, now: now), .none)
    }
}
