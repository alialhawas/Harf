import XCTest

@testable import DodomaCore

/// The check that stands between a desynchronised buffer and somebody's text.
final class CaretVerificationTests: XCTestCase {
    private func isProceed(_ axText: String?, _ replaced: String, _ mode: VerifyMode = .required)
        -> Bool
    {
        verdict(axText, replaced, mode) == .proceed
    }

    private func reason(_ axText: String?, _ replaced: String, _ mode: VerifyMode = .required)
        -> String?
    {
        if case .downgrade(let reason) = verdict(axText, replaced, mode) { return reason }
        return nil
    }

    /// A nil `axText` here means the element had nothing to give — the
    /// `.unreadable` cause, which is the only one the old `String?` API could
    /// express and the only one `.bestEffort` may proceed on.
    private func verdict(_ axText: String?, _ replaced: String, _ mode: VerifyMode)
        -> CaretVerification.Verdict
    {
        CaretVerification.verdict(
            read: axText.map(CaretRead.value) ?? .unreadable, replacedText: replaced, mode: mode)
    }

    func testExactSuffixMatchProceeds() {
        XCTAssertTrue(isProceed("please send hgsghl", "hgsghl"))
        XCTAssertTrue(isProceed("hgsghl", "hgsghl"), "the field holds nothing else")
    }

    func testMismatchDowngrades() {
        XCTAssertNotNil(reason("please send something else", "hgsghl"))
        XCTAssertNotNil(reason("hgsghl and then more", "hgsghl"), "not at the caret")
        XCTAssertEqual(
            reason("please send HGSGHL", "hgsghl"), "caret text does not end with the typed text",
            "the comparison is case sensitive")
    }

    func testUnreadableElementDowngradesOnTheAutomaticPath() {
        XCTAssertEqual(reason(nil, "hgsghl"), "the focused element exposes no text")
    }

    func testEmptyAccessibilityTextDowngrades() {
        XCTAssertEqual(reason("", "hgsghl"), "caret text is too short to confirm anything")
    }

    func testEmptyReplacementDowngrades() {
        XCTAssertEqual(reason("anything", ""), "the fix replaces nothing")
        XCTAssertEqual(reason(nil, ""), "the fix replaces nothing", "checked before the read")
        XCTAssertEqual(
            reason(nil, "", .bestEffort), "the fix replaces nothing",
            "an explicit request for nothing is still nothing")
    }

    /// Three agreeing characters is a coincidence, not a confirmation.
    func testShorterCaretTextDowngrades() {
        XCTAssertEqual(reason("ghl", "hgsghl"), "caret text is too short to confirm anything")
    }

    /// A short answer that agrees is still evidence.
    ///
    /// Terminals report only the current line or the visible cells, so they
    /// answer with a few characters however much was typed. Refusing those
    /// outright disqualified every such app and pushed the user towards turning
    /// the check off by hand, which is strictly worse than believing an answer
    /// that matches.
    func testShorterCaretTextThatAgreesIsAccepted() {
        XCTAssertNil(reason("sghl", "hgsghl"), "the tail the app can see matches")
        XCTAssertNil(reason("ويها اليوم", "اذ ودك انا اسويها اليوم"))
    }

    /// A short answer that disagrees is a contradiction and must still stop it.
    func testShorterCaretTextThatDisagreesDowngrades() {
        XCTAssertEqual(
            reason("xxxx", "hgsghl"), "caret text does not end with the typed text")
        XCTAssertEqual(
            reason("hgsg", "hgsghl"), "caret text does not end with the typed text",
            "matching the start is not matching the caret")
    }

    /// The buffer routinely ends in the separator the user typed after the
    /// word, and `Fix.replacedText` includes it, so this is the common shape.
    func testArabicTextWithATrailingSpace() {
        XCTAssertTrue(isProceed("قال السلام عليكم ", "السلام عليكم "))
        XCTAssertNotNil(
            reason("قال السلام عليكم", "السلام عليكم "), "the trailing space is part of the match")
    }

    /// Swift's `hasSuffix` compares canonically, so a decomposed rendering
    /// would match a composed one — and then the delete count, which is counted
    /// in what the user typed, would be wrong for what is on screen.
    func testComparisonIsNotUnicodeNormalising() {
        let composed = "\u{0623}"  // ARABIC LETTER ALEF WITH HAMZA ABOVE
        let decomposed = "\u{0627}\u{0654}"  // ALEF + HAMZA ABOVE
        XCTAssertTrue(composed.hasSuffix(decomposed), "precondition: Swift would call these equal")
        XCTAssertNotNil(reason(composed, decomposed))
    }

    func testMatchAcrossACombiningBoundaryIsNotSplit() {
        // The caret text ends mid-cluster relative to the replacement, so the
        // UTF-16 suffix cannot line up.
        XCTAssertNotNil(reason("abc\u{0627}", "\u{0627}\u{0654}"))
    }
}

/// Every cause the accessibility read can come back with, against both modes.
///
/// This table is the ruling M7 inherited: an explicit request — an accepted
/// suggestion, an undo — may proceed where accessibility is *structurally
/// silent*, and nowhere else. A live selection or a busy accessibility layer is
/// evidence of danger, not absence of evidence, so it stays fail-closed in both
/// modes even though the user asked by name.
final class CaretVerifyModeTableTests: XCTestCase {
    private static let replaced = "hgsghl"

