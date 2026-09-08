import XCTest

@testable import DodomaCore

final class GuardTests: XCTestCase {
    private func vetoes(_ text: String, recentlyUndone: Set<String> = []) -> Set<GuardReason> {
        Set(TextGuards.evaluate(text, recentlyUndone: recentlyUndone).vetoes)
    }

    func testUrlPathAndEnvironmentTokensVeto() {
        XCTAssertTrue(vetoes("open https://example.com/docs now").contains(.urlOrPath))
        XCTAssertTrue(vetoes("mail ali@example.com today").contains(.urlOrPath))
        XCTAssertTrue(vetoes("cat /usr/local/bin/swift now").contains(.urlOrPath))
        XCTAssertTrue(vetoes("cd C:\\Users\\ali today").contains(.urlOrPath))
        XCTAssertTrue(vetoes("echo $HOME please now").contains(.urlOrPath))
        XCTAssertTrue(vetoes("set flag=true please").contains(.urlOrPath))
        XCTAssertTrue(vetoes("open ~/notes please").contains(.urlOrPath))
    }

    /// A sentence-final full stop is punctuation, not a path separator.
    func testTrailingPunctuationIsNotAPath() {
        XCTAssertFalse(vetoes("we are finally done.").contains(.urlOrPath))
        XCTAssertFalse(vetoes("first item, second item;").contains(.urlOrPath))
        XCTAssertFalse(vetoes("are you sure about that?").contains(.urlOrPath))
    }

    func testDigitsAdjacentToLettersVeto() {
        XCTAssertTrue(vetoes("bump to v2 today").contains(.digitsAdjacent))
        XCTAssertTrue(vetoes("the sha1 hash there").contains(.digitsAdjacent))
        XCTAssertFalse(vetoes("we shipped 42 builds today").contains(.digitsAdjacent))
    }

    func testIdentifierCaseVetoes() {
        XCTAssertTrue(vetoes("call someCamelCaseName here").contains(.identifierCase))
        XCTAssertTrue(vetoes("call snake_case_name here").contains(.identifierCase))
        XCTAssertTrue(vetoes("use ALL_CAPS_CONST here").contains(.identifierCase))
        XCTAssertFalse(vetoes("Sentence case is fine here").contains(.identifierCase))
    }

    func testConsecutivePunctuationVetoes() {
        XCTAssertTrue(vetoes("really?! are you sure").contains(.consecutivePunct))
        XCTAssertTrue(vetoes("wait... let me check").contains(.consecutivePunct))
        XCTAssertFalse(vetoes("one, two, three, four").contains(.consecutivePunct))
    }

    func testShortSingleTokenVetoes() {
        XCTAssertTrue(vetoes("sghl").contains(.shortSingleToken))
        XCTAssertTrue(vetoes("fdjkh").contains(.shortSingleToken))
        XCTAssertFalse(vetoes("hsmdih").contains(.shortSingleToken))
        XCTAssertFalse(vetoes("sghl fdjkh").contains(.shortSingleToken))
    }

    func testCurrentLanguageCoverageVetoes() {
        let english = LanguageModel.shared(.english)
        XCTAssertTrue(
            TextGuards.evaluate("the report is ready", currentModel: english)
                .vetoes.contains(.currentLangCoverage))
        XCTAssertFalse(
            TextGuards.evaluate("hkh hsmdih hgdml", currentModel: english)
                .vetoes.contains(.currentLangCoverage))
    }

    func testMixedScriptTokenVetoes() {
        XCTAssertTrue(vetoes("helloمرحبا there").contains(.mixedScriptToken))
        XCTAssertFalse(vetoes("hello مرحبا there").contains(.mixedScriptToken))
    }

    func testRecentlyUndoneVetoes() {
        XCTAssertTrue(
            vetoes("hkh hsmdih hgdml", recentlyUndone: ["HKH HSMDIH HGDML"])
                .contains(.recentlyUndone))
        XCTAssertFalse(
            vetoes("hkh hsmdih hgdml", recentlyUndone: ["something else"])
                .contains(.recentlyUndone))
    }

    /// What the undo records is a `Fix.replacedText`, which carries the
    /// separator the user typed after the word. The region being re-evaluated a
    /// second later may or may not carry the same one — the user has typed
    /// another character by then, or has not — so both sides are trimmed. Losing
    /// this match means the fix that was just undone is re-applied within the
    /// second, which is the one outcome that makes undo worse than useless.
    func testRecentlyUndoneIgnoresSurroundingWhitespaceOnBothSides() {
        XCTAssertTrue(
            vetoes("hkh hsmdih hgdml", recentlyUndone: ["hkh hsmdih hgdml "])
                .contains(.recentlyUndone), "the recorded text has the trailing separator")
        XCTAssertTrue(
            vetoes("hkh hsmdih hgdml ", recentlyUndone: ["hkh hsmdih hgdml"])
                .contains(.recentlyUndone), "and the other way round")
        XCTAssertFalse(
            vetoes("hkh hsmdih hgdml", recentlyUndone: ["hkh hsmdih hgdm"])
                .contains(.recentlyUndone), "trimming is not truncating")
    }

