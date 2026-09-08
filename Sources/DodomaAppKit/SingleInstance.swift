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

    /// The only message the port understands. A number rather than a payload:
    /// nothing else is ever asked of the running copy, and a port that parses
    /// what it is sent is a surface that has to be defended.
    static let quitMessageID: Int32 = 1

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

    /// Handles a message on the claimed name. The only one it accepts asks the
    /// app to quit, and it quits the way the menu does — `NSApp.terminate`, so
    /// `applicationWillTerminate` runs and what was learned this session is
    /// written out before the process goes.
    ///
    /// A C function pointer, so it captures nothing; everything it needs is
    /// static. It is called on whichever run loop the source was added to,
    /// which is the main one, but the hop is kept anyway: `CFMessagePort`
    /// promises the run loop, not the thread, and `terminate` is main-thread
    /// only.
    private static let handleMessage: CFMessagePortCallBack = { _, messageID, _, _ in
        guard messageID == quitMessageID else { return nil }
        Log.app.info("quit requested over \(portName, privacy: .public)")
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return nil
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
