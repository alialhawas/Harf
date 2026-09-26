import AppKit
import DodomaCore
import Foundation

/// Reading and writing every setting from a shell.
///
/// The settings window is the discoverable surface; this is the one you can
/// script, diff, put in a dotfile, or read over ssh while the app runs on a
/// machine you are not sitting at.
///
/// Both surfaces edit the same blob, but the blob alone was never enough in
/// either direction. A write from here does not reach a running copy by itself —
/// `SettingsStore` caches at init — so `CLI.writing` asks that copy to re-read
/// it; and a *read* from here cannot describe a running copy at all, because
/// the permissions, the login-item registration and the applied settings all
/// belong to that process. `--status` therefore asks it, and says plainly when
/// it cannot be asked.
enum CLIConfig {
    // MARK: - Status

    /// Everything the running copy currently believes, in one screen; and when
    /// there is no running copy, everything that is saved, marked as such.
    ///
    /// A shell around `statusText`, which is where all the decisions live. The
    /// two questions asked of the world are kept here: whether anybody holds the
    /// single-instance name, and — only then — what that copy says about itself.
    /// Only then, because `requestStatus` waits up to two seconds for a reply
    /// and there is nothing to wait for when nobody is there.
    ///
    /// Both questions go through the bootstrap name, never a registration (see
    /// `SingleInstance.isHeld`), so `--status` cannot become the second instance
    /// it is reporting on. The name also catches the copy an identifier lookup
    /// misses — one started from a shell, which LaunchServices records with no
    /// bundle identifier at all — and that is the copy `--status` most needs to
    /// report, because it is the one the single-instance alert tells the user to
    /// go and quit.
    ///
    /// `Permissions.current()` is deliberately not called anywhere in this file.
    /// It answers for *this* process, and a command run from a terminal that has
    /// been granted Accessibility printed `accessibility yes` while the app was
    /// logging `accessibility=false`.
    static func status(_ store: SettingsStore, lexicon: UserLexicon) -> Int32 {
        let running = SingleInstance.isHeld()
        let snapshot = running ? SingleInstance.requestStatus() : nil

        print(
            statusText(
                version: Dodoma.version,
                running: running,
                snapshot: snapshot,
                stored: store.settings,
                localLoginItem: LoginItem.status,
                owningBundleIdentifier: LoginItem.owningBundleIdentifier,
                vocabulary: Vocabulary(lexicon)))
        return 0
    }

    /// The vocabulary counts, lifted out of `UserLexicon` so the screen can be
    /// rendered from a value instead of from a file on the developer's machine.
    struct Vocabulary: Equatable {
        var learned: Int
        var manual: Int
        var pending: Int
        var file: String

        init(learned: Int, manual: Int, pending: Int, file: String) {
            self.learned = learned
            self.manual = manual
            self.pending = pending
            self.file = file
        }

        init(_ lexicon: UserLexicon, file: String? = UserLexicon.defaultURL()?.path) {
            self.init(
                learned: lexicon.learned(.english).count + lexicon.learned(.arabic).count,
                manual: lexicon.manualWords(.english).count + lexicon.manualWords(.arabic).count,
                pending: lexicon.pending(.english).count + lexicon.pending(.arabic).count,
                file: file ?? "not available")
        }
    }

