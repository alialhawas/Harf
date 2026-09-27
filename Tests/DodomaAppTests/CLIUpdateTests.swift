import DodomaCore
import XCTest

@testable import DodomaAppKit

/// What `harf --update` says and does, held to the rule the whole feature turns
/// on: nothing here reaches the network, and nothing here downloads an app.
///
/// The command is a pure plan plus a runner, for the same reason `--status` is a
/// pure renderer: the interesting part is what a given outcome tells the user to
/// do, and neither a GitHub outage nor a Homebrew install can be reproduced from
/// a test.
final class CLIUpdateTests: XCTestCase {
    private let brew = "/opt/brew/bin/brew"
    private let newer = UpdateCheck.Result.updateAvailable(
        version: "1.1.0",
        releaseURL: URL(string: "https://github.com/alialhawas/Harf/releases/tag/v1.1.0")!)

    private func plan(
        _ result: UpdateCheck.Result,
        install: InstallKind,
        brewExecutable: String? = "/opt/brew/bin/brew",
        checkOnly: Bool = false
    ) -> CLIUpdate.Plan {
        CLIUpdate.plan(
            for: result, install: install, brewExecutable: brewExecutable, checkOnly: checkOnly)
    }

    // MARK: - Parsing

    func testUpdateParses() {
        XCTAssertEqual(CLI.parse(["--update"]), .update(checkOnly: false))
    }

    func testCheckOnlyParses() {
        XCTAssertEqual(CLI.parse(["--update", "--check-only"]), .update(checkOnly: true))
    }

    /// `--check-only` modifies `--update` and means nothing without it, so on its
    /// own it is a typo rather than a silent no-op.
    func testCheckOnlyAloneIsNotACommand() {
        XCTAssertEqual(CLI.parse(["--check-only"]), .unknown(argument: "--check-only"))
    }

    func testHelpDocumentsUpdateAndCheckOnly() {
        XCTAssertTrue(CLI.helpText.contains("--update"), CLI.helpText)
        XCTAssertTrue(CLI.helpText.contains("--check-only"), CLI.helpText)
    }

    /// The one network request in the app is the one thing about it that has to
    /// be written down where somebody looking for it will find it.
    func testHelpSaysTheCheckIsTheOnlyNetworkRequest() {
        XCTAssertTrue(CLI.helpText.lowercased().contains("only network request"), CLI.helpText)
    }

    // MARK: - Nothing to do

    func testUpToDateSaysSoAndSucceeds() {
        let printed = plan(.upToDate(version: "1.0.1"), install: .homebrew)
        XCTAssertEqual(printed.exitCode, 0)
        XCTAssertNil(printed.command)
        XCTAssertTrue(printed.message.contains("1.0.1"), printed.message)
        XCTAssertTrue(printed.message.lowercased().contains("newest"), printed.message)
    }

    /// A failed check exits non-zero, so a script that runs this in a loop can
    /// tell "nothing to install" from "I could not find out".
    func testAFailedCheckExitsNonZeroAndSaysWhy() {
        let printed = plan(
            .failed(reason: "Could not reach GitHub. The Internet connection appears to be offline."),
            install: .homebrew)
        XCTAssertEqual(printed.exitCode, 1)
        XCTAssertNil(printed.command)
        XCTAssertTrue(printed.message.contains("appears to be offline"), printed.message)
    }

    func testAFailedCheckExitsNonZeroUnderCheckOnlyToo() {
        XCTAssertEqual(
            plan(.failed(reason: "GitHub answered HTTP 500"), install: .directDownload,
                 checkOnly: true).exitCode,
            1)
    }

    // MARK: - An update, on a Homebrew install

    func testAHomebrewInstallRunsBrewUpgrade() {
        let printed = plan(newer, install: .homebrew)
        XCTAssertEqual(printed.command, [brew, "upgrade", "--cask", "alialhawas/harf/harf"])
        XCTAssertEqual(printed.exitCode, 0)
        XCTAssertTrue(printed.message.contains("1.1.0"), printed.message)
    }

    /// `--check-only` reports and stops. It still names the command, so the
    /// person who asked can run it themselves.
    func testCheckOnlyReportsWithoutRunningAnything() {
        let printed = plan(newer, install: .homebrew, checkOnly: true)
        XCTAssertNil(printed.command)
        XCTAssertEqual(printed.exitCode, 0)
        XCTAssertTrue(printed.message.contains(UpdateCheck.upgradeCommand), printed.message)
    }

    /// A Homebrew install whose `brew` cannot be found again between the check
    /// and the upgrade. Nothing is run on a guessed path; the command is printed
    /// for the user instead.
    func testAMissingBrewPrintsTheCommandRatherThanGuessingAPath() {
        let printed = plan(newer, install: .homebrew, brewExecutable: nil)
        XCTAssertNil(printed.command)
        XCTAssertTrue(printed.message.contains(UpdateCheck.upgradeCommand), printed.message)
    }

    // MARK: - An update, on a direct download

    /// The rule the brief is explicit about: no self-update. The plan for a
    /// direct download has nothing to run, and the release page is where the
    /// user goes.
    func testADirectDownloadPrintsTheManualStepsAndRunsNothing() {
        let printed = plan(newer, install: .directDownload)
        XCTAssertNil(printed.command)
        XCTAssertEqual(printed.exitCode, 0)
        XCTAssertTrue(
            printed.message.contains("https://github.com/alialhawas/Harf/releases/tag/v1.1.0"),
            printed.message)
        XCTAssertTrue(printed.message.contains("harf --quit"), printed.message)
    }

    /// A direct download told to run `brew upgrade` gets a command that fails on
    /// a cask it never installed.
    func testADirectDownloadIsNotToldToRunBrew() {
        XCTAssertFalse(plan(newer, install: .directDownload).message.contains("brew"))
    }

    /// And the other way round: a Homebrew install told to drag a DMG over its
    /// app leaves Homebrew's records describing a version that is not there.
    func testAHomebrewInstallIsNotToldToDownloadADiskImage() {
        let message = plan(newer, install: .homebrew).message.lowercased()
        XCTAssertFalse(message.contains(".dmg"), message)
        XCTAssertFalse(message.contains("download"), message)
    }

    /// Whatever the outcome, the command says something. A manual `--update`
    /// that prints nothing reads as a command that did not work.
    func testEveryOutcomeSaysSomething() {
        let results: [UpdateCheck.Result] = [
            .upToDate(version: "1.0.1"), newer, .failed(reason: "no"),
        ]
        for result in results {
            for install in [InstallKind.homebrew, .directDownload] {
                for checkOnly in [true, false] {
                    let printed = plan(result, install: install, checkOnly: checkOnly)
                    XCTAssertFalse(
                        printed.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(result) / \(install) / checkOnly \(checkOnly) printed nothing")
                }
            }
        }
    }

    /// No plan, for any outcome, ever runs anything but Homebrew. This is the
    /// "do not implement self-update" rule as a test rather than as a comment:
    /// a downloader added later fails here.
    func testNoPlanEverRunsAnythingButBrew() {
        let results: [UpdateCheck.Result] = [
            .upToDate(version: "1.0.1"), newer, .failed(reason: "no"),
        ]
        for result in results {
            for install in [InstallKind.homebrew, .directDownload] {
                for checkOnly in [true, false] {
                    guard let command = plan(result, install: install, checkOnly: checkOnly)
                        .command
                    else { continue }
                    XCTAssertEqual(command.first, brew, "\(result) ran \(command)")
                    XCTAssertTrue(command.contains("upgrade"), "\(command)")
                }
            }
        }
    }
}
