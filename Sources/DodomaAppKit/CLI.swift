import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Non-GUI entry points. Every command here runs without Accessibility or
/// Input Monitoring grants and exits before `NSApplication` is touched.
public enum CLI {
    public enum Command: Equatable {
        case render(text: String?)
        case dumpLayoutFixtures(path: String?)
        case score(text: String?)
        case decide(text: String?, language: String?, aggressiveness: String?, confident: String?)
        case eval(path: String?, aggressiveness: String?, confident: String?)
        case status
        case config
        case set(key: String?, value: String?)
        case policy(bundleID: String?, mode: String?)
        case skipVerify(bundleID: String?, state: String?)
        case unknown(argument: String)
        case words(action: String?, word: String?, language: String?)
        case quit
        case help
    }

    /// Whether this process is running out of an application bundle.
    ///
    /// The whole launch decision turns on this, so it is worth being precise
    /// about what it means. `Bundle.main.bundleIdentifier` is nil for a process
    /// started from the executable — including through the `harf` symlink the
    /// Homebrew cask puts on the PATH, which points *into* the bundle and still
    /// leaves `Bundle.main` pointing at `/opt/homebrew/bin`. It is non-nil only
    /// when macOS launched the `.app`, which is exactly the launch that wants
    /// the menu-bar application.
    public static var isBundled: Bool { LoginItem.isBundled }

    /// The escape hatch out of the bundle rule, for the one launch it would
    /// otherwise break: an unbundled GUI run during development. `swift run
    /// Harf`, `.build/release/Harf` and a debugger session all arrive with no
    /// bundle identifier and would get the usage block.
    ///
    /// An environment variable rather than a flag, so it survives `lldb`, an
    /// Xcode scheme and a `swift run` that passes no arguments of its own, and
    /// so it cannot be typed by accident by someone reaching for `--help`.
    public static func isApplicationForced(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["HARF_FORCE_APP"] == "1"
    }

    /// The lexicon the running app reads and writes, so a word added from a
    /// shell is the same word the app looks up.
    static func sharedLexicon() -> UserLexicon { UserLexicon(url: UserLexicon.defaultURL()) }