    /// The whole screen, as one string, from values alone.
    ///
    /// Pure because none of what it decides can be reproduced from a test
    /// otherwise: a running copy with revoked grants, a copy whose run loop is
    /// wedged, a saved blob that disagrees with what the app applied, two builds
    /// installed at once. Each of those used to be rendered wrongly and each of
    /// them now has a test instead of a hope.
    ///
    /// - Parameters:
    ///   - running: whether anybody holds the single-instance name. A lookup,
    ///     not the snapshot: the name can be held by a copy that does not
    ///     answer, and "running, and silent" is a different sentence from "not
    ///     running".
    ///   - snapshot: what that copy said about itself, or nil — which covers not
    ///     running, not answering, and answering with something this build
    ///     cannot read. All three render as *unknown*; none of them renders as
    ///     *no*.
    ///   - stored: the saved blob, used for the settings lines when nobody
    ///     answered, and compared against the applied settings when somebody
    ///     did.
    ///   - localLoginItem: what launchd says about *this* process, which is only
    ///     worth printing when the app could not be asked.
    static func statusText(
        version: String,
        running: Bool,
        snapshot: RuntimeSnapshot?,
        stored: AppSettings,
        localLoginItem: LoginItemStatus,
        owningBundleIdentifier: String?,
        vocabulary: Vocabulary
    ) -> String {
        // Every settings line answers from the app when the app answered. The
        // blob is the fallback, not the source: it is what will be in force
        // after the next launch, which is not the question being asked.
        let effective = snapshot?.settings ?? stored
        var lines: [String] = ["Harf \(version)", ""]

        for banner in banners(
            version: version, running: running, snapshot: snapshot, stored: stored)
        {
            lines.append(contentsOf: [banner, ""])
        }

        lines.append("  running          " + runningLine(running: running, snapshot: snapshot))
        lines.append("  accessibility    " + answer(snapshot?.permissions.accessibility))
        lines.append("  input monitoring " + answer(snapshot?.permissions.inputMonitoring))
        lines.append(
            "  state            "
                + (snapshot.map {
                    MenuBarController.statusText(
                        for: $0.permissions, capturing: $0.capturing, paused: $0.paused,
                        secureInput: $0.secureInput, degraded: $0.degraded)
                } ?? unknown))
        lines.append("")

        lines.append(
            "  launch at login  "
                + (snapshot.map { label($0.loginItem) }
                    ?? label(localLoginItem, owningBundleIdentifier: owningBundleIdentifier)))
        lines.append(
            "  shortcuts        \(SettingsCopy.undoChord) undo, "
                + "\(SettingsCopy.pauseChord) pause, \(SettingsCopy.flipChord) flip")
        lines.append("")

        lines.append("  paused           \(mark(effective.paused))")
        lines.append("  sensitivity      \(effective.aggressiveness.rawValue)")
        lines.append("  confident score  \(effective.confidentScore.map { pct($0) } ?? "off")")
        lines.append("  buffer           \(effective.bufferCapacity) keystrokes")
        lines.append("  idle             \(Int(effective.idleTimeout))s, then the buffer is dropped")
        lines.append("  learning words   \(mark(effective.learnVocabulary))")
        lines.append("  debug logging    \(mark(effective.debugLogging))")
        lines.append("")

        // Printed in full rather than counted. A count answers "is anything
        // configured", which is never the question someone runs --status to
        // settle; they want to know why a particular app is behaving as it is.
        lines.append(
            "  default policy   \(effective.defaultPolicy.rawValue)   (every app not listed below)")
        if effective.appPolicies.isEmpty {
            lines.append("  per-app modes    none")
        } else {
            lines.append("  per-app modes    \(effective.appPolicies.count)")
            for (id, policy) in effective.appPolicies.sorted(by: { $0.key < $1.key }) {
                lines.append("      \(pad(id))  \(policy.rawValue)")
            }
        }
        lines.append("")

        if effective.axVerifySkip.isEmpty {
            lines.append("  skipping verify  none")
        } else {
            lines.append(
                "  skipping verify  \(effective.axVerifySkip.count)   "
                    + "(rewrites go ahead unverified)")
            for id in effective.axVerifySkip.sorted() { lines.append("      \(id)") }
        }
        lines.append("")

        lines.append(
            "  words learned    \(vocabulary.learned)  (\(vocabulary.manual) added by hand, "
                + "\(vocabulary.pending) on the way)")
        lines.append("  vocabulary file  \(vocabulary.file)")
        return lines.joined(separator: "\n")
    }

    /// The paragraphs above the fields: each one changes how everything below it
    /// is to be read, which is why they are not footnotes.
    private static func banners(
        version: String, running: Bool, snapshot: RuntimeSnapshot?, stored: AppSettings
    ) -> [String] {
        var banners: [String] = []

        switch (running, snapshot) {
        case (true, nil):
            banners.append(
                "  Something is answering on \(SingleInstance.portName) but it did not answer\n"
                    + "  this request, so the permissions and the state below are unknown and the\n"
                    + "  settings are the saved ones rather than what that copy is enforcing.")
        case (false, _):
            banners.append(
                "  Nothing is running, so the settings below are the saved ones — what the\n"
                    + "  next launch will use — and nothing here describes a live copy.")
        case (true, _):
            break
        }

        if let snapshot, snapshot.appVersion != version {
            banners.append(
                "  The running copy is \(snapshot.appVersion) and this command is \(version), "
                    + "so the two\n  came from a different build. Everything below describes the "
                    + "copy that is running.")
        }

        if let snapshot, snapshot.settings != stored {
            banners.append(
                "  The saved settings differ from the ones the running copy is enforcing. The\n"
                    + "  lines below are the running copy's; something wrote the blob without it\n"
                    + "  being taken, and a restart would change behaviour.")
        }
        return banners
    }

