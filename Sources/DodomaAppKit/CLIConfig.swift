import AppKit
import DodomaCore
import Foundation

/// Reading and writing every setting from a shell.
///
/// The settings window is the discoverable surface; this is the one you can
/// script, diff, put in a dotfile, or read over ssh while the app runs on a
/// machine you are not sitting at. Both edit the same blob, so a change here
/// reaches a running app on its next evaluation without a restart.
enum CLIConfig {
    // MARK: - Status

    /// Everything the app currently believes, in one screen.
    ///
    /// Every setting, not a summary of them: someone reaching for this wants to
    /// know why an app is behaving as it is, and a count of configured apps
    /// cannot answer that.
    static func status(_ store: SettingsStore, lexicon: UserLexicon) -> Int32 {
        let s = store.settings
        let permissions = Permissions.current()

        print("Harf \(Dodoma.version)")
        print("")
        print("  running          \(isRunning ? "yes" : "no")")
        print("  accessibility    \(mark(permissions.accessibility))")
        print("  input monitoring \(mark(permissions.inputMonitoring))")
        print("")
        print(
            "  launch at login  "
                + label(LoginItem.status, owningBundleIdentifier: LoginItem.owningBundleIdentifier))
        print("  shortcuts        \(SettingsCopy.undoChord) undo, "
            + "\(SettingsCopy.pauseChord) pause, \(SettingsCopy.flipChord) flip")
        print("")
        print("  paused           \(mark(s.paused))")
        print("  sensitivity      \(s.aggressiveness.rawValue)")
        print("  confident score  \(s.confidentScore.map { pct($0) } ?? "off")")
        print("  buffer           \(s.bufferCapacity) keystrokes")
        print("  idle             \(Int(s.idleTimeout))s, then the buffer is dropped")
        print("  learning words   \(mark(s.learnVocabulary))")
        print("  debug logging    \(mark(s.debugLogging))")
        print("")

        // Printed in full rather than counted. A count answers "is anything
        // configured", which is never the question someone runs --status to
        // settle; they want to know why a particular app is behaving as it is.
        print("  default policy   \(s.defaultPolicy.rawValue)   (every app not listed below)")
        if s.appPolicies.isEmpty {
            print("  per-app modes    none")
        } else {
            print("  per-app modes    \(s.appPolicies.count)")
            for (id, policy) in s.appPolicies.sorted(by: { $0.key < $1.key }) {
                print("      \(pad(id))  \(policy.rawValue)")
            }
        }
        print("")

        if s.axVerifySkip.isEmpty {
            print("  skipping verify  none")
        } else {
            print("  skipping verify  \(s.axVerifySkip.count)   (rewrites go ahead unverified)")
            for id in s.axVerifySkip.sorted() { print("      \(id)") }
        }
        print("")

        let learned = lexicon.learned(.english).count + lexicon.learned(.arabic).count
        let manual = lexicon.manualWords(.english).count + lexicon.manualWords(.arabic).count
        let pending = lexicon.pending(.english).count + lexicon.pending(.arabic).count
        print("  words learned    \(learned)  (\(manual) added by hand, \(pending) on the way)")
        print("  vocabulary file  \(UserLexicon.defaultURL()?.path ?? "not available")")
        return 0
    }

    /// A word for the login-item state. `explanation` is a paragraph meant for
    /// a settings pane; a status line needs the state itself.
    ///
    /// - Parameter owningBundleIdentifier: the bundle this executable belongs
    ///   to, when the process itself is not running as one.
    ///
    ///   `harf` on the PATH is a symlink into `Harf.app`, and a process started
    ///   through it has no bundle identifier, so launchd will not answer for it
    ///   — while the user asking is running the bundled copy and may well have
    ///   start-at-login switched on. "Not running from a bundled app" is then
    ///   true of the command and false of everything the reader means by it.
    ///   Nothing lets one process ask launchd about another bundle, so the line
    ///   says which copy it cannot answer for and where the answer is.
    static func label(_ status: LoginItemStatus, owningBundleIdentifier: String? = nil) -> String {
        switch status {
        case .enabled: return "yes"
        case .disabled: return "no"
        case .requiresApproval: return "waiting for approval in System Settings"
        case .notFound: return "registered copy missing — switch it off and on again"
        case .unavailable:
            guard let owningBundleIdentifier else {
                return "unavailable (not running from a bundled app)"
            }
            return "not readable from here — this is the command line, not \(owningBundleIdentifier)"
                + "; see System Settings > General > Login Items"
        }
    }

