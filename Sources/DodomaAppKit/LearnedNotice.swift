import AppKit
import DodomaCore
import SwiftUI

/// The card shown when a word crosses into the dictionary.
///
/// Learning is the one thing Harf does that outlives the session and changes
/// how it scores everything afterwards, and until now it happened in silence:
/// the only way to find out that `teh` had become a word was to go looking for
/// it. A word crossing the threshold is rare — ten sightings of something the
/// shipped lists do not have — so saying so costs almost no interruption and
/// makes the one durable side effect visible at the moment it happens.
///
/// It cannot collide with a suggestion. Learning only runs when a run was
/// examined and left alone with no region to fix, and a suggestion requires a
/// region, so the two are mutually exclusive by construction.
struct LearnedCard: View {
    let words: [String]
    let rightToLeft: Bool
    let onUndo: () -> Void

    /// Drives the entrance. SwiftUI animates from the pre-appearance value, so
    /// this starts false and is set true once the view is on screen.
    @State private var settled = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .scaleEffect(settled ? 1 : 0.6)
                .opacity(settled ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("Added to your words")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(words.joined(separator: "، "))
                    .font(.system(size: 14, weight: .medium))
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                    .lineLimit(2)
            }

            Button(action: onUndo) {
                Text("Undo")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Forget these again.")
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
