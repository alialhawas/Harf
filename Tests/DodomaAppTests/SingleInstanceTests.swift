import XCTest

@testable import DodomaAppKit

/// Which of the copies of Harf on the machine this one has to stand down for,
/// what it tells the user about the one that won, and how it stops it.
///
/// Two ways a copy shows up in the list, and the tests carry both: the bundled
/// launch LaunchServices knows by identifier, and the bare executable started
/// from a shell, which LaunchServices records with no identifier at all.
final class SingleInstanceTests: XCTestCase {
    /// Where this process would be running from, in the tests that need the
    /// executable comparison to have something to compare against. A constant
    /// rather than the real `Bundle.main` path, so the truth table is the same
    /// on every machine and under every runner.
    private let ownExecutable = "/Applications/Harf.app/Contents/MacOS/Harf"

    /// A copy launched from a bundle. LaunchServices gives it the identifier,
    /// so this is the shape the original guard was written against.
    private func instance(_ pid: pid_t, _ path: String? = nil) -> SingleInstance.Instance {
        SingleInstance.Instance(
            pid: pid, bundleID: SingleInstance.bundleID,
            executablePath: path.map { "\($0)/Contents/MacOS/Harf" }, path: path)
    }

    /// A copy started by running the executable itself — `harf` on the PATH.
    /// No bundle identifier, no bundle path, only the executable.
    private func bare(_ pid: pid_t, _ executablePath: String?) -> SingleInstance.Instance {
        SingleInstance.Instance(
            pid: pid, bundleID: nil, executablePath: executablePath, path: nil)
    }

    /// The scan, resolved against a known executable of our own. The default
    /// would read `Bundle.main`, which under `swift test` is the test runner.
    private func conflict(
        among instances: [SingleInstance.Instance], own pid: pid_t, ownExecutable: String?
    ) -> SingleInstance.Conflict? {
        SingleInstance.conflict(among: instances, own: pid, ownExecutable: ownExecutable)
    }

    /// A bootstrap name no other process could be holding. Tests must never
    /// touch the production name: claiming it would take it from the
    /// developer's running Harf, and probing it would answer differently
    /// depending on whether that copy happened to be up.
    private func uniqueName() -> String {
        "com.ali.dodoma.test.\(UUID().uuidString)"
    }

    // MARK: - Bundled copies

    /// The ordinary launch: the list holds nobody but this process, so the app
    /// carries on and starts its tap.
    func testFindingOnlyItselfIsNoConflict() {
        XCTAssertNil(conflict(among: [instance(42)], own: 42, ownExecutable: ownExecutable))
    }

    func testAnEmptyListIsNoConflict() {
        XCTAssertNil(conflict(among: [], own: 42, ownExecutable: ownExecutable))
    }

    /// The bug this exists for: `/Applications/Harf.app` is already up and a
    /// workspace build is being launched over it. The path comes back with the
    /// pid so the alert can name the copy that won.
    func testAnotherPidIsAConflictAndCarriesItsPath() {
        let other = instance(7, "/Applications/Harf.app")
        XCTAssertEqual(
            conflict(among: [other, instance(42)], own: 42, ownExecutable: ownExecutable)?.instance,
            other)
    }

    /// Nothing is gained by naming all of them; the first is enough to say who
    /// to quit.
    func testSeveralOthersReportTheFirst() {
        let first = instance(7, "/Applications/Harf.app")
        let second = instance(9, "/tmp/build/Harf.app")
        XCTAssertEqual(
            conflict(
                among: [first, second, instance(42)], own: 42, ownExecutable: ownExecutable
            )?.instance, first)
    }

    /// The scan is best-effort and runs before this process is necessarily in
    /// the list, so an answer that omits us is expected rather than
    /// exceptional. Anyone else in it is still a second copy.
    func testOwnPidAbsentStillReportsTheOther() {
        let other = instance(7, "/Applications/Harf.app")
        XCTAssertEqual(
            conflict(among: [other], own: 42, ownExecutable: ownExecutable)?.instance, other)
    }

