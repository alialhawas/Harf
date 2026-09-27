import Foundation

/// How this copy of Harf got onto the machine.
///
/// It exists for one reason: an update check has to end in an instruction the
/// user can actually follow, and the two installs have nothing in common.
/// Telling somebody who installed with `brew install --cask` to download a DMG
/// and drag it over their app leaves Homebrew's records pointing at a version
/// that is no longer there; telling somebody who dragged the app in to run
/// `brew upgrade` gives them a command that fails on a cask they never
/// installed.
public enum InstallKind: String, Equatable {
    case homebrew
    case directDownload

    /// - Parameter environment: the prefix lookup and the running executable,
    ///   injected so the whole decision can be driven against a temporary
    ///   directory tree. `.live()` is the real machine.
    public static func detect(in environment: InstallEnvironment = .live()) -> InstallKind {
        guard
            let prefix = environment.brewPrefix()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !prefix.isEmpty
        else { return .directDownload }

        let link = URL(fileURLWithPath: prefix).appendingPathComponent("bin/harf")

        // lstat, not stat: a `bin/harf` that is a regular file is a binary
        // somebody copied onto their PATH by hand, and `brew upgrade --cask`
        // would not touch it.
        let attributes = try? FileManager.default.attributesOfItem(atPath: link.path)
        guard attributes?[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .directDownload
        }

        let destination = link.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: destination.path) else {
            // A link left behind by a cask whose bundle has since been deleted.
            return .directDownload
        }

        // Both sides are resolved before they are compared, which is what makes
        // the two launches of the same install agree: started from the bundle
        // the running path is `/Applications/Harf.app/Contents/MacOS/Harf`, and
        // started as `harf` at a shell it is the symlink itself.
        //
        // Comparing paths rather than stopping at "the link exists" is the point
        // of this function. Two copies can be installed at once — one from the
        // cask, one from a checkout or a second download — and `brew upgrade`
        // replaces only the one the cask manages. When the running copy is not
        // that one, the honest answer is `.directDownload`: the brew command
        // would report success and change nothing the user is running.
        let running = URL(fileURLWithPath: environment.runningExecutable)
            .resolvingSymlinksInPath().standardizedFileURL
        return destination.path == running.path ? .homebrew : .directDownload
    }
}

/// The two facts `InstallKind.detect` reads, as values, so the detection is
/// testable without a Homebrew install and without being the app.
public struct InstallEnvironment {
    /// Homebrew's prefix, or nil when there is no Homebrew on this machine.
    /// A closure rather than a string because resolving it touches the
    /// filesystem, and a `.directDownload` answer must not pay for that.
    public var brewPrefix: () -> String?
    /// The path this process was started from. Not required to be resolved;
    /// `detect` resolves it.
    public var runningExecutable: String

    public init(brewPrefix: @escaping () -> String?, runningExecutable: String) {
        self.brewPrefix = brewPrefix
        self.runningExecutable = runningExecutable
    }

    public static func live() -> InstallEnvironment {
        InstallEnvironment(
            brewPrefix: { Homebrew.locate()?.prefix },
            // `Bundle.main.executablePath` is the path this process was
            // exec'd from, which through the cask's symlink is
            // `<prefix>/bin/harf` rather than the bundle. `detect` resolves it.
            runningExecutable: Bundle.main.executablePath
                ?? ProcessInfo.processInfo.arguments.first ?? "")
    }
}

/// Where Homebrew is, when it is anywhere.
public struct Homebrew: Equatable {
    /// The `brew` executable, which is what `harf --update` runs.
    public let executable: String
    /// The prefix `bin/harf` would be linked into.
    public let prefix: String

    /// - Parameter candidates: the standard install locations, tried after the
    ///   PATH. Apple silicon first, then Intel.
    ///
    /// Deliberately not a `brew --prefix` subprocess. Homebrew defines its
    /// prefix as the grandparent of the real path of the `brew` executable, so
    /// once that executable has been found the prefix is already known —
    /// spawning a shell script to be told it would be slower and could fail for
    /// reasons of its own. Finding the executable rather than assuming a path is
    /// what makes this correct on Intel (`/usr/local`) and on a custom prefix.
    ///
    /// The candidate list matters because of *where* this runs. A menu click
    /// happens inside an app LaunchServices started, and that process inherits a
    /// minimal PATH — `/usr/bin:/bin:/usr/sbin:/sbin`, with no Homebrew in it —
    /// so a PATH search alone would report every Homebrew install as a direct
    /// download whenever the question was asked from the menu rather than from a
    /// shell. A custom prefix with no `HOMEBREW_PREFIX` exported is the one
    /// reading this still cannot see from a GUI launch; it falls back to the
    /// manual instructions, which work.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    ) -> Homebrew? {
        var searched: [String] = []
        if let exported = environment["HOMEBREW_PREFIX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !exported.isEmpty
        {
            searched.append(exported + "/bin/brew")
        }
        searched += (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { "\($0)/brew" }
        searched += candidates

        for path in searched where FileManager.default.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let prefix = resolved
                .deletingLastPathComponent()  // bin
                .deletingLastPathComponent()  // the prefix
            guard !prefix.path.isEmpty, prefix.path != "/" else { continue }
            return Homebrew(executable: resolved.path, prefix: prefix.path)
        }
        return nil
    }
}
