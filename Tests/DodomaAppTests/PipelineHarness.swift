import DodomaCore
import Foundation
import XCTest

@testable import DodomaAppKit

// MARK: - Stand-ins for the three things that touch the machine

/// The injector, without the injection.
///
/// The real one posts backspaces at the window server. A test that used it
/// would delete text out of whatever window the person running the tests
/// happened to have in front of them.
final class FakeFixEngine: FixApplying {
    struct Call {
        let fix: Fix
        let bundleID: String?
        /// Whether the pipeline's abort predicate said the caret verification
        /// had gone stale by the time the engine asked.
        let staleWhenAsked: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    /// What the next apply reports back. Defaults to a clean success.
    var result: Result<FixProgress, FixFailure> = .success(
        FixProgress(deletedClusters: 1, insertedUTF16Units: 1))

    /// Run on the pipeline queue while the apply is notionally in flight — i.e.
    /// with `isApplying` set. The only way to reproduce a click or a keystroke
    /// landing in the middle of a delete burst.
    var duringApply: (() -> Void)?

    /// Run after the completion handler, with the layout the fix selected.
    ///
    /// The real sequence ends in `TISSelectInputSource`, and the system
    /// announces that back to the app as a keyboard-layout change — an input,
    /// arriving a few milliseconds after every single fix. A fake that stayed
    /// silent about it would let a rule that mistakes it for the user typing
    /// pass every test in this file, which is exactly what happened once.
    var afterApply: ((Fix) -> Void)?

    /// What the next `copySelection` reports back. Defaults to the answer an
    /// application with nothing selected gives.
    var copyResult: CopyResult = .noSelection

    /// Run on the pipeline queue after the copy is notionally in flight and
    /// before it is answered. The only way to reproduce a keystroke landing in
    /// the middle of the ⌘C round trip, which for a real copy is the better
    /// part of a second.
    var beforeCopyAnswer: (() -> Void)?

    /// What the next `replaceSelection` reports back. One inserted unit and
    /// nothing deleted, which is the shape every successful selection flip has:
    /// typing over a selection deletes nothing itself.
    var replaceResult: Result<FixProgress, FixFailure> = .success(
        FixProgress(deletedClusters: 0, insertedUTF16Units: 1))

    /// Run after the completion handler, with the layout the flip selected.
    /// The counterpart of `afterApply`, and there for the same reason: a
    /// selection flip ends in `TISSelectInputSource` too, and the system
    /// announces that back to the app as an input a few milliseconds later.
    var afterReplace: ((String) -> Void)?

    struct Replacement: Equatable {
        let text: String
        let targetLayoutID: String
        let bundleID: String?
        /// Whether the pipeline's abort predicate said the selection read had
        /// gone stale by the time the engine asked.
        let staleWhenAsked: Bool
    }

    private var replacements: [Replacement] = []
    private var copies = 0

    var applied: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var replaced: [Replacement] {
        lock.lock()
        defer { lock.unlock() }
        return replacements
    }

    var copyCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return copies
    }

    var lastFix: Fix? { applied.last?.fix }

    func apply(
        _ fix: Fix,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void
    ) {
        lock.lock()
        calls.append(Call(fix: fix, bundleID: bundleID, staleWhenAsked: isStale()))
        let result = self.result
        lock.unlock()
        duringApply?()
        completion(result)
        // Only a sequence that got as far as switching the layout announces
        // one, which is the successful one.
        if case .success = result { afterApply?(fix) }
    }

    func copySelection(in bundleID: String?, completion: @escaping (CopyResult) -> Void) {
        lock.lock()
        copies += 1
        let result = copyResult
        lock.unlock()
        beforeCopyAnswer?()
        completion(result)
    }

    func replaceSelection(
        with text: String,
        targetLayoutID: String,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void
    ) {
        lock.lock()
        replacements.append(
            Replacement(
                text: text, targetLayoutID: targetLayoutID, bundleID: bundleID,
                staleWhenAsked: isStale()))
        let result = self.replaceResult
        lock.unlock()
        duringApply?()
        completion(result)
        // Only a sequence that got as far as switching the layout announces
        // one, which is the successful one.
        if case .success = result { afterReplace?(targetLayoutID) }
    }
}

/// The accessibility gate's answers, dictated.
final class FakeFocusOracle: FocusInspecting {
    private let lock = NSLock()
    private var answer = FocusInspection(security: .notSecure, caretRead: .unavailable)
    private var lengths: [Int?] = []
    private var invalidations = 0
    private var selection: SelectionRead = .noSelection
    private var selectionCalls = 0

