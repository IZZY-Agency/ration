import SwiftUI
import XCTest
@testable import Ration

final class AccountStateBadgeTests: XCTestCase {
    func testTintMapping() {
        XCTAssertEqual(AccountStateBadge.tint(for: .current), Theme.calm)
        XCTAssertEqual(AccountStateBadge.tint(for: .reauthenticationRequired), Theme.gold)
        XCTAssertEqual(AccountStateBadge.tint(for: .stale(lastError: .offline)), Theme.warn)
        XCTAssertEqual(AccountStateBadge.tint(for: .rateLimited(retryAt: nil)), Theme.warn)
        XCTAssertEqual(AccountStateBadge.tint(for: .integrationChanged), Theme.crit)
        XCTAssertEqual(AccountStateBadge.tint(for: .unavailable), Theme.creamFaint)
        XCTAssertEqual(AccountStateBadge.tint(for: .loading), Theme.creamFaint)
    }
}
