import DodomaCore
import XCTest

@testable import DodomaAppKit

/// What `harf --status` prints, held to one rule: every line is either something
/// the running copy said, or it is marked as something nobody could answer.
///
/// The screen used to be assembled out of whatever the *command's* own process
/// could see. `Permissions.current()` reads the grants of whoever calls it, so
/// run from a terminal that has been granted Accessibility it printed
/// `accessibility yes` while the app was logging `accessibility=false`; the
/// settings lines came from the saved blob, which is not what a running copy is
/// necessarily enforcing. Both are tested here as the pure renderer they now go
/// through, because neither can be reproduced by launching a copy of Harf from
/// a test.
final class CLIStatusTests: XCTestCase {
    private let version = "1.0.0"

    private func snapshot(
        appVersion: String? = nil,
        pid: Int32 = 4321,
        accessibility: Bool = true,
        inputMonitoring: Bool = true,
        capturing: Bool = true,
        paused: Bool = false,
        secureInput: Bool = false,
        degraded: Bool = false,
        loginItem: LoginItemStatus = .enabled,
        settings: AppSettings = .defaults
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            appVersion: appVersion ?? version,
            pid: pid,
            permissions: PermissionState(
                accessibility: accessibility, inputMonitoring: inputMonitoring),
            capturing: capturing,
            paused: paused,
            secureInput: secureInput,
            degraded: degraded,
            loginItem: loginItem,
            settings: settings)
    }

    private func text(
        running: Bool = true,
        snapshot: RuntimeSnapshot?,
        stored: AppSettings = .defaults,
        localLoginItem: LoginItemStatus = .unavailable,
        owningBundleIdentifier: String? = nil
    ) -> String {
        CLIConfig.statusText(
            version: version,
            running: running,
            snapshot: snapshot,
            stored: stored,
            localLoginItem: localLoginItem,
            owningBundleIdentifier: owningBundleIdentifier,
            vocabulary: CLIConfig.Vocabulary(
                learned: 8, manual: 0, pending: 394, file: "/tmp/lexicon.json"))
    }

    /// Finds one `  key   value` line, so an assertion is about the value of a
    /// named line rather than about the substring appearing anywhere on screen.
    private func value(of key: String, in text: String) -> String? {
        text.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key) }
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .dropFirst(key.count)
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    // MARK: - Permissions belong to the running copy

    /// The grants reported are the ones the app has, whatever the terminal
    /// running the command happens to have been granted.
    func testTheRunningAppsGrantsAreReportedNotThisProcesss() {
        let printed = text(snapshot: snapshot(accessibility: true, inputMonitoring: true))

        XCTAssertEqual(value(of: "accessibility", in: printed), "yes")
        XCTAssertEqual(value(of: "input monitoring", in: printed), "yes")
    }

    func testMissingGrantsReadAsNoWhenTheAppAnswered() {
        let printed = text(snapshot: snapshot(accessibility: false, inputMonitoring: false))

        XCTAssertEqual(value(of: "accessibility", in: printed), "no")
        XCTAssertEqual(value(of: "input monitoring", in: printed), "no")
    }

    /// The copy is there but its main run loop is busy — a modal alert, an
    /// injection holding main — so nothing came back. "no" would send the reader
    /// to System Settings to re-grant a permission that was never revoked.
    func testAnUnansweredRequestReadsAsUnknownRatherThanNo() {
        let printed = text(running: true, snapshot: nil)

        XCTAssertEqual(value(of: "accessibility", in: printed), "unknown")
        XCTAssertEqual(value(of: "input monitoring", in: printed), "unknown")
        XCTAssertEqual(value(of: "state", in: printed), "unknown")
        XCTAssertTrue(printed.contains("did not answer"), printed)
        XCTAssertTrue(printed.contains(SingleInstance.portName), printed)
        XCTAssertTrue(printed.contains("saved"), printed)
    }

    /// Nothing is running, so the settings on screen are the saved ones and the
    /// screen has to say so — otherwise it reads as a report on a running app.
    func testNotRunningSaysSoAndFallsBackToTheSavedSettings() {
        var stored = AppSettings.defaults
        stored.paused = true

        let printed = text(running: false, snapshot: nil, stored: stored)

        XCTAssertEqual(value(of: "running", in: printed), "no")
        XCTAssertTrue(printed.lowercased().contains("nothing is running"), printed)
        XCTAssertTrue(printed.contains("saved"), printed)
        XCTAssertEqual(value(of: "paused", in: printed), "yes")
        XCTAssertEqual(value(of: "accessibility", in: printed), "unknown")
    }

    /// A pid is the one thing that makes "running yes" checkable against `ps`,
    /// and it is the number the single-instance alert talks about.
    func testTheRunningLineCarriesThePidWhenTheAppAnswered() {
        XCTAssertEqual(value(of: "running", in: text(snapshot: snapshot(pid: 777))),
                       "yes (process 777)")
    }

    // MARK: - The state line

    /// Literally the menu's own sentence, from the menu's own renderer. Two
    /// spellings of "what is Harf doing" would drift apart.
    func testTheStateLineIsTheSentenceTheMenuShows() {
        let published = snapshot(capturing: true, paused: false)

        XCTAssertEqual(
            value(of: "state", in: text(snapshot: published)),
            MenuBarController.statusText(
                for: published.permissions, capturing: published.capturing,
                paused: published.paused, secureInput: published.secureInput,
                degraded: published.degraded))
    }

    func testTheStateLineReportsASecureInputPauseTheWayTheMenuDoes() {
        let printed = text(snapshot: snapshot(secureInput: true))

        XCTAssertEqual(value(of: "state", in: printed), "Paused — secure input")
    }

    // MARK: - Settings come from the app

    /// The blob is what is saved; the snapshot is what is being enforced. Every
    /// settings line reports the second, because the question `--status` answers
    /// is "why is the app behaving like this".
    func testTheSettingsLinesComeFromTheAppNotTheBlob() {
        var applied = AppSettings.defaults
        applied.paused = true
        applied.aggressiveness = .eager
        var stored = AppSettings.defaults
        stored.paused = false
        stored.aggressiveness = .conservative

        let printed = text(snapshot: snapshot(settings: applied), stored: stored)

        XCTAssertEqual(value(of: "paused", in: printed), "yes")
        XCTAssertEqual(value(of: "sensitivity", in: printed), "eager")
    }

    /// And when the two disagree the screen says so, because that is a state
    /// with a cause worth chasing: a write that never reached the app, or a copy
    /// that has not reloaded.
    func testADisagreementBetweenSavedAndRunningSettingsIsNamed() {
        var stored = AppSettings.defaults
        stored.aggressiveness = .conservative

        let printed = text(snapshot: snapshot(settings: .defaults), stored: stored)

        XCTAssertTrue(printed.contains("saved settings"), printed)
        XCTAssertTrue(printed.contains("differ"), printed)
    }

    func testNoDisagreementIsMentionedWhenTheTwoAgree() {
        let printed = text(snapshot: snapshot(settings: .defaults), stored: .defaults)

        XCTAssertFalse(printed.contains("differ"), printed)
    }

    /// Two builds on one machine: the cask's `harf` on the PATH and an older
    /// `/Applications/Harf.app` holding the port. Every line below then
    /// describes a build the reader is not looking at.
    func testAVersionMismatchIsNamed() {
        let printed = text(snapshot: snapshot(appVersion: "0.9.0"))

        XCTAssertTrue(printed.contains("0.9.0"), printed)
        XCTAssertTrue(printed.contains("different build"), printed)
    }

    func testNoVersionMismatchIsMentionedWhenTheBuildsMatch() {
        XCTAssertFalse(text(snapshot: snapshot()).contains("different build"))
    }

    // MARK: - Launch at login

    /// launchd only answers about `Bundle.main`, and for the `harf` symlink that
    /// is `/opt/homebrew/bin`. When the app answers, its own reading is the
    /// truth and the local one is irrelevant.
    func testTheLoginItemLineComesFromTheAppWhenItAnswered() {
        let printed = text(
            snapshot: snapshot(loginItem: .requiresApproval), localLoginItem: .unavailable,
            owningBundleIdentifier: "com.ali.dodoma")

        XCTAssertEqual(
            value(of: "launch at login", in: printed), CLIConfig.label(.requiresApproval))
    }

    /// With nobody answering, the line falls back to what this process can see —
    /// which for the command line is "I cannot answer for that bundle", named.
    func testTheLoginItemLineExplainsItselfWhenNobodyAnswered() {
        let printed = text(
            running: false, snapshot: nil, localLoginItem: .unavailable,
            owningBundleIdentifier: "com.ali.dodoma")

        XCTAssertEqual(
            value(of: "launch at login", in: printed),
            CLIConfig.label(.unavailable, owningBundleIdentifier: "com.ali.dodoma"))
    }

    // MARK: - The rest of the screen

    /// Per-app modes and the verify-skip list are settings like any other, so
    /// they come from the running copy too.
    func testThePerAppModesComeFromTheRunningCopy() {
        var applied = AppSettings.defaults
        applied.appPolicies = ["com.example.editor": .off]
        applied.axVerifySkip = ["com.google.Chrome"]

        let printed = text(snapshot: snapshot(settings: applied), stored: .defaults)

        XCTAssertTrue(printed.contains("com.example.editor"), printed)
        XCTAssertTrue(printed.contains("com.google.Chrome"), printed)
    }

    func testTheVocabularyBlockReportsWhatTheLexiconHolds() {
        let printed = text(snapshot: snapshot())

        XCTAssertTrue(printed.contains("8  (0 added by hand, 394 on the way)"), printed)
        XCTAssertTrue(printed.contains("/tmp/lexicon.json"), printed)
    }

    /// The header is the version of the command, always — the running copy's
    /// version is reported separately, and only when the two differ.
    func testTheHeaderNamesTheCommandsOwnVersion() {
        XCTAssertTrue(text(snapshot: snapshot()).hasPrefix("Harf \(version)"))
    }

    // MARK: - Editing words while a copy is running

    /// An edit that reached the running copy is one line, and the line it used
    /// to be — stop the app first, or lose this in twenty seconds — is gone.
    /// Somebody who is told to quit an app to add a word does it once and never
    /// uses the command again.
    func testAnEditTakenByTheRunningCopyIsConfirmedInOneLine() {
        let note = CLIConfig.vocabularyTakenNote

        XCTAssertTrue(note.contains("running"), note)
        XCTAssertFalse(note.contains("--quit"), note)
        XCTAssertFalse(note.contains("\n"), note)
    }

    /// And when the message was not taken. The edit is on disk and the running
    /// copy's own save merges rather than overwrites it, so this says what is
    /// true — saved, not in force yet — rather than asking for a restart.
    func testAnEditTheRunningCopyDidNotTakeSaysWhatIsTrue() {
        let warning = CLIConfig.vocabularyNotTakenWarning

        XCTAssertTrue(warning.contains("saved"), warning)
        XCTAssertFalse(warning.contains("--quit"), warning)
    }
}
