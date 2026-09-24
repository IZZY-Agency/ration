import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey; one registrar per key, and several
/// registrars may be live at once (⌥⌘U plus the popover's temporary keys), each
/// unregistered on its own. The Carbon implementation uses
/// `RegisterEventHotKey`, which works inside the app sandbox with no extra
/// entitlement and without the Accessibility permission a `CGEventTap` would
/// require. This keeps the Ration window reachable even when macOS 26
/// declines to draw the menu-bar item.
@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    /// `exclusive`: refuse the combination when anyone else already holds
    /// it (`kEventHotKeyExclusive`), instead of silently sharing it.
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        exclusive: Bool,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool
    func unregister()
}

extension GlobalHotKeyRegistering {
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool {
        register(keyCode: keyCode, modifiers: modifiers, exclusive: false, onFire: onFire)
    }
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
    private let signature: OSType
    private let id: UInt32
    /// This registration's token. A press is queued onto the main queue, so it
    /// can outlive `unregister()`; the token is revoked there and checked
    /// right before the action runs. One token per registration, so a
    /// re-registration (close → reopen) never revives a stale press.
    let token = HotKeyRegistrationToken()

    init(hotKeyID: EventHotKeyID, onFire: @escaping @MainActor () -> Void) {
        self.signature = hotKeyID.signature
        self.id = hotKeyID.id
        self.onFire = onFire
    }

    /// Every registrar installs its own handler on the application target, and
    /// Carbon offers each hotkey press to all of them, newest first. Claim
    /// only this registrar's own press; pass the rest down the chain.
    func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressed
        )
        guard status == noErr, pressed.signature == signature, pressed.id == id else {
            return OSStatus(eventNotHandledErr)
        }
        fire()
        return noErr
    }

    func fire() {
        let onFire = self.onFire
        let token = self.token
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard token.isLive else { return }
                onFire()
            }
        }
    }
}

@MainActor
private final class HotKeyRegistrationToken {
    private(set) var isLive = true

    func revoke() { isLive = false }
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

    /// Distinct per registration, so each handler can tell its press apart.
    private static var nextID: UInt32 = 1

    private(set) var registeredHotKeyID: EventHotKeyID?

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        exclusive: Bool,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool {
        unregister()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        Self.nextID &+= 1
        let retainedContext = Unmanaged.passRetained(
            HotKeyCallbackContext(hotKeyID: hotKeyID, onFire: onFire)
        )

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<HotKeyCallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                    .handle(event)
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
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            exclusive ? OptionBits(kEventHotKeyExclusive) : 0,
            &newHotKeyRef
        )
        guard registerStatus == noErr, let newHotKeyRef else {
            RemoveEventHandler(handlerRef)
            retainedContext.takeUnretainedValue().token.revoke()
            retainedContext.release()
            return false
        }

        eventHandlerRef = handlerRef
        hotKeyRef = newHotKeyRef
        callbackContext = retainedContext
        registeredHotKeyID = hotKeyID
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
        callbackContext?.takeUnretainedValue().token.revoke()
        callbackContext?.release()
        callbackContext = nil
        registeredHotKeyID = nil
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
        callbackContext?.takeUnretainedValue().token.revoke()
        callbackContext?.release()
    }
}

/// Finds the key that types a character on the current layout. Cocoa key
/// equivalents (the popover's `.keyboardShortcut`s) follow the character, but
/// a Carbon hotkey names a physical key — so ⌘Q on AZERTY must register the
/// key where ANSI has A, or ⌘A would quit.
enum ShortcutKeyCodeResolver {
    /// Keypad keys can type "," or "." too; never pick them over the main row.
    private static let keypadKeyCodes: Set<UInt16> = Set(
        UInt16(kVK_ANSI_KeypadDecimal)...UInt16(kVK_ANSI_Keypad9)
    ).union([UInt16(kVK_JIS_KeypadComma)])

    /// The ANSI key when it still types `character`, else the first
    /// non-keypad key that does, else `fallback`.
    static func keyCode(
        for character: String,
        fallback: UInt32,
        translate: (UInt16) -> String?
    ) -> UInt32 {
        if translate(UInt16(fallback))?.lowercased() == character { return fallback }
        for keyCode in UInt16(0)..<128 where !keypadKeyCodes.contains(keyCode) {
            if translate(keyCode)?.lowercased() == character { return UInt32(keyCode) }
        }
        return fallback
    }

    /// Resolved against the current ASCII-capable layout — the one macOS uses
    /// for ⌘ shortcuts — at each popover presentation.
    @MainActor
    static func liveKeyCode(for shortcut: PopoverShortcut) -> UInt32 {
        keyCode(
            for: shortcut.character,
            fallback: shortcut.ansiKeyCode,
            translate: liveTranslator()
        )
    }

    @MainActor
    private static func liveTranslator() -> (UInt16) -> String? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return { _ in nil }
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return { keyCode in
            data.withUnsafeBytes { buffer -> String? in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    0,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}
