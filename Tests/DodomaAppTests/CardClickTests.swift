import CoreGraphics
import DodomaCore
import XCTest

@testable import DodomaAppKit

/// What a click on one of Harf's own cards does to the pipeline's state.
///
/// The rule is that it does nothing. The ordinary mouse-down path bumps the
/// input serial and ends the undo window, so a click routed through it destroys
/// the undo slot — which is exactly what the Undo button on a card is for.
final class CardClickTests: XCTestCase {
    private var harness: PipelineHarness!
    private let card = CGRect(x: 100, y: 200, width: 300, height: 80)

    override func setUp() {
        super.setUp()
        harness = PipelineHarness()
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    /// Gets a fix onto the screen the way the user would, so there is an undo
    /// slot for the click to threaten.
    private func applyAFix() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)
        XCTAssertEqual(harness.engine.applied.count, 1, "precondition: a fix was applied")
        harness.waitForApplyTail(self)
        harness.oracle.answer(caret: Fixtures.caretAfterFix)
    }

    func testAClickOnARegisteredCardKeepsTheUndo() {
        applyAFix()
        harness.cardFrames.show(.flip, displayFrame: card)
        harness.click(at: CGPoint(x: 150, y: 220))

        XCTAssertNotNil(
            harness.pipeline.undoableFix(),
            "pressing a button on Harf's own card must not spend the ⌘⌥Z slot")
    }

    /// The exemption is the rectangle and nothing wider. A click next to the
    /// card is the user moving the caret, and it withdraws the undo like any
    /// other click.
    func testAClickOutsideItStillWithdrawsTheUndo() {
        applyAFix()
        harness.cardFrames.show(.flip, displayFrame: card)
        harness.click(at: CGPoint(x: 90, y: 220))

        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// And once the card is gone its rectangle is gone with it: the same point
    /// is ordinary screen again.
    func testHidingTheCardGivesTheRectangleBack() {
        applyAFix()
        harness.cardFrames.show(.flip, displayFrame: card)
        harness.cardFrames.hide(.flip)
        harness.click(at: CGPoint(x: 150, y: 220))

        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// The suggestion card is deliberately not in `CardFrames`: its clicks are
    /// not ignored, they are the second way to accept. A card registry that
    /// swallowed them first would make the card unclickable.
    func testAClickOnTheSuggestionCardStillAcceptsTheFix() {
        harness.offer(Fixtures.fix)
        harness.suggestionState.show(displayFrame: card)
        XCTAssertTrue(harness.cardFrames.isEmpty, "precondition: no card registry entry")

        harness.click(at: CGPoint(x: 150, y: 220))

        XCTAssertEqual(harness.engine.applied.count, 1)
        XCTAssertEqual(harness.engine.lastFix, Fixtures.fix)
    }
}
