import Foundation

/// Text rewritten as though it had been typed on the other layout.
public struct Flip: Equatable, Sendable {
    public let original: String
    public let flipped: String
    public let sourceLayoutID: String
    public let targetLayoutID: String
    public let sourceLanguage: Language
    public let targetLanguage: Language
    public let capsMode: CapsMode

    public init(
        original: String,
        flipped: String,
        sourceLayoutID: String,
        targetLayoutID: String,
        sourceLanguage: Language,
        targetLanguage: Language,
        capsMode: CapsMode
    ) {
        self.original = original
        self.flipped = flipped
        self.sourceLayoutID = sourceLayoutID
        self.targetLayoutID = targetLayoutID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.capsMode = capsMode
    }
}

/// Rewrites arbitrary text through the other keyboard layout.
///
/// The detector works from captured keystrokes; this works from text alone, so
/// it serves the paths where there are no keystrokes to replay — a selection
/// the user made, a paste, text typed before the app was running. The keys are
/// reconstructed from the layout that could have produced the text, then
/// rendered through the other one.
public enum FlipBuilder {
    /// UTF-16 units. A flip walks the text character by character and calls
    /// `UCKeyTranslate` on each one, so a whole document pasted by accident is
    /// refused rather than stalling the caller.
    public static let maximumLength = 5_000

    /// `text` as it would have read had it been typed on the other layout, or
    /// `nil` when there is nothing to flip.
    ///
    /// - Parameter keyboardType: `LMGetKbdType()` of the machine when omitted.
    ///   A `uchr` table disagrees with itself across ANSI, ISO and JIS, so the
    ///   reconstruction and the re-rendering have to agree on one type.
    public static func flip(
        _ text: String, english: KeyboardLayout, arabic: KeyboardLayout, keyboardType: UInt32? = nil
    ) -> Flip? {
        guard text.utf16.count <= maximumLength else { return nil }
        guard text.contains(where: { $0.isLetter }) else { return nil }

        // Direction comes from the script on screen, never from the current
        // input source: the whole point of a flip is that the text was typed
        // under the wrong one, and by the time the user asks for it the input
        // source may have been switched already.
        let arabicText = TextDisplay.isRightToLeftDominant(text)
        let sourceLayout = arabicText ? arabic : english
        let targetLayout = arabicText ? english : arabic
        let sourceLanguage: Language = arabicText ? .arabic : .english
        let targetLanguage: Language = arabicText ? .english : .arabic
        // The shifted Arabic layer is diacritics, so an English word typed with
        // Caps Lock on — which is how most of this text gets typed — would
        // render as harakat junk instead of letters. Latin has no such layer.
        let capsMode: CapsMode = targetLanguage == .arabic ? .lowercased : .asTyped

        let strokes = InverseKeymap.table(for: sourceLayout, keyboardType: keyboardType)
        var flipped = ""
        var run: [CapturedKey] = []

        for character in text {
            if let stroke = strokes[character] {
                run.append(
                    CapturedKey(
                        keycode: stroke.keycode,
                        flags: stroke.flags,
                        producedText: String(character),
                        keyboardType: keyboardType ?? 0))
                continue
            }
            // A newline, an emoji, an option-layer character, or the لا
            // ligature — which no key types, though ل and ا each do. Nothing
            // was pressed to make it, so it is carried over untouched and the
            // keys around it stay a single run.
            flipped += render(run, layout: targetLayout, capsMode: capsMode)
            run.removeAll(keepingCapacity: true)
            flipped.append(character)
        }
        flipped += render(run, layout: targetLayout, capsMode: capsMode)

        guard !flipped.isEmpty, flipped != text else { return nil }
        return Flip(
            original: text,
            flipped: flipped,
            sourceLayoutID: sourceLayout.sourceID,
            targetLayoutID: targetLayout.sourceID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            capsMode: capsMode)
    }

    /// Renders a whole run in one call so dead-key state threads across it, as
    /// it would while typing: the accent armed by one key belongs to the next.
    private static func render(_ run: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode)
        -> String
    {
        guard !run.isEmpty else { return "" }
        let rendered = LayoutRenderer.renderKeys(run, layout: layout, capsMode: capsMode)
        var out = ""
        for (index, key) in rendered.enumerated() {
            // The target layout has nothing on that key. Dropping it would
            // silently shorten the text, so the character the user actually
            // typed stands in for it.
            out += key.isUnproducible ? run[index].producedText : key.text
        }
        return out
    }
}
