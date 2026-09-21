import Foundation
import XCTest

/// What has to be true of the repository for the packaged app to carry its
/// icon, and what must never become true of it.
///
/// These read the source tree rather than a bundle: `make bundle` copies
/// `Resources/` verbatim, so the tree is where the mistake would be made, and
/// the test suite does not build an `.app`. `#filePath` is what makes the
/// files findable from a test binary that runs out of `.build`.
final class BrandPackagingTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // DodomaAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    private func infoPlist() throws -> [String: Any] {
        let url = Self.repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    /// `CFBundleIconFile` names the icon file inside `Contents/Resources`,
    /// without its extension. Nothing else makes the Finder, the Dock or a
    /// permission prompt show anything but a blank sheet of paper.
    func testTheBundleDeclaresItsIcon() throws {
        XCTAssertEqual(try infoPlist()["CFBundleIconFile"] as? String, "AppIcon")
    }

    /// The identifier is what macOS keys the Accessibility and Input
    /// Monitoring grants to. Changing it silently revokes both for everyone
    /// who has already approved the app, so it is pinned here alongside the
    /// branding it survived.
    func testTheBundleIdentifierIsUnchanged() throws {
        XCTAssertEqual(try infoPlist()["CFBundleIdentifier"] as? String, "com.ali.dodoma")
    }

    func testTheIconIsPresentAndIsAnIconFile() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Resources/AppIcon.icns")
        let data = try Data(contentsOf: url)
        // The `icns` magic, then a big-endian byte count for the whole file.
        XCTAssertEqual(Array(data.prefix(4)), Array("icns".utf8))
        // Ten representations up to 1024px; anything much smaller means the
        // rasteriser produced empty or partial images.
        XCTAssertGreaterThan(data.count, 100_000)
    }

    /// The identity is traced from Thmanyah Sans, whose licence permits the
    /// letterform in a logo and forbids redistributing the font software. IBM
    /// Plex Sans Arabic, the alternative face, is OFL and may be redistributed
    /// but is not needed at runtime either: everything ships as outlines.
    ///
    /// So no font file belongs in the three directories that are shipped or
    /// rendered. The check is scoped to those rather than the whole tree
    /// because legitimately licensed web fonts may live under `docs/assets/`.
    func testNoFontFileIsCommittedWhereTheBrandLives() throws {
        let suffixes = ["otf", "ttf", "ttc", "woff", "woff2"]
        var offenders: [String] = []
        for directory in ["docs/brand", "Resources", "Sources"] {
            let root = Self.repositoryRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker
            where suffixes.contains(url.pathExtension.lowercased()) {
                offenders.append(url.path)
            }
        }
        XCTAssertEqual(offenders, [], "font files may not be committed here")
    }
}
