import AppKit
import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Everything the suggestion panel needs to draw itself and to find the caret.
struct SuggestionOffer {
    let fix: Fix
    /// The application the fix is for. The caret lookup needs it; the panel
    /// controller passes it straight through to the accessibility layer.
    let pid: pid_t?
}

/// The offer as the pipeline remembers it, which is more than the panel needs.
private struct PendingSuggestion {
    let fix: Fix
    let bundleID: String?
    /// The input serial at the moment the offer was made. An acceptance is only
    /// valid while this has not moved.
    let serial: UInt64
}

/// The pipeline's `@objc` ear for the two Text Input Sources notifications.
///
/// `DistributedNotificationCenter`'s `suspensionBehavior` argument only exists
/// on the selector-based registration, and an `@objc` selector target has to
/// descend from `NSObject` — which the pipeline deliberately does not, so it
/// gains an object rather than a superclass. It holds its owner weakly: the
/// pipeline retains this, and the notification centre retains neither.
private final class InputSourceNotificationTarget: NSObject {
    weak var pipeline: TypingPipeline?

    @objc func selectedInputSourceChanged(_ notification: Notification) {
        pipeline?.selectedInputSourceChanged()
    }

    @objc func enabledInputSourcesChanged(_ notification: Notification) {
        pipeline?.enabledInputSourcesChanged()
    }
}

/// Thin app-side shell around `TypingSession`.
///
/// Responsibilities kept here (and only here): the serial queue, the AppKit
/// notification subscriptions, the clock, the idle trigger, the asynchronous
/// accessibility gate, logging, and publishing snapshots. Every decision the
/// shell makes — what the policy is, in which order the safety checks apply,
/// what to do with an unverifiable caret — is a pure function in `DodomaCore`,
/// which is unit tested directly.
final class TypingPipeline {
    /// How long typed input is ignored after a fix completes. The tap already
    /// filters our own events by marker; this is the belt-and-braces second
    /// line, covering the tail of an injection that is still draining through
    /// the event system when the engine reports back.
    static let applyTailWindow: TimeInterval = 0.12

    let queue = DispatchQueue(label: "com.ali.dodoma.pipeline", qos: .userInitiated)

    /// Called on `queue` after every processed event.
    var onChange: ((BufferSnapshot) -> Void)?
    /// Called on `queue` after every evaluation, and again when an apply ends.
    var onDecision: ((DecisionSnapshot) -> Void)?
    /// Called on `queue` after a fix has been written to the screen.
    var onAutoApply: ((AppliedFix) -> Void)?
    /// Called on `queue` after a fix has been taken back off the screen.
    var onUndoApplied: (() -> Void)?
    /// Called on `queue` when a fix was good enough to offer but not to apply,
    /// either because the app is suggest-only, because the scores were middling
    /// or because the caret could not be verified.
    var onSuggest: ((SuggestionOffer) -> Void)?
    /// Called on `queue` when the panel must come down. Every dismissal except
    /// the panel's own timeout starts here, because every one of them is a
    /// consequence of something only this queue can see.
    var onHideSuggestion: (() -> Void)?
    /// Called on `queue` when something the user asked for by name — an
    /// accepted suggestion, an undo — was not carried out after all, because
    /// the caret no longer matches or the field turned out to be secure.
    /// Silence there would look exactly like a broken key.
    var onRequestRejected: (() -> Void)?
    /// Words that just crossed into the dictionary, the language they belong
    /// to, and the app that was in front. Main thread.
    var onWordsLearned: (([String], Language, pid_t?) -> Void)?
    /// A flip the user asked for by name that reached the screen, and the app
    /// it went into. Main thread.
    ///
    /// Separate from `onAutoApply`, which is also called for a flip: that one
    /// is the record of a fix — the `Last fix` line, the flash — while this
    /// one carries the `Flip` itself, which is what the card needs to show the
    /// text and to offer learning it.
    var onFlipApplied: ((Flip, pid_t?) -> Void)?

    /// Shared, cached view of the enabled keyboard layouts. Owned here because
    /// this is where the invalidation notification is observed.
    let layoutEngine = LayoutEngine()

    private let session: TypingSession
    /// This user's own vocabulary. One instance, shared by both language
    /// models, so a word learned in English is not credited to Arabic.
    ///
    /// Injected rather than constructed here because the settings window shows
    /// and edits the same words. Two instances over one file would each hold a
    /// stale copy of the other's writes, and the last one to save would win.
    let lexicon: UserLexicon

    private let fixEngine: FixApplying
    private let settings: SettingsStore
    private let frontmost: FrontmostAppTracker
    private let secureInput: SecureInputReading
    /// Shared with the suggestion controller: the caret lookup and the security
    /// check must queue behind one another rather than race on two queues.
    let focusOracle = FocusOracle()
    /// The oracle as the gate uses it. Normally `focusOracle`; a test hands in
    /// something that answers without an accessibility grant.
    private let focus: FocusInspecting
    /// Written by the panel controller, read here and on the tap thread.
    private let suggestionState: SuggestionState
    /// The rectangles of Harf's own cards, so a click on one is not counted as
    /// input. Written by the card controllers on the main thread, read here.
    private let cardFrames: CardFrames

    /// Queue-confined state.
    private var pendingEvaluation: DispatchWorkItem?
    /// Whether this burst of typing has already had its second look.
    ///
    /// Set when the settled pass is armed rather than when it runs, so that a
    /// pass which itself ignores the buffer cannot arm another: the retry is
    /// one per burst, and `armTrigger()` — which every keystroke reaches — is
    /// the only thing that clears it.
    private var settledPassUsed = false
    /// The last refusal reported, so the same one is not reported again.
    /// Queue-confined, like everything the evaluation reads.
    private var skipLedger = SkipLedger()
    /// True from the moment a refused evaluation asks the main thread to re-read
    /// the selected input source until that answer has come back. Without it a
    /// burst of refusals would queue a main-thread Text Input Sources
    /// enumeration each.
    private var isRefreshingLayout = false
    private var isApplying = false
    /// True from the moment a decision is handed to the accessibility gate
    /// until the gate resolves. Distinct from `isApplying`: nothing has been
    /// written to the screen yet, so input arriving in this window is real
    /// input and must be buffered, not dropped — it just invalidates the fix.
    private var isGating = false
    /// Bumped by every input. Work decided at one value and carried out at
    /// another is work about text that has since moved. Lock-protected rather
    /// than queue-confined because the injector reads it from its own queue.
    private let inputs = InputSerial()
    /// The same count, restricted to what the *user* did: keystrokes and
    /// clicks. `inputs` deliberately counts application switches and layout
    /// changes too, because work in flight is invalidated by all of them — but
    /// a fix ends by switching the layout, and the app hears that back as an
    /// input a few milliseconds later, so a rule phrased against `inputs` would
    /// read every fix as having been overtaken the instant it landed. The undo
    /// slot is stamped against this one; the other two signals have their own,
    /// sharper rules in `FixHistory`.
    private let userInputs = InputSerial()
    /// Set when real input was discarded because a fix was in flight. Those
    /// keystrokes reached the screen but not the buffer, so the buffer no
    /// longer describes the text in front of the caret.
    private var droppedInputDuringApply = false
    private var captureActive = false
    private var paused: Bool
    private var secureInputActive = false
    /// The policy of the app that currently has focus, cached so that the tap
    /// callback does not take the settings lock once per keystroke. Only used
    /// to decide whether to buffer at all; the evaluation resolves the policy
    /// again, authoritatively.
    private var frontmostPolicy: AppPolicy
    private var lastDecision: DecisionSnapshot?
    /// The undo slot. Mutated here, on the queue; read from the main thread by
    /// the menu, which is why it is behind its own lock.
    private let history = FixHistoryStore()
    /// The suggestion currently on offer, if any. Queue-confined, and the
    /// authority on whether there is one: the shared `SuggestionState` says
    /// whether a *window* is on screen, which lags this by one main-thread hop.
    private var pendingSuggestion: PendingSuggestion?
    /// Region texts turned down recently, so a dismissal is not undone by the
    /// next quiet period. Queue-confined.
    private var suppression = SuggestionSuppression()
    /// Region texts the user has taken back. The same mechanism as `suppression`
    /// and for the same reason, one layer deeper: without it the quiet period a
    /// second after an undo re-applies the very fix that was just undone. It
    /// feeds both the offer check and `TextGuards.recentlyUndone`, because the
    /// re-application would otherwise be decided below the offer. Queue-confined.
    private var undoSuppression = SuggestionSuppression()

    private var frontmostObserver: UUID?
    /// The `@objc` ear for the two Text Input Sources notifications. Retained
    /// here because the notification centre does not retain an observer, and it
    /// points back weakly.
    private let inputSourceTarget = InputSourceNotificationTarget()

