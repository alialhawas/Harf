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

    private struct Store: Codable, Equatable {
        var counts: [String: Int] = [:]
        var manual: [String] = []
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.ali.dodoma.lexicon", qos: .utility)
    private var lastSaved: Date?
    private var stores: [String: Store] = [:]
    /// What the file held the last time this process read or wrote it.
    ///
    /// The third point of reference a merge needs. Two processes hold the same
    /// vocabulary and neither can see the other's memory, so "in the file but
    /// not in mine" is ambiguous on its own — it is either a word the other
    /// process just added or one this process removed a moment ago — and so is
    /// the reverse. Against what the file said last, both become unambiguous:
    /// whichever side moved away from it is the side that changed.
    private var baseline: [String: Store] = [:]
    private var dirty = false
    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url
        if let url, case .contents(let decoded) = Self.read(url) {
            stores = decoded
            baseline = decoded
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
        let pending = dirty
        lock.unlock()
        guard pending, let url else { return false }

        // Whatever another process wrote since this one last looked is folded
        // in before anything is written back, because this is the write that
        // would otherwise lose it: `harf --words add` edits the file, and a
        // save landing between that edit and the message announcing it used to
        // put the in-memory copy straight over the top. Read off the lock —
        // the file runs to thousands of words and decoding it under the lock
        // would put the typing queue's `contains` behind it.
        let disk = Self.read(url)
        lock.lock()
        adopt(disk)
        guard dirty else { lock.unlock(); return false }
        let snapshot = Self.persisted(stores)
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
        // Only now, and only on a write that happened: a baseline claiming the
        // file holds something it does not would read the next merge backwards.
        lock.lock()
        baseline = snapshot
        lock.unlock()
        return true
    }

    /// Erases everything remembered, on disk as well as in memory.
    ///
    /// Turning learning off should not leave the previous answer lying around,
    /// and somebody who wants this gone wants it gone.
    public func clear() {
        lock.lock()
        stores = [:]
        baseline = [:]
        dirty = false
        let path = url
        lock.unlock()
        if let path { try? FileManager.default.removeItem(at: path) }
    }

    // MARK: - An edit made in another process

    /// Folds an edit another process made to the file into what is held here.
    ///
    /// `harf --words add`, `remove` and `clear` write the file and then ask the
    /// running copy — over the single-instance port — to call this. Without it
    /// the app's own copy was authoritative by accident: the file changed, the
    /// app knew nothing about it, and its next save wrote the old vocabulary
    /// back over the new one within about twenty seconds.
    ///
    /// A merge rather than a reload, because the two copies know different
    /// things and both are right. The file carries the edit; memory carries
    /// every sighting counted since the last save, including the ones still
    /// short of the threshold, which are never written at all. Taking the file
    /// wholesale would throw a session of counting away to add one word.
    ///
    /// - Returns: whether anything moved, so a caller can log it.
    @discardableResult
    public func reload() -> Bool {
        guard let url else { return false }
        let disk = Self.read(url)
        lock.lock(); defer { lock.unlock() }
        return adopt(disk)
    }

    /// The same, on the queue this type already owns for touching the file.
    ///
    /// What the port callback calls. It runs on the app's main run loop, where
    /// reading and decoding the file is exactly the wrong thing to do, and
    /// there is nothing to wait for: the CLI has already written the change and
    /// does not read anything back.
    public func reloadSoon() {
        ioQueue.async { [weak self] in self?.reload() }
    }

    /// The file as it stands, in the three states a merge treats differently.
    private enum OnDisk {
        case contents([String: Store])
        /// Not there. Either nothing has ever been written, or somebody ran
        /// `--words clear`, which deletes it.
        case gone
        /// There and unreadable — mid-write, or not JSON at all. It says
        /// nothing, so nothing is concluded from it.
        case unreadable
    }

    private static func read(_ url: URL) -> OnDisk {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .gone
        }
        guard let decoded = try? JSONDecoder().decode([String: Store].self, from: data) else {
            return .unreadable
        }
        return .contents(decoded)
    }

    /// Takes the file's side of the story. Call with the lock held.
    @discardableResult
    private func adopt(_ disk: OnDisk) -> Bool {
        switch disk {
        case .unreadable:
            return false
        case .gone:
            // Deleting the file is how `clear` travels between processes, and
            // somebody who asked for everything to go meant the words still
            // counting too. Guarded by the baseline so that the ordinary case —
            // a copy that has learned something and never yet saved — is not
            // read as a clear: there the file has never existed.
            guard !baseline.isEmpty else { return false }
            stores = [:]
            baseline = [:]
            dirty = false
            return true
        case .contents(let current):
            guard current != baseline else { return false }
            stores = Self.merge(mine: stores, base: baseline, theirs: current)
            baseline = current
            dirty = Self.persisted(stores) != current
            return true
        }
    }

    /// Three-way, against what the file last said.
    ///
    /// Only what moved away from the baseline is taken from the file; anything
    /// this process alone knows is left where it is. So a word added from a
    /// shell appears, a word removed there stays removed, and neither touches
    /// the tally of sightings this session has accumulated in memory.
    private static func merge(
        mine: [String: Store], base: [String: Store], theirs: [String: Store]
    ) -> [String: Store] {
        var merged = mine
        for language in Set(base.keys).union(theirs.keys) {
            let was = base[language] ?? Store()
            let now = theirs[language] ?? Store()
            var ours = merged[language] ?? Store()
            for (word, count) in now.counts where was.counts[word] != count {
                ours.counts[word] = count
            }
            for word in was.counts.keys where now.counts[word] == nil {
                ours.counts[word] = nil
            }
            for word in now.manual where !was.manual.contains(word) {
                if !ours.manual.contains(word) { ours.manual.append(word) }
            }
            for word in was.manual where !now.manual.contains(word) {
                ours.manual.removeAll { $0 == word }
            }
            merged[language] = ours
        }
        return merged
    }

    /// What reaches disk: the promoted and the hand-added. Sub-threshold counts
    /// stay in memory — see the type's own header — so this is also the form
    /// memory has to be reduced to before it can be compared with the file.
    private static func persisted(_ stores: [String: Store]) -> [String: Store] {
        stores.mapValues {
            Store(
                counts: $0.counts.filter { $0.value >= promotionThreshold },
                manual: $0.manual)
        }
    }

    /// Where the file lives when the app is running normally.
    public static func defaultURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Harf", isDirectory: true)
            .appendingPathComponent("lexicon.json")
    }
}
