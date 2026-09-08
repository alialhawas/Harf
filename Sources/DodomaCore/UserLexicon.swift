import Foundation

/// Words this user actually writes, alongside the shipped frequency lists.
///
/// The bundled lists come from film subtitles, which is the right corpus for
/// ordinary prose and the wrong one for the way anybody works: `pr`, `dto`,
/// `async` and `endpoint` all score zero against them, and every unrecognised
/// token drags a reading down. Somebody who types those words hourly is not
/// writing gibberish, but the score cannot tell the difference.
///
/// So the lexicon watches. When a run is looked at and judged fine as it
/// stands, the words in it are evidence about this person's vocabulary, and a
/// word seen often enough is promoted to a real one. Manual entries skip the
/// counting for the cases learning cannot reach.
///
/// Only the promoted and the hand-added ever reach disk. A word still counting
/// has changed no score and is nothing but a record that this person typed it,
/// so it lives in memory for as long as the app is running and no longer. The
/// price is that ten sightings have to happen in one session; the alternative
/// was a file of everything unusual anybody had typed near the app, written
/// twenty seconds after the first sighting.
public final class UserLexicon: @unchecked Sendable {
    /// Sightings before a word counts. High enough that a one-off wrong-layout
    /// run that slipped past the detector never reaches it.
    public static let promotionThreshold = 10
    /// Shorter than this and a counted token is not vocabulary, it is noise.
    public static let minimumLength = 3
    /// Floor for a word put here by hand.
    ///
    /// `pr` is the example in this file's own header, and counting can never
    /// reach it: two-letter tokens are dropped on the way in precisely because
    /// a passive count cannot tell a word from a fragment. Somebody typing the
    /// word out and asking for it is the evidence the counter is missing, so
    /// the manual path is the one place the floor drops.
    public static let manualMinimumLength = 2
    /// Ceiling on remembered words per language; the rarest are dropped first.
    public static let capacity = 8_000

