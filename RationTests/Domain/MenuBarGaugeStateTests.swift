import Foundation
import XCTest
@testable import Ration

final class MenuBarGaugeStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private func makeAccount(_ provider: Provider, order: Int = 0, label: String? = nil) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: provider,
            label: label ?? "\(provider.rawValue)-\(order)",
            webProfileID: UUID(), displayOrder: order,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func freshUsage(source: UsageWindowKind = .fiveHour) -> ActiveUsage {
        ActiveUsage(lastUsedAt: now.addingTimeInterval(-60), source: source)
    }

    private func snapshot(
        for account: AccountRecord,
        fiveHour: Double? = nil,
        weekly: Double? = nil,
        modelWeekly: Double? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id,
            fetchedAt: now,
            fiveHour: fiveHour.map {
                UsageWindow(kind: .fiveHour, remainingFraction: $0, resetsAt: nil)
            },
            weekly: weekly.map {
                UsageWindow(kind: .weekly, remainingFraction: $0, resetsAt: nil)
            },
            modelWeekly: modelWeekly.map {
                UsageWindow(kind: .modelWeekly, remainingFraction: $0, resetsAt: nil)
            }
        )
    }

    private func gauges(
        accounts: [AccountRecord],
        activeUsage: [UUID: ActiveUsage] = [:],
        snapshots: [UUID: UsageSnapshot],
        windowKind: @escaping (Provider) -> UsageWindowKind = {
            AppSettingsData.defaultMenuBarWindow(for: $0)
        },
        displaysRemaining: Bool = false
    ) -> [MenuBarGauge] {
        MenuBarGaugeState.gauges(
            accounts: accounts,
            activeUsage: activeUsage,
            snapshots: { snapshots[$0] },
            windowKind: windowKind,
            displaysRemaining: displaysRemaining,
            now: now
        )
    }

    // MARK: Every account with a rate window earns a ring

    func testIdleAccountStillYieldsGaugeWithoutInUse() {
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            snapshots: [account.id: snapshot(for: account, fiveHour: 0.14)]
        )
        XCTAssertEqual(result, [
            MenuBarGauge(
                provider: .claude, label: account.label,
                fraction: 0.86, windowKind: .fiveHour, inUse: false
            )
        ])
    }

    func testAccountInBrightPhaseYieldsGaugeMarkedInUse() {
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            activeUsage: [account.id: freshUsage()],
            snapshots: [account.id: snapshot(for: account, fiveHour: 0.14)]
        )
        XCTAssertEqual(result, [
            MenuBarGauge(
                provider: .claude, label: account.label,
                fraction: 0.86, windowKind: .fiveHour, inUse: true
            )
        ])
    }

    func testLastUsedTailKeepsGaugeButDropsInUse() {
        // 20 minutes is past the fine bright threshold: the ring stays (it
        // shows usage now, not activity), only the in-use dot goes.
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            activeUsage: [account.id: ActiveUsage(
                lastUsedAt: now.addingTimeInterval(-1200), source: .fiveHour
            )],
            snapshots: [account.id: snapshot(for: account, fiveHour: 0.5)]
        )
        XCTAssertEqual(result.map(\.inUse), [false])
    }

    func testWeeklyOnlyAccountTwentyMinutesOldStillInUse() {
        // Weekly 1% steps land ~16–18 min apart under continuous use, so the
        // weekly bright window is 30 minutes — a 20-minute-old weekly burn
        // must keep the dot lit (the ChatGPT flicker fix, now on the dot).
        let account = makeAccount(.chatGPT)
        let result = gauges(
            accounts: [account],
            activeUsage: [account.id: ActiveUsage(
                lastUsedAt: now.addingTimeInterval(-1200), source: .weekly
            )],
            snapshots: [account.id: snapshot(for: account, weekly: 0.86)]
        )
        XCTAssertEqual(result, [
            MenuBarGauge(
                provider: .chatGPT, label: account.label,
                fraction: 0.14, windowKind: .weekly, inUse: true
            )
        ])
    }

    func testAllNonPausedAccountsOfAProviderYieldGaugesInAccountsOrder() {
        // Two visible Claude accounts → two rings, in the accounts order the
        // caller passed (the user's display order).
        let a = makeAccount(.claude, order: 0)
        let b = makeAccount(.claude, order: 1)
        // Binary-exact fractions (0.25/0.75, 0.5) so `1 - remaining` compares
        // equal without a tolerance.
        let result = gauges(
            accounts: [a, b],
            activeUsage: [b.id: freshUsage()],
            snapshots: [
                a.id: snapshot(for: a, fiveHour: 0.25),
                b.id: snapshot(for: b, fiveHour: 0.5)
            ]
        )
        XCTAssertEqual(result, [
            MenuBarGauge(provider: .claude, label: a.label,
                         fraction: 0.75, windowKind: .fiveHour, inUse: false),
            MenuBarGauge(provider: .claude, label: b.label,
                         fraction: 0.5, windowKind: .fiveHour, inUse: true)
        ])
    }

    func testGaugesGroupedCanonicallyRegardlessOfAccountOrder() {
        let chatgpt = makeAccount(.chatGPT, order: 0)
        let claude = makeAccount(.claude, order: 1)
        let result = gauges(
            accounts: [chatgpt, claude],
            snapshots: [
                chatgpt.id: snapshot(for: chatgpt, weekly: 0.5),
                claude.id: snapshot(for: claude, fiveHour: 0.5)
            ]
        )
        XCTAssertEqual(result.map(\.provider), [.claude, .chatGPT])
    }

    func testAccountsNotInListAreIgnored() {
        let visible = makeAccount(.claude)
        let hidden = makeAccount(.cursor)
        let result = gauges(
            accounts: [visible],
            activeUsage: [hidden.id: freshUsage()],
            snapshots: [hidden.id: snapshot(for: hidden, fiveHour: 0.5)]
        )
        XCTAssertEqual(result, [])
    }

    // MARK: Window selection, mode, and fallbacks

    func testSelectedWindowKindIsHonored() {
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            snapshots: [account.id: snapshot(
                for: account, fiveHour: 0.14, weekly: 0.09, modelWeekly: 0.51
            )],
            windowKind: { _ in .modelWeekly }
        )
        XCTAssertEqual(result.map(\.fraction), [0.49])
        XCTAssertEqual(result.map(\.windowKind), [.modelWeekly])
    }

    func testDisplaysRemainingFlipsTheFraction() {
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            snapshots: [account.id: snapshot(for: account, fiveHour: 0.14)],
            displaysRemaining: true
        )
        XCTAssertEqual(result.map(\.fraction), [0.14])
    }

    func testMissingSelectedWindowFallsBackToFinestAvailable() {
        // Fable selected, but this account has no modelWeekly window (not a
        // Max plan): fall back in fiveHour → weekly → modelWeekly order
        // rather than dropping the ring.
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            snapshots: [account.id: snapshot(for: account, fiveHour: 0.4, weekly: 0.2)],
            windowKind: { _ in .modelWeekly }
        )
        XCTAssertEqual(result.map(\.fraction), [0.6])
        XCTAssertEqual(result.map(\.windowKind), [.fiveHour])
    }

    func testNoSnapshotYieldsNoGauge() {
        let account = makeAccount(.claude)
        XCTAssertEqual(gauges(accounts: [account], snapshots: [:]), [])
    }

    func testSnapshotWithNoRateWindowsYieldsNoGauge() {
        // Cursor-shaped snapshot: spend only, no fraction windows.
        let account = makeAccount(.cursor)
        let result = gauges(
            accounts: [account],
            snapshots: [account.id: snapshot(for: account)]
        )
        XCTAssertEqual(result, [])
    }

    func testFractionIsClampedAgainstOutOfRangeRemaining() {
        let account = makeAccount(.claude)
        let result = gauges(
            accounts: [account],
            snapshots: [account.id: snapshot(for: account, fiveHour: 1.2)]
        )
        XCTAssertEqual(result.map(\.fraction), [0])
    }

    // MARK: TypeSafe

    private func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "USD", exponent: 2)! }

    /// A live reading: $26.58 left of $30.00 granted.
    private func typeSafeSnapshot(for account: AccountRecord, readAgo: TimeInterval = 60, freeExpiresIn: TimeInterval = 17 * 86_400) -> UsageSnapshot {
        let read = now.addingTimeInterval(-readAgo)
        let grants = [
            UsageCreditGrant(id: "free", kind: .free, remaining: usd(158), granted: usd(500), expiresAt: now.addingTimeInterval(freeExpiresIn)),
            UsageCreditGrant(id: "bought", kind: .purchased, remaining: usd(2500), granted: usd(2500), expiresAt: now.addingTimeInterval(364 * 86_400)),
        ]
        return UsageSnapshot(
            accountID: account.id, fetchedAt: read, fiveHour: nil, weekly: nil,
            usageCredits: UsageCredits(fetchedAt: read, balance: usd(2658), grants: grants, complete: true)
        )
    }

    func testTypeSafeGetsASquareForTheBalanceLeftOfTheCreditHeld() throws {
        let account = makeAccount(.typeSafe, label: "Lab")
        let left = try XCTUnwrap(gauges(accounts: [account], snapshots: [account.id: typeSafeSnapshot(for: account)], displaysRemaining: true).first)
        XCTAssertEqual(left.fraction, 0.886, accuracy: 0.0001)
        XCTAssertNil(left.windowKind)
        XCTAssertEqual(left.credit, CreditGaugeFacts(balance: usd(2658), granted: usd(3000)))
        XCTAssertEqual(left.source.gaugeShape, .roundedSquare, "an API account draws an API square")
        let used = try XCTUnwrap(gauges(accounts: [account], snapshots: [account.id: typeSafeSnapshot(for: account)]).first)
        XCTAssertEqual(used.fraction, 0.114, accuracy: 0.0001)
        XCTAssertEqual(Provider.claude.gaugeSource.gaugeShape, .ring)
    }

    /// An expired grant leaves the total; an old reading draws nothing.
    func testTypeSafeCountsOnlyUnexpiredGrantsAndCurrentReadings() throws {
        let account = makeAccount(.typeSafe)
        let expired = try XCTUnwrap(gauges(accounts: [account], snapshots: [account.id: typeSafeSnapshot(for: account, freeExpiresIn: -60)], displaysRemaining: true).first)
        XCTAssertEqual(expired.credit?.granted, usd(2500))
        XCTAssertEqual(expired.fraction, 1, "a balance above the grants' total reads full")
        XCTAssertTrue(gauges(accounts: [account], snapshots: [account.id: typeSafeSnapshot(for: account, readAgo: UsageEvidence.maxAge + 60)]).isEmpty)
    }

    func testTypeSafeWithoutGrantsDrawsNothing() {
        let account = makeAccount(.typeSafe)
        let snapshot = UsageSnapshot(
            accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
            usageCredits: UsageCredits(fetchedAt: now, balance: usd(500), grants: [], complete: true)
        )
        XCTAssertTrue(gauges(accounts: [account], snapshots: [account.id: snapshot]).isEmpty)
    }

    /// Spending a grant down never shrinks the whole: the
    /// free $5 spent to nothing still counts, so $10 of $30 is a third left,
    /// and everything spent is an empty square, not a missing one.
    func testASpentGrantStillCountsInTheWhole() throws {
        let account = makeAccount(.typeSafe)
        func reading(balance: Int64, grants: [UsageCreditGrant], spent: [UsageCreditGrant], complete: Bool = true) -> UsageSnapshot {
            UsageSnapshot(accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
                          usageCredits: UsageCredits(fetchedAt: now, balance: usd(balance), grants: grants, complete: complete, spentGrants: spent))
        }
        let free = UsageCreditGrant(id: "free", kind: .free, remaining: usd(0), granted: usd(500), expiresAt: now.addingTimeInterval(86_400))
        let bought = UsageCreditGrant(id: "bought", kind: .purchased, remaining: usd(1000), granted: usd(2500), expiresAt: nil)
        let third = try XCTUnwrap(gauges(accounts: [account], snapshots: [account.id: reading(balance: 1000, grants: [bought], spent: [free])], displaysRemaining: true).first)
        XCTAssertEqual(third.credit?.granted, usd(3000))
        XCTAssertEqual(third.fraction, 1.0 / 3.0, accuracy: 0.0001)
        let empty = try XCTUnwrap(gauges(accounts: [account], snapshots: [account.id: reading(balance: 0, grants: [], spent: [free])], displaysRemaining: true).first)
        XCTAssertEqual(empty.fraction, 0)
    }

    /// A guess would draw a falsely full square: a grant with no original
    /// amount, or a list missing a grant, draws nothing.
    func testAnUnknownWholeDrawsNothing() {
        let account = makeAccount(.typeSafe)
        let unknown = UsageCreditGrant(id: "gift", kind: .promotional, remaining: usd(300), granted: nil, expiresAt: nil)
        let bought = UsageCreditGrant(id: "bought", kind: .purchased, remaining: usd(2500), granted: usd(2500), expiresAt: nil)
        let noAmount = UsageSnapshot(accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
                                     usageCredits: UsageCredits(fetchedAt: now, balance: usd(2800), grants: [unknown, bought], complete: true))
        XCTAssertTrue(gauges(accounts: [account], snapshots: [account.id: noAmount]).isEmpty)
        let partial = UsageSnapshot(accountID: account.id, fetchedAt: now, fiveHour: nil, weekly: nil,
                                    usageCredits: UsageCredits(fetchedAt: now, balance: usd(2800), grants: [bought], complete: false))
        XCTAssertTrue(gauges(accounts: [account], snapshots: [account.id: partial]).isEmpty)
    }

    /// Without a saved order: subscriptions, then API orgs, then TypeSafe —
    /// the popover's order.
    func testTypeSafeComesAfterTheAPIOrgs() {
        let typeSafe = makeAccount(.typeSafe, order: 0, label: "Lab"), claude = makeAccount(.claude, order: 1, label: "AI")
        let accountGauges = gauges(
            accounts: [typeSafe, claude],
            snapshots: [typeSafe.id: typeSafeSnapshot(for: typeSafe), claude.id: snapshot(for: claude, fiveHour: 0.5)]
        )
        let org = MenuBarGauge(source: .api(.openAI), label: "Platform", fraction: 0, windowKind: nil, inUse: false)
        XCTAssertEqual(MenuBarGaugeState.grouped(accountGauges, apiOrgs: [org]).map(\.label), ["AI", "Platform", "Lab"])
    }
}

private extension Provider {
    var gaugeSource: DisplaySource { .subscription(self) }
}
