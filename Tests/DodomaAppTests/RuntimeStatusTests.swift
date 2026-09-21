import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The lock box `harf --status` reads out of the running copy, and the wire
/// format it travels in.
///
/// Everything here is about a value crossing a process boundary, so the tests
/// are about what survives the crossing and what must not be believed on the
/// other side: a blob from another build, a blob from something that is not
/// Harf at all, and a read that races a publish.
final class RuntimeStatusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RuntimeStatus.forget()
    }

    override func tearDown() {
        RuntimeStatus.forget()
        super.tearDown()
    }

    private func snapshot(
        pid: Int32 = 4321,
        accessibility: Bool = true,
        version: String = Dodoma.version,
        settings: AppSettings = .defaults
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            appVersion: version,
            pid: pid,
            permissions: PermissionState(accessibility: accessibility, inputMonitoring: true),
            capturing: true,
            paused: false,
            secureInput: false,
            degraded: false,
            loginItem: .enabled,
            settings: settings)
    }

    /// A copy that has not finished its first permission poll has nothing to
    /// say, and `--status` has to be able to tell that from "the app says no".
    func testNothingIsPublishedToBeginWith() {
        XCTAssertNil(RuntimeStatus.snapshot)
        XCTAssertTrue(RuntimeStatus.encoded().isEmpty)
    }

    func testAPublishedSnapshotIsReadBack() {
        RuntimeStatus.publish(snapshot(pid: 99))

        XCTAssertEqual(RuntimeStatus.snapshot?.pid, 99)
    }

    /// The whole point of the box: what the app published comes out of the
    /// bytes the port hands over, field for field.
    func testASnapshotSurvivesAJSONRoundTrip() {
        var settings = AppSettings.defaults
        settings.paused = true
        settings.aggressiveness = .eager
        let published = snapshot(settings: settings)
        RuntimeStatus.publish(published)

        XCTAssertEqual(RuntimeStatus.decode(RuntimeStatus.encoded()), published)
    }

    /// Two builds can be installed at once — the cask's `harf` on the PATH and
    /// an older `/Applications/Harf.app` — and the older one is the copy that
    /// holds the name. A snapshot whose shape this build does not know is not a
    /// snapshot; it renders as *unknown*, which is true, rather than as fields
    /// read out of the wrong offsets.
    func testAWireVersionFromAnotherBuildDecodesToNothing() throws {
        var stale = snapshot()
        stale.wire = RuntimeSnapshot.wireVersion + 1

        XCTAssertNil(RuntimeStatus.decode(try JSONEncoder().encode(stale)))
    }

    func testGarbageDecodesToNothing() {
        XCTAssertNil(RuntimeStatus.decode(Data("not json at all".utf8)))
        XCTAssertNil(RuntimeStatus.decode(Data()))
    }

    /// The port callback reads this while `refreshPermissions` writes it every
    /// two seconds, on two different threads. A reader must always see one
    /// whole snapshot — never half of one and half of the next.
    func testConcurrentPublishAndReadDoNotTear() {
        let first = snapshot(pid: 1, accessibility: true)
        let second = snapshot(pid: 2, accessibility: false)
        RuntimeStatus.publish(first)

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            if iteration.isMultiple(of: 2) {
                RuntimeStatus.publish(iteration.isMultiple(of: 4) ? first : second)
            } else {
                guard let read = RuntimeStatus.decode(RuntimeStatus.encoded()) else {
                    return XCTFail("a published snapshot must always decode")
                }
                XCTAssertEqual(read.permissions.accessibility, read.pid == 1)
            }
        }
    }

    /// The reload arm of the port has to reach `SettingsStore` without the
    /// callback — a capture-free C function pointer — knowing anything about
    /// it, and without a test having to touch the shared store.
    func testTheReloadHandlerIsWhatTheRequestRuns() {
        var ran = 0
        RuntimeStatus.setReloadHandler { ran += 1 }
        RuntimeStatus.handleReloadRequest()
        XCTAssertEqual(ran, 1)

        RuntimeStatus.setReloadHandler(nil)
        RuntimeStatus.handleReloadRequest()
        XCTAssertEqual(ran, 1, "a request after the app has gone must do nothing")
    }

    /// The same for the vocabulary arm, which reaches the lexicon the app owns
    /// without the callback knowing that it exists.
    func testTheVocabularyHandlerIsWhatTheRequestRuns() {
        var ran = 0
        RuntimeStatus.setVocabularyHandler { ran += 1 }
        RuntimeStatus.handleVocabularyRequest()
        XCTAssertEqual(ran, 1)

        RuntimeStatus.setVocabularyHandler(nil)
        RuntimeStatus.handleVocabularyRequest()
        XCTAssertEqual(ran, 1, "a request after the app has gone must do nothing")
    }

    /// Installing one must not install the other: `applicationWillTerminate`
    /// clears both, and a handler left behind would reach into a pipeline that
    /// is already half torn down.
    func testTheTwoHandlersAreSeparate() {
        var settings = 0
        var vocabulary = 0
        RuntimeStatus.setReloadHandler { settings += 1 }
        RuntimeStatus.setVocabularyHandler { vocabulary += 1 }

        RuntimeStatus.handleReloadRequest()
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(vocabulary, 0)

        RuntimeStatus.forget()
        RuntimeStatus.handleReloadRequest()
        RuntimeStatus.handleVocabularyRequest()
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(vocabulary, 0)
    }

    /// The raw values are the wire, not a Swift detail: an older copy of Harf
    /// answers a newer `--status` and the login-item word has to still mean
    /// what it meant. Renaming a case must not silently rename the wire.
    func testTheLoginItemStatusRawValuesAreTheWireNames() {
        XCTAssertEqual(LoginItemStatus.enabled.rawValue, "enabled")
        XCTAssertEqual(LoginItemStatus.disabled.rawValue, "disabled")
        XCTAssertEqual(LoginItemStatus.requiresApproval.rawValue, "requiresApproval")
        XCTAssertEqual(LoginItemStatus.notFound.rawValue, "notFound")
        XCTAssertEqual(LoginItemStatus.unavailable.rawValue, "unavailable")
    }
}
