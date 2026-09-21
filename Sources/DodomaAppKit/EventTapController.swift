import CoreGraphics
import DodomaCore
import Foundation

/// Something the event tap observed, already converted to plain values so that
/// no `CGEvent` ever escapes the tap thread.
enum TapEvent {
    case key(CapturedKey)
    /// - Parameters:
    ///   - at: the pointer in display coordinates, as `CGEvent` reports it. The
    ///     pipeline needs it to tell a click on the suggestion card from a click
    ///     anywhere else.
    ///   - primaryButton: a left mouse-down. Only a left click on the card
    ///     accepts a suggestion.
    case mouseDown(at: CGPoint, primaryButton: Bool)
    /// The accept key, consumed by the tap while a suggestion is on screen.
    /// Deliberately not a `.key`: it never reaches the typed buffer, and it must
    /// not move the input serial the acceptance is validated against.
    case suggestionAccept
    /// Likewise for the dismiss key.
    case suggestionDismiss
    /// Keystrokes reached the screen without reaching the pipeline.
    ///
    /// Two things cause it, and they have the same consequence: the system
    /// disabling the tap — every key pressed until it is re-enabled is invisible
    /// here — and an autorepeat burst, which is dropped on purpose so that
    /// holding a letter down does not flood the buffer with copies of it. Either
    /// way the buffer has stopped describing the text in front of the caret, and
    /// everything counted from the caret is now counted from the wrong place.
    case tapInterrupted(reason: String)
}

/// What one raw key event means to the tap, decided without touching a
/// `CGEvent`.
///
/// Pulled out of `handleKeyDown` so the order of the four filters is a thing
/// that can be read and tested. The order is load-bearing: the panel's keys are
/// claimed ahead of the autorepeat filter because a held-down Tab has to keep
/// being swallowed, and Dodoma's own chords are claimed ahead of it because the
/// undo they ask for is validated against a serial their own keystroke would
/// otherwise move.
enum TapKeyMeaning: Equatable {
    /// Posted by the injector. Never anything but passed through.
    case selfInjected
    case suggestionAccept
    case suggestionDismiss
    /// One of Dodoma's own chords, on its way to Carbon.
    case hotkey
    /// An autorepeat that is not a delete, and so is not delivered.
    case autorepeatDropped
    case typing
}

extension EventTapController {
    /// - Parameters:
    ///   - userData: `.eventSourceUserData` of the event.
    ///   - panelVisible: whether a suggestion card is on screen.
    ///   - panelConsumesKeys: false once the watchdog has tripped.
    static func meaning(
        userData: Int64,
        keycode: UInt16,
        flags: KeyFlags,
        isAutorepeat: Bool,
        panelVisible: Bool,
        panelConsumesKeys: Bool
    ) -> TapKeyMeaning {
        guard userData != injectedEventMarker else { return .selfInjected }

        switch SuggestionKeys.disposition(
            visible: panelVisible, consumesKeys: panelConsumesKeys, keycode: keycode, flags: flags)
        {
        case .swallowAndAccept:
            return .suggestionAccept
        case .swallowAndDismiss:
            return .suggestionDismiss
        case .pass, .dismissAndPass:
            // Real typing either way. `dismissAndPass` differs only in that the
            // pipeline will take the panel down when this key reaches it, which
            // it does for every input regardless.
            break
        }

        if Hotkeys.action(forKeycode: keycode, flags: flags) != nil { return .hotkey }

        // Backspace is the exception: held-down deletes must shrink the buffer.
        if isAutorepeat && keycode != Keycode.delete { return .autorepeatDropped }

        return .typing
    }
}

/// Owns the session-wide `CGEventTap` and pumps it on a dedicated run loop thread.
///
/// The tap is very nearly a listener: every event is passed straight through
/// unmodified, with exactly one exception. While a suggestion panel is on
/// screen, the accept and dismiss keys are consumed, because they are the
/// panel's keys for as long as it is up and letting a Tab through as well would
/// move focus in the application underneath. Nothing else is ever consumed, and
/// the exception switches itself off if the watchdog trips.
final class EventTapController {
    /// Marker written into `.eventSourceUserData` of the events Dodoma posts.
    /// Events carrying it are ignored here so the injector can never feed its
    /// own keystrokes back into the buffer.
    ///
    /// The process identifier rides in the high half. A fixed constant is a
    /// value any other process can write, deliberately or by coincidence, and
    /// anything that writes it makes this app deaf to a stream of real
    /// keystrokes; it is also the same value in a second copy of Harf, whose
    /// injection would then be invisible to this one. Read here and written in
    /// `FixEngine.makeSource`, from this one definition.
    static let injectedEventMarker: Int64 = {
        let pid = Int64(ProcessInfo.processInfo.processIdentifier) & 0xFFFF_FFFF
        return (pid << 32) | 0x444F_444F
    }()