    /// Bundle identifiers vary in length; a fixed column keeps the modes
    /// readable as a column rather than a ragged edge.
    private static func pad(_ text: String) -> String {
        text.padding(toLength: max(30, text.count), withPad: " ", startingAt: 0)
    }

    /// The settings as JSON, for scripting and for `diff`.
    static func dump(_ store: SettingsStore) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store.settings),
              let text = String(data: data, encoding: .utf8)
        else { return CLI.fail("--config: could not encode the settings", code: 1) }
        print(text)
        return 0
    }

    // MARK: - Writing

    static func set(_ key: String?, _ raw: String?, store: SettingsStore) -> Int32 {
        guard let key, let raw else {
            return CLI.fail("--set: expected a KEY and a VALUE", code: 2)
        }
        switch key {
        case "paused":
            guard let on = boolean(raw) else { return badBool("paused", raw) }
            store.setPaused(on)
        case "debugLogging", "debug":
            guard let on = boolean(raw) else { return badBool(key, raw) }
            store.setDebugLogging(on)
        case "sensitivity", "aggressiveness":
            guard let level = Aggressiveness(rawValue: raw) else {
                return CLI.fail(
                    "--set sensitivity: expected one of "
                        + Aggressiveness.allCases.map(\.rawValue).joined(separator: ", "),
                    code: 2)
            }
            store.setAggressiveness(level)
        case "confidentScore", "confident":
            if raw == "off" || raw == "none" {
                store.setConfidentScore(nil)
            } else if let score = percentOrFraction(raw) {
                store.setConfidentScore(score)
            } else {
                return CLI.fail(
                    "--set confident: expected a score such as 0.9 or 90, or 'off'", code: 2)
            }
        case "buffer", "bufferCapacity":
            guard let keys = Int(raw), keys > 0 else {
                return CLI.fail("--set buffer: expected a number of keystrokes", code: 2)
            }
            store.setBufferCapacity(keys)
        case "idle", "idleTimeout":
            guard let seconds = Double(raw), seconds > 0 else {
                return CLI.fail("--set idle: expected a number of seconds", code: 2)
            }
            store.setIdleTimeout(seconds)
        case "learn", "learnVocabulary":
            guard let on = boolean(raw) else { return badBool(key, raw) }
            store.setLearnVocabulary(on)
        case "defaultPolicy":
            guard let policy = AppPolicy(rawValue: raw) else { return badPolicy(raw) }
            store.setDefaultPolicy(policy)
        default:
            return CLI.fail(unknownKeyMessage(key), code: 2)
        }
        print("\(key) = \(raw)")
        return 0
    }

    /// Named so a test can hold it to the same list the switch above accepts.
    static func unknownKeyMessage(_ key: String) -> String {
        "--set: unknown key '\(key)'. Known keys: paused, sensitivity, confident, "
            + "buffer, idle, learn, debugLogging, defaultPolicy"
    }

    // MARK: - Verify-before-delete skip list

    /// The one setting the settings window could reach and the shell could
    /// not, which made it the one setting `--status` could report but nobody
    /// could act on.
    static func skipVerify(_ bundleID: String?, _ state: String?, store: SettingsStore) -> Int32 {
        guard let bundleID else {
            let skip = store.settings.axVerifySkip
            if skip.isEmpty {
                print("no apps skip the verify-before-delete read")
            } else {
                for id in skip.sorted() { print(id) }
            }
            return 0
        }
        guard let state else {
            print(store.settings.axVerifySkip.contains(bundleID) ? "on" : "off")
            return 0
        }
        guard let on = boolean(state) else {
            return CLI.fail("--skip-verify: expected on or off, not '\(state)'", code: 2)
        }
        let current = store.settings.axVerifySkip
        store.setAXVerifySkip(on ? current.union([bundleID]) : current.subtracting([bundleID]))
        print("\(bundleID) skip-verify = \(on ? "on" : "off")")
        if on {
            print("")
            print("Rewrites in this app now go ahead without checking what is in front of")
            print("the caret first. That is the check that stops a stale buffer deleting")
            print("text it did not put there.")
        }
        return 0
    }

    // MARK: - Per-app policy

    static func policy(_ bundleID: String?, _ mode: String?, store: SettingsStore) -> Int32 {
        guard let bundleID else {
            let s = store.settings
            print("all other apps    \(s.defaultPolicy.rawValue)")
            for (id, policy) in s.appPolicies.sorted(by: { $0.key < $1.key }) {
                print("\(id.padding(toLength: max(18, id.count), withPad: " ", startingAt: 0))"
                    + "  \(policy.rawValue)")
            }
            return 0
        }
        guard let mode else {
            print(store.settings.policy(for: bundleID).rawValue)
            return 0
        }
        guard let policy = AppPolicy(rawValue: mode) else { return badPolicy(mode) }
        store.setPolicy(policy, for: bundleID)
        print("\(bundleID) = \(policy.rawValue)")
        return 0
    }

    // MARK: - Vocabulary

    static func words(
        _ action: String?, _ word: String?, language raw: String?, lexicon: UserLexicon
    ) -> Int32 {
        let language: Language? = raw.flatMap {
            switch $0.lowercased() {
            case "en", "english": return .english
            case "ar", "arabic": return .arabic
            default: return nil
            }
        }
        if raw != nil && language == nil {
            return CLI.fail("--words: expected --lang en or --lang ar", code: 2)
        }

        switch action {
        case nil, "list":
            for lang in language.map({ [$0] }) ?? [.english, .arabic] {
                let learned = lexicon.learned(lang)
                let manual = lexicon.manualWords(lang)
                let pending = lexicon.pending(lang)
                print(
                    "\(lang.rawValue)  \(learned.count) known, \(manual.count) added by hand, "
                        + "\(pending.count) on the way")
                for word in manual { print("    \(word)   added") }
                for entry in learned.prefix(30) { print("    \(entry.word)   seen \(entry.count)×") }
                if learned.count > 30 { print("    … and \(learned.count - 30) more") }
                for entry in pending.prefix(15) {
                    print("    \(entry.word)   \(entry.count)/\(UserLexicon.promotionThreshold)")
                }
                if pending.count > 15 { print("    … and \(pending.count - 15) more on the way") }
                if learned.isEmpty && manual.isEmpty && pending.isEmpty {
                    print("    nothing yet")
                }
            }
            return 0
        case "clear":
            lexicon.clear()
            print("cleared every remembered word, on disk as well as in memory")
            return 0
        case "add", "remove":
            guard let word else { return CLI.fail("--words \(action!): expected a WORD", code: 2) }
            guard let language else {
                return CLI.fail("--words \(action!): expected --lang en or --lang ar", code: 2)
            }
            if action == "add" {
                lexicon.add(word, language: language)
                print("added \(word) to \(language.rawValue)")
            } else {
                lexicon.remove(word, language: language)
                print("removed \(word) from \(language.rawValue)")
            }
            lexicon.save()
            return 0
        default:
            return CLI.fail("--words: expected list, add, remove or clear", code: 2)
        }
    }

    // MARK: - Helpers

    /// Whether a copy is running, by the same test the copy itself used to
    /// decide it was allowed to.
    ///
    /// The identifier lookup this replaces answered "no" for a copy started
    /// from a shell — LaunchServices records those with no bundle identifier at
    /// all — which is the one copy `--status` most needs to report, because it
    /// is the one the single-instance alert tells the user to go and quit. Two
    /// answers to one question is worse than either answer alone.
    ///
    /// A lookup on the bootstrap name, never a registration: see
    /// `SingleInstance.isHeld`. `--status` must not become the second instance
    /// it is reporting on.
    private static var isRunning: Bool { SingleInstance.isHeld() }

    private static func mark(_ on: Bool) -> String { on ? "yes" : "no" }
    private static func pct(_ score: Double) -> String { "\(Int((score * 100).rounded()))%" }

    private static func boolean(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }

    /// Accepts 0.9 and 90 alike, because both are the obvious thing to type.
    private static func percentOrFraction(_ raw: String) -> Double? {
        guard let value = Double(raw.replacingOccurrences(of: "%", with: "")) else { return nil }
        let score = value > 1 ? value / 100 : value
        return (0.5...1.0).contains(score) ? score : nil
    }

    private static func badBool(_ key: String, _ raw: String) -> Int32 {
        CLI.fail("--set \(key): expected on or off, got '\(raw)'", code: 2)
    }

    private static func badPolicy(_ raw: String) -> Int32 {
        CLI.fail(
            "expected one of " + AppPolicy.allCases.map(\.rawValue).joined(separator: ", ")
                + ", got '\(raw)'",
            code: 2)
    }
}