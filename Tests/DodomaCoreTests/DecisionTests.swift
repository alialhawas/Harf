import XCTest

@testable import DodomaCore

final class DecisionTests: XCTestCase {
    private static let canonical = "HC MV; HKH HSMDIH HGDML"
    private static let canonicalArabic = "اذ ودك انا اسويها اليوم"

    // MARK: - Threshold presets

    /// These numbers are the contract the seed corpus was labelled against.
    /// Changing one is a product decision, not a refactor.
    func testThresholdPresets() {
        XCTAssertEqual(Thresholds.balanced.autoAlt, 0.62)
        XCTAssertEqual(Thresholds.balanced.autoCur, 0.28)
        XCTAssertEqual(Thresholds.balanced.autoGap, 0.40)
        XCTAssertEqual(Thresholds.balanced.suggestGap, 0.18)
        XCTAssertEqual(Thresholds.balanced.suggestAlt, 0.45)
        XCTAssertEqual(Thresholds.balanced.decisiveAlt, 0.78)
        XCTAssertEqual(Thresholds.balanced.decisiveGap, 0.50)
        XCTAssertEqual(Thresholds.balanced.dictOverrideAlt, 0.80)
        XCTAssertEqual(Thresholds.balanced.dictOverrideCur, 0.15)

        XCTAssertEqual(Thresholds.conservative.autoAlt, 0.70)
        XCTAssertEqual(Thresholds.conservative.autoCur, 0.20)
        XCTAssertEqual(Thresholds.conservative.autoGap, 0.48)
        XCTAssertEqual(Thresholds.conservative.suggestGap, 0.26)
        XCTAssertEqual(Thresholds.conservative.decisiveAlt, 0.86)
        XCTAssertEqual(Thresholds.conservative.decisiveGap, 0.58)
        XCTAssertEqual(Thresholds.conservative.dictOverrideAlt, 0.88)
        XCTAssertEqual(Thresholds.conservative.dictOverrideCur, 0.07)

        XCTAssertEqual(Thresholds.eager.autoAlt, 0.56)
        XCTAssertEqual(Thresholds.eager.autoCur, 0.34)
        XCTAssertEqual(Thresholds.eager.autoGap, 0.34)
        XCTAssertEqual(Thresholds.eager.suggestGap, 0.12)
        XCTAssertEqual(Thresholds.eager.decisiveAlt, 0.72)
        XCTAssertEqual(Thresholds.eager.decisiveGap, 0.44)
        XCTAssertEqual(Thresholds.eager.dictOverrideAlt, 0.74)
        XCTAssertEqual(Thresholds.eager.dictOverrideCur, 0.21)

        XCTAssertEqual(Thresholds.autoMinLetters, 6)
        XCTAssertEqual(Thresholds.suggestMinLetters, 4)
        XCTAssertEqual(Thresholds.dictOverrideTokens, 2)
    }

    /// Every automatic gate moves with the preset, by the same ±0.08 / −0.06
    /// of strictness. A gate left behind is a gate that decides at Balanced's
    /// numbers however the user set the slider.
    func testEveryAutomaticGateMovesWithThePreset() {
        let stricter: [(String, KeyPath<Thresholds, Double>)] = [
            ("autoAlt", \.autoAlt), ("autoGap", \.autoGap), ("suggestGap", \.suggestGap),
            ("decisiveAlt", \.decisiveAlt), ("decisiveGap", \.decisiveGap),
            ("dictOverrideAlt", \.dictOverrideAlt),
        ]
        for (name, gate) in stricter {
            XCTAssertGreaterThan(
                Thresholds.conservative[keyPath: gate], Thresholds.balanced[keyPath: gate], name)
            XCTAssertLessThan(
                Thresholds.eager[keyPath: gate], Thresholds.balanced[keyPath: gate], name)
        }
        // Ceilings: stricter means a lower number.
        for (name, gate) in [("autoCur", \Thresholds.autoCur),
                             ("dictOverrideCur", \Thresholds.dictOverrideCur)] {
            XCTAssertLessThan(
                Thresholds.conservative[keyPath: gate], Thresholds.balanced[keyPath: gate], name)
            XCTAssertGreaterThan(
                Thresholds.eager[keyPath: gate], Thresholds.balanced[keyPath: gate], name)
        }
    }

    // MARK: - The canonical fix

    func testCanonicalSampleAutoApplies() throws {
        let fixture = try DetectorFixture.make()
        let detection = try XCTUnwrap(fixture.detect(Self.canonical))
        guard case .autoApply(let fix) = detection.decision else {
            return XCTFail("expected autoApply, got \(detection.decision)")
        }
        XCTAssertEqual(fix.insertText, Self.canonicalArabic)
        XCTAssertEqual(fix.replacedText, Self.canonical)
        XCTAssertEqual(fix.deleteCount, Self.canonical.count)
        XCTAssertEqual(fix.capsMode, .shiftStripped)
        XCTAssertEqual(fix.targetLayoutID, fixture.arabic.layout.sourceID)
        XCTAssertEqual(fix.sourceLayoutID, fixture.abc.layout.sourceID)
    }

