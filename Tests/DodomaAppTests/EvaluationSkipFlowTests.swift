import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The evaluations that do nothing, and the promise that every one of them says
/// so.
///
/// A running instance was once observed receiving every keystroke for two days
/// while never logging a decision or a fix: the layout pair had become
/// unresolvable, and the branch that noticed re-armed the trigger once a second
/// and said nothing. From outside the process that is indistinguishable from an
/// app with nothing to correct, so nobody could tell until a restart fixed it.
///
/// What is covered here is that shape rather than the log text itself — os_log
/// cannot be read back in-process. The observable consequences are: a `skipped`
/// decision reaches the debug window, the selection is re-read exactly once, and
/// the trigger is re-armed only when re-reading it actually repaired something.
final class EvaluationSkipFlowTests: XCTestCase {
    private var harness: PipelineHarness!

    override func setUp() {
        super.setUp()
        harness = PipelineHarness()
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    /// The regression, stated as the checklist states it: one line, the
    /// documented wording, and the buffer left alone so it can be evaluated
    /// again once the pair comes back.
    func testAMissingLayoutPairPublishesTheDocumentedSkipAndKeepsTheBuffer() {
        harness.setLayoutPair { nil }
        harness.type("h")
        harness.waitForTrigger(self)

        let skips = harness.decisions.filter { $0.verdict == "skipped" }
        XCTAssertEqual(skips.count, 1, "said once, not once a second")
        XCTAssertEqual(skips.first?.reason, "no English/Arabic layout pair enabled")
        XCTAssertEqual(harness.buffer.text, "h", "the buffer is still there to evaluate")
    }

    /// The recovery: a refused evaluation asks the main thread what the selected
    /// input source actually is, rather than trusting a distributed notification
    /// that may have been coalesced away.
    func testAMissingLayoutPairAsksForTheSelectionToBeReReadExactlyOnce() {
        harness.setLayoutPair { nil }
        harness.setLayoutRefresh { false }
        harness.type("h")
        harness.waitForTrigger(self)

        XCTAssertEqual(harness.layoutRefreshRequests, 1)
    }

    /// The loop that ran for two days. A refusal the refresh could not repair
    /// leaves *no* trigger behind: retrying against an unchanged world once a
    /// second is not a recovery strategy, and a user with only English enabled
    /// is refused for good reasons.
    func testAnUnrepairableSelectionLeavesNoTriggerRunning() {
        harness.setLayoutPair { nil }
        harness.setLayoutRefresh { false }
        harness.type("h")
        harness.waitForTrigger(self)

        XCTAssertFalse(harness.isEvaluationArmed)
    }

    /// The other side of the same rule: a refresh that reports it repaired
    /// something has earned one more attempt, because there is still a buffer
    /// nothing has looked at.
    func testARepairedSelectionReArmsTheEvaluationExactlyOnce() {
        harness.setLayoutPair { nil }
        harness.setLayoutRefresh { true }
        harness.type("h")
        harness.waitForTrigger(self)

        XCTAssertTrue(harness.isEvaluationArmed, "the repair earned another attempt")
        XCTAssertEqual(harness.layoutRefreshRequests, 1, "and only one refresh per refusal")
    }

    /// The end of the story the checklist tells: re-enable the missing source
    /// and it fixes normally, with no restart. The assertion is that the
    /// detector *ran* — a verdict other than `skipped`, and a measured duration
    /// — rather than what it concluded, which belongs to the language models and
    /// their own tests.
    func testOnceThePairIsAvailableTheNextTriggerReachesTheDetector() throws {
        try XCTSkipIf(HarnessLayouts.pair == nil, "the committed layout tables are missing")
        harness.setLayoutPair { nil }
        harness.type("h")
        harness.waitForTrigger(self)
        XCTAssertEqual(
            harness.lastDecision?.verdict, "skipped", "precondition: the first one was refused")

        harness.setLayoutPair { HarnessLayouts.pair }
        harness.type("i")
        harness.waitForTrigger(self)

        let decision = try XCTUnwrap(harness.lastDecision)
        XCTAssertNotEqual(decision.verdict, "skipped", "the detector was reached")
        XCTAssertGreaterThan(decision.durationMillis, 0, "and it did the work")
    }

    /// The preflight refusals published to the debug window before this change
    /// but reached os_log through nothing at all. The buffer is dropped by the
    /// secure-input rule, which is separate and already covered; what is
    /// asserted here is that the refusal is named.
    func testAPreflightBlockPublishesSkippedWithTheSafetyGateReason() {
        harness.type("h")
        // Set on the fake only, so the pipeline's cached flag stays false and
        // the block happens inside `evaluate()` — which is the window the
        // synchronous re-read exists to close.
        harness.secureInput.set(true)
        harness.waitForTrigger(self)

        let skips = harness.decisions.filter { $0.verdict == "skipped" }
        XCTAssertEqual(skips.count, 1)
        XCTAssertEqual(skips.first?.reason, "secure input is enabled")
    }
}

// MARK: - The refusal order

/// `evaluationRefusal` is the single spelling of a guard that used to be written
/// out three times, so the order it applies the conditions in is the contract.
extension EvaluationSkipFlowTests {
    func testTheRefusalOrderFollowsTheSafetyOrder() {
        let cases:
            [(captureActive: Bool, isApplying: Bool, isGating: Bool, isSuppressed: Bool,
              expected: SkipReason?)] = [
                (true, false, false, false, nil),
                (false, false, false, false, .captureInactive),
                // The tap not running outranks everything: nothing else matters
                // if no keystroke can reach the buffer in the first place.
                (false, true, true, true, .captureInactive),
                (true, true, false, false, .applyInFlight),
                (true, true, true, true, .applyInFlight),
                (true, false, true, false, .gateOpen),
                (true, false, true, true, .gateOpen),
                (true, false, false, true, .suppressed),
            ]

        for entry in cases {
            XCTAssertEqual(
                TypingPipeline.evaluationRefusal(
                    captureActive: entry.captureActive, isApplying: entry.isApplying,
                    isGating: entry.isGating, isSuppressed: entry.isSuppressed),
                entry.expected,
                "capture=\(entry.captureActive) applying=\(entry.isApplying) "
                    + "gating=\(entry.isGating) suppressed=\(entry.isSuppressed)")
        }
    }
}
