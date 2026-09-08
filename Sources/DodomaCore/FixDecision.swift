import Foundation

/// How willing Dodoma is to rewrite text without asking. A user preference.
public enum Aggressiveness: String, Codable, Sendable, CaseIterable {
    case conservative
    case balanced
    case eager

    public var thresholds: Thresholds {
        switch self {
        case .conservative: return .conservative
        case .balanced: return .balanced
        case .eager: return .eager
        }
    }
}

/// What the app is currently allowed to do. Owned by the safety layer
/// (`AppSettings`); defined here because the decision function is the single
/// place that reads it.
public enum AppPolicy: String, Codable, Sendable, CaseIterable {
    /// Auto-fix and suggest.
    case normal
    /// Never rewrite silently; a suggestion is still allowed.
    case suggestOnly
    /// Do nothing at all (secure input, blocklisted app, user paused).
    case off
}

/// Score cut-offs for one aggressiveness preset.
///
/// The presets shift the three automatic gates in lockstep — conservative by
/// +0.08 of strictness, eager by −0.06 — so there is exactly one axis to
/// reason about. The dictionary override and the suggestion floor are shared:
/// the override is already a near-certainty test, and a suggestion that reads
/// worse than `suggestAlt` is not worth showing at any setting.
public struct Thresholds: Equatable, Sendable {
    /// Alternate rendering must score at least this to auto-apply.
    public let autoAlt: Double
    /// Current-layout text must score at most this to auto-apply.
    public let autoCur: Double
    /// Minimum alt − cur separation to auto-apply.
    public let autoGap: Double
    /// Minimum alt − cur separation to suggest.
    public let suggestGap: Double
    /// Minimum alternate score to suggest.
    public let suggestAlt: Double

    /// Score at which a fix is taken however short the text is, or nil to
    /// leave the length rules in charge.
    ///
    /// The length rules exist because short text is usually weak evidence: two
    /// letters can land on a real word in either language by luck. But that is
    /// a statement about the *average* short token, and the score already says
    /// which one is in front of us. "what" typed on the Arabic layout reads
    /// 0.999 against 0.24 — the rules were holding back a certainty because of
    /// a rule about uncertainty. Above this number the evidence speaks for
    /// itself; below it the length rules still apply.
    public var confidentScore: Double?

    /// Decisive shortcut: an overwhelming alternate reading with a wide
    /// separation, which `autoCur` must not veto.
    ///
    /// `autoCur` asks whether the text on screen is plausible as it stands, and
    /// a few accidental real words inflate it: "now i can merged ths dev to
    /// main" typed on the Arabic layout ends in وشهر, which strips to شهر —
    /// "month" — and lifted the typed reading to 0.33 against a ceiling of 0.28
    /// even though the English reading scored 0.84 and the separation was 0.51.
    /// When both of those hold there is no real ambiguity left to protect.
    public static let decisiveAlt = 0.78
    public static let decisiveGap = 0.50

    /// Dictionary shortcut: when the alternate rendering is almost entirely
    /// real words and the typed text is almost entirely not, the bigram gates
    /// are redundant.
    public static let dictOverrideAlt = 0.80
    public static let dictOverrideCur = 0.15
    public static let dictOverrideTokens = 2

    /// Length gates, shared by every preset.
    public static let autoMinLetters = 6
    public static let suggestMinLetters = 4

    /// Letters a region needs before the score is allowed to speak for it.
    ///
    /// Two letters is not evidence at any score: the dictionaries weight
    /// two-letter tokens at half and a great many of them are real words in
    /// both languages. Three is where a reading starts to mean something.
    public static let confidentMinLetters = 3

    /// The separation a confident fix still has to clear.
    ///
    /// Skipping the length rules is not the same as skipping the comparison:
    /// the other reading must still be decisively better, or a word that is
    /// merely plausible in both languages would be rewritten.
    public static let confidentMinGap = 0.45

    public static let balanced = Thresholds(
        autoAlt: 0.62, autoCur: 0.28, autoGap: 0.40, suggestGap: 0.18, suggestAlt: 0.45)
    public static let conservative = Thresholds(
        autoAlt: 0.70, autoCur: 0.20, autoGap: 0.48, suggestGap: 0.26, suggestAlt: 0.45)
    public static let eager = Thresholds(
        autoAlt: 0.56, autoCur: 0.34, autoGap: 0.34, suggestGap: 0.12, suggestAlt: 0.45)

    /// The same cut-offs with a confidence threshold attached.
    public func withConfidentScore(_ score: Double?) -> Thresholds {
        var copy = self
        copy.confidentScore = score
        return copy
    }
}

