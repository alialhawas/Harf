import DodomaCore
import Foundation

/// Everything a copy of Harf knows about itself that somebody outside the
/// process might ask for.
///
/// `harf --status` used to answer every one of these questions in its *own*
/// process and present the answers as the app's. `Permissions.current()` reads
/// the grants of whoever calls it, so a command run from a terminal that has
/// been granted Accessibility printed `accessibility yes` while the app was
/// logging `accessibility=false`; `LoginItem.status` asks launchd about
/// `Bundle.main`, which for the `harf` symlink is `/opt/homebrew/bin`; and the
/// settings lines came from the saved blob, which is not necessarily what the
/// running copy has applied. Two days of a wedged instance looked healthy from
/// the outside for exactly this reason.
///
/// So the running copy answers instead, and this is the value it sends.
///
/// `settings` is what the app has *applied*, not what is saved. That is the
/// interesting one — it is the difference between "the blob says paused" and
/// "the app is paused" — and carrying it means `--status` can name a
/// disagreement between the two without any generation counter or sequence
/// number to keep in step.
struct RuntimeSnapshot: Codable, Equatable {
    /// The shape of this struct, not the app's version.
    ///
    /// Two builds can be installed at once — `/Applications/Harf.app` and
    /// whatever the cask last linked onto the PATH — and the older of the two
    /// can be the one holding the port. A reader that does not recognise the
    /// number gives up and renders *unknown*, which is true, rather than
    /// decoding a payload it only half understands. Bump it when a field
    /// changes meaning; adding a field with a default does not need it, because
    /// `Codable` already tolerates that in the lenient direction.
    static let wireVersion = 1

    var wire: Int
    /// The running copy's version, so `--status` can say when the copy
    /// answering is not the build the command came from.
    var appVersion: String
    var pid: Int32
    var permissions: PermissionState
    var capturing: Bool
    var paused: Bool
    var secureInput: Bool
    var degraded: Bool
    var loginItem: LoginItemStatus
    /// The settings the app is enforcing right now.
    var settings: AppSettings

    init(
        wire: Int = RuntimeSnapshot.wireVersion,
        appVersion: String,
        pid: Int32,
        permissions: PermissionState,
        capturing: Bool,
        paused: Bool,
        secureInput: Bool,
        degraded: Bool,
        loginItem: LoginItemStatus,
        settings: AppSettings
    ) {
        self.wire = wire
        self.appVersion = appVersion
        self.pid = pid
        self.permissions = permissions
        self.capturing = capturing
        self.paused = paused
        self.secureInput = secureInput
        self.degraded = degraded
        self.loginItem = loginItem
        self.settings = settings
    }
}

/// The box the running copy's state sits in so that a Mach port callback can
/// reach it.
///
/// Static, and that is forced rather than chosen: `SingleInstance.handleMessage`
/// is a `CFMessagePortCallBack`, a C function pointer, so it captures nothing.
/// Whatever it answers with has to be reachable from a type name. The same
/// shape as `FixHistoryStore` and `SuggestionState` — one uncontended `NSLock`
/// around a value written on one thread and read on another — except that here
/// the reader is a run-loop callback rather than the menu.
///
/// `reloadHandler` and `vocabularyHandler` are the other direction: the CLI
/// asks the app to re-read its settings, or to take a word that was added or
/// removed from a shell, and the callback has no way to reach
/// `SettingsStore.shared` or the lexicon either. Hooks installed by
/// `AppDelegate` keep both out of this file, which also keeps them out of the
/// tests — a test that reached for `SettingsStore.shared` would be writing the
/// developer's real settings.
enum RuntimeStatus {
    private static let lock = NSLock()
    private static var current: RuntimeSnapshot?
    private static var reloadHandler: (() -> Void)?
    private static var vocabularyHandler: (() -> Void)?

    /// Called from `AppDelegate.refreshPermissions`, which already computes
    /// every field on its two-second poll.
    static func publish(_ snapshot: RuntimeSnapshot) {
        lock.lock()
        current = snapshot
        lock.unlock()
    }

    static var snapshot: RuntimeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The bytes the port replies with. Empty when nothing has been published
    /// yet — a copy still in `applicationDidFinishLaunching` has no honest
    /// answer, and empty decodes to nil at the other end, which renders as
    /// *unknown* rather than as a screen of falsehoods.
    ///
    /// The copy happens under the lock and the encoding outside it: JSON
    /// encoding is the expensive part, and holding the lock across it would put
    /// the two-second permission poll behind whatever a `--status` is doing.
    static func encoded() -> Data {
        lock.lock()
        let snapshot = current
        lock.unlock()

        guard let snapshot else { return Data() }
        do {
            return try JSONEncoder().encode(snapshot)
        } catch {
            Log.app.error(
                "the status snapshot could not be encoded: \(String(describing: error), privacy: .public)"
            )
            return Data()
        }
    }

    /// The reader's half. Nil for anything this build cannot vouch for:
    /// nothing published, a reply from a build with a different wire version,
    /// or bytes that are not a snapshot at all — which is possible, because a
    /// bootstrap name can in principle be held by something that is not Harf.
    static func decode(_ data: Data?) -> RuntimeSnapshot? {
        guard let data, !data.isEmpty,
              let snapshot = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data),
              snapshot.wire == RuntimeSnapshot.wireVersion
        else { return nil }
        return snapshot
    }

    static func setReloadHandler(_ handler: (() -> Void)?) {
        lock.lock()
        reloadHandler = handler
        lock.unlock()
    }

    /// Runs the installed handler, or does nothing when there is none — a
    /// request that arrives while the app is shutting down is not an error.
    /// Read out from under the lock before it is called, so a handler that
    /// touches the store cannot deadlock against a publish.
    static func handleReloadRequest() {
        lock.lock()
        let handler = reloadHandler
        lock.unlock()
        handler?()
    }

    static func setVocabularyHandler(_ handler: (() -> Void)?) {
        lock.lock()
        vocabularyHandler = handler
        lock.unlock()
    }

    /// Runs the installed vocabulary handler, or does nothing when there is
    /// none. Same shape as the settings reload above, and separate from it
    /// because the two read different files: `harf --set` changes the settings
    /// blob, `harf --words` changes the lexicon, and neither should make the
    /// app go and re-read the other.
    static func handleVocabularyRequest() {
        lock.lock()
        let handler = vocabularyHandler
        lock.unlock()
        handler?()
    }

    /// For tests, which share one process and would otherwise inherit each
    /// other's snapshots and handlers.
    static func forget() {
        lock.lock()
        current = nil
        reloadHandler = nil
        vocabularyHandler = nil
        lock.unlock()
    }
}
