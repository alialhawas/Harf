import XCTest

@testable import DodomaCore

/// Behavioural boundary tests for `FixDecision.verdict`, driven with synthetic
/// `Score` values rather than real text.
///
/// The language models produce a strongly bimodal distribution — real inputs
/// cluster near 0.0 or near 0.9 and essentially never land within 0.01 of a
/// threshold — so the gates cannot be pinned by corpus rows. Feeding the gate
/// ladder scores directly is the only way to prove each cut-off is read in the
/// right direction and that nothing else moves with it.
final class DecisionGateTests: XCTestCase {
    /// A score whose `combined` is exactly `value`: the 0.55/0.45 blend of a
    /// number with itself is that number.
    private func score(_ value: Double) -> Score {
        Score(bigram: value, dictCoverage: value)
    }

    private func verdict(
        alt: Score,
        cur: Score,
        letters: Int = 10,
        completed: Int = 1,
        tokens: Int = 2,
        guards: GuardResult = GuardResult(vetoes: []),
        policy: AppPolicy = .normal,
        thresholds: Thresholds = .balanced
    ) -> String {
        let typedText = Array(repeating: "aaaaa", count: max(tokens, 1)).joined(separator: " ")
        let region = CandidateRegion(
            keys: [],
            typedText: typedText,
            letterCount: letters,
            completedTokenCount: completed)
        let fix = Fix(
            deleteCount: typedText.count,
            insertText: "x",
            targetLayoutID: "target",
            sourceLayoutID: "source",
            replacedText: typedText,
            capsMode: .asTyped)
        switch FixDecision.verdict(
            region: region, current: cur, alternate: alt, fix: fix, guards: guards,
            policy: policy, thresholds: thresholds)
        {
        case .ignore: return "ignore"
        case .suggest: return "suggest"
        case .autoApply: return "autoApply"
        }
    }

    // MARK: - Automatic gates, ±0.01 around each cut-off

    func testAutoAltBoundary() {
        // Only alt moves; cur stays at 0 so the gap gate never binds.
        XCTAssertEqual(verdict(alt: score(0.63), cur: score(0.00)), "autoApply")
        XCTAssertEqual(verdict(alt: score(0.61), cur: score(0.00)), "suggest")
    }

