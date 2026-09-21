import AppKit

/// Refuses to be the second copy of Harf on the machine.
///
/// Nothing about the app is per-instance safe. Two copies both tap the same
/// keystrokes, so they build the same buffer and their idle timers fire
/// microseconds apart; and because `EventTapController.injectedEventMarker` is
/// a compile-time constant, each one reads the other's backspaces and injected
/// text as its *own* injection and drops them. Neither buffer is ever reset by
/// the other's work, so both still believe the original text is on screen and
/// both correct it — the user types one Arabic-layout sentence and gets the
/// English one twice over. The caret verification does not save it either: the
/// two verifications race inside the same few microseconds and both pass.
///
/// This is not hypothetical housekeeping, and the way it actually happens is
/// worth naming. The Homebrew cask links the app's executable onto the PATH as
/// `harf`, so `harf` in a terminal runs the same Mach-O the bundle runs. With
/// no arguments that used to fall through to `NSApplication.run()`: a complete
/// menu-bar app, event tap included, started from a shell. `CLI.launch` now
/// stops that at the door, but a copy started before it did — or started
/// deliberately with `HARF_FORCE_APP=1` — is still a copy, and the copy the
/// user opens from `/Applications` afterwards has to notice it.
///
/// It cannot notice it by bundle identifier. A process started from the
/// executable rather than the bundle is registered by LaunchServices with no
/// bundle identifier at all — `lsappinfo` prints `bundleID=[NULL]` for it — so
/// `runningApplications(withBundleIdentifier:)` returns an empty list while
/// the copy sits there tapping every keystroke. The same blindness is why
/// `pkill -x Harf` walked past it: the process is named `harf`.
///
/// So the decision is a name registered in the login session's bootstrap
/// namespace, not a search of what is running. `CFMessagePortCreateLocal`
/// returns nil when the name is already taken, which is true regardless of how
/// the holder was launched, and the registration is owned by the process, so
/// it goes away when the process does — no lock file to go stale, no pid to
/// re-check, nothing to clean up after a crash. The LaunchServices scan stays,
/// demoted to what it is good at: naming the copy that won, so the alert can
/// tell the user which one to quit and how.
///
/// The name is not only a flag. The winner answers on it, so `harf --quit` can
/// ask the running copy to stop through `applicationWillTerminate` — which
/// saves up to twenty seconds of learned vocabulary that a signal would throw
/// away — and `harf --status` can ask whether anyone is there without becoming
/// the second copy itself.
///
/// The check is a launch precondition rather than a recoverable condition: the
/// losing copy never creates a tap, a menu bar item or a window, it says which
/// copy is already up and exits.
public enum SingleInstance {
    /// Every copy of Harf launched from a bundle answers to this. A copy
    /// launched from the bare executable answers to nothing, which is the
    /// whole problem.
    static let bundleID = "com.ali.dodoma"

    /// The file name of the executable inside the bundle. The one thing a
    /// bundled copy and a shell-started copy have in common.
    static let executableName = "Harf"

    /// The name claimed in the bootstrap namespace. Bootstrap names are
    /// per-login-session, which is the right scope: two copies in one login
    /// session fight over one keyboard, two users on the same machine do not.
    ///
    /// Built from `bundleID` rather than spelled out again: the identifier is
    /// already written in the Info.plist, the settings suite, the TCC grants
    /// and the uninstall script, and a sixth hand-typed copy is a sixth place
    /// for a rename to go half-done.
    static let portName = bundleID + ".instance"

    /// Not `NSApp.terminate` and not zero. A copy that stood down did not do
    /// the job it was asked to do, and `make install` and any launcher that
    /// checks exit codes should be able to tell that apart from a clean quit.
    /// Distinct from the 2 that `CLI.usage` and every argument error return,
    /// so a script can tell "you typed it wrong" from "one is already up".
    public static let alreadyRunningExitCode: Int32 = 3

