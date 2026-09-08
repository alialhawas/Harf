public enum Dodoma {
    /// The version reported by `--status`, `--help` and every log line.
    ///
    /// Deliberately a literal rather than a read of `Bundle.main`'s
    /// `CFBundleShortVersionString`. The same binary is the menu-bar app and
    /// the command line, and `Bundle.main` does not describe it in every one
    /// of those launches: it is the bundle only when the app is started from
    /// `Harf.app`, and carries no Info.plist under `swift run` or when the
    /// executable is invoked through the Homebrew `harf` symlink. A
    /// bundle-derived version would therefore report a different number
    /// depending on how the same build was started, which is worse than one
    /// number that is always the same. `DodomaCore` is also a pure library and
    /// has no business reaching for the host application's bundle.
    ///
    /// The literal is kept honest by `VersionTests`, which parses
    /// `Resources/Info.plist` and fails if the two ever drift. Bump both.
    public static let version = "1.0.0"
}