    /// Run on the pipeline queue, just before the answer is handed back. The
    /// only way to reproduce a keystroke landing *during* the round trip, which
    /// is the race the input serial exists for.
    var beforeAnswering: (() -> Void)?

    /// The counterpart of `beforeAnswering` for the selection read, and there
    /// for the same reason: a real ⌘C round trip is the better part of a
    /// second, and anything the user does inside it has to be reproducible.
    var beforeSelectionAnswer: (() -> Void)?

    /// What the next `selectedText` reports back. Defaults to the answer a
    /// field with a caret and nothing highlighted gives.
    var selectionAnswer: SelectionRead {
        get {
            lock.lock()
            defer { lock.unlock() }
            return selection
        }
        set {
            lock.lock()
            selection = newValue
            lock.unlock()
        }
    }

    /// How many times the pipeline asked what was selected.
    var selectionRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return selectionCalls
    }

    func answer(_ inspection: FocusInspection) {
        lock.lock()
        answer = inspection
        lock.unlock()
    }

    func answer(caret: CaretRead, security: SecureFieldState = .notSecure) {
        answer(FocusInspection(security: security, caretRead: caret))
    }

    /// The UTF-16 lengths the pipeline asked for, one per inspection.
    var requestedLengths: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return lengths
    }

    var invalidateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invalidations
    }

    func inspect(
        pid: pid_t?, caretTextLength: Int?, completion: @escaping (FocusInspection) -> Void
    ) {
        lock.lock()
        lengths.append(caretTextLength)
        let answer = self.answer
        lock.unlock()
        beforeAnswering?()
        completion(answer)
    }

    func selectedText(pid: pid_t?, completion: @escaping (SelectionRead) -> Void) {
        lock.lock()
        selectionCalls += 1
        let answer = selection
        lock.unlock()
        beforeSelectionAnswer?()
        completion(answer)
    }

    func invalidate() {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }
}

/// The system-wide secure input flag, without the system.
final class FakeSecureInput: SecureInputReading {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func readNow() -> Bool { isEnabled }

    func set(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }
}

// MARK: - The harness

/// A `TypingPipeline` with the three system edges replaced, plus everything a
/// test needs to drive it and to see what it did.
///
/// `start()` is deliberately not called: it registers the frontmost observer and
/// two distributed notification observers, and the tests supply those events
/// themselves. Nothing here touches the window server, the accessibility API or
/// the event tap.
final class PipelineHarness {
    let engine = FakeFixEngine()
    let oracle = FakeFocusOracle()
    let secureInput = FakeSecureInput()
    let suggestionState = SuggestionState()
    let cardFrames = CardFrames()
    let frontmost = FrontmostAppTracker()
    let settings: SettingsStore
    let pipeline: TypingPipeline

    private let suiteName: String
    private let lock = NSLock()
    private var offered: [Fix] = []
    private var appliedFixes: [AppliedFix] = []
    private var rejections = 0
    private var undoCount = 0
    private var hides = 0
    private var switches: [String] = []
    private var flipped: [Flip] = []
    private var decided: [DecisionSnapshot] = []
    private var refreshRequests = 0
    private var latest = BufferSnapshot()
    /// Fulfilled by the next flip that lands. See `awaitFlipCard`.
    private var flipWaiter: XCTestExpectation?

    /// This person's own vocabulary, in memory.
    ///
    /// Injected rather than left to the pipeline's default, which is the real
    /// file in the real Application Support directory: a test that typed
    /// learnable prose would otherwise write counts into the vocabulary of
    /// whoever ran the suite.
    let lexicon = UserLexicon(url: nil)

    /// - Parameter axVerifySkip: seeded into the settings blob before the store
    ///   reads it, because there is no setter for it — it is a hand-edited
    ///   preference by design.
    init(bundleID: String? = Fixtures.app, axVerifySkip: Set<String> = []) {
        suiteName = "com.ali.dodoma.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if !axVerifySkip.isEmpty {
            var seeded = AppSettings.defaults
            seeded.axVerifySkip = axVerifySkip
            defaults.set(try! JSONEncoder().encode(seeded), forKey: SettingsStore.Key.settings)
        }
        settings = SettingsStore(defaults: defaults)
        pipeline = TypingPipeline(
            settings: settings,
            frontmost: frontmost,
            secureInput: secureInput,
            suggestionState: suggestionState,
            cardFrames: cardFrames,
            lexicon: lexicon,
            fixEngine: engine,
            focus: oracle)

