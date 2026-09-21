import XCTest
@testable import Ration

@MainActor
final class MenuBarPausedTests: XCTestCase {
    private func record(paused: Bool, label: String) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: .claude, label: label,
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast,
            isPaused: paused
        )
    }

    func testPopoverInputsExcludePausedEverywhere() {
        let active = record(paused: false, label: "Active")
        let paused = record(paused: true, label: "Paused")
        let visible = AccountVisibility.visible([active, paused])

        // The exact list MenuBarContent hands to ActiveUsageMap and MenuBarView.
        XCTAssertEqual(visible.map(\.id), [active.id])

        // The empty-state addendum count: total minus visible.
        let allPaused = [record(paused: true, label: "A"), record(paused: true, label: "B")]
        XCTAssertTrue(AccountVisibility.visible(allPaused).isEmpty)
        XCTAssertEqual(allPaused.count - AccountVisibility.visible(allPaused).count, 2)
    }
}
