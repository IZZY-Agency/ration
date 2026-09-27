import XCTest
@testable import Ration

@MainActor
final class StatusItemFactoryAPITests: XCTestCase {
    private let en = Locale(identifier: "en")
    private func api(_ vendor: APIVendor, label: String, exact: String, lowerBound: Bool = false, remaining: Bool = false) -> MenuBarGauge {
        let percent = Decimal(string: exact)!
        let spent = NSDecimalNumber(decimal: percent / 100).doubleValue
        return MenuBarGauge(source: .api(vendor), label: label, fraction: remaining ? 1 - spent : spent, windowKind: nil, inUse: false,
                            budget: BudgetGaugeFacts(exactPercent: percent, isLowerBound: lowerBound))
    }

    func testUsedAndRemainingCopy() {
        let used = StatusItemFactory.toolTip(for: [api(.anthropic, label: "IZZY", exact: "78.2")], displaysRemaining: false, locale: en)
        XCTAssertTrue(used.contains("Anthropic API IZZY 78% of monthly budget spent"), used)
        let left = StatusItemFactory.toolTip(for: [api(.anthropic, label: "IZZY", exact: "78.2", remaining: true)], displaysRemaining: true, locale: en)
        XCTAssertTrue(left.contains("22% of monthly budget left"), left)
    }

    func testLowerBoundDirections() {
        let used = StatusItemFactory.toolTip(for: [api(.anthropic, label: "IZZY", exact: "78.6", lowerBound: true)], displaysRemaining: false, locale: en)
        XCTAssertTrue(used.contains("at least 78%"), used)          // floored
        let left = StatusItemFactory.toolTip(for: [api(.anthropic, label: "IZZY", exact: "78.6", lowerBound: true, remaining: true)], displaysRemaining: true, locale: en)
        XCTAssertTrue(left.contains("at most 22%"), left)           // ceil(21.4)
    }

    /// Two orgs with the same label stay apart by vendor.
    func testSameLabelDifferentVendors() {
        let tip = StatusItemFactory.toolTip(for: [api(.anthropic, label: "Work", exact: "10"), api(.openAI, label: "Work", exact: "20")], displaysRemaining: false, locale: en)
        XCTAssertTrue(tip.contains("Anthropic API Work"), tip)
        XCTAssertTrue(tip.contains("OpenAI API Work"), tip)
    }

    func testRoundedSquareDiffersFromRingPixels() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let ring = StatusItemFactory.gaugeImage(fraction: 0.5, color: .systemYellow, shape: .ring, appearance: appearance)
        let square = StatusItemFactory.gaugeImage(fraction: 0.5, color: .systemYellow, shape: .roundedSquare, appearance: appearance)
        XCTAssertNotEqual(ring.tiffRepresentation, square.tiffRepresentation)
        // A rounded square's corner area near the top-right is inked; a ring's is not.
        func alphaAtCorner(_ image: NSImage) -> CGFloat {
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let x = Int(Double(rep.pixelsWide) * 0.88), y = Int(Double(rep.pixelsHigh) * 0.12)
            return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }
        XCTAssertGreaterThan(alphaAtCorner(square), alphaAtCorner(ring) + 0.1)
    }
}