    /// Two tap disables inside this window are treated as a fault.
    private static let watchdogWindow: TimeInterval = 60
    private static let watchdogThreshold = 2

    /// How long `stop()` waits for the tap thread to leave its run loop.
    private static let threadExitTimeout: DispatchTimeInterval = .seconds(2)

    private let queue: DispatchQueue
    private let handler: (TapEvent) -> Void
    /// Read from the tap thread on every keystroke. One lock, three fields.
    private let suggestion: SuggestionState

    /// Called on the tap thread the first time the watchdog trips. The caller
    /// is responsible for hopping to the main thread. Immutable, like `handler`,
    /// so the tap thread cannot read it while the main thread assigns it.
    private let onDegraded: () -> Void
    /// Set once and never cleared: a tap that has been disabled twice in a
    /// minute is a tap the system is unhappy with, and consuming input is the
    /// part of what we do that is most likely to be making that worse. A restart
    /// clears it.
    private var degraded = false

    /// `tap`, `runLoopSource`, `runLoop`, `thread` and `running` are shared
    /// between the main thread (start/stop) and the tap thread (run loop body
    /// and callbacks) and are only ever touched while holding `stateLock`.
    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var running = false

    /// Signalled by the tap thread when it leaves `runTapLoop`.
    private var threadExited = DispatchSemaphore(value: 0)

    /// Touched only from the tap thread.
    private var disableTimestamps: [TimeInterval] = []

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// - Parameters:
    ///   - queue: serial queue the captured events are delivered on.
    ///   - suggestion: the shared panel state, read on the tap thread.
    ///   - onDegraded: invoked on the tap thread the first time the watchdog
    ///     trips.
    ///   - handler: invoked on `queue` for every captured event.
    init(
        queue: DispatchQueue,
        suggestion: SuggestionState,
        onDegraded: @escaping () -> Void = {},
        handler: @escaping (TapEvent) -> Void
    ) {
        self.queue = queue
        self.suggestion = suggestion
        self.onDegraded = onDegraded
        self.handler = handler
    }

    deinit {
        // While `runTapLoop` is executing it holds a strong reference to self,
        // so deinit can only be reached once the tap thread has exited. `stop()`
        // is still called here so a controller that is dropped without an
        // explicit stop cannot leak the mach port, and it is idempotent.
        stop()
    }

