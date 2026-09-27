import XCTest

@testable import DodomaCore

/// How this copy of Harf was installed, which decides what an update check
/// tells the user to do about it.
///
/// Every test builds a real directory tree in a temporary directory — a `bin`
/// with a symlink in it, a bundle for it to point at — rather than asserting
/// against `/opt/homebrew`. Homebrew's prefix is `/usr/local` on Intel and can
/// be anywhere at all, and a test that passes only on the machine it was
/// written on is not a test of the detection.
final class InstallKindTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstallKindTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `<root>/Applications/Harf.app/Contents/MacOS/Harf`, created for real so
    /// that the symlink has something to resolve to.
    private func makeBundledExecutable() throws -> String {
        let executable = root
            .appendingPathComponent("Applications/Harf.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        let binary = executable.appendingPathComponent("Harf")
        try Data("binary".utf8).write(to: binary)
        return binary.path
    }

    /// `<prefix>/bin/harf`, as a symlink to `target` — which is exactly what
    /// the cask's `binary` stanza creates.
    private func makeBrewPrefix(linking target: String?, linkName: String = "harf") throws
        -> String
    {
        let prefix = root.appendingPathComponent("opt/brew", isDirectory: true)
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if let target {
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent(linkName).path, withDestinationPath: target)
        }
        return prefix.path
    }

    private func detect(prefix: String?, running: String) -> InstallKind {
        InstallKind.detect(
            in: InstallEnvironment(brewPrefix: { prefix }, runningExecutable: running))
    }

    /// The shape verified on the machine this was written on:
    /// `/opt/homebrew/bin/harf -> /Applications/Harf.app/Contents/MacOS/Harf`.
    func testASymlinkIntoTheRunningBundleIsAHomebrewInstall() throws {
        let running = try makeBundledExecutable()
        let prefix = try makeBrewPrefix(linking: running)
        XCTAssertEqual(detect(prefix: prefix, running: running), .homebrew)
    }

    /// The same install, reached through the symlink rather than through the
    /// bundle: `harf --update` typed at a shell arrives with `argv[0]` pointing
    /// at the link. Both sides are resolved, so the two launches agree.
    func testTheSymlinkItselfIsAHomebrewInstall() throws {
        let running = try makeBundledExecutable()
        let prefix = try makeBrewPrefix(linking: running)
        XCTAssertEqual(
            detect(prefix: prefix, running: prefix + "/bin/harf"), .homebrew)
    }

    /// No brew on this machine at all. The commonest reading of a direct
    /// download, and the one that must not crash on a missing prefix.
    func testNoHomebrewIsADirectDownload() throws {
        let running = try makeBundledExecutable()
        XCTAssertEqual(detect(prefix: nil, running: running), .directDownload)
    }

    /// Homebrew installed, but Harf was not installed through it: the prefix
    /// resolves and `bin/harf` is simply not there.
    func testHomebrewWithNoHarfLinkIsADirectDownload() throws {
        let running = try makeBundledExecutable()
        let prefix = try makeBrewPrefix(linking: nil)
        XCTAssertEqual(detect(prefix: prefix, running: running), .directDownload)
    }

    /// The case that decides why this check compares paths rather than just
    /// looking for the link: two copies installed, and the one running is not
    /// the one the cask manages. `brew upgrade` would upgrade the *other* copy
    /// and leave this one exactly as it is — so the running copy has to be told
    /// it is a direct download, which is what it is.
    func testALinkPointingAtADifferentCopyIsADirectDownload() throws {
        let caskCopy = try makeBundledExecutable()
        let prefix = try makeBrewPrefix(linking: caskCopy)
        let checkout = root.appendingPathComponent("checkout/.build/release", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let other = checkout.appendingPathComponent("Harf")
        try Data("binary".utf8).write(to: other)

        XCTAssertEqual(detect(prefix: prefix, running: other.path), .directDownload)
    }

    /// A `bin/harf` that is a regular file rather than a symlink is not
    /// something the cask made — somebody copied a binary onto their PATH — and
    /// `brew upgrade --cask` would not touch it.
    func testAPlainFileOnThePathIsNotAHomebrewInstall() throws {
        let running = try makeBundledExecutable()
        let prefix = try makeBrewPrefix(linking: nil)
        try Data("binary".utf8).write(to: URL(fileURLWithPath: prefix + "/bin/harf"))
        XCTAssertEqual(detect(prefix: prefix, running: running), .directDownload)
    }

    /// A link left behind by a cask whose bundle has since been deleted. It
    /// resolves to nothing, and nothing is not the running copy.
    func testADanglingLinkIsADirectDownload() throws {
        let running = try makeBundledExecutable()
        let prefix = try makeBrewPrefix(linking: root.appendingPathComponent("gone/Harf").path)
        XCTAssertEqual(detect(prefix: prefix, running: running), .directDownload)
    }

    /// An empty prefix — `brew --prefix` printing nothing, or a blank
    /// `HOMEBREW_PREFIX` — must not turn into a check of `/bin/harf`.
    func testABlankPrefixIsADirectDownload() throws {
        let running = try makeBundledExecutable()
        XCTAssertEqual(detect(prefix: "  ", running: running), .directDownload)
    }

    /// The live probe has to answer *something* on any machine, including a
    /// test runner out of `.build` where the answer is a direct download. It is
    /// the only thing here that reads the real filesystem, and it asserts no
    /// particular answer: what it must not do is trap.
    func testTheLiveEnvironmentResolvesWithoutTrapping() {
        XCTAssertNotNil(InstallKind.detect(in: .live()))
    }

    // MARK: - Finding Homebrew

    /// `<prefix>/bin/brew`, executable, so `Homebrew.locate` can find it.
    private func makeBrewExecutable(prefix: String) throws -> String {
        let bin = URL(fileURLWithPath: prefix).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew")
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brew.path)
        return brew.path
    }

    /// The prefix is the grandparent of the `brew` executable, which is how
    /// Homebrew itself defines it. Nothing assumes `/opt/homebrew`.
    func testThePrefixIsDerivedFromWhereBrewActuallyIs() throws {
        let prefix = root.appendingPathComponent("custom/brew").path
        let brew = try makeBrewExecutable(prefix: prefix)

        let found = Homebrew.locate(environment: ["PATH": prefix + "/bin"], candidates: [])
        XCTAssertEqual(found?.executable, brew)
        XCTAssertEqual(found?.prefix, prefix)
    }

    /// A GUI launch gets a minimal PATH from LaunchServices, with no Homebrew in
    /// it, so the standard locations are tried as well.
    func testTheStandardLocationsAreTriedWhenPathHasNoBrew() throws {
        let prefix = root.appendingPathComponent("opt/homebrew").path
        let brew = try makeBrewExecutable(prefix: prefix)

        let found = Homebrew.locate(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], candidates: [brew])
        XCTAssertEqual(found?.prefix, prefix)
    }

    /// `brew shellenv` exports this, and it is the only signal that finds a
    /// prefix nobody standard put there.
    func testHomebrewPrefixInTheEnvironmentIsBelievedWhenItHasABrewInIt() throws {
        let prefix = root.appendingPathComponent("elsewhere").path
        _ = try makeBrewExecutable(prefix: prefix)

        let found = Homebrew.locate(
            environment: ["HOMEBREW_PREFIX": prefix, "PATH": ""], candidates: [])
        XCTAssertEqual(found?.prefix, prefix)
    }

    /// No brew anywhere. nil rather than a guessed path, because every caller
    /// turns nil into "this is a direct download" and a guess would turn into an
    /// upgrade command that cannot run.
    func testNoBrewAnywhereIsNil() {
        XCTAssertNil(
            Homebrew.locate(
                environment: ["PATH": root.appendingPathComponent("empty").path],
                candidates: [root.appendingPathComponent("nope/bin/brew").path]))
    }
}