    static let helpText = """
        harf — fixes text typed with the wrong keyboard layout

        Shortcuts
          ⌃⌘F   flip the selection, or the last thing you typed, to the other layout
          ⌥⌘Z   put the last fix back, for 30 seconds
          ⌥⌘P   pause and resume

        Configuration
          --status                     every setting, permission and list, in full
          --config                     the same thing as JSON, for scripts and diffs
          --quit                       stop the running copy, letting it save the
                                       words it learned on the way out
          --set KEY VALUE              change one setting; keys and values below
          --words [list|add|remove|clear] [WORD] --lang en|ar
                                       your own vocabulary, kept in
                                       ~/Library/Application Support/Harf/lexicon.json
          --policy [BUNDLE_ID [MODE]]  list, read, or set an app's mode
          --skip-verify [BUNDLE_ID [on|off]]
                                       apps allowed to rewrite without checking
                                       the caret first; see Per-app modes below

          A change made here reaches the running copy straight away: the setting
          is saved and that copy is then asked to re-read it, so the menu, the
          settings window and the pipeline all move with it. If it cannot be
          asked, the command says so — the setting is still saved and will be in
          force at the next launch.

          --words works the same way. The word is written to the file and the
          running copy is asked to take it, which it does by merging the change
          into the vocabulary it is already using — so a word added here counts
          on the next keystroke, and the words it has learned this session are
          not lost to the merge. Nothing has to be quit first.

          --status reports the copy that is running, not this terminal: its
          permissions, the settings it is actually enforcing, and the same status
          line the menu shows. Permissions are granted per process, so the ones
          a terminal has are not the ones the app has; when no copy is running,
          or the running one does not answer, the grants read `unknown` rather
          than `no` and the settings shown are the saved ones.

        Settings you can change            values                     default
          paused                           yes | no                   no
          sensitivity                      conservative | balanced    balanced
                                           | eager
          confident                        a score, 70 or 0.70,       90
                                           or off
          buffer                           20-500 keystrokes          200
          idle                             seconds before the         10
                                           buffer is dropped
          learn                            yes | no                   yes
          debugLogging                     yes | no                   no
          defaultPolicy                    normal | suggestOnly       normal
                                           | off

          sensitivity moves the three automatic gates together. confident is a
          separate shortcut for text too short for those gates: a reading at or
          above it is applied however few letters there are, and `off` restores
          the length rules. Turning sensitivity up while confident sits near
          100 pulls in opposite directions.

        Per-app modes
          normal        replaces silently when one reading wins clearly, and
                        offers a card when the two are close
          suggestOnly   never deletes anything by itself; Tab applies the card,
                        esc dismisses it, and so does carrying on typing
          off           captures nothing at all in that app

          Every app is normal until changed, including ones installed later.
          Terminals ship as suggestOnly, password managers as off.

          harf --policy                              list every app
          harf --policy com.mitchellh.ghostty normal
          osascript -e 'id of app "Slack"'           find a bundle id

          Or click the menu bar icon with the app you mean in front: the
          submenu applies to that app alone.

        Starting and stopping the app
          Open /Applications/Harf.app. `harf` with no arguments is the command
          line, not the application: it prints a usage block and exits 2, rather
          than starting a second copy that taps the keyboard alongside the one
          already running and corrects everything twice. Only one copy runs at a
          time; a second says which one won and exits 3.

          HARF_FORCE_APP=1 harf         start an unbundled build as the app
                                        anyway (swift run, lldb, development)
          HARF_IGNORE_INSTANCE=1 harf   skip the single-copy check, with a
                                        warning in the log

        Inspecting a decision
          --render TEXT                what those keys produce under each layout
          --score TEXT                 how the text reads in each language
          --decide TEXT                the verdict, with every gate it passed
              [--lang en|ar] [--aggressiveness conservative|balanced|eager]
              [--confident 0.9]
          --eval FILE.tsv              run a labelled corpus
          --preview-cards              watch the floating cards animate, without
                                       reproducing what raises them

        Examples
          harf --status                      what is switched on right now
          harf --set paused yes              stop everything, without quitting
          harf --set sensitivity eager       act on weaker evidence
          harf --set confident 70            fix short words scoring 70% or better
          harf --set buffer 60               hold less of what you type
          harf --set idle 5                  forget it sooner after you stop
          harf --set learn off               stop remembering words, erase the file
          harf --set defaultPolicy off       an allowlist: silent everywhere but
                                             the apps you then set to normal
          harf --policy com.apple.Terminal off
          harf --words add kubectl --lang en
          harf --decide "hgsghl ugd;l"
        """

