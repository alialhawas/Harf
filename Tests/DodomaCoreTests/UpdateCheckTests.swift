import XCTest

@testable import DodomaCore

/// The version comparison behind "Check for Updates…" and `harf --update`.
///
/// Nothing here touches the network, and that is structural rather than
/// careful: `UpdateCheck.interpret` is a pure function over a fetch outcome, so
/// every reading below — including the ones that only happen against the real
/// GitHub API on a bad day — is a value passed in by hand.
final class UpdateCheckTests: XCTestCase {
    // MARK: - Comparing versions

    func testANewerPatchIsNewer() {
        XCTAssertEqual(UpdateCheck.isNewer("1.0.2", than: "1.0.1"), true)
    }

    func testAnOlderPatchIsNotNewer() {
        XCTAssertEqual(UpdateCheck.isNewer("1.0.0", than: "1.0.1"), false)
    }

    func testTheSameVersionIsNotNewer() {
        XCTAssertEqual(UpdateCheck.isNewer("1.0.1", than: "1.0.1"), false)
    }

    /// The reason this comparison cannot be a string comparison. "1.0.10" sorts
    /// *before* "1.0.9" lexically, because '1' < '9' — so the tenth patch
    /// release of a line would read as older than the ninth and every user on
    /// 1.0.9 would be told they were up to date forever.
    func testTheTenthPatchIsNewerThanTheNinth() {
        XCTAssertEqual(UpdateCheck.isNewer("1.0.10", than: "1.0.9"), true)
        XCTAssertEqual(UpdateCheck.isNewer("1.0.9", than: "1.0.10"), false)
    }

    /// The same trap one component to the left, which is where it bites first:
    /// a project that ships ten minor releases.
    func testTheTenthMinorIsNewerThanTheNinth() {
        XCTAssertEqual(UpdateCheck.isNewer("1.10.0", than: "1.9.0"), true)
    }

    /// Releases are tagged `v1.0.1`; the version the app carries is `1.0.1`.
    /// The `v` belongs to the tag, not to the version.
    func testALeadingVOnTheTagIsTolerated() {
        XCTAssertEqual(UpdateCheck.isNewer("v1.0.2", than: "1.0.1"), true)
        XCTAssertEqual(UpdateCheck.isNewer("V1.0.2", than: "1.0.1"), true)
    }

    /// A shorter tag is padded rather than rejected: somebody tagging `v1.1` by
    /// hand means 1.1.0, and refusing to read it would report a failure to
    /// every user on the day of that release.
    func testAShortTagIsPaddedWithZeros() {
        XCTAssertEqual(UpdateCheck.isNewer("v1.1", than: "1.0.9"), true)
        XCTAssertEqual(UpdateCheck.isNewer("v1", than: "1.0.0"), false)
    }

    /// nil is "I could not read this", and the caller turns it into a reported
    /// failure rather than into silence — see `testAnUnreadableTagIsAFailure`.
    func testAnUnreadableTagHasNoAnswer() {
        XCTAssertNil(UpdateCheck.isNewer("nightly", than: "1.0.1"))
        XCTAssertNil(UpdateCheck.isNewer("", than: "1.0.1"))
        XCTAssertNil(UpdateCheck.isNewer("v", than: "1.0.1"))
        XCTAssertNil(UpdateCheck.isNewer("1..1", than: "1.0.1"))
        XCTAssertNil(UpdateCheck.isNewer("1.0.1-beta.2", than: "1.0.1"))
        XCTAssertNil(UpdateCheck.isNewer("1.0.1.4", than: "1.0.1"))
        XCTAssertNil(UpdateCheck.isNewer("1.0.-1", than: "1.0.1"))
    }

    /// The version this build reports has to be readable by the comparison it
    /// is fed to, or every check fails on a release nobody has tagged wrong.
    func testTheShippedVersionIsComparable() {
        XCTAssertNotNil(UpdateCheck.isNewer(Dodoma.version, than: Dodoma.version))
    }

    // MARK: - Reading what the endpoint said

