import AppKit
import Foundation
import ServiceManagement

/// Whether Dodoma is registered to start when the user logs in.
///
/// A flattened `SMAppService.Status`: the four cases that matter to the UI,
/// plus the one the framework has no case for — being asked at all from a
/// process that is not in an app bundle, which is what `swift run` is.
enum LoginItemStatus: Equatable {
    /// Registered and allowed to run.
    case enabled
    /// Never registered, or unregistered again.
    case disabled
    /// Registered, but the user has to switch it on under
    /// System Settings > General > Login Items. macOS does not let an app
    /// grant this to itself, so the UI can only link there.
    case requiresApproval
    /// The service is gone as far as launchd is concerned — the usual cause is
    /// a bundle that has been moved or deleted since it was registered.
    case notFound
    /// Not a bundled app, so there is nothing to register.
    case unavailable

    /// What the settings and onboarding windows put under the toggle. Empty
    /// when there is nothing worth saying.
    var explanation: String {
        switch self {
        case .enabled, .disabled:
            return ""
        case .requiresApproval:
            return "macOS is holding this back. Approve Harf under "
                + "System Settings > General > Login Items."
        case .notFound:
            return "macOS cannot find the registered copy of Harf. This usually means the "
                + "app was moved after it was registered — switch this off and on again from "
                + "its current location."
        case .unavailable:
            return "Only a bundled app can be a login item. Install with `make install` and "
                + "use the copy in /Applications."
        }
    }

    /// Whether the toggle should read as on. `.requiresApproval` counts: the
    /// registration exists, macOS is simply not honouring it yet, and showing
    /// the switch as off would invite the user to "fix" it by registering
    /// again, which changes nothing.
    var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .disabled, .notFound, .unavailable: return false
        }
    }
}

/// Start-at-login, via `SMAppService.mainApp`.
///
/// `SMAppService` registers whatever bundle is running, from wherever it is —
/// including `build/Dodoma.app`. That works, but a login item pointing into a
/// build directory breaks the moment the directory is cleaned, so the README
/// recommends installing to /Applications first.
enum LoginItem {
    /// The Login Items pane. `.requiresApproval` is the only state the app
    /// cannot resolve on its own.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    static var status: LoginItemStatus {
        guard isBundled else { return .unavailable }
        return map(SMAppService.mainApp.status)
    }

    /// Pure, so the mapping is pinned by a test rather than by a live launchd.
    static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Registers or unregisters, and returns the status afterwards.
    ///
    /// Failures are logged and swallowed: there is nothing the user can do
    /// about them at the point of clicking, and the returned status — which is
    /// re-read from the service, not assumed — is what the toggle snaps back
    /// to.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> LoginItemStatus {
        guard isBundled else { return .unavailable }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error(
                "login item could not be \(enabled ? "registered" : "unregistered", privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        return status
    }

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// `swift run` produces a bare executable with no bundle identifier, and
    /// `SMAppService.mainApp` on one of those raises rather than returning a
    /// status.
    private static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }
}
