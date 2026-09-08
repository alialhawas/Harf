import AppKit
import SwiftUI
import XCTest

@testable import DodomaAppKit

/// The card is placed by measuring it before it is ever shown, so a view that
/// fails to lay out becomes a panel sized zero rather than a visible error.
final class LearnedCardTests: XCTestCase {
    private func size(_ card: LearnedCard) -> CGSize {
        NSHostingView(rootView: card).fittingSize
    }

    func testTheCardLaysOutToAVisibleSize() {
        let measured = size(LearnedCard(words: ["kubectl"], rightToLeft: false, onUndo: {}))

        XCTAssertGreaterThan(measured.width, 100)
        XCTAssertGreaterThan(measured.height, 20)
    }

    /// Several words at once must not push the card off screen; the view caps
    /// its own width and wraps instead.
    func testManyWordsDoNotWidenTheCardWithoutBound() {
        let many = ["kubectl", "endpoint", "webhooks", "namespace", "kustomize"]
        let measured = size(LearnedCard(words: many, rightToLeft: false, onUndo: {}))

        XCTAssertLessThanOrEqual(measured.width, 340)
    }

    /// Arabic entries lay out right-to-left, and the card must still measure.
    func testArabicWordsLayOutToAVisibleSize() {
        let measured = size(LearnedCard(words: ["تجريب"], rightToLeft: true, onUndo: {}))

        XCTAssertGreaterThan(measured.width, 100)
        XCTAssertGreaterThan(measured.height, 20)
    }
}
