import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey. The Carbon implementation uses
/// `RegisterEventHotKey`, which works inside the app sandbox with no extra
/// entitlement and without the Accessibility permission a `CGEventTap` would
/// require. This keeps the Ration window reachable even when macOS 26
/// declines to draw the menu-bar item.
@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool
    func unregister()
}

@MainActor
final class GlobalHotKeyController {
    /// ⌥⌘U — Option-Command-U ("U" for Usage). A full modifier combination,
    /// so it is unaffected by the macOS restriction on modifier-only hotkeys.
    static let defaultKeyCode = UInt32(kVK_ANSI_U)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    private let registrar: any GlobalHotKeyRegistering
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let onFire: @MainActor () -> Void
    private(set) var isRegistered = false

    init(
        keyCode: UInt32 = defaultKeyCode,
        modifiers: UInt32 = defaultModifiers,
        registrar: any GlobalHotKeyRegistering = CarbonHotKeyRegistrar(),
        onFire: @escaping @MainActor () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.registrar = registrar
        self.onFire = onFire
    }

    /// Registers the hotkey. Returns whether it is now active. Idempotent; a
    /// failed registration (e.g. the combination is already claimed) leaves the
    /// reopen-fallback window as the remaining access path.
    @discardableResult
    func register() -> Bool {
        guard !isRegistered else { return true }
        isRegistered = registrar.register(
            keyCode: keyCode,
            modifiers: modifiers,
            onFire: onFire
        )
        return isRegistered
    }

    func unregister() {
        guard isRegistered else { return }
        registrar.unregister()
        isRegistered = false
    }
}

/// Retained bridge between Carbon's C event handler and the main-actor action.
/// It is `Sendable` (immutable, main-actor-isolated closure) so it can be
/// handed to Carbon as an opaque pointer and touched from the callback without
/// a data race. `fire()` always hops onto the main queue before running the
/// action, so it never depends on which thread Carbon uses for delivery.
private final class HotKeyCallbackContext: Sendable {
    private let onFire: @MainActor () -> Void

    init(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
    }

    func fire() {
        let onFire = self.onFire
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onFire() }
        }
    }
}

@MainActor
final class CarbonHotKeyRegistrar: GlobalHotKeyRegistering {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    // The context is retained by Carbon for as long as the handler is installed
    // (`passRetained`), so it outlives this registrar; it is released only
    // after the handler is removed, which rules out a dangling-pointer fire.
    private var callbackContext: Unmanaged<HotKeyCallbackContext>?

    // 'AGST' — an app-specific four-char signature for the hotkey identity.
    private static let signature = OSType(0x4147_5354)

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool {
        unregister()

        let retainedContext = Unmanaged.passRetained(
            HotKeyCallbackContext(onFire: onFire)
        )

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKeyCallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                    .fire()
                return noErr
            },
            1,
            &eventType,
            retainedContext.toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr, let handlerRef else {
            retainedContext.release()
            return false
        }

        var newHotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )
        guard registerStatus == noErr, let newHotKeyRef else {
            RemoveEventHandler(handlerRef)
            retainedContext.release()
            return false
        }

        eventHandlerRef = handlerRef
        hotKeyRef = newHotKeyRef
        callbackContext = retainedContext
        return true
    }

    func unregister() {
        // Remove the hotkey and handler before releasing the retained context,
        // so the handler can never fire into a freed context.
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        callbackContext?.release()
        callbackContext = nil
    }

    // `isolated deinit` runs on the MainActor so it can touch the (non-Sendable)
    // Carbon references. Safety net: if a caller ever releases this registrar
    // without calling unregister() first, remove the still-installed handler and
    // release the retained context so nothing dangles. Production tears down via
    // MenuBarController.stop(); this covers every other path.
    isolated deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        callbackContext?.release()
    }
}
