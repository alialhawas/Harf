import XCTest

@testable import DodomaCore

final class UserLexiconTests: XCTestCase {
    private func lexicon() -> UserLexicon { UserLexicon(url: nil) }

    /// A word is not vocabulary because it appeared once.
    func testAWordIsNotKnownUntilItIsSeenEnough() {
        let lex = lexicon()
        for seen in 1..<UserLexicon.promotionThreshold {
            lex.observe(["endpoint"], language: .english)
            XCTAssertFalse(
                lex.contains("endpoint", language: .english),
                "promoted after only \(seen) sightings")
        }
        lex.observe(["endpoint"], language: .english)
        XCTAssertTrue(lex.contains("endpoint", language: .english))
    }

    /// Manual entries skip the counting, which is the point of having them.
    func testAManualWordCountsImmediately() {
        let lex = lexicon()
        lex.add("kubectl", language: .english)
        XCTAssertTrue(lex.contains("kubectl", language: .english))
    }

    /// Removal takes a word back whichever list put it there.
    func testRemovalClearsBothRoutes() {
        let lex = lexicon()
        lex.add("dto", language: .english)
        for _ in 0..<UserLexicon.promotionThreshold { lex.observe(["async"], language: .english) }
        lex.remove("dto", language: .english)
        lex.remove("async", language: .english)
        XCTAssertFalse(lex.contains("dto", language: .english))
        XCTAssertFalse(lex.contains("async", language: .english))
    }

    /// Languages keep their own vocabulary: one lexicon, two rooms.
    func testALanguageDoesNotInheritTheOtherWords() {
        let lex = lexicon()
        for _ in 0..<UserLexicon.promotionThreshold { lex.observe(["repo"], language: .english) }
        XCTAssertTrue(lex.contains("repo", language: .english))
        XCTAssertFalse(lex.contains("repo", language: .arabic))
    }

    /// Two letters is noise, not vocabulary, however often it appears.
    func testShortTokensAreNeverLearned() {
        let lex = lexicon()
        for _ in 0..<(UserLexicon.promotionThreshold * 3) {
            lex.observe(["pr", "ok"], language: .english)
        }
        XCTAssertFalse(lex.contains("pr", language: .english))
        XCTAssertFalse(lex.contains("ok", language: .english))
    }

    /// The list survives the session it was learned in.
    func testItRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lex-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold {
            first.observe(["backoffice"], language: .english)
        }
        first.add("خوارزمية", language: .arabic)
        XCTAssertTrue(first.save())

        let second = UserLexicon(url: url)
        XCTAssertTrue(second.contains("backoffice", language: .english))
        XCTAssertTrue(second.contains("خوارزمية", language: .arabic))
    }

    /// A word still counting has changed no score. What it would put on disk is
    /// nothing but a record that this person typed it, so it stays in memory for
    /// as long as the app is running and no longer.
    func testAWordStillCountingNeverReachesDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lex-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = UserLexicon(url: url)
        for _ in 1..<UserLexicon.promotionThreshold {
            first.observe(["passphrase"], language: .english)
        }
        first.add("kubectl", language: .english)
        XCTAssertEqual(first.pending(.english).map(\.word), ["passphrase"], "held in memory")
        XCTAssertTrue(first.save())

        let written = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertFalse(written.contains("passphrase"))
        XCTAssertTrue(written.contains("kubectl"))

        let second = UserLexicon(url: url)
        XCTAssertTrue(second.pending(.english).isEmpty)
    }

    /// A learned word lifts the score of text containing it, which is the only
    /// reason the lexicon exists.
    func testALearnedWordRaisesDictionaryCoverage() throws {
        let model = try LanguageModel.shared(.english)
        let before = model.dictCoverage("the endpoint returned")
        let lex = lexicon()
        for _ in 0..<UserLexicon.promotionThreshold { lex.observe(["endpoint"], language: .english) }
        model.lexicon = lex
        defer { model.lexicon = nil }
        XCTAssertGreaterThan(model.dictCoverage("the endpoint returned"), before)
    }
}