/// A concrete edit, expressed relative to the caret.
///
/// The contract the applier (M4) may rely on, exactly:
///
/// 1. `deleteCount` is the number of grapheme clusters IMMEDIATELY BEHIND THE
///    CARET, with nothing in between. There is no offset to add: the region
///    always runs to the end of the buffer, so any whitespace the user typed
///    after the misspelt word is part of `replacedText` and counted here.
/// 2. Deleting exactly `deleteCount` clusters removes exactly `replacedText`;
///    `deleteCount == replacedText.count`.
/// 3. Typing `insertText` afterwards leaves the caret where it started, in the
///    sense that any trailing whitespace in `replacedText` reappears at the end
///    of `insertText` — a space renders to a space under either layout, so the
///    user can keep typing the next word without retyping the separator.
///
/// So the whole operation is: `text.removeLast(deleteCount); text += insertText`.
public struct Fix: Equatable, Sendable {
    public let deleteCount: Int
    public let insertText: String
    public let targetLayoutID: String
    public let sourceLayoutID: String
    public let replacedText: String
    public let capsMode: CapsMode

    public init(
        deleteCount: Int,
        insertText: String,
        targetLayoutID: String,
        sourceLayoutID: String,
        replacedText: String,
        capsMode: CapsMode
    ) {
        self.deleteCount = deleteCount
        self.insertText = insertText
        self.targetLayoutID = targetLayoutID
        self.sourceLayoutID = sourceLayoutID
        self.replacedText = replacedText
        self.capsMode = capsMode
    }
}

public enum Decision: Equatable, Sendable {
    case ignore(reason: String)
    case suggest(Fix)
    case autoApply(Fix)

    public var fix: Fix? {
        switch self {
        case .ignore: return nil
        case .suggest(let fix), .autoApply(let fix): return fix
        }
    }

    public var isAuto: Bool {
        if case .autoApply = self { return true }
        return false
    }
}

/// Everything the decision was made from, so the CLI and the debug window can
/// explain a verdict without recomputing it.
public struct FixAnalysis: Sendable {
    public let decision: Decision
    public let current: Score
    public let alternate: Score
    /// Nil when no caps mode produced a renderable alternate.
    public let capsMode: CapsMode?
    public let alternateText: String
    public let guards: GuardResult
    public let thresholds: Thresholds

    public var gap: Double { alternate.combined - current.combined }
}

/// The pure decision function. No I/O, no clock, no layout enumeration: give it
/// a region and two layouts and it always returns the same verdict.
public enum FixDecision {
    /// A caps mode whose rendering leaves more than this fraction of keys
    /// unproducible is not a real reading of the sequence.
    public static let maxEmptyRate = 0.2

    public static func decide(
        region: CandidateRegion,
        currentLayout: KeyboardLayout,
        alternateLayout: KeyboardLayout,
        models: LanguageModelPair,
        guards: GuardResult,
        policy: AppPolicy = .normal,
        aggressiveness: Aggressiveness = .balanced,
        confidentScore: Double? = nil
    ) -> Decision {
        analyse(
            region: region,
            currentLayout: currentLayout,
            alternateLayout: alternateLayout,
            models: models,
            guards: guards,
            policy: policy,
            aggressiveness: aggressiveness, confidentScore: confidentScore
        ).decision
    }

    public static func analyse(
        region: CandidateRegion,
        currentLayout: KeyboardLayout,
        alternateLayout: KeyboardLayout,
        models: LanguageModelPair,
        guards: GuardResult,
        policy: AppPolicy = .normal,
        aggressiveness: Aggressiveness = .balanced,
        confidentScore: Double? = nil
    ) -> FixAnalysis {
        let thresholds = aggressiveness.thresholds.withConfidentScore(confidentScore)
        let current = models.current.combined(region.typedText)

        guard policy != .off else {
            return FixAnalysis(
                decision: .ignore(reason: "policy off"),
                current: current, alternate: .zero, capsMode: nil, alternateText: "",
                guards: guards, thresholds: thresholds)
        }

        guard
            let best = bestAlternate(
                region: region, alternateLayout: alternateLayout, model: models.alternate)
        else {
            return FixAnalysis(
                decision: .ignore(reason: "alternate layout renders nothing usable"),
                current: current, alternate: .zero, capsMode: nil, alternateText: "",
                guards: guards, thresholds: thresholds)
        }

        let fix = Fix(
            deleteCount: region.typedText.count,
            insertText: best.text,
            targetLayoutID: alternateLayout.sourceID,
            sourceLayoutID: currentLayout.sourceID,
            replacedText: region.typedText,
            capsMode: best.capsMode)

        let decision = verdict(
            region: region,
            current: current,
            alternate: best.score,
            fix: fix,
            guards: guards,
            policy: policy,
            thresholds: thresholds)

        return FixAnalysis(
            decision: decision,
            current: current,
            alternate: best.score,
            capsMode: best.capsMode,
            alternateText: best.text,
            guards: guards,
            thresholds: thresholds)
    }

