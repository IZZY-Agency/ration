import SwiftUI
import XCTest
@testable import Ration

@MainActor
final class InUseMarkerContentTests: XCTestCase {
    func testDefaultStyleIsFull() {
        let content = InUseMarkerContent(
            phase: .inUse(age: 10),
            date: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(content.style, .full)
    }

    func testWrapperForwardsStyleToContent() {
        // Guards SettingsSidebar's .pillOnly caller: dropping `style` would
        // render "last used · …" text where only a pill belongs. Exercises
        // `makeContent(at:)` — the same factory `body` calls — so a forwarding
        // regression (e.g. hardcoding `style: .full` inside it) actually fails
        // this test, rather than only asserting the struct's own
        // memberwise-initialized stored properties.
        // (The pill's color is no longer a parameter: it is always
        // `Theme.active`, the one activity green shared with the menu-bar dot
        // and the card frame — a knob here is how the surfaces drifted apart.)
        let marker = InUseMarker(activeUsage: nil, style: .pillOnly)
        let content = marker.makeContent(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(content.style, .pillOnly)
    }
}