    /// `yes (process N)` when the copy answered, because a pid is what makes the
    /// claim checkable and it is the number the single-instance alert talks
    /// about. A bare `yes` when the name is held by something that did not say
    /// which process it is.
    private static func runningLine(running: Bool, snapshot: RuntimeSnapshot?) -> String {
        guard running else { return "no" }
        guard let snapshot else { return "yes" }
        return "yes (process \(snapshot.pid))"
    }

    /// A permission nobody answered for. Never "no": the main run loop can be
    /// blocked by a modal alert or by an injection holding the main thread, and
    /// neither of those is a revoked grant.
    private static let unknown = "unknown"

    private static func answer(_ value: Bool?) -> String {
        value.map(mark) ?? unknown
    }

    /// Printed after a `--words` edit that the running copy took.
    ///
    /// `--words` writes `lexicon.json` and the running copy holds its own copy
    /// of the vocabulary in memory, so the file alone was never the whole
    /// story: the edit used to be undone by that copy's next save, within about
    /// twenty seconds. The copy is now told, over the single-instance port, and
    /// merges the change into the words it is using — so the only honest thing
    /// to say is the short one.
    static let vocabularyTakenNote = "Harf is running and has taken the change."

    /// And when the message was not taken. The edit is still on disk, and the
    /// running copy's own save merges the file rather than overwriting it, so
    /// nothing is lost — but that copy is not using the new word yet, and a
    /// user who adds a word and watches nothing change deserves the reason.
    static let vocabularyNotTakenWarning =
        "Harf is running but did not take the change. It is saved, and the running copy will "
        + "pick it up the next time it writes the file or at its next launch."

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
            } else if let score = confidentScore(raw) {
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
            tellTheRunningCopy()
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
            tellTheRunningCopy()
            return 0
        default:
            return CLI.fail("--words: expected list, add, remove or clear", code: 2)
        }
    }

    /// The other half of a vocabulary edit.
    ///
    /// `--words` is not wrapped in `CLI.writing` because it changes a different
    /// file with a different message, but it is the same idea: the shared state
    /// is written first and the copy that is running is then asked to take it.
    /// The file on its own never reached that copy — it had read the whole
    /// vocabulary at launch and would write it back over this within about
    /// twenty seconds.
    ///
    /// A refusal is a warning and not a failure, as it is for `--set`. The edit
    /// is on disk and the running copy's own save merges rather than clobbers
    /// it now, so the exit code stays 0 and a script that adds a word does not
    /// start failing whenever the app's run loop is busy.
    private static func tellTheRunningCopy() {
        guard SingleInstance.isHeld() else { return }
        if SingleInstance.requestVocabularyReload() {
            print(vocabularyTakenNote)
        } else {
            CLI.warn(vocabularyNotTakenWarning)
        }
    }

    // MARK: - Helpers

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
    /// How a confident-score argument reads, wherever one is typed: `--set
    /// confident`, `--decide --confident` and `--eval --confident` all come
    /// through here.
    ///
    /// Two scales, because both get typed for the same threshold. `--status`
    /// and the settings window show it as a percentage, so `90` is what
    /// somebody reading either of those reaches for; the JSON `--config` prints
    /// holds `0.9`, so that is what somebody scripting against it reaches for.
    ///
    /// The result is clamped into the band the store keeps rather than handed
    /// back raw. `--decide` and `--eval` answer "what would the app do at this
    /// setting", and a number the store would not hold is not a setting the app
    /// can ever be at — so reporting on it would describe a configuration that
    /// cannot exist. `--set` clamps again on the way in, which is harmless.
    ///
    /// Returns nil for anything that is not a score at all, so each caller can
    /// name its own flag in the failure.
    static func confidentScore(_ raw: String) -> Double? {
        guard let value = Double(raw.replacingOccurrences(of: "%", with: "")) else { return nil }
        let score = value > 1 ? value / 100 : value
        guard (0.5...1.0).contains(score) else { return nil }
        return SettingsStore.clampConfidentScore(score)
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