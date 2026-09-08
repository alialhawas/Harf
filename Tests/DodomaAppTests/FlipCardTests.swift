import AppKit
import SwiftUI
import XCTest

@testable import DodomaAppKit

/// The card is placed by measuring it before it is ever shown, so a view that
/// fails to lay out becomes a panel sized zero rather than a visible error.
final class FlipCardTests: XCTestCase {
    private func size(_ card: FlipCard) -> CGSize {
        NSHostingView(rootView: card).fittingSize
    }

    func testTheCardLaysOutToAVisibleSize() {
        let measured = size(
            FlipCard(text: "hello there", rightToLeft: false, onLearn: {}, onDismiss: {}))

        XCTAssertGreaterThan(measured.width, 100)
        XCTAssertGreaterThan(measured.height, 20)
    }

    /// Arabic flips lay out right-to-left, and the card must still measure.
    func testArabicTextLaysOutToAVisibleSize() {
        let measured = size(
            FlipCard(text: "السلام عليكم", rightToLeft: true, onLearn: {}, onDismiss: {}))

        XCTAssertGreaterThan(measured.width, 100)
        XCTAssertGreaterThan(measured.height, 20)
    }

    /// A flip carries whatever run the user asked about, which can be a whole
    /// sentence; the card caps its own width and wraps instead of running off
    /// the screen.
    func testALongFlipDoesNotWidenTheCardWithoutBound() {
        let long = String(repeating: "a", count: 200)
        let measured = size(FlipCard(text: long, rightToLeft: false, onLearn: {}, onDismiss: {}))

        XCTAssertLessThanOrEqual(measured.width, 340)
    }
}
