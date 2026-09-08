import AppKit
import DodomaAppKit

// Ahead of the command parser: this one needs a run loop and a window, which
// `CLI.run` — which returns an exit code — has no way to give it.
if CommandLine.arguments.contains("--preview-cards") {
    CardPreview.run()
}

if let command = CLI.parse(Array(CommandLine.arguments.dropFirst())) {
    exit(CLI.run(command))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
