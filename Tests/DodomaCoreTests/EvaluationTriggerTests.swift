import XCTest

@testable import DodomaCore

/// The seam between capture and detection: when the buffer becomes eligible
/// for evaluation, and what evaluating it yields.
///
/// The pipeline's `DispatchWorkItem` is not exercised here — it is a scheduling
/// detail. What is exercised is everything it delegates to.
final class EvaluationTriggerTests: XCTestCase {
    private static let canonical = "HC MV; HKH HSMDIH HGDML"
    private static let canonicalArabic = "اذ ودك انا اسويها اليوم"

    // MARK: - The quiet-period test

    func testEvaluationIsDueExactlyAtTheTriggerDelay() {
        XCTAssertEqual(TypingSession.triggerDelay, 1.0)
        let last: TimeInterval = 500

        XCTAssertFalse(TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: last))
        XCTAssertFalse(TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: last + 0.999))
        // The pipeline schedules its work item for exactly this instant, so the
        // boundary has to be inclusive or the first firing always misses.
        XCTAssertTrue(TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: last + 1.0))
        XCTAssertTrue(TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: last + 5))
    }

    /// The second pass has to fit in the window between the first evaluation
    /// and the point at which there is nothing left to evaluate. Asserted as an
    /// ordering rather than as three numbers so that moving any one of them
    /// into an inconsistent state fails here rather than in the field.
    func testTheSettledDelaySitsBetweenTheTriggerAndTheIdleTimeout() {
        XCTAssertEqual(TypingSession.settledDelay, 3.0)
        XCTAssertLessThan(
            TypingSession.triggerDelay, TypingSession.settledDelay,
            "the second pass must come after the first, not instead of it")
        XCTAssertLessThan(
            TypingSession.settledDelay, BufferResetPolicy.idleTimeout,
            "a buffer that has already been discarded cannot be looked at again")
    }

    func testTheSettledPassIsDueExactlyAtTheSettledDelay() {
        let last: TimeInterval = 500

        XCTAssertFalse(
            TypingSession.isEvaluationDue(
                lastKeyTimestamp: last, now: last + 2.999, after: TypingSession.settledDelay))
        // Inclusive at the boundary, for the same reason the first trigger is:
        // the work item is scheduled for exactly this instant.
        XCTAssertTrue(
            TypingSession.isEvaluationDue(
                lastKeyTimestamp: last, now: last + 3.0, after: TypingSession.settledDelay))
    }

    func testTypingRefreshesTheTimestampTheTriggerReadsFrom() throws {
        let session = TypingSession(frontmostBundleID: "com.apple.TextEdit")
        session.handle(.key(CapturedKey(keycode: 4, producedText: "h", timestamp: 100)))
        XCTAssertEqual(session.lastKeyTime, 100)

        session.handle(.key(CapturedKey(keycode: 34, producedText: "i", timestamp: 100.5)))
        let last = try XCTUnwrap(session.lastKeyTime)
        XCTAssertEqual(last, 100.5)
        XCTAssertFalse(TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: 101.2))
        XCTAssertTrue(TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: 101.5))
    }

    func testAResetDisarmsTheTrigger() {
        let session = TypingSession()
        session.handle(.key(CapturedKey(keycode: 4, producedText: "h", timestamp: 100)))
        session.reset(reason: .manual, at: 100.1)

        XCTAssertNil(session.lastKeyTime)
        XCTAssertTrue(session.isBufferEmpty)
    }

    // MARK: - Evaluating the buffer

    func testCanonicalSampleWithATrailingSpaceAutoAppliesThroughTheSession() throws {
        let fixture = try DetectorFixture.make()
        let session = try typedSession(Self.canonical + " ", fixture: fixture)

        let detection = try XCTUnwrap(
            session.evaluate(
                detector: fixture.detector, policy: .normal, aggressiveness: .balanced))
        guard case .autoApply(let fix) = detection.decision else {
            return XCTFail("expected autoApply, got \(detection.decision)")
        }

        // The Fix contract: the region runs to the caret, so the trailing space
        // is part of both sides of the edit and `deleteCount` counts it.
        XCTAssertEqual(fix.replacedText, Self.canonical + " ")
        XCTAssertEqual(fix.insertText, Self.canonicalArabic + " ")
        XCTAssertEqual(fix.deleteCount, Self.canonical.count + 1)
        XCTAssertEqual(fix.deleteCount, fix.replacedText.count)
        XCTAssertEqual(fix.targetLayoutID, fixture.arabic.layout.sourceID)
        XCTAssertEqual(fix.sourceLayoutID, fixture.abc.layout.sourceID)
    }

    func testEvaluationPicksTheTypedLanguageFromTheBufferItself() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("اثممخ اخص شقث غخع ")
        let session = try typedSession(keys: keys)

        let detection = try XCTUnwrap(
            session.evaluate(
                detector: fixture.detector, policy: .normal, aggressiveness: .balanced))
        guard case .autoApply(let fix) = detection.decision else {
            return XCTFail("expected autoApply, got \(detection.decision)")
        }
        XCTAssertEqual(detection.typedLanguage, .arabic)
        XCTAssertEqual(fix.insertText, "hello how are you ")
        XCTAssertEqual(fix.targetLayoutID, fixture.abc.layout.sourceID)
    }

    func testAnOffPolicyEvaluatesToNothing() throws {
        let fixture = try DetectorFixture.make()
        let session = try typedSession(Self.canonical + " ", fixture: fixture)

        let detection = try XCTUnwrap(
            session.evaluate(detector: fixture.detector, policy: .off, aggressiveness: .balanced))
        XCTAssertEqual(detection.decision, .ignore(reason: "policy off"))
    }

    func testOrdinaryTypingEvaluatesToIgnore() throws {
        let fixture = try DetectorFixture.make()
        let session = try typedSession("please send me the report ", fixture: fixture)

        let detection = try XCTUnwrap(
            session.evaluate(
                detector: fixture.detector, policy: .normal, aggressiveness: .balanced))
        XCTAssertNil(detection.decision.fix)
    }

    func testAnEmptyBufferIsNotEvaluatedAtAll() throws {
        let fixture = try DetectorFixture.make()
        let session = TypingSession(frontmostBundleID: "com.apple.TextEdit")

        XCTAssertNil(
            session.evaluate(
                detector: fixture.detector, policy: .normal, aggressiveness: .balanced))
    }

    func testTheBufferIsNotEvaluatedAgainAfterAFixWasApplied() throws {
        let fixture = try DetectorFixture.make()
        let session = try typedSession(Self.canonical + " ", fixture: fixture)

        // What the pipeline does the moment the fix engine reports success.
        session.reset(reason: .manual, at: 200)

        XCTAssertNil(
            session.evaluate(
                detector: fixture.detector, policy: .normal, aggressiveness: .balanced))
    }

    // MARK: - Helpers

    /// Feeds `text` through the session one synthetic keystroke at a time,
    /// 100 ms apart, exactly as the tap would.
    private func typedSession(
        _ text: String, fixture: DetectorFixture, file: StaticString = #filePath, line: UInt = #line
    ) throws -> TypingSession {
        try typedSession(
            keys: try fixture.latinKeys(text, file: file, line: line), file: file, line: line)
    }

    private func typedSession(
        keys: [CapturedKey], file: StaticString = #filePath, line: UInt = #line
    ) throws -> TypingSession {
        let session = TypingSession(frontmostBundleID: "com.apple.TextEdit")
        for (index, key) in keys.enumerated() {
            session.handle(
                .key(
                    CapturedKey(
                        keycode: key.keycode,
                        flags: key.flags,
                        producedText: key.producedText,
                        keyboardType: key.keyboardType,
                        timestamp: 100 + Double(index) * 0.1)))
        }
        XCTAssertEqual(session.snapshot(at: 0).keyCount, keys.count, file: file, line: line)
        return session
    }
}
