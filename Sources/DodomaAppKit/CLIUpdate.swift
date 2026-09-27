import DodomaCore
import Foundation

/// `harf --update`: the one command in Harf that opens a socket, and only
/// because somebody typed it.
///
/// Split the same way `--status` is — a pure plan, then a runner — because what
/// matters is what each outcome tells the user to do, and neither a GitHub
/// outage nor somebody else's Homebrew install can be reproduced from a test.
///
/// # Why this does not update Harf itself
///
/// It would be a short step from "print the release URL" to "fetch the DMG and
/// swap the bundle", and that step is deliberately not taken. Two reasons, both
/// of which would still be true after the code was written:
///
/// 1. **There is nothing trustworthy to verify a download against.** The build
///    is signed with a self-signed certificate and is not notarised, so
///    Gatekeeper cannot vouch for it and neither can a downloader: the only
///    checksum for `Harf-x.y.z.dmg` is published in the same GitHub release as
///    the file itself, so anything able to serve a bad DMG can serve a matching
///    sha256 beside it. That is not a check, it is a formality. Homebrew's
///    `sha256` is different in kind — it sits in `Casks/harf.rb`, in a tap the
///    user trusted at install time, and it is compared against what the download
///    actually contained. Handing the verification to the tool that already does
///    it properly is the whole point of preferring `brew upgrade` here.
///
/// 2. **Replacing `/Applications/Harf.app` under a running copy is the exact
///    thing the cask forbids.** That copy holds a live `CGEventTap`. Swapping
///    the bundle beneath it leaves it tapping every keystroke on the machine
///    with no app behind it, and loses whatever it has learned since its last
///    flush. The cask's `uninstall quit: "com.ali.dodoma"` stanza exists to stop
///    precisely that, and it is enforced by Homebrew — not by a self-updater
///    that would have to reimplement it and get the ordering right every time.
enum CLIUpdate {
    /// What `--update` will print, what it will exit with, and the one command
    /// it may run. `command` is nil for every outcome but "a Homebrew install
    /// has an upgrade to install" — see the note above.
    struct Plan: Equatable {
        var message: String
        var exitCode: Int32
        var command: [String]?
    }

    /// - Parameter brewExecutable: where `brew` was found, or nil when it could
    ///   not be found again. Passed in rather than looked up so the plan stays
    ///   pure and so a Homebrew install with no reachable `brew` is a test.
    static func plan(
        for result: UpdateCheck.Result,
        install: InstallKind,
        brewExecutable: String?,
        checkOnly: Bool
    ) -> Plan {
        switch result {
        case .failed(let reason):
            // Non-zero, because a script running this in a loop has to be able
            // to tell "nothing to install" from "I could not find out".
            return Plan(message: "Update check failed. \(reason)", exitCode: 1, command: nil)

        case .upToDate(let version):
            return Plan(
                message: "Harf \(version) is the newest release.", exitCode: 0, command: nil)

        case .updateAvailable(let version, let releaseURL):
            switch install {
            case .homebrew:
                guard let brewExecutable, !checkOnly else {
                    return Plan(
                        message: homebrewInstructions(version: version), exitCode: 0, command: nil)
                }
                return Plan(
                    message: "Harf \(version) is available. Upgrading with Homebrew; it quits "
                        + "the running copy first.",
                    exitCode: 0,
                    command: [brewExecutable, "upgrade", "--cask", "alialhawas/harf/harf"])

            case .directDownload:
                return Plan(
                    message: manualInstructions(version: version, releaseURL: releaseURL),
                    exitCode: 0, command: nil)
            }
        }
    }

    /// A Homebrew install that is only being asked, or whose `brew` has gone
    /// missing between the check and the upgrade. Names the command rather than
    /// running something off a guessed path.
    private static func homebrewInstructions(version: String) -> String {
        """
        Harf \(version) is available. This copy was installed with Homebrew, so:

          \(UpdateCheck.upgradeCommand)

        That quits the running copy before replacing it — it holds a keyboard
        event tap, and the cask makes sure nothing is tapping the keyboard with
        no app behind it.
        """
    }

    /// The direct-download path, which Harf does not walk for the user. See the
    /// note on this type for why it prints steps instead of fetching anything.
    private static func manualInstructions(version: String, releaseURL: URL) -> String {
        """
        Harf \(version) is available: \(releaseURL.absoluteString)

        This copy was not installed with a package manager, so replacing it is
        four steps and Harf does none of them for you — the build is not
        notarised, so nothing it downloaded could be verified against anything
        you already trust.

          1. Download Harf-\(version).dmg from the page above.
          2. harf --quit
             The running copy holds a keyboard event tap. Replacing the bundle
             underneath it leaves it tapping every key you press with nothing
             behind it, and loses the words it has learned since its last save.
          3. Drag Harf.app into /Applications, replacing the old one.
          4. Open it. macOS will refuse the first launch, because the build is
             not notarised: allow it once under System Settings > Privacy &
             Security > Open Anyway. If it asks for Accessibility and Input
             Monitoring again, grant both.
        """
    }

    // MARK: - Running it

    /// The live command. Blocks on the check, prints the plan, and runs the
    /// upgrade when there is one.
    static func run(checkOnly: Bool) -> Int32 {
        let homebrew = Homebrew.locate()
        let install = InstallKind.detect(
            in: InstallEnvironment(
                brewPrefix: { homebrew?.prefix },
                runningExecutable: Bundle.main.executablePath
                    ?? ProcessInfo.processInfo.arguments.first ?? ""))

        let printed = plan(
            for: check(), install: install, brewExecutable: homebrew?.executable,
            checkOnly: checkOnly)

        if printed.exitCode != 0 { return CLI.fail(printed.message, code: printed.exitCode) }
        print(printed.message)
        guard let command = printed.command else { return 0 }
        return stream(command)
    }

    /// `UpdateCheck.check` is asynchronous because `URLSession` is; a command is
    /// not. The wait is bounded a little beyond the request's own timeout, so a
    /// transport that never calls back cannot leave `harf --update` hanging in
    /// somebody's shell for good.
    private static func check() -> UpdateCheck.Result {
        var answer: UpdateCheck.Result?
        let finished = DispatchSemaphore(value: 0)
        UpdateCheck.check { result in
            answer = result
            finished.signal()
        }
        guard finished.wait(timeout: .now() + UpdateCheck.timeout + 5) == .success,
              let answer
        else {
            return .failed(
                reason: "GitHub did not answer within "
                    + "\(Int(UpdateCheck.timeout)) seconds.")
        }
        return answer
    }

    /// Runs the upgrade with this process's own standard output and error, which
    /// is what makes Homebrew's progress appear as it happens rather than in one
    /// block at the end: no pipes means the child inherits the terminal.
    ///
    /// Replacing the bundle while this command is running out of
    /// `<prefix>/bin/harf` — a symlink into that same bundle — is safe: the
    /// kernel keeps the open executable alive until it exits, whatever happens
    /// to the path it came from.
    private static func stream(_ command: [String]) -> Int32 {
        // The child writes to the same file descriptor this process has been
        // buffering into. Redirected to a pipe or a file, stdout is
        // block-buffered rather than line-buffered, so without this flush
        // `harf --update > log` puts Homebrew's output *above* the line
        // explaining what is being upgraded.
        fflush(stdout)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        do {
            try process.run()
        } catch {
            return CLI.fail(
                "Could not run \(command.joined(separator: " ")): "
                    + error.localizedDescription, code: 1)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
