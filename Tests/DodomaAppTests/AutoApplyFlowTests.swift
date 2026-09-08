import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The automatic path, from the detector's `.autoApply` verdict to the screen.
///
/// The scoring that produces the verdict is pure and covered in the core
/// tests; what is covered here is the part that only exists once the pipeline
/// is wired up: that a `.autoApply` decision passes the accessibility gate,
/// reaches the injector through `beginApply(kind: .auto)`, is reported as an
/// applied fix rather than a suggestion, and leaves an undoable fix behind.
/// The accept and undo flows exercise the other two `ApplyKind`s; this closes
/// the seam they do not cover.
final class AutoApplyFlowTests: XCTestCase {
    private var harness: PipelineHarness!
    private let lock = NSLock()
    private var decisions: [DecisionSnapshot] = []

    override func setUp() {
        super.setUp()
        harness = PipelineHarness()
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        harness.pipeline.onDecision = { [weak self] snapshot in
            guard let self else { return }
            self.lock.lock()
            self.decisions.append(snapshot)
            self.lock.unlock()
        }
    }

    override func tearDown() {
        harness = nil
        lock.lock()
        decisions.removeAll()
        lock.unlock()
        super.tearDown()
    }

    private var lastDecision: DecisionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return decisions.last
    }

    /// The whole happy path: the fix reaches the injector, is reported as an
    /// auto-apply and not as a suggestion, and the decision is labelled
    /// `applied`.
    func testAnAutoApplyDecisionReachesTheInjectorAndIsReportedAsApplied() {
        harness.autoApply(Fixtures.fix)

        XCTAssertEqual(harness.engine.applied.count, 1, "the injector was asked to apply it")
        XCTAssertEqual(harness.engine.lastFix, Fixtures.fix)

        XCTAssertEqual(harness.applied.count, 1, "reported through the auto-apply callback")
        XCTAssertEqual(harness.applied.first?.fix, Fixtures.fix)
        XCTAssertEqual(harness.applied.first?.bundleID, Fixtures.app)

        XCTAssertTrue(harness.offers.isEmpty, "the auto path does not raise a suggestion")
        XCTAssertEqual(harness.undoAppliedCount, 0, "and it is not an undo")

        XCTAssertEqual(lastDecision?.verdict, "autoApply")
        XCTAssertEqual(lastDecision?.result, "applied", "the `.auto` ApplyKind label")
    }

    /// A successful auto-apply is undoable, exactly like an accepted suggestion:
    /// the `.auto` and `.accepted` kinds both record the fix.
    func testASuccessfulAutoApplyRecordsAnUndoableFix() {
        harness.autoApply(Fixtures.fix)

        XCTAssertEqual(harness.pipeline.undoableFix()?.fix, Fixtures.fix)
        XCTAssertEqual(harness.pipeline.undoableFix()?.bundleID, Fixtures.app)
    }

    /// The gate the auto path shares with the explicit paths: a grant revoked
    /// inside the ~250ms accessibility round trip must not reach `beginApply`.
    func testCaptureRevokedDuringTheGateStopsTheAutoApply() {
        harness.oracle.beforeAnswering = { [weak harness] in
            harness?.pipeline.setCaptureActive(false)
        }
        harness.autoApply(Fixtures.fix)

        XCTAssertTrue(harness.engine.applied.isEmpty, "nothing was deleted")
        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// A password field turned up by the same read that fetched the caret text
    /// drops the buffer and applies nothing.
    func testASecureFieldDropsTheAutoApply() {
        harness.oracle.answer(caret: Fixtures.caretBeforeFix, security: .secure)
        harness.autoApply(Fixtures.fix)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// A caret that does not match the buffer downgrades the automatic path to a
    /// suggestion rather than deleting on a guess.
    func testAMismatchedCaretDowngradesToASuggestion() {
        harness.oracle.answer(caret: .value("something else entirely"))
        harness.autoApply(Fixtures.fix)

        XCTAssertTrue(harness.engine.applied.isEmpty, "nothing was deleted")
        XCTAssertEqual(harness.offers.count, 1, "it was offered instead")
        XCTAssertEqual(harness.offers.first, Fixtures.fix)
    }
}

// MARK: - Spans the burst may not be counted against

/// The cap and the cluster rule, at the end of the pipeline that produces
/// fixes rather than in the injector that posts them. A fix refused here is
/// never offered either, so the user is not shown a card for a rewrite that can
/// only end in a ✕.
extension AutoApplyFlowTests {
    private func fix(replacing text: String) -> Fix {
        Fix(
            deleteCount: text.count,
            insertText: "x",
            targetLayoutID: Fixtures.arabic,
            sourceLayoutID: Fixtures.english,
            replacedText: text,
            capsMode: .asTyped)
    }

    func testAFixLongerThanTheCapIsNeitherAppliedNorOffered() {
        let long = String(repeating: "a", count: TextGuards.maximumDeleteCount + 1)
        harness.oracle.answer(caret: .value(long))
        harness.autoApply(fix(replacing: long))

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertTrue(harness.offers.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 0, "nobody asked for it, so nothing flashes")
    }

    /// A cluster of more than one scalar is one whose removal is not one
    /// backspace everywhere, and the caret verification counts in UTF-16 while
    /// `deleteCount` counts clusters.
    func testAFixOverACombinedClusterIsNeitherAppliedNorOffered() {
        let text = "cafe\u{0301} "
        harness.oracle.answer(caret: .value(text))
        harness.autoApply(fix(replacing: text))

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertTrue(harness.offers.isEmpty)
    }

    /// The undo deletes what the fix typed, which is a different span from the
    /// one the fix itself was checked for.
    func testAnUndoOverACombinedClusterIsRefused() {
        let applied = Fix(
            deleteCount: 3,
            insertText: "\u{1F468}\u{200D}\u{1F4BB}",
            targetLayoutID: Fixtures.arabic,
            sourceLayoutID: Fixtures.english,
            replacedText: "abc",
            capsMode: .asTyped)
        harness.oracle.answer(caret: .value("abc"))
        harness.autoApply(applied)
        XCTAssertEqual(harness.engine.applied.count, 1, "precondition: the fix went through")
        harness.waitForApplyTail(self)

        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 1, "no burst was posted")
        XCTAssertEqual(harness.rejectionCount, 1, "the user asked, so the refusal is shown")
    }
}

// MARK: - Evaluations that never happened

extension AutoApplyFlowTests {
    /// The layout cache is repopulated on the main thread after every
    /// enabled-sources change, and enumerating input sources from the pipeline
    /// queue is a Text Input Sources call off-main — so a quiet period that
    /// lands inside that window is skipped. Skipped, not abandoned: without
    /// another trigger the word typed across the change is never looked at
    /// again until the user types more.
    func testAColdLayoutCacheLeavesTheEvaluationArmed() {
        harness.type("h")
        XCTAssertTrue(harness.isEvaluationArmed, "precondition: the first trigger is armed")

        let fired = expectation(description: "the trigger fired")
        harness.pipeline.queue.asyncAfter(
            deadline: .now() + TypingSession.triggerDelay + 0.2
        ) { fired.fulfill() }
        wait(for: [fired], timeout: 5)
        harness.drain()

        XCTAssertTrue(harness.isEvaluationArmed)
        XCTAssertEqual(harness.buffer.text, "h", "and the buffer is still there to evaluate")
    }
}