    /// Order is the list's, not the pids': `conflict` must not sort, or the
    /// alert would name a copy other than the one the system reported first.
    func testTheFirstIsPositionalNotTheLowestPid() {
        let later = instance(99, "/Applications/Harf.app")
        XCTAssertEqual(
            conflict(among: [later, instance(7)], own: 42, ownExecutable: ownExecutable)?.instance,
            later)
    }

    // MARK: - Copies started from a shell

    /// The case that got past the identifier-only guard for sixteen hours. The
    /// cask puts the executable on the PATH as `harf`; started that way there
    /// is no bundle, so LaunchServices records the process with no identifier
    /// and an identifier lookup returns an empty list. The executable is still
    /// the app's, and the symlink resolves to the one inside the bundle — the
    /// same path this process is running from.
    func testABareExecutableRunningTheSameBinaryIsStillAConflict() {
        let other = bare(7, ownExecutable)
        let found = conflict(
            among: [other, instance(42)], own: 42, ownExecutable: ownExecutable)
        XCTAssertEqual(found?.instance, other)
        XCTAssertEqual(found?.match, .executablePath)
    }

    /// The identifier is checked first, so a bundled copy is reported as one
    /// even though its executable is also called Harf — the alert for the two
    /// says different things.
    func testABundledCopyIsMatchedByItsIdentifierNotItsExecutable() {
        let other = instance(7, "/Applications/Harf.app")
        XCTAssertEqual(
            conflict(among: [other], own: 42, ownExecutable: ownExecutable)?.match,
            .bundleIdentifier)
    }

    /// A missing identifier is the normal state of most non-app processes on
    /// the machine. Only the executable makes one of them ours.
    func testAnUnrelatedProcessWithNoIdentifierIsNotAConflict() {
        XCTAssertNil(
            conflict(among: [bare(7, "/usr/bin/ssh")], own: 42, ownExecutable: ownExecutable))
    }

    /// `harf` is a plausible name for somebody else's tool, and the old
    /// basename test matched any of them — then told the user to go and quit
    /// it. It could never cause a wrongful refusal, because the bootstrap name
    /// is what decides, but an alert naming an innocent process is worse than
    /// one naming nothing.
    func testAnUnrelatedProcessNamedHarfElsewhereIsNotAConflict() {
        XCTAssertNil(
            conflict(
                among: [bare(7, "/usr/local/bin/harf")], own: 42, ownExecutable: ownExecutable))
    }

    func testAProcessWithNeitherIdentifierNorExecutableIsNotAConflict() {
        XCTAssertNil(conflict(among: [bare(7, nil)], own: 42, ownExecutable: ownExecutable))
    }

    /// Another app's bundle is not this one however busy the machine is.
    func testAnotherApplicationIsNotAConflict() {
        let safari = SingleInstance.Instance(
            pid: 7, bundleID: "com.apple.Safari",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", path:
                "/Applications/Safari.app")
        XCTAssertNil(conflict(among: [safari], own: 42, ownExecutable: ownExecutable))
    }

    /// With no path of our own to compare against, the name is all there is,
    /// and `/opt/homebrew/bin/harf` is the name the user types and the name
    /// that ends up in the process table. Lowercase, because the cask links it
    /// that way; inside the bundle the same file is `Harf`.
    func testWithNoOwnPathTheLowercaseNameOnThePathStillMatches() {
        let found = conflict(
            among: [bare(7, "/opt/homebrew/bin/harf")], own: 42, ownExecutable: nil)
        XCTAssertEqual(found?.match, .executablePath)
    }

    /// Its own pid is skipped whichever way it would have matched, or the
    /// bare-binary copy would refuse to start against itself.
    func testABareExecutableDoesNotConflictWithItself() {
        XCTAssertNil(
            conflict(among: [bare(42, ownExecutable)], own: 42, ownExecutable: ownExecutable))
    }

    // MARK: - What the user is told

