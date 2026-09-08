import XCTest

@testable import DodomaAppKit
@testable import DodomaCore

/// An application that reports no focused element says one of two things, and
/// which one it is decides whether an accepted suggestion may proceed.
final class FocusOracleTests: XCTestCase {
    /// Ghostty answers no focused element and no windows: it draws its own
    /// cells and exposes no accessibility text surface at all. Nothing was
    /// compared, but nothing contradicted either, so a rewrite the user asked
    /// for by pressing the accept key is allowed to go ahead.
    func testAnAppWithNoAccessibilityTreeReadsAsStructurallySilent() {
        let inspection = FocusOracle.withoutFocusedElement(trusted: true)

        XCTAssertEqual(inspection.caretRead, .unreadable)
        XCTAssertEqual(
            CaretVerification.verdict(read: .unreadable, replacedText: "hgsghl", mode: .bestEffort),
            .proceed,
            "an accepted suggestion must apply in an app that exposes no text")
    }

    /// The same nil without the grant means only that Harf is blind. The
    /// application may have text and a caret; nothing may be concluded from
    /// silence that is ours rather than theirs.
    func testWithoutTheGrantTheSameSilenceIsARefusal() {
        XCTAssertEqual(FocusOracle.withoutFocusedElement(trusted: false).caretRead, .unavailable)

        guard case .downgrade = CaretVerification.verdict(
            read: .unavailable, replacedText: "hgsghl", mode: .bestEffort)
        else { return XCTFail("an unreadable caret without the grant must not proceed") }
    }

    /// The loosening applies only to what the user explicitly asked for. A
    /// silent automatic rewrite in an app whose text cannot be read is exactly
    /// the thing the check exists to prevent, and a terminal is the worst place
    /// to get it wrong.
    func testAutomaticRewritesStayBlockedInSuchAnApp() {
        guard case .downgrade = CaretVerification.verdict(
            read: .unreadable, replacedText: "hgsghl", mode: .required)
        else { return XCTFail("the automatic path must still refuse an unreadable caret") }
    }

    /// The secure-field check fails open on `.unknown`, which is what this
    /// path reports. Password protection in these apps rests on secure event
    /// input, which is checked separately and without accessibility.
    func testSecurityIsUnknownRatherThanAsserted() {
        XCTAssertEqual(FocusOracle.withoutFocusedElement(trusted: true).security, .unknown)
    }
}

/// The selection read's mapping from what accessibility answered to what it
/// means.
///
/// Only the mapping. Everything around it is AX-bound — a live grant, a focused
/// application, a real highlighted range — and has no seam underneath to fake,
/// which is why the reasoning was split out as a pure function in the first
/// place.
final class SelectionReadTests: XCTestCase {
    private func read(
        trusted: Bool = true,
        security: SecureFieldState = .notSecure,
        hasFocusedElement: Bool = true,
        selectedRangeLength: Int? = nil,
        hasValue: Bool = true,
        selectedText: String? = nil
    ) -> SelectionRead {
        FocusOracle.selectionRead(
            trusted: trusted, security: security, hasFocusedElement: hasFocusedElement,
            selectedRangeLength: selectedRangeLength, hasValue: hasValue,
            selectedText: selectedText)
    }

    func testANonEmptyRangeWithTextIsASelection() {
        XCTAssertEqual(
            read(selectedRangeLength: 6, selectedText: "hgsghl"), .selected("hgsghl"))
    }

    func testAnEmptyRangeIsACaretWithNothingSelected() {
        XCTAssertEqual(read(selectedRangeLength: 0), .noSelection)
    }

    /// A terminal drawing its own cells: no focused element at all, with the
    /// grant in hand. Silence, and the caller falls back to the typed buffer.
    func testAnAppWithNoAccessibilityTreeIsStructurallySilent() {
        XCTAssertEqual(read(hasFocusedElement: false), .unreadable)
    }

    /// The same nil without the grant says only that Harf is blind.
    func testWithoutTheGrantTheSameSilenceIsUnavailable() {
        XCTAssertEqual(read(trusted: false, hasFocusedElement: false), .unavailable)
    }

    /// Neither a selected range nor a value is the same structural silence one
    /// level down: not a text field anybody can reason about.
    func testAnElementWithNeitherRangeNorValueIsUnreadable() {
        XCTAssertEqual(read(selectedRangeLength: nil, hasValue: false), .unreadable)
    }

    /// A value but no range is the noisy failure: it has text and will not say
    /// what is selected in it.
    func testAnElementWithAValueButNoRangeIsARefusal() {
        XCTAssertEqual(read(selectedRangeLength: nil, hasValue: true), .unavailable)
    }

    /// It claimed a selection and then would not hand it over. Flipping a
    /// selection whose contents are unknown would overwrite it with a guess.
    func testARangeThatYieldsNoTextIsARefusal() {
        XCTAssertEqual(read(selectedRangeLength: 6, selectedText: nil), .unavailable)
        XCTAssertEqual(read(selectedRangeLength: 6, selectedText: ""), .unavailable)
    }

    /// Reading a password field's selection is itself the leak, so the answer
    /// is the same one a refusal gets, whatever the range said.
    func testASecureFieldIsNeverRead() {
        XCTAssertEqual(
            read(security: .secure, selectedRangeLength: 6, selectedText: "hunter2"),
            .unavailable)
        XCTAssertEqual(read(security: .secure, selectedRangeLength: 0), .unavailable)
    }
}
