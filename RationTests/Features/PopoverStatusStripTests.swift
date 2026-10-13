import XCTest
@testable import Ration

/// The one status strip under the popover header: the keep-awake notice and
/// the snoozed-drop notice, each only when it applies.
final class PopoverStatusStripTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let utc = TimeZone(identifier: "UTC")!

    private func strip(_ keepAwake: KeepAwakeStatus, snoozed: Bool = false, showing: Bool = false) -> PopoverStatusStrip? {
        PopoverStatusStrip.make(keepAwake: keepAwake, dropSnoozed: snoozed, dropShowing: showing, locale: en, timeZone: utc)
    }

    func testNothingToSayIsNoStrip() {
        XCTAssertNil(strip(.off))
    }

    func testKeepAwakeAlone() {
        XCTAssertEqual(strip(.automatic)?.items,
                       [.keepAwake(text: "Mac kept awake while an account is in use", isOverride: false)])
        XCTAssertEqual(strip(.manual(until: nil))?.items,
                       [.keepAwake(text: "Mac kept awake until you turn it off", isOverride: true)])
    }

    func testSnoozedDropAlone() {
        XCTAssertEqual(strip(.off, snoozed: true)?.items, [.dropSnoozed])
    }

    /// While the drop is on screen there is nothing hidden to show.
    func testDropOnScreenIsNotSaidToBeHidden() {
        XCTAssertNil(strip(.off, snoozed: true, showing: true))
        XCTAssertEqual(strip(.automatic, snoozed: true, showing: true)?.items.count, 1)
    }

    /// Both: one strip, keep-awake first (as the two banners stood).
    func testBothShareOneStrip() {
        XCTAssertEqual(
            strip(.automatic, snoozed: true)?.items,
            [.keepAwake(text: "Mac kept awake while an account is in use", isOverride: false), .dropSnoozed]
        )
    }

    /// The glyph matches the footer's eye: filled while a hold is live.
    func testKeepAwakeGlyph() {
        XCTAssertEqual(PopoverStatusStrip.Item.keepAwake(text: "", isOverride: false).symbol, "eye.fill")
        XCTAssertEqual(PopoverStatusStrip.Item.dropSnoozed.symbol, "bell.badge.slash")
    }
}
