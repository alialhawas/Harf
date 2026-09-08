import Carbon.HIToolbox
import XCTest

@testable import DodomaCore

/// The shortcut table, pinned in both vocabularies.
///
/// It has to be pinned in both because it is used twice for two different
/// purposes — Carbon dispatches the chord, the event tap recognises it so that
/// Dodoma's own shortcut is never mistaken for typing — and the two would
/// silently disagree if one side were edited alone. The visible symptom of a
/// disagreement is an undo that abandons itself, which is not something a
/// reader would trace back to a modifier constant.
final class HotkeyTests: XCTestCase {
    func testTheBindings() {
        XCTAssertEqual(Hotkeys.undoLastFix.keycode, 6, "kVK_ANSI_Z")
        XCTAssertEqual(Hotkeys.undoLastFix.keycode, UInt16(kVK_ANSI_Z))
        XCTAssertEqual(Hotkeys.undoLastFix.modifiers, [.command, .option])

        XCTAssertEqual(Hotkeys.togglePause.keycode, 35, "kVK_ANSI_P")
        XCTAssertEqual(Hotkeys.togglePause.keycode, UInt16(kVK_ANSI_P))
        XCTAssertEqual(Hotkeys.togglePause.modifiers, [.command, .option])

        XCTAssertEqual(Hotkeys.flipSelection.keycode, 3, "kVK_ANSI_F")
        XCTAssertEqual(Hotkeys.flipSelection.keycode, UInt16(kVK_ANSI_F))
        XCTAssertEqual(Hotkeys.flipSelection.modifiers, [.control, .command])
    }

    func testEveryActionHasExactlyOneBinding() {
        XCTAssertEqual(Hotkeys.all.count, HotkeyAction.allCases.count)
        XCTAssertEqual(Set(Hotkeys.all.map(\.action)), Set(HotkeyAction.allCases))
    }

    /// Two bindings on one chord would mean the second is dead: Carbon refuses
    /// the duplicate registration and the tap's first match wins.
    func testNoTwoBindingsShareAChord() {
        let chords = Hotkeys.all.map { "\($0.keycode)/\($0.modifiers.rawValue)" }
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    // MARK: - The Carbon half

    func testCarbonModifiers() {
        XCTAssertEqual(Hotkeys.undoLastFix.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(Hotkeys.togglePause.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(Hotkeys.flipSelection.carbonModifiers, UInt32(cmdKey | controlKey))
    }

    func testEveryModifierIsTranslated() {
        let all = HotkeyBinding(
            action: .undoLastFix, keycode: 0, modifiers: [.command, .option, .shift, .control])
        XCTAssertEqual(
            all.carbonModifiers, UInt32(cmdKey | optionKey | shiftKey | controlKey))

        let none = HotkeyBinding(action: .undoLastFix, keycode: 0, modifiers: [])
        XCTAssertEqual(none.carbonModifiers, 0)
    }

    /// Caps Lock has no Carbon hot key meaning here, and must not leak into the
    /// mask as `alphaLock` — that would register a chord nobody can press.
    func testCapsLockIsNotTranslated() {
        let binding = HotkeyBinding(
            action: .undoLastFix, keycode: 6, modifiers: [.command, .option, .capsLock])
        XCTAssertEqual(binding.carbonModifiers, UInt32(cmdKey | optionKey))
    }

    // MARK: - The event tap half

    func testTheChordIsRecognised() {
        XCTAssertEqual(Hotkeys.action(forKeycode: 6, flags: [.command, .option]), .undoLastFix)
        XCTAssertEqual(Hotkeys.action(forKeycode: 35, flags: [.command, .option]), .togglePause)
        XCTAssertEqual(
            Hotkeys.action(forKeycode: 3, flags: [.control, .command]), .flipSelection)
    }

    /// Typing Arabic through the English layout with Caps Lock on is how the
    /// text this app exists to fix gets produced, so a shortcut that stopped
    /// working in that state would be useless.
    func testCapsLockIsIgnoredWhenMatching() {
        XCTAssertEqual(
            Hotkeys.action(forKeycode: 6, flags: [.command, .option, .capsLock]), .undoLastFix)
    }

    /// Every other modifier must match exactly. ⌘⌥⇧Z is somebody else's chord,
    /// and Carbon will not dispatch it either — so swallowing it here would
    /// take a keystroke out of the buffer for nothing.
    func testNearMissesAreNotTheChord() {
        let misses: [(UInt16, KeyFlags)] = [
            (6, [.command]),
            (6, [.option]),
            (6, []),
            (6, [.command, .option, .shift]),
            (6, [.command, .option, .control]),
            (6, [.command, .option, .fn]),
            (7, [.command, .option]),
            (35, [.command, .shift]),
            (3, [.command]),
            (3, [.control]),
            (3, [.control, .command, .shift]),
        ]
        for (keycode, flags) in misses {
            XCTAssertNil(
                Hotkeys.action(forKeycode: keycode, flags: flags), "\(keycode)/\(flags.symbols)")
        }
    }

    /// Ordinary typing goes through this test once per keystroke, so it had
    /// better say no to all of it.
    func testPlainTypingIsNeverAChord() {
        for keycode in UInt16(0)...UInt16(127) {
            XCTAssertNil(Hotkeys.action(forKeycode: keycode, flags: []))
            XCTAssertNil(Hotkeys.action(forKeycode: keycode, flags: [.shift]))
            XCTAssertNil(Hotkeys.action(forKeycode: keycode, flags: [.capsLock]))
        }
    }
}
