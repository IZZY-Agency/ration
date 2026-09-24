import XCTest
@testable import Ration

final class AccountRecordTests: XCTestCase {
    func testAccountRecordRoundTripsWithoutAuthenticationMaterial() throws {
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let account = AccountRecord(
            id: accountID,
            provider: .claude,
            label: "Work",
            webProfileID: profileID,
            displayOrder: 1,
            createdAt: createdAt
        )

        let encoded = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: encoded)

        XCTAssertEqual(decoded, account)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("token"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("cookie"))
    }

    func testProvidersHaveStableStorageIdentifiers() {
        XCTAssertEqual(Provider.claude.rawValue, "claude")
        XCTAssertEqual(Provider.chatGPT.rawValue, "chatgpt")
        XCTAssertEqual(Provider.cursor.rawValue, "cursor")
    }

    func testCursorProviderIdentity() {
        XCTAssertEqual(Provider.cursor.displayName, "Cursor")
        XCTAssertEqual(Provider.cursor.webOrigin, "https://cursor.com")
        XCTAssertTrue(Provider.allCases.contains(.cursor))
    }

    func testCursorMatchesOnlyItsOwnAppHost() {
        XCTAssertTrue(Provider.cursor.matchesAppHost("cursor.com"))
        XCTAssertTrue(Provider.cursor.matchesAppHost("www.cursor.com"))
        XCTAssertTrue(Provider.cursor.matchesAppHost("CURSOR.COM"))
        XCTAssertFalse(Provider.cursor.matchesAppHost("cursor.sh"))
        XCTAssertFalse(Provider.cursor.matchesAppHost("api2.cursor.sh"))
        XCTAssertFalse(Provider.cursor.matchesAppHost("notcursor.com"))
        XCTAssertFalse(Provider.cursor.matchesAppHost(nil))
        // Cross-provider isolation: existing providers must not claim cursor.com.
        XCTAssertFalse(Provider.claude.matchesAppHost("cursor.com"))
        XCTAssertFalse(Provider.chatGPT.matchesAppHost("cursor.com"))
    }

    func testDecodesBillingRenewalDayWhenPresent() throws {
        let account = AccountRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            provider: .claude,
            label: "Work",
            webProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            billingRenewalDay: 14
        )
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.billingRenewalDay, 14)
        XCTAssertEqual(decoded, account)
    }

    func testDefaultsBillingRenewalDayToNilForLegacyJSON() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","provider":"claude","label":"Work",\
        "webProfileID":"00000000-0000-0000-0000-000000000002","displayOrder":0,\
        "createdAt":1000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: legacy)
        XCTAssertNil(decoded.billingRenewalDay)
    }

    func testDecodesIsPausedWhenPresent() throws {
        let account = AccountRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            provider: .claude,
            label: "Work",
            webProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            isPaused: true
        )
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: JSONEncoder().encode(account))
        XCTAssertTrue(decoded.isPaused)
        XCTAssertEqual(decoded, account)
    }

    func testDefaultsIsPausedToFalseForLegacyJSON() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","provider":"claude","label":"Work",\
        "webProfileID":"00000000-0000-0000-0000-000000000002","displayOrder":0,\
        "createdAt":1000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: legacy)
        XCTAssertFalse(decoded.isPaused)
    }

    func testHistoryLabelMarksPausedAccounts() {
        let base = AccountRecord(
            id: UUID(), provider: .claude, label: "Work",
            webProfileID: UUID(), displayOrder: 0, createdAt: .distantPast
        )
        XCTAssertEqual(base.historyLabel, "Work")
        var paused = base
        paused.isPaused = true
        XCTAssertEqual(paused.historyLabel, "Work — PAUSED")
    }

    func testPlanRoundTrips() throws {
        let account = AccountRecord(
            id: UUID(), provider: .chatGPT, label: "20x", webProfileID: UUID(),
            displayOrder: 0, createdAt: Date(timeIntervalSince1970: 1_000),
            plan: .chatGPTPro20x, planSource: .user
        )
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.plan, .chatGPTPro20x)
        XCTAssertEqual(decoded.planSource, .user)
        XCTAssertEqual(decoded, account)
    }

    func testLegacyJSONHasNoPlan() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","provider":"claude","label":"Work",\
        "webProfileID":"00000000-0000-0000-0000-000000000002","displayOrder":0,\
        "createdAt":1000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: legacy)
        XCTAssertNil(decoded.plan)
        XCTAssertNil(decoded.planSource)
    }

    func testUnknownPlanValueDecodesLeniently() throws {
        let future = """
        {"id":"00000000-0000-0000-0000-000000000001","provider":"claude","label":"Work",\
        "webProfileID":"00000000-0000-0000-0000-000000000002","displayOrder":0,\
        "createdAt":1000,"plan":"claudeMax100x","planSource":"oracle"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: future)
        XCTAssertNil(decoded.plan)
        XCTAssertNil(decoded.planSource)
        XCTAssertEqual(decoded.label, "Work")
    }
}