        // The layouts a flip renders through. The real cache is populated from
        // the input sources enabled on whichever machine runs the suite, so
        // without this every flip test would depend on the tester having
        // Arabic installed.
        pipeline.layoutPair = { HarnessLayouts.pair }
        // The refusal's recovery path, answering "nothing was repaired" — the
        // only honest default for a harness whose pair comes from a fixture
        // rather than from the machine's input sources, where re-reading the
        // real selection could not change anything.
        setLayoutRefresh { false }

        pipeline.onChange = { [weak self] snapshot in self?.note(snapshot: snapshot) }
        pipeline.onDecision = { [weak self] snapshot in self?.append(decision: snapshot) }
        pipeline.onSuggest = { [weak self] offer in self?.append(offer: offer.fix) }
        pipeline.onAutoApply = { [weak self] applied in self?.append(applied: applied) }
        pipeline.onRequestRejected = { [weak self] in self?.bumpRejections() }
        pipeline.onUndoApplied = { [weak self] in self?.bumpUndos() }
        pipeline.onHideSuggestion = { [weak self] in self?.bumpHides() }
        // Main thread, like the card controller that normally receives it.
        pipeline.onFlipApplied = { [weak self] flip, _ in self?.append(flip: flip) }

        // Every applied fix ends by switching the keyboard layout, and the app
        // hears that back. On by default, because a fix that does not announce
        // its own layout switch is not a fix any user will ever perform.
        engine.afterApply = { [weak self] fix in
            self?.noteLayoutSwitch(fix.targetLayoutID)
            self?.pipeline.inputSourceChanged(to: fix.targetLayoutID)
        }
        engine.afterReplace = { [weak self] targetLayoutID in
            self?.noteLayoutSwitch(targetLayoutID)
            self?.pipeline.inputSourceChanged(to: targetLayoutID)
        }

