import Foundation

/// What a flip implies about the words this user writes.
///
/// A flip is the user stating which of the two readings was meant: the flipped
/// text is real words, and the text it replaced was never a word at all. Both
/// halves are worth acting on, because the wrong-layout original will have been
/// sitting in the passive learner's counts, quietly climbing towards being
/// treated as vocabulary.
public enum FlipLearning {
    public struct Plan: Equatable, Sendable {
        /// Words to record in the target language.
        public let add: [String]
        /// Counted sightings to drop in the source language.
        public let forget: [String]

        public init(add: [String], forget: [String]) {
            self.add = add
            self.forget = forget
        }
    }

    /// - Parameters:
    ///   - target: model for the language the flip produced.
    ///   - source: model for the language the flip replaced.
    public static func plan(for flip: Flip, target: LanguageModel, source: LanguageModel) -> Plan {
        // Only what the shipped list lacks, on both sides. Recording a word it
        // already knows changes no score, and forgetting one would be asking
        // the lexicon to unlearn something it never learned.
        let add = deduplicated(target.vocabulary(in: flip.flipped).filter { !target.isKnownWord($0) })
        let forget = deduplicated(
            source.vocabulary(in: flip.original).filter { !source.isKnownWord($0) })
        return Plan(add: add, forget: forget)
    }

    /// Order is kept so the words read back in the order they were written.
    private static func deduplicated(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        return words.filter { seen.insert($0).inserted }
    }
}
