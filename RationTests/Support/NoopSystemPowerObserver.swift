import Foundation
@testable import Ration

/// Inert `SystemPowerObserving` for tests that don't exercise it. Keeps the live
/// `SystemPowerObserver` (registered by `AppModel.load()`) from installing real
/// `NSWorkspace` sleep observers and memory-pressure sources, which would leak
/// across the suite and could fire a spurious WebView release mid-test.
@MainActor
final class NoopSystemPowerObserver: SystemPowerObserving {
    var onShouldReleaseIdleResources: (@MainActor () -> Void)?
    var onPowerSourceChanged: (@MainActor () -> Void)?
    var isLowPowerModeEnabled = false
    var powerSource: PowerSource = .external
    func start() {}
    func stop() {}

    /// Simulate the adapter being plugged or pulled (after setting `powerSource`).
    func firePowerSourceChanged() { onPowerSourceChanged?() }
}
