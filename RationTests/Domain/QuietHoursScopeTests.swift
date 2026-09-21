import XCTest
@testable import Ration

/// Quiet hours were warm-up-only until 0.28.0, when `AttentionDropModel` began
/// honouring them too. The Warm-up pane still told the user they had "no effect
/// yet" whenever no account had auto-start enabled — false for a drop user, and
/// exactly the claim these tests exist to keep honest.
final class QuietHoursScopeTests: XCTestCase {
    private let claudeWeekly = AppSettingsData.thresholdKey(provider: .claude, window: .weekly)

    private func settings(
        alertsEnabled: Bool = true,
        channels: [String: AlertChannels] = [:]
    ) -> AppSettingsData {
        var data = AppSettingsData()
        data.usageAlertsEnabled = alertsEnabled
        data.alertChannels = channels
        return data
    }

    private func scope(
        settings: AppSettingsData,
        autoStartEnabledCount: Int,
        keys: [String]? = nil
    ) -> QuietHoursScope {
        QuietHoursScope.current(
            settings: settings,
            autoStartEnabledCount: autoStartEnabledCount,
            channelKeys: keys ?? [claudeWeekly]
        )
    }

    // MARK: - Warm-up

    func testAutoStartAccountsPutWarmUpUnderQuietHours() {
        let scope = scope(settings: settings(alertsEnabled: false), autoStartEnabledCount: 1)
        XCTAssertTrue(scope.suppressesWarmUp)
        XCTAssertFalse(scope.governsNothing)
    }

    func testNoAutoStartAccountLeavesWarmUpUngoverned() {
        XCTAssertFalse(
            scope(settings: settings(alertsEnabled: false), autoStartEnabledCount: 0).suppressesWarmUp
        )
    }

    // MARK: - The drop

    /// THE REGRESSION: no auto-start account, but the drop is on — quiet hours
    /// are doing something, so the pane must not claim otherwise.
    func testDropAloneIsEnoughToGovern() {
        let data = settings(channels: [claudeWeekly: AlertChannels(notification: false, drop: true)])
        let scope = scope(settings: data, autoStartEnabledCount: 0)
        XCTAssertTrue(scope.suppressesDrop)
        XCTAssertFalse(
            scope.governsNothing,
            "quiet hours suppress the drop, so they are not inert"
        )
    }

    /// A cell with no stored channels falls back to `AlertChannels.default`,
    /// which delivers to the drop — so an untouched install is governed.
    func testUnconfiguredChannelsStillCountAsDrop() {
        XCTAssertTrue(
            scope(settings: settings(), autoStartEnabledCount: 0).suppressesDrop,
            "the default channel set includes the drop"
        )
    }

    func testMasterSwitchOffLeavesTheDropUngoverned() {
        let data = settings(
            alertsEnabled: false,
            channels: [claudeWeekly: AlertChannels(notification: true, drop: true)]
        )
        XCTAssertFalse(scope(settings: data, autoStartEnabledCount: 0).suppressesDrop)
    }

    func testEveryDropChannelOffLeavesTheDropUngoverned() {
        let cursor = AppSettingsData.cursorSpendKey
        let data = settings(channels: [
            claudeWeekly: AlertChannels(notification: true, drop: false),
            cursor: AlertChannels(notification: true, drop: false),
        ])
        XCTAssertFalse(
            scope(settings: data, autoStartEnabledCount: 0, keys: [claudeWeekly, cursor])
                .suppressesDrop
        )
    }

    /// One cell is enough — the drop is a single panel fed by every cell.
    func testASingleDropCellGoverns() {
        let cursor = AppSettingsData.cursorSpendKey
        let data = settings(channels: [
            claudeWeekly: AlertChannels(notification: true, drop: false),
            cursor: AlertChannels(notification: true, drop: true),
        ])
        XCTAssertTrue(
            scope(settings: data, autoStartEnabledCount: 0, keys: [claudeWeekly, cursor])
                .suppressesDrop
        )
    }

    // MARK: - Nothing at all

    func testNeitherSurfaceGovernedIsTheOnlyInertCase() {
        let data = settings(
            alertsEnabled: false,
            channels: [claudeWeekly: AlertChannels(notification: true, drop: true)]
        )
        XCTAssertTrue(scope(settings: data, autoStartEnabledCount: 0).governsNothing)
    }

    // MARK: - The key list the pane actually passes

    /// The pane asks about every cell that can exist, so a provider the user
    /// has not connected cannot make quiet hours look inert.
    func testAllChannelKeysCoverEveryCellPlusCursor() {
        let keys = AlertsGridModel.allChannelKeys
        XCTAssertTrue(keys.contains(claudeWeekly))
        XCTAssertTrue(keys.contains(AppSettingsData.cursorSpendKey))
        XCTAssertTrue(
            keys.contains(AppSettingsData.thresholdKey(provider: .chatGPT, window: .fiveHour))
        )
        XCTAssertEqual(Set(keys).count, keys.count, "no duplicate keys")
    }
}
