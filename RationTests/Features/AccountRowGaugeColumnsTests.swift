import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The gauges share an expanded row's width: a lone weekly gauge (ChatGPT
/// tiers without a 5 hour window) runs the full width, 5h and weekly split
/// it in half, and Claude's three (Fable · 5h · weekly) in thirds.
///
/// Each column's countdown is drawn flush right in its column, so where it
/// ends is where the column ends. Read from the accessibility tree, which
/// SwiftUI builds only for an assistive client (see `AccountRowFoldingTests`).
@MainActor
final class AccountRowGaugeColumnsTests: XCTestCase {
    private let now = Date()
    private var resetsAt: Date { now.addingTimeInterval(3 * 86_400) }

    /// The row's content, inside the card's inset on both sides.
    private var contentWidth: CGFloat { MenuBarView.popoverWidth - 2 * AccountListMetrics.cardInset }
    /// The gap between two gauge columns.
    private let gap: CGFloat = 16

    /// Where column `index` of `count` ends, in the row's coordinates.
    private func columnEnd(_ index: Int, of count: Int) -> CGFloat {
        let column = (contentWidth - gap * CGFloat(count - 1)) / CGFloat(count)
        return AccountListMetrics.cardInset + CGFloat(index + 1) * column + CGFloat(index) * gap
    }

    private func presentation(_ provider: Provider, fiveHour: Bool, fable: Bool = false) -> AccountPresentation {
        let id = UUID()
        let record = AccountRecord(id: id, provider: provider, label: "Client", webProfileID: UUID(), displayOrder: 0,
                                   createdAt: now, plan: provider == .claude ? .claudeMax20x : .chatGPTPro20x,
                                   planSource: .detected)
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: now.addingTimeInterval(-60),
            fiveHour: fiveHour ? UsageWindow(kind: .fiveHour, remainingFraction: 0.8, resetsAt: now.addingTimeInterval(2 * 3600)) : nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.61, resetsAt: resetsAt),
            modelWeekly: fable ? UsageWindow(kind: .modelWeekly, remainingFraction: 0.5, resetsAt: resetsAt, label: "Fable") : nil
        )
        return AccountPresentation(account: record, snapshot: snapshot, state: .current)
    }

    /// Where each countdown ends, by window, in the row's coordinates.
    private func countdownEnds(_ presentation: AccountPresentation) -> [UsageWindowKind: CGFloat] {
        let row = AccountCardView(presentation: presentation, onReauthenticate: {}, now: now)
        let host = NSHostingView(rootView: row.frame(width: MenuBarView.popoverWidth).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(origin: .zero, size: NSSize(width: MenuBarView.popoverWidth, height: host.fittingSize.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: enhanced.rawValue)?
            .takeUnretainedValue() as? Bool ?? false
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: enhanced.rawValue)
        defer {
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: previous), with: enhanced.rawValue)
            window.contentView = nil
            window.close()
        }
        var ends: [UsageWindowKind: CGFloat] = [:]
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, let node = object as? NSObject else { return }
            if node.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let identifier = node.value(forKey: "accessibilityIdentifier") as? String,
               identifier.hasPrefix("resetCountdown."),
               let kind = UsageWindowKind(rawValue: String(identifier.dropFirst("resetCountdown.".count))),
               let screen = (node as? NSAccessibilityElementProtocol)?.accessibilityFrame(), !screen.isEmpty {
                ends[kind] = window.convertFromScreen(screen).maxX
            }
            let children: [Any] = node.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? (node.value(forKey: "accessibilityChildren") as? [Any] ?? []) : []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return ends
    }

    /// The reported row: a ChatGPT tier with only the weekly limit. Its
    /// gauge used to sit in the first of three columns.
    func testALoneWeeklyGaugeRunsTheFullWidth() throws {
        let ends = countdownEnds(presentation(.chatGPT, fiveHour: false))
        XCTAssertEqual(Set(ends.keys), [.weekly])
        XCTAssertEqual(try XCTUnwrap(ends[.weekly]), columnEnd(0, of: 1), accuracy: 1)
    }

    func testFiveHourAndWeeklySplitTheRowInHalf() throws {
        let ends = countdownEnds(presentation(.chatGPT, fiveHour: true))
        XCTAssertEqual(try XCTUnwrap(ends[.fiveHour]), columnEnd(0, of: 2), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(ends[.weekly]), columnEnd(1, of: 2), accuracy: 1)
    }

    /// Claude without the Fable limit: the same two windows, the same halves.
    func testClaudeWithoutFableSplitsTheRowInHalf() throws {
        let ends = countdownEnds(presentation(.claude, fiveHour: true))
        XCTAssertEqual(try XCTUnwrap(ends[.fiveHour]), columnEnd(0, of: 2), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(ends[.weekly]), columnEnd(1, of: 2), accuracy: 1)
    }

    func testClaudesThreeGaugesTakeAThirdEach() throws {
        let ends = countdownEnds(presentation(.claude, fiveHour: true, fable: true))
        XCTAssertEqual(try XCTUnwrap(ends[.modelWeekly]), columnEnd(0, of: 3), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(ends[.fiveHour]), columnEnd(1, of: 3), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(ends[.weekly]), columnEnd(2, of: 3), accuracy: 1)
    }
}
