import XCTest

@testable import DodomaCore

final class FlipBuilderTests: XCTestCase {
    /// `hgsghl` is `السلام` typed with the English layout still selected.
    private let latinPhrase = "hgsghl "
    private let arabicPhrase = "السلام "

    private func flip(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> Flip?
    {
        let abc = try LayoutFixtures.abc(file: file, line: line)
        let arabic = try LayoutFixtures.arabic(file: file, line: line)
        return FlipBuilder.flip(
            text, english: abc.layout, arabic: arabic.layout, keyboardType: abc.keyboardType)
    }

    func testLatinTextFlipsToArabic() throws {
        let flip = try XCTUnwrap(flip(latinPhrase))

        XCTAssertEqual(flip.flipped, arabicPhrase)
        XCTAssertEqual(flip.original, latinPhrase)
        XCTAssertEqual(flip.sourceLanguage, .english)
        XCTAssertEqual(flip.targetLanguage, .arabic)
        XCTAssertEqual(flip.sourceLayoutID, LayoutFixtures.abcSourceID)
        XCTAssertEqual(flip.targetLayoutID, LayoutFixtures.arabicSourceID)
    }

    func testArabicTextFlipsToLatin() throws {
        let flip = try XCTUnwrap(flip(arabicPhrase))

        XCTAssertEqual(flip.flipped, latinPhrase)
        XCTAssertEqual(flip.sourceLanguage, .arabic)
        XCTAssertEqual(flip.targetLanguage, .english)
        XCTAssertEqual(flip.sourceLayoutID, LayoutFixtures.arabicSourceID)
        XCTAssertEqual(flip.targetLayoutID, LayoutFixtures.abcSourceID)
        // Latin has no diacritic layer to protect against, so what was typed
        // in shift stays in shift.
        XCTAssertEqual(flip.capsMode, .asTyped)
    }

    /// Direction is read off the script, not off which layout the caller
    /// happened to name first, and not off the current input source — by the
    /// time a flip is asked for, that may already have been switched.
    func testDirectionFollowsTheScriptRatherThanTheArguments() throws {
        let abc = try LayoutFixtures.abc()
        let arabic = try LayoutFixtures.arabic()

        let fromLatin = try XCTUnwrap(
            FlipBuilder.flip(
                latinPhrase, english: abc.layout, arabic: arabic.layout,
                keyboardType: abc.keyboardType))
        let fromArabic = try XCTUnwrap(
            FlipBuilder.flip(
                arabicPhrase, english: abc.layout, arabic: arabic.layout,
                keyboardType: abc.keyboardType))

        XCTAssertEqual(fromLatin.sourceLayoutID, fromArabic.targetLayoutID)
        XCTAssertEqual(fromLatin.targetLayoutID, fromArabic.sourceLayoutID)
    }

    /// The shifted Arabic layer is diacritics, so Caps Lock — which is how a
    /// great deal of this text gets typed — must not reach the render.
    func testCaseIsDroppedOnTheWayIntoArabic() throws {
        let shouted = try XCTUnwrap(flip("HGSGHL "))

        XCTAssertEqual(shouted.flipped, arabicPhrase)
        XCTAssertEqual(shouted.capsMode, .lowercased)
    }

    /// A character no key produces is carried over untouched, and the keys
    /// around it still flip.
    func testUntypeableCharactersPassThrough() throws {
        let flip = try XCTUnwrap(flip("hgsghl\n😀"))

        XCTAssertEqual(flip.flipped, "السلام\n😀")
    }

    func testTextWithoutLettersIsNotWorthFlipping() throws {
        XCTAssertNil(try flip(""))
        XCTAssertNil(try flip("1234 !!"))
    }

    /// A whole document pasted by accident is refused rather than translated
    /// one `UCKeyTranslate` call at a time.
    func testOverlongTextIsRefused() throws {
        XCTAssertNil(try flip(String(repeating: "a", count: 6_000)))
    }

    func testFlippingTwiceReturnsTheOriginal() throws {
        for sample in ["hgsghl", "hello", "world"] {
            let there = try XCTUnwrap(flip(sample), sample)
            let back = try XCTUnwrap(flip(there.flipped), there.flipped)
            XCTAssertEqual(back.flipped, sample)
        }
    }

    /// `é` is composed through a dead key, so the inverse table has no entry
    /// for it. It survives the round trip through the run it sits in.
    func testAComposedCharacterSurvivesInsideLatinText() throws {
        let flip = try XCTUnwrap(flip("caf\u{e9} hgsghl"))

        XCTAssertTrue(flip.flipped.contains("\u{e9}"), flip.flipped)
        XCTAssertTrue(flip.flipped.hasSuffix("السلام"), flip.flipped)
    }

    /// Dominance, not presence: an Arabic sentence with a Latin word in it
    /// flips as Arabic, and the Latin word is left where it is only insofar as
    /// the Arabic layout has no key for its letters.
    func testMostlyArabicTextFlipsToLatin() throws {
        let flip = try XCTUnwrap(flip("السلام okay السلام"))

        XCTAssertEqual(flip.targetLanguage, .english)
        XCTAssertEqual(flip.flipped, "hgsghl okay hgsghl")
    }
}
