import Foundation

/// A reason not to touch the text. Guards are deliberately cheap, syntactic
/// and pessimistic: the cost of rewriting a URL or an identifier is far higher
/// than the cost of missing one wrong-layout word.
public enum GuardReason: String, Sendable, Equatable, CaseIterable {
    /// Looks like a URL, a file path, an email address or an env var.
    case urlOrPath
    /// A letter sits next to a digit inside one token (`v2`, `sha1`).
    case digitsAdjacent
    /// camelCase, snake_case or SCREAMING_SNAKE.
    case identifierCase
    /// Two or more punctuation characters in a row.
    case consecutivePunct
    /// The whole region is one short token, where the models have no signal.
    case shortSingleToken
    /// The text already reads as the language the user is typing in.
    case currentLangCoverage
    /// Arabic and Latin letters touch inside a single token.
    case mixedScriptToken
    /// The user just undid this exact text; do not fight them.
    case recentlyUndone
}

/// The guards that fired for a region.
///
/// One veto blocks an automatic fix, two block even a suggestion. That
/// asymmetry is the point: a single weak signal should demote a fix to a
/// suggestion, not silence it.
public struct GuardResult: Equatable, Sendable {
    public let vetoes: [GuardReason]

    public init(vetoes: [GuardReason]) {
        self.vetoes = vetoes
    }

    public var isEmpty: Bool { vetoes.isEmpty }

    /// Everything except "this is only one short word".
    ///
    /// Shortness is a statement about how much evidence there is, which a high
    /// enough score answers directly. Every other veto says the text is not
    /// prose — a path, an address, an identifier — and no score overrides that.
    public var vetoesBesidesShortness: [GuardReason] {
        vetoes.filter { $0 != .shortSingleToken }
    }
    public var blocksAuto: Bool { !vetoes.isEmpty }
    public var blocksSuggest: Bool { vetoes.count >= 2 }

    public var summary: String {
        vetoes.isEmpty ? "none" : vetoes.map(\.rawValue).joined(separator: ",")
    }
}

public enum TextGuards {
    /// Characters that turn a word into a locator rather than prose.
    private static let pathCharacters: Set<Character> = [".", "/", "\\", "@", "_", "=", "~", "$"]
    /// Stripped before the path test so that "done." is prose, not a path.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "،", "؛", "؟",
    ]

    /// Evaluates every guard over the region's as-typed text.
    ///
    /// - Parameters:
    ///   - currentModel: model for the language the user is typing in; drives
    ///     `.currentLangCoverage`. Pass `nil` to skip that guard.
    ///   - recentlyUndone: regions the user has undone, matched
    ///     case-insensitively and ignoring surrounding whitespace. Both sides
    ///     are trimmed: what is recorded is a `Fix.replacedText`, which carries
    ///     the separator the user typed after the word, and the region being
    ///     re-evaluated a moment later may or may not carry the same one.
    public static func evaluate(
        _ text: String,
        currentModel: LanguageModel? = nil,
        recentlyUndone: Set<String> = []
    ) -> GuardResult {
        var vetoes: [GuardReason] = []
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)

        if tokens.contains(where: looksLikePath) { vetoes.append(.urlOrPath) }
        if tokens.contains(where: hasAdjacentDigit) { vetoes.append(.digitsAdjacent) }
        if tokens.contains(where: looksLikeIdentifier) { vetoes.append(.identifierCase) }
        if hasConsecutivePunctuation(text) { vetoes.append(.consecutivePunct) }
        if tokens.count == 1, tokens[0].filter(\.isLetter).count <= 5 {
            vetoes.append(.shortSingleToken)
        }
        if let currentModel, currentModel.dictCoverage(text) >= 0.5 {
            vetoes.append(.currentLangCoverage)
        }
        if tokens.contains(where: hasMixedScript) { vetoes.append(.mixedScriptToken) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasUndone = recentlyUndone.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if wasUndone { vetoes.append(.recentlyUndone) }

        return GuardResult(vetoes: vetoes)
    }

    private static func looksLikePath(_ token: String) -> Bool {
        var core = Substring(token)
        while let last = core.last, trailingPunctuation.contains(last) {
            core.removeLast()
        }
        guard core.contains(where: \.isLetter) else { return false }
        if core.contains("://") { return true }
        return core.contains(where: pathCharacters.contains)
    }

    private static func hasAdjacentDigit(_ token: String) -> Bool {
        var previous: Character?
        for character in token {
            if let previous,
               (previous.isLetter && character.isNumber) || (previous.isNumber && character.isLetter)
            {
                return true
            }
            previous = character
        }
        return false
    }

    private static func looksLikeIdentifier(_ token: String) -> Bool {
        if token.contains("_"), token.contains(where: \.isLetter) { return true }
        var previous: Character?
        for character in token {
            if let previous, previous.isLowercase, character.isUppercase { return true }
            previous = character
        }
        return false
    }

    private static func hasConsecutivePunctuation(_ text: String) -> Bool {
        var previousWasPunctuation = false
        for character in text {
            let isPunctuation =
                !character.isLetter && !character.isNumber && !character.isWhitespace
            if isPunctuation && previousWasPunctuation { return true }
            previousWasPunctuation = isPunctuation
        }
        return false
    }

    private static func hasMixedScript(_ token: String) -> Bool {
        var previous: Script?
        for character in token {
            let script = Script(character)
            if let previous, let script, previous != script { return true }
            if script != nil { previous = script }
        }
        return false
    }

    private enum Script {
        case latin
        case arabic

        init?(_ character: Character) {
            guard character.isLetter, let scalar = character.unicodeScalars.first else {
                return nil
            }
            switch scalar.value {
            case 0x0000...0x024F: self = .latin
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: self = .arabic
            default: return nil
            }
        }
    }
}
