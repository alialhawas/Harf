import CoreGraphics
import XCTest

@testable import DodomaAppKit

/// The registry the pipeline consults before it treats a click as input.
///
/// Everything here is about one failure: a rectangle that is wrong, or left
/// behind, either swallows an ordinary click in the application underneath or
/// lets a press of a card's own button destroy the undo slot that button exists
/// to use.
final class CardFramesTests: XCTestCase {
    private let card = CGRect(x: 100, y: 200, width: 300, height: 80)

    func testNothingIsRegisteredToBeginWith() {
        let frames = CardFrames()
        XCTAssertTrue(frames.isEmpty)
        XCTAssertFalse(frames.contains(CGPoint(x: 150, y: 220)))
    }

    func testAClickInsideARegisteredCardIsRecognised() {
        let frames = CardFrames()
        frames.show(.flip, displayFrame: card)

        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.contains(CGPoint(x: 150, y: 220)))
    }

    func testAClickOutsideItIsNot() {
        let frames = CardFrames()
        frames.show(.flip, displayFrame: card)

        XCTAssertFalse(frames.contains(CGPoint(x: 90, y: 220)), "left of the card")
        XCTAssertFalse(frames.contains(CGPoint(x: 150, y: 500)), "below it")
    }

    /// A rectangle that outlived its card would keep swallowing clicks in
    /// whatever the user went on to use that part of the screen for.
    func testHidingRemovesTheRectangle() {
        let frames = CardFrames()
        frames.show(.learned, displayFrame: card)
        frames.hide(.learned)

        XCTAssertTrue(frames.isEmpty)
        XCTAssertFalse(frames.contains(CGPoint(x: 150, y: 220)))
    }

    /// Two cards can be up at once — a flip card and a learned-word card — and
    /// taking one down must not take the other's rectangle with it.
    func testBothCardsAreHonouredIndependently() {
        let frames = CardFrames()
        let other = CGRect(x: 600, y: 700, width: 200, height: 60)
        frames.show(.flip, displayFrame: card)
        frames.show(.learned, displayFrame: other)

        XCTAssertTrue(frames.contains(CGPoint(x: 150, y: 220)))
        XCTAssertTrue(frames.contains(CGPoint(x: 650, y: 720)))

        frames.hide(.flip)
        XCTAssertFalse(frames.contains(CGPoint(x: 150, y: 220)))
        XCTAssertTrue(frames.contains(CGPoint(x: 650, y: 720)), "the learned card is still up")
    }

    /// Showing the same kind twice is the card moving, not a second card.
    func testShowingTheSameKindAgainReplacesItsRectangle() {
        let frames = CardFrames()
        let moved = CGRect(x: 600, y: 700, width: 200, height: 60)
        frames.show(.learned, displayFrame: card)
        frames.show(.learned, displayFrame: moved)

        XCTAssertFalse(frames.contains(CGPoint(x: 150, y: 220)), "the old place is not a card")
        XCTAssertTrue(frames.contains(CGPoint(x: 650, y: 720)))
    }

    /// Written from the main thread as a card appears, read from the pipeline
    /// queue on every mouse-down. The lock is the only thing making that safe.
    func testConcurrentReadsAndWritesDoNotTear() {
        let frames = CardFrames()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                frames.show(.flip, displayFrame: card)
            } else {
                _ = frames.contains(CGPoint(x: 150, y: 220))
                frames.hide(.flip)
            }
        }
    }
}