    func testAutoCurBoundary() {
        // gap is 0.48 / 0.46, both clear of autoGap; alt clears autoAlt.
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.27)), "autoApply")
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.29)), "suggest")
    }

    func testAutoGapBoundary() {
        // alt clears autoAlt and cur clears autoCur in both rows; only the
        // separation crosses 0.40.
        XCTAssertEqual(verdict(alt: score(0.68), cur: score(0.27)), "autoApply")
        XCTAssertEqual(verdict(alt: score(0.66), cur: score(0.27)), "suggest")
    }

    // MARK: - Suggestion gates

    func testSuggestGapBoundary() {
        // alt is below autoAlt throughout, so only the suggestion ladder runs.
        XCTAssertEqual(verdict(alt: score(0.50), cur: score(0.31)), "suggest")
        XCTAssertEqual(verdict(alt: score(0.50), cur: score(0.33)), "ignore")
    }

    func testSuggestAltBoundary() {
        XCTAssertEqual(verdict(alt: score(0.46), cur: score(0.00)), "suggest")
        XCTAssertEqual(verdict(alt: score(0.44), cur: score(0.00)), "ignore")
    }

    // MARK: - Dictionary override

    /// alt.combined is 0.53 — under autoAlt — so an autoApply here can only
    /// come from the override.
    func testDictOverrideTriple() {
        let alt = Score(bigram: 0.30, dictCoverage: 0.81)
        let cur = Score(bigram: 0.00, dictCoverage: 0.14)
        XCTAssertLessThan(alt.combined, Thresholds.balanced.autoAlt)
        XCTAssertEqual(verdict(alt: alt, cur: cur, tokens: 2), "autoApply")

        // altDict just under 0.80.
        XCTAssertEqual(
            verdict(alt: Score(bigram: 0.30, dictCoverage: 0.79), cur: cur, tokens: 2), "suggest")
        // curDict just over 0.15.
        XCTAssertEqual(
            verdict(alt: alt, cur: Score(bigram: 0.00, dictCoverage: 0.16), tokens: 2), "suggest")
        // one token is not enough.
        XCTAssertEqual(verdict(alt: alt, cur: cur, tokens: 1), "suggest")
    }

    func testDictOverrideStillObeysTheSharedGates() {
        let alt = Score(bigram: 0.30, dictCoverage: 0.81)
        let cur = Score(bigram: 0.00, dictCoverage: 0.14)
        XCTAssertEqual(verdict(alt: alt, cur: cur, letters: 5), "suggest", "letterCount")
        XCTAssertEqual(verdict(alt: alt, cur: cur, completed: 0), "suggest", "completedTokenCount")
        XCTAssertEqual(
            verdict(alt: alt, cur: cur, guards: GuardResult(vetoes: [.digitsAdjacent])),
            "suggest", "one veto")
        XCTAssertEqual(verdict(alt: alt, cur: cur, policy: .suggestOnly), "suggest", "policy")
    }

    // MARK: - Length, completion, guards, policy

    func testAutoLengthGateBoundary() {
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.00), letters: 6), "autoApply")
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.00), letters: 5), "suggest")
    }

    func testSuggestLengthGateBoundary() {
        XCTAssertEqual(verdict(alt: score(0.50), cur: score(0.00), letters: 4), "suggest")
        XCTAssertEqual(verdict(alt: score(0.50), cur: score(0.00), letters: 3), "ignore")
    }

    func testCompletedTokenGate() {
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.00), completed: 1), "autoApply")
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.00), completed: 0), "suggest")
    }

    func testGuardCountGate() {
        let auto = score(0.75)
        XCTAssertEqual(verdict(alt: auto, cur: score(0.00)), "autoApply")
        XCTAssertEqual(
            verdict(alt: auto, cur: score(0.00), guards: GuardResult(vetoes: [.shortSingleToken])),
            "suggest")
        XCTAssertEqual(
            verdict(
                alt: auto, cur: score(0.00),
                guards: GuardResult(vetoes: [.shortSingleToken, .digitsAdjacent])),
            "ignore")
    }

    func testPolicyGate() {
        XCTAssertEqual(verdict(alt: score(0.75), cur: score(0.00), policy: .normal), "autoApply")
        XCTAssertEqual(
            verdict(alt: score(0.75), cur: score(0.00), policy: .suggestOnly), "suggest")
    }

    // MARK: - Presets move the same rows

    func testPresetsShiftTheAutoBoundary() {
        // alt 0.63: over balanced's 0.62, under conservative's 0.70.
        XCTAssertEqual(
            verdict(alt: score(0.63), cur: score(0.00), thresholds: .conservative), "suggest")
        XCTAssertEqual(
            verdict(alt: score(0.63), cur: score(0.00), thresholds: .balanced), "autoApply")
        // alt 0.57: under balanced's 0.62, over eager's 0.56.
        XCTAssertEqual(
            verdict(alt: score(0.57), cur: score(0.00), thresholds: .balanced), "suggest")
        XCTAssertEqual(
            verdict(alt: score(0.57), cur: score(0.00), thresholds: .eager), "autoApply")
    }

    func testPresetsShiftTheSuggestGap() {
        // gap 0.19: over balanced's 0.18, under conservative's 0.26.
        XCTAssertEqual(
            verdict(alt: score(0.50), cur: score(0.31), thresholds: .conservative), "ignore")
        XCTAssertEqual(
            verdict(alt: score(0.50), cur: score(0.31), thresholds: .balanced), "suggest")
        // gap 0.14: under balanced's 0.18, over eager's 0.12.
        XCTAssertEqual(
            verdict(alt: score(0.50), cur: score(0.36), thresholds: .balanced), "ignore")
        XCTAssertEqual(
            verdict(alt: score(0.50), cur: score(0.36), thresholds: .eager), "suggest")
    }
    /// A decisive separation is not vetoed by an inflated typed-language score.
    ///
    /// `autoCur` asks whether the text on screen is plausible as it stands, and
    /// accidental real words lift it: a sentence ending in وشهر — which strips
    /// to "month" — reached cur 0.33 against a 0.28 ceiling while the other
    /// reading scored 0.84. At that separation there is no ambiguity to protect.
    func testADecisiveSeparationAutoAppliesAboveTheCurrentCeiling() {
        XCTAssertEqual(verdict(alt: score(0.84), cur: score(0.33)), "autoApply")
    }

    /// The clause is deliberately narrow in both directions.
    func testTheDecisiveClauseNeedsBothAStrongAlternateAndAWideGap() {
        XCTAssertEqual(
            verdict(alt: score(0.77), cur: score(0.33)), "suggest",
            "just under decisiveAlt, and cur is over the ceiling")
        XCTAssertEqual(
            verdict(alt: score(0.80), cur: score(0.31)), "suggest",
            "strong alternate but the 0.49 separation is under decisiveGap")
    }

    /// A score high enough to speak for itself carries text too short for the
    /// length rules. This is the whole point of the setting: "what" typed on
    /// the Arabic layout reads 0.999 against 0.24 and used to be held back by
    /// a rule about how little four letters usually prove.
    func testAConfidentScoreCarriesTextTooShortForTheLengthRules() {
        XCTAssertEqual(
            verdict(alt: score(0.95), cur: score(0.10), letters: 4, completed: 0, tokens: 1,
                    guards: GuardResult(vetoes: [.shortSingleToken]),
                    thresholds: .balanced.withConfidentScore(0.90)),
            "autoApply")
    }

    /// Off by default in the sense that matters: with no threshold set, the
    /// same input is only ever offered.
    func testWithoutAConfidentScoreShortTextIsOnlySuggested() {
        XCTAssertEqual(
            verdict(alt: score(0.95), cur: score(0.10), letters: 4, completed: 0, tokens: 1,
                    guards: GuardResult(vetoes: [.shortSingleToken])),
            "suggest")
    }

    /// Confidence waives shortness and nothing else. A path or an identifier is
    /// a statement that the text is not prose, which no score answers.
    func testAConfidentScoreDoesNotWaiveTheOtherGuards() {
        for veto in [GuardReason.urlOrPath, .identifierCase, .digitsAdjacent, .recentlyUndone] {
            XCTAssertEqual(
                verdict(alt: score(0.99), cur: score(0.02), letters: 4, completed: 0, tokens: 1,
                        guards: GuardResult(vetoes: [.shortSingleToken, veto]),
                        thresholds: .balanced.withConfidentScore(0.90)),
                "ignore", "\(veto.rawValue) must still block")
        }
    }

    /// Two letters is not evidence at any score.
    func testAConfidentScoreStillRefusesTwoLetters() {
        XCTAssertEqual(
            verdict(alt: score(0.99), cur: score(0.02), letters: 2, completed: 0, tokens: 1,
                    guards: GuardResult(vetoes: [.shortSingleToken]),
                    thresholds: .balanced.withConfidentScore(0.90)),
            "ignore")
    }

    /// And a narrow separation is not either, however high the alternate reads:
    /// a word merely plausible in both languages must not be rewritten.
    func testAConfidentScoreStillNeedsASeparation() {
        XCTAssertEqual(
            verdict(alt: score(0.95), cur: score(0.60), letters: 4, completed: 0, tokens: 1,
                    guards: GuardResult(vetoes: [.shortSingleToken]),
                    thresholds: .balanced.withConfidentScore(0.90)),
            "suggest",
            "0.35 of separation is under confidentMinGap, so the confident path "
                + "refuses and the ordinary suggestion path takes it instead")
    }

}
