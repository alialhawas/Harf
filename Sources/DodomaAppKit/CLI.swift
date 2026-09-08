import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Non-GUI entry points. Every command here runs without Accessibility or
/// Input Monitoring grants and exits before `NSApplication` is touched.
public enum CLI {
    public enum Command {
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
        case help
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
          --set KEY VALUE              change one setting; keys and values below
          --words [list|add|remove|clear] [WORD] --lang en|ar
                                       your own vocabulary, kept in
                                       ~/Library/Application Support/Harf/lexicon.json
          --policy [BUNDLE_ID [MODE]]  list, read, or set an app's mode
          --skip-verify [BUNDLE_ID [on|off]]
                                       apps allowed to rewrite without checking
                                       the caret first; see Per-app modes below

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

    public static func parse(_ arguments: [String]) -> Command? {
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
            case "--help", "-h":
                return .help
            default:
                continue
            }
        }

        // Nothing matched. Returning nil here means "no command", and the
        // caller's answer to no command is to start the menu-bar application —
        // so a mistyped flag launched a second copy of the app, in the
        // foreground, which never exits. Two instances means two event taps
        // both capturing and both able to inject.
        //
        // Only long options are treated as a typo. macOS hands a bundled
        // application single-dash arguments of its own — -psn_0_… from
        // LaunchServices, -NSDocumentRevisionsDebugMode and friends — and
        // refusing to start because of one would be a worse bug than the one
        // this fixes.
        if let mistyped = arguments.first(where: { $0.hasPrefix("--") }) {
            return .unknown(argument: mistyped)
        }
        return nil
    }

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
            return CLIConfig.set(key, value, store: SettingsStore())
        case .policy(let bundleID, let mode):
            return CLIConfig.policy(bundleID, mode, store: SettingsStore())
        case .skipVerify(let bundleID, let state):
            return CLIConfig.skipVerify(bundleID, state, store: SettingsStore())
        case .unknown(let argument):
            return fail("unknown option '\(argument)'. Run harf --help for the full list.", code: 2)
        case .words(let action, let word, let language):
            return CLIConfig.words(action, word, language: language, lexicon: sharedLexicon())
        case .help:
            print(helpText)
            return 0
        }
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
            return fail(
                "--decide: this machine needs both an English and an Arabic keyboard layout "
                    + "enabled in System Settings > Keyboard > Input Sources",
                code: 1)
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
        let confidentScore = confident.flatMap(Double.init)
        guard let detection = detector.detect(text: text, typedLanguage: typedLanguage,
                                              aggressiveness: level,
                                              confidentScore: confidentScore)
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
        if let message = preloadModels() { return fail("--eval: \(message)", code: 1) }
        guard let detector = liveDetector() else {
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
            confidentScore: confident.flatMap(Double.init))
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

    private static func parseAggressiveness(_ raw: String?) -> Aggressiveness? {
        guard let raw else { return .balanced }
        return Aggressiveness(rawValue: raw)
    }

    /// - Parameter withLearnedWords: whether the user's own vocabulary counts.
    ///
    ///   `--decide` and `--score` say yes, because their whole job is to report
    ///   what the running app would do, and the app scores with the lexicon
    ///   attached; without it they quietly disagree with the thing they are
    ///   describing. `--eval` says no: a corpus has to score the same on every
    ///   machine, and a run whose numbers depend on what its operator has been
    ///   typing lately is not a measurement.
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

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func fail(_ message: String, code: Int32) -> Int32 {
        warn(message)
        return code
    }
}
