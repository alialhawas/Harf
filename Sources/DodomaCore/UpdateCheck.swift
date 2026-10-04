import Foundation

/// Comparing the version this build carries against the newest tagged release,
/// and nothing else.
///
/// This is the only thing in Harf that can open a socket, and it does so only
/// when a person asks — the "Check for Updates…" item in the menu, or `harf
/// --update`. There is no timer, no check at launch and no setting that turns
/// one on, which is what keeps the README's promise worth making: Harf makes no
/// network request unless you ask it for one.
///
/// The fetch is a closure rather than a `URLSession` call inline, for the usual
/// reason `DodomaCore` keeps I/O at its edges: every reading below — a 403 from
/// a rate limiter, a truncated body, a tag nobody can parse — is a value a test
/// passes in, so the whole decision is covered without a single test touching
/// the network.
public enum UpdateCheck {
    /// Where the check looks. The releases endpoint rather than the tags one:
    /// tags include anything anybody pushed, releases are what was published.
    public static let endpoint = URL(
        string: "https://api.github.com/repos/alialhawas/Harf/releases/latest")!

    /// Short on purpose. This runs behind a menu click, so the user is watching
    /// a menu that has already closed; a minute of default `URLSession`
    /// patience reads as nothing having happened at all. Ten seconds is long
    /// enough for a slow hotel network and short enough that the alert arrives
    /// while the click is still in mind.
    public static let timeout: TimeInterval = 10

    /// The command that upgrades a Homebrew install, in one place because it is
    /// quoted by the alert, by `harf --update`, by the cask's caveats and by
    /// the README.
    public static let upgradeCommand = "brew upgrade --cask alialhawas/harf/harf"

    /// Where a release is read by a human, for the install that has no upgrade
    /// command to run.
    public static let releasesPage = URL(string: "https://github.com/alialhawas/Harf/releases")!

    // MARK: - The answer

    public enum Result: Equatable {
        /// Nothing to do. Carries the version so the alert can say which one.
        case upToDate(version: String)
        /// A newer release exists, with the page it is described on.
        case updateAvailable(version: String, releaseURL: URL)
        /// The check did not produce an answer, in words a person can act on.
        ///
        /// Deliberately distinct from `upToDate`. Every failure here — no
        /// network, a rate limiter, a tag that cannot be parsed — used to be
        /// tempting to collapse into "you are up to date", which is the one
        /// wrong answer that looks like a right one: it tells somebody running
        /// a version with a bug in it that there is nothing to install.
        case failed(reason: String)
    }

    // MARK: - The fetch, and the only I/O in this file

    /// What a fetch of the releases endpoint came back with.
    ///
    /// Two cases rather than a `Swift.Result`, because an HTTP reply that
    /// arrived is not an error even when its status is 500: the status and the
    /// headers are what distinguish a rate limiter from an outage, and both have
    /// to survive as far as the wording of the alert.
    public enum Fetched: Equatable {
        case response(status: Int, headers: [String: String], body: Data)
        /// Nothing arrived: no route, DNS, a captive portal, the timeout above.
        case transportFailure(String)
    }

    /// Supplied by the caller so that no test needs a network. `check` defaults
    /// it to `networkFetch()`, which is the one place a socket is opened.
    public typealias Fetch = (@escaping (Fetched) -> Void) -> Void

    /// The live fetch.
    ///
    /// No entitlement is required for this. The app is built with the hardened
    /// runtime and ships no entitlements file, and the hardened runtime does not
    /// restrict outgoing connections — that is the App Sandbox's
    /// `com.apple.security.network.client`, and Harf is not sandboxed (it could
    /// not be: it holds a system-wide event tap).
    public static func networkFetch(session: URLSession = .shared) -> Fetch {
        { completion in
            var request = URLRequest(url: endpoint, timeoutInterval: timeout)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Harf/\(Dodoma.version)", forHTTPHeaderField: "User-Agent")
            // A manual check answered out of the URL cache would tell somebody
            // who just heard about a release that there is nothing to install.
            request.cachePolicy = .reloadIgnoringLocalCacheData

            session.dataTask(with: request) { data, response, error in
                if let error {
                    return completion(.transportFailure(error.localizedDescription))
                }
                guard let http = response as? HTTPURLResponse else {
                    return completion(.transportFailure("GitHub's reply was not an HTTP response."))
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String {
                        headers[key] = value
                    }
                }
                completion(
                    .response(status: http.statusCode, headers: headers, body: data ?? Data()))
            }.resume()
        }
    }

