import Foundation

/// Every user preference, in one value.
///
/// Persisted by the app target as a single JSON blob rather than as a key per
/// preference: the per-app policy map has no fixed key set, and one blob keeps
/// a half-written upgrade from leaving the policies and the schema version
/// disagreeing.
///
/// Decoding is deliberately lenient — see `init(from:)`. A settings file
/// written by a newer build, or hand-edited into nonsense, must degrade to the
/// defaults for the affected field rather than throw the whole file away.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var aggressiveness: Aggressiveness

    /// Score at which a fix is applied however short the text is.
    ///
    /// nil leaves the length rules in charge, which is how the app behaved
    /// before this existed: a single word was never rewritten silently no
    /// matter how certain the reading.
    public var confidentScore: Double?

    /// Keystrokes held in memory at once. See `TypedBuffer.capacity`.
    public var bufferCapacity: Int

    /// Seconds of not typing after which the buffer is dropped.
    public var idleTimeout: Double

    /// Whether words are learned from what you write.
    ///
    /// Learning writes to disk. Everything else this app does lives in memory
    /// and dies with the process, so this is the one switch that decides
    /// whether anything you typed outlives the session.
    public var learnVocabulary: Bool
    /// Per-app overrides, keyed by exact (case-sensitive) bundle identifier.
    public var appPolicies: [String: AppPolicy]
    /// What an app with no entry in `appPolicies` gets.
    public var defaultPolicy: AppPolicy
    /// Global off switch. The event tap keeps running; nothing is buffered,
    /// evaluated or applied.
    public var paused: Bool
    /// Opt-in switch for the `decision` log category, which is the only place
    /// typed text may reach os_log.
    public var debugLogging: Bool
    /// Apps where the accessibility verify-before-delete read is skipped.
    ///
    /// Reserved for apps whose accessibility tree is expensive to touch —
    /// Chromium force-enables its full a11y tree the moment anything reads it,
    /// which costs the user memory and CPU for the rest of the session. Empty
    /// by default; edited from the Advanced tab of the settings window, which
    /// spells out what is being given up. Skipping the read means the
    /// auto-apply runs unverified, so the entry is a deliberate trade of safety
    /// for cost.
    public var axVerifySkip: Set<String>

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        aggressiveness: Aggressiveness = .balanced,
        confidentScore: Double? = 0.90,
        bufferCapacity: Int = TypedBuffer.defaultCapacity,
        idleTimeout: Double = BufferResetPolicy.idleTimeout,
        learnVocabulary: Bool = true,
        appPolicies: [String: AppPolicy] = PolicySeeds.table,
        defaultPolicy: AppPolicy = .normal,
        paused: Bool = false,
        debugLogging: Bool = false,
        axVerifySkip: Set<String> = []
    ) {
        self.schemaVersion = schemaVersion
        self.aggressiveness = aggressiveness
        self.confidentScore = confidentScore
        self.bufferCapacity = bufferCapacity
        self.idleTimeout = idleTimeout
        self.learnVocabulary = learnVocabulary
        self.appPolicies = appPolicies
        self.defaultPolicy = defaultPolicy
        self.paused = paused
        self.debugLogging = debugLogging
        self.axVerifySkip = axVerifySkip
    }

    /// A fresh install: seeds and nothing else.
    public static var defaults: AppSettings { AppSettings() }

    // MARK: - Resolution

    /// The policy in force for `bundleID`.
    ///
    /// Exact match first, then `defaultPolicy`. An unknown frontmost app — no
    /// bundle identifier at all, which is what a daemon, a login window or a
    /// crashed process looks like — is never rewritten.
    public func policy(for bundleID: String?) -> AppPolicy {
        guard let bundleID, !bundleID.isEmpty else { return .off }
        return appPolicies[bundleID] ?? defaultPolicy
    }

    public func skipsAXVerify(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return axVerifySkip.contains(bundleID)
    }

    // MARK: - Upgrade

    /// Adds seed entries the stored settings have never seen, without touching
    /// anything the user has already decided.
    ///
    /// Presence in `appPolicies` is the record of a decision, so a terminal the
    /// user has explicitly set to Normal keeps Normal forever, while a terminal
    /// added to the seed list by a later release arrives as Suggest-only.
    public func mergingSeedDefaults() -> AppSettings {
        var merged = self
        for (bundleID, policy) in PolicySeeds.table where merged.appPolicies[bundleID] == nil {
            merged.appPolicies[bundleID] = policy
        }
        merged.schemaVersion = Self.currentSchemaVersion
        return merged
    }

    /// Builds the live settings from whatever is on disk.
    ///
    /// - Parameters:
    ///   - storedJSON: the `settings` blob, nil on a fresh install.
    ///   - legacyAggressiveness: the bare `aggressiveness` string key written by
    ///     builds before the blob existed. Only consulted when there is no blob.
    ///   - legacyDebugLogging: likewise for the bare `debugLogging` boolean.
    public static func load(
        storedJSON: Data?,
        legacyAggressiveness: String? = nil,
        legacyDebugLogging: Bool = false
    ) -> AppSettings {
        if let storedJSON,
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: storedJSON)
        {
            return decoded.mergingSeedDefaults()
        }
        var migrated = AppSettings.defaults
        if let legacyAggressiveness, let level = Aggressiveness(rawValue: legacyAggressiveness) {
            migrated.aggressiveness = level
        }
        migrated.debugLogging = legacyDebugLogging
        return migrated
    }

    /// True when a stored blob exists but cannot be read at all.
    ///
    /// `load` deliberately falls back to the defaults in that case, and the
    /// defaults are *permissive*: `defaultPolicy` is `.normal` and `paused` is
    /// false. Silently writing those back over an unreadable file would revert
    /// every application the user had switched off and un-pause the app, with
    /// no way to get any of it back. The caller must keep a copy of the
    /// original bytes before it persists the fallback.
    public static func isUnreadable(_ storedJSON: Data?) -> Bool {
        guard let storedJSON else { return false }
        return (try? JSONDecoder().decode(AppSettings.self, from: storedJSON)) == nil
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, aggressiveness, confidentScore, bufferCapacity, idleTimeout
        case learnVocabulary, appPolicies, defaultPolicy, paused, debugLogging
        case axVerifySkip
    }

    /// Field-by-field, each with its own fallback: an unreadable or unknown
    /// value costs that one preference, never the whole file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        let rawPolicies = value(.appPolicies, [String: String]())

        self.init(
            schemaVersion: value(.schemaVersion, Self.currentSchemaVersion),
            aggressiveness: Aggressiveness(rawValue: value(.aggressiveness, "")) ?? .balanced,
            // A blob written before this setting existed decodes as nil, which
            // is the old behaviour, not the new default: an upgrade must not
            // silently start rewriting single words on someone.
            confidentScore: (try? container.decodeIfPresent(Double.self, forKey: .confidentScore)) ?? nil,
            bufferCapacity: value(.bufferCapacity, TypedBuffer.defaultCapacity),
            idleTimeout: value(.idleTimeout, BufferResetPolicy.idleTimeout),
            learnVocabulary: value(.learnVocabulary, true),
            appPolicies: rawPolicies.compactMapValues(AppPolicy.init(rawValue:)),
            defaultPolicy: AppPolicy(rawValue: value(.defaultPolicy, "")) ?? .normal,
            paused: value(.paused, false),
            debugLogging: value(.debugLogging, false),
            axVerifySkip: Set(value(.axVerifySkip, [String]())))
    }
}

/// The per-app policies a fresh install starts with.
///
/// M5 flips the M4 containment: `AppSettings.defaultPolicy` is `.normal`, so
/// Dodoma now rewrites text in every app that is not named here. The two lists
/// are what remains of the containment.
public enum PolicySeeds {
    /// Terminals. A wrong-layout rewrite in a shell is a command being retyped
    /// behind the user's back, and a mis-sized backspace burst there can send a
    /// half-deleted command to a running process. Suggest, never apply.
    public static let suggestOnly: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    /// Password managers and the system's own credential surfaces. Nothing is
    /// buffered, evaluated, suggested or applied in these.
    public static let off: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
    ]

    public static let table: [String: AppPolicy] = {
        var table = [String: AppPolicy]()
        for bundleID in suggestOnly { table[bundleID] = .suggestOnly }
        for bundleID in off { table[bundleID] = .off }
        return table
    }()
}
