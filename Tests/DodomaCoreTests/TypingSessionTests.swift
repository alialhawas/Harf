import XCTest
@testable import DodomaCore

/// Covers the behaviour that used to live inline in `TypingPipeline`:
/// idle-timeout enforcement, reset suppression, mouse-down handling and
/// frontmost-application handling.
final class TypingSessionTests: XCTestCase {
    private func character(
        _ text: String,
        keycode: UInt16 = 0,
        at time: TimeInterval
    ) -> SessionInput {
        .key(CapturedKey(keycode: keycode, producedText: text, timestamp: time))
    }

    private func special(_ keycode: UInt16, at time: TimeInterval) -> SessionInput {
        .key(CapturedKey(keycode: keycode, producedText: "", timestamp: time))
    }

    // MARK: - Basic accumulation

    func testKeysAccumulateAndSnapshotReflectsThem() {
        let session = TypingSession(frontmostBundleID: "com.apple.TextEdit")

        session.handle(character("h", keycode: 4, at: 100))
        let outcome = session.handle(character("i", keycode: 34, at: 100.1))

        XCTAssertEqual(outcome.snapshot.text, "hi")
        XCTAssertEqual(outcome.snapshot.keyCount, 2)
        XCTAssertEqual(outcome.snapshot.frontmostBundleID, "com.apple.TextEdit")
        XCTAssertEqual(outcome.snapshot.capturedAt, 100.1)
        XCTAssertNil(outcome.performedReset)
        XCTAssertEqual(outcome.action, .append)
    }

    // MARK: - Idle timeout

    func testIdleTimeoutBoundaryIsStrictlyGreaterThanTenSeconds() {
        let session = TypingSession()
        session.handle(character("a", at: 100))

        // Exactly at the timeout: still the same typing burst.
        let atBoundary = session.handle(character("b", at: 110))
        XCTAssertNil(atBoundary.performedReset)
        XCTAssertEqual(atBoundary.snapshot.text, "ab")

        // Just past it: the stale prefix is dropped first.
        let pastBoundary = session.handle(character("c", at: 120.001))
        XCTAssertEqual(pastBoundary.performedReset, .idleTimeout)
        XCTAssertEqual(pastBoundary.snapshot.text, "c")
        XCTAssertEqual(pastBoundary.snapshot.keyCount, 1)
        XCTAssertEqual(pastBoundary.snapshot.lastReset, .idleTimeout)
    }

    func testIdleTimeoutDoesNotFireOnAnEmptyBuffer() {
        let session = TypingSession()
        session.handle(character("a", at: 100))
        session.handle(special(36, at: 101))  // Return empties the buffer

        let outcome = session.handle(character("b", at: 200))
        XCTAssertNil(outcome.performedReset)
        XCTAssertEqual(outcome.snapshot.text, "b")
        // The Return reset is still the last one recorded.
        XCTAssertEqual(outcome.snapshot.lastReset, .enterKey)
    }

    func testIdleTimeoutAlsoAppliesToBackspace() {
        let session = TypingSession()
        session.handle(character("a", at: 100))
        session.handle(character("b", at: 100.1))

        let outcome = session.handle(special(51, at: 200))
        XCTAssertEqual(outcome.performedReset, .idleTimeout)
        XCTAssertEqual(outcome.action, .backspace)
        XCTAssertEqual(outcome.snapshot.text, "")
        XCTAssertEqual(outcome.snapshot.keyCount, 0)
    }

    func testBackspaceDoesNotHideStalenessFromTheFollowingAppend() {
        // Regression guard: if the idle check ran on append only, the backspace
        // would refresh the clock and "ab" would silently glue onto "c".
        let session = TypingSession()
        session.handle(character("a", at: 100))
        session.handle(character("b", at: 100.1))
        session.handle(special(51, at: 200))

        let outcome = session.handle(character("c", at: 200.1))
        XCTAssertEqual(outcome.snapshot.text, "c")
    }

    // MARK: - Reset suppression

    func testRepeatedResetWithTheSameReasonIsSuppressed() {
        let session = TypingSession()
        session.handle(character("a", at: 100))

        let first = session.handle(special(36, at: 101))
        XCTAssertEqual(first.performedReset, .enterKey)

        let second = session.handle(special(36, at: 102))
        XCTAssertNil(second.performedReset)
        XCTAssertEqual(second.snapshot.lastReset, .enterKey)
    }

