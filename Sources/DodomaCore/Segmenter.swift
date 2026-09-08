import Foundation

/// The current and alternate language models for one detection pass.
public struct LanguageModelPair: Sendable {
    public let current: LanguageModel
    public let alternate: LanguageModel

    public init(current: LanguageModel, alternate: LanguageModel) {
        self.current = current
        self.alternate = alternate
    }
}

/// The trailing slice of the buffer that is a candidate for rewriting.
public struct CandidateRegion: Equatable, Sendable {
    /// Contiguous keys, from the first key of the first bad token through the
    /// END OF THE BUFFER — trailing whitespace included.
    ///
    /// The region has to run to the caret, because a fix deletes backwards
    /// from it. Stopping at the last letter would leave the trailing space
    /// between the caret and the text being replaced, and deleting
    /// `typedText.count` clusters would then eat one letter too many and
    /// strand the space. The space is cheap to carry: it renders to itself
    /// under either layout, so it reappears unchanged in `insertText`.
    public let keys: [CapturedKey]
    /// What is actually on screen for those keys, trailing whitespace included.
    /// Exactly the text a fix replaces.
    public let typedText: String
    /// Letters only: punctuation and spaces do not count towards length gates.
    public let letterCount: Int
    /// Tokens in the region that were finished with a space. A region with at
    /// least one is far safer to auto-fix than a word still being typed.
    public let completedTokenCount: Int
    /// Tokens that read decisively better under the other layout.
    public let alternateVotes: Int
    /// Tokens that read decisively better as they stand.
    public let currentVotes: Int

    public init(
        keys: [CapturedKey], typedText: String, letterCount: Int, completedTokenCount: Int,
        alternateVotes: Int = 0, currentVotes: Int = 0
    ) {
        self.keys = keys
        self.typedText = typedText
        self.letterCount = letterCount
        self.completedTokenCount = completedTokenCount
        self.alternateVotes = alternateVotes
        self.currentVotes = currentVotes
    }

    /// Whitespace-separated token count of the as-typed text.
    public var tokenCount: Int {
        typedText.split(whereSeparator: \.isWhitespace).count
    }
}

/// Picks the trailing run of tokens that the user probably typed in the wrong
/// layout.
///
/// Walking backwards from the caret is what makes mid-sentence switches work:
/// `check this HSMDIH` must offer to fix only the last word. The walk stops at
/// the first token the current language recognises, because a real word is a
/// hard boundary — whatever precedes it was typed deliberately.
public enum Segmenter {
    /// A token is considered current-language text at or above this coverage.
    public static let coveredThreshold = 0.5

    /// How much better a longer region must score before it is taken.
    ///
    /// A longer run has to earn its extra tokens rather than merely tie, so the
    /// region never creeps outward on a rounding difference.
    public static let extensionMargin = 0.05

    /// How much better a single token must read under the other layout before
    /// it counts as a vote. Below this the token is evidence of nothing and
    /// abstains rather than being counted for whichever side edged ahead.
    public static let voteMargin = 0.25
    /// The share of voting tokens that must favour the other layout.
    public static let majorityRatio = 0.7
    /// Votes a majority needs before it means anything. Two tokens agreeing is
    /// a coincidence; the aggregate rules already cover short runs.
    public static let majorityMinimumVotes = 2
    /// How plausible a wall token's *other* reading must be before a majority
    /// is allowed to reach past it.
    ///
    /// This is what separates a word typed on purpose from one produced by
    /// accident. "report" left on the English layout renders to قثحخقف, which
    /// scores 0.00 as Arabic — nobody typed that by mistake, so it is a real
    /// boundary. فقعر renders to "trun", which scores 0.76 as English: not a
    /// word, but shaped like one, which is exactly what a typo looks like.
    /// Dictionary membership cannot make this distinction; both are absent
    /// from it.
    public static let wallAlternateBigram = 0.70

    /// Keys whose produced text is a space. Tab and newline never reach here:
    /// the reset policy clears the buffer on both.
    private static let whitespaceTexts: Set<String> = [" ", "\u{00A0}"]

