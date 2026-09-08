import Combine
import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The parts of the settings window's model that are reachable without putting
/// a window on screen: what a write does to the store, and when the policy
/// tables are rebuilt.
///
/// Nothing here drives SwiftUI. `objectWillChange` is used only as the seam for
/// "did this cause a republication", which is the property that keeps a global
/// pause chord from costing a LaunchServices sweep.
final class SettingsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var lexicon: UserLexicon!
    private var model: SettingsModel!
    private var cancellables: Set<AnyCancellable> = []

    /// Bundle identifiers that are not in `PolicySeeds` and are not installed,
    /// so their resolved name is the identifier itself — which makes the sort
    /// order predictable without depending on what this machine has in
    /// /Applications.
    private let alpha = "com.example.aaa-alpha"
    private let mango = "com.example.mmm-mango"
    private let zebra = "com.example.zzz-zebra"

    override func setUp() {
        super.setUp()
        suiteName = "com.ali.dodoma.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        // url: nil keeps the lexicon in memory. A test that wrote to the
        // default location would edit the vocabulary of whoever ran it.
        lexicon = UserLexicon(url: nil)
        model = SettingsModel(store: store, lexicon: lexicon)
        model.refresh()
    }

    override func tearDown() {
        cancellables.removeAll()
        model = nil
        store = nil
        lexicon = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func publications(during body: () -> Void) -> Int {
        var count = 0
        let token = model.objectWillChange.sink { _ in count += 1 }
        body()
        token.cancel()
        return count
    }

    // MARK: - Rows

    func testTheSeededPoliciesAreAllPresentAsRows() {
        XCTAssertEqual(model.policyRows.count, PolicySeeds.table.count)
        XCTAssertEqual(
            Set(model.policyRows.map(\.bundleID)), Set(PolicySeeds.table.keys))
        for row in model.policyRows {
            XCTAssertFalse(row.name.isEmpty, row.bundleID)
            XCTAssertEqual(row.policy, store.policy(for: row.bundleID))
        }
    }

    /// Added out of order; the table has to come back in name order, because
    /// dictionary iteration order is not stable across launches and a list that
    /// reshuffles itself is unusable.
    func testRowsAreSortedByDisplayName() {
        model.addPolicy(for: zebra)
        model.addPolicy(for: alpha)
        model.addPolicy(for: mango)

        let names = model.policyRows.map(\.name)
        XCTAssertEqual(
            names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        let added = model.policyRows.map(\.bundleID).filter { $0.hasPrefix("com.example.") }
        XCTAssertEqual(added, [alpha, mango, zebra])
    }

    // MARK: - Per-app policies

    func testAddingAnAppGivesItTheCurrentDefaultPolicy() {
        store.setDefaultPolicy(.suggestOnly)
        model.refresh()

        model.addPolicy(for: alpha)

        XCTAssertEqual(model.settings.appPolicies[alpha], .suggestOnly)
        XCTAssertEqual(store.settings.appPolicies[alpha], .suggestOnly)
    }

    /// Picking an app that already has a row must not silently reset the mode
    /// the user chose for it back to the default.
    func testAddingAnAppThatIsAlreadyListedChangesNothing() {
        model.setPolicy(.off, for: alpha)
        let before = model.settings

        let publications = publications { model.addPolicy(for: alpha) }

        XCTAssertEqual(model.settings, before)
        XCTAssertEqual(model.settings.appPolicies[alpha], .off)
        XCTAssertEqual(publications, 0)
    }

    func testRemovingARowDropsTheOverrideRatherThanWritingTheDefault() {
        model.setPolicy(.off, for: alpha)
        model.removePolicy(for: alpha)

        XCTAssertNil(model.settings.appPolicies[alpha])
        XCTAssertFalse(model.policyRows.contains { $0.bundleID == alpha })
        XCTAssertEqual(model.settings.policy(for: alpha), model.settings.defaultPolicy)
    }

    // MARK: - Accessibility verification skips

    func testAXVerifySkipAddAndRemoveRoundTripThroughTheRows() {
        model.addAXVerifySkip(zebra)

        XCTAssertEqual(model.skipRows.map(\.bundleID), [zebra])
        XCTAssertTrue(store.skipsAXVerify(zebra))

        model.addAXVerifySkip(alpha)
        XCTAssertEqual(model.skipRows.map(\.bundleID), [alpha, zebra], "sorted, like the policies")

        model.removeAXVerifySkip(zebra)

        XCTAssertEqual(model.skipRows.map(\.bundleID), [alpha])
        XCTAssertFalse(store.skipsAXVerify(zebra))
    }

    /// The skip list is separate from the policy table: adding one must not
    /// invent a policy override for the app.
    func testSkippingVerificationDoesNotCreateAPolicyRow() {
        model.addAXVerifySkip(zebra)

        XCTAssertNil(model.settings.appPolicies[zebra])
        XCTAssertFalse(model.policyRows.contains { $0.bundleID == zebra })
    }

    // MARK: - accept()

    func testAcceptingTheSameSettingsTwiceIsANoOp() {
        let current = store.settings

        let publications = publications { model.accept(current) }

        XCTAssertEqual(publications, 0)
    }

    /// The reason `accept` looks at the two maps rather than at the whole
    /// value: a pause toggle must not cost a rebuild of every row.
    func testAScalarChangeDoesNotRebuildTheTables() {
        model.addPolicy(for: alpha)
        let rowsBefore = model.policyRows
        let skipsBefore = model.skipRows

        var paused = store.settings
        paused.paused = true
        model.accept(paused)

        XCTAssertTrue(model.settings.paused, "the value still lands")
        XCTAssertEqual(model.policyRows, rowsBefore)
        XCTAssertEqual(model.skipRows, skipsBefore)
    }

    func testAPolicyChangeMadeElsewhereRebuildsTheTables() {
        store.setPolicy(.off, for: mango)
        model.accept(store.settings)

        XCTAssertEqual(
            model.policyRows.first { $0.bundleID == mango }?.policy, .off,
            "a change made from the menu shows up in an open window")
    }

    // MARK: - Vocabulary

    func testAddedWordIsListedAsManualRegardlessOfCount() {
        model.addWord("kubectl")

        let row = model.vocabRows.first { $0.word == "kubectl" }
        XCTAssertNotNil(row, "a word added by hand must appear without being counted to")
        XCTAssertTrue(row?.manual == true)
        XCTAssertTrue(row?.promoted == true)
    }

    func testCountedWordShowsProgressUntilThresholdThenCountsAsKnown() {
        for _ in 1..<UserLexicon.promotionThreshold {
            lexicon.observe(["endpoint"], language: .english)
        }
        model.refresh()
        let pending = model.vocabRows.first { $0.word == "endpoint" }
        XCTAssertEqual(pending?.promoted, false)
        XCTAssertEqual(pending?.count, UserLexicon.promotionThreshold - 1)

        lexicon.observe(["endpoint"], language: .english)
        model.refresh()
        XCTAssertEqual(model.vocabRows.first { $0.word == "endpoint" }?.promoted, true)
    }

    func testRemovingAWordDropsItFromTheList() {
        model.addWord("kubectl")
        model.removeWord("kubectl")

        XCTAssertNil(model.vocabRows.first { $0.word == "kubectl" })
    }

    func testLanguagesAreListedSeparately() {
        model.vocabLanguage = .english
        model.addWord("kubectl")

        model.vocabLanguage = .arabic
        XCTAssertNil(
            model.vocabRows.first { $0.word == "kubectl" },
            "an English word must not appear under Arabic")

        model.vocabLanguage = .english
        XCTAssertNotNil(model.vocabRows.first { $0.word == "kubectl" })
    }

    func testErasingClearsBothLanguages() {
        model.vocabLanguage = .english
        model.addWord("kubectl")
        model.vocabLanguage = .arabic
        model.addWord("تجريب")

        model.eraseVocabulary()
        XCTAssertTrue(model.vocabRows.isEmpty)
        model.vocabLanguage = .english
        XCTAssertTrue(model.vocabRows.isEmpty)
    }

}
