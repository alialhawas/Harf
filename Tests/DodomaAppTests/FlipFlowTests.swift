import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The manual flip, from the chord to the screen.
///
/// What the flip *is* — which characters map to which — is pure and covered in
/// `FlipBuilderTests`. What is covered here is everything that only exists once
/// the pipeline is wired up: which question is asked of the application first,
/// which injector call the answer chooses, and what is recorded afterwards.
///
/// The two paths are deliberately not symmetrical, and most of this file is
/// about the difference. A selection is a span the user pointed at, so it is
/// typed over; the typed run is a span inferred from the buffer alone, so it
/// has to be verified against the caret before a single backspace is posted.
final class FlipFlowTests: XCTestCase {
    private var harness: PipelineHarness!

    /// `السلام` typed with the English layout still selected, and what it
    /// should have been.
    private let latin = "hgsghl "
    private let arabic = "السلام "

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try XCTUnwrap(
            HarnessLayouts.pair,
            "the layout snapshot is missing or malformed; run `make fixtures`")
        harness = PipelineHarness()
        // The focused field is not a password field, and — for the selection
        // path — the flipped text is what the read-back afterwards finds.
        harness.oracle.answer(caret: Fixtures.caretAfterFix)
        harness.oracle.selectionAnswer = .selected(latin)
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    private func typeAKey(_ text: String) {
        harness.pipeline.handle(
            .key(
                CapturedKey(
                    keycode: 0, producedText: text,
                    timestamp: Date().timeIntervalSinceReferenceDate)))
    }

    // MARK: - The selection

    func testASelectionIsFlippedByTypingOverIt() {
        harness.flip()

        XCTAssertEqual(harness.engine.replaced.count, 1)
        XCTAssertEqual(harness.engine.replaced.first?.text, arabic)
        XCTAssertEqual(harness.engine.replaced.first?.targetLayoutID, Fixtures.arabic)
        XCTAssertTrue(
            harness.engine.applied.isEmpty,
            "typing replaces the selection, so a backspace here would eat what came before it")
    }

    func testTheAccessibilitySelectionIsPreferredToTheClipboard() {
        harness.flip()

        XCTAssertEqual(harness.engine.replaced.count, 1)
        XCTAssertEqual(
            harness.engine.copyCalls, 0,
            "⌘C costs the better part of a second and disturbs the pasteboard")
    }

    /// The one case the clipboard is for: an element that exposes no text at
    /// all, so accessibility cannot say whether anything is selected.
    func testTheClipboardIsUsedWhenTheSelectionCannotBeRead() {
        harness.oracle.selectionAnswer = .unreadable
        harness.engine.copyResult = .copied(latin)
        harness.flip()

        XCTAssertEqual(harness.engine.replaced.first?.text, arabic)
        XCTAssertEqual(harness.engine.copyCalls, 1)
    }

    func testAnEmptySelectionDoesNotReachForTheClipboard() {
        harness.oracle.selectionAnswer = .noSelection
        harness.flip()

        XCTAssertEqual(
            harness.engine.copyCalls, 0, "the application answered; there is nothing to ask again")
    }

    /// The caret text is what the *typed-run* path verifies against. Asking for
    /// it before a selection is injected would be reading the text around a
    /// span that is about to be replaced wholesale.
    func testTheSelectionPathDoesNotAskForCaretTextBeforeInjecting() {
        harness.flip()

        XCTAssertEqual(harness.oracle.requestedLengths.count, 2)
        XCTAssertNil(
            harness.oracle.requestedLengths[0], "the first question is about security alone")
        XCTAssertEqual(
            harness.oracle.requestedLengths[1], arabic.utf16.count,
            "and the second is the read-back, after the text has landed")
    }

    // MARK: - Afterwards

    func testAFlippedSelectionCanBeTakenBack() {
        harness.flip()
        XCTAssertEqual(harness.pipeline.undoableFix()?.fix.replacedText, latin)

        harness.waitForApplyTail(self)
        harness.undo()

        XCTAssertEqual(harness.engine.lastFix?.insertText, latin)
        XCTAssertEqual(harness.engine.lastFix?.deleteCount, arabic.count)
        XCTAssertEqual(
            harness.engine.lastFix?.targetLayoutID, Fixtures.english, "and the layout goes back")
    }

