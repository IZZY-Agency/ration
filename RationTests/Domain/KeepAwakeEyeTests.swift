import XCTest
@testable import Ration

/// `KeepAwakeEye`: what the status item and the ring bar show for Keep awake —
/// nothing while the switch is off, an outline eye at rest, a filled eye
/// while a hold is live.
final class KeepAwakeEyeTests: XCTestCase {
    private let until = Date(timeIntervalSince1970: 1_791_733_200)

    func testTheSwitchOffHidesTheEyeWhateverTheHold() {
        XCTAssertEqual(KeepAwakeEye.forBars(enabled: false, status: .off), .hidden)
        XCTAssertEqual(KeepAwakeEye.forBars(enabled: false, status: .automatic), .hidden)
        XCTAssertEqual(KeepAwakeEye.forBars(enabled: false, status: .manual(until: nil)), .hidden)
    }

    func testTheSwitchOnShowsAnIdleEyeWithoutAHoldAndAHeldOneWithIt() {
        XCTAssertEqual(KeepAwakeEye.forBars(enabled: true, status: .off), .idle)
        XCTAssertEqual(KeepAwakeEye.forBars(enabled: true, status: .automatic), .held(.automatic))
        XCTAssertEqual(KeepAwakeEye.forBars(enabled: true, status: .manual(until: until)), .held(.manual(until: until)))
    }

    func testTheStatusBehindTheEye() {
        XCTAssertEqual(KeepAwakeEye.hidden.status, .off)
        XCTAssertEqual(KeepAwakeEye.idle.status, .off)
        XCTAssertEqual(KeepAwakeEye.held(.manual(until: until)).status, .manual(until: until))
        XCTAssertFalse(KeepAwakeEye.hidden.isShown)
        XCTAssertTrue(KeepAwakeEye.idle.isShown)
        XCTAssertTrue(KeepAwakeEye.held(.automatic).isShown)
    }
}
