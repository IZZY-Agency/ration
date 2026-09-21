import Foundation

/// What the quiet-hours schedule actually suppresses right now.
///
/// Quiet hours began as a warm-up-only gate, so the Warm-up pane told the user
/// they had "no effect yet" whenever no account had auto-start enabled. 0.28.0
/// made them alert-wide — `AttentionDropModel.rows` returns nothing inside a
/// quiet cell — and that message became false for anyone using the drop but not
/// warm-ups.
///
/// Derived rather than stored, for the same reason the drop itself is: a
/// channel checkbox or the master switch changes what quiet hours govern, and
/// nothing should have to remember to invalidate a cached answer.
struct QuietHoursScope: Equatable {
    /// Warm-ups are governed only if some account can actually start one.
    let suppressesWarmUp: Bool
    /// The drop is governed if the master switch is on and any cell delivers
    /// to it.
    let suppressesDrop: Bool

    /// The only case in which the schedule is genuinely inert.
    var governsNothing: Bool { !suppressesWarmUp && !suppressesDrop }

    /// `channelKeys` is every cell that can exist rather than only the ones the
    /// user has edited — an untouched cell falls back to `AlertChannels.default`,
    /// which includes the drop, so an install nobody has configured is still
    /// governed.
    static func current(
        settings: AppSettingsData,
        autoStartEnabledCount: Int,
        channelKeys: [String]
    ) -> QuietHoursScope {
        QuietHoursScope(
            suppressesWarmUp: autoStartEnabledCount > 0,
            suppressesDrop: settings.usageAlertsEnabled
                && channelKeys.contains { settings.channels(forKey: $0).drop }
        )
    }
}
