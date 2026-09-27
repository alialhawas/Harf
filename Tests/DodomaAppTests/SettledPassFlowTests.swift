import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The second look, three seconds after the last keystroke.
///
/// The first evaluation runs one second in, and a second is not long enough to
/// tell a finished word from a pause in the middle of one — so a short word the
/// user never followed with a space is ignored and then never looked at again
/// until they type more. What is covered here is the shape of the retry: it is
/// scheduled only when the first evaluation ignored the buffer, it happens
/// exactly once per burst of typing, and an ignore from the retry itself does
/// not start a third.
///
/// `PipelineHarness.shortSettledDelay` stands in for the shipped 3 seconds so
/// that the suite does not spend that long per test. The real constant, and its
/// place between `triggerDelay` and the idle timeout, is pinned by
/// `EvaluationTriggerTests`.
final class SettledPassFlowTests: XCTestCase {
    private var harness: PipelineHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(HarnessLayouts.pair == nil, "the committed layout tables are missing")
        harness = PipelineHarness()
        harness.useShortSettledDelay()
        harness.oracle.answer(caret: .value("اثغ"))
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    func testAnIgnoredEvaluationSchedulesASecondPass() {
        harness.type("h")
        harness.waitForTrigger(self)

        XCTAssertEqual(harness.lastDecision?.verdict, "ignore", "precondition")
        XCTAssertTrue(harness.isEvaluationArmed, "the buffer has earned one more look")
    }

    func testTheSecondPassRunsExactlyOnce() {
        harness.type("h")
        harness.waitForTrigger(self)
        XCTAssertEqual(harness.decisions.count, 1, "precondition")

        harness.waitForSettledPass(self)

        XCTAssertEqual(harness.decisions.count, 2, "one more evaluation, not a stream of them")
    }

    /// No loops. The retry is the last word on a burst of typing.
    func testASecondIgnoreDoesNotScheduleAThird() {
        harness.type("h")
        harness.waitForTrigger(self)
        harness.waitForSettledPass(self)
        XCTAssertEqual(harness.decisions.count, 2, "precondition")

        XCTAssertFalse(harness.isEvaluationArmed)
        harness.waitForSettledPass(self)
        XCTAssertEqual(harness.decisions.count, 2, "nothing looked again")
    }

    /// Typing goes back through the ordinary one-second path, and puts the
    /// second pass back on the table for the burst that just started.
    func testANewKeystrokeReArmsTheOrdinaryTriggerAndTheSecondPassWithIt() {
        harness.type("h")
        harness.waitForTrigger(self)
        harness.waitForSettledPass(self)
        XCTAssertEqual(harness.decisions.count, 2, "precondition")

        harness.type("i")
        XCTAssertTrue(harness.isEvaluationArmed, "the ordinary trigger, armed by the keystroke")
        harness.waitForTrigger(self)
        XCTAssertEqual(harness.decisions.count, 3)

        harness.waitForSettledPass(self)
        XCTAssertEqual(harness.decisions.count, 4, "the second pass is available again")
    }

    /// The outcome the whole thing exists for: `اثغ` typed on the Arabic layout
    /// and never followed by a space stands through the first evaluation and is
    /// rewritten to `hey` by the second, through the ordinary auto-apply path.
    func testAWordFinishedWithoutASpaceIsFixedByTheSecondPass() throws {
        try typeUnderArabic("اثغ")
        harness.waitForTrigger(self)

        XCTAssertEqual(harness.lastDecision?.verdict, "ignore", "a space is still required at 1s")
        XCTAssertTrue(harness.applied.isEmpty)

        harness.waitForSettledPass(self)

        XCTAssertEqual(harness.lastDecision?.verdict, "autoApply")
        XCTAssertEqual(harness.engine.lastFix?.insertText, "hey")
        XCTAssertEqual(harness.engine.lastFix?.replacedText, "اثغ")
    }

    /// The second pass is the same text read again, not a second sighting of
    /// it. Counting it twice would quietly halve the ten uses a word needs
    /// before it joins this person's dictionary.
    func testTheSecondPassDoesNotCountTheVocabularyTwice() throws {
        try typeUnderEnglish("kamailio ")
        harness.waitForTrigger(self)
        XCTAssertEqual(
            harness.lexicon.pending(.english).first(where: { $0.word == "kamailio" })?.count, 1,
            "precondition: the first evaluation counted it once")

        harness.waitForSettledPass(self)

        XCTAssertEqual(
            harness.lexicon.pending(.english).first(where: { $0.word == "kamailio" })?.count, 1)
    }

    private func typeUnderEnglish(_ text: String) throws {
        let pair = try XCTUnwrap(HarnessLayouts.pair)
        try type(text, under: pair.english)
    }

    /// Replays `text` as the Arabic layout would produce it, one keystroke at a
    /// time. The timestamps have to be real: the trigger reads the clock, not
    /// the fixture.
    private func typeUnderArabic(_ text: String) throws {
        let pair = try XCTUnwrap(HarnessLayouts.pair)
        try type(text, under: pair.arabic)
    }

    private func type(_ text: String, under layout: KeyboardLayout) throws {
        let keys = try XCTUnwrap(InverseKeymap.keys(for: text, layout: layout))
        for key in keys {
            harness.send(
                .key(
                    CapturedKey(
                        keycode: key.keycode, flags: key.flags, producedText: key.producedText,
                        keyboardType: key.keyboardType,
                        timestamp: Date().timeIntervalSinceReferenceDate)))
        }
    }
}
