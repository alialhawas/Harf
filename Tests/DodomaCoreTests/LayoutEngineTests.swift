import XCTest

@testable import DodomaCore

/// `LayoutEngine.pair(all:selectedID:)`, driven with synthetic enabled-source
/// lists rather than the Text Input Sources of the machine the tests run on.
///
/// The `uchr` bytes come from the committed fixtures and are shared by every
/// layout in a list: `pair` reads only the identifier and the language, and
/// giving each variant its own table would prove nothing and cost a fixture.
final class LayoutEngineTests: XCTestCase {
    private var abcData: Data!
    private var arabicData: Data!

    override func setUpWithError() throws {
        abcData = try LayoutFixtures.abc().layout.uchrData
        arabicData = try LayoutFixtures.arabic().layout.uchrData
    }

    private func english(_ sourceID: String) -> KeyboardLayout {
        KeyboardLayout(
            sourceID: sourceID, localizedName: sourceID, languageCode: "en", uchrData: abcData)
    }

    private func arabic(_ sourceID: String) -> KeyboardLayout {
        KeyboardLayout(
            sourceID: sourceID, localizedName: sourceID, languageCode: "ar", uchrData: arabicData)
    }

    private func other(_ sourceID: String, _ languageCode: String) -> KeyboardLayout {
        KeyboardLayout(
            sourceID: sourceID, localizedName: sourceID, languageCode: languageCode,
            uchrData: abcData)
    }

    // MARK: - The selected side is the selected layout

    /// A Dvorak typist with ABC also enabled must have their keycodes read
    /// through Dvorak. Taking the first enabled English layout would render
    /// every key through ABC and switch them to a layout they never chose.
    func testTheEnglishSideIsTheSelectedLayoutNotTheFirstEnabledOne() throws {
        let all = [english("com.apple.keylayout.ABC"), english("com.apple.keylayout.Dvorak"),
                   arabic(LayoutFixtures.arabicSourceID)]
        let pair = try XCTUnwrap(
            LayoutEngine.pair(all: all, selectedID: "com.apple.keylayout.Dvorak"))
        XCTAssertEqual(pair.english.sourceID, "com.apple.keylayout.Dvorak")
        XCTAssertEqual(pair.arabic.sourceID, LayoutFixtures.arabicSourceID)
    }

    /// The same rule on the other side: two Arabic layouts, and the one being
    /// typed in wins over the one that happens to be listed first.
    func testTheArabicSideIsTheSelectedLayoutWhenTwoArabicLayoutsAreEnabled() throws {
        let all = [english(LayoutFixtures.abcSourceID), arabic("com.apple.keylayout.Arabic"),
                   arabic("com.apple.keylayout.ArabicPC")]
        let pair = try XCTUnwrap(
            LayoutEngine.pair(all: all, selectedID: "com.apple.keylayout.ArabicPC"))
        XCTAssertEqual(pair.arabic.sourceID, "com.apple.keylayout.ArabicPC")
        XCTAssertEqual(pair.english.sourceID, LayoutFixtures.abcSourceID)
    }

    /// Nothing says which Arabic layout a user typing English meant, so the
    /// unselected side stays the first enabled layout of its language — the
    /// order System Settings lists and ⌃Space cycles through.
    func testTheUnselectedSideIsTheFirstEnabledLayoutOfItsLanguage() throws {
        let all = [english(LayoutFixtures.abcSourceID), arabic("com.apple.keylayout.Arabic"),
                   arabic("com.apple.keylayout.ArabicPC")]
        let pair = try XCTUnwrap(
            LayoutEngine.pair(all: all, selectedID: LayoutFixtures.abcSourceID))
        XCTAssertEqual(pair.arabic.sourceID, "com.apple.keylayout.Arabic")
    }

    // MARK: - Refusals

    /// An input method carries no `uchr` table, so enumeration never returns
    /// it and `UCKeyTranslate` could not render through it anyway.
    func testASelectedInputMethodHasNoPair() {
        let all = [english(LayoutFixtures.abcSourceID), arabic(LayoutFixtures.arabicSourceID)]
        XCTAssertNil(
            LayoutEngine.pair(all: all, selectedID: "com.apple.inputmethod.SCIM.ITABC"))
    }

    /// A selection cached from before the user disabled that source. Refusing
    /// is the safe read: the engine has no table for what is being typed.
    func testASelectionMissingFromTheEnabledListHasNoPair() {
        let all = [english(LayoutFixtures.abcSourceID), arabic(LayoutFixtures.arabicSourceID)]
        XCTAssertNil(LayoutEngine.pair(all: all, selectedID: "com.apple.keylayout.Dvorak"))
    }

    func testAThirdLanguageSelectionHasNoPair() {
        let all = [english(LayoutFixtures.abcSourceID), arabic(LayoutFixtures.arabicSourceID),
                   other("com.apple.keylayout.French", "fr")]
        XCTAssertNil(LayoutEngine.pair(all: all, selectedID: "com.apple.keylayout.French"))
    }