    /// Set to 1 to start anyway. The guard refuses on *any* failure to claim
    /// the name, including failures that have nothing to do with a second copy
    /// — a squatter on the name, or a bootstrap namespace that will not take a
    /// registration at all — and a guard with no way past it turns one of
    /// those into an app that can never be started again.
    static let overrideEnvironmentKey = "HARF_IGNORE_INSTANCE"

    /// Asks the running copy to quit, the way the menu does.
    ///
    /// A number rather than a payload. That is the rule for all three of these:
    /// requests carry no bytes at all, so the port never parses what it is
    /// sent, and only the *replies* have a format. A port that parses input is
    /// a surface that has to be defended; a port that only answers is not.
    static let quitMessageID: Int32 = 1

    /// Asks for `RuntimeStatus.encoded()`. The one message with a reply, and
    /// the reason `harf --status` can report the running copy's grants instead
    /// of its own terminal's.
    static let statusMessageID: Int32 = 2

    /// Asks the running copy to re-read the settings blob. `harf --set` writes
    /// the blob and then sends this; without it the store caches at init and
    /// the app's next write copies its stale cache over the change.
    static let reloadSettingsMessageID: Int32 = 3

    /// Asks the running copy to fold a vocabulary edit into the words it is
    /// using. `harf --words add|remove|clear` writes `lexicon.json` and then
    /// sends this; without it the running copy holds the vocabulary it loaded
    /// at launch and its next save puts that copy back over the edit.
    ///
    /// A separate number from the settings reload rather than one "something
    /// changed" message, because the two are different files with different
    /// owners: a `--set` must not make the app re-read a lexicon of thousands
    /// of words, and a `--words` must not make it re-read settings it is
    /// already enforcing.
    static let reloadVocabularyMessageID: Int32 = 4

    /// How long `--status` waits for the reply after the message has been
    /// taken. Two seconds because the app's main run loop can legitimately be
    /// busy — the modal single-instance alert, or `FixEngine` holding main
    /// during an injection — and because the alternative to waiting is printing
    /// something untrue.
    private static let replyTimeout: CFTimeInterval = 2

    /// The run-loop mode the reply is waited for in.
    ///
    /// The default mode on purpose, and it is load-bearing for the tests rather
    /// than merely conventional: `claimPort` adds the port's source to
    /// `.commonModes`, the default mode is one of those, so a single process can
    /// serve its own status request. That makes the round trip — callback,
    /// encoding, reply, decode — testable without arranging for a second copy
    /// of Harf to exist.
    private static let replyMode = CFRunLoopMode.defaultMode.rawValue

    /// Holds the claim open. A `CFMessagePort` unregisters its name when it is
    /// deallocated, so dropping this reference would hand the name back while
    /// the app is still running and let the next copy in.
    private static var claimedPort: CFMessagePort?

    // MARK: - Recognising another copy

    /// How a running process was recognised as a copy of Harf. Not a detail:
    /// it decides what the user is told to do about it, and the two answers
    /// have nothing in common. A bundled copy has a menu bar icon to quit; a
    /// copy started from a shell may have one too, but the user has no way to
    /// tell which icon is which, so it needs a command instead.
    enum Match: Equatable {
        /// Registered with LaunchServices under `com.ali.dodoma`.
        case bundleIdentifier
        /// No identifier, but running the app's own executable.
        case executablePath
    }

    /// One running process, in the only terms this file needs.
    ///
    /// Every field is optional because `NSRunningApplication` promises none of
    /// them, and the process this exists to catch is missing two of the three.
    /// `path` is the bundle location, carried only so the alert can name
    /// *which* copy won — the single question the user asks when three of them
    /// are installed.
    struct Instance: Equatable {
        let pid: pid_t
        let bundleID: String?
        /// The executable, symlinks already resolved by whoever built this.
        let executablePath: String?
        let path: String?
    }

    /// A copy that is not this process, and the reason it counts as one.
    struct Conflict: Equatable {
        let instance: Instance
        let match: Match
    }