    private func body(tag: String?, htmlURL: String? = "https://github.com/x/y/releases/tag/v9")
        -> Data
    {
        var fields: [String] = []
        if let tag { fields.append("\"tag_name\": \"\(tag)\"") }
        if let htmlURL { fields.append("\"html_url\": \"\(htmlURL)\"") }
        return Data("{\(fields.joined(separator: ", "))}".utf8)
    }

    private func ok(tag: String?, htmlURL: String? = "https://github.com/x/y/releases/tag/v9")
        -> UpdateCheck.Fetched
    {
        .response(status: 200, headers: [:], body: body(tag: tag, htmlURL: htmlURL))
    }

    func testANewerTagIsAnAvailableUpdate() {
        let result = UpdateCheck.interpret(ok(tag: "v1.0.2"), current: "1.0.1")
        XCTAssertEqual(
            result,
            .updateAvailable(
                version: "1.0.2",
                releaseURL: URL(string: "https://github.com/x/y/releases/tag/v9")!))
    }

    /// The version is reported without the tag's `v`, because that is how the
    /// app spells its own version everywhere else the user meets it.
    func testTheReportedVersionDropsTheTagPrefix() {
        guard case .updateAvailable(let version, _) = UpdateCheck.interpret(
            ok(tag: "v2.0.0"), current: "1.0.1")
        else { return XCTFail("expected an available update") }
        XCTAssertEqual(version, "2.0.0")
    }

    /// A release with no `html_url` still has somewhere to send the user.
    func testAMissingReleaseURLFallsBackToTheReleasesPage() {
        let result = UpdateCheck.interpret(ok(tag: "v1.0.2", htmlURL: nil), current: "1.0.1")
        XCTAssertEqual(
            result, .updateAvailable(version: "1.0.2", releaseURL: UpdateCheck.releasesPage))
    }

    func testTheSameTagIsUpToDate() {
        XCTAssertEqual(
            UpdateCheck.interpret(ok(tag: "v1.0.1"), current: "1.0.1"),
            .upToDate(version: "1.0.1"))
    }

    /// A build ahead of the newest release — a local `make install`, or a
    /// release tagged after this binary was cut. Nothing to install, so
    /// nothing to report.
    func testAnOlderTagIsUpToDate() {
        XCTAssertEqual(
            UpdateCheck.interpret(ok(tag: "v1.0.0"), current: "1.0.1"),
            .upToDate(version: "1.0.1"))
    }

    /// The case the brief singles out, and the one that must never read as
    /// "up to date": a tag this code cannot rank. The reason names the tag, so
    /// whoever tagged it can see what they typed.
    func testAnUnreadableTagIsAFailure() {
        guard case .failed(let reason) = UpdateCheck.interpret(
            ok(tag: "nightly-2026-09-01"), current: "1.0.1")
        else { return XCTFail("an unparseable tag must not read as up to date") }
        XCTAssertTrue(reason.contains("nightly-2026-09-01"), reason)
    }

    func testAReleaseWithNoTagIsAFailure() {
        guard case .failed(let reason) = UpdateCheck.interpret(ok(tag: nil), current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.lowercased().contains("tag"), reason)
    }

