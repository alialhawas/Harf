import Carbon.HIToolbox
import DodomaCore
import Foundation

/// The global shortcuts, registered with Carbon.
///
/// Carbon rather than the event tap, deliberately. The tap is the thing most
/// likely to be broken at the moment a shortcut is most wanted: the system
/// disables taps that are slow to answer, and the watchdog then stops Dodoma
/// consuming anything for the rest of the session. Undo is the escape hatch
/// from a rewrite the user did not ask for, so it must not be reachable only
/// through the machinery that did the rewriting. `RegisterEventHotKey` is
/// handled by the window server and keeps working regardless.
///
/// Main thread only, throughout: `InstallEventHandler` on the application event
/// target delivers on the main run loop, and `RegisterEventHotKey` is a
/// main-thread call.
final class HotkeyCenter {
    /// Four-character code identifying our hot keys, so the handler can tell
    /// them from anybody else's. 'DODO'.
    private static let signature: OSType = 0x444F_444F

    /// Called on the main thread when a shortcut fires.
    var onAction: ((HotkeyAction) -> Void)?

    private var registered: [EventHotKeyRef] = []
    /// The actions that actually got their chord. Anything missing here is a
    /// chord another application already owns, and nothing in the interface
    /// may advertise it.
    private(set) var registeredActions: Set<HotkeyAction> = []
    private var handler: EventHandlerRef?
    /// Index into `HotkeyAction.allCases`, which is what the hot key id carries.
    private let actions = HotkeyAction.allCases

    deinit {
        // Nothing about the Carbon handler holds this object alive, so an
        // instance dropped without an explicit unregister would leave a handler
        // pointing at freed memory. `unregister` is idempotent.
        unregister()
    }

    /// Installs the handler and registers every binding. Returns false if any
    /// part of it failed; the ones that succeeded stay registered and working.
    @discardableResult
    func register() -> Bool {
        assert(Thread.isMainThread)
        guard handler == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            dodomaHotkeyHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
        guard status == noErr else {
            Log.app.error(
                "hot key handler could not be installed (\(status, privacy: .public)); ⌘⌥Z, ⌘⌥P and ⌃⌘F will not work"
            )
            handler = nil
            return false
        }

        var allRegistered = true
        for binding in Hotkeys.all {
            guard let index = actions.firstIndex(of: binding.action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let result = RegisterEventHotKey(
                UInt32(binding.keycode), binding.carbonModifiers, id,
                GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                registered.append(ref)
                registeredActions.insert(binding.action)
            } else {
                // Almost always because another application already owns the
                // chord. Nothing to do about it here, and the rest still works.
                allRegistered = false
                Log.app.error(
                    "hot key for \(binding.action.rawValue, privacy: .public) could not be registered (\(result, privacy: .public))"
                )
            }
        }
        Log.app.info("hot keys registered: \(self.registered.count, privacy: .public)")
        return allRegistered
    }

    /// Idempotent. Main thread only.
    func unregister() {
        for ref in registered {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
        registeredActions.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    /// Called on the main thread by the Carbon handler.
    fileprivate func fire(id: UInt32) {
        guard actions.indices.contains(Int(id)) else { return }
        let action = actions[Int(id)]
        Log.app.info("hot key: \(action.rawValue, privacy: .public)")
        onAction?(action)
    }
}

/// C callback: no captures allowed, so the centre arrives via `userData`.
private func dodomaHotkeyHandler(
    callRef: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }

    let centre = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    centre.fire(id: id.id)
    return noErr
}