    func testResetOnEmptyBufferWithADifferentReasonIsStillRecorded() {
        let session = TypingSession()
        session.handle(character("a", at: 100))
        session.handle(special(36, at: 101))

        let outcome = session.handle(special(53, at: 102))  // Escape
        XCTAssertEqual(outcome.performedReset, .escapeKey)
        XCTAssertEqual(outcome.snapshot.lastReset, .escapeKey)
    }

    func testIgnoredKeysChangeNothing() {
        let session = TypingSession()
        session.handle(character("a", at: 100))

        let outcome = session.handle(special(56, at: 101))  // pure Shift keycode
        XCTAssertEqual(outcome.action, .ignore)
        XCTAssertNil(outcome.performedReset)
        XCTAssertEqual(outcome.snapshot.text, "a")
    }

    // MARK: - Mouse down

    func testMouseDownResetsANonEmptyBuffer() {
        let session = TypingSession()
        session.handle(character("a", at: 100))

        let outcome = session.handle(.mouseDown(at: 101))
        XCTAssertEqual(outcome.performedReset, .mouseDown)
        XCTAssertEqual(outcome.snapshot.text, "")
        XCTAssertEqual(outcome.snapshot.lastReset, .mouseDown)
        XCTAssertEqual(outcome.snapshot.capturedAt, 101)
        XCTAssertNil(outcome.action)
    }

    func testMouseDownOnAnEmptyBufferIsSuppressedButStillLogged() {
        let session = TypingSession()

        let outcome = session.handle(.mouseDown(at: 100))
        XCTAssertNil(outcome.performedReset)
        XCTAssertNil(outcome.snapshot.lastReset)
        XCTAssertEqual(outcome.snapshot.recentEvents.first?.keycodeText, "mouse")
    }

    // MARK: - Application activation

    func testActivatingADifferentApplicationResetsAndTracksTheBundleID() {
        let session = TypingSession(frontmostBundleID: "com.apple.TextEdit")
        session.handle(character("a", at: 100))

        let outcome = session.handle(.appActivated(bundleID: "com.apple.Safari", at: 101))
        XCTAssertEqual(outcome.performedReset, .appChanged)
        XCTAssertEqual(outcome.snapshot.frontmostBundleID, "com.apple.Safari")
        XCTAssertEqual(outcome.snapshot.text, "")
        XCTAssertEqual(session.currentFrontmostBundleID, "com.apple.Safari")
    }

    func testReactivatingTheSameApplicationDoesNotReset() {
        let session = TypingSession(frontmostBundleID: "com.apple.TextEdit")
        session.handle(character("a", at: 100))

        let outcome = session.handle(.appActivated(bundleID: "com.apple.TextEdit", at: 101))
        XCTAssertNil(outcome.performedReset)
        XCTAssertEqual(outcome.snapshot.text, "a")
    }

    func testActivationDoesNotRecordADebugRow() {
        let session = TypingSession()
        session.handle(character("a", at: 100))

        let outcome = session.handle(.appActivated(bundleID: "com.apple.Safari", at: 101))
        XCTAssertEqual(outcome.snapshot.recentEvents.count, 1)
    }

    // MARK: - Input source

    func testInputSourceChangeResetsANonEmptyBuffer() {
        let session = TypingSession()
        session.handle(character("a", at: 100))

        let outcome = session.handle(.inputSourceChanged(at: 101))
        XCTAssertEqual(outcome.performedReset, .inputSourceChanged)
        XCTAssertEqual(outcome.snapshot.text, "")
    }

    func testInputSourceChangeOnAnEmptyBufferIsSuppressed() {
        let session = TypingSession()

        let outcome = session.handle(.inputSourceChanged(at: 100))
        XCTAssertNil(outcome.performedReset)
    }

    // MARK: - Debug event log

