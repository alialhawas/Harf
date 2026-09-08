import AppKit
import DodomaCore
import SwiftUI

/// Main-thread mirror of what the first-run window shows.
final class OnboardingModel: ObservableObject {
    @Published var permissions = PermissionState(accessibility: false, inputMonitoring: false)
    @Published var loginStatus: LoginItemStatus = .disabled

    /// True once both grants are in place, which is the only thing the Done
    /// button reads differently.
    var isReady: Bool { permissions.accessibility && permissions.inputMonitoring }

    func refreshLoginStatus() {
        let status = LoginItem.status
        if status != loginStatus { loginStatus = status }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        loginStatus = LoginItem.setEnabled(enabled)
    }
}

/// The first-run walkthrough.
///
/// The one window in Dodoma that activates the application. An accessory app
/// that steals focus is a bug everywhere else, but the grants cannot be given
/// without the user going to System Settings, and a menu-bar icon quietly
/// reading "Needs Accessibility permission" is not a first-run experience — the
/// app looks broken and there is nothing on screen saying why.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model = OnboardingModel()
    private let onDone: () -> Void
    private var window: NSWindow?

    /// - Parameter onDone: records that the walkthrough was finished, so it
    ///   never opens itself again.
    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Seeded here rather than left to the poll: reopening the window from
        // the menu on a fully granted install would otherwise show two empty
        // circles for up to two seconds, which reads as "the grants are gone".
        model.permissions = Permissions.current()
        model.refreshLoginStatus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Driven by the app delegate's existing two-second permission poll, so the
    /// checkmarks tick over while the user is in System Settings.
    func update(permissions: PermissionState) {
        guard isVisible else { return }
        if model.permissions != permissions { model.permissions = permissions }
        model.refreshLoginStatus()
    }

    /// Closing the window counts as finishing: the walkthrough is a courtesy,
    /// not a gate, and re-presenting it on the next launch to someone who has
    /// already dismissed it once would be worse than a menu item they can find.
    func windowWillClose(_ notification: Notification) {
        onDone()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Welcome to Harf"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.075, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: ZStack {
                DodomaTheme.canvas
                GravityStarsBackground(
                    starCount: 110, starSize: 2.4, starOpacity: 0.85,
                    starColor: Color(red: 0.87, green: 0.95, blue: 0.98))
                OnboardingView(
                    model: model,
                    onDone: { [weak self] in self?.finish() })
            }
            .preferredColorScheme(.dark))
        window.center()
        return window
    }

    private func finish() {
        // `onDone` also runs from `windowWillClose`; it is idempotent.
        window?.close()
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Harf fixes wrong-layout typing")
                .font(.title2)

            Text(OnboardingCopy.introduction)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    PermissionRow(
                        title: "Accessibility",
                        detail: "Lets Harf read the text in front of the caret and replace it.",
                        granted: model.permissions.accessibility,
                        open: { NSWorkspace.shared.open(PermissionPanes.accessibility) })
                    PermissionRow(
                        title: "Input Monitoring",
                        detail: "Lets Harf see the keys you type.",
                        granted: model.permissions.inputMonitoring,
                        open: { NSWorkspace.shared.open(PermissionPanes.inputMonitoring) })
                    Text(OnboardingCopy.certificateNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            Toggle("Start Harf at login", isOn: loginItem)
                .disabled(model.loginStatus == .unavailable)
            if !model.loginStatus.explanation.isEmpty {
                Text(model.loginStatus.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Text(model.isReady
                    ? "Both grants are in place — Harf is watching."
                    : "You can close this and grant the rest later; the menu-bar item says "
                        + "what is still missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }

    private var loginItem: Binding<Bool> {
        Binding(get: { model.loginStatus.isOn }, set: { model.setLoginItemEnabled($0) })
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? "granted" : "not granted")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(granted ? "Open…" : "Grant…", action: open)
        }
    }
}

/// The two System Settings panes, shared with the menu.
enum PermissionPanes {
    static let accessibility = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let inputMonitoring = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
}

/// The onboarding prose, kept out of the view so it can be read as prose.
enum OnboardingCopy {
    static let introduction = """
        Typing Arabic with the US layout active produces mojibake — `hgsghl` instead of \
        `السلام`. Dodoma watches what you type, and when a word only makes sense under the \
        other layout it deletes what is on screen and types the correction in its place, \
        switching the keyboard layout as it goes. That is a destructive edit made on your \
        behalf: it presses Delete in the app you are typing in. It is held back in password \
        fields, in terminals (which are offered a suggestion instead), and whenever the text \
        in front of the caret is not exactly what Dodoma recorded you typing — but when it \
        does go wrong, \(SettingsCopy.undoChord) puts your text back for 30 seconds \
        afterwards, and \(SettingsCopy.pauseChord) switches the whole thing off.
        """

    static let certificateNote = """
        Building from source: run `scripts/make-cert.sh` once before `make install`, or macOS \
        drops both grants on every rebuild and you will be re-approving Dodoma after each \
        build. See the README.
        """
}
