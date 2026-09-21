import XCTest
@testable import DodomaCore

final class VersionTests: XCTestCase {
    /// Shape, not value. `testVersionMatchesInfoPlist` is what pins the number,
    /// and a literal here would make a version bump a three-file edit — the
    /// third of which nobody remembers until CI fails.
    func testVersionIsASemanticVersion() {
        let parts = Dodoma.version.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "'\(Dodoma.version)' is not major.minor.patch")
        for part in parts {
            XCTAssertNotNil(Int(part), "'\(part)' in '\(Dodoma.version)' is not a number")
        }
    }

    /// `Dodoma.version` is a literal (see the note on it), so nothing at
    /// runtime notices when a release bumps `Resources/Info.plist` and leaves
    /// the literal behind: the app would report the previous version in
    /// `--status` and in every log line while calling itself the new one
    /// everywhere users can see. This is the check that catches that drift.
    func testVersionMatchesInfoPlist() throws {
        let plist = Self.repositoryRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        let entries = try XCTUnwrap(parsed as? [String: Any], "Info.plist is not a dictionary")

        let short = try XCTUnwrap(
            entries["CFBundleShortVersionString"] as? String,
            "Info.plist has no CFBundleShortVersionString")
        XCTAssertEqual(
            Dodoma.version, short,
            "Dodoma.version and CFBundleShortVersionString have drifted. Bump both.")

        // CFBundleVersion is the build number scripts/release.sh increments. It
        // has to stay an integer: macOS compares it numerically, and a
        // non-numeric value makes update comparisons undefined.
        let build = try XCTUnwrap(
            entries["CFBundleVersion"] as? String, "Info.plist has no CFBundleVersion")
        XCTAssertNotNil(Int(build), "CFBundleVersion '\(build)' is not an integer")
    }

    /// `#filePath` is `Tests/DodomaCoreTests/VersionTests.swift`; the root is
    /// three levels up. `Bundle.module` cannot be used here — `Info.plist` is
    /// an app-bundle input, not a test resource.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
