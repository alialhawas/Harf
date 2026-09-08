import DodomaCore
import Foundation

/// User preferences, backed by `UserDefaults`.
///
/// One JSON blob under the `settings` key, not a key per preference: the
/// per-app policy map has no fixed key set, and a single blob cannot be caught
/// half-upgraded. `AppSettings` owns the shape, the seeding and the migration;
/// this type owns the storage, the lock and the change notification.
///
/// Read from the pipeline queue on every evaluation and written from the main
/// thread by the menu, so the cached value is behind a lock rather than being
/// re-decoded per read.
final class SettingsStore {
    enum Key {
        static let settings = "settings"
        /// Where an unreadable `settings` blob is kept, so that restoring the
        /// defaults over it is recoverable by hand.
        static let corruptSettings = "settings.corrupt"
        /// Written by builds before the blob existed; read once, at migration.
        static let legacyAggressiveness = "aggressiveness"
        /// Still honoured as a live override so that the documented
        /// `defaults write com.ali.dodoma debugLogging -bool YES` keeps working
        /// without a settings-window round trip.
        static let debugLogging = "debugLogging"
        /// Set once the user has pressed Done in the onboarding window. Kept
        /// out of the settings blob deliberately: it is a record of something
        /// that happened, not a preference, and restoring a corrupt blob to the
        /// defaults must not walk the user back through onboarding.
        static let onboardingCompleted = "onboardingCompleted"
    }

    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: AppSettings

    /// Called on the thread that made the change, after it has been persisted.
    var onChange: ((AppSettings) -> Void)?

    /// - Parameter defaults: `UserDefaults(suiteName:)` returns nil when the
    ///   suite is the running app's own bundle identifier, which is exactly the
    ///   case inside the shipped bundle — and there `.standard` already *is*
    ///   the `com.ali.dodoma` domain. Running from `swift run`, where the
    ///   process has no bundle identifier, the suite resolves and writes to the
    ///   same plist. Either way the settings land in one place.
    init(defaults: UserDefaults = UserDefaults(suiteName: "com.ali.dodoma") ?? .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Key.settings)
        let loaded = AppSettings.load(
            storedJSON: stored,
            legacyAggressiveness: defaults.string(forKey: Key.legacyAggressiveness),
            legacyDebugLogging: defaults.bool(forKey: Key.debugLogging))
        cached = loaded

        // The fallback is the *permissive* default — every app Normal, not
        // paused — so overwriting an unreadable blob with it would quietly
        // switch Dodoma back on everywhere the user had switched it off, and
        // leave nothing to restore from. Keep the bytes first.
        if let stored, AppSettings.isUnreadable(stored) {
            defaults.set(stored, forKey: Key.corruptSettings)
            Log.app.fault(
                "the settings blob could not be read; the defaults were restored and the original was kept under the \(Key.corruptSettings, privacy: .public) key"
            )
        }
        // Writing the merged result straight back is what makes the seed merge
        // durable: a policy added by this release is on disk before the user
        // touches anything, so a later release can tell "never seen" from
        // "seen and left alone".
        persist(loaded)
    }

    // MARK: - Reading

    var settings: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    var aggressiveness: Aggressiveness { settings.aggressiveness }

    var confidentScore: Double? { settings.confidentScore }

    var bufferCapacity: Int { settings.bufferCapacity }
    var idleTimeout: Double { settings.idleTimeout }
    var learnVocabulary: Bool { settings.learnVocabulary }

    var paused: Bool { settings.paused }

    /// The blob's value, or the bare key, whichever is on.
    var debugLogging: Bool { settings.debugLogging || defaults.bool(forKey: Key.debugLogging) }

    func policy(for bundleID: String?) -> AppPolicy { settings.policy(for: bundleID) }

    func skipsAXVerify(_ bundleID: String?) -> Bool { settings.skipsAXVerify(bundleID) }

    // MARK: - Writing

    func setPaused(_ paused: Bool) {
        mutate { $0.paused = paused }
    }

    /// nil turns the confidence rule off and returns the length rules to
    /// charge; any value is clamped into the range the slider can reach.
    func setBufferCapacity(_ keys: Int) {
        mutate {
            $0.bufferCapacity = min(
                max(keys, TypedBuffer.minimumCapacity), TypedBuffer.maximumCapacity)
        }
    }

    func setIdleTimeout(_ seconds: Double) {
        mutate { $0.idleTimeout = min(max(seconds, 2), 120) }
    }

    func setLearnVocabulary(_ enabled: Bool) {
        mutate { $0.learnVocabulary = enabled }
    }

    func setConfidentScore(_ score: Double?) {
        mutate { $0.confidentScore = score.map { min(max($0, 0.60), 0.99) } }
    }

    func setPolicy(_ policy: AppPolicy, for bundleID: String) {
        mutate { $0.appPolicies[bundleID] = policy }
    }

    /// Drops the override entirely, so the app falls back to `defaultPolicy`.
    ///
    /// Not the same as writing the default policy into the entry: presence in
    /// the map is what `mergingSeedDefaults` reads as "the user has decided
    /// about this app", so a removed entry can be re-seeded by a later release
    /// while an explicit one never is.
    func removePolicy(for bundleID: String) {
        mutate { $0.appPolicies[bundleID] = nil }
    }

    func setDefaultPolicy(_ policy: AppPolicy) {
        mutate { $0.defaultPolicy = policy }
    }

    func setAggressiveness(_ aggressiveness: Aggressiveness) {
        mutate { $0.aggressiveness = aggressiveness }
    }

    /// Switching it off also clears the bare `debugLogging` key.
    ///
    /// The getter is the OR of the two, so leaving the bare key set would make
    /// the switch look broken: the user turns it off and typed text keeps
    /// reaching `os_log`.
    func setDebugLogging(_ enabled: Bool) {
        if !enabled, defaults.object(forKey: Key.debugLogging) != nil {
            defaults.removeObject(forKey: Key.debugLogging)
        }
        mutate { $0.debugLogging = enabled }
    }

    func setAXVerifySkip(_ skip: Set<String>) {
        mutate { $0.axVerifySkip = skip }
    }

    // MARK: - Onboarding

    var onboardingCompleted: Bool { defaults.bool(forKey: Key.onboardingCompleted) }

    func setOnboardingCompleted(_ completed: Bool) {
        defaults.set(completed, forKey: Key.onboardingCompleted)
    }

    /// The single write path behind every setter above. Main thread: each
    /// caller is a menu item, a hot key handler or a settings-window control,
    /// and `onChange` is delivered synchronously on the calling thread to
    /// whoever owns the pipeline.
    private func mutate(_ body: (inout AppSettings) -> Void) {
        lock.lock()
        var updated = cached
        body(&updated)
        guard updated != cached else {
            lock.unlock()
            return
        }
        cached = updated
        lock.unlock()

        persist(updated)
        onChange?(updated)
    }

    private func persist(_ settings: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Key.settings)
        } catch {
            // Nothing actionable: the in-memory value is still correct, the
            // change just will not survive a restart.
            Log.app.error(
                "settings could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }
}
