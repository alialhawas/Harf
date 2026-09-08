import AppKit
import DodomaCore
import SwiftUI

/// Shows the flip card and takes it away again.
///
/// Thinner than `SuggestionController` for the same reasons `LearnedController`
/// is: nothing here decides anything, nothing swallows a key, and dismissing
/// costs the user nothing. The card is a notification with two buttons on it,
/// so the machinery it needs is a window, a placement and a timer.
///
/// The one thing it decides is nothing. Learn and Not say the same thing to
/// this type — take the card down — and what Learn does to the dictionary
/// belongs to whoever passed `onLearn`. A card that times out is a card nobody
/// answered, which is Not by another name, so the timer runs the same path. The
/// flip itself is already on screen and stays there whichever button is
/// pressed; there is no undo here to get wrong.
///
/// The frame is registered with `CardFrames` for the same reason the
/// learned-word card's is: a click on Learn or Not must not count as input. The
/// ordinary mouse-down path bumps the input serial and ends the undo window, so
/// pressing a button on this card would spend the ⌘⌥Z slot belonging to the
/// very flip the card is asking about, on the way to the handler that was going
/// to use it.
@MainActor
final class FlipController {
    /// The same six seconds as the learned-word card, and for the same reason:
    /// the suggestion card's four interrupt a decision the user is in the middle
    /// of, while this one reports a rewrite already made and is only worth
    /// reading in order to answer it.
    static let autoDismissDelay: TimeInterval = 6.0
    static let fadeDuration: TimeInterval = 0.12

    private let oracle: FocusOracle
    /// Where the card is, so the pipeline can tell a press of Learn or Not from
    /// a click in the application underneath. Without it the click ends the undo
    /// window on its way to the button that was going to use it.
    private let cards: CardFrames
    private var panel: SuggestionPanel?
    private var hosting: NSHostingView<FlipCard>?
    private var dismissTimer: Timer?
    /// Guards against a caret lookup answering after its card was superseded.
    private var generation = 0

    init(oracle: FocusOracle, cards: CardFrames) {
        self.oracle = oracle
        self.cards = cards
    }

    func show(flip: Flip, pid: pid_t?, onLearn: @escaping () -> Void) {
        generation += 1
        let generation = self.generation

        // The flipped text is what is on screen now, so its language is what
        // decides the card's direction and which side of the caret it sits on.
        let rightToLeft = flip.targetLanguage == .arabic
        let card = FlipCard(
            text: flip.flipped,
            rightToLeft: rightToLeft,
            onLearn: { [weak self] in
                onLearn()
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            })
        let size = measure(card)
        let geometry = ScreenGeometry.current()

        oracle.locateCaret(pid: pid, geometry: geometry, rightToLeftText: rightToLeft) {
            [weak self] anchor in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.present(
                    card: card, size: size, anchor: anchor, geometry: geometry,
                    rightToLeft: rightToLeft)
            }
        }
    }

    func dismiss() {
        // First, before the fade: the fade sets `ignoresMouseEvents`, so from
        // this moment a click over the card really does reach the application
        // underneath and really is input.
        cards.hide(.flip)
        generation += 1
        let generation = self.generation
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let panel, panel.isVisible else { return }
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self, self.generation == generation else { return }
                cards.hide(.flip)
                panel.orderOut(nil)
            })
    }

    // MARK: - Placement

    private func present(
        card: FlipCard, size: CGSize, anchor: CaretAnchor, geometry: ScreenGeometry,
        rightToLeft: Bool
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // A fresh hosting view each time, so `onAppear` runs and the card
        // animates in. Reusing one and swapping `rootView` would leave the
        // second card already settled.
        let hosting = NSHostingView(rootView: card)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.hosting = hosting

        let frame = PanelPlacement.compute(
            anchor: anchor.point, panelSize: size,
            screen: geometry.visibleFrame(containing: anchor.point),
            rtl: rightToLeft, quality: anchor.quality)

        panel.setFrame(frame, display: false)
        cards.show(
            .flip,
            displayFrame: ScreenCoordinates.displayRect(
                fromAppKit: frame, primaryScreenMaxY: geometry.primaryMaxY))
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }

        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autoDismissDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        // Common modes, or the card would outstay its welcome for as long as a
        // menu is open or a window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer

        Log.pipeline.debug("flip card shown")
    }

    private func makePanel() -> SuggestionPanel {
        let panel = SuggestionPanel()
        panel.contentView = NSView()
        return panel
    }

    private func measure(_ card: FlipCard) -> CGSize {
        let hosting = NSHostingView(rootView: card)
        return hosting.fittingSize
    }
}
