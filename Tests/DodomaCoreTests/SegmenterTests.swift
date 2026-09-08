import XCTest

@testable import DodomaCore

final class SegmenterTests: XCTestCase {
    func testMixedBufferSelectsOnlyTheTrailingBadToken() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("check this HSMDIH")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HSMDIH")
        XCTAssertEqual(region.letterCount, 6)
        XCTAssertEqual(region.tokenCount, 1)
        XCTAssertEqual(region.completedTokenCount, 0)
    }

    /// Regression: a one-letter token used to end the backwards walk.
    ///
    /// Typing "how i did what" on the Arabic layout came back as
    /// "اخص ه did what" — the lone "i" scored the same in both languages, the
    /// walk treated the tie as a boundary, and everything before it was
    /// stranded in the wrong script. A single letter is evidence of nothing
    /// and must not be a wall.
    func testASingleLetterTokenDoesNotStopTheWalk() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("HSMDIH H HGDML")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HSMDIH H HGDML")
        XCTAssertEqual(region.tokenCount, 3)
    }

    /// The other half of the same rule: a leading single letter that the
    /// alternate layout does not actually improve stays out of the region.
    func testALeadingSignalFreeTokenIsNotAbsorbed() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("a HSMDIH HGDML")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HSMDIH HGDML")
    }

    func testFullGibberishBufferSelectsEverything() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("HC MV; HKH HSMDIH HGDML")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HC MV; HKH HSMDIH HGDML")
        XCTAssertEqual(region.tokenCount, 5)
        XCTAssertEqual(region.completedTokenCount, 4)
        XCTAssertEqual(region.letterCount, 18)
    }

    /// Regression: a real word of the current language used to end the region.
    ///
    /// Typing "what is pr dojs" on the Arabic layout produces
    /// "صاشف هس حق يختس", and حق is a genuine Arabic word. Treating it as the
    /// boundary of deliberate typing left three quarters of one English
    /// sentence unconverted and offered only the trailing token, which at four
    /// letters was too short to act on. The region-level comparison has to
    /// reach past it.
    func testARealWordOfTheCurrentLanguageDoesNotStrandTheRestOfTheRun() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("صاشف هس حق يختس")
        let region = try XCTUnwrap(fixture.segment(keys, typedLanguage: .arabic))

        XCTAssertEqual(region.typedText, "صاشف هس حق يختس")
        XCTAssertEqual(region.tokenCount, 4)
    }

    /// The other half: reaching past a word has to cost something.
    ///
    /// Here the trailing token already reads perfectly under the other layout,
    /// so dragging real current-language text into the region can only make it
    /// worse, and the region stays where the walk put it.
    func testAStrongWordOfTheCurrentLanguageStillBoundsTheRegion() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("HSMDIH ha HGDML HSMDIH")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HGDML HSMDIH")
    }

    /// Regression: the walk refused to start when the last token was a word.
    ///
    /// The walk reads right to left from the caret, so a real word of the
    /// language on screen in the *final* position stopped it on the first step
    /// and nothing was ever accepted. "now i can merged ths dev to main" typed
    /// on the Arabic layout ends in وشهر, which strips to شهر — "month" — and
    /// the whole sentence was passed over.
    func testARealWordInTheFinalPositionDoesNotSuppressTheWholeRun() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("رخص ه ذشر وثقلثي فاس يثد فخ وشهر")
        let region = try XCTUnwrap(fixture.segment(keys, typedLanguage: .arabic))

        XCTAssertTrue(
            region.typedText.hasSuffix("وشهر"),
            "the region has to reach the caret, got \(region.typedText)")
        XCTAssertGreaterThanOrEqual(region.tokenCount, 6)
    }

    func testPureEnglishBufferHasNoCandidate() throws {
        let fixture = try DetectorFixture.make()
        for text in [
            "please send me the report",
            "the quick brown fox jumps",
            "let me know if you have any questions",
        ] {
            let keys = try fixture.latinKeys(text)
            XCTAssertNil(fixture.segment(keys), text)
        }
    }

    /// The region has to reach the caret. `deleteCount` counts clusters
    /// immediately behind it, so a region that stopped at the last letter
    /// would delete one letter too many and strand the space:
    /// "hgsghl " − 6 = "h", + "السلام" = "hالسلام".
    func testTrailingSpaceIsPartOfTheRegion() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("check this HSMDIH ")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HSMDIH ")
        XCTAssertEqual(region.letterCount, 6, "the space is not a letter")
        XCTAssertEqual(region.tokenCount, 1, "the space does not open a token")
        XCTAssertEqual(region.completedTokenCount, 1, "the word was finished with a space")
    }

    func testApplyingTheFixLeavesTheCorrectText() throws {
        let fixture = try DetectorFixture.make()
        let cases: [(typed: String, expected: String)] = [
            ("hgsghl ", "السلام "),
            ("check this lvnsi ", "check this مدرسه "),
            ("check this lvnsi  ", "check this مدرسه  "),
            ("HC MV; HKH HSMDIH HGDML", "اذ ودك انا اسويها اليوم"),
            ("HC MV; HKH HSMDIH HGDML ", "اذ ودك انا اسويها اليوم "),
        ]
        for row in cases {
            let detection = try XCTUnwrap(fixture.detect(row.typed), row.typed)
            let fix = try XCTUnwrap(detection.decision.fix, row.typed)
            XCTAssertEqual(fix.deleteCount, fix.replacedText.count, row.typed)

            var text = row.typed
            text.removeLast(fix.deleteCount)
            text += fix.insertText
            XCTAssertEqual(text, row.expected, "applying the fix to \(row.typed)")
        }
    }

    func testMultipleTrailingSpacesAreAllCarried() throws {
        let fixture = try DetectorFixture.make()
        let region = try XCTUnwrap(fixture.segment(try fixture.latinKeys("hgsghl   ")))
        XCTAssertEqual(region.typedText, "hgsghl   ")
        XCTAssertEqual(region.letterCount, 6)
    }

    func testEmptyAndWhitespaceOnlyBuffersHaveNoCandidate() throws {
        let fixture = try DetectorFixture.make()
        XCTAssertNil(fixture.segment([]))
        XCTAssertNil(fixture.segment(try fixture.latinKeys("   ")))
    }

    func testArabicJunkTypedUnderTheArabicLayoutSelectsEverything() throws {
        let fixture = try DetectorFixture.make()
        // "hello how are you" typed while the Arabic layout was active.
        let typed = "اثممخ اخص شقث غخع"
        let keys = try fixture.arabicKeys(typed)
        let region = try XCTUnwrap(fixture.segment(keys, typedLanguage: .arabic))

        XCTAssertEqual(region.typedText, typed)
        XCTAssertEqual(region.tokenCount, 4)
    }

    func testRealArabicUnderTheArabicLayoutHasNoCandidate() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("صباح الخير كيف كان يومك")
        XCTAssertNil(fixture.segment(keys, typedLanguage: .arabic))
    }

    /// The walk must stop at the first recognised word, not scan the whole
    /// buffer: everything before a real word was typed on purpose.
    func testWalkStopsAtTheFirstRecognisedWord() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("hkh hsmdih report hkh hsmdih")
        let region = try XCTUnwrap(fixture.segment(keys))
        XCTAssertEqual(region.typedText, "hkh hsmdih")
    }

    /// Regression: an accidental token that parses as valid morphology of the
    /// language on screen used to collapse the region to nothing usable.
    ///
    /// "how we trun it" typed on the Arabic layout gives اخص صث فقعر هف. فقعر
    /// is not in the dictionary, but stripping its ف clitic leaves قعر —
    /// "depth" — so it reads as real Arabic and walled the walk off. The
    /// region became هف alone: two letters, discarded for being too short,
    /// and nothing was offered for a sentence that is plainly English.
    func testAnAccidentalRealWordDoesNotCollapseTheRegion() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("اخص صث فقعر هف")
        let region = try XCTUnwrap(fixture.segment(keys, typedLanguage: .arabic))

        XCTAssertEqual(region.typedText, "اخص صث فقعر هف")
        XCTAssertEqual(region.tokenCount, 4)
    }

    /// The counting that makes the case above work, stated directly: three
    /// tokens for English against the one accident. Averaging the same run
    /// yields a 0.32 separation, which no auto rule accepts.
    func testTheTallyCountsTokensRatherThanAveragingThem() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("اخص صث فقعر هف")
        let region = try XCTUnwrap(fixture.segment(keys, typedLanguage: .arabic))

        XCTAssertEqual(region.alternateVotes, 3)
        XCTAssertEqual(region.currentVotes, 1)
    }

    /// The limit on that rule. A majority may reach past a word only when the
    /// word could plausibly have been produced by the wrong layout. "report"
    /// renders to قثحخقف, which scores zero as Arabic, so it bounds the region
    /// however many gibberish tokens surround it — here four against one.
    func testAMajorityDoesNotReachPastADeliberateWord() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("hkh hsmdih report hkh hsmdih")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "hkh hsmdih")
    }

}
