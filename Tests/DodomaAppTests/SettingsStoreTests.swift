import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The settings window has no Apply button: every control writes straight
/// through `SettingsStore` and reads back what was persisted. These are the
/// round trips that makes true.
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    /// A bundle identifier that is not in `PolicySeeds`, so a removal is not
    /// immediately undone by the seed merge on the next load.
    private let unseeded = "com.example.editor"

    override func setUp() {
        super.setUp()
        suiteName = "com.ali.dodoma.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults)
    }

    /// Reads the blob back through a second store, which is the only honest
    /// test of persistence: the first store answers from its own cache.
    private func reloaded() -> AppSettings {
        makeStore().settings
    }

    // MARK: - Per-app policies

    func testSettingAPolicySurvivesAReload() {
        let store = makeStore()
        store.setPolicy(.off, for: unseeded)

        XCTAssertEqual(store.policy(for: unseeded), .off)
        XCTAssertEqual(reloaded().policy(for: unseeded), .off)
    }

    func testRemovingAPolicyRevertsTheAppToTheDefault() {
        let store = makeStore()
        store.setPolicy(.off, for: unseeded)
        store.removePolicy(for: unseeded)

        XCTAssertNil(store.settings.appPolicies[unseeded], "the override is gone, not rewritten")
        XCTAssertEqual(store.policy(for: unseeded), store.settings.defaultPolicy)
        XCTAssertNil(reloaded().appPolicies[unseeded])
    }

    /// Removing a *seeded* row is only good until the next launch. Presence in
    /// the map is how `mergingSeedDefaults` records "the user has decided", so
    /// deleting the row deletes the decision and the seed comes back — which is
    /// the safe direction for a terminal.
    func testRemovingASeededPolicyLetsTheSeedReturnOnTheNextLoad() {
        let store = makeStore()
        store.removePolicy(for: "com.apple.Terminal")
        XCTAssertNil(store.settings.appPolicies["com.apple.Terminal"])

        XCTAssertEqual(reloaded().policy(for: "com.apple.Terminal"), .suggestOnly)
    }

    func testChangingTheDefaultPolicyAppliesToEveryUnlistedApp() {
        let store = makeStore()
        store.setDefaultPolicy(.suggestOnly)

        XCTAssertEqual(store.policy(for: unseeded), .suggestOnly)
        XCTAssertEqual(reloaded().defaultPolicy, .suggestOnly)
        // Seeded entries are overrides and are unmoved by the default.
        XCTAssertEqual(reloaded().policy(for: "com.1password.1password"), .off)
    }

    // MARK: - Accessibility verification skips

    func testAXVerifySkipAddAndRemoveRoundTrip() {
        let store = makeStore()
        store.setAXVerifySkip(store.settings.axVerifySkip.union(["com.google.Chrome"]))

        XCTAssertTrue(store.skipsAXVerify("com.google.Chrome"))
        XCTAssertEqual(reloaded().axVerifySkip, ["com.google.Chrome"])

        store.setAXVerifySkip(store.settings.axVerifySkip.subtracting(["com.google.Chrome"]))

        XCTAssertFalse(store.skipsAXVerify("com.google.Chrome"))
        XCTAssertTrue(reloaded().axVerifySkip.isEmpty)
    }

    // MARK: - Scalars

    func testAggressivenessAndPauseRoundTrip() {
        let store = makeStore()
        store.setAggressiveness(.eager)
        store.setPaused(true)

        XCTAssertEqual(reloaded().aggressiveness, .eager)
        XCTAssertTrue(reloaded().paused)
    }

    /// The getter is the OR of the blob and the bare `defaults write` key, so
    /// switching the toggle off has to clear both or it looks broken.
    func testSwitchingDebugLoggingOffAlsoClearsTheBareOverrideKey() {
        defaults.set(true, forKey: SettingsStore.Key.debugLogging)
        let store = makeStore()
        XCTAssertTrue(store.debugLogging, "the bare key alone turns it on")

        store.setDebugLogging(false)

        XCTAssertFalse(store.debugLogging)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.debugLogging))
    }

    func testSwitchingDebugLoggingOnPersists() {
        let store = makeStore()
        store.setDebugLogging(true)

        XCTAssertTrue(store.debugLogging)
        XCTAssertTrue(reloaded().debugLogging)
    }

    // MARK: - Change notification

    func testEveryWriteNotifiesWithThePersistedValue() {
        let store = makeStore()
        var seen: [AppSettings] = []
        store.onChange = { seen.append($0) }

        store.setAggressiveness(.conservative)
        store.setPolicy(.suggestOnly, for: unseeded)

        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.last?.aggressiveness, .conservative)
        XCTAssertEqual(seen.last?.appPolicies[unseeded], .suggestOnly)
        XCTAssertEqual(seen.last, store.settings)
    }

    func testAWriteThatChangesNothingIsNotAnnounced() {
        let store = makeStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.setAggressiveness(store.settings.aggressiveness)

        XCTAssertEqual(changes, 0)
    }

    // MARK: - Re-reading what somebody else wrote

    /// Writes the blob behind the store's back, the way `harf --set` in another
    /// process does. Not through a second `SettingsStore`, because that would
    /// also exercise the seed merge and the corrupt-blob rescue; this is only
    /// the bytes arriving.
    private func externalWrite(_ body: (inout AppSettings) -> Void) throws {
        var settings = AppSettings.defaults
        body(&settings)
        defaults.set(try JSONEncoder().encode(settings), forKey: SettingsStore.Key.settings)
    }

    /// The defect behind `harf --set paused yes` doing nothing to a running app:
    /// the store cached at init and never looked again.
    func testReloadPicksUpAnExternalWriteAndAnnouncesItOnce() throws {
        let store = makeStore()
        var seen: [AppSettings] = []
        store.onChange = { seen.append($0) }

        try externalWrite { $0.aggressiveness = .eager }

        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.settings.aggressiveness, .eager)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.last?.aggressiveness, .eager)
    }

    /// The reload message is fire-and-forget and cheap to send, so it is sent on
    /// every write — including the ones that change nothing. Announcing those
    /// would rebuild the pipeline's settings and reset the settings window's
    /// controls for no reason.
    func testReloadAnnouncesNothingWhenTheBlobHasNotChanged() {
        let store = makeStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }

        XCTAssertFalse(store.reload())

        XCTAssertEqual(changes, 0)
    }

    /// The fallback for an unreadable blob is the *permissive* default — not
    /// paused, every app normal — so a reload that applied it would un-pause a
    /// running app and switch capture back on in every application the user had
    /// switched off. A reload has nothing to restore from and no user watching:
    /// the only safe answer is to keep what is in memory and say so in the log.
    func testReloadIgnoresAnUnreadableBlobRatherThanRestoringTheDefaults() {
        let store = makeStore()
        store.setPaused(true)
        defaults.set(Data("not json".utf8), forKey: SettingsStore.Key.settings)
        var changes = 0
        store.onChange = { _ in changes += 1 }

        XCTAssertFalse(store.reload())

        XCTAssertTrue(store.paused, "the running copy stays paused")
        XCTAssertEqual(changes, 0)
        XCTAssertNil(
            defaults.data(forKey: SettingsStore.Key.corruptSettings),
            "a reload does not move the blob aside; only a launch does, where there is a user")
    }

    /// The other half of the same defect, and the more destructive half: a menu
    /// write used to copy the store's stale cache and persist it, so the
    /// external change was not merely missed, it was overwritten. Each write now
    /// starts from what is actually on disk.
    func testAMenuWriteAfterAnExternalWriteKeepsBoth() throws {
        let store = makeStore()
        try externalWrite { $0.paused = true }

        store.setAggressiveness(.eager)

        XCTAssertTrue(store.settings.paused)
        XCTAssertEqual(store.settings.aggressiveness, .eager)
        XCTAssertTrue(reloaded().paused)
        XCTAssertEqual(reloaded().aggressiveness, .eager)
    }

    /// The inverse case, and the one that only bites now that a reload exists.
    /// A menu write that puts a setting back to the value already in memory
    /// changes nothing in memory — but if the blob says otherwise it has to be
    /// written anyway, or the next reload (from any later `harf --set`) would
    /// hand the external value back and silently undo the user's click.
    func testAMenuWriteThatUndoesAnExternalWriteStillReachesTheBlob() throws {
        let store = makeStore()
        try externalWrite { $0.paused = true }
        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.setPaused(false)

        XCTAssertFalse(reloaded().paused, "the blob agrees with what is in memory")
        XCTAssertFalse(store.reload(), "so a later reload has nothing to undo")
        XCTAssertFalse(store.paused)
        XCTAssertEqual(changes, 0, "nothing in memory moved, so nobody is told")
    }

    // MARK: - Onboarding flag

    func testTheOnboardingFlagStartsUnsetAndSurvivesAReload() {
        let store = makeStore()
        XCTAssertFalse(store.onboardingCompleted)

        store.setOnboardingCompleted(true)

        XCTAssertTrue(store.onboardingCompleted)
        XCTAssertTrue(makeStore().onboardingCompleted)
    }

    /// The flag is not in the settings blob, so restoring an unreadable blob to
    /// the defaults must not walk the user back through the walkthrough.
    func testTheOnboardingFlagOutlivesACorruptSettingsBlob() {
        makeStore().setOnboardingCompleted(true)
        defaults.set(Data("not json".utf8), forKey: SettingsStore.Key.settings)

        let store = makeStore()

        XCTAssertEqual(store.settings.aggressiveness, .balanced, "the blob was restored")
        XCTAssertTrue(store.onboardingCompleted)
    }
}