    /// Creates and starts the tap. Returns false when the tap cannot be created,
    /// which is what happens while Accessibility / Input Monitoring are ungranted.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dodomaEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.tap.debug("tap creation failed (permissions not granted yet)")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Log.tap.error("failed to create run loop source for tap")
            return false
        }

        let thread = Thread { [weak self] in
            self?.runTapLoop()
        }
        thread.name = "com.ali.dodoma.eventtap"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        tap = port
        runLoopSource = source
        self.thread = thread
        threadExited = DispatchSemaphore(value: 0)
        running = true
        stateLock.unlock()

        thread.start()

        Log.tap.info("event tap started")
        return true
    }

    /// Idempotent and safe to call from any thread. Returns only once the tap
    /// thread has left its run loop, so no callback can still be in flight when
    /// the mach port is invalidated.
    func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let port = tap
        let source = runLoopSource
        let loop = runLoop
        let exited = threadExited
        tap = nil
        runLoopSource = nil
        runLoop = nil
        stateLock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }

        if let loop {
            // The thread is inside (or about to enter) CFRunLoopRun. Wake it and
            // wait, so that no callback can be running when the port dies below.
            CFRunLoopStop(loop)
            if exited.wait(timeout: .now() + Self.threadExitTimeout) == .timedOut {
                Log.tap.error("tap thread did not exit before the teardown timeout")
            }
        }
        // If `loop` was nil the thread has not yet entered its critical section;
        // because `tap` was cleared under the same lock it will find nothing to
        // do and return immediately, so there is nothing to wait for.

        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let port {
            CFMachPortInvalidate(port)
        }

        stateLock.lock()
        thread = nil
        stateLock.unlock()

        Log.tap.info("event tap stopped")
    }

    /// Body of the dedicated tap thread. Holds a strong reference to the
    /// controller for its whole duration, which is what keeps the unretained
    /// `userInfo` pointer handed to `tapCreate` valid.
    private func runTapLoop() {
        stateLock.lock()
        let source = runLoopSource
        let port = tap
        let exited = threadExited
        let loop: CFRunLoop? = (source != nil && port != nil) ? CFRunLoopGetCurrent() : nil
        runLoop = loop
        stateLock.unlock()

        defer { exited.signal() }

        // `stop()` won the race and already tore everything down.
        guard let source, let port, let loop else { return }

        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        CFRunLoopRun()

        CFRunLoopRemoveSource(loop, source, .commonModes)
    }

    /// Snapshot of the mach port for use on the tap thread.
    private func currentTap() -> CFMachPort? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tap
    }

    // MARK: - Callback path (runs on the tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            handleTapDisabled(cause: "timeout")
            return nil
        case .tapDisabledByUserInput:
            handleTapDisabled(cause: "userInput")
            return nil
        case .keyDown:
            if handleKeyDown(event) { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isSelfInjected(event) {
                deliver(.mouseDown(at: event.location, primaryButton: type == .leftMouseDown))
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleTapDisabled(cause: String) {
        guard let tap = currentTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)

        // Before the watchdog arithmetic, and on every disable rather than on
        // the second one in a minute: the tap is re-enabled above, but nothing
        // that was typed while it was off came through here, and the pipeline
        // has no other way to find that out.
        deliver(.tapInterrupted(reason: cause))

        let now = Date().timeIntervalSinceReferenceDate
        disableTimestamps.append(now)
        disableTimestamps.removeAll { now - $0 > Self.watchdogWindow }

        if disableTimestamps.count >= Self.watchdogThreshold {
            Log.tap.fault(
                "event tap disabled \(self.disableTimestamps.count, privacy: .public) times in \(Int(Self.watchdogWindow), privacy: .public)s (cause=\(cause, privacy: .public)); re-enabled"
            )
            degrade()
        } else {
            Log.tap.error("event tap disabled (cause=\(cause, privacy: .public)); re-enabled")
        }
    }

    /// Stops consuming events for the rest of the session.
    ///
    /// The suggestion panel keeps working — it is a window, not an event
    /// interception — and is accepted by clicking it. What stops is the tap
    /// returning nil for anything, which is the only behaviour that could turn
    /// a sick tap into lost keystrokes.
    private func degrade() {
        guard !degraded else { return }
        degraded = true
        suggestion.setConsumesKeys(false)
        Log.tap.fault(
            "event consumption disabled after the watchdog tripped; suggestions are click-only")
        onDegraded()
    }

    /// - Returns: true when the event must be swallowed.
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = KeyFlags(event.flags)
        let panel = suggestion.snapshot

        switch Self.meaning(
            userData: event.getIntegerValueField(.eventSourceUserData),
            keycode: keycode,
            flags: flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            panelVisible: panel.visible,
            panelConsumesKeys: panel.consumesKeys)
        {
        case .selfInjected, .hotkey:
            return false

        case .suggestionAccept:
            deliver(.suggestionAccept)
            return true

        case .suggestionDismiss:
            deliver(.suggestionDismiss)
            return true

        case .autorepeatDropped:
            // The repeats are still returned to the system, so the character
            // arrives on screen once per repeat while the buffer stands still.
            // Saying so costs one queued value per held key and is the
            // difference between a buffer that is short and one that is wrong.
            deliver(.tapInterrupted(reason: "autorepeat"))
            return false

        case .typing:
            let keyboardType = UInt32(
                truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType))

            deliver(.key(CapturedKey(
                keycode: keycode,
                flags: flags,
                producedText: Self.unicodeString(from: event),
                keyboardType: keyboardType,
                timestamp: Date().timeIntervalSinceReferenceDate)))
            return false
        }
    }

    private func isSelfInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventMarker
    }

    private func deliver(_ event: TapEvent) {
        let handler = self.handler
        queue.async { handler(event) }
    }

    private static func unicodeString(from event: CGEvent) -> String {
        let maxLength = 8
        var length = 0
        var buffer = [UniChar](repeating: 0, count: maxLength)
        event.keyboardGetUnicodeString(
            maxStringLength: maxLength,
            actualStringLength: &length,
            unicodeString: &buffer)

        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: min(length, maxLength))
    }
}

/// C callback: no captures allowed, so the controller arrives via `userInfo`.
private func dodomaEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

extension KeyFlags {
    /// Boundary conversion: CoreGraphics flags are not allowed inside DodomaCore.
    init(_ flags: CGEventFlags) {
        var result: KeyFlags = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlphaShift) { result.insert(.capsLock) }
        if flags.contains(.maskSecondaryFn) { result.insert(.fn) }
        self = result
    }
}