    private func proceeds(_ read: CaretRead, _ mode: VerifyMode) -> Bool {
        CaretVerification.verdict(read: read, replacedText: Self.replaced, mode: mode) == .proceed
    }

    func testTheWholeTable() {
        let rows: [(read: CaretRead, required: Bool, bestEffort: Bool, note: String)] = [
            (.value("please send hgsghl"), true, true, "a match is a match either way"),
            (.value("please send hgsghk"), false, false, "a mismatch is the danger this exists for"),
            (.value("ghl"), false, false, "a short read cannot be matched"),
            (.value(""), false, false, "an empty read cannot be matched"),
            (.unreadable, false, true, "structural silence: the only best-effort exception"),
            (.selectionPresent, false, false, "the burst would eat the selection first"),
            (.unavailable, false, false, "no answer is not the same as no text"),
        ]

        for row in rows {
            XCTAssertEqual(
                proceeds(row.read, .required), row.required,
                "required/\(row.read): \(row.note)")
            XCTAssertEqual(
                proceeds(row.read, .bestEffort), row.bestEffort,
                "bestEffort/\(row.read): \(row.note)")
        }
    }

    /// `.bestEffort` is allowed to be more permissive than `.required` and
    /// never less: a rule that flipped the other way for some cause would mean
    /// the automatic path deleting text the explicit one refuses to.
    func testBestEffortIsNeverStricterThanRequired() {
        let reads: [CaretRead] = [
            .value("please send hgsghl"), .value("nope"), .unreadable, .selectionPresent,
            .unavailable,
        ]
        for read in reads where proceeds(read, .required) {
            XCTAssertTrue(proceeds(read, .bestEffort), "\(read) is monotone")
        }
    }

    // MARK: - Undo's extra condition

    /// `.bestEffort` proceeds without comparing anything in two cases, and both
    /// of them stop being true the moment the user types another character:
    /// the correction is no longer the last thing in front of the caret, so the
    /// inverse's backspaces would eat what came after it. In an application
    /// where the caret cannot be read there is no second chance to notice.
    func testUndoRequiresAnUnmovedSerialWhereverNothingWasCompared() {
        let rows: [(read: CaretRead, verified: Bool, quiet: Bool, proceeds: Bool, note: String)] = [
            (.value("please send hgsghl"), true, true, true, "a match, and nothing happened"),
            (.value("please send hgsghl"), true, false, true,
             "a match is direct evidence: typing and deleting back is still undoable"),
            (.value("nope"), true, true, false, "a mismatch is a mismatch"),
            (.unreadable, true, true, true, "silent, but nothing has happened since"),
            (.unreadable, true, false, false, "silent AND the screen moved: the dangerous one"),
            (.selectionPresent, true, true, false, "fail-closed either way"),
            (.selectionPresent, true, false, false, "fail-closed either way"),
            (.unavailable, true, true, false, "fail-closed either way"),
            (.unavailable, true, false, false, "fail-closed either way"),
            (.unavailable, false, true, true, "axVerifySkip: nothing asked, nothing happened"),
            (.unavailable, false, false, false, "axVerifySkip AND the screen moved"),
        ]

        for row in rows {
            let verdict = CaretVerification.undoVerdict(
                read: row.read, replacedText: Self.replaced, verified: row.verified,
                inputSinceFix: !row.quiet)
            XCTAssertEqual(
                verdict == .proceed, row.proceeds,
                "\(row.read)/verified=\(row.verified)/quiet=\(row.quiet): \(row.note)")
        }
    }

    /// Undo is never more permissive than an accepted suggestion would be.
    func testUndoIsNeverLooserThanBestEffort() {
        let reads: [CaretRead] = [
            .value("please send hgsghl"), .value("nope"), .unreadable, .selectionPresent,
            .unavailable,
        ]
        for read in reads where !proceeds(read, .bestEffort) {
            for quiet in [true, false] {
                let verdict = CaretVerification.undoVerdict(
                    read: read, replacedText: Self.replaced, verified: true, inputSinceFix: !quiet)
                XCTAssertNotEqual(verdict, .proceed, "\(read), quiet=\(quiet)")
            }
        }
    }

    func testUndoOfAnEmptyReplacementIsStillNothing() {
        XCTAssertNotEqual(
            CaretVerification.undoVerdict(
                read: .value(""), replacedText: "", verified: true, inputSinceFix: false),
            .proceed)
    }

    /// The reasons reach the log and the debug window, and they are how a user
    /// finds out why nothing happened. Each cause has to say something
    /// different, or the log cannot tell them apart.
    func testEachCauseHasItsOwnReason() {
        let reads: [CaretRead] = [.unreadable, .selectionPresent, .unavailable, .value("nope")]
        var reasons: Set<String> = []
        for read in reads {
            guard
                case .downgrade(let reason) = CaretVerification.verdict(
                    read: read, replacedText: Self.replaced, mode: .required)
            else {
                return XCTFail("\(read) should not proceed")
            }
            reasons.insert(reason)
        }
        XCTAssertEqual(reasons.count, reads.count)
    }
}