    /// Layouts snapshotted into the test fixture. Tests render through these
    /// rather than through whatever is enabled on the running machine.
    private static let fixtureSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.Arabic",
    ]

    /// - Parameter isBundled: whether this process was launched as the `.app`.
    ///   It only decides how forgiving the typo net at the bottom is; every
    ///   recognised option parses the same either way.
    public static func parse(_ arguments: [String], isBundled: Bool = true) -> Command? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1)
            else { return nil }
            return arguments[index + 1]
        }

        for (index, argument) in arguments.enumerated() {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            switch argument {
            case "--render":
                return .render(text: next)
            case "--dump-layout-fixtures":
                return .dumpLayoutFixtures(path: next)
            case "--score":
                return .score(text: next)
            case "--decide":
                return .decide(
                    text: next,
                    language: value(after: "--lang"),
                    aggressiveness: value(after: "--aggressiveness"),
                    confident: value(after: "--confident"))
            case "--eval":
                return .eval(path: next, aggressiveness: value(after: "--aggressiveness"),
                             confident: value(after: "--confident"))
            case "--status":
                return .status
            case "--config":
                return .config
            case "--set":
                return .set(key: next, value: arguments.indices.contains(index + 2)
                            ? arguments[index + 2] : nil)
            case "--skip-verify":
                return .skipVerify(bundleID: next, state: arguments.indices.contains(index + 2)
                                   ? arguments[index + 2] : nil)
            case "--policy":
                return .policy(bundleID: next, mode: arguments.indices.contains(index + 2)
                               ? arguments[index + 2] : nil)
            case "--words":
                return .words(
                    action: next, word: arguments.indices.contains(index + 2)
                        ? arguments[index + 2] : nil,
                    language: value(after: "--lang"))
            case "--quit":
                return .quit
            case "--help", "-h":
                return .help
            default:
                continue
            }
        }

        // Nothing matched. Returning nil here means "no command", and for a
        // bundled launch the answer to no command is to start the menu-bar
        // application — so a mistyped flag used to launch a second copy of the
        // app, in the foreground, which never exits. Two instances means two
        // event taps both capturing and both able to inject.
        //
        // How wide the net is depends on where the arguments came from, because
        // the two sources have nothing in common. macOS hands a *bundled*
        // application single-dash arguments of its own — -psn_0_… from
        // LaunchServices, -NSDocumentRevisionsDebugMode and friends, and file
        // paths on an open-with — and refusing to start because of one would be
        // a worse bug than the one this fixes. So a bundled launch only treats
        // a long option as a typo.
        //
        // Nothing hands arguments to the *unbundled* executable except a person
        // at a shell, and there `harf -status` and `harf status` are typos as
        // plainly as `--staus` is. Without this they fall through to nil, and
        // nil unbundled means the usage block: the same exit code, but a screen
        // of general help instead of a line naming what was actually typed.
        if let mistyped = arguments.first(where: { $0.hasPrefix("--") }) {
            return .unknown(argument: mistyped)
        }
        if !isBundled, let stray = arguments.first {
            return .unknown(argument: stray)
        }
        return nil
    }

    /// What the process should do, once the arguments have been read.
    public enum Launch: Equatable {
        case run(Command)
        /// Start the menu-bar application: `NSApplication`, event tap and all.
        case application
        /// Print `usageText` and exit non-zero.
        case usage
    }

    /// Whether a command line asks for a command, for the application, or for
    /// neither.
    ///
    /// No command used to mean "start the application" unconditionally, and
    /// that is how one copy of Harf ran for sixteen hours out of a terminal
    /// window. The Homebrew cask links this executable onto the PATH as
    /// `harf`, so typing the tool's own name started the whole menu-bar app —
    /// a second event tap alongside the one in /Applications, correcting
    /// everything the user typed a second time. Nothing said so: the app is an
    /// accessory with no Dock tile, and started from the executable rather
    /// than the bundle it carries no bundle identifier, so neither
    /// LaunchServices nor `pkill -x Harf` could see it.
    ///
    /// - Parameter isBundled: whether macOS launched the `.app`.
    ///
    ///   This is the signal, and unlike the controlling terminal it briefly
    ///   replaced, it is exact rather than close: it is the same question the
    ///   process is *already* answering everywhere else it matters — it is what
    ///   `LoginItem` asks before touching `SMAppService`, and it is precisely
    ///   what makes a shell-started copy invisible to `pkill -x Harf` and to
    ///   LaunchServices. A bundled launch is the application; anything else is
    ///   the command line wearing the application's binary.
    ///
    /// - Parameter isTerminal: whether a person is watching, from `isatty`.
    ///
    ///   Deliberately not part of the answer, and kept as a parameter so that
    ///   staying out of it is a decision with tests on it rather than an
    ///   omission. The tty test was the first attempt at this and it was wrong
    ///   in both directions. `swift run Harf` has a terminal and is not the
    ///   application; and `harf >/dev/null 2>&1 &` — a cron line, a CI step, a
    ///   login script — has none and is *still* not the application, which is
    ///   the case that matters, because it starts an event tap nobody knows
    ///   about and takes the single-instance name from the copy the user
    ///   actually opens later.
    ///
    /// - Parameter forceApplication: the way back for an unbundled GUI run.
    ///   `HARF_FORCE_APP=1` is what `swift run` and a debugger session use; see
    ///   `isApplicationForced`.
    ///
    /// A parsed command runs whatever the launch looks like. Commands are the
    /// reason the binary is on the PATH, they never start a tap, and a bundled
    /// `Harf.app --status` is a legitimate way to run one.
    public static func launch(
        command: Command?, isBundled: Bool, isTerminal: Bool, forceApplication: Bool = false
    ) -> Launch {
        if let command { return .run(command) }
        if isBundled || forceApplication { return .application }
        return .usage
    }

    /// Short enough to be read in a terminal that was expecting a tool, and it
    /// answers the two questions someone who typed `harf` now has: what the
    /// command does, and how the application is started instead.
    public static let usageText = """
        harf — fixes text typed with the wrong keyboard layout

          harf --status    what is switched on right now
          harf --quit      stop the copy that is running
          harf --help      every command and setting, in full

        To start the app, open /Applications/Harf.app. Running it from a
        terminal would leave a second copy tapping the keyboard alongside the
        one already running, and both would correct the same text — so this
        does nothing but print these lines. To run an unbundled build as the
        application anyway, during development, set HARF_FORCE_APP=1.
        """

    /// Non-zero, so a script that runs `harf` expecting it to do something does
    /// not quietly succeed.
    public static func usage() -> Int32 { fail(usageText, code: 2) }

    public static func run(_ command: Command) -> Int32 {
        switch command {
        case .render(let text):
            guard let text else {
                return fail("--render: expected a TEXT argument", code: 2)
            }
            return render(text)
        case .dumpLayoutFixtures(let path):
            guard let path else {
                return fail("--dump-layout-fixtures: expected an output path", code: 2)
            }
            return dumpLayoutFixtures(to: path)
        case .score(let text):
            guard let text else {
                return fail("--score: expected a TEXT argument", code: 2)
            }
            return score(text)
        case .decide(let text, let language, let aggressiveness, let confident):
            guard let text else {
                return fail("--decide: expected a TEXT argument", code: 2)
            }
            return decide(
                text, language: language, aggressiveness: aggressiveness, confident: confident)
        case .eval(let path, let aggressiveness, let confident):
            guard let path else {
                return fail("--eval: expected a corpus path", code: 2)
            }
            return eval(path, aggressiveness: aggressiveness, confident: confident)
        case .status:
            return CLIConfig.status(SettingsStore(), lexicon: sharedLexicon())
        case .config:
            return CLIConfig.dump(SettingsStore())
        case .set(let key, let value):
            return writing { CLIConfig.set(key, value, store: $0) }
        case .policy(let bundleID, let mode):
            return writing { CLIConfig.policy(bundleID, mode, store: $0) }
        case .skipVerify(let bundleID, let state):
            return writing { CLIConfig.skipVerify(bundleID, state, store: $0) }
        case .unknown(let argument):
            return fail("unknown option '\(argument)'. Run harf --help for the full list.", code: 2)
        case .words(let action, let word, let language):
            return CLIConfig.words(action, word, language: language, lexicon: sharedLexicon())
        case .quit:
            return quit()
        case .help:
            print(helpText)
            return 0
        }
    }

    // MARK: - Writing a setting

    /// Every command that changes the settings blob, wrapped so the copy that is
    /// running finds out about it.
    ///
    /// The blob was always shared; what was missing was anybody re-reading it.
    /// `SettingsStore` loads once at init and caches, so `harf --set paused yes`
    /// against a running app changed a file and nothing else — and the app's next
    /// write copied its stale cache straight over it. `UserDefaults
    /// .didChangeNotification` does not help, being same-process only, so the
    /// notification goes over the single-instance port instead.
    ///
    /// `flush` before the message, because the two ends are different processes:
    /// without it the app can read the blob back before this one's write has left
    /// its own `UserDefaults` cache, find the old bytes, and conclude that
    /// nothing changed.
    ///
    /// A refusal is a warning, not a failure. The setting *is* saved; what did
    /// not happen is the running copy taking it now, and the exit code has to
    /// stay 0 or every script that changes a setting starts failing whenever the
    /// app's run loop is busy.
    ///
    /// `--words` is not routed through here because it changes a different file
    /// and sends a different message, but it does the same two things in the
    /// same order: see `CLIConfig.tellTheRunningCopy`.
    private static func writing(_ body: (SettingsStore) -> Int32) -> Int32 {
        let store = SettingsStore()
        let code = body(store)
        guard code == 0 else { return code }

        store.flush()
        if SingleInstance.isHeld(), !SingleInstance.requestReload() {
            warn(
                "Harf is running but did not take the change; it will pick it up when it "
                    + "restarts.")
        }
        return code
    }

    // MARK: - Quitting

    /// Stops the running copy, the way that lets it save first.
    ///
    /// The alert, `make install`, `make run`, `scripts/uninstall.sh` and the
    /// README all used to say `pkill`, which skips `applicationWillTerminate`
    /// and with it the only write of the words learned since the last flush —
    /// up to twenty seconds of them. It also could not name the copy started
    /// from a shell, which is the one the alert exists to talk about. One
    /// command now does both, because it goes through the single-instance name
    /// rather than through the process table.
    private static func quit() -> Int32 {
        let outcome = SingleInstance.requestQuit()
        let message = SingleInstance.quitMessage(for: outcome)
        let code = SingleInstance.quitExitCode(for: outcome)
        if code == 0 {
            print(message)
        } else {
            warn(message)
        }
        return code
    }

    // MARK: - Scoring

    private static func score(_ text: String) -> Int32 {
        if let message = preloadModels() { return fail("--score: \(message)", code: 1) }
        print("text: \(text)")
        print("lang   bigram  dict    combined")
        // Same reasoning as `--decide`: this reports how the running app reads
        // the text, and the app reads it with the user's own words counting.
        let lexicon = sharedLexicon()
        for language in Language.allCases {
            let model = LanguageModel.shared(language)
            model.lexicon = lexicon
            let score = model.combined(text)
            print(
                String(
                    format: "%@     %-7.3f %-7.3f %.3f", language.rawValue,
                    score.bigram, score.dictCoverage, score.combined))
        }
        return 0
    }

    // MARK: - Deciding

    private static func decide(
        _ text: String, language: String?, aggressiveness: String?, confident: String?
    ) -> Int32 {
        if let message = preloadModels() { return fail("--decide: \(message)", code: 1) }
        guard let detector = liveDetector(withLearnedWords: true) else {
            return fail("--decide: \(layoutPairProblem())", code: 1)
        }

        let typedLanguage: Language
        switch language?.lowercased() {
        case nil:
            typedLanguage = Detector.scriptLanguage(of: text)
        case "en", "english":
            typedLanguage = .english
        case "ar", "arabic":
            typedLanguage = .arabic
        case let other?:
            return fail("--decide: --lang expects en or ar, got \(other)", code: 2)
        }

        guard let level = parseAggressiveness(aggressiveness) else {
            return fail(
                "--decide: --aggressiveness expects one of "
                    + Aggressiveness.allCases.map(\.rawValue).joined(separator: ", "),
                code: 2)
        }

        let sourceLayout = detector.layout(for: typedLanguage)
        let threshold = confidentScore(confident, flag: "--decide")
        if let problem = threshold.problem { return fail(problem, code: 2) }
        guard let detection = detector.detect(text: text, typedLanguage: typedLanguage,
                                              aggressiveness: level,
                                              confidentScore: threshold.score)
        else {
            let character = InverseKeymap.unmappableCharacter(in: text, layout: sourceLayout)
            return fail(
                "--decide: \(sourceLayout.sourceID) has no key for "
                    + "'\(character.map(String.init) ?? "?")'",
                code: 2)
        }

        print("text:          \(text)")
        print("typed layout:  \(sourceLayout.sourceID) (\(typedLanguage.rawValue))")
        print("aggressiveness: \(level.rawValue)")

        guard let region = detection.region, let analysis = detection.analysis else {
            print("decision:      ignore (\(reasonText(detection.decision)))")
            return 0
        }

        print("region:        \(region.typedText)")
        print(
            "               letters \(region.letterCount), tokens \(region.tokenCount), "
                + "completed \(region.completedTokenCount)")
        print(String(format: "current:       bigram %.3f dict %.3f combined %.3f",
                     analysis.current.bigram, analysis.current.dictCoverage,
                     analysis.current.combined))
        print(String(format: "alternate:     bigram %.3f dict %.3f combined %.3f",
                     analysis.alternate.bigram, analysis.alternate.dictCoverage,
                     analysis.alternate.combined))
        print(String(format: "gap:           %.3f", analysis.gap))
        print("capsMode:      \(analysis.capsMode?.rawValue ?? "none")")
        print("guards:        \(analysis.guards.summary)")

        switch detection.decision {
        case .ignore(let reason):
            print("decision:      ignore (\(reason))")
        case .suggest(let fix):
            printFix("suggest", fix)
        case .autoApply(let fix):
            printFix("autoApply", fix)
        }
        return 0
    }

    private static func printFix(_ verdict: String, _ fix: Fix) {
        print("decision:      \(verdict)")
        print("  delete:      \(fix.deleteCount)")
        print("  insert:      \(fix.insertText)")
        print("  target:      \(fix.targetLayoutID)")
    }

    private static func reasonText(_ decision: Decision) -> String {
        if case .ignore(let reason) = decision { return reason }
        return ""
    }

    // MARK: - Eval

    private static func eval(_ path: String, aggressiveness: String?, confident: String?)
        -> Int32
    {
        let threshold = confidentScore(confident, flag: "--eval")
        if let problem = threshold.problem { return fail(problem, code: 2) }

        if let message = preloadModels() { return fail("--eval: \(message)", code: 1) }
        guard let detector = corpusDetector() else {
            return fail(
                "--eval: this machine needs both an English and an Arabic keyboard layout enabled",
                code: 1)
        }
        guard let level = parseAggressiveness(aggressiveness) else {
            return fail("--eval: unknown --aggressiveness value", code: 2)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return fail("--eval: cannot read \(path): \(error.localizedDescription)", code: 2)
        }

        let rows: [EvalRow]
        do {
            rows = try EvalHarness.parse(contents)
        } catch {
            return fail("--eval: \(error)", code: 2)
        }

        let report = EvalHarness.run(
            rows: rows, detector: detector, aggressiveness: level,
            confidentScore: threshold.score)
        print(report.render())
        return report.exitCode
    }

    // MARK: - Shared helpers

    /// Forces both language models in so a missing or malformed resource
    /// exits with a message instead of quietly scoring everything as zero.
    /// Returns a description of the failure, or nil on success.
    private static func preloadModels() -> String? {
        for language in Language.allCases {
            do {
                try LanguageModel.shared(language).preload()
            } catch {
                return "\(error)"
            }
        }
        return nil
    }

    /// Reads the `--confident` argument that `--decide` and `--eval` share,
    /// through the one reading `--set confident` uses, so a threshold typed at
    /// a flag and the same threshold typed into the settings mean one number.
    ///
    /// A bare `Double.init` used to stand here, which took `--confident 90` as
    /// a threshold of 90.0. Nothing scores above 1, so every fix was blocked
    /// and the command still exited zero — the worst shape a wrong answer can
    /// take, because `--eval`'s exit code is read by a build gate as a verdict
    /// on the corpus. A value that is not a score is now named and the command
    /// stops, rather than being taken at face value.
    ///
    /// Nil `raw` is the flag left off, which is the gate off and not a failure.
    static func confidentScore(_ raw: String?, flag: String)
        -> (score: Double?, problem: String?)
    {
        guard let raw else { return (nil, nil) }
        guard let score = CLIConfig.confidentScore(raw) else {
            return (
                nil,
                "\(flag): --confident expects a score such as 0.9 or 90, got '\(raw)'")
        }
        return (score, nil)
    }

    private static func parseAggressiveness(_ raw: String?) -> Aggressiveness? {
        guard let raw else { return .balanced }
        return Aggressiveness(rawValue: raw)
    }

    /// The pair the running app would use right now, which is the point of
    /// `--decide`: it reports the verdict the app would reach, and the app
    /// reads keycodes through the layout the user has *selected*, not through
    /// whichever English layout happens to be first in the enabled list.
    ///
    /// - Parameter withLearnedWords: whether the user's own vocabulary counts.
    ///
    ///   `--decide` says yes, because its whole job is to report what the
    ///   running app would do, and the app scores with the lexicon attached;
    ///   without it the command quietly disagrees with the thing it is
    ///   describing.
    private static func liveDetector(withLearnedWords: Bool = false) -> Detector? {
        guard let pair = LayoutEngine().currentPair() else { return nil }
        let detector = Detector(englishLayout: pair.english, arabicLayout: pair.arabic)
        if withLearnedWords {
            let lexicon = sharedLexicon()
            detector.englishModel.lexicon = lexicon
            detector.arabicModel.lexicon = lexicon
        }
        return detector
    }

    /// The pair a labelled corpus is scored through: the first enabled English
    /// and Arabic layouts, and nothing about the operator.
    ///
    /// Deliberately not `currentPair()`. That resolves against the input source
    /// selected at the moment the command runs and returns nil when the
    /// selection is a third language, so a run of `--eval` would score
    /// differently — or refuse outright — depending on what the person at the
    /// keyboard had last pressed ⌃Space to. A corpus has to score the same on
    /// every machine and on every run, or it is not a measurement; the numbers
    /// it produces are compared against numbers from other machines.
    ///
    /// The lexicon is left off for the same reason: a run whose scores depend
    /// on what its operator has been typing lately measures the operator.
    private static func corpusDetector() -> Detector? {
        let enabled = LayoutEngine.enabledKeyboardLayouts()
        guard
            let english = enabled.first(where: { $0.language == .english }),
            let arabic = enabled.first(where: { $0.language == .arabic })
        else { return nil }
        return Detector(englishLayout: english, arabicLayout: arabic)
    }

    /// Why no English/Arabic pair could be resolved, in the words of the thing
    /// the user has to go and change.
    ///
    /// One message used to cover this — "enable both layouts" — and it is the
    /// wrong advice for two of the three ways it now happens, both of which
    /// arrive on a machine that already has both layouts enabled. Pure, and
    /// separate from the lookup, so all three readings are a test.
    static func layoutPairProblem(
        enabled: [KeyboardLayout] = LayoutEngine.enabledKeyboardLayouts(),
        selectedID: String? = LayoutEngine.selectedLayoutID()
    ) -> String {
        guard
            enabled.contains(where: { $0.language == .english }),
            enabled.contains(where: { $0.language == .arabic })
        else {
            return "this machine needs both an English and an Arabic keyboard layout "
                + "enabled in System Settings > Keyboard > Input Sources"
        }

        guard let selectedID else {
            return "macOS did not report a selected input source, so there is no layout to "
                + "read these keys through"
        }
        guard let selected = enabled.first(where: { $0.sourceID == selectedID }) else {
            return "the selected input source (\(selectedID)) carries no keyboard layout "
                + "table — it is an input method rather than a layout — so there is nothing "
                + "to read these keys through; select the English or Arabic layout and run "
                + "this again"
        }
        return "the selected input source (\(selected.localizedName)) is neither English nor "
            + "Arabic. Harf arbitrates between those two and reads keys through the layout "
            + "you are actually typing in, so select one of them and run this again"
    }

    // MARK: - Existing commands

    private static func render(_ text: String) -> Int32 {
        guard let keys = KeycodeMap.keys(forLatin: text) else {
            return fail("--render: input has characters with no US keycode mapping", code: 2)
        }

        let layouts = LayoutEngine.enabledKeyboardLayouts()
        guard !layouts.isEmpty else {
            return fail("--render: no enabled keyboard layout carries a uchr table", code: 1)
        }

        print("selected: \(LayoutEngine.selectedLayoutID() ?? "unknown")")
        for layout in layouts {
            for capsMode in CapsMode.allCases {
                let rendered = LayoutRenderer.renderSequence(
                    keys, layout: layout, capsMode: capsMode)
                var line = "\(layout.sourceID) \(capsMode.rawValue): \(rendered.text)"
                if rendered.emptyRate > 0 {
                    line += String(format: "  (emptyRate %.2f)", rendered.emptyRate)
                }
                print(line)
            }
        }
        return 0
    }

    private static func dumpLayoutFixtures(to path: String) -> Int32 {
        let layouts = LayoutEngine.enabledKeyboardLayouts()
        let matched = fixtureSourceIDs.compactMap { sourceID in
            layouts.first { $0.sourceID == sourceID }
        }
        guard !matched.isEmpty else {
            return fail(
                "--dump-layout-fixtures: none of \(fixtureSourceIDs.joined(separator: ", ")) are enabled",
                code: 1)
        }
        for sourceID in fixtureSourceIDs where !matched.contains(where: { $0.sourceID == sourceID })
        {
            warn("--dump-layout-fixtures: \(sourceID) is not enabled, skipping")
        }

        let keyboardType = UInt32(LMGetKbdType())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: path)
        do {
            let fixtures = matched.map {
                LayoutFixture(layout: $0, keyboardType: keyboardType)
            }
            let data = try encoder.encode(fixtures)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return fail("--dump-layout-fixtures: \(error.localizedDescription)", code: 1)
        }

        print("wrote \(matched.count) layout fixture(s) to \(path)")
        return 0
    }

    /// Standard error, so a warning never lands in the middle of output a script
    /// is parsing. Internal because `writing` is not the only caller any more.
    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func fail(_ message: String, code: Int32) -> Int32 {
        warn(message)
        return code
    }
}
