import XCTest
@testable import Ration

/// The pure low-balance policy and what it persists.
final class LowBalancePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "USD", exponent: 2)! }

    private func run(_ balance: Money?, _ threshold: Int?, _ memory: inout LowBalanceAlertMemory) -> [AlertEvent] {
        var events: [AlertEvent] = []
        LowBalancePolicy.evaluate(balance: balance, thresholdCents: threshold, memory: &memory, events: &events)
        return events
    }

    func testFiresOnceWhileBelow() {
        var memory = LowBalanceAlertMemory()
        XCTAssertEqual(run(usd(412), 500, &memory), [.lowBalance(LowBalanceAlert(balance: usd(412), thresholdCents: 500))])
        XCTAssertEqual(memory, LowBalanceAlertMemory(notified: true, row: .active))
        XCTAssertEqual(run(usd(100), 500, &memory), [], "still below: already told")
    }

    func testATopUpReArms() {
        var memory = LowBalanceAlertMemory(notified: true, row: .dismissed)
        XCTAssertEqual(run(usd(500), 500, &memory), [], "exactly on the threshold is not below it")
        XCTAssertEqual(memory, LowBalanceAlertMemory(), "re-armed, row cleared")
        XCTAssertEqual(run(usd(499), 500, &memory).count, 1)
    }

    func testTurningItOffReArmsAndNoEvidenceLeavesMemoryAlone() {
        var memory = LowBalanceAlertMemory(notified: true, row: .active)
        XCTAssertEqual(run(nil, 500, &memory), [])
        XCTAssertEqual(memory, LowBalanceAlertMemory(notified: true, row: .active), "no current reading: untouched")
        XCTAssertEqual(run(usd(1), nil, &memory), [])
        XCTAssertEqual(memory, LowBalanceAlertMemory(), "off: re-armed for when it is turned back on")
    }

    /// Already told the balance is low: editing the threshold while it stays
    /// below never repeats the alert.
    func testEditingTheThresholdWhileBelowDoesNotRepeat() {
        var memory = LowBalanceAlertMemory()
        XCTAssertEqual(run(usd(300), 500, &memory).count, 1)
        XCTAssertEqual(run(usd(300), 2_000, &memory), [])
        XCTAssertEqual(run(usd(300), 400, &memory), [])
    }

    func testOnlyAVerifiedCurrentReadingInCentsCounts() {
        func snapshot(readAgo: TimeInterval = 10, readThisSession: Bool = true, exponent: Int = 2) -> UsageSnapshot {
            let at = now.addingTimeInterval(-readAgo)
            let balance = Money(minorUnits: 300, currency: "USD", exponent: exponent)!
            return UsageSnapshot(
                accountID: UUID(), fetchedAt: at, fiveHour: nil, weekly: nil,
                usageCredits: UsageCredits(fetchedAt: at, balance: balance, grants: [], complete: true, readThisSession: readThisSession)
            )
        }
        XCTAssertEqual(LowBalancePolicy.currentBalance(snapshot: snapshot(), now: now), usd(300))
        XCTAssertNil(LowBalancePolicy.currentBalance(snapshot: snapshot(readThisSession: false), now: now), "restored from disk")
        XCTAssertNil(LowBalancePolicy.currentBalance(snapshot: snapshot(readAgo: UsageEvidence.maxAge + 1), now: now), "too old")
        XCTAssertNil(LowBalancePolicy.currentBalance(snapshot: snapshot(exponent: 3), now: now), "not in cents")
        XCTAssertNil(LowBalancePolicy.currentBalance(snapshot: nil, now: now))
    }

    func testAlertPolicyLeavesMemoryAloneWithoutAnInput() {
        var previous = AccountAlertState()
        previous.lowBalance = LowBalanceAlertMemory(notified: true, row: .active)
        let (events, next) = AlertPolicy.evaluate(
            previous: previous, snapshot: nil, state: .current,
            thresholds: { _ in .default }, spendThresholds: .off, lowBalance: nil
        )
        XCTAssertEqual(events, [])
        XCTAssertEqual(next.lowBalance, previous.lowBalance, "priming passes nil")
    }

    // MARK: Persistence

    func testMemoryDecodesLeniently() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(AccountAlertState.self, from: Data(#"{"notifiedReauth":true}"#.utf8))
        XCTAssertEqual(legacy.lowBalance, LowBalanceAlertMemory(), "files before 1.10 have no key")
        let wrong = try decoder.decode(AccountAlertState.self, from: Data(#"{"lowBalance":{"notified":"yes","row":"active"}}"#.utf8))
        XCTAssertEqual(wrong.lowBalance, LowBalanceAlertMemory(notified: false, row: .active), "a wrong-typed field costs only itself")
        let garbage = try decoder.decode(AccountAlertState.self, from: Data(#"{"lowBalance":[1],"notifiedReauth":true}"#.utf8))
        XCTAssertEqual(garbage.lowBalance, LowBalanceAlertMemory())
        XCTAssertTrue(garbage.notifiedReauth, "and never the rest of the account's memory")

        var state = AccountAlertState()
        state.lowBalance = LowBalanceAlertMemory(notified: true, row: .dismissed)
        XCTAssertEqual(try decoder.decode(AccountAlertState.self, from: JSONEncoder().encode(state)), state)
    }

    func testTheThresholdSettingIsOptInAndLenient() throws {
        let data = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"lowBalanceCents":{"typesafe":500,"claude":"x","cursor":0}}"#.utf8))
        XCTAssertEqual(data.lowBalanceCents(provider: .typeSafe), 500)
        XCTAssertNil(data.lowBalanceCents(provider: .cursor), "non-positive is off")
        XCTAssertNil(data.lowBalanceCents(provider: .claude), "a malformed entry drops alone")
        XCTAssertNil(AppSettingsData().lowBalanceCents(provider: .typeSafe), "off by default")
        XCTAssertEqual(AppSettingsData.lowBalanceKey(provider: .typeSafe), "typesafe.lowBalance")
    }

    @MainActor
    func testTheSetterStoresAndClears() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await settings.setLowBalanceCents(750, provider: .typeSafe)
        XCTAssertEqual(settings.data.lowBalanceCents(provider: .typeSafe), 750)
        try await settings.setLowBalanceCents(0, provider: .typeSafe)
        XCTAssertEqual(settings.lowBalanceCents, [:], "zero turns it off and leaves no entry")
        try await settings.setLowBalanceCents(750, provider: .typeSafe)
        try await settings.setLowBalanceCents(nil, provider: .typeSafe)
        XCTAssertEqual(settings.lowBalanceCents, [:])
    }

    // MARK: Event plumbing

    func testChannelKeyAndNotificationID() {
        let event = AlertEvent.lowBalance(LowBalanceAlert(balance: usd(412), thresholdCents: 500))
        XCTAssertEqual(AlertChannelKey.forEvent(event, provider: .typeSafe), "typesafe.lowBalance")
        let id = UUID()
        XCTAssertEqual(AlertMessage.id(for: event, accountID: id), "\(id.uuidString).lowBalance")
    }
}
