import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The alert "Check for Updates…" ends in, as a value.
///
/// The alert itself cannot be run from a test — `NSAlert.runModal` needs
/// somebody to press a button — so the copy and the buttons are decided by a
/// pure function and `MenuBarController` does nothing but render what it
/// returns. Same arrangement as `CLIConfig.statusText`.
final class UpdateAlertTests: XCTestCase {
    private let releaseURL = URL(
        string: "https://github.com/alialhawas/Harf/releases/tag/v1.1.0")!
    private lazy var newer = UpdateCheck.Result.updateAvailable(
        version: "1.1.0", releaseURL: releaseURL)

    /// After a click the user is waiting for an answer, so every outcome —
    /// including the boring one and the failed one — has something to show. An
    /// alert that only appears when there is news makes the menu item look
    /// broken on the day there is none.
    func testEveryOutcomeProducesAnAlertWithSomethingInIt() {
        let results: [UpdateCheck.Result] = [
            .upToDate(version: "1.0.1"), newer, .failed(reason: "Could not reach GitHub."),
        ]
        for result in results {
            for install in [InstallKind.homebrew, .directDownload] {
                let alert = UpdateAlert.describing(result, install: install)
                XCTAssertFalse(alert.title.isEmpty, "\(result) / \(install)")
                XCTAssertFalse(alert.body.isEmpty, "\(result) / \(install)")
            }
        }
    }

    func testUpToDateNamesTheVersionInHand() {
        let alert = UpdateAlert.describing(.upToDate(version: "1.0.1"), install: .homebrew)
        XCTAssertTrue(alert.title.contains("1.0.1") || alert.body.contains("1.0.1"), alert.body)
        XCTAssertNil(alert.action, "nothing to do means no second button")
        XCTAssertFalse(alert.isWarning)
    }

    /// A Homebrew install gets the command and a button that puts it on the
    /// pasteboard, because the alternative is retyping
    /// `alialhawas/harf/harf` from a screenshot.
    func testAHomebrewInstallOffersTheCommandAndCopiesIt() {
        let alert = UpdateAlert.describing(newer, install: .homebrew)
        XCTAssertTrue(alert.body.contains(UpdateCheck.upgradeCommand), alert.body)
        XCTAssertEqual(alert.action, .copy(UpdateCheck.upgradeCommand))
        XCTAssertEqual(alert.actionTitle, "Copy")
    }

    /// A direct download has no command to run, so the button opens the page the
    /// release is on. Harf downloads nothing itself.
    func testADirectDownloadOffersTheReleasePage() {
        let alert = UpdateAlert.describing(newer, install: .directDownload)
        XCTAssertEqual(alert.action, .open(releaseURL))
        XCTAssertEqual(alert.actionTitle, "Open Release Page")
        XCTAssertFalse(alert.body.contains("brew"), alert.body)
    }

    func testBothInstallsNameTheVersionOnOffer() {
        for install in [InstallKind.homebrew, .directDownload] {
            let alert = UpdateAlert.describing(newer, install: install)
            XCTAssertTrue(alert.body.contains("1.1.0") || alert.title.contains("1.1.0"), alert.body)
        }
    }

    /// A failed check says why, in the words the check itself produced, and reads
    /// as a warning rather than as news.
    func testAFailedCheckShowsTheReason() {
        let alert = UpdateAlert.describing(
            .failed(reason: "GitHub's rate limit for this network has been reached."),
            install: .homebrew)
        XCTAssertTrue(alert.body.contains("rate limit"), alert.body)
        XCTAssertNil(alert.action)
        XCTAssertTrue(alert.isWarning)
    }

    // MARK: - One check at a time

    /// The menu can be opened again while the first request is still out. A
    /// second request would arrive as a second alert on top of the first, and on
    /// a rate-limited network it is also what exhausts the budget.
    func testASecondCheckIsRefusedWhileTheFirstIsInFlight() {
        var gate = UpdateCheckGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
    }

    func testTheGateReopensWhenTheCheckFinishes() {
        var gate = UpdateCheckGate()
        XCTAssertTrue(gate.begin())
        gate.finish()
        XCTAssertTrue(gate.begin())
    }
}