    func testAFlipIsReportedAsAnAppliedFix() {
        harness.flip()

        XCTAssertEqual(harness.applied.count, 1, "the flash and the `Last fix` line come from this")
        XCTAssertEqual(harness.applied.first?.fix.insertText, arabic)
    }

    func testAFlipIsPublishedToTheCard() {
        harness.flip()

        let flip = harness.awaitFlipCard(self)
        XCTAssertEqual(flip?.flipped, arabic)
        XCTAssertEqual(flip?.original, latin)
    }

    /// The injector reported success and the text is somewhere else — an
    /// application that had already dropped the selection. Nothing was
    /// verified before the burst, because a selection needs no verifying, so
    /// this read-back is the only thing standing between that and an undo slot
    /// pointed at text nobody has seen.
    func testAFlipThatDidNotLandArmsNoUndo() {
        harness.oracle.answer(caret: .value("somewhere else entirely"))
        harness.flip()

        XCTAssertEqual(harness.engine.replaced.count, 1, "the keys were posted")
        XCTAssertNil(harness.pipeline.undoableFix())
        XCTAssertEqual(harness.rejectionCount, 1)
        harness.waitForApplyTail(self)
        XCTAssertTrue(harness.flips.isEmpty, "and no card claims a flip that is not there")
    }

    func testTheFlippedTextIsNotOfferedAgain() {
        harness.flip()
        harness.waitForApplyTail(self)

        harness.offer(Fixtures.fix)
        XCTAssertTrue(
            harness.offers.isEmpty,
            "the user just asked for this text to be flipped; offering to flip it again is a loop")

        harness.offer(Fixtures.otherFix)
        XCTAssertEqual(harness.offers.count, 1, "and only that text is held back")
    }

    // MARK: - The typed run

    func testTheTypedRunIsFlippedWhenNothingIsSelected() {
        harness.oracle.selectionAnswer = .noSelection
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        harness.type(latin)
        harness.flip()

        XCTAssertEqual(harness.engine.applied.count, 1)
        XCTAssertEqual(harness.engine.lastFix?.deleteCount, latin.count)
        XCTAssertEqual(harness.engine.lastFix?.insertText, arabic)
        XCTAssertTrue(harness.engine.replaced.isEmpty, "there was no selection to type over")
        XCTAssertTrue(
            harness.oracle.requestedLengths.contains(latin.utf16.count),
            "and the caret was verified against the run first")
    }