    func testEnglishTypedUnderTheArabicLayoutAutoApplies() throws {
        let fixture = try DetectorFixture.make()
        let detection = try XCTUnwrap(fixture.detect("اثممخ اخص شقث غخع"))
        guard case .autoApply(let fix) = detection.decision else {
            return XCTFail("expected autoApply, got \(detection.decision)")
        }
        XCTAssertEqual(fix.insertText, "hello how are you")
        XCTAssertEqual(fix.targetLayoutID, fixture.abc.layout.sourceID)
    }

    // MARK: - Gates

    /// Each row: text, then the verdict expected of it, and why.
    func testGateTable() throws {
        let fixture = try DetectorFixture.make()
        let cases: [(text: String, expected: String, why: String)] = [
            (Self.canonical, "autoApply", "long, finished, unguarded, huge gap"),
            ("hgsghl", "suggest", "no completed token: the word may still be in progress"),
            ("sghl", "suggest", "shortSingleToken veto demotes an otherwise clean fix"),
            ("hgm", "ignore", "3 letters is below the suggestion floor"),
            ("please send me the report", "ignore", "no candidate region at all"),
            ("v2.1.3", "ignore", "two guards block even a suggestion"),
            ("shgt", "ignore", "alternate reads no better than 0.45"),
        ]
        for row in cases {
            let detection = try XCTUnwrap(fixture.detect(row.text), row.text)
            XCTAssertEqual(
                verdictName(detection.decision), row.expected,
                "\(row.text): \(row.why) — \(detection.decision)")
        }
    }

    func testGuardVetoDemotesAutoToSuggest() throws {
        let fixture = try DetectorFixture.make()
        let detection = try XCTUnwrap(
            fixture.detect(Self.canonical, recentlyUndone: [Self.canonical]))
        XCTAssertEqual(verdictName(detection.decision), "suggest")
        XCTAssertEqual(detection.analysis?.guards.vetoes, [.recentlyUndone])
    }

    // MARK: - Policy

    func testSuggestOnlyNeverAutoApplies() throws {
        let fixture = try DetectorFixture.make()
        for text in [Self.canonical, "اثممخ اخص شقث غخع", "sghl"] {
            let detection = try XCTUnwrap(fixture.detect(text, policy: .suggestOnly), text)
            XCTAssertFalse(detection.decision.isAuto, text)
        }
        let canonical = try XCTUnwrap(
            fixture.detect(Self.canonical, policy: .suggestOnly))
        XCTAssertEqual(verdictName(canonical.decision), "suggest")
    }

    func testOffDoesNothingAtAll() throws {
        let fixture = try DetectorFixture.make()
        for text in [Self.canonical, "اثممخ اخص شقث غخع", "sghl"] {
            let detection = try XCTUnwrap(fixture.detect(text, policy: .off), text)
            XCTAssertEqual(detection.decision, .ignore(reason: "policy off"), text)
        }
    }

    // MARK: - Aggressiveness

    func testPresetsDisagreeOnTheCanonicalSample() throws {
        let fixture = try DetectorFixture.make()
        // alt.combined is 0.69: over the balanced bar of 0.62, under the
        // conservative bar of 0.70.
        XCTAssertEqual(
            verdictName(
                try XCTUnwrap(fixture.detect(Self.canonical, aggressiveness: .conservative))
                    .decision),
            "suggest")
        XCTAssertEqual(
            verdictName(
                try XCTUnwrap(fixture.detect(Self.canonical, aggressiveness: .balanced)).decision),
            "autoApply")
        XCTAssertEqual(
            verdictName(
                try XCTUnwrap(fixture.detect(Self.canonical, aggressiveness: .eager)).decision),
            "autoApply")
    }

    func testAggressivenessMapsToItsThresholds() {
        XCTAssertEqual(Aggressiveness.conservative.thresholds, .conservative)
        XCTAssertEqual(Aggressiveness.balanced.thresholds, .balanced)
        XCTAssertEqual(Aggressiveness.eager.thresholds, .eager)
    }

    // MARK: - Rendering choice

    func testAlternateRenderingPicksTheBestCapsMode() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys(Self.canonical)
        let region = try XCTUnwrap(fixture.segment(keys))
        let best = try XCTUnwrap(
            FixDecision.bestAlternate(
                region: region, alternateLayout: fixture.arabic.layout,
                model: fixture.detector.arabicModel))

        // asTyped would render the shifted Arabic layout, which is diacritics.
        XCTAssertEqual(best.capsMode, .shiftStripped)
        XCTAssertEqual(best.text, Self.canonicalArabic)
    }

    private func verdictName(_ decision: Decision) -> String {
        switch decision {
        case .ignore: return "ignore"
        case .suggest: return "suggest"
        case .autoApply: return "autoApply"
        }
    }
}
