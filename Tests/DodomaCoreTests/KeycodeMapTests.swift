import Carbon.HIToolbox
import XCTest

@testable import DodomaCore

final class KeycodeMapTests: XCTestCase {
    func testEveryMappableCharacterRoundTripsThroughAbc() throws {
        let abc = try LayoutFixtures.abc()
        let text = "the quick brown fox jumps over the lazy dog 0123456789 ;'[],./\\-=`"
        let keys = try abc.keys(text)

        XCTAssertEqual(keys.count, text.count)
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), text)
    }

    func testUppercaseMapsToTheLowercaseKeycodePlusShift() throws {
        let lower = try XCTUnwrap(KeycodeMap.keys(forLatin: "az"))
        let upper = try XCTUnwrap(KeycodeMap.keys(forLatin: "AZ"))

        XCTAssertEqual(lower.map(\.keycode), upper.map(\.keycode))
        XCTAssertEqual(lower.map(\.flags), [[], []])
        XCTAssertEqual(upper.map(\.flags), [.shift, .shift])
    }

    func testProducedTextMirrorsTheInputCharacters() throws {
        let keys = try XCTUnwrap(KeycodeMap.keys(forLatin: "Hi you"))
        XCTAssertEqual(keys.map(\.producedText), ["H", "i", " ", "y", "o", "u"])
    }

    func testKeyboardTypeDefaultsToTheHostAndCanBeOverridden() throws {
        let host = try XCTUnwrap(KeycodeMap.keys(forLatin: "a"))
        XCTAssertNotEqual(host[0].keyboardType, 0)

        let pinned = try XCTUnwrap(KeycodeMap.keys(forLatin: "a", keyboardType: 41))
        XCTAssertEqual(pinned[0].keyboardType, 41)
    }

    func testEmptyInputYieldsNoKeys() {
        XCTAssertEqual(KeycodeMap.keys(forLatin: ""), [])
    }

    func testCopyKeycodeMatchesCarbon() {
        XCTAssertEqual(Keycode.c, UInt16(kVK_ANSI_C))
    }

    func testUnmappableCharactersReturnNil() {
        XCTAssertNil(KeycodeMap.keys(forLatin: "hello!"))
        XCTAssertNil(KeycodeMap.keys(forLatin: "مرحبا"))
        XCTAssertNil(KeycodeMap.keys(forLatin: "caf\u{00E9}"))
        XCTAssertNil(KeycodeMap.keys(forLatin: "line\nbreak"))
    }
}