    /// The whole check: fetch, then read. Runs the completion on whatever thread
    /// the fetch finished on — `URLSession` means a background one — so a caller
    /// with a UI marshals it to the main thread itself.
    public static func check(
        current: String = Dodoma.version,
        fetch: Fetch = networkFetch(),
        completion: @escaping (Result) -> Void
    ) {
        fetch { completion(interpret($0, current: current)) }
    }

    // MARK: - Reading the reply

    /// Pure, and the reason the rest of this file needs no network to be tested.
    public static func interpret(_ fetched: Fetched, current: String = Dodoma.version) -> Result {
        switch fetched {
        case .transportFailure(let reason):
            return .failed(reason: "Could not reach GitHub. \(reason)")

        case .response(let status, let headers, let body):
            if let limited = rateLimitReason(status: status, headers: headers) {
                return .failed(reason: limited)
            }
            guard status == 200 else {
                return .failed(
                    reason: "GitHub answered HTTP \(status) instead of the release list. "
                        + "Try again, or look at \(releasesPage.absoluteString).")
            }

            let parsed = try? JSONSerialization.jsonObject(with: body)
            guard let release = parsed as? [String: Any] else {
                return .failed(
                    reason: "GitHub's reply could not be read as a release. Try again, or "
                        + "look at \(releasesPage.absoluteString).")
            }
            guard let tag = release["tag_name"] as? String, !tag.isEmpty else {
                return .failed(
                    reason: "GitHub's newest release carries no tag name, so there is no "
                        + "version to compare against \(current).")
            }
            guard let newer = isNewer(tag, than: current) else {
                return .failed(
                    reason: "GitHub's newest release is tagged '\(tag)', which is not a "
                        + "version number this can compare against \(current). "
                        + "See \(releasesPage.absoluteString).")
            }
            guard newer else { return .upToDate(version: current) }
            return .updateAvailable(
                version: displayVersion(of: tag), releaseURL: releaseURL(in: release))
        }
    }

    /// GitHub allows 60 unauthenticated requests an hour per address, which an
    /// office behind one NAT shares. It is the most likely way this check fails
    /// in practice, and it arrives as a bare 403 — a status that on its own
    /// reads as "you are not allowed", which is the wrong thing to tell
    /// somebody whose only problem is the clock.
    ///
    /// nil when this is not a limiter, so a genuine 403 keeps its own wording.
    private static func rateLimitReason(status: Int, headers: [String: String]) -> String? {
        let exhausted = header("X-RateLimit-Remaining", in: headers) == "0"
        guard status == 429 || (status == 403 && exhausted) else { return nil }
        return "GitHub's rate limit for this network has been reached — it allows a limited "
            + "number of unauthenticated requests an hour. Try again later, or look at "
            + "\(releasesPage.absoluteString)."
    }

    /// HTTP/2 lower-cases header names on the wire and `HTTPURLResponse` hands
    /// back what the server sent, so the name this code is written with is not
    /// the name it arrives under on a real connection.
    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The tag without its `v`, because that is how the app spells its version
    /// in `--status`, in the menu and in every log line.
    private static func displayVersion(of tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func releaseURL(in release: [String: Any]) -> URL {
        guard let raw = release["html_url"] as? String, let url = URL(string: raw) else {
            return releasesPage
        }
        return url
    }

    // MARK: - Comparing two versions

    /// Whether `tag` names a version after `current`, or nil when either side
    /// cannot be read as a version.
    ///
    /// nil is not "no": a tag this cannot parse is reported to the user as a
    /// failed check, because the alternative is telling somebody they are
    /// current on the strength of a string nobody understood.
    public static func isNewer(_ tag: String, than current: String) -> Bool? {
        guard let candidate = components(of: tag), let installed = components(of: current) else {
            return nil
        }
        for (left, right) in zip(candidate, installed) where left != right {
            return left > right
        }
        return false
    }

    /// `major.minor.patch` as three numbers, or nil when the string is not that.
    ///
    /// Numeric and component-wise, because the comparison it feeds cannot be a
    /// string comparison: "1.0.10" sorts before "1.0.9" lexically, so the tenth
    /// patch of a line would read as older than the ninth and everybody on
    /// 1.0.9 would be told they were current for good.
    ///
    /// Shorter is padded — `v1.1` means 1.1.0, and refusing to read a tag
    /// somebody typed by hand would report a failure to every user on the day
    /// of that release. Anything else is rejected rather than guessed at:
    /// a fourth component, a `-beta.2` suffix, an empty component, a negative
    /// number. Harf has no pre-release channel, so a tag with a suffix is a
    /// tag this code was not written for, and saying so is better than ranking
    /// it by a rule nobody chose.
    static func components(of version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = String(text.dropFirst()) }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            // `Int("+1")` and `Int("-1")` both succeed, and neither is a version
            // component. Digits only.
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}
