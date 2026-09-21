import XCTest
@testable import Ration

final class AlertThresholdsTests: XCTestCase {
    func testDefaultIs75And90() {
        XCTAssertEqual(ThresholdPair.default.warningPercent, 75)
        XCTAssertEqual(ThresholdPair.default.criticalPercent, 90)
    }

    func testCriticalClampsToTwoThroughOneHundred() {
        XCTAssertEqual(ThresholdPair(warningPercent: 1, criticalPercent: 0).criticalPercent, 2)
        XCTAssertEqual(ThresholdPair(warningPercent: 1, criticalPercent: 500).criticalPercent, 100)
    }

    // The first design draft used `warning = critical - 1` floored at 1, which
    // yields warning == critical when critical == 1. Critical's floor of 2 is
    // what keeps the ladder strictly ordered.
    func testCriticalOfOneStillLeavesStrictlyOrderedPair() {
        let pair = ThresholdPair(warningPercent: 90, criticalPercent: 1)
        XCTAssertEqual(pair.criticalPercent, 2)
        XCTAssertEqual(pair.warningPercent, 1)
        XCTAssertLessThan(pair.warningPercent, pair.criticalPercent)
    }

    func testWarningClampsBelowCritical() {
        let pair = ThresholdPair(warningPercent: 95, criticalPercent: 80)
        XCTAssertEqual(pair.warningPercent, 79)
        XCTAssertEqual(pair.criticalPercent, 80)
    }

    func testFractionsConvertFromPercent() {
        let pair = ThresholdPair(warningPercent: 60, criticalPercent: 85)
        XCTAssertEqual(pair.warningFraction, 0.60, accuracy: 1e-9)
        XCTAssertEqual(pair.criticalFraction, 0.85, accuracy: 1e-9)
    }

    func testDecodeCanonicalisesOutOfRangeStoredValues() throws {
        let json = Data(#"{"warningPercent":200,"criticalPercent":-5}"#.utf8)
        let pair = try JSONDecoder().decode(ThresholdPair.self, from: json)
        XCTAssertEqual(pair.criticalPercent, 2)
        XCTAssertEqual(pair.warningPercent, 1)
    }

    func testSpendThresholdsDropNonPositiveValues() {
        let spend = SpendThresholds(warningCents: 0, criticalCents: -100)
        XCTAssertNil(spend.warningCents)
        XCTAssertNil(spend.criticalCents)
    }

    func testSpendThresholdsDropWarningWhenNotBelowCritical() {
        let spend = SpendThresholds(warningCents: 8_000, criticalCents: 5_000)
        XCTAssertNil(spend.warningCents)
        XCTAssertEqual(spend.criticalCents, 5_000)
    }

    func testSpendThresholdsKeepOrderedPair() {
        let spend = SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        XCTAssertEqual(spend.warningCents, 5_000)
        XCTAssertEqual(spend.criticalCents, 8_000)
    }

    func testSpendThresholdsDecodeCanonicalises() throws {
        let json = Data(#"{"warningCents":9000,"criticalCents":1000}"#.utf8)
        let spend = try JSONDecoder().decode(SpendThresholds.self, from: json)
        XCTAssertNil(spend.warningCents)
        XCTAssertEqual(spend.criticalCents, 1_000)
    }

    // `SpendThresholds` yields the warning when it is not STRICTLY below
    // critical — the equality case is the boundary that a `>=` → `>` mutation
    // would silently pass.
    func testSpendThresholdsDropWarningWhenEqualToCritical() {
        let spend = SpendThresholds(warningCents: 5_000, criticalCents: 5_000)
        XCTAssertNil(spend.warningCents)
        XCTAssertEqual(spend.criticalCents, 5_000)
    }

    func testDefaultChannelsAreNotificationOnly() {
        XCTAssertTrue(AlertChannels.notificationOnly.notification)
        XCTAssertFalse(AlertChannels.notificationOnly.drop)
    }

    func testChannelsRoundTripAsTokens() throws {
        let channels = AlertChannels(notification: false, drop: true)
        let data = try JSONEncoder().encode(channels)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["drop"]"#)
        XCTAssertEqual(try JSONDecoder().decode(AlertChannels.self, from: data), channels)
    }

    // A future third channel must be additive, not fatal, for older builds.
    func testUnknownChannelTokenIsIgnoredNotFatal() throws {
        let json = Data(#"["notification","carrierPigeon"]"#.utf8)
        let channels = try JSONDecoder().decode(AlertChannels.self, from: json)
        XCTAssertTrue(channels.notification)
        XCTAssertFalse(channels.drop)
    }

    // MARK: - Default delivery channels

    /// The drop is ON by default. A menu-bar panel nobody has switched on is a
    /// feature nobody sees — and the panel is dismissible, self-retracting and
    /// never steals focus, so the cost of it appearing uninvited is low.
    func testDefaultChannelsIncludeBothNotificationAndDrop() {
        XCTAssertTrue(AlertChannels.default.notification)
        XCTAssertTrue(AlertChannels.default.drop)
    }

    /// An unconfigured cell resolves to that default rather than to
    /// notification-only.
    func testUnconfiguredCellResolvesToTheDefaultChannels() {
        let data = AppSettingsData()
        let key = AppSettingsData.thresholdKey(provider: .claude, window: .weekly)
        XCTAssertEqual(data.channels(forKey: key), .default)
    }

    /// `notificationOnly` still exists and still means what it says — it is
    /// what an explicit opt-out of the drop persists as.
    func testNotificationOnlyExcludesTheDrop() {
        XCTAssertTrue(AlertChannels.notificationOnly.notification)
        XCTAssertFalse(AlertChannels.notificationOnly.drop)
    }

    // MARK: - Which events belong to a channel cell

    /// Threshold crossings are what the per-cell channels govern.
    func testThresholdEventsMapToTheirProviderAndWindowCell() {
        XCTAssertEqual(
            AlertChannelKey.forEvent(
                .threshold(kind: .weekly, tier: .critical, percent: 90),
                provider: .claude
            ),
            AppSettingsData.thresholdKey(provider: .claude, window: .weekly)
        )
        XCTAssertEqual(
            AlertChannelKey.forEvent(
                .spendThreshold(tier: .warning, thresholdCents: 5_000, spentCents: 6_000),
                provider: .cursor
            ),
            AppSettingsData.cursorSpendKey
        )
    }

    /// Everything else has NO cell and is therefore never suppressed by one.
    /// Silencing one window's notifications must not silence "sign in again",
    /// "you are being rate-limited", or a reset.
    func testNonThresholdEventsHaveNoChannelCell() {
        XCTAssertNil(AlertChannelKey.forEvent(.reauthRequired, provider: .claude))
        XCTAssertNil(AlertChannelKey.forEvent(.rateLimited, provider: .claude))
        XCTAssertNil(AlertChannelKey.forEvent(.reset(kind: .weekly), provider: .claude))
    }
}