    private struct Store: Codable {
        var counts: [String: Int] = [:]
        var manual: [String] = []
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.ali.dodoma.lexicon", qos: .utility)
    private var lastSaved: Date?
    private var stores: [String: Store] = [:]
    private var dirty = false
    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Store].self, from: data)
        {
            stores = decoded
        }
    }

    // MARK: - Reading

    /// Whether this user's own vocabulary vouches for the token.
    ///
    /// Normalises on the way in, as `add` does on the way out. Both sides have
    /// to agree on what "the same word" is, or an Arabic entry stored with its
    /// tāʾ marbūṭa folded would never match the word that taught it. The
    /// normalisation is idempotent, so the scoring path — which hands over
    /// already-normalised forms — pays only for a scan of a short token.
    ///
    /// The two routes have different floors. A hand-added `pr` is a claim about
    /// this user's vocabulary and is honoured at two letters; a counted `pr` is
    /// a two-letter fragment that happened to recur, and is not.
    public func contains(_ token: String, language: Language) -> Bool {
        guard token.count >= Self.manualMinimumLength else { return false }
        let key = LanguageModel.normalize(token, for: language)
        lock.lock(); defer { lock.unlock() }
        guard let store = stores[language.rawValue] else { return false }
        if store.manual.contains(key) { return true }
        guard token.count >= Self.minimumLength else { return false }
        return (store.counts[key] ?? 0) >= Self.promotionThreshold
    }

    /// Words promoted by use, most seen first, for the settings list.
    public func learned(_ language: Language) -> [(word: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        guard let store = stores[language.rawValue] else { return [] }
        return store.counts
            .filter { $0.value >= Self.promotionThreshold }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (word: $0.key, count: $0.value) }
    }

    /// Words seen but not yet promoted, most seen first.
    ///
    /// Ten sightings is a long wait to watch in silence; showing the count on
    /// the way there is the difference between a rule someone can verify and
    /// one they have to trust.
    public func pending(_ language: Language) -> [(word: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        guard let store = stores[language.rawValue] else { return [] }
        return store.counts
            .filter { $0.value < Self.promotionThreshold }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (word: $0.key, count: $0.value) }
    }

    public func manualWords(_ language: Language) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (stores[language.rawValue]?.manual ?? []).sorted()
    }

    // MARK: - Writing

    /// Records a sighting of each token.
    ///
    /// Callers pass only words the shipped list does not already contain, so
    /// what accumulates here is the gap between the two — never a record of
    /// ordinary writing. And only from text the detector examined and left
    /// alone, which is the one moment the app has grounds to believe the words
    /// are real: it looked at the run, in this language, and found nothing to
    /// correct.
    /// - Returns: the words this call pushed over the threshold, in the order
    ///   they were seen. Only the crossing counts: a word already known adds
    ///   nothing to tell the user about, and one still counting has not
    ///   changed how anything scores yet.
    @discardableResult
    public func observe(_ tokens: [String], language: Language) -> [String] {
        let worth = tokens.filter { $0.count >= Self.minimumLength }
        guard !worth.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        var store = stores[language.rawValue] ?? Store()
        var promoted: [String] = []
        for token in worth {
            let key = LanguageModel.normalize(token, for: language)
            let before = store.counts[key] ?? 0
            let after = before + 1
            store.counts[key] = after
            // Strictly the crossing, so a word seen for the eleventh time does
            // not announce itself again.
            if before < Self.promotionThreshold, after >= Self.promotionThreshold,
               !store.manual.contains(key)
            {
                promoted.append(key)
            }
        }
        if store.counts.count > Self.capacity { evict(&store) }
        stores[language.rawValue] = store
        dirty = true
        return promoted
    }

    /// Records a word by hand, past the counting.
    ///
    /// Held to `manualMinimumLength` rather than `minimumLength`: this is the
    /// only route to the short words — `pr`, `qa`, `ci` — that `observe` throws
    /// away as noise before it can ever count them.
    public func add(_ word: String, language: Language) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.manualMinimumLength else { return }
        let key = LanguageModel.normalize(trimmed, for: language)
        lock.lock(); defer { lock.unlock() }
        var store = stores[language.rawValue] ?? Store()
        if !store.manual.contains(key) { store.manual.append(key) }
        stores[language.rawValue] = store
        dirty = true
    }

    /// Removes a word however it got there, so a mistakenly learned token can
    /// be taken back without hunting for which list it is in.
    public func remove(_ word: String, language: Language) {
        let key = LanguageModel.normalize(word, for: language)
        lock.lock(); defer { lock.unlock() }
        guard var store = stores[language.rawValue] else { return }
        store.manual.removeAll { $0 == key }
        store.counts[key] = nil
        stores[language.rawValue] = store
        dirty = true
    }

    /// Drops what counting learned about a word, leaving a hand-added entry
    /// alone.
    ///
    /// A flip is the user saying the run was never words in this language, so
    /// the sightings it accumulated were miscounted and go. A word somebody
    /// typed out and asked for outranks that inference, and is never touched:
    /// `remove` is the way to take one of those back.
    public func forgetCount(_ word: String, language: Language) {
        let key = LanguageModel.normalize(word, for: language)
        lock.lock(); defer { lock.unlock() }
        guard var store = stores[language.rawValue], !store.manual.contains(key) else { return }
        store.counts[key] = nil
        stores[language.rawValue] = store
        dirty = true
    }

    /// Drops the rarest half once the cap is hit.
    ///
    /// Halving rather than trimming to the limit means this runs rarely instead
    /// of on nearly every write once the cap is reached. Promoted words are
    /// kept regardless of where they fall.
    private func evict(_ store: inout Store) {
        let keep = store.counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(Self.capacity / 2)
        store.counts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: - Persistence

    /// Writes at most once per `interval`, off the calling queue.
    ///
    /// Saving only at quit meant the file — which is what `harf --words` reads
    /// — stayed empty for as long as the app kept running, so nobody could see
    /// what was being learned about them until they closed it. That is the
    /// wrong way round for a privacy surface.
    public func saveIfDue(interval: TimeInterval = 20) {
        lock.lock()
        let due = dirty && (lastSaved.map { Date().timeIntervalSince($0) >= interval } ?? true)
        if due { lastSaved = Date() }
        lock.unlock()
        guard due else { return }
        ioQueue.async { [weak self] in self?.save() }
    }

    @discardableResult
    public func save() -> Bool {
        lock.lock()
        guard dirty, let url else { lock.unlock(); return false }
        // Sub-threshold counts stay in memory. See the type's own header: what
        // is written is what changes a score, never the tally on the way there.
        let snapshot = stores.mapValues {
            Store(
                counts: $0.counts.filter { $0.value >= Self.promotionThreshold },
                manual: $0.manual)
        }
        dirty = false
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        let manager = FileManager.default
        // The directory and the file are owner-only. This holds words the user
        // typed, which is the one thing this app puts on disk, and the default
        // 0644 would let every process running as any user on the machine read
        // it. Set on create and re-applied on write, since an atomic write
        // replaces the inode and takes the umask with it.
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Erases everything remembered, on disk as well as in memory.
    ///
    /// Turning learning off should not leave the previous answer lying around,
    /// and somebody who wants this gone wants it gone.
    public func clear() {
        lock.lock()
        stores = [:]
        dirty = false
        let path = url
        lock.unlock()
        if let path { try? FileManager.default.removeItem(at: path) }
    }

    /// Where the file lives when the app is running normally.
    public static func defaultURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Harf", isDirectory: true)
            .appendingPathComponent("lexicon.json")
    }
}
