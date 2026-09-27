import DodomaCore
import Foundation

/// What "Check for Updates…" puts on screen, as a value rather than as an
/// `NSAlert`.
///
/// The same split as `CLIConfig.statusText`: the decision — which words, which
/// second button, warning or not — is a pure function with tests on it, and
/// `MenuBarController` does nothing but hand the result to AppKit. `runModal`
/// cannot be driven from a test, so anything decided inside it would be decided
/// where nothing can check it.
struct UpdateAlert: Equatable {
    /// The one extra button beside OK, and what pressing it does.
    ///
    /// Two cases because the two installs have nothing useful in common: a
    /// Homebrew install has a command worth putting on the pasteboard, and a
    /// direct download has a page worth opening. Neither ever downloads
    /// anything; see the note on `CLIUpdate`.
    enum Action: Equatable {
        case copy(String)
        case open(URL)
    }

    var title: String
    var body: String
    var action: Action?
    var isWarning: Bool

    /// The button that performs `action`, in the words of what it does.
    var actionTitle: String? {
        switch action {
        case .copy: return "Copy"
        case .open: return "Open Release Page"
        case nil: return nil
        }
    }

    /// All three outcomes get an alert. After an explicit click, silence reads
    /// as a broken menu item — there is no other feedback, because the menu has
    /// already closed by the time the answer arrives.
    static func describing(_ result: UpdateCheck.Result, install: InstallKind) -> UpdateAlert {
        switch result {
        case .upToDate(let version):
            return UpdateAlert(
                title: "Harf is up to date.",
                body: "You are running \(version), which is the newest release.",
                action: nil, isWarning: false)

        case .failed(let reason):
            return UpdateAlert(
                title: "Could not check for updates.",
                body: reason, action: nil, isWarning: true)

        case .updateAvailable(let version, let releaseURL):
            switch install {
            case .homebrew:
                return UpdateAlert(
                    title: "Harf \(version) is available.",
                    body: "This copy was installed with Homebrew. To upgrade it, in a "
                        + "terminal:\n\n\(UpdateCheck.upgradeCommand)\n\nThat quits Harf "
                        + "before replacing it, which it has to: this copy is holding a "
                        + "keyboard event tap.",
                    action: .copy(UpdateCheck.upgradeCommand), isWarning: false)

            case .directDownload:
                return UpdateAlert(
                    title: "Harf \(version) is available.",
                    body: "Quit Harf, then replace /Applications/Harf.app with the copy "
                        + "from the release page. Harf does not install it for you — the "
                        + "build is not notarised, so nothing it fetched could be verified "
                        + "against anything you already trust.",
                    action: .open(releaseURL), isWarning: false)
            }
        }
    }
}

/// One check at a time.
///
/// The menu can be opened and clicked again while the first request is still
/// out, and two requests mean two alerts stacked on each other — plus two calls
/// against a rate limit that allows a few dozen an hour. A struct rather than a
/// bare `Bool` so that "is a check running" has the two operations that may
/// change it and nothing else.
struct UpdateCheckGate {
    private var running = false

    /// True when this caller owns the check. False when one is already out, and
    /// the caller must then do nothing at all.
    mutating func begin() -> Bool {
        if running { return false }
        running = true
        return true
    }

    mutating func finish() { running = false }
}