    /// A copy with no menu bar icon to quit and no Dock tile to find needs the
    /// command that stops it, or the alert is a dead end. `harf --quit` and not
    /// `pkill`, so the copy saves what it has learned on the way out.
    func testTheAlertNamesTheTerminalForABareExecutable() {
        let text = SingleInstance.alertText(
            for: SingleInstance.Conflict(
                instance: bare(7, ownExecutable), match: .executablePath))
        XCTAssertTrue(text.contains("terminal"), text)
        XCTAssertTrue(text.contains("harf --quit"), text)
    }

    /// A bundled copy is quit the ordinary way, and the alert says which one
    /// rather than reaching for a shell command.
    func testTheAlertNamesTheBundleForABundledCopy() {
        let text = SingleInstance.alertText(
            for: SingleInstance.Conflict(
                instance: instance(7, "/Applications/Harf.app"), match: .bundleIdentifier))
        XCTAssertTrue(text.contains("/Applications/Harf.app"), text)
        XCTAssertFalse(text.contains("terminal"), text)
    }

    /// The port is the decision and the scan is only a description, so the two
    /// can disagree: the port can be taken by a copy the scan does not see, or
    /// by a build at a path this one does not share. The alert still has to be
    /// worth reading.
    func testTheAlertStandsAloneWhenTheOtherCopyCannotBeNamed() {
        let text = SingleInstance.alertText(for: nil)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("harf --quit"), text)
    }

    /// A failed registration that nobody is answering on is not another copy,
    /// and saying it is would send the user hunting for a process that does not
    /// exist. The only useful thing to say is the way past it.
    func testTheUnclaimableAlertOffersTheOverrideRatherThanNamingACopy() {
        XCTAssertTrue(
            SingleInstance.unclaimableAlertText.contains(SingleInstance.overrideEnvironmentKey),
            SingleInstance.unclaimableAlertText)
        XCTAssertFalse(SingleInstance.unclaimableAlertText.contains("--quit"))
    }

    // MARK: - The name itself

    /// The claim is per-process, not per-call: `CFMessagePortCreateLocal` hands
    /// back the port it already made when the same process asks for the same
    /// name again. That is what makes the guard idempotent, and it is the only
    /// half of the mechanism a test can reach.
    ///
    /// The half that matters — a *second process* getting nil — cannot be
    /// tested from inside one process, because a bootstrap name is only taken
    /// as far as other processes are concerned. It is covered by the manual
    /// checklist instead: launch two copies and watch the second refuse.
    func testClaimingTheSameNameTwiceInOneProcessSucceedsBothTimes() {
        let name = uniqueName()
        XCTAssertTrue(SingleInstance.claimPort(name: name))
        XCTAssertTrue(SingleInstance.claimPort(name: name))
    }

    /// What `--status` reads. A name nobody registered answers nobody.
    func testANameNobodyHasClaimedIsNotHeld() {
        XCTAssertFalse(SingleInstance.isHeld(name: uniqueName()))
    }

    /// And once it is claimed it is, so `--status` and the guard agree about
    /// what "running" means instead of the identifier lookup's answer, which
    /// was "no" for every copy started from a shell.
    func testAClaimedNameIsHeld() {
        let name = uniqueName()
        SingleInstance.claimPort(name: name)
        XCTAssertTrue(SingleInstance.isHeld(name: name))
    }

    // MARK: - The override

    /// A guard that refuses on every failure to register — including failures
    /// that are not another copy at all — needs a way past it, or one bad
    /// bootstrap namespace is an app that can never be started again.
    func testTheOverrideIsOffUnlessTheVariableIsExactlyOne() {
        XCTAssertFalse(SingleInstance.isOverridden(environment: [:]))
        XCTAssertFalse(
            SingleInstance.isOverridden(
                environment: [SingleInstance.overrideEnvironmentKey: "yes"]))
    }

    func testTheOverrideIsOnWhenTheVariableIsOne() {
        XCTAssertTrue(
            SingleInstance.isOverridden(environment: [SingleInstance.overrideEnvironmentKey: "1"]))
    }

    // MARK: - Quitting the copy that won

    /// The message the port route prints. It is the good case: the running copy
    /// goes through `applicationWillTerminate` and writes out what it learned.
    func testAMessagedQuitReportsThatHarfIsQuitting() {
        XCTAssertEqual(SingleInstance.quitMessage(for: .messaged), "Harf is quitting.")
    }

    /// The fallback is for a build too old to answer on the name. It still
    /// quits, but the lexicon flush is not guaranteed, and the user should hear
    /// that rather than discover it.
    func testTerminatingAnOlderBuildSaysWhatMayBeLost() {
        let text = SingleInstance.quitMessage(for: .terminated(4321))
        XCTAssertTrue(text.contains("4321"), text)
        XCTAssertTrue(text.contains("lost"), text)
    }

    /// Nothing running is the state `--quit` was asked for, so it is not an
    /// error: `make install` and `uninstall.sh` both run it on machines where
    /// it is already true.
    func testNothingRunningIsNotAFailure() {
        XCTAssertEqual(SingleInstance.quitExitCode(for: .notRunning), 0)
        XCTAssertEqual(SingleInstance.quitMessage(for: .notRunning), "Harf is not running.")
    }

    /// A copy that is running and would not stop is the one case a script has
    /// to be able to notice, so `make install` can fall back to `pkill`.
    func testARefusedQuitExitsNonZero() {
        XCTAssertNotEqual(SingleInstance.quitExitCode(for: .failed("busy")), 0)
    }

    /// The reason is passed through rather than swallowed: "could not quit" on
    /// its own leaves nothing to act on.
    func testAFailedQuitCarriesTheReason() {
        XCTAssertTrue(
            SingleInstance.quitMessage(for: .failed("process 9 refused")).contains(
                "process 9 refused"))
    }

    // MARK: - Which bundle the executable belongs to

    /// `harf` on the PATH is a symlink into `Harf.app`, and a process started
    /// through it has no bundle identifier of its own — so `harf --status`
    /// reported start-at-login as unavailable to a user who was running the
    /// bundled copy. The path arithmetic that finds the bundle again is the
    /// part that can break, so it is the part with a test; the launch it exists
    /// for cannot be reproduced inside a test process.
    ///
    /// Lives here rather than with the login-item mapping tests because it is
    /// the same question this file exists for — which copy of Harf is this —
    /// asked of a path instead of a process.
    func testTheEnclosingBundleIsFoundFromTheExecutableInsideIt() throws {
        let root = try makeTemporaryDirectory()
        let app = root.appendingPathComponent("Harf.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Harf")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try infoPlist(identifier: "com.ali.dodoma")
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        XCTAssertEqual(
            LoginItem.bundleIdentifier(forExecutableAt: executable), "com.ali.dodoma")
    }

    /// `swift run` and a plain `.build/release/Harf` have no bundle above them
    /// at all, and inventing one would be worse than saying so.
    func testAnExecutableWithNoBundleAboveItHasNoIdentifier() throws {
        let root = try makeTemporaryDirectory()
        let executable = root.appendingPathComponent("Harf")
        try Data().write(to: executable)

        XCTAssertNil(LoginItem.bundleIdentifier(forExecutableAt: executable))
    }

    /// A directory called `.app` that is not a bundle is not an answer. The
    /// walk stops at the first `.app` either way, so a wrong one there must
    /// come back nil rather than reaching further up for a right one.
    func testADirectoryNamedAppWithNoBundleInsideItHasNoIdentifier() throws {
        let root = try makeTemporaryDirectory()
        let executable = root.appendingPathComponent("Harf.app/Contents/MacOS/Harf")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)

        XCTAssertNil(LoginItem.bundleIdentifier(forExecutableAt: executable))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func infoPlist(identifier: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleExecutable</key><string>Harf</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """.utf8)
    }
}
