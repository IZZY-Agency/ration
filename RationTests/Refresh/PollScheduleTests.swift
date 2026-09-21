import XCTest
@testable import Ration

final class PollScheduleTests: XCTestCase {
    func testNormalCadenceWithoutJitter() {
        XCTAssertEqual(
            PollSchedule.interval(lowPowerMode: false, jitterSeconds: 0),
            .seconds(PollSchedule.baseSeconds)
        )
    }

    func testLowPowerLengthensCadence() {
        XCTAssertEqual(
            PollSchedule.interval(lowPowerMode: true, jitterSeconds: 0),
            .seconds(PollSchedule.lowPowerSeconds)
        )
        XCTAssertGreaterThan(PollSchedule.lowPowerSeconds, PollSchedule.baseSeconds)
    }

    func testJitterIsAddedAndClamped() {
        XCTAssertEqual(
            PollSchedule.interval(lowPowerMode: false, jitterSeconds: 45),
            .seconds(PollSchedule.baseSeconds + 45)
        )
        // Never shorten below base (a bad random source), never exceed the cap.
        XCTAssertEqual(
            PollSchedule.interval(lowPowerMode: false, jitterSeconds: -100),
            .seconds(PollSchedule.baseSeconds)
        )
        XCTAssertEqual(
            PollSchedule.interval(lowPowerMode: false, jitterSeconds: 10_000),
            .seconds(PollSchedule.baseSeconds + PollSchedule.maxJitterSeconds)
        )
    }
}