    private static let selectedSourceNotification = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String)
    private static let enabledSourcesNotification = Notification.Name(
        kTISNotifyEnabledKeyboardInputSourcesChanged as String)

    /// Must be created on the main thread.
    ///
    /// - Parameters:
    ///   - fixEngine: the injector. Defaults to the real one; a test passes
    ///     something that does not post events into the tester's own windows.
    ///   - focus: the accessibility gate's oracle. Defaults to `focusOracle`.
    init(
        settings: SettingsStore = .shared,
        frontmost: FrontmostAppTracker,
        secureInput: SecureInputReading,
        suggestionState: SuggestionState,
        cardFrames: CardFrames,
        lexicon: UserLexicon? = nil,
        fixEngine: FixApplying? = nil,
        focus: FocusInspecting? = nil
    ) {
        self.lexicon = lexicon ?? UserLexicon(url: UserLexicon.defaultURL())
        self.settings = settings
        self.frontmost = frontmost
        self.secureInput = secureInput
        self.suggestionState = suggestionState
        self.cardFrames = cardFrames
        self.paused = settings.paused
        self.secureInputActive = secureInput.isEnabled
        frontmostPolicy = settings.policy(for: frontmost.bundleID)
        self.fixEngine = fixEngine ?? FixEngine(frontmost: frontmost)
        self.focus = focus ?? focusOracle
        session = TypingSession(frontmostBundleID: frontmost.bundleID)
    }

    func start() {
        frontmostObserver = frontmost.addObserver { [weak self] app in
            self?.frontmostChanged(to: app)
        }

        // The selector API rather than the block one, for its one extra
        // argument. A distributed notification's default suspension behaviour
        // is `.coalesce`, which holds a notification while the receiving
        // application is *inactive* and delivers only the most recent one when
        // it becomes active again. Harf is an LSUIElement: it is never active,
        // so there is no such moment, and the selection notification — the only
        // thing that tells the cache a ⌃Space happened — can be held or dropped
        // indefinitely. `.deliverImmediately` is the whole reason this is not
        // the block API.
        //
        // Delivery is still on the main thread: the distributed centre is
        // driven by the main run loop, which is where both handlers read Text
        // Input Sources.
        inputSourceTarget.pipeline = self
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            inputSourceTarget,
            selector: #selector(InputSourceNotificationTarget.selectedInputSourceChanged(_:)),
            name: Self.selectedSourceNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(
            inputSourceTarget,
            selector: #selector(InputSourceNotificationTarget.enabledInputSourcesChanged(_:)),
            name: Self.enabledSourcesNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately)

        warmLayoutCache()
    }

    /// `kTISNotifySelectedKeyboardInputSourceChanged` arrived. Main thread.
    fileprivate func selectedInputSourceChanged() {
        // Which layout it changed *to* is read here, on the main thread,
        // because that is where Text Input Sources calls belong and because the
        // undo slot cannot tell the fix's own switch from the user's without it.
        let selected = LayoutEngine.selectedLayoutID()
        // The cache resolves the pair against the selected source, and this is
        // the only notification that says the selection moved. Without it a
        // ⌃Space switch is invisible until the enabled sources change, which
        // for most people is never.
        layoutEngine.noteSelectedLayout(selected)
        inputSourceChanged(to: selected)
    }

    /// `kTISNotifyEnabledKeyboardInputSourcesChanged` arrived. Main thread.
    fileprivate func enabledInputSourcesChanged() {
        layoutEngine.invalidate()
        warmLayoutCache()
    }

    /// The selected keyboard layout changed — by the user's hand, or by the
    /// last fix, which ends by switching it. Main thread.
    func inputSourceChanged(to sourceID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            // Before `process`, which is where the buffer reset happens: the
            // two are independent, and the undo rule wants the layout, which
            // `SessionInput` does not carry.
            self.history.noteInputSource(sourceID)
            self.process(.inputSourceChanged(at: Self.now()))
        }
    }

    /// Another application came to the front. Main thread.
    func frontmostChanged(to app: FrontmostApp) {
        // The cached focus verdict belongs to the app that just lost focus.
        focus.invalidate()
        // macOS remembers an input source per application, so an application
        // switch is the *other* moment the selection moves — and this
        // notification comes through AppKit rather than the distributed centre,
        // so it is not subject to the coalescing that can swallow a selection
        // change while an LSUIElement is inactive. One Text Input Sources read,
        // no enumeration: cheap enough to do on every switch, and it keeps the
        // cached selection honest for free most of the time.
        layoutEngine.noteSelectedLayout(LayoutEngine.selectedLayoutID())
        submit(.appActivated(bundleID: app.bundleID, at: Self.now()))
    }

    /// Enumerating input sources is a Text Input Sources call, which prefers
    /// the main thread. Warming the cache here and after every invalidation —
    /// both of which happen on the main thread — keeps the pipeline queue from
    /// having to enumerate in the middle of an evaluation.
    private func warmLayoutCache() {
        _ = layoutEngine.layouts()
    }

    /// Main thread only.
    func stop() {
        if let frontmostObserver {
            frontmost.removeObserver(frontmostObserver)
            self.frontmostObserver = nil
        }
        let center = DistributedNotificationCenter.default()
        center.removeObserver(
            inputSourceTarget, name: Self.selectedSourceNotification, object: nil)
        center.removeObserver(
            inputSourceTarget, name: Self.enabledSourcesNotification, object: nil)
        inputSourceTarget.pipeline = nil
        queue.async { [weak self] in
            // Clearing the flags as well as the timer: a tap event already
            // queued behind this block could otherwise arm a trigger that
            // fires a second into shutdown, and a gate still in flight could
            // arm one when it resolves.
            self?.captureActive = false
            self?.isGating = false
            self?.cancelTrigger()
            self?.dismissSuggestion("the pipeline is shutting down", remember: false)
        }
    }

    /// Nothing is evaluated — and so nothing is ever injected — unless the tap
    /// is actually running, which is the app's proxy for "permissions granted".
    func setCaptureActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.captureActive != active else { return }
            self.captureActive = active
            if !active {
                self.cancelTrigger()
                self.dismissSuggestion("capture stopped", remember: false)
            }
        }
    }

    /// Takes the user's settings, from the initial load or from a menu change.
    /// Callable from any thread.
    func apply(_ updated: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            if updated.paused, !self.paused {
                self.paused = true
                self.suspend(reason: .manual, describedAs: "paused")
            } else {
                self.paused = updated.paused
            }

            // How much is held, and for how long, are privacy controls: apply
            // them before anything else, and to the buffer as it already
            // stands rather than only to what arrives next.
            self.session.setBufferCapacity(updated.bufferCapacity)
            self.session.idleTimeout = updated.idleTimeout
            if !updated.learnVocabulary { self.lexicon.clear() }

            let policy = updated.policy(for: self.session.currentFrontmostBundleID)
            if policy == .off, self.frontmostPolicy != .off {
                self.suspend(reason: .manual, describedAs: "this app was set to Off")
            }
            self.frontmostPolicy = policy
        }
    }

    /// The system-wide secure event input flag. Callable from the main thread.
    func setSecureInput(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.secureInputActive != active else { return }
            self.secureInputActive = active
            if active { self.suspend(reason: .secureInput, describedAs: "secure input") }
        }
    }

    /// Stops buffering and throws away what is buffered. Queue-confined.
    private func suspend(reason: ResetReason, describedAs description: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        Log.pipeline.info("capture suspended: \(description, privacy: .public)")
        cancelTrigger()
        // Not remembered as a refusal: the user did not turn this down, and a
        // pause should not poison the next minute of suggestions.
        dismissSuggestion("capture suspended", remember: false)
        // A gate resolving after this must not act on a decision taken before.
        inputs.bump()
        resetBuffer(reason: reason)
    }

    /// Must be called on `queue`. Called by the event tap.
    func handle(_ event: TapEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .key(let key):
            process(.key(key))

        case .mouseDown(let location, let primaryButton):
            // A click on one of Harf's own cards is not input. The ordinary
            // mouse-down path bumps the input serial and ends the undo window,
            // so routing a press of the learned card's Undo button through it
            // would throw away the ⌘⌥Z slot that button exists to use. The
            // card's own handler still gets the click through its panel.
            //
            // The suggestion card is not in here on purpose: its clicks must
            // reach `mouseDisposition` below, which turns one into an accept.
            if cardFrames.contains(location) { return }

            // A click on the card is the second way to accept, and it must not
            // be treated as input first: the ordinary mouse-down path bumps the
            // input serial, which would make the acceptance it is *part of*
            // invalid. The test is done here rather than in the tap callback so
            // the tap does no arithmetic.
            let panel = suggestionState.snapshot
            switch SuggestionKeys.mouseDisposition(
                visible: panel.visible && pendingSuggestion != nil,
                primaryButton: primaryButton,
                panelFrame: panel.panelFrame,
                location: location)
            {
            case .accept:
                acceptSuggestion()
            case .pass, .dismissAndPass:
                process(.mouseDown(at: Self.now()))
            }

        case .suggestionAccept:
            acceptSuggestion()

        case .suggestionDismiss:
            dismissSuggestion("the user pressed escape")

        case .tapInterrupted(let reason):
            tapInterrupted(reason: reason)
        }
    }

    /// Input reached the screen without reaching this queue. Queue-confined.
    ///
    /// Everything the app is willing to delete is counted backwards from the
    /// caret against a buffer that claims to describe what is in front of it,
    /// so the honest response to "some number of keystrokes are missing" is to
    /// stop claiming anything: the buffer goes, the undo slot goes, and any
    /// card on screen goes with them. Both serials move, because work already
    /// in flight — a gate, a fix the injector has not started — was decided
    /// against text that has since moved.
    private func tapInterrupted(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))

        inputs.bump()
        userInputs.bump()
        // Not remembered as a refusal: the user did not turn the card down,
        // they typed past it in a window this queue could not see.
        dismissSuggestion("the tap missed input", remember: false)
        // Explicitly rather than through `ResetReason.purgesHistory`: the
        // keystroke log is still an honest record of what the tap did see, and
        // only the undo has to go. Its backspaces are counted from the caret,
        // and whatever the tap missed is now in front of it.
        history.invalidate(.purged)
        cancelTrigger()
        guard !session.isBufferEmpty else { return }
        Log.pipeline.error(
            "typed buffer dropped: the tap missed input (\(reason, privacy: .public))")
        resetBuffer(reason: .tapInterrupted)
    }

    /// Hops onto `queue` from wherever the caller is.
    private func submit(_ input: SessionInput) {
        queue.async { [weak self] in
            self?.process(input)
        }
    }

    /// Queue-confined.
    private func process(_ input: SessionInput) {
        dispatchPrecondition(condition: .onQueue(queue))

        // Before every early return below: input the pipeline chose not to
        // buffer still reached the screen, and that is exactly what the
        // in-flight work needs to know about. Ahead of the suppression check
        // too, so that typing during a pause still counts as having happened.
        inputs.bump()
        if Self.isTypingSignal(input) { userInputs.bump() }

        // Every kind of input invalidates an open suggestion — a keystroke and
        // a click because the text moved, an application switch and a layout
        // change because the fix was about somewhere else. This is also the
        // path that covers the gap between the offer and the panel actually
        // appearing, when the tap does not yet know there is one.
        dismissSuggestion("input arrived")

        // Withdrawing the undo is decided from the input rather than from the
        // reset it caused, and ahead of every early return below, for the same
        // reason: after a fix the buffer is already empty, so a click resets
        // nothing and reports no reason at all — and a click is precisely the
        // signal that the user has moved on and ⌘⌥Z now means something else.
        if FixHistory.endsUndoWindow(input) {
            history.invalidate(.userMovedOn)
        }
        if case .appActivated(let bundleID, _) = input {
            history.noteFrontmost(bundleID: bundleID)
        }

        if isSuppressed, Self.isTypingSignal(input) {
            // Not "ignored": never seen. While the pause is on, secure input is
            // enabled or the frontmost app is Off, keystrokes do not enter the
            // buffer at all — so there is nothing held in memory for a password
            // manager, and nothing to evaluate later.
            return
        }

        if isApplying, Self.isTypingSignal(input) {
            // Either our own injection came back despite the marker filter, or
            // the user typed into the middle of a rewrite. Both would corrupt
            // the buffer relative to what is on screen.
            droppedInputDuringApply = true
            Log.fix.debug("input dropped while a fix was being applied")
            return
        }

        // Input the pipeline is willing to buffer is a new situation, so the
        // last refusal is no longer the thing being reported about — the next
        // occurrence of it deserves its own line. Deliberately not reached by
        // input that was dropped or suppressed above: none of that arms a
        // trigger, so none of it can produce a refusal to report.
        skipLedger.clear()

        let outcome = session.handle(input)

        if case .appActivated = input {
            frontmostPolicy = settings.policy(for: session.currentFrontmostBundleID)
        }

        if let reason = outcome.performedReset {
            Log.pipeline.debug("buffer reset reason=\(reason.rawValue, privacy: .public)")
        }
        updateTrigger(after: outcome)
        onChange?(outcome.snapshot)
    }

    /// Nothing may be buffered. Queue-confined.
    private var isSuppressed: Bool { paused || secureInputActive || frontmostPolicy == .off }

    private static func isTypingSignal(_ input: SessionInput) -> Bool {
        switch input {
        case .key, .mouseDown: return true
        case .appActivated, .inputSourceChanged: return false
        }
    }

    // MARK: - Idle trigger

    private func updateTrigger(after outcome: SessionOutcome) {
        switch outcome.action {
        case .append, .backspace:
            if outcome.snapshot.keyCount > 0 {
                armTrigger()
            } else {
                cancelTrigger()
            }
        case .reset:
            cancelTrigger()
        case .ignore:
            // The buffer did not move, so neither should the timer.
            break
        case nil:
            if outcome.performedReset != nil { cancelTrigger() }
        }
    }

    private func armTrigger() {
        cancelTrigger()
        // A keystroke starts the burst over, so the second look is on the table
        // again — for the text as it now stands.
        settledPassUsed = false
        if let refusal = Self.evaluationRefusal(
            captureActive: captureActive, isApplying: isApplying, isGating: isGating,
            isSuppressed: isSuppressed)
        {
            noteSkipped(refusal, phrased: "not armed")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.triggerFired()
        }
        pendingEvaluation = work
        queue.asyncAfter(deadline: .now() + TypingSession.triggerDelay, execute: work)
    }

    private func cancelTrigger() {
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
    }

    private func triggerFired() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingEvaluation = nil
        // `isSuppressed` is deliberately not among these: a pause, a secure
        // field or an Off app all empty the buffer on their way in, so by the
        // time a trigger armed before them fires there is nothing left to refuse
        // about — and reporting one would put a line on the log for every
        // keystroke typed during a pause.
        if let refusal = Self.evaluationRefusal(
            captureActive: captureActive, isApplying: isApplying, isGating: isGating,
            isSuppressed: false)
        {
            noteSkipped(refusal)
            return
        }
        guard let last = session.lastKeyTime else {
            noteSkipped(.nothingTyped)
            return
        }

        // A key may have landed between the last arming and this block being
        // dequeued; the timestamp is the authority, not the timer. Re-schedule
        // for the remainder rather than dropping the evaluation, so the buffer
        // cannot end up permanently un-evaluated.
        let now = Self.now()
        guard TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: now) else {
            let remaining = TypingSession.triggerDelay - (now - last)
            let work = DispatchWorkItem { [weak self] in
                self?.triggerFired()
            }
            pendingEvaluation = work
            queue.asyncAfter(deadline: .now() + max(remaining, 0.001), execute: work)
            return
        }
        evaluate()
    }

    /// Schedules the one further evaluation a buffer gets after being left
    /// alone, at `settledDelay` from the last keystroke. Queue-confined.
    ///
    /// The first evaluation runs a second after the user stops, and a second of
    /// silence says nothing: it is as consistent with a finished word as with a
    /// pause in the middle of one, which is why the confident gate will not take
    /// a token no whitespace key completed. Three and a half seconds is not
    /// ambiguous, so the buffer is offered once more with that token read as
    /// finished — and once only, which is what `settledPassUsed` enforces.
    private func armSettledPass() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !settledPassUsed, !session.isBufferEmpty else { return }
        guard let last = session.lastKeyTime else { return }
        cancelTrigger()
        // The same refusals arming the ordinary trigger honours, in the same
        // order. Nothing about a second look makes a paused app, a secure field
        // or an apply in flight any more willing to be evaluated.
        if let refusal = Self.evaluationRefusal(
            captureActive: captureActive, isApplying: isApplying, isGating: isGating,
            isSuppressed: isSuppressed)
        {
            noteSkipped(refusal, phrased: "second pass not armed")
            return
        }

        settledPassUsed = true
        let work = DispatchWorkItem { [weak self] in
            self?.settledTriggerFired()
        }
        pendingEvaluation = work
        let remaining = settledDelay - (Self.now() - last)
        queue.asyncAfter(deadline: .now() + max(remaining, 0.001), execute: work)
    }

    private func settledTriggerFired() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingEvaluation = nil
        // `isSuppressed` deliberately absent, exactly as in `triggerFired()`.
        if let refusal = Self.evaluationRefusal(
            captureActive: captureActive, isApplying: isApplying, isGating: isGating,
            isSuppressed: false)
        {
            noteSkipped(refusal)
            return
        }
        guard let last = session.lastKeyTime else {
            noteSkipped(.nothingTyped)
            return
        }

        // The timestamp is the authority here too: a key may have landed between
        // the arming and this block being dequeued. That key will have armed the
        // ordinary trigger and cleared `settledPassUsed`, so the honest thing is
        // to wait out the remainder rather than evaluate text the user is still
        // adding to.
        let now = Self.now()
        guard
            TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: now, after: settledDelay)
        else {
            let remaining = settledDelay - (now - last)
            let work = DispatchWorkItem { [weak self] in
                self?.settledTriggerFired()
            }
            pendingEvaluation = work
            queue.asyncAfter(deadline: .now() + max(remaining, 0.001), execute: work)
            return
        }
        evaluate(trailingTokenSettled: true)
    }

    // MARK: - Evaluation

    /// Counts the words of a run the detector examined and left alone.
    ///
    /// "Left alone" is the whole safeguard. It means the detector rendered the
    /// keys under both layouts, scored them, and concluded the text already
    /// reads as the language it is in — which is the only moment the app has
    /// grounds to treat those words as this person's vocabulary rather than as
    /// something waiting to be corrected. A run that produced a candidate is
    /// never counted, however it was resolved, so wrong-layout text cannot
    /// teach itself into the dictionary.
    private func learnVocabulary(from detection: Detector.Detection, using detector: Detector) {
        guard settings.learnVocabulary else { return }
        guard case .ignore = detection.decision, detection.region == nil else { return }
        // Not the whole buffer. With no candidate region there was no region to
        // guard, so nothing here has been asked whether it reads as prose at
        // all, and the run at the caret is still being typed. `learnableProse`
        // is that question, asked of the finished part — without it a path, an
        // identifier, or a passphrase at a prompt that did not raise secure
        // input is counted as this person's vocabulary on first sighting.
        guard let text = TextGuards.learnableProse(in: session.currentText) else { return }
        let model = detector.model(for: detection.typedLanguage)
        // Only words the shipped list does not already have.
        //
        // Counting everything meant the file filled with "the", "and" and
        // "create" — words that were already known, so learning them changed
        // no score, while the counts amounted to a frequency profile of
        // ordinary writing sitting on disk. The gap this exists to close is
        // the vocabulary the subtitle corpus lacks, so that is all it records:
        // what is missing, and how often it is used.
        let unknown = model.vocabulary(in: text).filter { !model.isKnownWord($0) }
        guard !unknown.isEmpty else { return }
        let promoted = lexicon.observe(unknown, language: detection.typedLanguage)
        lexicon.saveIfDue()

        // A crossing changes how everything after it scores, and it is the one
        // thing here that outlives the session. Saying so is the difference
        // between a dictionary the user owns and one that happens to them.
        guard !promoted.isEmpty else { return }
        let language = detection.typedLanguage
        let pid = frontmost.current.processIdentifier
        DispatchQueue.main.async { [weak self] in
            self?.onWordsLearned?(promoted, language, pid)
        }
    }

    /// - Parameter trailingTokenSettled: true only for the second pass. See
    ///   `armSettledPass()`; the decision function is where it is read.
    private func evaluate(trailingTokenSettled: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))

        let bundleID = session.currentFrontmostBundleID
        let now = Self.now()

        // Steps (a) to (c) of the safety order. The secure-input flag is read
        // from the system here rather than from the monitor's cache: the poll
        // is a second wide, and finishing a password and pausing is precisely
        // how you land inside that second.
        let resolved = settings.policy(for: bundleID)
        let preflight = SafetyGate.preflight(
            paused: paused,
            secureInputEnabled: secureInputActive || secureInput.readNow(),
            policy: resolved)

        let policy: AppPolicy
        switch preflight {
        case .blocked(let reason, let resetBuffer):
            if let resetBuffer { self.resetBuffer(reason: resetBuffer) }
            // Published *and* logged. The debug window has always shown this
            // one; the log line is what makes it visible from outside the
            // process, which is the whole difference between an app that is
            // idle and one that has quietly stopped working. The reason is
            // SafetyGate's own wording, not a `SkipReason`: it names which of
            // the three preflight conditions blocked, which is more than
            // `.suppressed` says.
            noteSkipped(reason)
            publish(
                .skipped(reason: reason, policy: resolved, bundleID: bundleID, evaluatedAt: now))
            return
        case .proceed(let allowed):
            policy = allowed
        }

        // The cache, not `currentPair()`: this runs on the pipeline queue, and
        // enumerating input sources is a Text Input Sources call that belongs on
        // the main thread.
        guard let pair = currentLayoutPair() else {
            // The two-day bug. This branch used to re-arm unconditionally and
            // say nothing, on the theory that a `nil` pair means a cold cache
            // and a cold cache is always repopulated on the main thread a
            // moment later. It is also what a *warm* cache with a stale
            // selection returns — and that one never heals on its own, so the
            // re-arm became a one-second loop that ran for two days while the
            // log stayed empty.
            //
            // So: say so once, show it in the debug window, and ask the main
            // thread to re-read the selection. Re-arming is now that refresh's
            // decision, not this one's: retrying against an unchanged refusal
            // is the loop being replaced.
            noteSkipped(.noLayoutPair)
            publish(
                .skipped(
                    reason: SkipReason.noLayoutPair.rawValue, policy: policy, bundleID: bundleID,
                    evaluatedAt: now))
            refreshLayoutSelection()
            return
        }

        let detector = Detector(englishLayout: pair.english, arabicLayout: pair.arabic)
        detector.englishModel.lexicon = lexicon
        detector.arabicModel.lexicon = lexicon
        let started = Self.now()
        // Step (b), second half: `suggestOnly` is capped inside the decision
        // function, which is the one place that reads `AppPolicy`.
        guard
            let detection = session.evaluate(
                detector: detector, policy: policy, aggressiveness: settings.aggressiveness,
                confidentScore: settings.confidentScore,
                recentlyUndone: undoSuppression.texts(bundleID: bundleID, at: now),
                trailingTokenSettled: trailingTokenSettled)
        else {
            noteSkipped(.emptyBuffer)
            return
        }
        let duration = Self.now() - started

        // Not on the second pass. It is the same buffer the first evaluation
        // already read, so counting its words again would be one pause in the
        // typing masquerading as two sightings — and ten sightings is what a
        // word needs to join this person's dictionary.
        if !trailingTokenSettled { learnVocabulary(from: detection, using: detector) }

        let snapshot = DecisionSnapshot(
            detection: detection, policy: policy, bundleID: bundleID, duration: duration,
            evaluatedAt: now)

        // The evaluation got all the way here, so whatever it last refused for
        // is history: the next time that refusal comes round it is news again.
        skipLedger.clear()

        // Deliberately not published or logged yet. The snapshot carries the
        // region — the user's own text — and the focused field has not been
        // checked. In a password field that text is a password, and §6(c) says
        // nothing is shown. `resolveGate` publishes it, or does not.
        beginGate(for: detection.decision, snapshot: snapshot, policy: policy, bundleID: bundleID)
    }

    /// The first condition, in safety order, that stops an evaluation from
    /// happening at all — or `nil` when none of them does.
    ///
    /// Pure and static because the order is the interesting part and it is
    /// asked at three different points in the chain: when the trigger is armed,
    /// when it fires, and when the accessibility gate is about to open. Each of
    /// those used to spell the same `guard` out for itself, so each could drift
    /// from the others, and none of them said which condition it was that had
    /// stopped it.
    ///
    /// - Parameter isSuppressed: pass `false` from a caller that deliberately
    ///   does not check it. Only arming does; see `triggerFired()`.
    static func evaluationRefusal(
        captureActive: Bool, isApplying: Bool, isGating: Bool, isSuppressed: Bool
    ) -> SkipReason? {
        if !captureActive { return .captureInactive }
        if isApplying { return .applyInFlight }
        if isGating { return .gateOpen }
        if isSuppressed { return .suppressed }
        return nil
    }

    private func noteSkipped(_ reason: SkipReason, phrased prefix: String = "evaluation skipped") {
        noteSkipped(reason.rawValue, phrased: prefix)
    }

    /// Says once that nothing was done, and why. Queue-confined.
    ///
    /// `.info`, not `.debug`: debug messages are not written to the persistent
    /// store, which is exactly why two days of an app doing nothing left no
    /// trace anyone could read afterwards. Nothing here is ever typed text —
    /// every reason is a fixed string chosen from `SkipReason` or from
    /// `SafetyGate`, which is what makes the line safe to emit unconditionally,
    /// without the `debugLogging` opt-in a decision line needs.
    private func noteSkipped(_ reason: String, phrased prefix: String = "evaluation skipped") {
        dispatchPrecondition(condition: .onQueue(queue))
        let line = "\(prefix): \(reason)"
        guard skipLedger.shouldReport(line) else { return }
        Log.pipeline.info("\(line, privacy: .public)")
    }

    /// Asks the main thread what the selected input source actually is, and
    /// re-arms the evaluation only if that repaired anything. Queue-confined.
    ///
    /// Both hops are `async`. The menu asks this queue questions with
    /// `queue.sync` from the main thread, so a `main.sync` from here is half of
    /// a deadlock; and the refresh itself calls Text Input Sources, which is why
    /// it cannot simply happen here.
    ///
    /// Re-arming is conditional on two things, and that is the whole difference
    /// from the loop this replaces: the refresh has to report that the cache now
    /// resolves to a pair, and there has to still be something in the buffer to
    /// evaluate. A user typing with only English enabled is refused for good
    /// reasons, and retrying that once a second forever is not a recovery
    /// strategy.
    private func refreshLayoutSelection() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isRefreshingLayout else { return }
        isRefreshingLayout = true
        let refresh = layoutRefresh ?? layoutEngine.refreshSelection
        DispatchQueue.main.async { [weak self] in
            let repaired = refresh()
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isRefreshingLayout = false
                guard repaired, !self.session.isBufferEmpty else { return }
                self.armTrigger()
            }
        }
    }

    /// Region text is typed text. It only ever reaches os_log through this
    /// category, and only when the user opted in.
    private func logDecision(_ snapshot: DecisionSnapshot) {
        guard settings.debugLogging else {
            Log.decision.info(
                "\(snapshot.verdict, privacy: .public) in \(snapshot.durationMillis, format: .fixed(precision: 1), privacy: .public) ms"
            )
            return
        }
        // The region is the user's own text, so it stays `.private` even here.
        // The opt-in decides whether the line is emitted at all; it does not
        // unredact it. Anyone reading the log sees `region=<private>` unless
        // they have turned private-data logging on for the whole system, which
        // is a deliberate act on the machine that produced the text and is the
        // only way it is ever readable.
        Log.decision.info(
            "\(snapshot.verdict, privacy: .public) region=\(snapshot.regionText, privacy: .private) cur=\(snapshot.currentScore, format: .fixed(precision: 2), privacy: .public) alt=\(snapshot.alternateScore, format: .fixed(precision: 2), privacy: .public) guards=\(snapshot.guards, privacy: .public) reason=\(snapshot.reason, privacy: .public) in \(snapshot.durationMillis, format: .fixed(precision: 1), privacy: .public) ms"
        )
    }

    private func publish(_ snapshot: DecisionSnapshot) {
        lastDecision = snapshot
        onDecision?(snapshot)
    }

    // MARK: - The accessibility gate

    /// Steps (c) and (d): ask the accessibility API about the focused element,
    /// off this queue, before anything is shown, logged or deleted.
    ///
    /// This runs on *every* evaluation that had something in the buffer, not
    /// only on the ones that produced a fix. A password is not wrong-layout
    /// text, so it produces no fix — and gating the secure-field check on a fix
    /// existing would mean a password field that does not raise the secure
    /// event input flag is never noticed at all, and the buffer just keeps
    /// growing. `SafetyGate.inspection` owns that rule.
    ///
    /// The auto path asks for the caret text in the same round trip as the
    /// secure-field check — one focused-element read serves both, and the two
    /// answers then fail in opposite directions as `SafetyGate` documents.
    private func beginGate(
        for decision: Decision, snapshot: DecisionSnapshot, policy: AppPolicy, bundleID: String?
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isGating, !isApplying else { return }

        // Before the accessibility round trip, and before anything is offered:
        // a fix whose span cannot be deleted by counting backspaces is one the
        // injector will refuse anyway, and offering it would put a card in
        // front of the user for a rewrite that can only end in a ✕.
        if let fix = decision.fix,
           let refusal = TextGuards.deleteRefusal(deleting: fix.deleteCount, of: fix.replacedText)
        {
            Log.fix.info(
                "fix withheld: \(refusal.rawValue, privacy: .public) over \(fix.deleteCount, privacy: .public) clusters"
            )
            return
        }

        isGating = true
        cancelTrigger()
        let serial = inputs.current
        let inspection = SafetyGate.inspection(
            for: decision, skipVerify: settings.skipsAXVerify(bundleID))

        focus.inspect(
            pid: frontmost.current.processIdentifier,
            caretTextLength: inspection.caretTextLength
        ) { [weak self] inspected in
            guard let self else { return }
            self.queue.async {
                self.resolveGate(
                    inspected, decision: decision, snapshot: snapshot, policy: policy,
                    bundleID: bundleID, verified: inspection.caretTextLength != nil, serial: serial)
            }
        }
    }

    private func resolveGate(
        _ focus: FocusInspection,
        decision: Decision,
        snapshot: DecisionSnapshot,
        policy: AppPolicy,
        bundleID: String?,
        verified: Bool,
        serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isGating else { return }
        isGating = false

        guard !inputs.hasMoved(since: serial) else {
            // Something happened while we were asking — a keystroke, a click,
            // an app switch. The decision is about text that has since moved,
            // and publishing it would show a region that is no longer there.
            Log.pipeline.debug("evaluation abandoned: input arrived during the accessibility check")
            if !session.isBufferEmpty { armTrigger() }
            return
        }

        // `.required`: nobody asked for this rewrite, so the only reason good
        // enough to delete anything is a positive match.
        let verification =
            verified
            ? CaretVerification.verdict(
                read: focus.caretRead, replacedText: decision.fix?.replacedText ?? "",
                mode: .required)
            : .proceed

        let resolution = SafetyGate.resolve(
            decision: decision, secureField: focus.security, verification: verification)

        // The region-carrying publication, gated by the pure rule.
        if resolution.mayPublishRegion {
            var published = snapshot
            if case .suggest(let downgradedFrom) = resolution, let downgradedFrom {
                Log.fix.info(
                    "auto-apply downgraded to a suggestion: \(downgradedFrom, privacy: .public)")
                published.verdict = "suggest"
                published.result = "downgraded: \(downgradedFrom)"
            }
            publish(published)
            logDecision(published)
        }

        switch resolution {
        case .drop(let reason):
            // Everything about the evaluation is withheld: only that it was
            // skipped, and why. No region, no scores, no `decision` log line.
            Log.pipeline.info("buffer dropped: \(reason, privacy: .public)")
            publish(
                .skipped(
                    reason: reason, policy: policy, bundleID: bundleID,
                    evaluatedAt: snapshot.evaluatedAt))
            // Publishing the cleaned buffer snapshot, rather than staying
            // silent, is the point: the debug window keeps the *last* snapshot
            // it was handed even while it is closed, and shows it when it is
            // next opened. Staying silent would leave the password-bearing one
            // sitting there. `.secureInput` also purges the keystroke log, so
            // what replaces it carries neither the text nor the key history.
            resetBuffer(reason: .secureInput)

        case .suggest:
            guard let fix = decision.fix else { break }
            offerSuggestion(fix, bundleID: bundleID, serial: serial)

        case .autoApply:
            guard let fix = decision.fix else { break }
            // The accept and undo paths both re-check this before they delete;
            // the auto path must too. The gate took ~250ms, and a grant revoked
            // inside that window — the tap stopped, a pause, the app set to
            // Off — must not reach `beginApply`.
            guard captureActive, !isSuppressed else {
                Log.fix.info("auto-apply refused: the pipeline is suspended")
                break
            }
            beginApply(fix, bundleID: bundleID, verifiedAt: serial, kind: .auto)

        case .nothing:
            // The detector looked and left the text alone. If it did so because
            // the word at the caret was not finished with a space, a longer
            // silence is the only thing that can change the answer — so the
            // buffer gets exactly one more look, and no more.
            armSettledPass()
        }
    }

    // MARK: - Suggestions

    /// Raises the panel, unless the same text was turned down here recently.
    ///
    /// - Parameter serial: the input serial the decision was taken at, and the
    ///   token the eventual acceptance is validated against. It is the gate's
    ///   serial, which `resolveGate` has just confirmed has not moved.
    private func offerSuggestion(_ fix: Fix, bundleID: String?, serial: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))

        // One offer at a time. Reaching here with one already open takes an
        // input the panel never saw, so it is not a refusal and is not
        // remembered as one.
        dismissSuggestion("superseded by a newer suggestion", remember: false)

        let now = Self.now()
        let refusedRecently =
            suppression.isSuppressed(text: fix.replacedText, bundleID: bundleID, at: now)
            || undoSuppression.isSuppressed(text: fix.replacedText, bundleID: bundleID, at: now)
        guard !refusedRecently else {
            // The buffer is not reset by a dismissal — the text really is still
            // in front of the caret — so without this the same offer comes back
            // one second later, indefinitely. Text that was *undone* is held
            // back here as well: taking a fix back and being offered it again a
            // second later is the same loop with an extra insult.
            Log.pipeline.debug("suggestion withheld: the same text was refused here recently")
            return
        }

        pendingSuggestion = PendingSuggestion(fix: fix, bundleID: bundleID, serial: serial)
        Log.pipeline.info(
            "suggesting: replace \(fix.deleteCount, privacy: .public) clusters with \(fix.insertText.count, privacy: .public)"
        )
        onSuggest?(
            SuggestionOffer(fix: fix, pid: frontmost.current.processIdentifier))
    }

    /// Takes the panel down and remembers the refusal. A no-op when nothing is
    /// on offer, which is what makes it safe to call from `process`.
    private func dismissSuggestion(_ reason: String, remember: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let pending = pendingSuggestion else { return }
        pendingSuggestion = nil
        // Cleared here as well as by the controller: the controller's copy is
        // one main-thread hop away, and for the length of that hop the tap
        // would go on swallowing the panel's keys for a panel that has already
        // been decided against.
        suggestionState.hide()

        if remember {
            suppression.record(
                text: pending.fix.replacedText, bundleID: pending.bundleID, at: Self.now())
        }
        Log.pipeline.debug("suggestion dismissed: \(reason, privacy: .public)")
        onHideSuggestion?()
    }

    /// The panel timed out on its own. Callable from any thread.
    func suggestionTimedOut() {
        queue.async { [weak self] in
            // The panel has already taken itself off the screen; this only
            // records the refusal, so nothing is hidden a second time.
            self?.dismissSuggestion("timed out", remember: true)
        }
    }

    /// Queue-confined. Reached from the swallowed accept key and from a click
    /// on the card.
    private func acceptSuggestion() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let pending = pendingSuggestion else { return }
        pendingSuggestion = nil
        suggestionState.hide()
        onHideSuggestion?()

        switch SuggestionKeys.acceptance(
            pendingSerial: pending.serial, currentSerial: inputs.current)
        {
        case .apply:
            break
        case .stale, .gone:
            // Typing while the panel is up is an implicit refusal, and the two
            // signals can cross on the way to this queue. The span the fix
            // would delete is no longer the span it was computed from, so the
            // only safe reading is the refusal.
            Log.pipeline.info("suggestion not applied: input arrived after the panel appeared")
            suppression.record(
                text: pending.fix.replacedText, bundleID: pending.bundleID, at: Self.now())
            return
        }

        guard captureActive, !isSuppressed, !isApplying, !isGating else {
            // Silence here would look exactly like a broken accept key, so the
            // refusal is shown even though the user can do nothing about it.
            Log.pipeline.info("suggestion not applied: the pipeline is busy or suspended")
            onRequestRejected?()
            return
        }
        beginAcceptGate(pending)
    }

    /// The accepted fix goes through the same accessibility gate as an
    /// auto-apply, for the same reason: the user asked for the text in front of
    /// the caret to be replaced, and if the screen does not match what we think
    /// is there, the delete burst removes somebody else's characters. An
    /// explicit request is not evidence about the screen.
    private func beginAcceptGate(_ pending: PendingSuggestion) {
        dispatchPrecondition(condition: .onQueue(queue))
        isGating = true
        cancelTrigger()

        let serial = pending.serial
        let caretTextLength =
            settings.skipsAXVerify(pending.bundleID)
            ? nil : pending.fix.replacedText.utf16.count

        focus.inspect(
            pid: frontmost.current.processIdentifier,
            caretTextLength: caretTextLength
        ) { [weak self] inspected in
            guard let self else { return }
            self.queue.async {
                self.resolveAccept(
                    inspected, pending: pending, verified: caretTextLength != nil, serial: serial)
            }
        }
    }

    private func resolveAccept(
        _ focus: FocusInspection, pending: PendingSuggestion, verified: Bool, serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isGating else { return }
        isGating = false

        guard !inputs.hasMoved(since: serial) else {
            Log.pipeline.info("accepted fix abandoned: input arrived during the caret check")
            // The keystroke that abandoned this arrived while `isGating` was
            // set, so its own `armTrigger` was swallowed by the guard there.
            // Without re-arming, the buffer is never evaluated again until the
            // user types more. Same reasoning, and same line, as `resolveGate`.
            if !session.isBufferEmpty { armTrigger() }
            return
        }

        // `.bestEffort`: the user pointed at this text and asked for it to be
        // replaced. That is worth proceeding on where accessibility is
        // structurally silent — a terminal, a canvas-drawn web view — and
        // nothing more. See `VerifyMode`.
        let verification =
            verified
            ? CaretVerification.verdict(
                read: focus.caretRead, replacedText: pending.fix.replacedText, mode: .bestEffort)
            : .proceed

        // The same rule the automatic path is resolved by, given the same
        // inputs, so the two cannot drift apart.
        switch SafetyGate.resolve(
            decision: .autoApply(pending.fix), secureField: focus.security,
            verification: verification)
        {
        case .autoApply:
            beginApply(
                pending.fix, bundleID: pending.bundleID, verifiedAt: serial, kind: .accepted)

        case .drop(let reason):
            Log.pipeline.info("accepted fix dropped: \(reason, privacy: .public)")
            resetBuffer(reason: .secureInput)
            onRequestRejected?()

        case .suggest(let downgradedFrom):
            // Re-offering would be a loop: the same check would fail again. The
            // user asked, the screen does not match, and saying so is the only
            // honest outcome.
            Log.fix.info(
                "accepted fix abandoned: \(downgradedFrom ?? "the caret could not be verified", privacy: .public)"
            )
            onRequestRejected?()

        case .nothing:
            break
        }
    }

    // MARK: - Undo

    /// The fix the user may still take back, if any. Callable from any thread:
    /// the menu asks while it is opening, and the answer moves with the clock,
    /// so it cannot be a value published after the fact.
    func undoableFix(now: Date = Date()) -> AppliedFix? {
        history.undoableFix(now: now)
    }

    /// Whether an undo asked for right now would actually be attempted.
    ///
    /// The menu needs this rather than `undoableFix` alone: an item that is
    /// enabled and then answers with a ✕ is worse than one that is greyed out.
    /// The suspension flags are queue-confined, so the answer is taken on the
    /// queue — three boolean reads, and only once there is something to undo,
    /// so the common case does not hop at all. Safe from the main thread: no
    /// work on this queue ever waits on the main one.
    func canUndo(now: Date = Date()) -> Bool {
        guard history.undoableFix(now: now) != nil else { return false }
        return queue.sync { captureActive && !isSuppressed && !isApplying && !isGating }
    }

    /// Takes back the last fix. Callable from any thread — the hot key and the
    /// menu item both arrive on the main one.
    func undoLastFix() {
        queue.async { [weak self] in
            self?.performUndo()
        }
    }

    private func performUndo() {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let undoable = history.undoableFix(now: Date()) else {
            // ⌘⌥Z is a global chord, and most presses of it while there is
            // nothing to take back are meant for the application underneath.
            // Flashing at every one of them would be noise.
            Log.fix.debug("undo requested with nothing to undo")
            return
        }
        // The undo deletes what the fix typed, so it is the *corrected* text
        // the burst is counted against — a different span from the one the fix
        // itself was checked for, and the one that carries whatever the
        // alternate layout rendered.
        let inverse = undoable.fix.inverted
        if let refusal = TextGuards.deleteRefusal(
            deleting: inverse.deleteCount, of: inverse.replacedText)
        {
            Log.fix.info("undo refused: \(refusal.rawValue, privacy: .public)")
            onRequestRejected?()
            return
        }
        guard captureActive, !isSuppressed, !isApplying, !isGating else {
            Log.fix.info("undo refused: the pipeline is busy or suspended")
            onRequestRejected?()
            return
        }
        guard let applied = history.takeUndoable(now: Date()) else { return }

        // A card on screen is about text that is about to change underneath it.
        // Not remembered as a refusal: the user was not answering the card.
        dismissSuggestion("an undo was requested", remember: false)
        beginUndoGate(applied)
    }

    /// The undo goes through the same accessibility gate as everything else
    /// that deletes, asking about the *corrected* text — that is what is in
    /// front of the caret now, and `Fix.inverted` puts it in `replacedText`
    /// exactly so this check needs no special case.
    private func beginUndoGate(_ applied: AppliedFix) {
        dispatchPrecondition(condition: .onQueue(queue))
        isGating = true
        cancelTrigger()

        let inverse = applied.fix.inverted
        let serial = inputs.current
        let caretTextLength =
            settings.skipsAXVerify(applied.bundleID) ? nil : inverse.replacedText.utf16.count

        focus.inspect(
            pid: frontmost.current.processIdentifier,
            caretTextLength: caretTextLength
        ) { [weak self] inspected in
            guard let self else { return }
            self.queue.async {
                self.resolveUndo(
                    inspected, applied: applied, inverse: inverse,
                    verified: caretTextLength != nil, serial: serial)
            }
        }
    }

    private func resolveUndo(
        _ focus: FocusInspection, applied: AppliedFix, inverse: Fix, verified: Bool, serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isGating else { return }
        isGating = false

        guard !inputs.hasMoved(since: serial) else {
            Log.fix.info("undo abandoned: input arrived during the caret check")
            // Nothing was posted, so the fix is still on screen and still worth
            // offering. Same re-arm as the other two abandon paths.
            history.restore(applied)
            if !session.isBufferEmpty { armTrigger() }
            return
        }

        // `.bestEffort`, plus undo's own condition: the two ways best effort
        // proceeds without comparing anything — an element that exposes no
        // text, an application in `axVerifySkip` — are only safe while nothing
        // the user did has happened since the fix landed. `serial` above is
        // taken when the undo was *asked for*, which says nothing about the
        // minute before that; `applied.userInputSerial` has the fix as its
        // origin, and counts only keystrokes and clicks — a fix's own layout
        // switch comes back as an input and must not read as the user typing.
        let verification = CaretVerification.undoVerdict(
            read: focus.caretRead,
            replacedText: inverse.replacedText,
            verified: verified,
            inputSinceFix: userInputs.hasMoved(since: applied.userInputSerial))

        switch SafetyGate.resolve(
            decision: .autoApply(inverse), secureField: focus.security, verification: verification)
        {
        case .autoApply:
            beginApply(
                inverse, bundleID: applied.bundleID, verifiedAt: serial,
                kind: .undo(original: applied))

        case .drop(let reason):
            Log.fix.info("undo dropped: \(reason, privacy: .public)")
            resetBuffer(reason: .secureInput)
            onRequestRejected?()

        case .suggest(let downgradedFrom):
            // The corrected text is not where it was put. Deleting back from
            // the caret would eat something else, and the slot stays gone: what
            // is on screen is no longer the fix this undo was about.
            Log.fix.info(
                "undo abandoned: \(downgradedFrom ?? "the caret could not be verified", privacy: .public)"
            )
            onRequestRejected?()

        case .nothing:
            break
        }
    }

    // MARK: - Flipping

    /// Rewrites the selection — or, when nothing is selected, the typed run —
    /// through the other keyboard layout.
    ///
    /// Callable from any thread: the hot key and the menu item both arrive on
    /// the main one. Same shape as `undoLastFix()`.
    func flipSelection() {
        queue.async { [weak self] in
            self?.beginFlip()
        }
    }

    /// Whether a flip asked for right now would actually be attempted.
    ///
    /// Mirrors `canUndo()` minus the history check — there is no slot to
    /// consult, the command stands on its own — and is used for the same
    /// reason: a menu item that is enabled and then answers with a ✕ is worse
    /// than one that is greyed out. Safe from the main thread: no work on this
    /// queue ever waits on the main one.
    func canFlip() -> Bool {
        queue.sync { captureActive && !isSuppressed && !isApplying && !isGating }
    }

    private func beginFlip() {
        dispatchPrecondition(condition: .onQueue(queue))

        guard captureActive, !isSuppressed, !isApplying, !isGating else {
            // The user pressed a chord. Silence would look exactly like a
            // broken key, so the refusal is shown even though there is nothing
            // to be done about it.
            Log.fix.info("flip refused: the pipeline is busy or suspended")
            onRequestRejected?()
            return
        }

        // The session's view of what is in front, exactly as `evaluate()`
        // takes it: it is the identifier the policy, the buffer and the
        // suppression tables are all keyed by, so reading a fresher one here
        // would apply this app's rules under that app's name.
        //
        // Never `frontmost.currentBundleID()`, tempting as an authoritative
        // read is: that one hops to the main thread with `sync`, and the menu
        // asks `canFlip()` and `canUndo()` with `queue.sync` *from* the main
        // thread. The two together are a deadlock.
        let bundleID = session.currentFrontmostBundleID
        switch SafetyGate.preflight(
            paused: paused,
            secureInputEnabled: secureInputActive || secureInput.readNow(),
            policy: settings.policy(for: bundleID))
        {
        case .blocked(let reason, let reset):
            if let reset { resetBuffer(reason: reset) }
            Log.fix.info("flip refused: \(reason, privacy: .public)")
            onRequestRejected?()
            return
        case .proceed:
            // The allowed policy is deliberately discarded. `.suggestOnly`
            // caps what the *detector* may do unasked; this is the user naming
            // the command, and the only policy that refuses that is `.off`,
            // which preflight has already blocked.
            break
        }

        guard let pair = currentLayoutPair() else {
            // Same rule as `evaluate()`: a cold cache is repopulated on the
            // main thread after every invalidation, and enumerating input
            // sources from here is a Text Input Sources call off-main.
            Log.fix.info("flip refused: the layout cache is cold")
            onRequestRejected?()
            return
        }

        // A card on screen is about text that is about to change underneath
        // it, and nothing else takes it down: the tap swallows the flip chord,
        // so `process` never runs for it. Left up, its stale fix could then be
        // accepted on top of the flipped text. Not remembered as a refusal —
        // the user was not answering the card.
        dismissSuggestion("a flip was requested", remember: false)
        inputs.bump()

        isGating = true
        cancelTrigger()
        let serial = inputs.current
        // The pid, unlike the identifier, comes from the tracker: it is what
        // the accessibility calls are addressed to, and a stale one asks a
        // process that no longer has focus. Same split as `beginGate`.
        let pid = frontmost.current.processIdentifier

        // The focused element is asked about first and for nothing but its
        // security, because the answer decides whether the application may be
        // asked anything else at all.
        focus.inspect(pid: pid, caretTextLength: nil) { [weak self] inspected in
            guard let self else { return }
            self.queue.async {
                guard self.continueFlip(serial: serial, describedAs: "the focus check") else {
                    return
                }
                // Before any selection is read and before ⌘C is ever posted:
                // putting a password field's selection on the pasteboard is
                // itself the leak, which is why this cannot wait for
                // `SafetyGate.resolve` at the end of the chain.
                guard SafetyGate.allowsExplicitCommand(secureField: inspected.security) else {
                    self.isGating = false
                    Log.fix.info("flip refused: the focused field is a password field")
                    self.resetBuffer(reason: .secureInput)
                    self.onRequestRejected?()
                    return
                }
                self.readSelectionForFlip(
                    pid: pid, pair: pair, security: inspected.security, bundleID: bundleID,
                    serial: serial)
            }
        }
    }

    /// The two guards every hop of the flip repeats.
    ///
    /// Returns false when the flip is over: either something else claimed the
    /// gate, or input arrived while an application was being asked something,
    /// which means the text the flip is about has moved.
    private func continueFlip(serial: UInt64, describedAs stage: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isGating else { return false }
        guard !inputs.hasMoved(since: serial) else {
            isGating = false
            Log.fix.info("flip abandoned: input arrived during \(stage, privacy: .public)")
            // The keystroke that abandoned this arrived while `isGating` was
            // set, so its own `armTrigger` was swallowed by the guard there.
            // Same re-arm, and same reason, as the other abandon paths.
            if !session.isBufferEmpty { armTrigger() }
            return false
        }
        return true
    }

    private func readSelectionForFlip(
        pid: pid_t?,
        pair: (english: KeyboardLayout, arabic: KeyboardLayout),
        security: SecureFieldState,
        bundleID: String?,
        serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        focus.selectedText(pid: pid) { [weak self] read in
            guard let self else { return }
            self.queue.async {
                guard self.continueFlip(serial: serial, describedAs: "the selection read") else {
                    return
                }
                switch read {
                case .selected(let text):
                    self.resolveFlipText(
                        text, overSelection: true, pair: pair, security: security,
                        bundleID: bundleID, pid: pid, serial: serial)

                case .unreadable:
                    // The element exposes no text surface — a terminal, a
                    // canvas-drawn web view — so accessibility cannot say
                    // whether anything is selected. ⌘C is the only way left to
                    // ask, and it costs the better part of a second, which is
                    // why it is spent here and nowhere else.
                    self.copySelectionForFlip(
                        pair: pair, security: security, bundleID: bundleID, pid: pid,
                        serial: serial)

                case .noSelection, .unavailable:
                    self.flipTypedRun(
                        pair: pair, security: security, bundleID: bundleID, pid: pid,
                        serial: serial)
                }
            }
        }
    }

    private func copySelectionForFlip(
        pair: (english: KeyboardLayout, arabic: KeyboardLayout),
        security: SecureFieldState,
        bundleID: String?,
        pid: pid_t?,
        serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        fixEngine.copySelection(in: bundleID) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.continueFlip(serial: serial, describedAs: "the copy") else { return }
                switch result {
                case .copied(let text):
                    self.resolveFlipText(
                        text, overSelection: true, pair: pair, security: security,
                        bundleID: bundleID, pid: pid, serial: serial)

                case .noSelection:
                    self.flipTypedRun(
                        pair: pair, security: security, bundleID: bundleID, pid: pid,
                        serial: serial)

                case .timedOut:
                    // The same reasoning as `couldNotTry`, one step further
                    // out: the application was asked and did not answer, so
                    // whether anything is highlighted is unknown rather than
                    // known to be nothing.
                    self.isGating = false
                    Log.fix.info("flip refused: the selection went unanswered")
                    self.onRequestRejected?()

                case .couldNotTry(let error):
                    // "The question could not be asked" is not "there is
                    // nothing selected". Falling back to the typed run here
                    // would rewrite a completely different span of the
                    // document from the one the user meant.
                    self.isGating = false
                    Log.fix.info(
                        "flip refused: the selection could not be read (\(error.description, privacy: .public))"
                    )
                    self.onRequestRejected?()
                }
            }
        }
    }

    /// Nothing is selected, so the flip is about what the user has just typed.
    private func flipTypedRun(
        pair: (english: KeyboardLayout, arabic: KeyboardLayout),
        security: SecureFieldState,
        bundleID: String?,
        pid: pid_t?,
        serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        let text = session.currentText
        guard !text.isEmpty else {
            isGating = false
            // Nothing selected and nothing typed. The flip chord is global,
            // and most presses of it in that state are meant for the
            // application underneath, so this is silent for exactly the reason
            // ⌘⌥Z with nothing to undo is.
            Log.fix.debug("flip requested with nothing selected and an empty buffer")
            return
        }
        resolveFlipText(
            text, overSelection: false, pair: pair, security: security, bundleID: bundleID,
            pid: pid, serial: serial)
    }

    private func resolveFlipText(
        _ text: String,
        overSelection: Bool,
        pair: (english: KeyboardLayout, arabic: KeyboardLayout),
        security: SecureFieldState,
        bundleID: String?,
        pid: pid_t?,
        serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let flip = FlipBuilder.flip(text, english: pair.english, arabic: pair.arabic) else {
            // There *was* text — a selection, or a typed run — so the user has
            // every reason to expect something to happen. Silence would read
            // as a dead key rather than as "this text does not flip".
            isGating = false
            Log.fix.info("flip refused: nothing in the text maps to the other layout")
            onRequestRejected?()
            return
        }

        // The typed-run path is the only flip that deletes anything itself: it
        // backspaces cluster by cluster from the caret, over a span inferred
        // from a capped buffer rather than one the user highlighted. So it is
        // held to the same rule as every other burst, and for the same reasons
        // — a run longer than the cap is one the buffer never held in full, and
        // the burst would stop short and leave a hybrid of both layouts on
        // screen. A selection flip is exempt because it types over the
        // selection and posts no backspaces at all.
        if !overSelection,
           let refusal = TextGuards.deleteRefusal(deleting: flip.original.count, of: flip.original)
        {
            isGating = false
            Log.fix.info("flip refused: \(refusal.rawValue, privacy: .public)")
            onRequestRejected?()
            return
        }

        // `deleteCount == replacedText.count` holds by construction, which is
        // what makes `Fix.inverted` — and so ⌘⌥Z after a flip — correct.
        let fix = Fix(
            deleteCount: flip.original.count,
            insertText: flip.flipped,
            targetLayoutID: flip.targetLayoutID,
            sourceLayoutID: flip.sourceLayoutID,
            replacedText: flip.original,
            capsMode: flip.capsMode)

        guard overSelection else {
            verifyThenFlipTypedRun(
                flip, fix: fix, bundleID: bundleID, pid: pid, serial: serial)
            return
        }

        isGating = false
        // `.proceed` rather than a caret verdict, and this is the one place
        // that is right: a live selection is precisely the state
        // `CaretVerification` fails closed on (`.selectionPresent`), because
        // there it is evidence of something the buffer cannot see. Here the
        // selection *is* the span being replaced, it was read back
        // character for character, and typing over it deletes exactly it.
        switch SafetyGate.resolve(
            decision: .autoApply(fix), secureField: security, verification: .proceed)
        {
        case .autoApply:
            beginApply(
                fix, bundleID: bundleID, verifiedAt: serial,
                kind: .flip(flip, overSelection: true))

        case .drop(let reason):
            Log.fix.info("flip dropped: \(reason, privacy: .public)")
            resetBuffer(reason: .secureInput)
            onRequestRejected?()

        case .suggest(let downgradedFrom):
            Log.fix.info(
                "flip refused: \(downgradedFrom ?? "the caret could not be verified", privacy: .public)"
            )
            onRequestRejected?()

        case .nothing:
            break
        }
    }

    /// The typed-run flip's own gate: it is the only explicit command that
    /// deletes text the user never pointed at.
    private func verifyThenFlipTypedRun(
        _ flip: Flip, fix: Fix, bundleID: String?, pid: pid_t?, serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard !settings.skipsAXVerify(bundleID) else {
            // The skip list trades the caret check away for applications that
            // cannot answer it. That trade is acceptable where the user
            // pointed at the text — a selection, an offer, an undo — and not
            // here, where the span is inferred from the buffer alone.
            isGating = false
            Log.fix.info("flip refused: the caret cannot be verified in this app")
            onRequestRejected?()
            return
        }

        focus.inspect(pid: pid, caretTextLength: fix.replacedText.utf16.count) {
            [weak self] inspected in
            guard let self else { return }
            self.queue.async {
                guard self.continueFlip(serial: serial, describedAs: "the caret check") else {
                    return
                }
                self.isGating = false

                // `.required`, not `.bestEffort`: this path deletes up to the
                // whole buffer — text the user named a command for, not text
                // they put a cursor in — so an element that exposes nothing is
                // not reason enough. Only a positive match may proceed.
                let verification = CaretVerification.verdict(
                    read: inspected.caretRead, replacedText: fix.replacedText, mode: .required)

                switch SafetyGate.resolve(
                    decision: .autoApply(fix), secureField: inspected.security,
                    verification: verification)
                {
                case .autoApply:
                    self.beginApply(
                        fix, bundleID: bundleID, verifiedAt: serial,
                        kind: .flip(flip, overSelection: false))

                case .drop(let reason):
                    Log.fix.info("flip dropped: \(reason, privacy: .public)")
                    self.resetBuffer(reason: .secureInput)
                    self.onRequestRejected?()

                case .suggest(let downgradedFrom):
                    Log.fix.info(
                        "flip refused: \(downgradedFrom ?? "the caret could not be verified", privacy: .public)"
                    )
                    self.onRequestRejected?()

                case .nothing:
                    break
                }
            }
        }
    }

    // MARK: - Applying

    /// Which of the ways a fix can reach the screen this is.
    ///
    /// The sequence, its guards and its aftermath are identical for all of
    /// them by design — that is the whole reason undo goes through here rather
    /// than down a path of its own. What differs is only what is recorded and
    /// what the user is shown afterwards.
    private enum ApplyKind {
        case auto
        case accepted
        /// The inverse of `original`, which has already been claimed out of the
        /// undo slot and is put back if this never reaches the screen.
        case undo(original: AppliedFix)
        /// A flip the user asked for by name.
        ///
        /// `overSelection` chooses the injector call, and it has to: typing
        /// over a selection replaces it, so the forward `Fix` must never reach
        /// `FixEngine.apply`, whose `deleteCount` backspaces would be posted
        /// *after* the replacement had already consumed the selected span —
        /// eating that many clusters of whatever preceded it.
        case flip(Flip, overSelection: Bool)

        var description: String {
            switch self {
            case .auto: return "auto-applying"
            case .accepted: return "applying an accepted suggestion"
            case .undo: return "undoing"
            case .flip(_, let overSelection):
                return overSelection ? "flipping a selection" : "flipping the typed run"
            }
        }
    }

    /// - Parameter verifiedAt: the input serial the caret verification was
    ///   taken at. The injector re-checks it after its modifier pre-flight,
    ///   which is the only part of the sequence long enough for the screen to
    ///   have changed since.
    private func beginApply(
        _ fix: Fix, bundleID: String?, verifiedAt: UInt64, kind: ApplyKind
    ) {
        isApplying = true
        droppedInputDuringApply = false
        cancelTrigger()
        // Taken here rather than threaded down from each gate: the gates call
        // this synchronously, in the same queue block, so it is the same value
        // and one fewer parameter to keep in step across three call sites.
        let userSerial = userInputs.current

        let inputs = self.inputs
        let isStale = { inputs.hasMoved(since: verifiedAt) }
        let completion: (Result<FixProgress, FixFailure>) -> Void = { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.finishApply(
                    fix, bundleID: bundleID, kind: kind, userSerial: userSerial, result: result)
            }
        }

        if case .flip(let flip, overSelection: true) = kind {
            // Nothing is deleted: the selection is still there, and typing
            // replaces it. Logged as such, because a line claiming a delete
            // count that was never posted is a line that sends the next reader
            // hunting for backspaces in the wrong place.
            Log.fix.info(
                "\(kind.description, privacy: .public): type \(flip.flipped.count, privacy: .public) over the selection, switch to \(fix.targetLayoutID, privacy: .public)"
            )
            fixEngine.replaceSelection(
                with: flip.flipped,
                targetLayoutID: flip.targetLayoutID,
                in: bundleID,
                isStale: isStale,
                completion: completion)
        } else {
            Log.fix.info(
                "\(kind.description, privacy: .public): delete \(fix.deleteCount, privacy: .public) clusters, insert \(fix.insertText.count, privacy: .public), switch to \(fix.targetLayoutID, privacy: .public)"
            )
            fixEngine.apply(fix, in: bundleID, isStale: isStale, completion: completion)
        }
    }

    private func finishApply(
        _ fix: Fix, bundleID: String?, kind: ApplyKind, userSerial: UInt64,
        result: Result<FixProgress, FixFailure>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        let progress: FixProgress
        var transientFailure = false
        switch result {
        case .success(let succeeded):
            progress = succeeded
            switch kind {
            case .auto, .accepted:
                let applied = AppliedFix(
                    fix: fix, appliedAt: Date(), bundleID: bundleID, userInputSerial: userSerial)
                if droppedInputDuringApply {
                    // Real input reached the screen while the burst was
                    // running — it was dropped here, not there — so what is in
                    // front of the caret is the correction followed by
                    // something this app never saw. An undo counts its
                    // backspaces from the caret, so it would eat that
                    // something first. No offer at all is the honest answer;
                    // the fix itself still happened and is still reported.
                    Log.fix.info("no undo offered: input arrived while the fix was being applied")
                } else {
                    history.record(applied)
                }
                lastDecision?.result = "applied"
                onAutoApply?(applied)
            case .undo(let original):
                // The text the user originally typed is back in front of the
                // caret, and the next quiet period will look straight at it.
                // Without this it is re-fixed within the second.
                undoSuppression.record(
                    text: original.fix.replacedText, bundleID: bundleID, at: Self.now())
                lastDecision?.result = "undone"
                onUndoApplied?()
            case .flip(let flip, let overSelection):
                guard overSelection, !settings.skipsAXVerify(bundleID) else {
                    // A typed-run flip verified the caret before it deleted
                    // anything, and an app on the skip list has already been
                    // declared unable to answer. Neither is asked again.
                    recordFlip(
                        flip, fix: fix, bundleID: bundleID, userSerial: userSerial,
                        droppedInput: droppedInputDuringApply)
                    break
                }
                // Read now, before the hop: input arriving during the check
                // says nothing about whether the flip itself landed, and the
                // undo offer is a question about the moment the burst ended.
                let droppedInput = droppedInputDuringApply
                focus.inspect(
                    pid: frontmost.current.processIdentifier,
                    caretTextLength: flip.flipped.utf16.count
                ) { [weak self] inspected in
                    guard let self else { return }
                    self.queue.async {
                        if self.flipLanded(flip, read: inspected.caretRead) {
                            self.recordFlip(
                                flip, fix: fix, bundleID: bundleID, userSerial: userSerial,
                                droppedInput: droppedInput)
                        } else {
                            // The injector reported success and the text is
                            // not there. Something else consumed the
                            // keystrokes, so nothing is recorded: an undo slot
                            // armed here would post backspaces over whatever
                            // is actually in front of the caret.
                            Log.fix.fault(
                                "the flipped text is not in front of the caret; no undo is offered")
                            self.lastDecision?.result = "flip unverified"
                            self.onRequestRejected?()
                        }
                        self.completeApply(progress: succeeded, transientFailure: false)
                    }
                }
                // The aftermath runs in that callback instead, so that it runs
                // exactly once and after the check rather than racing it.
                return
            }
        case .failure(let failure):
            progress = failure.progress
            transientFailure = failure.error.isTransient
            lastDecision?.result = "failed: \(failure.error.description)"
            if case .undo(let original) = kind, progress.touchedNothing, !droppedInputDuringApply {
                // The undo never reached the screen — a modifier still held
                // from the chord itself is the common case — so the fix is
                // exactly where it was and the offer stands. Anything that did
                // post events leaves a half-restored line, and a second
                // destructive pass over that is not something to offer.
                history.restore(original)
            }
            if case .flip = kind {
                // Unlike an auto-apply, this one was asked for by name, and a
                // command that quietly does nothing reads as a broken key.
                onRequestRejected?()
            }
        }
        completeApply(progress: progress, transientFailure: transientFailure)
    }

    /// What a flip left in front of the caret, checked before an undo for it
    /// is armed.
    ///
    /// A selection flip is the one apply whose delete half is performed by the
    /// application rather than by us: we type, and the app is supposed to
    /// replace the highlighted span. An app that had already dropped the
    /// selection puts the text somewhere else entirely, and the injector
    /// cannot tell — it posted its keys and they were accepted. Recording an
    /// undo for that would arm a delete burst over text nobody has seen.
    ///
    /// The comparison is over UTF-16 with no normalisation, for the reason
    /// `CaretVerification` gives.
    private func flipLanded(_ flip: Flip, read: CaretRead) -> Bool {
        // Every other read — an element that exposes no text, a live
        // selection, no answer at all — saw nothing either way, and the
        // injector reported success. Only a reading that positively disagrees
        // counts against it.
        guard case .value = read else { return true }
        // The same comparison the automatic path trusts before it deletes,
        // partial-match rule included. A terminal reports only its visible
        // line, so the read-back can be shorter than the flip and still agree
        // with it; refusing an undo for that would take ⌘⌥Z away precisely
        // where a flip that went wrong needs it most.
        if case .proceed = CaretVerification.verdict(
            read: read, replacedText: flip.flipped, mode: .required)
        {
            return true
        }
        return false
    }

    private func recordFlip(
        _ flip: Flip, fix: Fix, bundleID: String?, userSerial: UInt64, droppedInput: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        let applied = AppliedFix(
            fix: fix, appliedAt: Date(), bundleID: bundleID, userInputSerial: userSerial)
        if droppedInput {
            // Same reasoning as the automatic path: what is in front of the
            // caret is the flip followed by something this app never saw, and
            // an undo counts its backspaces from the caret.
            Log.fix.info("no undo offered: input arrived while the flip was being applied")
        } else {
            history.record(applied)
        }
        // The flipped text reads as the other language now, so the next quiet
        // period would look straight at what was flipped *from* and offer to
        // put it back. Held down for the same minute a refusal is.
        undoSuppression.record(text: flip.original, bundleID: bundleID, at: Self.now())
        lastDecision?.result = "flipped"
        // The flash and the `Last fix` line come from the same callback every
        // other fix uses; only the card is particular to a flip.
        onAutoApply?(applied)
        let pid = frontmost.current.processIdentifier
        DispatchQueue.main.async { [weak self] in
            self?.onFlipApplied?(flip, pid)
        }
    }

    /// The half of an apply that runs whatever the outcome was: publish the
    /// decision, decide what becomes of the buffer, and close the window in
    /// which input is ignored.
    ///
    /// Split out because a selection flip reaches it one accessibility hop
    /// later than everything else. Running it twice would re-arm the trigger
    /// against a buffer already reset; not running it at all would leave
    /// `isApplying` set for good, and with it the whole pipeline.
    private func completeApply(progress: FixProgress, transientFailure: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))

        if let lastDecision { onDecision?(lastDecision) }

        let aftermath = ApplyAftermath.decide(
            touchedNothing: progress.touchedNothing,
            droppedInput: droppedInputDuringApply,
            transientFailure: transientFailure,
            bufferEmpty: session.isBufferEmpty)

        if aftermath.resetBuffer {
            resetBuffer(reason: .manual)
        } else {
            // Nothing was posted and nothing was swallowed, so the buffer still
            // describes the screen exactly. Throwing it away here would cost
            // the user a valid fix for no reason.
            Log.fix.debug("nothing was typed, so the buffer is kept as it is")
        }

        queue.asyncAfter(deadline: .now() + Self.applyTailWindow) { [weak self] in
            guard let self else { return }
            self.isApplying = false

            if self.droppedInputDuringApply, !self.session.isBufferEmpty {
                // Input arrived during the tail window, after the decision
                // above was taken. Same reasoning, one beat later.
                self.resetBuffer(reason: .manual)
            } else if aftermath.rearmTrigger, !self.session.isBufferEmpty {
                // The obstacle was a passing one, so let the next quiet period
                // try again. Each round costs a full trigger delay plus the
                // modifier pre-flight, so a modifier held down indefinitely
                // retries about every two seconds rather than spinning.
                self.armTrigger()
            }
            self.droppedInputDuringApply = false
        }
    }

    /// The buffer no longer describes what is in front of the caret.
    private func resetBuffer(reason: ResetReason) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Nothing that was refused was refused about this buffer any more.
        skipLedger.clear()
        if reason.purgesHistory {
            // The undo slot holds the user's own text, both halves of it.
            // Whatever made the buffer unkeepable — a password field, so far —
            // makes that unkeepable too, and a reset that purged one and left
            // the other would protect nothing.
            history.invalidate(.purged)
        }
        let snapshot = session.reset(reason: reason, at: Self.now())
        onChange?(snapshot)
    }

    private static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    // MARK: - Seams for DodomaAppTests

    /// Where a flip gets the layout pair it renders through. Nil — the normal
    /// case — means the shared cache, warmed on the main thread.
    ///
    /// A test cannot use that cache: it is populated from the input sources
    /// enabled on whichever machine happens to be running the suite, so a
    /// machine without Arabic enabled would silently turn every flip test into
    /// a test of the cold-cache refusal. The committed `uchr` fixtures go in
    /// here instead.
    var layoutPair: (() -> (english: KeyboardLayout, arabic: KeyboardLayout)?)?

    /// What a refused evaluation calls to have the selection re-read, and
    /// whether that repaired anything. Nil — the normal case — means the shared
    /// cache's own refresh, on the main thread.
    ///
    /// Overridden for the same reason as `layoutPair`, plus one: the real
    /// refresh would answer from the input sources of whichever machine runs
    /// the suite, so whether the recovery re-arms would depend on the tester's
    /// System Settings rather than on the code.
    var layoutRefresh: (() -> Bool)?

    /// How long the second pass waits. The shipped `TypingSession.settledDelay`
    /// everywhere but the tests, which cannot afford three seconds
    /// of real time per case and are testing the ordering rather than the
    /// number. Queue-confined, like everything the trigger reads.
    var settledDelay: TimeInterval = TypingSession.settledDelay

    /// The pair the evaluation and the flip both resolve against, from the seam
    /// when a test installed one and from the shared cache otherwise.
    ///
    /// One accessor rather than the expression spelled out at both call sites:
    /// they are the two places that refuse when there is no usable pair, and
    /// only one of them was reachable from a test while the other read the cache
    /// directly — which is why the refusal that mattered had no test at all.
    private func currentLayoutPair() -> (english: KeyboardLayout, arabic: KeyboardLayout)? {
        (layoutPair ?? layoutEngine.cachedPair)()
    }

    /// Raises an offer for `fix` as though the detector had just produced one.
    /// Queue-confined.
    ///
    /// The tests cannot reach this through the detector: that needs both an
    /// English and an Arabic input source enabled on whichever machine happens
    /// to be running them, and what is under test here is the interaction, not
    /// the detection — which has its own tests, against fixtures.
    func offerNow(_ fix: Fix, bundleID: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        offerSuggestion(fix, bundleID: bundleID, serial: inputs.current)
    }

    /// Drives `fix` through the accessibility gate as an auto-apply, as though
    /// the detector had just returned `.autoApply`. Queue-confined.
    ///
    /// The counterpart to `offerNow` for the automatic path. Like `offerNow`,
    /// it exists because the tests cannot reach this through the detector — that
    /// needs a particular pair of input sources enabled on whichever machine
    /// runs them — and what is under test is the gate-to-apply-to-aftermath
    /// wiring, not the detection.
    func autoApplyNow(_ fix: Fix, bundleID: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let snapshot = DecisionSnapshot(
            verdict: "autoApply", policy: frontmostPolicy.rawValue, bundleID: bundleID,
            deleteCount: fix.deleteCount, insertText: fix.insertText, evaluatedAt: Self.now())
        beginGate(
            for: .autoApply(fix), snapshot: snapshot, policy: frontmostPolicy, bundleID: bundleID)
    }

    /// Whether an evaluation is scheduled. Queue-confined. The three abandon
    /// paths re-arm the trigger, and there is nothing else that shows they did.
    var isEvaluationArmed: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return pendingEvaluation != nil
    }
}