extension UserLexiconTests {
    /// The personal list holds what the shipped one lacks, and nothing else.
    ///
    /// Recording every word would have put a frequency profile of ordinary
    /// writing on disk while changing no score, since those words were already
    /// known.
    func testOnlyWordsMissingFromTheShippedListAreWorthRecording() throws {
        let model = try LanguageModel.shared(.english)
        let sentence = "we should create the endpoint and merge the pr"
        let unknown = model.vocabulary(in: sentence).filter { !model.isKnownWord($0) }

        XCTAssertTrue(unknown.contains("endpoint"), "jargon the subtitle corpus lacks")
        for ordinary in ["should", "create", "the", "and", "merge"] {
            XCTAssertFalse(unknown.contains(ordinary), "\(ordinary) is already known")
        }
    }

    // MARK: - Announcing a crossing

    /// The card exists to make the one durable side effect visible, so the
    /// crossing has to be reported at the moment it happens and not before.
    func testObserveReportsTheWordThatCrossesTheThreshold() {
        let lexicon = UserLexicon(url: nil)

        for _ in 1..<UserLexicon.promotionThreshold {
            XCTAssertTrue(
                lexicon.observe(["kubectl"], language: .english).isEmpty,
                "a word still counting has not changed how anything scores")
        }

        XCTAssertEqual(lexicon.observe(["kubectl"], language: .english), ["kubectl"])
    }

    /// Strictly the crossing. Announcing every sighting after the tenth would
    /// turn a rare event into a recurring interruption for a word the user has
    /// already been told about.
    func testAWordAlreadyKnownIsNotAnnouncedAgain() {
        let lexicon = UserLexicon(url: nil)
        for _ in 0..<UserLexicon.promotionThreshold {
            _ = lexicon.observe(["kubectl"], language: .english)
        }

        XCTAssertTrue(lexicon.observe(["kubectl"], language: .english).isEmpty)
        XCTAssertTrue(lexicon.observe(["kubectl"], language: .english).isEmpty)
    }

    /// A word added by hand is known from the moment it is added; counting it
    /// to ten afterwards is not news.
    func testAManuallyAddedWordIsNeverAnnounced() {
        let lexicon = UserLexicon(url: nil)
        lexicon.add("kubectl", language: .english)

        for _ in 0...UserLexicon.promotionThreshold {
            XCTAssertTrue(lexicon.observe(["kubectl"], language: .english).isEmpty)
        }
    }

    /// Several words can cross on one evaluation, and the card names them all.
    func testEveryWordCrossingOnTheSamePassIsReported() {
        let lexicon = UserLexicon(url: nil)
        for _ in 1..<UserLexicon.promotionThreshold {
            _ = lexicon.observe(["kubectl", "endpoint"], language: .english)
        }

        XCTAssertEqual(
            Set(lexicon.observe(["kubectl", "endpoint"], language: .english)),
            ["kubectl", "endpoint"])
    }

    // MARK: - Taking back a miscount

    /// A flip says the run was never words in that language, so the sightings
    /// it accumulated were counted in error.
    func testForgetCountClearsWhatCountingLearned() {
        let lexicon = UserLexicon(url: nil)
        for _ in 0..<UserLexicon.promotionThreshold {
            _ = lexicon.observe(["hgsghl"], language: .english)
        }
        XCTAssertTrue(lexicon.contains("hgsghl", language: .english))

        lexicon.forgetCount("hgsghl", language: .english)
        XCTAssertFalse(lexicon.contains("hgsghl", language: .english))
    }

    /// A word typed out and asked for outranks anything inferred from a flip.
    func testForgetCountLeavesAHandAddedWordAlone() {
        let lexicon = UserLexicon(url: nil)
        lexicon.add("kubectl", language: .english)

        lexicon.forgetCount("kubectl", language: .english)
        XCTAssertTrue(lexicon.contains("kubectl", language: .english))
    }

