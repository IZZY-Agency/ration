import XCTest
@testable import Ration

@MainActor
final class AccountPinSnapshotTests: XCTestCase {
    private func account(_ provider: Provider, _ order: Int) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: provider, label: "L\(order)",
            webProfileID: UUID(), displayOrder: order,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
    private func usage(_ at: TimeInterval) -> ActiveUsage {
        ActiveUsage(lastUsedAt: Date(timeIntervalSince1970: at), source: .fiveHour)
    }

    func testRefreshCapturesActiveAccountPerProvider() {
        let claude = account(.claude, 0)
        let gpt = account(.chatGPT, 1)
        let snapshot = AccountPinSnapshot()

        snapshot.refresh(
            from: [claude.id: usage(100), gpt.id: usage(200)],
            accounts: [claude, gpt]
        )

        XCTAssertEqual(snapshot.orderingPinByProvider[.claude], claude.id)
        XCTAssertEqual(snapshot.orderingPinByProvider[.chatGPT], gpt.id)
        XCTAssertNil(snapshot.orderingPinByProvider[.cursor])
    }

    func testRefreshClearsProviderThatLostItsActiveAccount() {
        let claude = account(.claude, 0)
        let snapshot = AccountPinSnapshot()
        snapshot.refresh(from: [claude.id: usage(100)], accounts: [claude])
        XCTAssertEqual(snapshot.orderingPinByProvider[.claude], claude.id)

        snapshot.refresh(from: [:], accounts: [claude])
        XCTAssertNil(snapshot.orderingPinByProvider[.claude])
    }

    func testRefreshIgnoresActiveIDsWithNoMatchingAccount() {
        let claude = account(.claude, 0)
        let snapshot = AccountPinSnapshot()
        snapshot.refresh(from: [UUID(): usage(100)], accounts: [claude])
        XCTAssertTrue(snapshot.orderingPinByProvider.isEmpty)
    }

    func testShouldCaptureOnNewWindowAndOnHiddenToVisible() {
        XCTAssertTrue(AccountPinSnapshot.shouldCapture(isNewWindow: true, isVisible: false))
        XCTAssertTrue(AccountPinSnapshot.shouldCapture(isNewWindow: false, isVisible: false))
    }

    func testShouldNotCaptureWhenAlreadyVisible() {
        // A plain re-focus of a visible window must not move cards.
        XCTAssertFalse(AccountPinSnapshot.shouldCapture(isNewWindow: false, isVisible: true))
    }
}