        pipeline.setCaptureActive(true)
        activate(bundleID)
        drain()
    }

    deinit {
        UserDefaults.standard.removeSuite(named: suiteName)
    }

    // MARK: Driving

    /// Replaces the layout pair the evaluation and the flip resolve against.
    ///
    /// `queue.sync` because the seam is read on the pipeline queue, and a test
    /// that assigned it from its own thread would be racing whatever evaluation
    /// is already in flight.
    func setLayoutPair(_ pair: @escaping () -> (english: KeyboardLayout, arabic: KeyboardLayout)?) {
        pipeline.queue.sync { pipeline.layoutPair = pair }
    }

    /// Replaces the answer the pipeline gets when it asks for the selected
    /// input source to be re-read. The request is counted either way, so a test
    /// can install its own answer and still assert how often it was asked.
    func setLayoutRefresh(_ refresh: @escaping () -> Bool) {
        pipeline.queue.sync {
            pipeline.layoutRefresh = { [weak self] in
                self?.bumpLayoutRefreshRequests()
                return refresh()
            }
        }
    }

    /// Tells the pipeline an application came to the front, the way the real
    /// frontmost observer would.
    func activate(_ bundleID: String?) {
        pipeline.frontmostChanged(
            to: FrontmostApp(bundleID: bundleID, processIdentifier: 42, localizedName: "Test"))
        drain()
    }

    func offer(_ fix: Fix, in bundleID: String? = Fixtures.app) {
        pipeline.queue.sync { pipeline.offerNow(fix, bundleID: bundleID) }
        drain()
    }

    /// Drives `fix` through the gate as an auto-apply, the way the detector
    /// would when it returns `.autoApply`.
    func autoApply(_ fix: Fix, in bundleID: String? = Fixtures.app) {
        pipeline.queue.sync { pipeline.autoApplyNow(fix, bundleID: bundleID) }
        drain()
    }

    func send(_ event: TapEvent) {
        pipeline.queue.sync { pipeline.handle(event) }
        drain()
    }

    func type(_ text: String = "x", keycode: UInt16 = 0) {
        send(.key(CapturedKey(
            keycode: keycode, producedText: text,
            timestamp: Date().timeIntervalSinceReferenceDate)))
    }

    /// - Parameter location: in display coordinates, the way `CGEvent` reports
    ///   a click and the way both card registries store their rectangles.
    func click(at location: CGPoint = .zero) {
        send(.mouseDown(at: location, primaryButton: true))
    }

    /// The user picking a layout out of the menu bar, as the pipeline's own
    /// notification observer would report it.
    func switchLayout(to sourceID: String?) {
        pipeline.inputSourceChanged(to: sourceID)
        drain()
    }

    func undo() {
        pipeline.undoLastFix()
        drain()
    }

    /// - Parameter rounds: more than the default, because the flip is the
    ///   longest chain in the pipeline: security check, selection read, the
    ///   copy that may follow it, resolve, apply, the read-back, finish, and
    ///   the layout announcement each of those hops behind the last.
    func flip(rounds: Int = 10) {
        pipeline.flipSelection()
        drain(rounds)
    }

    /// Lets everything already queued run, and everything those blocks queue in
    /// turn. Six rounds covers the ordinary chain — gate, resolve, apply,
    /// finish; the flip is longer, which is what `flip(rounds:)` is for.
    func drain(_ rounds: Int = 6) {
        for _ in 0..<rounds { pipeline.queue.sync {} }
    }

    /// Waits out the idle trigger, so the evaluation it armed has run.
    ///
    /// An expectation rather than `drain()`, and not only because the delay has
    /// to elapse: the refusal path hops to the main thread to re-read the
    /// selected input source, and the main thread is the one the test itself is
    /// sitting on. Draining the pipeline queue would prove nothing about that
    /// hop; waiting is what lets the main queue run.
    func waitForTrigger(_ test: XCTestCase, timeout: TimeInterval = 5) {
        let fired = test.expectation(description: "the idle trigger fired")
        pipeline.queue.asyncAfter(deadline: .now() + TypingSession.triggerDelay + 0.2) {
            fired.fulfill()
        }
        test.wait(for: [fired], timeout: timeout)
        drain()
    }

    /// The second pass's delay, as the tests run it.
    ///
    /// The shipped 3 seconds is a statement about human pauses, and waiting
    /// it out in every test that touches the retry would add most of a minute
    /// to the suite for no extra coverage. What the pipeline actually depends
    /// on is the ordering — the retry comes after the first evaluation, not
    /// instead of it — and this preserves that. The constant itself is pinned
    /// by `EvaluationTriggerTests`.
    static let shortSettledDelay: TimeInterval = 1.6

    /// Installs `shortSettledDelay`. `queue.sync` because the seam is read on
    /// the pipeline queue.
    func useShortSettledDelay() {
        pipeline.queue.sync { pipeline.settledDelay = Self.shortSettledDelay }
    }

    /// Waits out the second pass, measured from now rather than from the last
    /// keystroke: the caller has already waited out the first trigger, so this
    /// overshoots, which is the safe direction.
    func waitForSettledPass(_ test: XCTestCase, timeout: TimeInterval = 10) {
        let fired = test.expectation(description: "the settled pass fired")
        pipeline.queue.asyncAfter(deadline: .now() + Self.shortSettledDelay + 0.2) {
            fired.fulfill()
        }
        test.wait(for: [fired], timeout: timeout)
        drain()
    }

    /// Waits out the window in which input is ignored after an apply. Needed
    /// only by tests that do a second thing to the pipeline afterwards.
    func waitForApplyTail(_ test: XCTestCase) {
        let done = test.expectation(description: "apply tail window")
        pipeline.queue.asyncAfter(deadline: .now() + TypingPipeline.applyTailWindow + 0.05) {
            done.fulfill()
        }
        test.wait(for: [done], timeout: 5)
        drain()
    }

    // MARK: Observing

    var offers: [Fix] {
        lock.lock()
        defer { lock.unlock() }
        return offered
    }

    var applied: [AppliedFix] {
        lock.lock()
        defer { lock.unlock() }
        return appliedFixes
    }

    var rejectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rejections
    }

    var undoAppliedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return undoCount
    }

    var hideCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hides
    }

    /// Every decision the pipeline published, in order — including the
    /// `skipped` ones, which are the only trace an evaluation that did nothing
    /// leaves behind.
    var decisions: [DecisionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return decided
    }

    var lastDecision: DecisionSnapshot? { decisions.last }

    /// How many times a refused evaluation asked for the selected input source
    /// to be re-read.
    var layoutRefreshRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return refreshRequests
    }

    /// The flips published to the card, in order.
    var flips: [Flip] {
        lock.lock()
        defer { lock.unlock() }
        return flipped
    }

    /// The first flip published to the card, waiting for it if it has not
    /// arrived yet.
    ///
    /// `onFlipApplied` lands on the main thread, which is the thread the test
    /// itself is running on: draining the pipeline queue proves nothing about
    /// it, and reading `flips` straight after a flip would always find it
    /// empty. Waiting on an expectation is what lets the main queue run.
    func awaitFlipCard(_ test: XCTestCase, timeout: TimeInterval = 1) -> Flip? {
        lock.lock()
        if let first = flipped.first {
            lock.unlock()
            return first
        }
        let waiting = test.expectation(description: "a flip was published to the card")
        // Registered under the same lock the callback takes, so a flip landing
        // between the check above and here cannot go unnoticed.
        flipWaiter = waiting
        lock.unlock()

        test.wait(for: [waiting], timeout: timeout)
        return flips.first
    }

    /// The buffer as of the last snapshot the pipeline published.
    var buffer: BufferSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func note(snapshot: BufferSnapshot) {
        lock.lock()
        latest = snapshot
        lock.unlock()
    }

    /// The layout switches the applies announced, in order.
    var layoutSwitches: [String] {
        lock.lock()
        defer { lock.unlock() }
        return switches
    }

    private func noteLayoutSwitch(_ sourceID: String) {
        lock.lock()
        switches.append(sourceID)
        lock.unlock()
    }

    var isEvaluationArmed: Bool {
        pipeline.queue.sync { pipeline.isEvaluationArmed }
    }

    private func append(offer fix: Fix) {
        lock.lock()
        offered.append(fix)
        lock.unlock()
    }

    private func append(applied: AppliedFix) {
        lock.lock()
        appliedFixes.append(applied)
        lock.unlock()
    }

    private func append(decision: DecisionSnapshot) {
        lock.lock()
        decided.append(decision)
        lock.unlock()
    }

    private func bumpLayoutRefreshRequests() {
        lock.lock()
        refreshRequests += 1
        lock.unlock()
    }

    private func append(flip: Flip) {
        lock.lock()
        flipped.append(flip)
        let waiting = flipWaiter
        flipWaiter = nil
        lock.unlock()
        waiting?.fulfill()
    }

    private func bumpRejections() {
        lock.lock()
        rejections += 1
        lock.unlock()
    }

    private func bumpUndos() {
        lock.lock()
        undoCount += 1
        lock.unlock()
    }

    private func bumpHides() {
        lock.lock()
        hides += 1
        lock.unlock()
    }
}

