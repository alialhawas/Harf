import XCTest

@testable import DodomaAppKit

/// What an argument list means, once it is known how the process was launched.
///
/// `harf` is on the PATH — the Homebrew cask links the app's executable there —
/// so a bare `harf` in a shell used to start a full menu-bar copy, event tap
/// and all, from a terminal window that then had to stay open. Because it was
/// the executable rather than the bundle, LaunchServices recorded it with no
/// bundle identifier, nothing named it in the Dock, and the second copy the
/// user later opened from `/Applications` corrected everything twice.
///
/// Being launched as the `.app` is the whole signal. It is the same fact that
/// makes such a copy invisible to `pkill -x Harf`, and the same fact
/// `LoginItem` already asks before touching `SMAppService`.
final class CLILaunchTests: XCTestCase {
    /// The bug. Someone typing the name of a command-line tool gets the usage
    /// of a command-line tool, not a background application.
    func testABareInvocationOfTheExecutablePrintsUsageInsteadOfStarting() {
        XCTAssertEqual(
            CLI.launch(command: nil, isBundled: false, isTerminal: true), .usage)
    }

    /// The case the tty test got wrong, and the reason it had to go.
    /// `harf >/dev/null 2>&1 &` in a cron line or a login script has no
    /// terminal, and under the old rule that alone meant "start the app": a tap
    /// nobody knew about, holding the single-instance name against the copy the
    /// user opens later.
    func testAHeadlessBareInvocationDoesNotStartATapEither() {
        XCTAssertEqual(
            CLI.launch(command: nil, isBundled: false, isTerminal: false), .usage)
    }

    /// How the application is actually started. LaunchServices opens the
    /// bundle and passes no arguments; that has to keep meaning "run".
    func testABundledLaunchWithNoArgumentsStartsTheApp() {
        XCTAssertEqual(
            CLI.launch(command: nil, isBundled: true, isTerminal: false), .application)
    }

    /// Opening the bundle from a shell — `build/Harf.app/Contents/MacOS/Harf`
    /// during development — is still the application. The terminal says
    /// nothing either way.
    func testABundledLaunchFromATerminalStillStartsTheApp() {
        XCTAssertEqual(
            CLI.launch(command: nil, isBundled: true, isTerminal: true), .application)
    }

    /// macOS also hands a bundled application single-dash arguments of its own
    /// — -psn_0_… from LaunchServices and friends. `parse` returns nil for
    /// those, and for a bundled launch that still has to mean "start".
    func testLaunchServicesArgumentsStillStartTheApp() {
        XCTAssertEqual(
            CLI.launch(
                command: CLI.parse(["-psn_0_1234567"], isBundled: true), isBundled: true,
                isTerminal: false),
            .application)
    }

    /// `swift run Harf` and a debugger session are unbundled and are the
    /// application, which is the one thing the bundle rule cannot see. The
    /// environment variable is the way to say so.
    func testAnUnbundledBuildStartsTheAppWhenForced() {
        XCTAssertEqual(
            CLI.launch(command: nil, isBundled: false, isTerminal: true, forceApplication: true),
            .application)
    }

    /// Every command keeps working from the command line — that is what the
    /// binary is on the PATH for.
    func testACommandFromTheCommandLineRuns() {
        XCTAssertEqual(
            CLI.launch(command: .status, isBundled: false, isTerminal: true), .run(.status))
    }

    /// And from the bundle, so `Harf.app/Contents/MacOS/Harf --status` is not
    /// silently turned into a second copy of the app.
    func testACommandFromTheBundleRunsRatherThanStartingTheApp() {
        XCTAssertEqual(
            CLI.launch(command: .config, isBundled: true, isTerminal: false), .run(.config))
    }

    /// A mistyped option already has its own error, and that error is more use
    /// than a usage block that does not mention what was typed.
    func testAMistypedOptionKeepsItsOwnErrorRatherThanBecomingUsage() {
        XCTAssertEqual(
            CLI.launch(
                command: CLI.parse(["--skipverify"], isBundled: false), isBundled: false,
                isTerminal: true),
            .run(.unknown(argument: "--skipverify")))
    }

    /// The usage block is the only thing the user sees after typing `harf`, so
    /// it has to answer both questions they now have: what the command does,
    /// and how the application is started instead.
    func testUsageSaysHowToStartTheApplication() {
        XCTAssertTrue(CLI.usageText.contains("--help"), CLI.usageText)
        XCTAssertTrue(CLI.usageText.contains("/Applications/Harf.app"), CLI.usageText)
    }

    /// The dev path the bundle rule shuts out has to be findable from the one
    /// screen a developer running `swift run Harf` is looking at.
    func testUsageNamesTheEscapeHatchForUnbundledBuilds() {
        XCTAssertTrue(CLI.usageText.contains("HARF_FORCE_APP"), CLI.usageText)
    }

    /// Non-zero, so a shell script that runs `harf` expecting it to do
    /// something does not silently succeed.
    func testUsageExitsNonZero() {
        XCTAssertNotEqual(CLI.usage(), 0)
    }

    /// The forcing variable is spelled one way and read exactly.
    func testTheApplicationIsOnlyForcedByTheExactValue() {
        XCTAssertTrue(CLI.isApplicationForced(environment: ["HARF_FORCE_APP": "1"]))
        XCTAssertFalse(CLI.isApplicationForced(environment: ["HARF_FORCE_APP": "true"]))
        XCTAssertFalse(CLI.isApplicationForced(environment: [:]))
    }
}
