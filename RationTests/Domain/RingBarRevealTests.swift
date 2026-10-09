import XCTest
@testable import Ration

/// Hide at edge: push against the edge to reveal (with a short dwell so a
/// fly-by does nothing), stay shown through the corridor and the hover card,
/// hide a moment after leaving.
final class RingBarRevealTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testAlwaysShownWhenHideIsOff() {
        var reveal = RingBarReveal(hidesAtEdge: false)
        XCTAssertTrue(reveal.isVisible)
        XCTAssertFalse(reveal.step(inActivation: false, inKeepZone: false, cardShown: false, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(reveal.isVisible)
    }

    func testRevealNeedsDwellAtTheEdge() {
        var reveal = RingBarReveal(hidesAtEdge: true)
        XCTAssertFalse(reveal.isVisible)
        reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0)
        XCTAssertFalse(reveal.isVisible)
        XCTAssertTrue(reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0.addingTimeInterval(0.16)))
        XCTAssertTrue(reveal.isVisible)
    }

    func testFlyByDoesNotReveal() {
        var reveal = RingBarReveal(hidesAtEdge: true)
        reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0)
        reveal.step(inActivation: false, inKeepZone: false, cardShown: false, now: t0.addingTimeInterval(0.05))
        reveal.step(inActivation: false, inKeepZone: false, cardShown: false, now: t0.addingTimeInterval(0.3))
        XCTAssertFalse(reveal.isVisible)
    }

    func testCorridorAndCardKeepItShownThenItHidesAfterDelay() {
        var reveal = RingBarReveal(hidesAtEdge: true)
        reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0)
        reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0.addingTimeInterval(0.2))
        reveal.step(inActivation: false, inKeepZone: true, cardShown: false, now: t0.addingTimeInterval(2))
        XCTAssertTrue(reveal.isVisible)
        reveal.step(inActivation: false, inKeepZone: false, cardShown: true, now: t0.addingTimeInterval(3))
        XCTAssertTrue(reveal.isVisible)
        reveal.step(inActivation: false, inKeepZone: false, cardShown: false, now: t0.addingTimeInterval(4))
        XCTAssertTrue(reveal.isVisible, "hiding, still visible during the delay")
        reveal.step(inActivation: false, inKeepZone: true, cardShown: false, now: t0.addingTimeInterval(4.3))
        XCTAssertEqual(reveal.phase, .shown, "coming back cancels the hide")
        reveal.step(inActivation: false, inKeepZone: false, cardShown: false, now: t0.addingTimeInterval(5))
        XCTAssertTrue(reveal.step(inActivation: false, inKeepZone: false, cardShown: false, now: t0.addingTimeInterval(5.61)))
        XCTAssertFalse(reveal.isVisible)
    }

    func testHideNowForWake() {
        var reveal = RingBarReveal(hidesAtEdge: true)
        reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0)
        reveal.step(inActivation: true, inKeepZone: true, cardShown: false, now: t0.addingTimeInterval(1))
        XCTAssertTrue(reveal.isVisible)
        reveal.hideNow()
        XCTAssertFalse(reveal.isVisible)
        var off = RingBarReveal(hidesAtEdge: false)
        off.hideNow()
        XCTAssertTrue(off.isVisible, "hideNow never hides a bar that does not hide at the edge")
    }
}
