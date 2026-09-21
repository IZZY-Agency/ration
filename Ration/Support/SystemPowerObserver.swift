import AppKit
import Foundation

/// Seam over the system power / memory signals the app reacts to. Injected
/// so tests can drive sleep, memory-pressure, and Low Power deterministically,
/// mirroring `NotificationScheduling` and `WebProfileManaging`.
@MainActor
protocol SystemPowerObserving: AnyObject {
    /// Invoked when the system is about to sleep or is under memory pressure —
    /// the owner should release WebViews that aren't backing in-flight work.
    var onShouldReleaseIdleResources: (@MainActor () -> Void)? { get set }
    /// Whether the Mac is in Low Power Mode (phase 3 — relaxes poll cadence).
    var isLowPowerModeEnabled: Bool { get }
    func start()
    func stop()
}

/// Live implementation: `NSWorkspace.willSleepNotification` plus a
/// memory-pressure `DispatchSource`. Both funnel to
/// `onShouldReleaseIdleResources`. Best-effort — a missed signal only means the
/// app keeps a warm WebView slightly longer, never incorrectness.
@MainActor
final class SystemPowerObserver: SystemPowerObserving {
    var onShouldReleaseIdleResources: (@MainActor () -> Void)?

    var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var sleepObserver: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func start() {
        guard sleepObserver == nil, memoryPressureSource == nil else { return }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` delivers on the main thread; hop to the main actor.
            MainActor.assumeIsolated {
                self?.onShouldReleaseIdleResources?()
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.onShouldReleaseIdleResources?()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func stop() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }
}
