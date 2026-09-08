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
}
