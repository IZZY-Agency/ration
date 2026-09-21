import XCTest
@testable import Ration

final class AccountVisibilityTests: XCTestCase {
    private func record(paused: Bool) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: .claude, label: paused ? "Paused" : "Active",
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast,
            isPaused: paused
        )
    }

    func testDropsPausedRecordsKeepsOrder() {
        let active1 = record(paused: false)
        let paused = record(paused: true)
        let active2 = record(paused: false)
        XCTAssertEqual(
            AccountVisibility.visible([active1, paused, active2]).map(\.id),
            [active1.id, active2.id]
        )
    }

    func testDropsPausedPresentations() {
        let active = record(paused: false)
        let paused = record(paused: true)
        let presentations = [
            AccountPresentation(account: active, snapshot: nil, state: .unavailable),
            AccountPresentation(account: paused, snapshot: nil, state: .unavailable),
        ]
        XCTAssertEqual(
            AccountVisibility.visible(presentations).map(\.account.id),
            [active.id]
        )
    }
}
