import XCTest
@testable import Ration

final class ResetCreditTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func credit(_ id: String, expiresIn: TimeInterval, count: Int = 1) -> ResetCredit {
        ResetCredit(id: id, title: "Launch reset", count: count, expiresAt: t0.addingTimeInterval(expiresIn), usableNow: true)
    }

    func testUnexpiredHidesItemsAtOrPastExpiry() {
        let list = ResetCredits(fetchedAt: t0, items: [credit("a", expiresIn: 60), credit("b", expiresIn: 0), credit("c", expiresIn: -1)], complete: true)
        XCTAssertEqual(list.unexpired(at: t0).map(\.id), ["a"])
    }

    func testSnapshotRoundTripsResetCredits() throws {
        let list = ResetCredits(fetchedAt: t0, items: [credit("a", expiresIn: 60)], complete: false)
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, resetCredits: list)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(back.resetCredits, list)
    }

    func testLegacySnapshotWithoutKeyDecodesNil() throws {
        let json = #"{"accountID":"123E4567-E89B-12D3-A456-426614174000","fetchedAt":0}"#
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.resetCredits)
    }

    func testMalformedResetCreditsDecodesNilWithoutFailingSnapshot() throws {
        let json = #"{"accountID":"123E4567-E89B-12D3-A456-426614174000","fetchedAt":0,"resetCredits":{"items":"nope"}}"#
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.resetCredits)
    }

    func testReplacingResetCreditsKeepsEverythingElse() {
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, organizationID: "org")
        let list = ResetCredits(fetchedAt: t0, items: [], complete: true)
        let replaced = snap.replacingResetCredits(list)
        XCTAssertEqual(replaced.resetCredits, list)
        XCTAssertEqual(replaced.organizationID, "org")
        XCTAssertEqual(replaced.fetchedAt, t0)
    }
}
