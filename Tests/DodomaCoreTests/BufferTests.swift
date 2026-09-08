import XCTest
@testable import DodomaCore

final class BufferTests: XCTestCase {
    private func key(_ text: String, keycode: UInt16 = 0, at time: TimeInterval = 0) -> CapturedKey {
        CapturedKey(keycode: keycode, producedText: text, timestamp: time)
    }

    func testStartsEmpty() {
        let buffer = TypedBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.currentText, "")
        XCTAssertNil(buffer.lastResetReason)
        XCTAssertNil(buffer.lastKey)
    }

    func testAppendKeepsOrder() {
        let buffer = TypedBuffer()
        buffer.append(key("h", keycode: 4))
        buffer.append(key("i", keycode: 34))

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.keys.map(\.keycode), [4, 34])
        XCTAssertEqual(buffer.currentText, "hi")
        XCTAssertEqual(buffer.lastKey?.producedText, "i")
    }

    func testCurrentTextConcatenatesMultiCodepointProducedText() {
        let buffer = TypedBuffer()
        buffer.append(key("لا"))
        buffer.append(key("م"))

        XCTAssertEqual(buffer.currentText, "لام")
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.currentText.unicodeScalars.count, 3)
    }

    func testCurrentTextPreservesEmptyAndMultiCharEntries() {
        let buffer = TypedBuffer()
        buffer.append(key("a"))
        buffer.append(key(""))
        buffer.append(key("bc"))

        XCTAssertEqual(buffer.currentText, "abc")
        XCTAssertEqual(buffer.count, 3)
    }

    func testBackspaceRemovesLastKey() {
        let buffer = TypedBuffer()
        buffer.append(key("a"))
        buffer.append(key("b"))
        buffer.backspace()

        XCTAssertEqual(buffer.currentText, "a")
        XCTAssertEqual(buffer.count, 1)
    }

    func testBackspacePastEmptyIsNoOp() {
        let buffer = TypedBuffer()
        buffer.backspace()
        buffer.backspace()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.currentText, "")

        buffer.append(key("z"))
        XCTAssertEqual(buffer.currentText, "z")
    }

    func testOverflowDropsFromTheHeadAtCapacity() {
        let buffer = TypedBuffer()
        for index in 0..<(TypedBuffer.defaultCapacity + 5) {
            buffer.append(CapturedKey(keycode: UInt16(index % 100), producedText: "x"))
        }

        XCTAssertEqual(buffer.count, TypedBuffer.defaultCapacity)
        XCTAssertEqual(buffer.currentText.count, TypedBuffer.defaultCapacity)
        XCTAssertEqual(buffer.keys.first?.keycode, 5)
    }

    func testCapacityIsTwoHundred() {
        XCTAssertEqual(TypedBuffer.defaultCapacity, 200)
    }

    /// Lowering the limit has to act on what is already held. A control that
    /// only governed future keystrokes would not be a privacy control.
    func testLoweringTheCapacityTrimsWhatIsAlreadyHeld() {
        let buffer = TypedBuffer()
        for index in 0..<120 { buffer.append(key("x", keycode: UInt16(index % 100))) }
        buffer.setCapacity(30)
        XCTAssertEqual(buffer.keys.count, 30)
        XCTAssertEqual(buffer.keys.last?.keycode, UInt16(119 % 100), "the newest keys survive")
    }

    /// The limit is clamped, so a bad value cannot disable the ring.
    func testCapacityIsClamped() {
        let buffer = TypedBuffer()
        buffer.setCapacity(1)
        XCTAssertEqual(buffer.capacity, TypedBuffer.minimumCapacity)
        buffer.setCapacity(10_000)
        XCTAssertEqual(buffer.capacity, TypedBuffer.maximumCapacity)
    }

    func testResetClearsAndRecordsReason() {
        let buffer = TypedBuffer()
        buffer.append(key("a"))
        buffer.append(key("b"))
        buffer.reset(reason: .enterKey)

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.currentText, "")
        XCTAssertEqual(buffer.keys, [])
        XCTAssertEqual(buffer.lastResetReason, .enterKey)

        buffer.reset(reason: .appChanged)
        XCTAssertEqual(buffer.lastResetReason, .appChanged)
    }

    func testKeyFlagsSymbols() {
        XCTAssertEqual(KeyFlags([]).symbols, "")
        XCTAssertEqual(KeyFlags([.command, .shift]).symbols, "⇧⌘")
        XCTAssertEqual(KeyFlags([.capsLock, .control, .option]).symbols, "⇪⌃⌥")
    }
}