    /// `pr` is a word this user writes hourly and one counting can never reach,
    /// which is what the manual list is for.
    func testATwoLetterWordCanBeAddedByHand() {
        let lexicon = UserLexicon(url: nil)
        lexicon.add("pr", language: .english)

        XCTAssertTrue(lexicon.contains("pr", language: .english))
    }

    /// The lower floor is the manual route's alone: a two-letter token that
    /// merely recurs is still a fragment.
    func testATwoLetterTokenIsStillNeverCounted() {
        let lexicon = UserLexicon(url: nil)
        for _ in 0..<(UserLexicon.promotionThreshold * 3) {
            _ = lexicon.observe(["pr"], language: .english)
        }

        XCTAssertFalse(lexicon.contains("pr", language: .english))
        XCTAssertTrue(lexicon.pending(.english).isEmpty)
    }

    // MARK: - An edit made in another process

    /// What `harf --words` does: open the file, change one word, write it back.
    /// A fresh lexicon every time, because the command is a process that lives
    /// for the length of it.
    private func shellEdit(_ url: URL, _ edit: (UserLexicon) -> Void) {
        let cli = UserLexicon(url: url)
        edit(cli)
        cli.save()
    }

    private func temporaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lex-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `harf --words add kubectl` against a running app. The word has to count
    /// straight away, and the session's own counting has to survive the merge:
    /// a word part-way to promotion lives only in memory and is not in the file
    /// the CLI just wrote.
    func testAWordAddedFromAShellArrivesWithoutCostingWhatWasCounted() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold { app.observe(["endpoint"], language: .english) }
        app.observe(["passphrase"], language: .english)

        shellEdit(url) { $0.add("kubectl", language: .english) }

