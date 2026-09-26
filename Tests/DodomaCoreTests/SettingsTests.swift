import XCTest

@testable import DodomaCore

/// The persisted settings, their seeds, and the two things a settings file has
/// to survive: an upgrade that adds seeds, and an older build's key layout.
final class SettingsTests: XCTestCase {
    private func encode(_ settings: AppSettings) throws -> Data {
        try JSONEncoder().encode(settings)
    }

    // MARK: - Seeds

    func testFreshInstallSeedsTerminalsAndPasswordManagers() {
        let settings = AppSettings.defaults

        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertEqual(settings.defaultPolicy, .normal)
        XCTAssertEqual(settings.aggressiveness, .balanced)
        XCTAssertFalse(settings.paused)
        XCTAssertFalse(settings.debugLogging)
        XCTAssertTrue(settings.axVerifySkip.isEmpty)

        for bundleID in PolicySeeds.suggestOnly {
            XCTAssertEqual(settings.policy(for: bundleID), .suggestOnly, bundleID)
        }
        for bundleID in PolicySeeds.off {
            XCTAssertEqual(settings.policy(for: bundleID), .off, bundleID)
        }
    }

    /// The shipped confident score, pinned. It is the only gate that can fix a
    /// region shorter than the ordinary length rules allow, so the number is
    /// what decides whether a one-word mistake is corrected at all; moving it
    /// changes the behaviour of every fresh install.
    func testFreshInstallShipsTheConfidentScoreAtEightyPercent() {
        XCTAssertEqual(AppSettings.defaults.confidentScore, 0.80)
        XCTAssertEqual(AppSettings().confidentScore, 0.80)
    }