    /// This process's own executable with symlinks resolved, which is what a
    /// running copy's executable is compared against. Nil only when Foundation
    /// cannot say where we are running from.
    static var ownExecutablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    /// Whether a process is a copy of Harf, and how it was recognised. Nil for
    /// everything else on the machine.
    ///
    /// The identifier is tried first so a bundled copy is reported as bundled
    /// even though its executable would also match; the alert for the two says
    /// different things.
    ///
    /// - Parameter ownExecutable: this process's own resolved executable.
    ///
    ///   With it, the executable test is equality against a full path, and the
    ///   only processes that match are ones running the very same binary. The
    ///   basename test this replaces matched anything on the machine called
    ///   `harf` — a Go tool, an unrelated script — and then told the user to
    ///   quit it. It could never cause a wrongful *refusal*, because the port
    ///   is what decides and this only describes, but an alert that names an
    ///   innocent process and a command to stop it is worse than an alert that
    ///   names nothing: `alertText(for: nil)` already handles the copy that
    ///   cannot be named, and it handles it honestly.
    ///
    ///   The price is that a *different* build of Harf — `/Applications` versus
    ///   one in a build directory — is no longer described, only refused. That
    ///   is the right way round: the refusal is the safety property and it does
    ///   not depend on this at all.
    ///
    ///   Nil falls back to the case-insensitive basename, because the name
    ///   reaches this in two spellings: inside the bundle it is `Harf`, and on
    ///   the PATH the cask links it as `harf`.
    static func match(_ instance: Instance, ownExecutable: String? = ownExecutablePath) -> Match? {
        if instance.bundleID == bundleID { return .bundleIdentifier }
        guard let executablePath = instance.executablePath else { return nil }

        if let ownExecutable {
            return executablePath == ownExecutable ? .executablePath : nil
        }
        let isSameName = URL(fileURLWithPath: executablePath).lastPathComponent
            .compare(executableName, options: .caseInsensitive) == .orderedSame
        return isSameName ? .executablePath : nil
    }

    /// The other copy this process must stand down for, or nil when it is
    /// alone. Pure, so the truth table is a test rather than a second launch.
    ///
    /// Position, not pid order, decides which of several is named: the list
    /// arrives from the system and re-sorting it would report a copy other than
    /// the one the system considers first. `own` missing from the list is not
    /// an error case — the scan happens before this process is necessarily
    /// registered — and anyone else in it is still a second copy, so it is
    /// still a conflict.
    static func conflict(
        among instances: [Instance], own pid: pid_t, ownExecutable: String? = ownExecutablePath
    ) -> Conflict? {
        for instance in instances where instance.pid != pid {
            if let match = match(instance, ownExecutable: ownExecutable) {
                return Conflict(instance: instance, match: match)
            }
        }
        return nil
    }

    /// What the alert says under its heading. Pure, because the difference
    /// between the two cases is the entire value of the alert and a difference
    /// only reachable by launching two copies is a difference nobody checks.
    ///
    /// Nil is a real case rather than a defensive one: the bootstrap name is
    /// the decision and the scan is only a description, so the name can be
    /// taken by a copy the scan does not report — a process mid-launch, one
    /// LaunchServices has not caught up with, or a build at a path this one
    /// does not share. The alert still has to be worth reading, so it falls
    /// back to the command that works either way.
    ///
    /// `harf --quit`, not `pkill`: the running copy has up to twenty seconds of
    /// learned vocabulary that only `applicationWillTerminate` writes out, and
    /// the command is the same one whichever way that copy was started.
    static func alertText(for conflict: Conflict?) -> String {
        let consequence =
            "Two copies would correct the same text twice, so this one will quit. "

        guard let conflict else {
            return consequence
                + "The copy that is already running does not appear in the list of "
                + "applications, so it cannot be named here. Quit it from its menu bar "
                + "icon, or run `harf --quit` to stop it."
        }

        switch conflict.match {
        case .bundleIdentifier:
            return (conflict.instance.path.map { "The copy at \($0) is already running. " }
                    ?? "Another copy is already running. ")
                + consequence
                + "Quit the running copy from its menu bar icon first if you meant to "
                + "use this one."
        case .executablePath:
            return "A copy started from a terminal (process \(conflict.instance.pid)) is "
                + "already running. "
                + consequence
                + "It was started from the command line rather than from "
                + "/Applications/Harf.app, so nothing identifies it as Harf: stop it with "
                + "`harf --quit`, or quit it from its menu bar icon."
        }
    }

