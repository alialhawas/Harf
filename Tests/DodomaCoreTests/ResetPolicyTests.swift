import XCTest
@testable import DodomaCore

final class ResetPolicyTests: XCTestCase {
    private func action(
        keycode: UInt16,
        flags: KeyFlags = [],
        text: String = "a"
    ) -> BufferAction {
        BufferResetPolicy.action(
            for: CapturedKey(keycode: keycode, flags: flags, producedText: text))
    }

    func testSpecialKeycodesMapToExpectedActions() {
        let table: [(UInt16, BufferAction)] = [
            (36, .reset(.enterKey)),    // Return
            (76, .reset(.enterKey)),    // Keypad Enter
            (48, .reset(.tabKey)),      // Tab
            (53, .reset(.escapeKey)),   // Escape
            (123, .reset(.arrowNav)),   // Left
            (124, .reset(.arrowNav)),   // Right
            (125, .reset(.arrowNav)),   // Down
            (126, .reset(.arrowNav)),   // Up
            (115, .reset(.arrowNav)),   // Home
            (119, .reset(.arrowNav)),   // End
            (116, .reset(.arrowNav)),   // Page Up
            (121, .reset(.arrowNav)),   // Page Down
            (117, .reset(.arrowNav)),   // Forward delete
            (51, .backspace)            // Delete / Backspace
        ]

        for (keycode, expected) in table {
            XCTAssertEqual(action(keycode: keycode, text: ""), expected,
                           "keycode \(keycode) with empty text")
            XCTAssertEqual(action(keycode: keycode, text: "\u{7F}"), expected,
                           "keycode \(keycode) with control text")
        }
    }

    func testOrdinaryKeysAppend() {
        XCTAssertEqual(action(keycode: 0, text: "a"), .append)
        XCTAssertEqual(action(keycode: 49, text: " "), .append)
        XCTAssertEqual(action(keycode: 42, text: "لا"), .append)
    }

    func testTypingModifiersStillAppend() {
        XCTAssertEqual(action(keycode: 0, flags: .shift, text: "A"), .append)
        XCTAssertEqual(action(keycode: 0, flags: .option, text: "å"), .append)
        XCTAssertEqual(action(keycode: 0, flags: .capsLock, text: "A"), .append)
        XCTAssertEqual(action(keycode: 0, flags: [.shift, .option, .capsLock], text: "Å"), .append)
    }

    func testCommandAndControlChordsReset() {
        XCTAssertEqual(action(keycode: 0, flags: .command, text: "a"), .reset(.modifierChord))
        XCTAssertEqual(action(keycode: 0, flags: .control, text: "a"), .reset(.modifierChord))
        XCTAssertEqual(action(keycode: 0, flags: [.command, .shift], text: "A"), .reset(.modifierChord))
        XCTAssertEqual(action(keycode: 48, flags: .command, text: ""), .reset(.modifierChord))
        XCTAssertEqual(action(keycode: 51, flags: .command, text: ""), .reset(.modifierChord))
    }

    func testKeysWithoutProducedTextReset() {
        // Function keys F1–F12 and friends produce no text.
        for keycode: UInt16 in [96, 97, 98, 99, 100, 101, 103, 105, 107, 109, 111, 113, 122, 120] {
            XCTAssertEqual(action(keycode: keycode, text: ""), .reset(.modifierChord),
                           "keycode \(keycode)")
        }
    }

    func testPureModifierKeycodesAreIgnored() {
        for keycode: UInt16 in 54...63 {
            XCTAssertEqual(action(keycode: keycode, flags: .command, text: ""), .ignore,
                           "keycode \(keycode)")
        }
    }

    func testIdleTimeoutIsTenSeconds() {
        XCTAssertEqual(BufferResetPolicy.idleTimeout, 10)
        XCTAssertFalse(BufferResetPolicy.isIdle(lastKeyTimestamp: 100, now: 105))
        XCTAssertFalse(BufferResetPolicy.isIdle(lastKeyTimestamp: 100, now: 110))
        XCTAssertTrue(BufferResetPolicy.isIdle(lastKeyTimestamp: 100, now: 110.5))
    }

    func testPolicyDrivesBufferEndToEnd() {
        let buffer = TypedBuffer()
        let script: [(UInt16, KeyFlags, String)] = [
            (4, [], "h"),
            (34, [], "i"),
            (51, [], ""),      // backspace
            (34, [], "i"),
            (49, [], " "),
            (36, [], "")       // Return resets
        ]

        for (keycode, flags, text) in script {
            let key = CapturedKey(keycode: keycode, flags: flags, producedText: text)
            switch BufferResetPolicy.action(for: key) {
            case .append: buffer.append(key)
            case .backspace: buffer.backspace()
            case .reset(let reason): buffer.reset(reason: reason)
            case .ignore: break
            }
        }

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.lastResetReason, .enterKey)
    }

    // MARK: - Which reasons also throw away the keystroke history

    /// Exhaustive over `allCases`, so adding a reason is a decision somebody
    /// has to make rather than a default they inherit. The debug event log
    /// holds the produced text of the last fifty keys; only a reason that means
    /// "this text was never ours" may take it.
    func testOnlySecureInputPurgesTheKeystrokeHistory() {
        let purging = ResetReason.allCases.filter(\.purgesHistory)
        XCTAssertEqual(purging, [.secureInput])
        XCTAssertEqual(ResetReason.allCases.count, 14, "a new reason needs a purge decision")
    }

    /// The decision made for the newest reason, written down where the count
    /// above sends the next reader.
    ///
    /// A tap interruption says keystrokes reached the screen without reaching
    /// the buffer. That makes the buffer's claim about what is in front of the
    /// caret false — so the buffer goes, and the pipeline gives up the undo slot
    /// with it — but it says nothing about the fifty keys the tap *did* see, and
    /// those are exactly what somebody opening the debug window after a missed
    /// burst is looking for.
    func testATapInterruptionKeepsTheKeystrokeHistory() {
        XCTAssertFalse(ResetReason.tapInterrupted.purgesHistory)
    }
}