        XCTAssertTrue(app.reload())
        XCTAssertTrue(app.contains("kubectl", language: .english), "the shell's word")
        XCTAssertTrue(app.contains("endpoint", language: .english), "learned, never saved")
        XCTAssertEqual(app.pending(.english).map(\.word), ["passphrase"], "still counting")
    }

    /// And the save that used to undo it. The app has unsaved words of its own,
    /// so this is the write that goes out; both sides have to be in it.
    func testTheNextSaveKeepsBothSidesOfTheEdit() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold { app.observe(["endpoint"], language: .english) }

        shellEdit(url) { $0.add("kubectl", language: .english) }
        XCTAssertTrue(app.save())

        let reopened = UserLexicon(url: url)
        XCTAssertTrue(reopened.contains("kubectl", language: .english))
        XCTAssertTrue(reopened.contains("endpoint", language: .english))
    }

    /// The race the message cannot close: the app's periodic save fires between
    /// the CLI writing the file and the app being told about it. Nothing here
    /// calls `reload`, so the save path is the only thing standing between the
    /// edit and being overwritten.
    func testASaveThatRacesTheEditDoesNotOverwriteIt() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold { app.observe(["endpoint"], language: .english) }

        shellEdit(url) { $0.add("kubectl", language: .english) }
        XCTAssertTrue(app.save())

        XCTAssertTrue(app.contains("kubectl", language: .english), "adopted by the save itself")
        XCTAssertTrue(UserLexicon(url: url).contains("kubectl", language: .english))
    }

    /// A word taken back from a shell stays taken back, including one the app
    /// had already promoted and is holding in memory.
    func testAWordRemovedFromAShellStaysRemoved() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold {
            app.observe(["kubectl", "endpoint"], language: .english)
        }
        XCTAssertTrue(app.save())

        shellEdit(url) { $0.remove("kubectl", language: .english) }

        XCTAssertTrue(app.reload())
        XCTAssertFalse(app.contains("kubectl", language: .english))
        XCTAssertTrue(app.contains("endpoint", language: .english), "untouched by the edit")

        app.observe(["backoffice"], language: .english)
        app.save()
        XCTAssertFalse(UserLexicon(url: url).contains("kubectl", language: .english))
    }

    /// A removal must not be undone by a later count either: the word is gone
    /// from memory, so counting it again starts from nothing rather than from
    /// the ten sightings it had.
    func testARemovalIsNotResurrectedByTheNextSave() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold { app.observe(["kubectl"], language: .english) }
        XCTAssertTrue(app.save())

        shellEdit(url) { $0.remove("kubectl", language: .english) }

        app.observe(["endpoint"], language: .english)
        app.save()
        XCTAssertFalse(app.contains("kubectl", language: .english))
        XCTAssertFalse(UserLexicon(url: url).contains("kubectl", language: .english))
    }

    /// `--words clear` deletes the file, and that is the whole message: the
    /// running copy empties out too, counting included, and writes nothing back.
    func testClearFromAShellEmptiesTheRunningCopyAndStaysCleared() throws {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        app.add("kubectl", language: .english)
        for _ in 0..<UserLexicon.promotionThreshold { app.observe(["endpoint"], language: .english) }
        app.observe(["passphrase"], language: .english)
        XCTAssertTrue(app.save())

        shellEdit(url) { $0.clear() }

        XCTAssertTrue(app.reload())
        XCTAssertFalse(app.contains("kubectl", language: .english))
        XCTAssertFalse(app.contains("endpoint", language: .english))
        XCTAssertTrue(app.pending(.english).isEmpty, "the words still counting go as well")

        XCTAssertFalse(app.save())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path), "nothing is written back")
    }

    /// The guard on that rule. A copy that has learned something and never yet
    /// saved also faces a file that is not there, and it must not read its own
    /// first run as somebody else's `clear`.
    func testAFileThatHasNeverExistedIsNotAClear() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold { app.observe(["endpoint"], language: .english) }

        XCTAssertFalse(app.reload())
        XCTAssertTrue(app.contains("endpoint", language: .english))
        XCTAssertTrue(app.save())
        XCTAssertTrue(UserLexicon(url: url).contains("endpoint", language: .english))
    }

    /// Nothing to adopt is not a change, so the app's own state is left exactly
    /// as it was and the caller has nothing to log.
    func testReloadingAnUnchangedFileChangesNothing() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        app.add("kubectl", language: .english)
        XCTAssertTrue(app.save())

        XCTAssertFalse(app.reload())
        XCTAssertTrue(app.contains("kubectl", language: .english))
    }

    /// A file that is there and cannot be read says nothing. Treating it as
    /// empty would be treating a half-written file, or one that is not ours at
    /// all, as an instruction to forget everything.
    func testAnUnreadableFileIsNotAnInstruction() throws {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        app.add("kubectl", language: .english)
        XCTAssertTrue(app.save())

        try Data("not json at all".utf8).write(to: url)

        XCTAssertFalse(app.reload())
        XCTAssertTrue(app.contains("kubectl", language: .english))
    }

    /// Each language is merged on its own, as everything else here is.
    func testAnEditInOneLanguageLeavesTheOtherAlone() {
        let url = temporaryFile()
        let app = UserLexicon(url: url)
        app.add("kubectl", language: .english)
        XCTAssertTrue(app.save())

        shellEdit(url) { $0.add("خوارزمية", language: .arabic) }

        XCTAssertTrue(app.reload())
        XCTAssertTrue(app.contains("خوارزمية", language: .arabic))
        XCTAssertTrue(app.contains("kubectl", language: .english))
    }

    /// Undo is a real removal, so a word can be learned again later rather than
    /// being permanently suppressed.
    func testAnUndoneWordCanBeLearnedAgain() {
        let lexicon = UserLexicon(url: nil)
        for _ in 0..<UserLexicon.promotionThreshold {
            _ = lexicon.observe(["kubectl"], language: .english)
        }
        lexicon.remove("kubectl", language: .english)
        XCTAssertFalse(lexicon.contains("kubectl", language: .english))

        for _ in 1..<UserLexicon.promotionThreshold {
            _ = lexicon.observe(["kubectl"], language: .english)
        }
        XCTAssertEqual(lexicon.observe(["kubectl"], language: .english), ["kubectl"])
    }

}
