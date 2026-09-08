import AppKit
import DodomaCore
import SwiftUI

/// The card shown after a flip, offering to learn the words it produced.
///
/// A flip is the one rewrite the user asked for by name, so the question it
/// asks is not "was this right" — the user already said it was — but "should
/// Harf learn from it". The words now on screen are, by construction, words the
/// user meant to type in the language they are now in, which is exactly the
/// evidence the dictionary is built from; the flip is just the rare moment
/// where that evidence arrives with a confirmation attached.
///
/// Learning is offered, never assumed. A manual entry changes every future
/// score, and a card that times out on screen is not an argument for a durable
/// change to how Harf reads the rest of the session — so an ignored card leaves
/// the dictionary exactly as it was.
///
/// It cannot collide with a suggestion: a flip dismisses any suggestion before
/// it starts, so the two are never on screen together.
struct FlipCard: View {
    /// The flipped text now on screen.
    let text: String
    /// True when the flipped text is Arabic.
    let rightToLeft: Bool
    let onLearn: () -> Void
    let onDismiss: () -> Void

    /// Drives the entrance. SwiftUI animates from the pre-appearance value, so
    /// this starts false and is set true once the view is on screen.
    @State private var settled = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .scaleEffect(settled ? 1 : 0.6)
                .opacity(settled ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("Flipped")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                    .lineLimit(2)
            }

            Button(action: onLearn) {
                Text("Learn")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Remember these words in the language they are now in, and stop counting the originals.")

            Button(action: onDismiss) {
                Text("Not")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Leave the dictionary alone. The flip stays either way.")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5))
        )
        // Rise rather than grow: the card appears beside text the user is still
        // typing into, and anything that changes size next to a caret reads as
        // the text itself moving.
        .offset(y: settled ? 0 : 6)
        .opacity(settled ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { settled = true }
        }
    }
}
