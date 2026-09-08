import AppKit
import DodomaAppKit

// Ahead of the command parser: this one needs a run loop and a window, which
// `CLI.run` — which returns an exit code — has no way to give it. Ahead of the
// single-copy check too, and deliberately: the preview opens a window and
// nothing else — no tap, no settings, nothing persisted — so looking at the
// cards while Harf is running is not a second copy of anything.
if CommandLine.arguments.contains("--preview-cards") {
    CardPreview.run()
}

// Whether macOS launched the `.app`. Everything about the launch turns on this
// — see `CLI.launch` — and it is the one question this file answers itself,
// because it is a fact about the running process rather than about the
// arguments.
let isBundled = CLI.isBundled

// `isatty` is the only part of the decision that cannot be tested, so it is the
// only part that lives here. Either handle is enough: a pipeline redirects one
// of them and the other still shows a person is watching, and LaunchServices
// gives the app neither. It is passed on rather than acted on; `CLI.launch`
// says why it is no longer the signal.
let isTerminal = isatty(STDIN_FILENO) != 0 || isatty(STDOUT_FILENO) != 0

switch CLI.launch(
    command: CLI.parse(Array(CommandLine.arguments.dropFirst()), isBundled: isBundled),
    isBundled: isBundled,
    isTerminal: isTerminal,
    forceApplication: CLI.isApplicationForced())
{
case .run(let command):
    exit(CLI.run(command))
case .usage:
    exit(CLI.usage())
case .application:
    break
}

// Before `AppDelegate()`, not inside `applicationDidFinishLaunching`, and the
// distance between those two is the whole point. `AppDelegate` holds
// `SettingsStore.shared`, and building one writes the merged settings back to
// the `com.ali.dodoma` suite — which the copy that is already running reads. A
// losing copy from an older build would truncate the running copy's settings on
// its way to being told to quit. Nothing that persists anything may run above
// this line.
SingleInstance.enforceOnlyCopy()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