    /// The default applies to a fresh install only. A settings file written
    /// before the field existed keeps the old behaviour, so an upgrade does not
    /// start rewriting single words on somebody who never asked for it.
    func testAStoredBlobWithoutAConfidentScoreStaysOff() throws {
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            .confidentScore)
        var stored = AppSettings.defaults
        stored.confidentScore = nil
        XCTAssertNil(AppSettings.load(storedJSON: try encode(stored)).confidentScore)
    }

    /// The exact seed lists, spelled out. A typo in a bundle identifier is a
    /// silent loss of protection, and these are the identifiers the plan names.
    func testSeedListsAreExactlyTheDocumentedBundleIdentifiers() {
        XCTAssertEqual(
            PolicySeeds.suggestOnly,
            [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "dev.warp.Warp-Stable",
                "com.mitchellh.ghostty",
                "net.kovidgoyal.kitty",
                "org.alacritty",
                "com.github.wez.wezterm",
                "co.zeit.hyper",
            ])
        XCTAssertEqual(
            PolicySeeds.off,
            [
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop",
                "com.apple.keychainaccess",
                "com.apple.SecurityAgent",
                "com.apple.loginwindow",
            ])
        XCTAssertTrue(PolicySeeds.suggestOnly.isDisjoint(with: PolicySeeds.off))
    }

    // MARK: - Resolution

    func testPolicyResolution() {
        var settings = AppSettings.defaults
        settings.appPolicies["com.example.custom"] = .off

        let cases: [(bundleID: String?, expected: AppPolicy)] = [
            ("com.apple.TextEdit", .normal),  // no entry, so the default
            ("com.apple.Notes", .normal),
            ("com.apple.Terminal", .suggestOnly),
            ("com.1password.1password", .off),
            ("com.example.custom", .off),
            ("com.apple.terminal", .normal),  // bundle IDs are matched exactly
            ("", .off),
            (nil, .off),
        ]
        for row in cases {
            XCTAssertEqual(
                settings.policy(for: row.bundleID), row.expected, row.bundleID ?? "nil")
        }
    }

    /// M5 deliberately flips the M4 containment: everything not named in the
    /// seeds is now rewritten automatically.
    func testDefaultPolicyIsNormalSoUnknownAppsAreLive() {
        XCTAssertEqual(AppSettings.defaults.policy(for: "com.some.app.nobody.has.heard.of"),
                       .normal)
    }

    func testAXVerifySkipIsEmptyByDefaultAndMatchesExactly() {
        var settings = AppSettings.defaults
        XCTAssertFalse(settings.skipsAXVerify("com.google.Chrome"))
        settings.axVerifySkip = ["com.google.Chrome"]
        XCTAssertTrue(settings.skipsAXVerify("com.google.Chrome"))
        XCTAssertFalse(settings.skipsAXVerify("com.google.chrome"))
        XCTAssertFalse(settings.skipsAXVerify(nil))
    }

    // MARK: - Round trip

    func testRoundTripsThroughJSON() throws {
        var settings = AppSettings.defaults
        settings.aggressiveness = .eager
        settings.paused = true
        settings.debugLogging = true
        settings.defaultPolicy = .suggestOnly
        settings.appPolicies["com.example.custom"] = .off
        settings.axVerifySkip = ["com.google.Chrome"]

        let decoded = try JSONDecoder().decode(AppSettings.self, from: encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    /// A field written by a newer build, or hand-edited into nonsense, costs
    /// that field and nothing else.
    func testUnknownValuesFallBackFieldByField() throws {
        let json = """
            {
              "schemaVersion": 1,
              "aggressiveness": "reckless",
              "defaultPolicy": "whatever",
              "appPolicies": {"com.apple.Terminal": "off", "com.example.a": "nonsense"},
              "paused": true
            }
            """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.aggressiveness, .balanced)
        XCTAssertEqual(decoded.defaultPolicy, .normal)
        XCTAssertTrue(decoded.paused)
        XCTAssertEqual(decoded.appPolicies["com.apple.Terminal"], .off)
        XCTAssertNil(decoded.appPolicies["com.example.a"])
    }

    // MARK: - Upgrade

    func testMergeAddsNewSeedsAndKeepsUserEdits() throws {
        // A settings file from a release that only knew about two terminals,
        // in which the user set one of them back to Normal.
        var stored = AppSettings.defaults
        stored.appPolicies = [
            "com.apple.Terminal": .normal,
            "com.googlecode.iterm2": .suggestOnly,
        ]

        let loaded = AppSettings.load(storedJSON: try encode(stored))

        XCTAssertEqual(
            loaded.policy(for: "com.apple.Terminal"), .normal,
            "a policy the user changed is never overwritten by a seed")
        XCTAssertEqual(loaded.policy(for: "com.mitchellh.ghostty"), .suggestOnly,
                       "a seed the stored file has never seen is added")
        XCTAssertEqual(loaded.policy(for: "com.1password.1password"), .off)
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testMergeKeepsUserPoliciesForAppsThatAreNotSeeded() throws {
        var stored = AppSettings.defaults
        stored.appPolicies["com.example.custom"] = .off
        stored.paused = true
        stored.aggressiveness = .conservative

        let loaded = AppSettings.load(storedJSON: try encode(stored))

        XCTAssertEqual(loaded.policy(for: "com.example.custom"), .off)
        XCTAssertTrue(loaded.paused)
        XCTAssertEqual(loaded.aggressiveness, .conservative)
    }

    // MARK: - Migration

    func testMigratesTheBareAggressivenessKey() {
        let loaded = AppSettings.load(
            storedJSON: nil, legacyAggressiveness: "eager", legacyDebugLogging: true)

        XCTAssertEqual(loaded.aggressiveness, .eager)
        XCTAssertTrue(loaded.debugLogging)
        XCTAssertEqual(loaded.policy(for: "com.apple.Terminal"), .suggestOnly, "seeds still land")
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testMigrationIgnoresAnUnparseableLegacyValue() {
        let loaded = AppSettings.load(storedJSON: nil, legacyAggressiveness: "aggressive")
        XCTAssertEqual(loaded.aggressiveness, .balanced)
    }

    func testUnreadableBlobFallsBackToDefaultsRatherThanThrowing() {
        let loaded = AppSettings.load(
            storedJSON: Data("not json at all".utf8), legacyAggressiveness: "conservative")
        XCTAssertEqual(loaded.aggressiveness, .conservative)
        XCTAssertEqual(loaded.policy(for: "com.bitwarden.desktop"), .off)
    }

    func testFreshInstallHasNoStoredBlobAndNoLegacyKeys() {
        XCTAssertEqual(AppSettings.load(storedJSON: nil), AppSettings.defaults)
    }

    // MARK: - Corruption

    /// The fallback for an unreadable blob is the *permissive* default — every
    /// app Normal, not paused — so the caller has to be able to tell "nothing
    /// stored" from "stored and unreadable" before it overwrites anything.
    func testUnreadableIsDistinguishableFromAbsent() throws {
        XCTAssertFalse(AppSettings.isUnreadable(nil), "a fresh install is not corruption")
        XCTAssertFalse(AppSettings.isUnreadable(try encode(AppSettings.defaults)))
        XCTAssertFalse(
            AppSettings.isUnreadable(Data("{}".utf8)),
            "an empty object is readable: every field falls back on its own")

        XCTAssertTrue(AppSettings.isUnreadable(Data("not json at all".utf8)))
        XCTAssertTrue(AppSettings.isUnreadable(Data()))
        XCTAssertTrue(AppSettings.isUnreadable(Data("[1,2,3]".utf8)), "right JSON, wrong shape")
    }

    /// What would be silently lost if the corrupt blob were overwritten without
    /// a copy: every per-app Off, and the pause switch.
    func testTheFallbackIsMorePermissiveThanAnythingItCouldReplace() {
        let fallback = AppSettings.load(storedJSON: Data("corrupt".utf8))
        XCTAssertEqual(fallback.defaultPolicy, .normal)
        XCTAssertFalse(fallback.paused)
        XCTAssertEqual(fallback.policy(for: "com.example.the.user.switched.this.off"), .normal)
    }
}
