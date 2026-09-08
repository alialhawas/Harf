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
}