    func testCleanProseFiresNothing() {
        XCTAssertEqual(vetoes("hkh hsmdih hgdml"), [])
    }

    // MARK: - Decision rule

    func testOneVetoBlocksAutoAndTwoBlockSuggest() {
        let none = GuardResult(vetoes: [])
        XCTAssertFalse(none.blocksAuto)
        XCTAssertFalse(none.blocksSuggest)

        let one = GuardResult(vetoes: [.shortSingleToken])
        XCTAssertTrue(one.blocksAuto)
        XCTAssertFalse(one.blocksSuggest)

        let two = GuardResult(vetoes: [.shortSingleToken, .digitsAdjacent])
        XCTAssertTrue(two.blocksAuto)
        XCTAssertTrue(two.blocksSuggest)
    }

    func testVersionStringTripsEnoughGuardsToBlockSuggestions() {
        let result = TextGuards.evaluate("v2.1.3")
        XCTAssertTrue(result.blocksSuggest, "fired: \(result.summary)")
    }
}

// MARK: - What a delete burst may be counted against

/// The rule the injector and the pipeline both apply before anything is
/// deleted. It is the one place where "how many clusters" and "which text" are
/// made to agree, and where a burst is given a length limit at all.
extension GuardTests {
    private func refusal(_ text: String, count: Int? = nil) -> DeleteRefusal? {
        TextGuards.deleteRefusal(deleting: count ?? text.count, of: text)
    }

    func testOrdinaryTypedTextIsDeletable() {
        XCTAssertNil(refusal("hkh hsmdih hgdml "))
    }

    /// The لا ligature is one scalar that no key types, and it is what the flip
    /// path produces for ل followed by ا. Refusing it would break the flip on
    /// the most common word shape in the language.
    func testTheLamAlefLigatureIsDeletable() {
        XCTAssertNil(refusal("\u{FEFB} "))
    }

    func testARunLongerThanTheCapIsRefused() {
        let cap = TextGuards.maximumDeleteCount
        XCTAssertNil(refusal(String(repeating: "a", count: cap)))
        XCTAssertEqual(refusal(String(repeating: "a", count: cap + 1)), .tooLong)
    }

    /// `deleteCount == replacedText.count` is the `Fix` contract, asserted here
    /// rather than trusted: the two are counted in different places, and a fix
    /// where they disagree deletes a span nobody described.
    func testACountThatDisagreesWithTheTextIsRefused() {
        XCTAssertEqual(refusal("hgs", count: 4), .countMismatch)
        XCTAssertEqual(refusal("hgs", count: 2), .countMismatch)
    }

    /// Applications disagree about whether one backspace removes the cluster,
    /// the scalar or the UTF-16 unit, and the caret verification counts in
    /// UTF-16 while `deleteCount` counts clusters. Where the three cannot agree,
    /// nothing is deleted.
    func testClustersThatAreNotOneBackspaceAreRefused() {
        XCTAssertEqual(refusal("cafe\u{0301} "), .ambiguousCluster, "decomposed é")
        XCTAssertEqual(refusal("\u{0645}\u{064E}\u{0646} "), .ambiguousCluster, "base + haraka")
        XCTAssertEqual(
            refusal("\u{1F468}\u{200D}\u{1F4BB} "), .ambiguousCluster, "a ZWJ emoji sequence")
        XCTAssertEqual(refusal("\u{1F600} "), .ambiguousCluster, "a single non-BMP scalar")
    }
}

// MARK: - What may be counted as this person's vocabulary

extension GuardTests {
    func testTheRunAtTheCaretIsNotLearnedFromYet() {
        XCTAssertNil(TextGuards.learnableProse(in: "endpoint"))
        XCTAssertEqual(TextGuards.learnableProse(in: "we shipped the endpoint"), "we shipped the")
    }

    func testProseIsLearnedFrom() {
        XCTAssertEqual(
            TextGuards.learnableProse(in: "we should merge the branch "),
            "we should merge the branch")
    }

    /// The shapes a passphrase, a path or an identifier take. None of them was
    /// ever guarded — a detection with no candidate region never ran the guards
    /// at all — so this is where they are asked.
    func testTextThatIsNotProseTeachesNothing() {
        XCTAssertNil(TextGuards.learnableProse(in: "Tr0ub4dor&3 "))
        XCTAssertNil(TextGuards.learnableProse(in: "cat /usr/local/bin/swift "))
        XCTAssertNil(TextGuards.learnableProse(in: "let requestHandler = 1 "))
        XCTAssertNil(TextGuards.learnableProse(in: "hunter2 "), "a lone token, and digits in it")
    }

    func testAnEmptyOrWhitespaceRunTeachesNothing() {
        XCTAssertNil(TextGuards.learnableProse(in: ""))
        XCTAssertNil(TextGuards.learnableProse(in: "   "))
    }
}
