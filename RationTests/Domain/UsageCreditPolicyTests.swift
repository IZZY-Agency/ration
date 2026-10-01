import XCTest
@testable import Ration

final class UsageCreditPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func euros(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "EUR", exponent: 2)! }

    private func grant(_ id: String, cents: Int64 = 1000, expiresIn: TimeInterval?) -> UsageCreditGrant {
        UsageCreditGrant(id: id, kind: .promotional, remaining: euros(cents), granted: euros(cents),
                         expiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }

    private func input(_ grants: [UsageCreditGrant], complete: Bool = true, switchOff: Bool = false, leadDays: Int = 1, at: Date? = nil) -> UsageCreditAlertInput {
        let credits = UsageCredits(fetchedAt: now.addingTimeInterval(-60), balance: euros(grants.reduce(0) { $0 + $1.remaining.minorUnits }), grants: grants, complete: complete)
        return UsageCreditAlertInput(credits: credits, switchOff: switchOff, leadDays: leadDays, now: at ?? now)
    }

    private func run(_ input: UsageCreditAlertInput, _ memory: inout [String: UsageCreditAlertMemory]) -> [AlertEvent] {
        var events: [AlertEvent] = []
        UsageCreditPolicy.evaluate(input, memory: &memory, events: &events)
        return events
    }

    // MARK: The window

    func testOutsideTheWindowIsSilentButRemembered() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        XCTAssertEqual(run(input([grant("a", expiresIn: 2 * day)]), &memory), [])
        XCTAssertEqual(memory["a"]?.expiryHandled, false)
        XCTAssertEqual(memory["a"]?.lastSeenExpiresAt, now.addingTimeInterval(2 * day))
    }

    func testEnteringTheWindowFiresOnce() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        let first = run(input([grant("a", expiresIn: day - 1)]), &memory)
        XCTAssertEqual(first, [.usageCreditExpiring(UsageCreditExpiry(
            grantID: "a", amount: euros(1000), expiresAt: now.addingTimeInterval(day - 1), switchOff: false, grantIDs: ["a"]
        ))])
        XCTAssertEqual(memory["a"]?.row, .active)
        XCTAssertEqual(run(input([grant("a", expiresIn: day - 1)]), &memory), [], "once per expiry")
    }

    func testWindowEdges() {
        XCTAssertTrue(UsageCreditPolicy.isWithinLeadWindow(grant("a", expiresIn: day), leadDays: 1, now: now), "the window opens exactly lead days before")
        XCTAssertFalse(UsageCreditPolicy.isWithinLeadWindow(grant("a", expiresIn: day + 1), leadDays: 1, now: now))
        XCTAssertFalse(UsageCreditPolicy.isWithinLeadWindow(grant("a", expiresIn: 0), leadDays: 1, now: now), "expired at its own instant")
        XCTAssertTrue(UsageCreditPolicy.isWithinLeadWindow(grant("a", expiresIn: 7 * day), leadDays: 7, now: now))
        XCTAssertFalse(UsageCreditPolicy.isWithinLeadWindow(grant("a", expiresIn: nil), leadDays: 7, now: now), "no expiry, no window")
    }

    func testLongerLeadTimeFiresEarlier() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        XCTAssertEqual(run(input([grant("a", expiresIn: 3 * day)], leadDays: 3), &memory).count, 1)
    }

    func testNeverExpiringOrSpentGrantsNeverFire() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        XCTAssertEqual(run(input([grant("forever", expiresIn: nil), grant("spent", cents: 0, expiresIn: 60)]), &memory), [])
    }

    func testTheSwitchStateTravelsWithTheEvent() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        guard case .usageCreditExpiring(let expiry)? = run(input([grant("a", expiresIn: 60)], switchOff: true), &memory).first else {
            return XCTFail("expected an expiry event")
        }
        XCTAssertTrue(expiry.switchOff)
    }

    // MARK: Several grants

    func testGrantsThatFireTogetherAreOneEvent() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        let events = run(input([grant("late", cents: 600, expiresIn: 20 * 3600), grant("soon", cents: 400, expiresIn: 2 * 3600)]), &memory)
        XCTAssertEqual(events, [.usageCreditExpiring(UsageCreditExpiry(
            grantID: "soon", amount: euros(1000), expiresAt: now.addingTimeInterval(2 * 3600), switchOff: false, grantIDs: ["late", "soon"]
        ))])
        XCTAssertEqual(memory["late"]?.row, .active)
        XCTAssertEqual(memory["soon"]?.row, .active)
    }

    func testAGrantEnteringLaterFiresOnItsOwn() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        let grants = [grant("soon", cents: 400, expiresIn: 2 * 3600), grant("later", cents: 600, expiresIn: 3 * day)]
        XCTAssertEqual(run(input(grants), &memory).count, 1)
        let twoDaysOn = now.addingTimeInterval(2 * day + 60)
        let events = run(input(grants, at: twoDaysOn), &memory)
        XCTAssertEqual(events.count, 1)
        guard case .usageCreditExpiring(let expiry)? = events.first else { return XCTFail() }
        XCTAssertEqual(expiry.grantIDs, ["later"])
        XCTAssertEqual(expiry.amount, euros(600))
    }

    // MARK: Changing expiries

    func testALaterExpiryReArms() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        XCTAssertEqual(run(input([grant("a", expiresIn: 3600)]), &memory).count, 1)
        // Extended by a month, then that new date comes near.
        let extended = grant("a", expiresIn: 30 * day)
        XCTAssertEqual(run(input([extended]), &memory), [], "re-armed but not yet inside the new window")
        XCTAssertEqual(memory["a"]?.expiryHandled, false)
        XCTAssertEqual(memory["a"]?.row, .inactive)
        XCTAssertEqual(run(input([extended], at: now.addingTimeInterval(29 * day + 60)), &memory).count, 1)
    }

    func testAnEarlierExpiryNeverUndoesAWarning() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        XCTAssertEqual(run(input([grant("a", expiresIn: 5 * 3600)]), &memory).count, 1)
        XCTAssertEqual(run(input([grant("a", expiresIn: 2 * 3600)]), &memory), [])
        XCTAssertEqual(memory["a"]?.expiryHandled, true)
    }

    // MARK: Memory pruning

    func testACompleteReadingPrunesGrantsThatAreGone() {
        var memory: [String: UsageCreditAlertMemory] = ["gone": UsageCreditAlertMemory(expiryHandled: true, row: .dismissed)]
        _ = run(input([grant("a", expiresIn: 2 * day)]), &memory)
        XCTAssertNil(memory["gone"])
    }

    func testAPartialReadingKeepsMemory() {
        var memory: [String: UsageCreditAlertMemory] = ["maybe": UsageCreditAlertMemory(expiryHandled: true, row: .dismissed)]
        _ = run(input([grant("a", expiresIn: 2 * day)], complete: false), &memory)
        XCTAssertNotNil(memory["maybe"], "a skipped grant may be this one")
    }

    // MARK: Freshness

    private func snapshot(readAt: Date, enabled: Bool? = false, readFor: String? = "org-1", snapshotOrg: String? = "org-1") -> UsageSnapshot {
        let credits = UsageCredits(fetchedAt: readAt, balance: euros(1000), grants: [grant("a", expiresIn: 60)], complete: true, organizationID: readFor)
        return UsageSnapshot(accountID: UUID(), fetchedAt: readAt.addingTimeInterval(-5), fiveHour: nil, weekly: nil,
                             organizationID: snapshotOrg, usageCredits: credits, usageCreditsEnabled: enabled)
    }

    /// Only a reading this session applied for the snapshot's organization.
    func testInputNeedsAReadingForThisOrganization() {
        XCTAssertNotNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now), leadDays: 1, now: now))
        XCTAssertNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now, readFor: nil), leadDays: 1, now: now), "restored from disk")
        XCTAssertNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now, readFor: "org-1", snapshotOrg: "org-2"), leadDays: 1, now: now))
        XCTAssertNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now, readFor: "org-1", snapshotOrg: nil), leadDays: 1, now: now))
    }

    /// Corrected to an earlier date and back: still one warning.
    func testAnExpiryCorrectedAndRestoredWarnsOnce() {
        var memory: [String: UsageCreditAlertMemory] = [:]
        XCTAssertEqual(run(input([grant("a", expiresIn: 5 * 3600)]), &memory).count, 1)
        XCTAssertEqual(run(input([grant("a", expiresIn: 2 * 3600)]), &memory), [])
        XCTAssertEqual(run(input([grant("a", expiresIn: 5 * 3600)]), &memory), [], "not an extension")
        XCTAssertEqual(memory["a"]?.lastSeenExpiresAt, now.addingTimeInterval(5 * 3600))
        XCTAssertEqual(run(input([grant("a", expiresIn: 30 * day)], at: now.addingTimeInterval(29 * day + 60)), &memory).count, 1, "a real extension still re-arms")
    }

    func testMoneySumIsCheckedOnce() {
        XCTAssertEqual(Money.sum([euros(400), euros(600)]), euros(1000))
        XCTAssertNil(Money.sum([]))
        XCTAssertNil(Money.sum([euros(1), Money(minorUnits: 1, currency: "USD", exponent: 2)!]))
        XCTAssertNil(Money.sum([euros(Int64.max), euros(1)]), "overflow is no total, not a smaller one")
    }

    func testInputNeedsACurrentReading() {
        XCTAssertNotNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now.addingTimeInterval(-UsageEvidence.maxAge)), leadDays: 1, now: now))
        XCTAssertNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now.addingTimeInterval(-UsageEvidence.maxAge - 1)), leadDays: 1, now: now), "too old")
        XCTAssertNotNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now.addingTimeInterval(UsageEvidence.allowedClockSkew)), leadDays: 1, now: now))
        XCTAssertNil(UsageCreditPolicy.input(snapshot: snapshot(readAt: now.addingTimeInterval(UsageEvidence.allowedClockSkew + 1)), leadDays: 1, now: now), "from the future")
        XCTAssertNil(UsageCreditPolicy.input(snapshot: nil, leadDays: 1, now: now))
        XCTAssertNil(UsageCreditPolicy.input(snapshot: UsageSnapshot(accountID: UUID(), fetchedAt: now, fiveHour: nil, weekly: nil), leadDays: 1, now: now))
    }

    func testInputCarriesTheSwitchOnlyWhenKnownOff() {
        XCTAssertEqual(UsageCreditPolicy.input(snapshot: snapshot(readAt: now, enabled: false), leadDays: 1, now: now)?.switchOff, true)
        XCTAssertEqual(UsageCreditPolicy.input(snapshot: snapshot(readAt: now, enabled: true), leadDays: 1, now: now)?.switchOff, false)
        XCTAssertEqual(UsageCreditPolicy.input(snapshot: snapshot(readAt: now, enabled: nil), leadDays: 1, now: now)?.switchOff, false)
    }

    // MARK: Persistence

    func testAlertStateRoundTripsWithDatesAndDropsOnlyAMalformedEntry() throws {
        var state = AccountAlertState()
        state.usageCredits = ["a": UsageCreditAlertMemory(expiryHandled: true, row: .dismissed, lastSeenExpiresAt: now)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AccountAlertState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded.usageCredits["a"]?.lastSeenExpiresAt, now, "dates survive with the store's strategy")

        let json = #"{"usageCredits":{"good":{"expiryHandled":true,"row":"active"},"bad":{"expiryHandled":"yes"},"odd":{"expiryHandled":false,"row":"inactive","lastSeenExpiresAt":7}}}"#
        let mixed = try decoder.decode(AccountAlertState.self, from: Data(json.utf8))
        XCTAssertEqual(mixed.usageCredits["good"], UsageCreditAlertMemory(expiryHandled: true, row: .active))
        XCTAssertNil(mixed.usageCredits["bad"])
        XCTAssertEqual(mixed.usageCredits["odd"], UsageCreditAlertMemory(expiryHandled: false, row: .inactive), "a bad date costs only the date")
        let legacy = try decoder.decode(AccountAlertState.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.usageCredits, [:])
    }
}