    public static func candidate(
        in keys: [CapturedKey],
        currentLayout: KeyboardLayout,
        alternateLayout: KeyboardLayout,
        models: LanguageModelPair
    ) -> CandidateRegion? {
        let tokens = tokenRanges(in: keys)
        guard !tokens.isEmpty else { return nil }

        // Scored once, up front. The walk, the majority test and the tally on
        // the returned region all ask the same question of the same tokens,
        // and each token costs a dictionary lookup plus three renderings.
        let scored = tokens.map {
            score(token: $0, in: keys, currentLayout: currentLayout,
                  alternateLayout: alternateLayout, models: models)
        }

        var firstAccepted: Int?
        for position in stride(from: tokens.count - 1, through: 0, by: -1) {
            let token = scored[position]
            let typed = token.typed

            if token.coverage >= coveredThreshold { break }

            if token.alternate > token.current {
                firstAccepted = position
                continue
            }

            // A one-letter token is evidence of nothing. Both languages score
            // it the same, so the comparison above ties and the walk would
            // stop — stranding everything before it. That is how "how i did
            // what" typed on the wrong layout came back as "اخص ه did what":
            // the lone "i" was a wall, not a word. Step over it. It cannot
            // start a region, because `firstAccepted` only moves for a token
            // that earns it, so a genuine leading "I" or "a" is still left
            // alone; one merely sitting between two rewritten words is
            // carried along by the region that reaches the caret.
            if carriesNoSignal(typed) { continue }

            break
        }

        // The walk can also refuse to start at all.
        //
        // It reads right to left from the caret, so if the *last* token happens
        // to be a real word of the language on screen it breaks on the first
        // step and nothing is ever accepted. Typing "now i can merged ths dev
        // to main" on the Arabic layout ends in وشهر, which strips to شهر —
        // "month" — and the whole sentence was passed over. Whether the
        // accident lands in the middle of the run or at the end of it is not a
        // meaningful difference, so the same region-level question is asked
        // here: is there a run ending at the caret that reads better under the
        // other layout? Nothing is returned unless one does, and the decision
        // thresholds still have to be met afterwards.
        var accepted = firstAccepted
        if accepted == nil {
            var best: (position: Int, gap: Double)?
            for position in stride(from: tokens.count - 1, through: 0, by: -1) {
                let gap = regionGap(
                    from: tokens[position].range.lowerBound, in: keys,
                    currentLayout: currentLayout, alternateLayout: alternateLayout,
                    models: models)
                if best == nil || gap > best!.gap + extensionMargin {
                    best = (position, gap)
                }
            }
            if let best, best.gap > 0 { accepted = best.position }
        }

        guard var firstAccepted = accepted else { return nil }

        // The walk above stops at the first token the current language claims,
        // on the theory that a real word marks where deliberate typing began.
        // Two languages sharing one keyboard break that theory: "what is pr
        // dojs" typed on the Arabic layout lands on "صاشف هس حق يختس", and حق
        // is a real Arabic word. The wall went up mid-sentence and only the
        // last token was ever offered.
        //
        // So having found where the walk stopped, ask the region-level
        // question it cannot: does a longer run read better under the other
        // layout than the one we settled on? For that sentence the whole buffer
        // wins by 0.60 against 0.40. For "check this hgsghl" it loses, -0.23
        // against 0.91, because pulling real English into the region wrecks it.
        // Mixed-language text stays protected by arithmetic rather than by a
        // rule that has to guess.
        if firstAccepted > 0 {
            var bestGap = regionGap(
                from: tokens[firstAccepted].range.lowerBound, in: keys,
                currentLayout: currentLayout, alternateLayout: alternateLayout, models: models)
            for position in stride(from: firstAccepted - 1, through: 0, by: -1) {
                let gap = regionGap(
                    from: tokens[position].range.lowerBound, in: keys,
                    currentLayout: currentLayout, alternateLayout: alternateLayout, models: models)
                if gap > bestGap + extensionMargin {
                    bestGap = gap
                    firstAccepted = position
                }
            }
        }

        // One last question, and the one the two rules above cannot answer.
        //
        // Both of them compare whole regions by their average score, and an
        // average is the wrong statistic when a single token accidentally
        // reads as a real word of the language on screen. "how we trun it"
        // typed on the Arabic layout lands on "اخص صث فقعر هف", and فقعر
        // strips its ف clitic to قعر — "depth" — so it scores 0.82 as Arabic.
        // Averaged in, it drags the whole run to a 0.32 separation and the
        // region collapses to the last two letters.
        //
        // Counted instead of averaged, the same run is three tokens to one for
        // English, by margins of 0.45, 1.00 and 0.92. So walk left while a
        // clear majority of the tokens still favours the other layout. Genuine
        // text before the mistake defends itself: pulling it in adds votes to
        // the other side and the majority collapses.
        if firstAccepted > 0 {
            var start = firstAccepted
            for position in stride(from: firstAccepted - 1, through: 0, by: -1) {
                let token = scored[position]
                // A word that reads as deliberate text and whose other reading
                // is not even shaped like the other language is a real
                // boundary. No majority reaches past it: "hkh hsmdih report
                // hkh hsmdih" is four gibberish tokens to one, and "report"
                // still ends the region, because nobody produces "report" by
                // holding the wrong layout.
                if token.votesCurrent && token.alternateBigram < wallAlternateBigram { break }
                // A single letter cannot start a region, for the same reason it
                // cannot stop one.
                if token.noSignal { continue }
                if tally(of: scored[position...]).favoursAlternate { start = position }
            }
            firstAccepted = start
        }

        let start = tokens[firstAccepted].range.lowerBound
        // Through the end of the buffer, not the end of the last token: the
        // region must reach the caret. See `CandidateRegion.keys`.
        let regionKeys = Array(keys[start...])
        let typedText = onScreenText(of: regionKeys, layout: currentLayout)

        return CandidateRegion(
            keys: regionKeys,
            typedText: typedText,
            letterCount: typedText.filter(\.isLetter).count,
            completedTokenCount: tokens[firstAccepted...].filter(\.isCompleted).count,
            alternateVotes: tally(of: scored[firstAccepted...]).alternate,
            currentVotes: tally(of: scored[firstAccepted...]).current)
    }

