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

    // MARK: - Re-reading

    /// Picks up a blob written by another process — which in practice means
    /// `harf --set`.
    ///
    /// The store caches at init and nothing ever looked again, so a setting
    /// changed from a shell did not reach the running app at all; worse, the
    /// app's next write copied its stale cache over it. `UserDefaults
    /// .didChangeNotification` is no help: it is same-process only. So the CLI
    /// writes the blob and then asks the running copy to call this, over the
    /// single-instance port.
    ///
    /// Returns whether anything actually changed, which is what the caller
    /// announces. Three things are deliberate:
    ///
    /// - A missing blob is not an error and not a reason to load anything. It
    ///   means the domain was removed under a running app, and the defaults are
    ///   *permissive* — not paused, every app normal — so adopting them would
    ///   silently un-pause the app and switch capture back on everywhere the
    ///   user had switched it off.
    /// - An unreadable blob is the same refusal, for the same reason, and it is
    ///   logged as a fault because somebody wrote nonsense over the settings of
    ///   a running app. Unlike `init`, it does *not* move the bytes aside under
    ///   `settings.corrupt`: at launch there is a user who can be told the
    ///   defaults were restored, here there is neither a restore nor a user, and
    ///   overwriting the rescue copy from a background reload would destroy the
    ///   one thing `init` saved.
    /// - `onChange` fires outside the lock, because the listeners are the
    ///   pipeline and the settings window and neither has any business running
    ///   while this store is locked.
    @discardableResult
    func reload() -> Bool {
        lock.lock()
        guard let stored = defaults.data(forKey: Key.settings) else {
            lock.unlock()
            return false
        }
        if AppSettings.isUnreadable(stored) {
            lock.unlock()
            Log.app.fault(
                "the settings blob changed under a running copy and could not be read; the settings in memory were kept"
            )
            return false
        }
        let loaded = AppSettings.load(storedJSON: stored)
        guard loaded != cached else {
            lock.unlock()
            return false
        }
        cached = loaded
        lock.unlock()

        onChange?(loaded)
        return true
    }

    /// Pushes the written blob out of this process's `UserDefaults` cache so the
    /// app can read it back. For the CLI to call between writing a setting and
    /// asking the running copy to re-read: the two are different processes, and
    /// without this the reload can race the write and find the old bytes.
    func flush() {
        defaults.synchronize()
    }

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
        mutate { $0.confidentScore = score.map(Self.clampConfidentScore) }
    }

    /// The band a confident score is held in, in one place because more than
    /// the settings window sets one: `--set confident` writes here, and
    /// `--decide`/`--eval` take the same number as a flag to report what the
    /// app would do at that setting. A second copy of these two numbers is a
    /// second answer to "what threshold is in force".
    ///
    /// Below 0.60 the gate fires on text nothing would call certain, which is
    /// the one path allowed to rewrite text too short for the ordinary rules.
    /// 1.0 is unreachable, so it would be an off switch that reads as on.
    static func clampConfidentScore(_ score: Double) -> Double {
        min(max(score, 0.60), 0.99)
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
    ///
    /// The mutation is applied to what is *persisted*, not to the cache. The
    /// cache can be stale — another process can have written the blob since
    /// this one loaded it — and a mutation based on the stale copy does not
    /// merely miss that change, it encodes the whole settings value and
    /// overwrites it. This is the other half of the defect `reload` fixes, and
    /// the more destructive half: `harf --set paused yes` followed by any menu
    /// click used to lose the pause.
    ///
    /// Two different questions come out of that, and they are answered
    /// separately. Whether to *write* is whether this call moved either the
    /// blob or the cache: a click that puts a setting back to the value already
    /// in memory changes nothing in memory, but if the blob disagrees it still
    /// has to be written, or the next reload would hand the other value back and
    /// silently undo the click. Whether to *announce* is only whether the
    /// in-memory value moved — nobody listening has anything to do about a write
    /// that changed nothing they can see.
    private func mutate(_ body: (inout AppSettings) -> Void) {
        lock.lock()
        let base = persistedOrCached()
        var updated = base
        body(&updated)
        let moved = updated != cached
        guard moved || updated != base else {
            lock.unlock()
            return
        }
        cached = updated
        lock.unlock()

        persist(updated)
        if moved { onChange?(updated) }
    }

    /// What a write should be based on: the blob if it can be read, the cache
    /// otherwise. Call with the lock held — it reads `cached`.
    ///
    /// The seed merge is applied for the same reason `load` applies it: a blob
    /// written by an older build is missing the policies this one seeds, and a
    /// mutation that persisted the un-merged value would drop them.
    private func persistedOrCached() -> AppSettings {
        guard let stored = defaults.data(forKey: Key.settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: stored)
        else { return cached }
        return decoded.mergingSeedDefaults()
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
