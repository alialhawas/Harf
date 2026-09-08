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
    private var inputSourceObserver: NSObjectProtocol?
    private var enabledSourcesObserver: NSObjectProtocol?

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

        let inputSourceName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: inputSourceName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Which layout it changed *to* is read here, on the main thread,
            // because that is where Text Input Sources calls belong and because
            // the undo slot cannot tell the fix's own switch from the user's
            // without it.
            self?.inputSourceChanged(to: LayoutEngine.selectedLayoutID())
        }

        let enabledSourcesName = Notification.Name(
            kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        enabledSourcesObserver = DistributedNotificationCenter.default().addObserver(
            forName: enabledSourcesName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutEngine.invalidate()
            self?.warmLayoutCache()
        }

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
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        if let enabledSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(enabledSourcesObserver)
            self.enabledSourcesObserver = nil
        }
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
        }
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
        guard captureActive, !isApplying, !isGating, !isSuppressed else { return }

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
        guard captureActive, !isApplying, !isGating else { return }
        guard let last = session.lastKeyTime else { return }

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
        let model = detector.model(for: detection.typedLanguage)
        let text = session.currentText
        guard !text.isEmpty else { return }
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

    private func evaluate() {
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
            publish(
                .skipped(reason: reason, policy: resolved, bundleID: bundleID, evaluatedAt: now))
            return
        case .proceed(let allowed):
            policy = allowed
        }

        // `cachedPair()`, not `currentPair()`: this runs on the pipeline queue,
        // and enumerating input sources is a Text Input Sources call that
        // belongs on the main thread. A cold cache means an enabled-sources
        // change just invalidated it; `warmLayoutCache()` always repopulates on
        // the main thread after an invalidation, so the next quiet period will
        // have a warm cache. Skip this one rather than enumerate off-main.
        guard let pair = layoutEngine.cachedPair() else {
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
                recentlyUndone: undoSuppression.texts(bundleID: bundleID, at: now))
        else { return }
        let duration = Self.now() - started

        learnVocabulary(from: detection, using: detector)

        let snapshot = DecisionSnapshot(
            detection: detection, policy: policy, bundleID: bundleID, duration: duration,
            evaluatedAt: now)

        // Deliberately not published or logged yet. The snapshot carries the
        // region — the user's own text — and the focused field has not been
        // checked. In a password field that text is a password, and §6(c) says
        // nothing is shown. `resolveGate` publishes it, or does not.
        beginGate(for: detection.decision, snapshot: snapshot, policy: policy, bundleID: bundleID)
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
        // The one interpolation in the project that is deliberately public:
        // redacting it would make the opt-in flag pointless.
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
            break
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

        guard history.undoableFix(now: Date()) != nil else {
            // ⌘⌥Z is a global chord, and most presses of it while there is
            // nothing to take back are meant for the application underneath.
            // Flashing at every one of them would be noise.
            Log.fix.debug("undo requested with nothing to undo")
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

    // MARK: - Applying

    /// Which of the three ways a fix can reach the screen this is.
    ///
    /// The sequence, its guards and its aftermath are identical for all three
    /// by design — that is the whole reason undo goes through here rather than
    /// down a path of its own. What differs is only what is recorded and what
    /// the user is shown afterwards.
    private enum ApplyKind {
        case auto
        case accepted
        /// The inverse of `original`, which has already been claimed out of the
        /// undo slot and is put back if this never reaches the screen.
        case undo(original: AppliedFix)

        var description: String {
            switch self {
            case .auto: return "auto-applying"
            case .accepted: return "applying an accepted suggestion"
            case .undo: return "undoing"
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
        Log.fix.info(
            "\(kind.description, privacy: .public): delete \(fix.deleteCount, privacy: .public) clusters, insert \(fix.insertText.count, privacy: .public), switch to \(fix.targetLayoutID, privacy: .public)"
        )

        let inputs = self.inputs
        fixEngine.apply(
            fix,
            in: bundleID,
            isStale: { inputs.hasMoved(since: verifiedAt) }
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.finishApply(
                    fix, bundleID: bundleID, kind: kind, userSerial: userSerial, result: result)
            }
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
        }
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
