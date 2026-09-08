import XCTest

@testable import DodomaAppKit

/// A mistyped option used to start a second copy of the menu-bar application,
/// in the foreground, which never exits — two event taps both capturing and
/// both able to inject.
final class CLIParseTests: XCTestCase {
    func testAMistypedOptionIsRejectedRatherThanLaunchingTheApp() {
        guard case .unknown(let argument)? = CLI.parse(["--skipverify", "com.example.app", "off"])
        else { return XCTFail("a mistyped option must not fall through to launching the app") }

        XCTAssertEqual(argument, "--skipverify")
    }

    /// No arguments is how the application is started. It has to keep meaning
    /// that, or the app stops launching at all.
    func testNoArgumentsStillMeansLaunchTheApp() {
        XCTAssertNil(CLI.parse([]))
    }

    /// macOS hands a bundled application single-dash arguments of its own —
    /// -psn_0_… from LaunchServices, -NSDocumentRevisionsDebugMode and friends.
    /// Refusing to start because of one would be worse than the bug this fixes.
    func testSingleDashArgumentsFromMacOSStillLaunchTheApp() {
        XCTAssertNil(CLI.parse(["-psn_0_1234567"]))
        XCTAssertNil(CLI.parse(["-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testRecognisedCommandsAreUnaffected() {
        guard case .skipVerify(let bundleID, let state)? =
            CLI.parse(["--skip-verify", "com.example.app", "off"])
        else { return XCTFail("--skip-verify should parse") }

        XCTAssertEqual(bundleID, "com.example.app")
        XCTAssertEqual(state, "off")
    }

    /// A recognised option later in the line still wins, so trailing modifiers
    /// like --lang are not mistaken for typos.
    func testAModifierAfterACommandIsNotTreatedAsATypo() {
        guard case .words? = CLI.parse(["--words", "list", "--lang", "ar"]) else {
            return XCTFail("--lang must not be read as an unknown option")
        }
    }

    func testQuitIsACommandLikeAnyOther() {
        XCTAssertEqual(CLI.parse(["--quit"]), .quit)
    }

    // MARK: - How wide the typo net is

    /// Nothing hands arguments to the unbundled executable except a person at
    /// a shell, so a single dash there is a typo as plainly as a double one.
    /// Without this it fell through to the general usage block, which does not
    /// mention what was typed.
    func testASingleDashTypoIsCaughtWhenNotRunningFromTheBundle() {
        XCTAssertEqual(
            CLI.parse(["-status"], isBundled: false), .unknown(argument: "-status"))
    }

    /// The same for a missing dash: `harf status` is a guess at the interface,
    /// and it deserves the answer that names it.
    func testAnArgumentWithNoDashIsCaughtWhenNotRunningFromTheBundle() {
        XCTAssertEqual(CLI.parse(["status"], isBundled: false), .unknown(argument: "status"))
    }

    /// And none of it applies to the bundle, because macOS is what passes it
    /// arguments: -psn_0_…, -NSDocumentRevisionsDebugMode, a file path on an
    /// open-with. Refusing to start over one would be a worse bug than the one
    /// the net exists for.
    func testTheBundleKeepsStartingOnMacOSsOwnArguments() {
        XCTAssertNil(CLI.parse(["-psn_0_1234567"], isBundled: true))
        XCTAssertNil(CLI.parse(["-NSDocumentRevisionsDebugMode", "YES"], isBundled: true))
    }

    /// No arguments is still no arguments either way; the net only catches what
    /// was actually typed.
    func testNoArgumentsIsNotATypoEvenUnbundled() {
        XCTAssertNil(CLI.parse([], isBundled: false))
    }
}
