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
}
