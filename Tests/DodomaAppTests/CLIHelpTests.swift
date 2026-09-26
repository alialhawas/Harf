import XCTest

@testable import DodomaAppKit
@testable import DodomaCore

/// The help text is hand-written prose next to a hand-written switch, and the
/// two drift apart silently: the unknown-key error listed five of the eight
/// settable keys for months. These tests make the drift fail the build.
final class CLIHelpTests: XCTestCase {
    /// Canonical name of every key `CLIConfig.set` accepts. Aliases are
    /// deliberately excluded — help should teach one spelling.
    private let settableKeys = [
        "paused", "sensitivity", "confident", "buffer", "idle", "learn",
        "debugLogging", "defaultPolicy",
    ]

    func testHelpDocumentsEverySettableKey() {
        for key in settableKeys {
            XCTAssertTrue(
                CLI.helpText.contains(key),
                "--set accepts '\(key)' but --help never mentions it")
        }
    }

    /// The default column is hand-written beside the switch that owns the
    /// value, so a default moved in code and not here teaches the wrong number.
    func testHelpPrintsTheShippedConfidentDefault() throws {
        let score = try XCTUnwrap(AppSettings.defaults.confidentScore)
        let row = try XCTUnwrap(
            CLI.helpText.split(separator: "\n").first { $0.contains("a score, 70 or 0.70") },
            "the confident row is gone from --help")
        XCTAssertTrue(
            row.hasSuffix(SettingsCopy.percent(score).replacingOccurrences(of: "%", with: "")),
            "--help states a confident default the app does not ship: \(row)")
    }

    /// Every command that writes a setting has to be discoverable from --help,
    /// or it is a setting only the settings window can reach — which is what
    /// the verify-skip list was until it was given a command.
    func testHelpDocumentsEveryWritingCommand() {
        for command in ["--set", "--policy", "--skip-verify", "--words"] {
            XCTAssertTrue(
                CLI.helpText.contains(command),
                "\(command) changes a setting but --help never mentions it")
        }
    }

    func testHelpListsEverySensitivityLevel() {
        for level in Aggressiveness.allCases {
            XCTAssertTrue(
                CLI.helpText.contains(level.rawValue),
                "sensitivity accepts '\(level.rawValue)' but --help never mentions it")
        }
    }

    func testHelpListsEveryPerAppMode() {
        for policy in AppPolicy.allCases {
            XCTAssertTrue(
                CLI.helpText.contains(policy.rawValue),
                "--policy accepts '\(policy.rawValue)' but --help never mentions it")
        }
    }

    /// The chords are hand-written in three places — the menu, the settings
    /// window and this text — and a chord missing from --help is a feature
    /// only somebody who opened the menu can find.
    func testHelpNamesEveryShortcut() {
        for chord in [SettingsCopy.undoChord, SettingsCopy.pauseChord, SettingsCopy.flipChord] {
            XCTAssertTrue(
                CLI.helpText.contains(chord),
                "\(chord) is a registered shortcut but --help never mentions it")
        }
    }

    /// The message someone sees after a typo has to name every key, or it sends
    /// them looking for a setting they already have.
    func testTheUnknownKeyErrorNamesEverySettableKey() {
        let message = CLIConfig.unknownKeyMessage("nonsense")
        for key in settableKeys {
            XCTAssertTrue(
                message.contains(key),
                "the unknown-key error omits '\(key)'")
        }
    }

    /// `--quit` is how the app is stopped, and it is quoted by the
    /// single-instance alert, `make install`, `uninstall.sh` and the README.
    /// A command four other things point at cannot be missing from --help.
    func testHelpDocumentsQuit() {
        XCTAssertTrue(CLI.helpText.contains("--quit"), CLI.helpText)
    }

    /// The header comment of `CLIConfig` claimed for months that a write from a
    /// shell reached a running app; it did not, and nobody could have known
    /// from the outside. Now it does, and the promise belongs where the user
    /// reads it rather than only in a source file.
    func testHelpSaysAChangeReachesTheRunningCopy() {
        XCTAssertTrue(CLI.helpText.contains("reaches the running copy"), CLI.helpText)
    }

    /// The two ways past the launch rules exist for people who will only find
    /// them if they are written down.
    func testHelpDocumentsBothEnvironmentOverrides() {
        XCTAssertTrue(CLI.helpText.contains("HARF_FORCE_APP"), CLI.helpText)
        XCTAssertTrue(CLI.helpText.contains("HARF_IGNORE_INSTANCE"), CLI.helpText)
    }

    // MARK: - Messages that have to name the real problem

    /// The only reading the old single message covered. It is still the right
    /// advice when a layout really is missing.
    func testAMissingLayoutIsReportedAsAMissingLayout() {
        let message = CLI.layoutPairProblem(enabled: [layout("en")], selectedID: "keylayout.ABC")
        XCTAssertTrue(message.contains("Input Sources"), message)
    }

    /// The reading that used to be reported as a missing layout on a machine
    /// that has both: the pair is resolved against the source the user is
    /// typing in, so a third language selected means there is nothing to
    /// arbitrate, and "enable both layouts" sends them to a settings pane where
    /// everything is already correct.
    func testAThirdLanguageSelectedIsReportedAsTheSelectionNotAMissingLayout() {
        let message = CLI.layoutPairProblem(
            enabled: [layout("en"), layout("ar"), layout("fr")], selectedID: "keylayout.fr")
        XCTAssertFalse(message.contains("Input Sources"), message)
        XCTAssertTrue(message.contains("neither English nor Arabic"), message)
    }

    /// An input method carries no `uchr` table, so it never appears in the
    /// enabled list even while it is the thing the user is typing in. That is a
    /// third distinct reason, and it has a different fix from the other two.
    func testASelectionWithNoLayoutTableIsReportedAsSuch() {
        let message = CLI.layoutPairProblem(
            enabled: [layout("en"), layout("ar")], selectedID: "inputmethod.Kotoeri")
        XCTAssertTrue(message.contains("inputmethod.Kotoeri"), message)
        XCTAssertTrue(message.contains("input method"), message)
    }

    /// `harf --status` through the cask's symlink is not a bundled process, so
    /// launchd will not answer for it — while the person asking is running the
    /// bundled copy and may well have start-at-login switched on. Saying "not
    /// running from a bundled app" is true of the command and false of
    /// everything the reader means by it.
    func testTheLoginItemLineNamesTheBundleItCannotAnswerFor() {
        let line = CLIConfig.label(.unavailable, owningBundleIdentifier: "com.ali.dodoma")
        XCTAssertTrue(line.contains("com.ali.dodoma"), line)
        XCTAssertTrue(line.contains("Login Items"), line)
    }

    /// `swift run` has no bundle above it at all, and there the old sentence is
    /// exactly right.
    func testTheLoginItemLineStillSaysUnavailableWithNoBundleAtAll() {
        XCTAssertTrue(CLIConfig.label(.unavailable).contains("not running from a bundled app"))
    }

    private func layout(_ languageCode: String) -> KeyboardLayout {
        KeyboardLayout(
            sourceID: "keylayout.\(languageCode)", localizedName: languageCode,
            languageCode: languageCode, uchrData: Data())
    }
}
