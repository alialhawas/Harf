import AppKit
import DodomaCore
import SwiftUI

/// Shows the floating cards in an ordinary window, replaying their entrances
/// on a loop.
///
/// Every one of them is otherwise only reachable by reproducing the conditions
/// that raises it — typing a specific phrase in a specific layout, getting a
/// word to its tenth sighting, or asking for a flip — which is a poor way to
/// look at an animation you are trying to get right. Same views, same
/// modifiers, same timings as the real thing; only the window is different.
///
/// A development affordance, in the same spirit as `--dump-layout-fixtures`.
public enum CardPreview {
    /// Long enough to watch the loop several times, short enough that a
    /// forgotten window closes itself.
    static let lifetime: TimeInterval = 120
    static let replayInterval: TimeInterval = 2.0

    /// The window is built from `applicationDidFinishLaunching` rather than
    /// before `run()`. An executable launched from a shell has no bundle, and
    /// ordering a window in before AppKit has finished starting leaves it
    /// owned by an application the window server has not activated — the
    /// process runs, and nothing appears on any display.
    /// Held here rather than in a local. `NSApplication.delegate` is a weak
    /// reference, so a delegate that only a local variable owns is released
    /// before AppKit finishes starting: `applicationDidFinishLaunching` never
    /// runs, no window is ever built, and the process sits there showing
    /// nothing on any display.
    private static var delegate: PreviewDelegate?

    public static func run() -> Never {
        let app = NSApplication.shared
        delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}

private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Harf — card preview"
        window.contentView = NSHostingView(rootView: PreviewStage())
        window.center()
        // Floating and on every space. The bundle is marked LSUIElement for the
        // menu-bar app's sake, and a window from an accessory bundle settles
        // behind whatever is already on screen — which for a preview you are
        // trying to look at is the same as not appearing at all.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        Timer.scheduledTimer(withTimeInterval: CardPreview.lifetime, repeats: false) { _ in
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Rebuilds both cards on a timer. Identity changes with `take`, so SwiftUI
/// tears the old views down and `onAppear` runs again — which is what replays
/// the entrance rather than leaving it settled after the first pass.
private struct PreviewStage: View {
    @State private var take = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            label("Suggestion")
            SuggestionCard(
                insertText: "السلام عليكم",
                replacedText: "hgsghl ugd;l",
                rightToLeft: true,
                clickOnly: false)
                .id("suggestion-\(take)")

            label("Learned a word")
            LearnedCard(words: ["kubectl"], rightToLeft: false, onUndo: {})
                .id("learned-en-\(take)")

            label("Learned a word — Arabic")
            LearnedCard(words: ["تفعيل"], rightToLeft: true, onUndo: {})
                .id("learned-ar-\(take)")

            label("Flipped")
            FlipCard(text: "السلام عليكم", rightToLeft: true, onLearn: {}, onDismiss: {})
                .id("flip-\(take)")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(
            Timer.publish(every: CardPreview.replayInterval, on: .main, in: .common).autoconnect()
        ) { _ in
            take += 1
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .kerning(1.2)
            .foregroundStyle(.tertiary)
    }
}