    /// What the alert says when the name could not be claimed and nobody holds
    /// it — a squatter under the same name, or a bootstrap namespace that
    /// refused the registration. Naming a copy of Harf here would be a lie, and
    /// telling the user to quit one would send them after a process that does
    /// not exist. The way out is the only thing worth saying.
    static let unclaimableAlertText =
        "Harf could not register the name it uses to notice a second copy of itself, and "
        + "nothing appears to be answering on that name. This is not another copy of Harf. "
        + "To start anyway, run Harf with \(overrideEnvironmentKey)=1 in its environment; the "
        + "single-copy check will be skipped and a warning written to the log."

    /// The system's answer, in the shape `conflict` takes. Kept apart from the
    /// decision because it cannot be driven from a test: it reports whatever
    /// happens to be running on the machine the tests run on.
    ///
    /// `NSWorkspace.shared.runningApplications` rather than the identifier
    /// lookup `CLIConfig.isRunning` used to use, because the identifier lookup
    /// is exactly what misses a copy started from a shell. The full list does
    /// carry that process — `lsappinfo` lists it too, with a null bundle id —
    /// so the executable is there to be matched on.
    ///
    /// Symlinks are resolved because the PATH entry the cask installs is one:
    /// `/opt/homebrew/bin/harf` points into the bundle, and resolved it ends
    /// in the same `Harf` a bundled copy runs.
    static func running() -> [Instance] {
        NSWorkspace.shared.runningApplications.map { application in
            Instance(
                pid: application.processIdentifier,
                bundleID: application.bundleIdentifier,
                executablePath: application.executableURL?.resolvingSymlinksInPath().path,
                path: application.bundleURL?.path)
        }
    }

    // MARK: - The claim

    /// Handles a message on the claimed name.
    ///
    /// A C function pointer, so it captures nothing; everything the three arms
    /// need is static. `RuntimeStatus` exists because of this signature, not
    /// the other way round.
    ///
    /// Nothing here blocks, and in particular nothing here is a
    /// `DispatchQueue.main.sync`: the callback runs on whichever run loop the
    /// source was added to, which is the main one, so a synchronous hop to main
    /// would be a deadlock against itself. The two arms with main-thread work —
    /// `NSApp.terminate`, and a settings reload that fires `onChange` into the
    /// pipeline and the settings window — hop with `async` instead. The status
    /// arm needs no hop at all: the lock box is thread-safe and the reply has to
    /// be returned from this call.
    ///
    /// The reply is `passRetained`, which is the contract: CoreFoundation
    /// releases the returned data once it has been sent.
    ///
    /// An unrecognised message ID does nothing. A newer build of `harf` on the
    /// PATH talking to an older copy in /Applications is an ordinary state of
    /// this machine, not an error.
    private static let handleMessage: CFMessagePortCallBack = { _, messageID, _, _ in
        switch messageID {
        case quitMessageID:
            Log.app.info("quit requested over \(portName, privacy: .public)")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        case statusMessageID:
            return Unmanaged.passRetained(RuntimeStatus.encoded() as CFData)
        case reloadSettingsMessageID:
            Log.app.info("settings reload requested over \(portName, privacy: .public)")
            DispatchQueue.main.async { RuntimeStatus.handleReloadRequest() }
            return nil
        case reloadVocabularyMessageID:
            Log.app.info("vocabulary reload requested over \(portName, privacy: .public)")
            // No hop, because this arm has no main-thread work: the handler
            // hands the merge to the lexicon's own queue and returns. Reading
            // the file here, on the run loop the tap and the panels share,
            // would be the one thing this arm must not do.
            RuntimeStatus.handleVocabularyRequest()
            return nil
        default:
            return nil
        }
    }

