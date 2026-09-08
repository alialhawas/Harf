import XCTest

@testable import DodomaCore

final class FlipLearningTests: XCTestCase {
    private func models() throws -> (english: LanguageModel, arabic: LanguageModel) {
        let english = LanguageModel.shared(.english)
        let arabic = LanguageModel.shared(.arabic)
        try english.preload()
        try arabic.preload()
        return (english, arabic)
    }

    private func flip(
        original: String, flipped: String, target: Language
    ) -> Flip {
        Flip(
            original: original,
            flipped: flipped,
            sourceLayoutID: target == .arabic
                ? LayoutFixtures.abcSourceID : LayoutFixtures.arabicSourceID,
            targetLayoutID: target == .arabic
                ? LayoutFixtures.arabicSourceID : LayoutFixtures.abcSourceID,
            sourceLanguage: target == .arabic ? .english : .arabic,
            targetLanguage: target,
            capsMode: target == .arabic ? .lowercased : .asTyped)
    }

    /// The flipped text is the user stating these are real words, so the ones
    /// the shipped list is missing are worth keeping.
    func testUnknownWordsInTheFlippedTextAreProposed() throws {
        let models = try models()
        let plan = FlipLearning.plan(
            for: flip(original: "hgsghl", flipped: "the kubectl endpoint", target: .english),
            target: models.english,
            source: models.arabic)

        XCTAssertTrue(plan.add.contains("kubectl"))
        XCTAssertTrue(plan.add.contains("endpoint"))
    }

    /// Recording a word the shipped list already has changes no score, and puts
    /// a profile of ordinary writing on disk for nothing.
    func testShippedWordsAreNotProposed() throws {
        let models = try models()
        let plan = FlipLearning.plan(
            for: flip(original: "hgsghl", flipped: "the link is fine", target: .english),
            target: models.english,
            source: models.arabic)

        for ordinary in ["the", "link", "is", "fine"] {
            XCTAssertFalse(plan.add.contains(ordinary), "\(ordinary) is already known")
        }
    }

    /// The wrong-layout original was never words, so whatever the passive
    /// learner counted from it is a miscount and goes back.
    func testTheOriginalIsProposedForForgettingOnlyWhenUnknown() throws {
        let models = try models()
        let plan = FlipLearning.plan(
            for: flip(original: "hgsghl the", flipped: "السلام", target: .arabic),
            target: models.arabic,
            source: models.english)

        XCTAssertEqual(plan.forget, ["hgsghl"], "`the` is a shipped word and is never touched")
    }

    /// A word written twice in one run is one entry, in the order it was
    /// written.
    func testProposalsAreDeduplicatedInOrder() throws {
        let models = try models()
        let plan = FlipLearning.plan(
            for: flip(original: "hgsghl", flipped: "kubectl endpoint kubectl", target: .english),
            target: models.english,
            source: models.arabic)

        XCTAssertEqual(plan.add, ["kubectl", "endpoint"])
    }
}
