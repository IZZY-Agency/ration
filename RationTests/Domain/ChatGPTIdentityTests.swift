import XCTest
@testable import Ration

/// Who a ChatGPT web session is rides the snapshot IN MEMORY ONLY, like
/// `organizationID`: it links a remembered Codex login to a card and must
/// never reach `snapshots.json`.
final class ChatGPTIdentityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let identity = ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "a@b", planType: "pro")

    private func euros(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "EUR", exponent: 2)! }

    /// Every field set, so a rebuild that drops one shows.
    private func full(identity: ChatGPTIdentity?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            fetchedAt: t0,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: t0),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: t0),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.3, resetsAt: t0, label: "Fable"),
            cursorSpend: CursorSpend(spentCents: 120, periodStart: t0, resetsAt: t0.addingTimeInterval(86_400), planLabel: "Pro"),
            organizationID: "org-1",
            resetCredits: ResetCredits(fetchedAt: t0, items: [ResetCredit(id: "r", title: nil, count: 1, expiresAt: t0.addingTimeInterval(9_000), usableNow: true)], complete: true),
            planDetection: .tier(.chatGPTPro5x),
            usageCredits: UsageCredits(fetchedAt: t0, balance: euros(1000), grants: [], complete: true),
            usageCreditsEnabled: true,
            codexCredits: CodexCredits(fetchedAt: t0, balance: 120, unlimited: false),
            typeSafeSpend: TypeSafeSpend(fetchedAt: t0, cycleSpent: euros(300), cycleLabel: "October 2026", resetsAt: t0, autoRecharge: false),
            typeSafeDailyUsage: TypeSafeDailyUsage(fetchedAt: t0, days: [TypeSafeDay(day: t0, inputTokens: 1, outputTokens: 2, requests: 3)]),
            chatGPTIdentity: identity
        )
    }

    func testASnapshotKeepsItsIdentity() {
        let snapshot = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, chatGPTIdentity: identity)
        XCTAssertEqual(snapshot.chatGPTIdentity, identity)
        XCTAssertNil(UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil).chatGPTIdentity, "nil by default")
    }

    func testTheIdentityIsNeverEncoded() throws {
        let snapshot = full(identity: identity)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["chatGPTIdentity"], "no chatGPTIdentity key")
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for value in ["acct-A", "user-1", "a@b"] {
            XCTAssertFalse(json.contains(value), "\(value) must not be encoded")
        }

        let decoded = try decoder.decode(UsageSnapshot.self, from: data)
        XCTAssertNil(decoded.chatGPTIdentity)
        XCTAssertEqual(decoded.codexCredits, snapshot.codexCredits, "the rest survives")
        XCTAssertEqual(decoded.weekly, snapshot.weekly)

        // The decode side holds on its own: a smuggled key is ignored.
        let smuggled = """
        {"accountID":"\(snapshot.accountID.uuidString)","fetchedAt":"2026-09-21T14:13:20Z",
         "chatGPTIdentity":{"accountID":"acct-A","userID":"user-1","email":"a@b","planType":"pro"}}
        """
        XCTAssertNil(try decoder.decode(UsageSnapshot.self, from: Data(smuggled.utf8)).chatGPTIdentity)
    }

    func testReplacingTheIdentityKeepsEveryOtherField() {
        let original = full(identity: identity)
        let cleared = original.replacingChatGPTIdentity(nil)
        XCTAssertNil(cleared.chatGPTIdentity)
        XCTAssertNotEqual(cleared, original)
        XCTAssertEqual(cleared.replacingChatGPTIdentity(identity), original, "only the identity changed")

        let other = ChatGPTIdentity(accountID: "acct-A", userID: "user-2", email: nil, planType: nil)
        XCTAssertEqual(original.replacingChatGPTIdentity(other).chatGPTIdentity, other)
        XCTAssertEqual(original.replacingChatGPTIdentity(other).replacingChatGPTIdentity(identity), original)
    }

    /// The store's carry-forward goes through these on the NEW snapshot:
    /// none may drop that snapshot's identity.
    func testEveryOtherReplacingHelperKeepsTheIdentity() {
        let snapshot = full(identity: identity)
        XCTAssertEqual(snapshot.replacingResetCredits(nil).chatGPTIdentity, identity)
        XCTAssertEqual(snapshot.replacingUsageCredits(nil).chatGPTIdentity, identity)
        XCTAssertEqual(snapshot.replacingUsageCreditsEnabled(nil).chatGPTIdentity, identity)
        XCTAssertEqual(snapshot.replacingTypeSafeSpend(nil).chatGPTIdentity, identity)
        XCTAssertEqual(snapshot.replacingCodexCredits(nil).chatGPTIdentity, identity)
        XCTAssertEqual(snapshot.replacingTypeSafeDailyUsage(nil).chatGPTIdentity, identity)
    }
}

/// The window kinds a fetch saw reported but could not read ride
/// the snapshot IN MEMORY ONLY, like the identity.
final class UnreadableWindowKindsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(_ kinds: Set<UsageWindowKind> = [.fiveHour]) -> UsageSnapshot {
        UsageSnapshot(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, fetchedAt: t0, fiveHour: nil,
                      weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: t0),
                      codexCredits: CodexCredits(fetchedAt: t0, balance: 1, unlimited: false),
                      chatGPTIdentity: ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: nil, planType: nil),
                      unreadableWindowKinds: kinds)
    }

    func testNoneByDefault() {
        XCTAssertEqual(UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil).unreadableWindowKinds, [])
        XCTAssertEqual(snapshot().unreadableWindowKinds, [.fiveHour])
    }

    func testNeverEncoded() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["unreadableWindowKinds"])
        XCTAssertEqual(try decoder.decode(UsageSnapshot.self, from: data).unreadableWindowKinds, [])
    }

    /// The store's carry-forward goes through these on the NEW snapshot.
    func testEveryReplacingHelperKeepsThem() {
        let original = snapshot()
        XCTAssertEqual(original.replacingResetCredits(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertEqual(original.replacingUsageCredits(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertEqual(original.replacingUsageCreditsEnabled(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertEqual(original.replacingTypeSafeSpend(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertEqual(original.replacingCodexCredits(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertEqual(original.replacingTypeSafeDailyUsage(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertEqual(original.replacingChatGPTIdentity(nil).unreadableWindowKinds, [.fiveHour])
        XCTAssertNotEqual(original, snapshot([]), "part of equality")
    }
}