    /// One token, read both ways.
    private struct ScoredToken {
        let typed: String
        /// How much of the token the current language's dictionary claims.
        let coverage: Double
        let current: Double
        /// Best of the three caps modes: a run typed with Caps Lock renders to
        /// junk under `asTyped` and to the intended text under the others.
        let alternate: Double
        /// Letter-shape score of that same reading, with the dictionary left
        /// out. A typo is absent from the dictionary but still shaped like the
        /// language; junk is neither.
        let alternateBigram: Double
        /// Too short for either language to say anything about.
        let noSignal: Bool

        /// Reads decisively better as it stands than under the other layout.
        var votesCurrent: Bool { !noSignal && current - alternate >= voteMargin }
    }

    private static func score(
        token: TokenRange, in keys: [CapturedKey],
        currentLayout: KeyboardLayout, alternateLayout: KeyboardLayout,
        models: LanguageModelPair
    ) -> ScoredToken {
        let tokenKeys = Array(keys[token.range])
        let typed = onScreenText(of: tokenKeys, layout: currentLayout)
        let best = CapsMode.allCases
            .map { models.alternate.combined(
                LayoutRenderer.render(tokenKeys, layout: alternateLayout, capsMode: $0)) }
            .max { $0.combined < $1.combined }
        return ScoredToken(
            typed: typed,
            coverage: models.current.dictCoverage(typed),
            current: models.current.combined(typed).combined,
            alternate: best?.combined ?? 0,
            alternateBigram: best?.bigram ?? 0,
            noSignal: carriesNoSignal(typed))
    }

    /// How the tokens of a region vote.
    ///
    /// A token only votes when one reading beats the other by `voteMargin`.
    /// Anything closer than that abstains: counting a 0.02 difference as a
    /// vote would let a run of ambiguous fragments outvote real evidence.
    private static func tally(
        of tokens: ArraySlice<ScoredToken>
    ) -> (alternate: Int, current: Int, favoursAlternate: Bool) {
        var alternate = 0
        var current = 0
        for token in tokens where !token.noSignal {
            let gap = token.alternate - token.current
            if gap >= voteMargin { alternate += 1 } else if -gap >= voteMargin { current += 1 }
        }
        let voting = alternate + current
        let favours =
            alternate >= majorityMinimumVotes
            && voting > 0
            && Double(alternate) / Double(voting) >= majorityRatio
        return (alternate, current, favours)
    }

    /// How much better the whole run from `start` reads under the other layout.
    private static func regionGap(
        from start: Int, in keys: [CapturedKey],
        currentLayout: KeyboardLayout, alternateLayout: KeyboardLayout,
        models: LanguageModelPair
    ) -> Double {
        let regionKeys = Array(keys[start...])
        let current = models.current.combined(
            onScreenText(of: regionKeys, layout: currentLayout)).combined
        let alternate = CapsMode.allCases
            .map { models.alternate.combined(
                LayoutRenderer.render(regionKeys, layout: alternateLayout, capsMode: $0)
            ).combined }
            .max() ?? 0
        return alternate - current
    }

    /// Whether a token is too short to be evidence for either language.
    ///
    /// Scoring one letter is a coin toss: the dictionaries exclude length-one
    /// tokens by design, and a single character's bigram score says nothing.
    private static func carriesNoSignal(_ typed: String) -> Bool {
        typed.filter(\.isLetter).count <= 1
    }

    /// What those keys put on screen.
    ///
    /// A real capture carries the text each event produced, which is the
    /// authority: the fix has to delete exactly that many grapheme clusters.
    /// Synthetic keys (tests, the CLI harnesses) may carry none, so they are
    /// rendered through the layout they were "typed" under instead.
    private static func onScreenText(of keys: [CapturedKey], layout: KeyboardLayout) -> String {
        let produced = keys.map(\.producedText).joined()
        guard produced.isEmpty else { return produced }
        return LayoutRenderer.render(keys, layout: layout, capsMode: .asTyped)
    }

    private struct TokenRange {
        let range: Range<Int>
        /// Followed by a whitespace key, i.e. the user finished the word.
        let isCompleted: Bool
    }

    private static func tokenRanges(in keys: [CapturedKey]) -> [TokenRange] {
        var ranges: [TokenRange] = []
        var start: Int?
        for (index, key) in keys.enumerated() {
            if whitespaceTexts.contains(key.producedText) {
                if let begin = start {
                    ranges.append(TokenRange(range: begin..<index, isCompleted: true))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let begin = start {
            ranges.append(TokenRange(range: begin..<keys.count, isCompleted: false))
        }
        return ranges
    }
}
