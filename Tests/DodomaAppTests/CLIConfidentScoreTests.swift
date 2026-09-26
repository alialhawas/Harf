import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The `--confident` argument, read the same way everywhere it is typed.
///
/// `--set confident` has always taken both scales — `0.9` because that is what
/// the JSON `--config` prints holds, `90` because that is what the settings
/// window shows — and refused anything that is not a score. `--decide` and
/// `--eval` read the same argument through a bare `Double.init`, so
/// `--confident 90` became a threshold of 90.0: a bar no combined score can
/// clear, which blocked every fix and printed nothing to say why. Two commands
/// whose whole purpose is to report what the app would do at a given setting
/// were answering about a setting the app can never be at.
final class CLIConfidentScoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

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

    // MARK: - Both scales are one threshold

    func testTheTwoScalesTypedForTheSameThresholdAgree() {
        XCTAssertEqual(CLIConfig.confidentScore("0.9"), 0.9)
        XCTAssertEqual(CLIConfig.confidentScore("90"), 0.9)
        XCTAssertEqual(CLIConfig.confidentScore("90%"), 0.9)
        XCTAssertEqual(CLIConfig.confidentScore("90"), CLIConfig.confidentScore("0.9"))
    }

    /// The flag on `--decide` and `--eval` has to land on the same number, not
    /// merely be parsed by something with a similar shape.
    func testBothScalesReachTheGateAsTheSameThreshold() {
        XCTAssertEqual(CLI.confidentScore("90", flag: "--decide").score, 0.9)
        XCTAssertEqual(CLI.confidentScore("0.9", flag: "--decide").score, 0.9)
        XCTAssertNil(CLI.confidentScore("90", flag: "--decide").problem)
        XCTAssertNil(CLI.confidentScore("0.9", flag: "--eval").problem)
    }

    /// The cross-check that matters: the threshold `--decide --confident 90`
    /// reports on is the threshold `--set confident 90` puts in force. These
    /// two readings drifting apart is the whole bug.
    func testTheFlagAndTheStoredSettingReadTheSameArgument() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(CLIConfig.set("confident", "90", store: store), 0)

        XCTAssertEqual(store.settings.confidentScore, CLI.confidentScore("90", flag: "--decide").score)
        XCTAssertEqual(store.settings.confidentScore, CLI.confidentScore("0.9", flag: "--decide").score)
    }

    // MARK: - Out of range is named, not swallowed

    /// `9000` is what `--confident 90` used to mean. Nothing can clear it, so
    /// taking it silently is the failure mode this test exists to prevent: the
    /// command runs, exits zero, and every verdict it prints is a lie about the
    /// reason.
    func testAThresholdNoScoreCouldClearIsRefused() {
        for raw in ["9000", "1.5", "101", "-1", "0", "abc", ""] {
            XCTAssertNil(CLIConfig.confidentScore(raw), "'\(raw)' is not a score")
        }
    }

    func testTheFlagFailsLoudlyOnAThresholdItCannotUse() {
        let refused = CLI.confidentScore("9000", flag: "--decide")

        XCTAssertNil(refused.score)
        let problem = try? XCTUnwrap(refused.problem)
        XCTAssertTrue(problem?.contains("--decide") == true, problem ?? "no message")
        XCTAssertTrue(problem?.contains("--confident") == true, problem ?? "no message")
        XCTAssertTrue(problem?.contains("9000") == true, problem ?? "no message")
    }

    /// And the command stops on it rather than going on to print a report.
    /// `--eval` returning 0 is what a build gate reads as "the corpus is
    /// clean", so a run that silently used a threshold nothing can clear is a
    /// green build that proved nothing.
    ///
    /// The corpus here is real and readable, so the only thing left that can
    /// fail the command is the threshold. The check runs before the language
    /// models and the layout pair are touched, which is also why this test does
    /// not depend on the input sources of the machine running it.
    func testAnImpossibleThresholdStopsTheCommandInsteadOfBeingTakenAtFaceValue() throws {
        let corpus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harf-confident-\(UUID().uuidString).tsv")
        try "hello\tignore\n".write(to: corpus, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: corpus) }

        XCTAssertEqual(
            CLI.run(.eval(path: corpus.path, aggressiveness: nil, confident: "9000")), 2)
        XCTAssertEqual(
            CLI.run(.decide(text: "hello", language: nil, aggressiveness: nil,
                            confident: "9000")), 2)
    }

    /// The message is worded like the one `--set confident` gives, because the
    /// reader who mistyped it in one place is the reader who will mistype it in
    /// the other.
    func testTheMessageNamesTheTwoScalesThatWork() {
        let problem = CLI.confidentScore("9000", flag: "--eval").problem

        XCTAssertTrue(problem?.contains("0.9") == true, problem ?? "no message")
        XCTAssertTrue(problem?.contains("90") == true, problem ?? "no message")
    }

    // MARK: - The band the store keeps

    /// A score inside the accepted range but below what the store will hold is
    /// pulled up to the store's floor rather than used as typed. `--decide` and
    /// `--eval` answer "what would the app do at this setting", and 0.55 is not
    /// a setting the app can be at — `--set confident 0.55` lands on 0.60 too.
    func testAScoreBelowTheStoredBandIsPulledIntoIt() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(CLIConfig.set("confident", "0.55", store: store), 0)

        XCTAssertEqual(CLIConfig.confidentScore("0.55"), 0.60)
        XCTAssertEqual(CLIConfig.confidentScore("0.55"), store.settings.confidentScore)
    }

    func testACertaintyIsPulledDownToTheCeilingTheStoreKeeps() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(CLIConfig.set("confident", "100", store: store), 0)

        XCTAssertEqual(CLIConfig.confidentScore("100"), 0.99)
        XCTAssertEqual(CLIConfig.confidentScore("100"), store.settings.confidentScore)
    }

    // MARK: - The flag left off

    /// No `--confident` is the gate off, which is not the same as a bad value:
    /// it must not produce a message and must not produce a threshold.
    func testTheFlagLeftOffIsTheGateOffRatherThanAnError() {
        let absent = CLI.confidentScore(nil, flag: "--decide")

        XCTAssertNil(absent.score)
        XCTAssertNil(absent.problem)
    }
}
