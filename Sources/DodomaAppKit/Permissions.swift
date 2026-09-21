import ApplicationServices
import Foundation
import IOKit.hid

/// The two privacy grants, as one value.
///
/// `Codable` because it crosses a process boundary: `harf --status` asks the
/// running copy for its grants rather than reading its own, since
/// `Permissions.current()` answers for whichever process calls it and a command
/// run from a trusted terminal inherits that terminal's grants — which is how
/// `--status` came to report `accessibility yes` while the app itself was
/// logging `accessibility=false`.
struct PermissionState: Codable, Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool
}

enum Permissions {
    static func current() -> PermissionState {
        PermissionState(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
