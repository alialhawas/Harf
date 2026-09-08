import Foundation

/// What the typed buffer should do with an incoming key event.
public enum BufferAction: Equatable, Hashable, Sendable {
    case append
    case backspace
    case reset(ResetReason)
    /// The event carries no typing signal; leave the buffer untouched.
    case ignore
}

/// Pure decision layer: maps a captured key onto a buffer action.
///
/// Rules, in evaluation order:
/// 1. Pure modifier key codes (54–63) are ignored. In practice the event tap
///    never forwards them, but the policy is defensive so that a stray
///    modifier keyDown cannot be mistaken for a command chord.
/// 2. Any event carrying Command or Control is a chord, not typing →
///    `reset(.modifierChord)`. Shift, Option and Caps Lock are legitimate
///    typing modifiers and do not reset.
/// 3. Named navigation / commit key codes reset with a specific reason.
///    Key codes are hardware values and therefore layout independent.
/// 4. Delete/Backspace (51) removes the last buffered key.
/// 5. Anything else that produced no text (function keys, media keys, dead
///    keys that only set state) → `reset(.modifierChord)`. This is the
///    documented catch-all: no text means the keystroke was not typing.
/// 6. Everything else appends.
public enum BufferResetPolicy {
    /// Seconds of inactivity after which the buffer is considered stale.
    /// The policy only publishes the value; the owner enforces it by comparing
    /// timestamps, because the buffer owns no timers.
    public static let idleTimeout: TimeInterval = 10

    /// Key codes of the pure modifier keys, which never produce text.
    static let modifierKeycodes: ClosedRange<UInt16> = 54...63

    public static func action(for key: CapturedKey) -> BufferAction {
        if modifierKeycodes.contains(key.keycode) {
            return .ignore
        }

        if !key.flags.isDisjoint(with: .chordModifiers) {
            return .reset(.modifierChord)
        }

        switch key.keycode {
        case Keycode.returnKey, Keycode.keypadEnter:
            return .reset(.enterKey)
        case Keycode.tab:
            return .reset(.tabKey)
        case Keycode.escape:
            return .reset(.escapeKey)
        case Keycode.leftArrow, Keycode.rightArrow, Keycode.downArrow, Keycode.upArrow,
             Keycode.home, Keycode.end, Keycode.pageUp, Keycode.pageDown:
            return .reset(.arrowNav)
        case Keycode.forwardDelete:
            // Caret semantics after a forward delete are unknowable from the
            // tap alone, so drop the buffer rather than desynchronise it.
            return .reset(.arrowNav)
        case Keycode.delete:
            return .backspace
        default:
            break
        }

        if key.producedText.isEmpty {
            return .reset(.modifierChord)
        }

        return .append
    }

    /// True when `now` is more than `idleTimeout` seconds after the last keystroke.
    public static func isIdle(
        lastKeyTimestamp: TimeInterval, now: TimeInterval, timeout: TimeInterval = idleTimeout
    ) -> Bool {
        now - lastKeyTimestamp > timeout
    }
}
