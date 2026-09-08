import Carbon.HIToolbox
import Foundation

/// Something the user can ask for from anywhere, without Dodoma being frontmost.
public enum HotkeyAction: String, Equatable, Sendable, CaseIterable {
    case undoLastFix
    case togglePause
    case flipSelection
}

/// One chord, in the two vocabularies that have to agree about it: the app's own
/// `KeyFlags` (which is what the event tap speaks) and Carbon's modifier mask
/// (which is what `RegisterEventHotKey` speaks).
///
/// They have to agree because the chord is used twice. Carbon dispatches it —
/// deliberately, because a Carbon hot key keeps working when the event tap has
/// been disabled by the system, which is one of the situations an undo is most
/// wanted in. The tap then *recognises* it, so that Dodoma's own shortcut is
/// never mistaken for typing: letting it through would bump the input serial
/// the undo is validated against, and the undo would abandon itself.
public struct HotkeyBinding: Equatable, Sendable {
    public let action: HotkeyAction
    /// Hardware key code, layout independent.
    public let keycode: UInt16
    public let modifiers: KeyFlags

    public init(action: HotkeyAction, keycode: UInt16, modifiers: KeyFlags) {
        self.action = action
        self.keycode = keycode
        self.modifiers = modifiers
    }

    /// The same chord as `RegisterEventHotKey` wants it.
    public var carbonModifiers: UInt32 {
        var mask: Int = 0
        if modifiers.contains(.command) { mask |= cmdKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        if modifiers.contains(.control) { mask |= controlKey }
        return UInt32(mask)
    }

    /// Whether a captured keystroke is this chord.
    ///
    /// Caps Lock is ignored, for the reason it is ignored everywhere else in
    /// this project: typing Arabic through the English layout with Caps Lock on
    /// is how the text Dodoma exists to fix gets produced, and a hot key that
    /// stopped working in exactly that state would be useless. Every other
    /// modifier must match exactly — ⌘⌥⇧Z is somebody else's chord, and Carbon
    /// will not dispatch it either.
    public func matches(keycode: UInt16, flags: KeyFlags) -> Bool {
        self.keycode == keycode && flags.subtracting(.capsLock) == modifiers
    }
}

/// The bindings, in one place. Rebinding is not supported — the settings
/// window shows the chords read-only and says so. When it is, it replaces
/// this table and nothing else.
public enum Hotkeys {
    /// ⌘⌥Z. Key code 6 is Z on every layout.
    public static let undoLastFix = HotkeyBinding(
        action: .undoLastFix, keycode: 6, modifiers: [.command, .option])

    /// ⌘⌥P. Key code 35 is P on every layout.
    public static let togglePause = HotkeyBinding(
        action: .togglePause, keycode: 35, modifiers: [.command, .option])

    /// ⌃⌘F. Key code 3 is F on every layout.
    public static let flipSelection = HotkeyBinding(
        action: .flipSelection, keycode: 3, modifiers: [.control, .command])

    public static let all: [HotkeyBinding] = [undoLastFix, togglePause, flipSelection]

    /// The action a captured keystroke asks for, or nil when it is ordinary
    /// typing. Called on the event tap thread, once per keystroke.
    public static func action(forKeycode keycode: UInt16, flags: KeyFlags) -> HotkeyAction? {
        all.first { $0.matches(keycode: keycode, flags: flags) }?.action
    }
}