    /// Claims the bootstrap name and starts answering on it, or reports that
    /// someone else holds it.
    ///
    /// - Parameter name: the name to claim. Defaulted rather than hardcoded so
    ///   a test can exercise the mechanism on a name of its own; claiming the
    ///   real one from a test would take it from the developer's running Harf,
    ///   or fail because that copy holds it, depending on the machine.
    ///
    /// Kept apart from `enforceOnlyCopy` so the alert, the logging and the
    /// environment override are not entangled with the one call that has a
    /// side effect on the whole login session.
    ///
    /// The run-loop source is what makes the name answer rather than merely
    /// exist. Without it the port is registered and every message sent to it
    /// times out, which is exactly what `harf --quit` would then do.
    @discardableResult
    static func claimPort(name: String = portName) -> Bool {
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, handleMessage, nil, nil)
        else { return false }

        if let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        claimedPort = port
        return true
    }

    /// Whether anybody is answering on the name.
    ///
    /// A lookup, never a registration: `CFMessagePortCreateRemote` fails when
    /// the name is free and connects when it is taken, so asking this question
    /// cannot make the asker into the copy it was asking about. That matters —
    /// `harf --status` calls it, and `--status` must never become the second
    /// instance it is reporting on.
    static func isHeld(name: String = portName) -> Bool {
        CFMessagePortCreateRemote(nil, name as CFString) != nil
    }

    /// Why a claim failed. `CFMessagePortCreateLocal` returns the same nil for
    /// both, and the two want opposite things said to the user, so the name is
    /// looked up again to tell them apart. The window between the two calls is
    /// harmless: a holder that appears or disappears in it only changes which
    /// of two messages is logged, never whether this copy stands down.
    enum ClaimFailure: Equatable {
        /// Somebody is answering on the name: another Harf.
        case nameTaken
        /// Nobody is answering, so the registration itself failed.
        case unavailable
    }

    /// Whether the copy that is not running should carry on regardless. Reads
    /// the environment rather than a setting: the settings live in the suite
    /// that a losing copy must not touch, and this decision is made before
    /// anything is loaded.
    static func isOverridden(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[overrideEnvironmentKey] == "1"
    }

    /// The whole guard, for the entry point to call before it builds anything
    /// at all. Returns only when this copy is the one that should carry on;
    /// otherwise it says which copy is already up and exits.
    ///
    /// Called from `main.swift` before `AppDelegate()` exists, which is earlier
    /// than it looks like it needs to be. `AppDelegate` holds `SettingsStore
    /// .shared`, and that store's `init` writes the merged settings straight
    /// back to the `com.ali.dodoma` suite — the *shared* suite, the one the
    /// copy that is already running reads. A losing copy from an older build
    /// decodes only the keys it knows, re-seeds the rest and persists the
    /// truncated blob before it ever gets as far as standing down, and the
    /// running copy never re-reads, so the loss only shows up at the next
    /// launch. Nothing that persists may run before this.
    ///
    /// The alert is modal, and stays modal. It is the one thing a copy started
    /// by mistake can do that a log line cannot, and the cost — a login-item
    /// launch against a copy that is somehow already up leaves a dialog sitting
    /// on the screen until a human finds it — is a dialog on the screen at
    /// login, which is where a person is. The alternative, exiting silently,
    /// is an app that "did not start" with no reason given anywhere the user
    /// looks.
    ///
    /// The app is an accessory, so it has no place in the Dock and no way to be
    /// brought forward by clicking one; without the explicit activation the
    /// alert would open behind whatever the user is typing into and the app
    /// would look like it had simply failed to start.
    public static func enforceOnlyCopy() {
        if isOverridden() {
            Log.app.warning(
                """
                \(overrideEnvironmentKey, privacy: .public)=1: starting without claiming \
                \(portName, privacy: .public). If another copy is running, both will correct \
                the same text.
                """
            )
            return
        }

        if claimPort() { return }

        switch isHeld() ? ClaimFailure.nameTaken : .unavailable {
        case .nameTaken:
            let other = conflict(
                among: running(), own: ProcessInfo.processInfo.processIdentifier)
            Log.app.error(
                """
                another Harf already holds \(portName, privacy: .public); quitting \
                (other pid \(other.map { String($0.instance.pid) } ?? "unknown", privacy: .public), \
                \(other?.instance.executablePath ?? other?.instance.path ?? "unknown path", privacy: .public), \
                matched by \(String(describing: other?.match), privacy: .public))
                """
            )
            present(alertText(for: other))
        case .unavailable:
            Log.app.error(
                """
                \(portName, privacy: .public) could not be registered and nothing answers on \
                it, so this is not a second copy; quitting. Set \
                \(overrideEnvironmentKey, privacy: .public)=1 to start anyway.
                """
            )
            present(unclaimableAlertText)
        }
        exit(alreadyRunningExitCode)
    }

    /// `NSApplication` only as far as an alert needs it. `NSApp.run()` is never
    /// reached: this copy has already lost, and everything past the alert is
    /// `exit`.
    private static func present(_ text: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate()

        let alert = NSAlert()
        alert.messageText = "Harf is already running."
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Asking the running copy to quit

    /// What happened when the running copy was asked to stop.
    enum QuitOutcome: Equatable {
        /// The message reached the copy holding the name. It quits through
        /// `applicationWillTerminate`, so the lexicon is saved.
        case messaged
        /// Nobody was answering on the name, but the scan found a copy anyway —
        /// a build too old to have a port. Asked to quit the ordinary way.
        case terminated(pid_t)
        /// Nothing to quit.
        case notRunning
        case failed(String)
    }

    /// Two seconds. The receiving copy does the work on its main run loop after
    /// this returns, so the only thing being waited on is the message being
    /// handed over — long enough for a machine under load, short enough that a
    /// `make install` does not appear to hang.
    private static let sendTimeout: CFTimeInterval = 2

    /// How long a copy that took the quit message is given to let go of the
    /// name before the request is reported as failed.
    ///
    /// "Took" is weaker than it sounds: `CFMessagePortSendRequest` succeeds
    /// when the message is delivered, not when it is acted on. A build whose
    /// port had no handler at all took the message just as happily — the
    /// 2026-09-08 build did exactly that under `make install`: `--quit` said
    /// the copy was quitting, the `pkill` fallback therefore never ran, and
    /// the old process kept tapping the keyboard underneath the freshly
    /// installed bundle. Waiting for the name to disappear is the only thing
    /// that tells the two apart. Three seconds covers `applicationWillTerminate`
    /// writing the lexicon on a loaded machine.
    private static let quitGrace: CFTimeInterval = 3

    /// True once nobody holds `name`, or false when it is still held after
    /// `grace`. Polls, because there is no notification for a bootstrap name
    /// going away and the process that registered it may be mid-exit.
    static func waitUntilReleased(
        name: String, within grace: CFTimeInterval, poll: CFTimeInterval = 0.1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(grace)
        while isHeld(name: name) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
        return true
    }

    /// Asks the running copy to quit, by the route that lets it save first.
    ///
    /// `pkill` is what the app used to tell people to use, and what `make
    /// install` did. A signal skips `applicationWillTerminate`, and with it the
    /// only write of the vocabulary learned since the last flush — up to twenty
    /// seconds of it. The port is already there and already proves the copy is
    /// alive, so it carries the request.
    ///
    /// The fallback exists for the copy that has the app but not the port: a
    /// build from before this change. It is found by the same scan the alert
    /// uses, and `NSRunningApplication.terminate` is still a polite quit.
    static func requestQuit(name: String = portName) -> QuitOutcome {
        if let remote = CFMessagePortCreateRemote(nil, name as CFString) {
            let status = CFMessagePortSendRequest(
                remote, quitMessageID, nil, sendTimeout, 0, nil, nil)
            guard status == Int32(kCFMessagePortSuccess) else {
                return .failed("the running copy did not take the request (error \(status))")
            }
            guard waitUntilReleased(name: name, within: quitGrace) else {
                return .failed(
                    "the running copy took the request but is still running after \(Int(quitGrace)) seconds"
                )
            }
            return .messaged
        }

        guard
            let other = conflict(among: running(), own: ProcessInfo.processInfo.processIdentifier),
            let application = NSRunningApplication(processIdentifier: other.instance.pid)
        else { return .notRunning }

        guard application.terminate() else {
            return .failed("process \(other.instance.pid) refused to quit")
        }
        return .terminated(other.instance.pid)
    }

    // MARK: - Asking the running copy about itself

    /// What the copy holding the name says about itself, or nil when there is
    /// nothing trustworthy to say.
    ///
    /// Nil covers three different states on purpose — nobody holds the name,
    /// the holder did not answer inside `replyTimeout`, and the reply could not
    /// be decoded — because `--status` renders all three the same way: as
    /// *unknown*. The one thing it must never do is render them as *no*. A main
    /// run loop stuck behind a modal alert is not a revoked Accessibility
    /// grant, and printing `accessibility no` for it sends the reader to System
    /// Settings to fix something that is not broken.
    ///
    /// A lookup, never a registration: like `isHeld`, this cannot turn the
    /// asker into the second copy it is asking about.
    static func requestStatus(name: String = portName) -> RuntimeSnapshot? {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return nil }

        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote, statusMessageID, nil, sendTimeout, replyTimeout, replyMode, &reply)
        guard status == Int32(kCFMessagePortSuccess) else { return nil }
        return RuntimeStatus.decode(reply?.takeRetainedValue() as Data?)
    }

    /// Tells the running copy that the settings blob has changed under it.
    ///
    /// Fire-and-forget — receive timeout 0, no reply mode — because there is
    /// nothing to wait for: the blob is the shared state and this is only the
    /// nudge to go and read it. Waiting for the app to finish reloading would
    /// put a `harf --set` behind whatever the main run loop is doing, and the
    /// answer would not change what the command prints.
    ///
    /// False means the message was not taken, which is worth saying out loud:
    /// the setting is saved, but the copy that is running is still enforcing the
    /// old one until it restarts.
    @discardableResult
    static func requestReload(name: String = portName) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        return CFMessagePortSendRequest(
            remote, reloadSettingsMessageID, nil, sendTimeout, 0, nil, nil)
            == Int32(kCFMessagePortSuccess)
    }

    /// Tells the running copy that `lexicon.json` has changed under it.
    ///
    /// Fire-and-forget for the same reason as `requestReload`: the file is the
    /// shared state and this is only the nudge to go and read it. False means
    /// the message was not taken — the edit is on disk either way, and the
    /// running copy's own save merges it rather than overwriting it, but it is
    /// not using the new word yet.
    @discardableResult
    static func requestVocabularyReload(name: String = portName) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        return CFMessagePortSendRequest(
            remote, reloadVocabularyMessageID, nil, sendTimeout, 0, nil, nil)
            == Int32(kCFMessagePortSuccess)
    }

    /// What `--quit` prints. Pure, so the four answers are a test rather than
    /// four ways of arranging for a second copy to exist.
    static func quitMessage(for outcome: QuitOutcome) -> String {
        switch outcome {
        case .messaged:
            return "Harf is quitting."
        case .terminated(let pid):
            return "Harf (process \(pid)) was asked to quit. It is an older build with no "
                + "way to be messaged, so words learned in the last few seconds may be lost."
        case .notRunning:
            return "Harf is not running."
        case .failed(let reason):
            return "Harf could not be asked to quit: \(reason)."
        }
    }

    /// Nothing running is not a failure: `--quit` is asked for the state where
    /// Harf is not running, and `make install` and `uninstall.sh` both run it
    /// on machines where it is already true.
    static func quitExitCode(for outcome: QuitOutcome) -> Int32 {
        if case .failed = outcome { return 1 }
        return 0
    }
}
