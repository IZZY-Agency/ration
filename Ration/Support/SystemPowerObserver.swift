import AppKit
import Foundation
import IOKit.ps

/// Seam over the system power / memory signals the app reacts to. Injected
/// so tests can drive sleep, memory-pressure, Low Power and the power source
/// deterministically, mirroring `NotificationScheduling` and
/// `WebProfileManaging`.
@MainActor
protocol SystemPowerObserving: AnyObject {
    /// Invoked when the system is about to sleep or is under memory pressure —
    /// the owner should release WebViews that aren't backing in-flight work.
    var onShouldReleaseIdleResources: (@MainActor () -> Void)? { get set }
    /// Whether the Mac is in Low Power Mode (phase 3 — relaxes poll cadence).
    var isLowPowerModeEnabled: Bool { get }
    /// What powers the Mac right now. The automatic keep-awake hold applies
    /// only on `.external` (the adapter or a UPS), never on an unknown read.
    var powerSource: PowerSource { get }
    /// Invoked when the power source changes (adapter plugged or pulled).
    var onPowerSourceChanged: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

/// The Mac's providing power source, as IOKit reports it.
enum PowerSource: Equatable, Sendable {
    /// The adapter or a UPS (`kIOPMACPowerKey`, `kIOPMUPSPowerKey`).
    case external
    case battery
    /// IOKit gave no answer. Treated as "not established", so nothing that
    /// needs external power proceeds on it.
    case unknown
}

/// Live implementation: `NSWorkspace.willSleepNotification` plus a
/// memory-pressure `DispatchSource`, both funnelled to
/// `onShouldReleaseIdleResources`, and IOKit's power-source notification for
/// `onPowerSourceChanged`. Best-effort — a missed signal only means the app
/// keeps a warm WebView slightly longer, or re-reads the power source on the
/// next minute's tick, never incorrectness.
@MainActor
final class SystemPowerObserver: SystemPowerObserving {
    var onShouldReleaseIdleResources: (@MainActor () -> Void)?
    var onPowerSourceChanged: (@MainActor () -> Void)?

    var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// `IOPSGetProvidingPowerSourceType` answers AC, battery or UPS. A
    /// failed read is `.unknown`, which fails closed for the automatic hold:
    /// external power was never established, so it is not assumed.
    var powerSource: PowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return .unknown }
        switch type as String {
        case kIOPMACPowerKey, kIOPMUPSPowerKey: return .external
        case kIOPMBatteryPowerKey: return .battery
        default: return .unknown
        }
    }

    private var sleepObserver: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var powerSourceNotification: CFRunLoopSource?

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

        // The IOKit callback takes a C function pointer, so `self` travels
        // as an unretained context; `stop()` removes the source before the
        // observer can go away.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<SystemPowerObserver>.fromOpaque(context).takeUnretainedValue()
            // IOKit delivers on the run loop the source was added to: main.
            MainActor.assumeIsolated {
                observer.onPowerSourceChanged?()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            powerSourceNotification = runLoopSource
        }
    }

    func stop() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let powerSourceNotification {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceNotification, .defaultMode)
            self.powerSourceNotification = nil
        }
    }
}