    /// `.required`, not `.bestEffort`: this path deletes text the user pointed
    /// at with a chord rather than with a cursor, so an element that exposes
    /// nothing is not reason enough.
    func testTheTypedRunIsRefusedWhenTheCaretExposesNoText() {
        harness.oracle.selectionAnswer = .noSelection
        harness.oracle.answer(caret: .unreadable)
        harness.type(latin)
        harness.flip()

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    func testTheTypedRunIsRefusedWhenTheCaretDisagrees() {
        harness.oracle.selectionAnswer = .noSelection
        harness.oracle.answer(caret: .value("please send something else"))
        harness.type(latin)
        harness.flip()

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    /// The skip list trades the caret check away for applications that cannot
    /// answer it. That trade is fine where the user pointed at the text; it is
    /// not fine for a span inferred from the buffer alone.
    func testTheTypedRunIsRefusedInAnAppThatSkipsVerification() {
        harness = PipelineHarness(axVerifySkip: [Fixtures.app])
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        harness.oracle.selectionAnswer = .noSelection
        harness.type(latin)
        harness.flip()

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertTrue(harness.engine.replaced.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    /// Nothing selected and nothing typed. The chord is global, and most
    /// presses of it in that state are meant for the application underneath.
    func testAFlipWithNothingToFlipIsSilent() {
        harness.oracle.selectionAnswer = .noSelection
        harness.flip()

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertTrue(harness.engine.replaced.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 0)
    }

    // MARK: - Safety

    func testAPausedPipelineFlipsNothing() {
        var paused = harness.settings.settings
        paused.paused = true
        harness.pipeline.apply(paused)
        harness.drain()

        harness.flip()

        XCTAssertEqual(harness.rejectionCount, 1)
        XCTAssertEqual(harness.oracle.selectionRequests, 0)
        XCTAssertEqual(harness.engine.copyCalls, 0)
        XCTAssertTrue(harness.engine.replaced.isEmpty)
    }

    func testAnAppSetToOffFlipsNothing() {
        harness.settings.setPolicy(.off, for: Fixtures.app)
        harness.pipeline.apply(harness.settings.settings)
        harness.drain()

        harness.flip()

        XCTAssertEqual(harness.rejectionCount, 1)
        XCTAssertTrue(
            harness.oracle.requestedLengths.isEmpty, "nothing is asked of an app set to Off")
        XCTAssertEqual(harness.oracle.selectionRequests, 0)
    }

    /// `.suggestOnly` caps what the detector may do unasked. A command the user
    /// named is not the detector acting on its own.
    func testASuggestOnlyAppStillFlips() {
        harness.settings.setPolicy(.suggestOnly, for: Fixtures.app)
        harness.pipeline.apply(harness.settings.settings)
        harness.drain()

        harness.flip()

        XCTAssertEqual(harness.engine.replaced.first?.text, arabic)
    }

    /// Read fresh rather than from the monitor's cache, which is a second wide:
    /// finishing a password and reaching for the chord is precisely how you
    /// land inside that second.
    func testSecureInputFlipsNothing() {
        harness.secureInput.set(true)
        harness.flip()

        XCTAssertEqual(harness.rejectionCount, 1)
        XCTAssertTrue(harness.oracle.requestedLengths.isEmpty)
        XCTAssertEqual(harness.oracle.selectionRequests, 0)
        XCTAssertEqual(harness.engine.copyCalls, 0)
    }

    /// The password-field check comes before the selection is read, not after:
    /// putting a password field's selection on the pasteboard is itself the
    /// leak, whatever is done with it afterwards.
    func testAPasswordFieldIsNeverAskedWhatItHasSelected() {
        harness.oracle.answer(caret: .unavailable, security: .secure)
        harness.flip()

        XCTAssertEqual(harness.rejectionCount, 1)
        XCTAssertEqual(harness.oracle.selectionRequests, 0)
        XCTAssertEqual(harness.engine.copyCalls, 0)
        XCTAssertTrue(harness.engine.replaced.isEmpty)
    }

    /// "The question could not be asked" is not "there is nothing selected".
    /// Falling back to the buffer here would rewrite a different span of the
    /// document from the one the user meant.
    func testACopyThatCouldNotBeTriedDoesNotFallBackToTheBuffer() {
        harness.oracle.selectionAnswer = .unreadable
        harness.engine.copyResult = .couldNotTry(.modifierHeld)
        harness.type(latin)
        harness.flip()

        XCTAssertTrue(harness.engine.applied.isEmpty, "the typed run is not flipped instead")
        XCTAssertTrue(harness.engine.replaced.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    /// The card is about text that is about to change underneath it, and the
    /// tap swallows the flip chord, so nothing else takes it down.
    func testAFlipDismissesAnOpenSuggestion() {
        harness.offer(Fixtures.fix)
        harness.flip()

        XCTAssertEqual(harness.hideCount, 1)

        harness.send(.suggestionAccept)
        XCTAssertFalse(
            harness.engine.applied.contains { $0.fix == Fixtures.fix },
            "there is nothing left to accept")
    }

    func testInputDuringTheSelectionReadAbandonsTheFlip() {
        harness.oracle.beforeSelectionAnswer = { [weak self] in
            // On the pipeline queue, which is where the read is answered, so
            // this is a keystroke landing inside the round trip.
            self?.typeAKey("z")
        }
        harness.flip()

        XCTAssertTrue(harness.engine.replaced.isEmpty, "the selection has moved")
        XCTAssertTrue(
            harness.isEvaluationArmed,
            "and the keystroke's own arming was swallowed by the gate, so the flip re-arms it")
    }

    func testAFailedInjectionArmsNoUndoAndSaysSo() {
        harness.engine.replaceResult = .failure(
            FixFailure(error: .modifierHeld, progress: FixProgress()))
        harness.flip()

        XCTAssertEqual(harness.rejectionCount, 1, "the user asked for this by name")
        XCTAssertNil(harness.pipeline.undoableFix())
        harness.waitForApplyTail(self)
        XCTAssertTrue(harness.flips.isEmpty)
    }
}
