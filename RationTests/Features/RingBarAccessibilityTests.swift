import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// What VoiceOver gets from the ring bar. The accessibility tree had gauges
/// without a press action, values repeating the name, and two unnamed
/// "system dialog" windows.
@MainActor
final class RingBarAccessibilityTests: XCTestCase {
    private func gauge(_ label: String, provider: Provider = .chatGPT, fraction: Double = 0.3, inUse: Bool = true) -> GaugeEntry {
        GaugeEntry(id: UUID(), gauge: MenuBarGauge(provider: provider, label: label, fraction: fraction, windowKind: .weekly, inUse: inUse),
                   details: .credit)
    }

    /// The gauge's VoiceOver label is the whole sentence, said once, with no
    /// separate value repeating it ("ChatGPT 20x, ChatGPT ChatGPT 20x weekly…").
    /// SwiftUI builds its accessibility tree only for an assistive client, so
    /// the press action and the missing value are checked on the live tree.
    func testAGaugeSaysItsStateOnce() {
        let entry = gauge("ChatGPT 20x")
        XCTAssertEqual(RingBarText.accessibilityLabel(for: entry, displaysRemaining: true, locale: Locale(identifier: "en")),
                       "ChatGPT 20x weekly 30% left (in use)")
        XCTAssertEqual(RingBarText.accessibilityLabel(for: gauge("Client", provider: .claude, fraction: 0.73, inUse: false), displaysRemaining: true,
                                                      locale: Locale(identifier: "en")),
                       "Claude Client weekly 73% left")
    }

    func testTheBarWindowIsNamedAndTheGripIsHidden() {
        let bar = RingBarPanel()
        XCTAssertEqual(bar.accessibilityTitle(), SettingsSectionTitle.ringBar)
        XCTAssertEqual(bar.accessibilitySubrole(), .floatingWindow, "not a system dialog")
    }
}