// MARK: - Layouts

/// The committed `uchr` snapshot, as the flip paths need it.
///
/// `DodomaCoreTests` loads the same file through `LayoutFixtures`, but one test
/// target cannot import another and the JSON is a resource of that target's
/// bundle, so it is read off the source tree here. `#filePath` is what makes
/// that work under both `swift test` and Xcode, whose working directories
/// differ.
enum HarnessLayouts {
    static let url =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/DodomaAppTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("DodomaCoreTests/Fixtures/layout-tables.json")

    /// Nil when the snapshot is missing or malformed. Tests that need it say
    /// so once, rather than failing with a decoding error each.
    static let pair: (english: KeyboardLayout, arabic: KeyboardLayout)? = {
        guard
            let data = try? Data(contentsOf: url),
            let fixtures = try? JSONDecoder().decode([LayoutFixture].self, from: data),
            let english = fixtures.first(where: { $0.sourceID == Fixtures.english })?.makeLayout(),
            let arabic = fixtures.first(where: { $0.sourceID == Fixtures.arabic })?.makeLayout()
        else { return nil }
        return (english, arabic)
    }()
}

// MARK: - Fixtures

enum Fixtures {
    static let app = "com.apple.TextEdit"
    static let otherApp = "com.tinyspeck.slackmacgap"

    static let english = "com.apple.keylayout.ABC"
    static let arabic = "com.apple.keylayout.Arabic"

    /// `hgsghl ` → `السلام `, the canonical fix, trailing separator and all.
    static let fix = Fix(
        deleteCount: 7,
        insertText: "السلام ",
        targetLayoutID: arabic,
        sourceLayoutID: english,
        replacedText: "hgsghl ",
        capsMode: .asTyped)

    /// A second, different fix, for the tests about replacement.
    static let otherFix = Fix(
        deleteCount: 4,
        insertText: "ودك ",
        targetLayoutID: arabic,
        sourceLayoutID: english,
        replacedText: "l,;a",
        capsMode: .asTyped)

    /// A caret read that matches `fix`: the typed text is what is on screen.
    static let caretBeforeFix = CaretRead.value("please send hgsghl ")
    /// A caret read that matches the *inverse* of `fix`: the correction is on
    /// screen, which is what an undo verifies against.
    static let caretAfterFix = CaretRead.value("please send السلام ")
}