    func testABodyThatIsNotJSONIsAFailure() {
        let fetched = UpdateCheck.Fetched.response(
            status: 200, headers: [:], body: Data("<html>502 Bad Gateway</html>".utf8))
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.lowercased().contains("could not be read"), reason)
    }

    func testAnHTTPErrorIsAFailureNamingTheStatus() {
        let fetched = UpdateCheck.Fetched.response(status: 500, headers: [:], body: Data())
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("500"), reason)
    }

    /// The most likely real failure: GitHub allows 60 unauthenticated requests
    /// an hour per address, and an office behind one NAT shares that budget. It
    /// arrives as a 403, which on its own reads as "forbidden" — the wrong
    /// thing to tell somebody whose only problem is the clock.
    func testRateLimitingIsNamedAsRateLimiting() {
        let fetched = UpdateCheck.Fetched.response(
            status: 403, headers: ["X-RateLimit-Remaining": "0"], body: Data())
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.lowercased().contains("rate limit"), reason)
        XCTAssertTrue(reason.lowercased().contains("hour"), reason)
    }

    /// HTTP/2 sends header names lower-cased, and `HTTPURLResponse` hands back
    /// whatever the server sent. A case-sensitive lookup would miss the header
    /// on every real connection and report a bare 403.
    func testTheRateLimitHeaderIsReadCaseInsensitively() {
        let fetched = UpdateCheck.Fetched.response(
            status: 403, headers: ["x-ratelimit-remaining": "0"], body: Data())
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.lowercased().contains("rate limit"), reason)
    }

    /// 429 is the other shape a limiter takes, and it needs no header to be
    /// unambiguous.
    func testTooManyRequestsIsNamedAsRateLimiting() {
        let fetched = UpdateCheck.Fetched.response(status: 429, headers: [:], body: Data())
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.lowercased().contains("rate limit"), reason)
    }

    /// A 403 with budget left is a real refusal, not a limiter, and saying
    /// "wait an hour" would be advice that never works.
    func testAForbiddenWithBudgetLeftIsNotCalledRateLimiting() {
        let fetched = UpdateCheck.Fetched.response(
            status: 403, headers: ["x-ratelimit-remaining": "57"], body: Data())
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertFalse(reason.lowercased().contains("rate limit"), reason)
        XCTAssertTrue(reason.contains("403"), reason)
    }

    /// No network at all: aeroplane mode, a captive portal, a firewall. The
    /// transport's own words are carried through rather than replaced, because
    /// they are what distinguishes those three.
    func testATransportFailureIsReportedWithItsReason() {
        let fetched = UpdateCheck.Fetched.transportFailure("The Internet connection appears to be offline.")
        guard case .failed(let reason) = UpdateCheck.interpret(fetched, current: "1.0.1")
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("appears to be offline"), reason)
    }

    // MARK: - The check as a whole

    /// `check` is the whole flow, with the network replaced by a closure. This
    /// is what the menu item and `--update` call, so it is worth one test that
    /// the canned data reaches the answer.
    func testCheckRunsThroughTheInjectedFetch() {
        var asked = 0
        let fetch: UpdateCheck.Fetch = { completion in
            asked += 1
            completion(self.ok(tag: "v1.2.3"))
        }

        var result: UpdateCheck.Result?
        UpdateCheck.check(current: "1.0.1", fetch: fetch) { result = $0 }

        XCTAssertEqual(asked, 1)
        guard case .updateAvailable(let version, _) = result
        else { return XCTFail("expected an available update, got \(String(describing: result))") }
        XCTAssertEqual(version, "1.2.3")
    }

    // MARK: - What the endpoint is

    /// The one request Harf can make, pinned: it is https, it is GitHub's API,
    /// and it is the repository the cask installs from. A typo here would send
    /// an explicit update check somewhere nobody intended.
    func testTheEndpointIsTheHTTPSGitHubAPIForThisRepository() {
        XCTAssertEqual(UpdateCheck.endpoint.scheme, "https")
        XCTAssertEqual(UpdateCheck.endpoint.host, "api.github.com")
        XCTAssertEqual(UpdateCheck.endpoint.path, "/repos/alialhawas/Harf/releases/latest")
    }

    /// A menu click cannot wait on `URLSession`'s default minute.
    func testTheTimeoutIsShortEnoughForAMenuClick() {
        XCTAssertLessThanOrEqual(UpdateCheck.timeout, 15)
        XCTAssertGreaterThan(UpdateCheck.timeout, 2)
    }

    /// Quoted in four places — the alert, `--update`, the cask caveats and the
    /// README — so it is spelled once and pinned here.
    func testTheUpgradeCommandNamesTheQualifiedCask() {
        XCTAssertEqual(UpdateCheck.upgradeCommand, "brew upgrade --cask alialhawas/harf/harf")
    }
}