    func testDebugEventLogIsNewestFirstAndCappedAtFifty() {
        let session = TypingSession()
        for index in 0..<60 {
            session.handle(character("x", keycode: UInt16(index), at: 100 + Double(index) * 0.01))
        }

        let events = session.snapshot(at: 200).recentEvents
        XCTAssertEqual(TypingSession.debugEventLimit, 50)
        XCTAssertEqual(events.count, 50)
        XCTAssertEqual(events.first?.keycodeText, "59")
        XCTAssertEqual(events.last?.keycodeText, "10")
        XCTAssertEqual(events.map(\.id), events.map(\.id).sorted(by: >))
    }

    func testDebugRowsCarryTheRenderedActionAndFlags() throws {
        let session = TypingSession()
        let key = CapturedKey(
            keycode: 0, flags: [.command, .shift], producedText: "A", timestamp: 100)

        let outcome = session.handle(.key(key))
        let row = try XCTUnwrap(outcome.snapshot.recentEvents.first)
        XCTAssertEqual(row.actionText, "reset(modifierChord)")
        XCTAssertEqual(row.flagsText, "⇧⌘")
        XCTAssertEqual(row.keycodeText, "0")
    }

    // MARK: - Buffer capacity through the session

    // MARK: - The secure-input purge

    /// The drop has to be retroactive. By the time the accessibility layer says
    /// "password field", the characters are already in the debug event log, and
    /// that log is published to the debug window in the very next snapshot.
    func testASecureInputResetAlsoPurgesTheKeystrokeHistory() {
        let session = TypingSession(frontmostBundleID: "com.apple.Safari")
        session.handle(character("h", keycode: 4, at: 100))
        session.handle(character("u", keycode: 32, at: 100.1))
        session.handle(character("n", keycode: 45, at: 100.2))
        session.handle(.mouseDown(at: 100.3))
        XCTAssertEqual(session.snapshot(at: 100.4).recentEvents.count, 4, "precondition")

        let snapshot = session.reset(reason: .secureInput, at: 101)

        XCTAssertEqual(snapshot.text, "")
        XCTAssertEqual(snapshot.keyCount, 0)
        XCTAssertEqual(snapshot.lastReset, .secureInput)
        XCTAssertTrue(snapshot.recentEvents.isEmpty, "the produced text of every key must go too")
        XCTAssertTrue(
            session.snapshot(at: 102).recentEvents.isEmpty, "and stay gone in later snapshots")
    }

    /// The log surviving an ordinary reset is the whole point of it: watching
    /// what happened either side of one is most of what the window is for.
    func testAnOrdinaryResetKeepsTheKeystrokeHistory() {
        for reason in ResetReason.allCases where !reason.purgesHistory {
            let fresh = TypingSession()
            fresh.handle(character("a", keycode: 0, at: 100))
            fresh.handle(character("b", keycode: 11, at: 100.1))
            let snapshot = fresh.reset(reason: reason, at: 101)
            XCTAssertEqual(snapshot.text, "", reason.rawValue)
            XCTAssertEqual(snapshot.recentEvents.count, 2, reason.rawValue)
        }
    }

    /// Every path that clears the buffer goes through the same helper, so an
    /// in-stream reset purges just as a caller-driven one does.
    func testTheInStreamResetPathsAlsoRespectThePurgeRule() {
        let session = TypingSession()
        session.handle(character("a", keycode: 0, at: 100))
        session.handle(.mouseDown(at: 100.1))
        XCTAssertEqual(
            session.snapshot(at: 100.2).recentEvents.count, 2,
            "a mouse-down reset keeps the history")

        // Nothing in the input stream can produce `.secureInput` today — it
        // only ever arrives through `reset(reason:at:)` — but the rule lives on
        // the reason, so it holds wherever a future path puts it.
        XCTAssertFalse(ResetReason.mouseDown.purgesHistory)
        XCTAssertTrue(ResetReason.secureInput.purgesHistory)
    }

    func testSessionRespectsTheTwoHundredKeyRing() {
        let session = TypingSession()
        for index in 0..<210 {
            session.handle(character("x", at: 100 + Double(index) * 0.01))
        }

        let snapshot = session.snapshot(at: 200)
        XCTAssertEqual(snapshot.keyCount, TypedBuffer.defaultCapacity)
        XCTAssertEqual(snapshot.text.count, TypedBuffer.defaultCapacity)
    }
}
