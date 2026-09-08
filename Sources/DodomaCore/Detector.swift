import Foundation

/// Ties the segmenter, the guards and the decision function together for one
/// English/Arabic layout pair.
///
/// This is the whole detection brain behind one call. M4 drives it from the
/// typing pipeline; `--decide` and `--eval` drive it from the CLI. It owns no
/// state beyond the layouts and models, so it is safe to share.
public struct Detector: Sendable {
    public let englishLayout: KeyboardLayout
    public let arabicLayout: KeyboardLayout
    public let englishModel: LanguageModel
    public let arabicModel: LanguageModel

    public init(
        englishLayout: KeyboardLayout,
        arabicLayout: KeyboardLayout,
        englishModel: LanguageModel = .shared(.english),
        arabicModel: LanguageModel = .shared(.arabic)
    ) {
        self.englishLayout = englishLayout
        self.arabicLayout = arabicLayout
        self.englishModel = englishModel
        self.arabicModel = arabicModel
    }

    /// Result of one pass. `region` is nil when nothing at the end of the
    /// buffer looked wrong, which is the overwhelmingly common case.
    public struct Detection: Sendable {
        public let typedLanguage: Language
        public let region: CandidateRegion?
        public let analysis: FixAnalysis?
        public let decision: Decision
    }

    public func layout(for language: Language) -> KeyboardLayout {
        language == .english ? englishLayout : arabicLayout
    }

    public func model(for language: Language) -> LanguageModel {
        language == .english ? englishModel : arabicModel
    }

    public func detect(
        keys: [CapturedKey],
        typedLanguage: Language,
        policy: AppPolicy = .normal,
        aggressiveness: Aggressiveness = .balanced,
        confidentScore: Double? = nil,
        recentlyUndone: Set<String> = []
    ) -> Detection {
        let alternateLanguage: Language = typedLanguage == .english ? .arabic : .english
        let currentLayout = layout(for: typedLanguage)
        let alternateLayout = layout(for: alternateLanguage)
        let models = LanguageModelPair(
            current: model(for: typedLanguage), alternate: model(for: alternateLanguage))

        guard
            let region = Segmenter.candidate(
                in: keys,
                currentLayout: currentLayout,
                alternateLayout: alternateLayout,
                models: models)
        else {
            return Detection(
                typedLanguage: typedLanguage, region: nil, analysis: nil,
                decision: .ignore(reason: "no candidate region"))
        }

        let guards = TextGuards.evaluate(
            region.typedText, currentModel: models.current, recentlyUndone: recentlyUndone)
        let analysis = FixDecision.analyse(
            region: region,
            currentLayout: currentLayout,
            alternateLayout: alternateLayout,
            models: models,
            guards: guards,
            policy: policy,
            aggressiveness: aggressiveness, confidentScore: confidentScore)

        return Detection(
            typedLanguage: typedLanguage, region: region, analysis: analysis,
            decision: analysis.decision)
    }

    /// Replays `text` as if it had been typed under `typedLanguage`'s layout.
    /// Returns nil when that layout cannot type one of the characters.
    public func detect(
        text: String,
        typedLanguage: Language? = nil,
        policy: AppPolicy = .normal,
        aggressiveness: Aggressiveness = .balanced,
        confidentScore: Double? = nil,
        recentlyUndone: Set<String> = [],
        keyboardType: UInt32? = nil
    ) -> Detection? {
        let language = typedLanguage ?? Self.scriptLanguage(of: text)
        guard
            let keys = InverseKeymap.keys(
                for: text, layout: layout(for: language), keyboardType: keyboardType)
        else { return nil }
        return detect(
            keys: keys, typedLanguage: language, policy: policy,
            aggressiveness: aggressiveness, confidentScore: confidentScore,
            recentlyUndone: recentlyUndone)
    }

    /// Which layout the text was most likely typed under, from its script
    /// alone. Arabic characters can only come off the Arabic layout.
    public static func scriptLanguage(of text: String) -> Language {
        for scalar in text.unicodeScalars where (0x0600...0x06FF).contains(scalar.value) {
            return .arabic
        }
        return .english
    }
}
