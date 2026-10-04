import DodomaCore
import Foundation
import XCTest

@testable import DodomaAppKit

/// What the documentation is allowed to claim about the network, now that one
/// thing in Harf can use it.
///
/// "Does no networking of any kind" was true for every release up to 1.0.1 and
/// was printed in four places, two of them in Arabic. A manual update check
/// makes it false as written, and the honest replacement is narrower rather than
/// vaguer: no network request unless the user asks for one. These tests read the
/// repository the way `BrandPackagingTests` does, because the claim lives in
/// prose and prose is where it will silently drift back.
final class NetworkPromiseTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // DodomaAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - README

    /// The sentence this feature falsified. It is not enough to add a caveat
    /// elsewhere while the summary at the top still says this.
    func testTheREADMENoLongerClaimsNoNetworkingOfAnyKind() throws {
        let readme = try read("README.md")
        XCTAssertFalse(readme.contains("does no networking of any kind"), "README.md line 18")
        XCTAssertFalse(
            readme.contains("No network code exists in the app"),
            "the 'What it holds' table still says no network code exists")
    }

    /// The replacement has to be the precise claim rather than silence about it:
    /// somebody choosing this app over a cloud-backed one is choosing it for
    /// this sentence.
    func testTheREADMEMakesTheNarrowerClaimInstead() throws {
        let readme = try read("README.md")
        XCTAssertTrue(
            readme.contains("no network request unless"),
            "README.md no longer states when Harf does and does not use the network")
    }

    /// A command nobody documented is a command nobody runs.
    func testTheREADMEDocumentsTheUpdateCommandAndTheMenuItem() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains("--update"), "README.md does not document harf --update")
        XCTAssertTrue(readme.contains("--check-only"), "README.md does not document --check-only")
        XCTAssertTrue(
            readme.contains("Check for Updates"),
            "README.md does not mention the menu item")
    }

    /// How to upgrade a Homebrew install was documented nowhere at all before
    /// this feature — not in the README, not in the cask.
    func testTheREADMEDocumentsHowToUpgradeWithHomebrew() throws {
        XCTAssertTrue(
            try read("README.md").contains(UpdateCheck.upgradeCommand),
            "README.md never says how to upgrade a Homebrew install")
    }

    /// The `--update` documentation has to say what it will not do, because
    /// "check for updates" reads to most people as "and install them".
    func testTheREADMESaysHarfDoesNotUpdateItself() throws {
        let readme = try read("README.md").lowercased()
        XCTAssertTrue(
            readme.contains("does not download") || readme.contains("downloads nothing"),
            "README.md does not say that Harf never replaces itself")
    }

    // MARK: - The cask

    /// The caveats are the last thing a Homebrew user reads, and upgrading was
    /// not among them.
    func testTheCaskCaveatsSayHowToUpgrade() throws {
        XCTAssertTrue(
            try read("Casks/harf.rb").contains(UpdateCheck.upgradeCommand),
            "Casks/harf.rb never says how to upgrade")
    }

    // MARK: - The article, in both languages

    /// `docs/why-we-built-harf.html` makes the same promise in prose, and it is
    /// the version a reader who never opens the README will see.
    func testTheArticleQualifiesItsPrivacyClaim() throws {
        let article = try read("docs/why-we-built-harf.html")
        XCTAssertTrue(
            article.contains("update check"),
            "the article's privacy paragraph does not mention the update check")
    }

    /// The Arabic mirror is a translation of that paragraph, and a correction
    /// applied to one language only leaves the other one wrong. Arabic readers
    /// are the audience this app was built for.
    func testTheArabicMirrorQualifiesItTheSameWay() throws {
        let strings = try read("docs/assets/harf-article-i18n.js")
        let privacy = try XCTUnwrap(
            strings.split(separator: "\n").first { $0.contains("\"privacyBody\"") },
            "privacyBody is gone from the Arabic strings")
        XCTAssertTrue(
            privacy.contains("التحديثات") || privacy.contains("تحديث"),
            "the Arabic privacy paragraph does not mention the update check: \(privacy)")
    }

    /// Both languages have to be talking about the same behaviour: the English
    /// says the request only happens when asked for, so the Arabic has to say so
    /// too rather than only naming the feature.
    func testBothLanguagesSayTheRequestOnlyHappensWhenAsked() throws {
        XCTAssertTrue(
            try read("docs/why-we-built-harf.html").contains("only when you ask"),
            "the English paragraph does not say the request is yours to make")
        XCTAssertTrue(
            try read("docs/assets/harf-article-i18n.js").contains("إلا عندما تطلب"),
            "the Arabic paragraph does not say the request is the reader's to make")
    }
}
