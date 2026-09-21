import AppKit
import DodomaCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private var menuBarController: MenuBarController?
    private var debugWindowController: DebugWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var pipeline: TypingPipeline?
    private var eventTap: EventTapController?
    private var suggestionController: SuggestionController?
    private let hotkeys = HotkeyCenter()
    private var pollTimer: Timer?
    private var lastState: PermissionState?
    private var lastCapturing = false
    /// Set once, by the tap watchdog. Only the menu line reads it; the tap and
    /// the panel take their own copy from `suggestionState`.
    private var tapDegraded = false

    /// The single frontmost-app observer, shared by the pipeline (which needs
    /// the switch as a buffer-reset event), the injector (which re-checks
    /// between keystrokes) and the menu (which labels its per-app submenu).
    private let frontmost = FrontmostAppTracker()
    private let secureInput = SecureInputMonitor()
    private let settings = SettingsStore.shared
    /// The one piece of state the event tap thread, the pipeline queue and the
    /// main thread all touch. Created here so no one of the three owns it.
    private let suggestionState = SuggestionState()
    /// The rectangles of the cards whose clicks are not input. One registry,
    /// because a second would be a second set of rectangles that can disagree
    /// with the first about where a card is.
    private let cardFrames = CardFrames()
    /// Owned here, not by the pipeline, because the settings window reads and
    /// edits the same words and both must see one file.
    private let lexicon = UserLexicon(url: UserLexicon.defaultURL())
    private var learnedController: LearnedController?
    private var flipController: FlipController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The first thing written anywhere by a copy that is going to keep
        // running. The single-copy check is already behind us — `main.swift`
        // runs it before this object is constructed, because constructing it
        // touches `SettingsStore.shared`, which writes to the settings suite
        // the running copy shares — so a copy that stood down never logs a
        // start it did not make.
        Log.app.info("Harf \(DodomaCore.Dodoma.version, privacy: .public) starting")

        preloadLanguageModels()

        let controller = MenuBarController(settings: settings, frontmost: frontmost)
        menuBarController = controller

        let debugWindow = DebugWindowController()
        debugWindowController = debugWindow
        controller.onShowDebugWindow = { [weak debugWindow] in
            debugWindow?.show()
        }

        let settingsWindow = SettingsWindowController(settings: settings, lexicon: lexicon)
        settingsWindowController = settingsWindow
        controller.onShowSettings = { [weak settingsWindow] in
            settingsWindow?.show()
        }

        let onboarding = OnboardingWindowController(onDone: { [weak self] in
            self?.settings.setOnboardingCompleted(true)
        })
        onboardingWindowController = onboarding
        controller.onShowOnboarding = { [weak onboarding] in
            onboarding?.show()
        }

        let pipeline = TypingPipeline(
            settings: settings, frontmost: frontmost, secureInput: secureInput,
            suggestionState: suggestionState, cardFrames: cardFrames, lexicon: lexicon)

        // The panel borrows the pipeline's accessibility oracle rather than
        // making a second one: the caret lookup and the security check have to
        // queue behind one another, and one serial queue is what guarantees it.
        let suggestions = SuggestionController(
            state: suggestionState, oracle: pipeline.focusOracle)
        suggestionController = suggestions
        suggestions.onTimeout = { [weak pipeline] in
            pipeline?.suggestionTimedOut()
        }

        // Shares the pipeline's oracle for the same reason the suggestion panel
        // does: one serial queue for every accessibility call.
        let learned = LearnedController(oracle: pipeline.focusOracle, cards: cardFrames)
        learnedController = learned
        pipeline.onWordsLearned = { [weak self, weak learned] words, language, pid in
            guard let self else { return }
            learned?.show(words: words, language: language, pid: pid) { [weak self] in
                guard let self else { return }
                for word in words { self.lexicon.remove(word, language: language) }
                _ = self.lexicon.save()
                Log.app.info("\(words.count, privacy: .public) learned words undone")
            }
        }

        // Shares the pipeline's oracle for the same reason the suggestion panel
        // does: one serial queue for every accessibility call.
        let flips = FlipController(oracle: pipeline.focusOracle, cards: cardFrames)
        flipController = flips
        pipeline.onFlipApplied = { [weak self, weak flips] flip, pid in
            flips?.show(flip: flip, pid: pid) { [weak self] in
                self?.learn(from: flip)
            }
        }

        pipeline.onChange = { [weak debugWindow] snapshot in
            debugWindow?.accept(snapshot)
        }
        pipeline.onDecision = { [weak debugWindow] decision in
            debugWindow?.accept(decision)
        }
        pipeline.onAutoApply = { [weak controller] applied in
            DispatchQueue.main.async { controller?.showAutoApply(applied) }
        }
        pipeline.onSuggest = { [weak suggestions] offer in
            DispatchQueue.main.async { suggestions?.show(fix: offer.fix, pid: offer.pid) }
        }
        pipeline.onHideSuggestion = { [weak suggestions] in
            DispatchQueue.main.async { suggestions?.dismiss() }
        }
        pipeline.onRequestRejected = { [weak controller] in
            DispatchQueue.main.async { controller?.showRejected() }
        }
        pipeline.onUndoApplied = { [weak controller] in
            DispatchQueue.main.async { controller?.showUndo() }
        }
        pipeline.start()
        self.pipeline = pipeline

        controller.onUndo = { [weak pipeline] in
            pipeline?.undoLastFix()
        }
        controller.isUndoAvailable = { [weak pipeline] in
            // Not just "is there one": an item that is enabled and then
            // answers with a ✕ because the app is paused is worse than a
            // greyed-out one.
            pipeline?.canUndo() ?? false
        }
        controller.onFlip = { [weak pipeline] in
            pipeline?.flipSelection()
        }
        controller.isFlipAvailable = { [weak pipeline] in
            pipeline?.canFlip() ?? false
        }

        // Carbon, not the event tap: the shortcut has to work in exactly the
        // situations where the tap does not. See `HotkeyCenter`.
        hotkeys.onAction = { [weak self] action in
            switch action {
            case .undoLastFix:
                self?.pipeline?.undoLastFix()
            case .togglePause:
                // Through the menu controller so the checkmark, the settings
                // blob and the pipeline all move together.
                self?.menuBarController?.togglePause()
                self?.menuBarController?.showPauseChanged(paused: self?.settings.paused ?? false)
            case .flipSelection:
                self?.pipeline?.flipSelection()
            }
        }
        hotkeys.register()
        if !hotkeys.registeredActions.contains(.undoLastFix) {
            controller.clearUndoShortcut()
        }
        if !hotkeys.registeredActions.contains(.flipSelection) {
            controller.clearFlipShortcut()
        }

        // Both halves of the safety layer feed the pipeline the same way: a
        // flag it caches on its own queue, plus a buffer drop on the way up.
        //
        // One notification, two listeners. The settings window is the second
        // because it has to show what was actually persisted rather than what
        // its own control was set to, and because a change made from the menu
        // has to move the switch in an open window.
        settings.onChange = { [weak pipeline, weak settingsWindow] updated in
            pipeline?.apply(updated)
            settingsWindow?.settingsChanged(updated)
        }
        // The third way the settings can change: `harf --set` in another
        // process. It writes the blob and asks this copy to re-read it over the
        // single-instance port, and the reply lands in the same `onChange` above
        // — so a change made from a shell moves the pipeline and the settings
        // window exactly as a menu click does. The hook lives in `RuntimeStatus`
        // because the port callback is a C function pointer and can reach a
        // static and nothing else.
        //
        // Republished at once rather than on the next poll: the `harf --set`
        // that asked for the reload is usually followed by a `harf --status`
        // within the second, and a snapshot up to two seconds old would tell it
        // — wrongly — that the saved settings and the running copy disagree.
        RuntimeStatus.setReloadHandler { [weak self] in
            guard let self, self.settings.reload() else { return }
            self.refreshPermissions()
        }
        // And the fourth: `harf --words` in another process. It writes
        // `lexicon.json` and sends the same kind of nudge, which the lexicon
        // answers by merging the file into the words it is already using
        // rather than by taking it wholesale — the session's own counting is
        // in memory and nowhere else. Without this the edit had a twenty-second
        // fuse: the app's next save wrote its own copy straight back over it.
        RuntimeStatus.setVocabularyHandler { [weak self] in
            self?.lexicon.reloadSoon()
        }
        controller.onPauseChanged = { [weak self] _ in
            self?.refreshPermissions()
        }
        secureInput.onChange = { [weak self] active in
            self?.pipeline?.setSecureInput(active)
            self?.refreshPermissions()
        }
        // Activating an app is the usual way secure input comes on between two
        // polls, so it is checked there as well as every second.
        frontmost.addObserver { [weak self] _ in
            self?.secureInput.refresh()
        }
        secureInput.start()
        pipeline.setSecureInput(secureInput.isEnabled)
        pipeline.apply(settings.settings)

        eventTap = EventTapController(
            queue: pipeline.queue,
            suggestion: suggestionState,
            onDegraded: { [weak self] in
                DispatchQueue.main.async {
                    self?.tapDegraded = true
                    self?.refreshPermissions()
                }
            },
            handler: { [weak pipeline] event in
                pipeline?.handle(event)
            })

        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

        refreshPermissions()

        // After the first permission read, so the walkthrough opens only when
        // there is genuinely something missing.
        if Onboarding.isNeeded(
            permissions: Permissions.current(), hasCompleted: settings.onboardingCompleted)
        {
            onboarding.show()
        } else {
            // Both grants are already in place, so there is nothing to walk
            // through — and the flag has to be set anyway. Without this, an
            // install that was granted before Dodoma ever ran keeps the flag
            // unset forever, and the first time a grant is revoked (which
            // `scripts/reset-tcc.sh` in the README's own troubleshooting does)
            // the next login opens a window that takes the screen. Onboarding
            // is for the first run, not for every later permission problem;
            // the menu's status line handles those.
            settings.setOnboardingCompleted(true)
        }

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // What was learned this session outlives it.
        pipeline?.lexicon.save()

        // The port can still take a message while the app is going down. With
        // the handlers cleared a late reload does nothing instead of reaching
        // into a half-torn-down pipeline.
        RuntimeStatus.setReloadHandler(nil)
        RuntimeStatus.setVocabularyHandler(nil)

        pollTimer?.invalidate()
        pollTimer = nil
        hotkeys.unregister()
        suggestionController?.dismiss()
        secureInput.stop()
        eventTap?.stop()
        pipeline?.stop()
    }

    /// Takes the flip card's Learn button at its word: the flipped reading was
    /// right, so its words belong to the language it was flipped into and the
    /// words that were counted for the other one were noise.
    private func learn(from flip: Flip) {
        let plan = FlipLearning.plan(
            for: flip,
            target: LanguageModel.shared(flip.targetLanguage),
            source: LanguageModel.shared(flip.sourceLanguage))
        for word in plan.add { lexicon.add(word, language: flip.targetLanguage) }
        for word in plan.forget { lexicon.forgetCount(word, language: flip.sourceLanguage) }
        // Not `save()`: this runs on the main thread, from a button press, and
        // a synchronous write of the whole lexicon would stall the cursor.
        // Interval 0 makes it due now, and the write itself happens on the
        // lexicon's own IO queue.
        lexicon.saveIfDue(interval: 0)
        Log.app.info(
            "flip learned: \(plan.add.count, privacy: .public) added, \(plan.forget.count, privacy: .public) forgotten"
        )
    }

    /// The tables are ~800 KB of JSON and word lists. Loading them here, off
    /// the main thread, keeps the first evaluation from stalling the typing
    /// queue a second after the user's first keystroke.
    private func preloadLanguageModels() {
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            do {
                for language in Language.allCases {
                    try LanguageModel.shared(language).preload()
                }
            } catch {
                Log.app.fault(
                    "language models failed to load: \(String(describing: error), privacy: .public); nothing will ever be detected"
                )
                return
            }
            let millis = Date().timeIntervalSince(started) * 1000
            Log.app.info(
                "language models loaded in \(millis, format: .fixed(precision: 0), privacy: .public) ms"
            )
        }
    }

    private func refreshPermissions() {
        let state = Permissions.current()

        // The tap can only be created once the grants are in place, so retry on
        // every poll until it succeeds and then leave it alone.
        if let eventTap, !eventTap.isRunning {
            eventTap.start()
        }
        let capturing = eventTap?.isRunning ?? false

        menuBarController?.update(
            with: state, capturing: capturing, secureInput: secureInput.isEnabled,
            degraded: tapDegraded)
        // Detection — and therefore injection — only runs while the tap does.
        pipeline?.setCaptureActive(capturing && state.accessibility && state.inputMonitoring)
        // Both windows show state that changes outside the app — the grants and
        // the login-item registration — and both no-op while hidden, so they
        // ride this poll rather than starting timers of their own. After the
        // pipeline, which is the part with a deadline.
        onboardingWindowController?.update(permissions: state)
        settingsWindowController?.poll()

        // What `harf --status` reads out of this process over the
        // single-instance port. Published here because this method already
        // computes every field on its own two-second poll, and published
        // *above* the change guard below on purpose: below it, the snapshot
        // would only ever be written when the grants or the capture state
        // moved, so a paused app or a changed setting would be reported as
        // whatever was true the last time a permission changed — a snapshot
        // frozen days ago, which is the exact failure this whole feature exists
        // to end.
        RuntimeStatus.publish(
            RuntimeSnapshot(
                appVersion: DodomaCore.Dodoma.version,
                pid: ProcessInfo.processInfo.processIdentifier,
                permissions: state,
                capturing: capturing,
                paused: settings.paused,
                secureInput: secureInput.isEnabled,
                degraded: tapDegraded,
                // One launchd round trip every two seconds. It is the same call
                // the settings window makes while it is open, and the answer
                // changes outside the app — a user can approve or revoke the
                // login item in System Settings — so there is nothing to cache.
                loginItem: LoginItem.status,
                settings: settings.settings))

        guard state != lastState || capturing != lastCapturing else { return }
        lastState = state
        lastCapturing = capturing
        Log.app.info(
            "permissions accessibility=\(state.accessibility, privacy: .public) inputMonitoring=\(state.inputMonitoring, privacy: .public) capturing=\(capturing, privacy: .public)")
    }
}
