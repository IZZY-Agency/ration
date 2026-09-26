import AppKit
import ObjectiveC

/// Holds back a quit while another quit's decision is still open.
///
/// Every quit — the app menu's Quit and ⌘Q (a nil-targeted `terminate:`),
/// the popover's Quit, the Dock menu — ends in `NSApplication.terminate(_:)`.
/// While a `.terminateLater` decision is open, AppKit answers another
/// terminate by going straight to `applicationWillTerminate` without asking
/// the delegate (probed on macOS 27.2), which would skip the open decision's
/// Settings-edit flush and cleanup. `shouldForward` decides first; a request
/// it holds back joins the open decision (see
/// `AppRelauncher.shouldForwardTermination()`).
///
/// Why a method replacement and not a subclass: a SwiftUI app runs as
/// SwiftUI's own `NSApplication` subclass and ignores `NSPrincipalClass`
/// (probed). That subclass does not override `terminate(_:)` (probed), so
/// replacing `NSApplication`'s implementation covers it. AppKit's own reply
/// path (`reply(toApplicationShouldTerminate:)`) does not call
/// `terminate(_:)`, and a quit Apple Event (log out) is not delivered while
/// the decision is open (both probed).
@MainActor
enum TerminationGate {
    /// Asked before a terminate request reaches AppKit; false holds it back.
    static var shouldForward: @MainActor () -> Bool = {
        AppRelauncher.shared.shouldForwardTermination()
    }

    private(set) static var isInstalled = false

    private typealias Terminate = @convention(c) (AnyObject, Selector, Any?) -> Void

    /// Idempotent. Call once at startup, before any quit can happen.
    static func install() {
        guard !isInstalled else { return }
        let selector = #selector(NSApplication.terminate(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Terminate.self)
        let replacement: @convention(block) (AnyObject, Any?) -> Void = { application, sender in
            let forward: Bool = MainActor.assumeIsolated { shouldForward() }
            guard forward else { return }
            original(application, selector, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        isInstalled = true
    }
}
