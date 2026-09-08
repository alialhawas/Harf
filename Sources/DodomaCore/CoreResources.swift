import Foundation

/// Finds the files SwiftPM copies into `Dodoma_DodomaCore.bundle`.
///
/// `Bundle.module` is not used, deliberately. SwiftPM generates it as
///
///     Bundle(path: Bundle.main.bundleURL/"Harf_DodomaCore.bundle")
///         ?? Bundle(path: "<absolute path into this machine's .build>")
///         ?? fatalError()
///
/// which is wrong twice over for a shipped `.app`: `Bundle.main.bundleURL` is
/// `Dodoma.app` itself, where nothing may live outside `Contents/` without
/// breaking the bundle format and its signature, and the fallback is an
/// absolute path that only exists on the machine that built the binary. On any
/// other Mac the first read of `Bundle.module` would `fatalError`, and on this
/// one it would appear to work while actually reading out of `.build`.
///
/// So the candidate directories are searched explicitly, covering the three
/// contexts the code runs in: `swift run` (bundle next to the executable),
/// `swift test` (bundle next to the `.xctest` package) and the packaged app
/// (bundle inside `Contents/Resources`, put there by `make bundle`).
enum CoreResources {
    /// Marker class used to locate the bundle this code was linked into.
    private final class Token {}

    static let bundleName = "Harf_DodomaCore.bundle"

    static func url(forResource name: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Deduplicated, in priority order.
    static let searchDirectories: [URL] = {
        let own = Bundle(for: Token.self)
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        if let resources = own.resourceURL { roots.append(resources) }
        roots.append(own.bundleURL)
        roots.append(own.bundleURL.deletingLastPathComponent())

        var directories: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let bundle = root.appendingPathComponent(bundleName)
            for candidate in [
                bundle.appendingPathComponent("Resources"),
                bundle.appendingPathComponent("Contents/Resources"),
                bundle,
                root.appendingPathComponent("Resources"),
            ] where seen.insert(candidate.standardizedFileURL.path).inserted {
                directories.append(candidate)
            }
        }
        return directories
    }()
}