    func testNoPairWhenTheOtherLanguageIsNotEnabled() {
        let all = [english(LayoutFixtures.abcSourceID), english("com.apple.keylayout.Dvorak")]
        XCTAssertNil(LayoutEngine.pair(all: all, selectedID: LayoutFixtures.abcSourceID))
    }

    func testNoPairWhenNothingIsSelected() {
        let all = [english(LayoutFixtures.abcSourceID), arabic(LayoutFixtures.arabicSourceID)]
        XCTAssertNil(LayoutEngine.pair(all: all, selectedID: nil))
    }

    // MARK: - Cache

    /// `noteSelectedLayout` never enumerates, so a selection change against a
    /// cold cache leaves it cold and `cachedPair()` still refuses rather than
    /// reaching for Text Input Sources off the main thread.
    func testAColdCacheHasNoPairEvenAfterASelectionChange() {
        let engine = LayoutEngine()
        engine.noteSelectedLayout(LayoutFixtures.abcSourceID)
        XCTAssertNil(engine.cachedPair())
    }

    // MARK: - Healing a warm cache with a bad selection

    /// The list the refresh seam is handed, and a warm cache built from it.
    private func warmEngine(selecting sourceID: String? = LayoutFixtures.abcSourceID)
        -> (engine: LayoutEngine, all: [KeyboardLayout])
    {
        let all = [english(LayoutFixtures.abcSourceID), arabic(LayoutFixtures.arabicSourceID)]
        let engine = LayoutEngine()
        _ = engine.refreshSelection(reading: { sourceID }, enumerating: { all })
        return (engine, all)
    }

    /// The failure that cost two days: Text Input Sources answered `nil` while
    /// the selection was mid-switch, the cache took that as the answer, and
    /// `cachedPair()` then refused forever with nothing left to re-read it.
    /// There is always a selected source, so `nil` only ever means the read
    /// failed — never that nothing is selected.
    func testANilSelectionDoesNotEraseAGoodOne() {
        let (engine, _) = warmEngine()
        XCTAssertNotNil(engine.cachedPair(), "precondition: the cache resolves")

        engine.noteSelectedLayout(nil)

        XCTAssertNotNil(engine.cachedPair(), "the good selection survived the failed read")
    }

    func testRefreshingAColdCacheEnumeratesAndResolves() {
        let all = [english(LayoutFixtures.abcSourceID), arabic(LayoutFixtures.arabicSourceID)]
        let engine = LayoutEngine()
        var enumerations = 0

        let repaired = engine.refreshSelection(
            reading: { LayoutFixtures.abcSourceID },
            enumerating: {
                enumerations += 1
                return all
            })

        XCTAssertTrue(repaired)
        XCTAssertEqual(enumerations, 1)
        XCTAssertEqual(engine.cachedPair()?.english.sourceID, LayoutFixtures.abcSourceID)
    }

    /// A refresh that cannot read the selection changes nothing and enumerates
    /// nothing: copying every `uchr` table to learn that the system is busy
    /// would be the expensive way to find out.
    func testAnUnreadableSelectionLeavesTheCacheAlone() {
        let (engine, _) = warmEngine()

        let repaired = engine.refreshSelection(
            reading: { nil },
            enumerating: {
                XCTFail("a failed selection read must not trigger an enumeration")
                return []
            })

        XCTAssertFalse(repaired)
        XCTAssertEqual(engine.cachedPair()?.english.sourceID, LayoutFixtures.abcSourceID)
    }

    /// A selection the cached list has never heard of means the list itself is
    /// stale — an enabled-sources notification that was coalesced away, or a
    /// source enabled since. Re-enumerating is the only way to tell that apart
    /// from an input method, and it is the case that heals.
    func testASelectionMissingFromTheListReEnumeratesAndResolves() {
        let (engine, all) = warmEngine()
        let widened = all + [english("com.apple.keylayout.Dvorak")]
        var enumerations = 0

        let repaired = engine.refreshSelection(
            reading: { "com.apple.keylayout.Dvorak" },
            enumerating: {
                enumerations += 1
                return widened
            })

        XCTAssertTrue(repaired)
        XCTAssertEqual(enumerations, 1)
        XCTAssertEqual(engine.cachedPair()?.english.sourceID, "com.apple.keylayout.Dvorak")
    }

    /// The other half of that re-enumeration: a selection still absent from the
    /// fresh list is an input method, which carries no `uchr` table and can
    /// never be rendered. The refresh reports honestly that it repaired nothing.
    func testASelectionThatMovedToAnInputMethodStillHasNoPair() {
        let (engine, all) = warmEngine()

        let repaired = engine.refreshSelection(
            reading: { "com.apple.inputmethod.SCIM.ITABC" }, enumerating: { all })

        XCTAssertFalse(repaired)
        XCTAssertNil(engine.cachedPair())
    }
}
