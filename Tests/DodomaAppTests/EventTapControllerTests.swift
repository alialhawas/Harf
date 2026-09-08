import DodomaCore
import XCTest

@testable import DodomaAppKit

/// What the tap makes of one raw key event, and what the pipeline makes of the
/// tap admitting it missed some.
///
/// The tap itself needs a session event tap and the two privacy grants, so
/// nothing here creates one. What is covered is the part that decides — the
/// order of the four filters, and the marker the injector is recognised by —
/// plus the pipeline's answer to `tapInterrupted`, which is the only thing
/// standing between "keystrokes reached the screen and not the buffer" and a
/// delete burst counted from the wrong place.
final class EventTapControllerTests: XCTestCase {
    private func meaning(
        keycode: UInt16,
        flags: KeyFlags = [],
        isAutorepeat: Bool = false,
        userData: Int64 = 0,
        panelVisible: Bool = false,
        panelConsumesKeys: Bool = true
    ) -> TapKeyMeaning {
        EventTapController.meaning(
            userData: userData, keycode: keycode, flags: flags, isAutorepeat: isAutorepeat,
            panelVisible: panelVisible, panelConsumesKeys: panelConsumesKeys)
    }

    // MARK: - Reading one event

    func testAnOrdinaryKeystrokeIsTyping() {
        XCTAssertEqual(meaning(keycode: 4), .typing)
    }

    func testTheInjectorsOwnEventsAreRecognisedByTheirMarker() {
        XCTAssertEqual(
            meaning(keycode: 4, userData: EventTapController.injectedEventMarker), .selfInjected)
    }

    /// A fixed constant is a value any other process can write, and a process
    /// that writes it makes Harf deaf to a stream of real keystrokes.
    func testTheInjectionMarkerCarriesThisProcess() {
        let marker = EventTapController.injectedEventMarker
        XCTAssertEqual(marker >> 32, Int64(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNotEqual(marker, 0x444F_444F)
    }

    func testAHeldLetterIsDroppedRatherThanDelivered() {
        XCTAssertEqual(meaning(keycode: 4, isAutorepeat: true), .autorepeatDropped)
    }

    /// Held-down deletes have to keep shrinking the buffer, or the buffer grows
    /// past text the user has already removed.
    func testAHeldBackspaceIsStillTyping() {
        XCTAssertEqual(meaning(keycode: Keycode.delete, isAutorepeat: true), .typing)
    }

    func testTabIsThePanelsKeyWhileTheCardIsUp() {
        XCTAssertEqual(
            meaning(keycode: Keycode.tab, panelVisible: true), .suggestionAccept)
        XCTAssertEqual(
            meaning(keycode: Keycode.escape, panelVisible: true), .suggestionDismiss)
    }

    func testTabIsOrdinaryTypingWithNoCardUp() {
        XCTAssertEqual(meaning(keycode: Keycode.tab), .typing)
    }

    /// The panel's keys are claimed ahead of the autorepeat filter: a repeat
    /// dropped there would still be returned to the system, and the application
    /// underneath would receive a stream of tabs through the card sitting on it.
    func testAHeldTabIsStillSwallowedByTheCard() {
        XCTAssertEqual(
            meaning(keycode: Keycode.tab, isAutorepeat: true, panelVisible: true),
            .suggestionAccept)
    }

    /// After the watchdog trips nothing is consumed, so the card is click-only.
    func testTheCardStopsClaimingKeysOnceConsumptionIsOff() {
        XCTAssertEqual(
            meaning(keycode: Keycode.tab, panelVisible: true, panelConsumesKeys: false), .typing)
    }

    /// Harf's own chord must not reach the pipeline as typing: it would move the
    /// serial the undo it is asking for is validated against.
    func testHarfsOwnChordIsNeverTyping() {
        XCTAssertEqual(
            meaning(keycode: Hotkeys.undoLastFix.keycode, flags: [.command, .option]), .hotkey)
    }

    /// And is claimed ahead of the autorepeat filter, so holding ⌘⌥Z reports
    /// nothing missing.
    func testAHeldChordIsNotReportedAsMissedInput() {
        XCTAssertEqual(
            meaning(
                keycode: Hotkeys.undoLastFix.keycode, flags: [.command, .option],
                isAutorepeat: true),
            .hotkey)
    }

    // MARK: - What the pipeline does about it

    func testAnInterruptedTapEmptiesTheBuffer() {
        let harness = PipelineHarness()
        harness.type("h")
        harness.type("i")
        XCTAssertEqual(harness.buffer.text, "hi", "precondition: the buffer holds the run")

        harness.send(.tapInterrupted(reason: "timeout"))

        XCTAssertEqual(harness.buffer.text, "")
        XCTAssertEqual(harness.buffer.lastReset, .tapInterrupted)
    }

    func testAnInterruptedTapTakesDownAPendingSuggestion() {
        let harness = PipelineHarness()
        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers.count, 1, "precondition: a card is up")

        harness.send(.tapInterrupted(reason: "autorepeat"))
        XCTAssertEqual(harness.hideCount, 1)

        harness.send(.suggestionAccept)
        XCTAssertTrue(harness.engine.applied.isEmpty, "the withdrawn offer cannot be accepted")
    }

    /// The keystrokes the tap missed are in front of the caret now, and an undo
    /// counts its backspaces from there.
    func testAnInterruptedTapWithdrawsTheUndo() {
        let harness = PipelineHarness()
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)
        XCTAssertEqual(harness.engine.applied.count, 1, "precondition: a fix was applied")
        harness.waitForApplyTail(self)
        harness.oracle.answer(caret: Fixtures.caretAfterFix)

        harness.send(.tapInterrupted(reason: "timeout"))
        XCTAssertNil(harness.pipeline.undoableFix())

        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 1, "nothing was posted")
        XCTAssertEqual(harness.undoAppliedCount, 0)
    }
}