    // MARK: - Gates

    /// The gate ladder, isolated from scoring so it can be table-driven with
    /// synthetic `Score` values at the threshold boundaries.
    static func verdict(
        region: CandidateRegion,
        current: Score,
        alternate: Score,
        fix: Fix,
        guards: GuardResult,
        policy: AppPolicy,
        thresholds: Thresholds
    ) -> Decision {
        let gap = alternate.combined - current.combined
        let lengthOK = region.letterCount >= Thresholds.autoMinLetters
        let completedOK = region.completedTokenCount >= 1
        let autoAllowed = policy == .normal && guards.isEmpty && lengthOK && completedOK

        // A score high enough to speak for itself, on text too short for the
        // ordinary rules. Only the shortness veto is waived: a URL, a path, an
        // identifier or a recently undone fix still blocks, because those say
        // the text is not prose at all rather than that it is merely brief.
        if policy == .normal,
           let confident = thresholds.confidentScore,
           alternate.combined >= confident,
           gap >= Thresholds.confidentMinGap,
           region.letterCount >= Thresholds.confidentMinLetters,
           guards.vetoesBesidesShortness.isEmpty
        {
            return .autoApply(fix)
        }

        if autoAllowed {
            let scoresOK =
                alternate.combined >= thresholds.autoAlt
                && current.combined <= thresholds.autoCur
                && gap >= thresholds.autoGap
            let dictOverride =
                alternate.dictCoverage >= Thresholds.dictOverrideAlt
                && region.tokenCount >= Thresholds.dictOverrideTokens
                && current.dictCoverage <= Thresholds.dictOverrideCur
            let decisive =
                alternate.combined >= Thresholds.decisiveAlt
                && gap >= Thresholds.decisiveGap
            if scoresOK || dictOverride || decisive { return .autoApply(fix) }
        }

        let suggestAllowed = policy == .normal || policy == .suggestOnly
        if suggestAllowed,
           !guards.blocksSuggest,
           region.letterCount >= Thresholds.suggestMinLetters,
           gap >= thresholds.suggestGap,
           alternate.combined >= thresholds.suggestAlt
        {
            return .suggest(fix)
        }

        return .ignore(
            reason: ignoreReason(
                region: region, alternate: alternate, gap: gap,
                guards: guards, thresholds: thresholds))
    }

    /// Names the first gate that failed, in the order a reader would check
    /// them. Only reachable when a suggestion gate failed: `policy == .off`
    /// returns earlier, and both remaining policies permit suggestions.
    private static func ignoreReason(
        region: CandidateRegion,
        alternate: Score,
        gap: Double,
        guards: GuardResult,
        thresholds: Thresholds
    ) -> String {
        if guards.blocksSuggest { return "guards \(guards.summary)" }
        if region.letterCount < Thresholds.suggestMinLetters {
            return "letterCount \(region.letterCount) < \(Thresholds.suggestMinLetters)"
        }
        if alternate.combined < thresholds.suggestAlt {
            return String(
                format: "alt %.2f < suggestAlt %.2f", alternate.combined, thresholds.suggestAlt)
        }
        if gap < thresholds.suggestGap {
            return String(format: "gap %.2f < suggestGap %.2f", gap, thresholds.suggestGap)
        }
        return "no gate met"
    }

    // MARK: - Candidate rendering

    struct AlternateRendering {
        let capsMode: CapsMode
        let text: String
        let score: Score
    }

    /// Best-scoring caps mode whose rendering the alternate layout can actually
    /// produce. Arabic-through-English is routinely typed with caps lock on and
    /// the shifted Arabic layout is nearly all diacritics, so the modes have to
    /// be tried rather than inferred.
    static func bestAlternate(
        region: CandidateRegion, alternateLayout: KeyboardLayout, model: LanguageModel
    ) -> AlternateRendering? {
        var best: AlternateRendering?
        for capsMode in CapsMode.allCases {
            let rendered = LayoutRenderer.renderSequence(
                region.keys, layout: alternateLayout, capsMode: capsMode)
            guard rendered.emptyRate <= maxEmptyRate, !rendered.text.isEmpty else { continue }
            let score = model.combined(rendered.text)
            if best == nil || score.combined > best!.score.combined {
                best = AlternateRendering(capsMode: capsMode, text: rendered.text, score: score)
            }
        }
        return best
    }
}
