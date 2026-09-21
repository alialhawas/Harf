import CoreGraphics
import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The delete burst, without the window server.
///
/// Everything here goes through `FixEngine.Machine`, which is the only reason
/// these tests exist: the real sequence posts backspaces at whatever window the
/// person running the suite has in front of them, so until there was a seam the
/// one part of the app that removes text it cannot see had no tests at all.
final class FixEngineTests: XCTestCase {
    /// The machine, dictated. Every answer is a closure so a test can change it
    /// part-way through a burst, which is the whole point: what is under test is
    /// what the sequence does when the answers change between two backspaces.
    private final class FakeMachine {
        var posted: [CGEvent] = []
        var bundleID: String? = "com.harf.tests"
        /// Answers of `currentBundleID`, in order; the last one repeats.
        var authoritative: [String?] = ["com.harf.tests"]
        private var authoritativeReads = 0
        var selectedLayouts: [String] = []

        /// Key-downs of the backspace key, which is one per deleted cluster.
        var backspaces: Int {
            posted.filter {
                $0.type == .keyDown
                    && $0.getIntegerValueField(.keyboardEventKeycode) == Int64(Keycode.delete)
            }.count
        }

        /// Reports the caret stale once this many clusters have been deleted.
        var staleAfterBackspaces: Int?

        func isStale() -> Bool {
            guard let limit = staleAfterBackspaces else { return false }
            return backspaces >= limit
        }

        func make() -> FixEngine.Machine {
            FixEngine.Machine(
                post: { [unowned self] in self.posted.append($0) },
                modifierFlags: { [] },
                cachedBundleID: { [unowned self] in self.bundleID },
                currentBundleID: { [unowned self] in
                    let answer = self.authoritative[
                        min(self.authoritativeReads, self.authoritative.count - 1)]
                    self.authoritativeReads += 1
                    return answer
                },
                selectLayout: { [unowned self] in
                    self.selectedLayouts.append($0)
                    return nil
                })
        }
    }

    private var machine: FakeMachine!
    private var engine: FixEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(
            CGEventSource(stateID: .combinedSessionState) == nil,
            "this environment cannot make an event source, so there is no sequence to run")
        machine = FakeMachine()
        engine = FixEngine(frontmost: FrontmostAppTracker(), machine: machine.make())
    }

    override func tearDown() {
        engine = nil
        machine = nil
        super.tearDown()
    }

    private func fix(deleting text: String, count: Int? = nil) -> Fix {
        Fix(
            deleteCount: count ?? text.count,
            insertText: "x",
            targetLayoutID: Fixtures.arabic,
            sourceLayoutID: Fixtures.english,
            replacedText: text,
            capsMode: .asTyped)
    }

    @discardableResult
    private func apply(_ fix: Fix) -> Result<FixProgress, FixFailure> {
        let done = expectation(description: "the sequence finished")
        var outcome: Result<FixProgress, FixFailure>!
        engine.apply(fix, in: machine.bundleID, isStale: { [machine] in machine!.isStale() }) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return outcome
    }

    private func failure(of outcome: Result<FixProgress, FixFailure>) -> FixFailure? {
        guard case .failure(let failure) = outcome else { return nil }
        return failure
    }

    // MARK: - The burst

    func testOneBackspaceIsPostedPerDeletedCluster() {
        let outcome = apply(fix(deleting: "hgs"))

        XCTAssertNil(failure(of: outcome))
        XCTAssertEqual(machine.backspaces, 3)
        XCTAssertEqual(machine.selectedLayouts, [Fixtures.arabic])
    }

    /// The لا ligature is a single scalar that no key types. It is the one
    /// multi-letter-looking cluster the flip path produces, and it has to keep
    /// working.
    func testTheLamAlefLigatureIsStillDeleted() {
        let outcome = apply(fix(deleting: "\u{FEFB} "))

        XCTAssertNil(failure(of: outcome))
        XCTAssertEqual(machine.backspaces, 2)
    }

    // MARK: - Stopping part-way

    /// C8: the cached identifier says the same application throughout, and the
    /// authoritative read is the only thing that knows about the ⌘-Tab.
    func testTheBurstStopsWhenTheAuthoritativeFrontmostChanges() {
        machine.authoritative = ["com.harf.tests", "com.apple.Notes"]
        let outcome = apply(fix(deleting: String(repeating: "a", count: 40)))

        XCTAssertEqual(failure(of: outcome)?.error, .frontmostChanged)
        XCTAssertEqual(
            machine.backspaces, FixEngine.Timing.deleteCheckpointInterval,
            "stopped at the first checkpoint, not at the end of the burst")
    }

    /// The caret was verified once, before a pre-flight that can wait half a
    /// second. A keystroke a tenth of a second into the burst means every
    /// remaining backspace is counted from somewhere nobody checked.
    func testTheBurstStopsWhenInputArrivesDuringIt() {
        machine.staleAfterBackspaces = FixEngine.Timing.deleteCheckpointInterval
        let outcome = apply(fix(deleting: String(repeating: "a", count: 40)))

        XCTAssertEqual(failure(of: outcome)?.error, .inputSinceVerification)
        XCTAssertEqual(machine.backspaces, FixEngine.Timing.deleteCheckpointInterval)
    }

    // MARK: - Spans that are refused outright

    func testARunLongerThanTheCapPostsNothing() {
        let long = String(repeating: "a", count: TextGuards.maximumDeleteCount + 1)
        let outcome = apply(fix(deleting: long))

        XCTAssertEqual(failure(of: outcome)?.error, .unsafeDelete(.tooLong))
        XCTAssertTrue(machine.posted.isEmpty)
    }

    func testACountThatDisagreesWithTheTextPostsNothing() {
        let outcome = apply(fix(deleting: "hgs", count: 4))

        XCTAssertEqual(failure(of: outcome)?.error, .unsafeDelete(.countMismatch))
        XCTAssertTrue(machine.posted.isEmpty)
    }

    /// Decomposed `é` is two scalars in one cluster: applications disagree about
    /// whether one backspace takes the cluster or the accent, and the caret
    /// verification counts in UTF-16 either way.
    func testADecomposedAccentPostsNothing() {
        let outcome = apply(fix(deleting: "cafe\u{0301} "))

        XCTAssertEqual(failure(of: outcome)?.error, .unsafeDelete(.ambiguousCluster))
        XCTAssertTrue(machine.posted.isEmpty)
    }

    func testALetterCarryingAHarakaPostsNothing() {
        let outcome = apply(fix(deleting: "\u{0645}\u{064E}\u{0646} "))

        XCTAssertEqual(failure(of: outcome)?.error, .unsafeDelete(.ambiguousCluster))
        XCTAssertTrue(machine.posted.isEmpty)
    }

    func testAZeroWidthJoinerEmojiPostsNothing() {
        let outcome = apply(fix(deleting: "\u{1F468}\u{200D}\u{1F4BB} "))

        XCTAssertEqual(failure(of: outcome)?.error, .unsafeDelete(.ambiguousCluster))
        XCTAssertTrue(machine.posted.isEmpty)
    }
}
