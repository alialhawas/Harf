import CoreGraphics
import Foundation

/// Which of Harf's own cards a rectangle belongs to.
enum CardKind: String {
    case flip
    case learned
}

/// The rectangles of the cards whose clicks are not input.
///
/// A click on one of Harf's own cards must not be routed through the ordinary
/// mouse-down path, because that path destroys the very thing the card's
/// buttons act on: `process` bumps the input serial and `FixHistory`'s
/// `endsUndoWindow` throws the undo slot away. Pressing Undo on the learned-word
/// card would therefore cost the user their ⌘⌥Z before the button's own handler
/// ever ran — the click invalidates what the click was for.
///
/// So the pipeline asks this registry first and returns without treating the
/// click as input at all. The card's own SwiftUI button handler still receives
/// it through the panel, which is the only place that click belongs.
///
/// The suggestion card deliberately stays on `SuggestionState` instead: its
/// clicks are not merely ignored, they have to route into `acceptSuggestion`,
/// and that needs the panel frame paired atomically with the visibility flag
/// the event tap also reads.
///
/// Shaped like `SuggestionState` for the same reason: written from the main
/// thread by the panel controllers, read from the pipeline queue on every
/// mouse-down, so one uncontended lock and no allocation on the read.
final class CardFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CardKind: CGRect] = [:]

    /// - Parameter displayFrame: the card's frame in display coordinates —
    ///   top-left origin — because that is what `CGEvent.location` reports and
    ///   the conversion belongs on the main thread.
    func show(_ kind: CardKind, displayFrame: CGRect) {
        lock.lock()
        frames[kind] = displayFrame
        lock.unlock()
    }

    /// The rectangle goes with the card. One left behind would swallow ordinary
    /// clicks in whatever is underneath it once the card is gone.
    func hide(_ kind: CardKind) {
        lock.lock()
        frames[kind] = nil
        lock.unlock()
    }

    /// `location` in display coordinates, as `CGEvent` reports it.
    func contains(_ location: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.values.contains { $0.contains(location) }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty
    }
}
