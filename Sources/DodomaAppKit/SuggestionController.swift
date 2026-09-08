import AppKit
import DodomaCore
import SwiftUI

/// Owns the suggestion panel's lifetime and nothing else.
///
/// Deliberately not the owner of the *decision*. Whether an acceptance is still
/// valid, whether the same text may be offered again and what happens after an
/// accept are all pipeline questions, decided on the pipeline queue against the
/// input serial. This type shows a card, takes it away again, and publishes the
/// one event the pipeline cannot see for itself: the card timing out.
///
/// Main thread only, throughout. The single exception is the accessibility
/// lookup, which is handed to `FocusOracle` and answered back onto the main
/// thread.
final class SuggestionController {
    /// How long the card stays up with nothing happening.
    static let autoDismissDelay: TimeInterval = 4.0
    /// Fade in and out. Long enough not to pop, short enough that accepting
    /// immediately is not waiting on an animation.
    static let fadeDuration: TimeInterval = 0.12

    /// Called on the main thread when the card timed out. The pipeline turns it
    /// into a dismissal, which is what records the suppression entry.
    var onTimeout: (() -> Void)?

    private let state: SuggestionState
    private let oracle: FocusOracle

    private var panel: SuggestionPanel?
    private var hosting: NSHostingView<SuggestionCard>?
    private var dismissTimer: Timer?

    /// Bumped by every show and every dismissal, so a caret lookup that comes
    /// back after its suggestion has already been superseded — or taken down —
    /// cannot put a stale card on screen.
    private var generation = 0

    /// - Parameter oracle: the pipeline's own oracle, not a second one. The
    ///   caret lookup has to queue behind the security check rather than race
    ///   it, and one serial queue is what guarantees that.
    init(state: SuggestionState, oracle: FocusOracle) {
        self.state = state
        self.oracle = oracle
    }

    // MARK: - Showing

    /// Replaces whatever is on screen with a card for `fix`. Main thread only.
    func show(fix: Fix, pid: pid_t?) {
        generation += 1
        let generation = self.generation

        let clickOnly = !state.consumesKeys
        let card = SuggestionCard(
            insertText: fix.insertText,
            replacedText: fix.replacedText,
            rightToLeft: TextDisplay.isRightToLeftDominant(fix.insertText),
            clickOnly: clickOnly)
        let size = measure(card)
        let geometry = ScreenGeometry.current()
        // What is on screen right now is the text being replaced, and its
        // direction is what decides which end of a glyph box the caret is at.
        let screenTextIsRTL = TextDisplay.isRightToLeftDominant(fix.replacedText)

        oracle.locateCaret(pid: pid, geometry: geometry, rightToLeftText: screenTextIsRTL) {
            [weak self] anchor in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.present(
                    card: card, size: size, anchor: anchor, geometry: geometry,
                    rightToLeft: TextDisplay.isRightToLeftDominant(fix.insertText))
            }
        }
    }

    /// Takes the card down. Idempotent, and safe to call when nothing is up.
    /// Main thread only.
    func dismiss() {
        generation += 1
        let generation = self.generation
        dismissTimer?.invalidate()
        dismissTimer = nil
        state.hide()

        guard let panel, panel.isVisible else { return }
        // On the way out the card is no longer clickable, so the click that
        // lands on it during the fade reaches the application underneath
        // instead of being eaten by a window that is already gone as far as
        // everything else is concerned.
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                // A new card may have been raised during the fade, reusing this
                // same window. The generation says whether that happened;
                // reading the alpha back would not, because the new card starts
                // its own fade from zero.
                guard let self, self.generation == generation else { return }
                panel.orderOut(nil)
            })
    }

    // MARK: - Placement

    private func present(
        card: SuggestionCard, size: CGSize, anchor: CaretAnchor, geometry: ScreenGeometry,
        rightToLeft: Bool
    ) {
        let generation = self.generation
        let panel = self.panel ?? makePanel()
        self.panel = panel

        hosting?.rootView = card
        let frame = PanelPlacement.compute(
            anchor: anchor.point,
            panelSize: size,
            screen: geometry.visibleFrame(containing: anchor.point),
            rtl: rightToLeft,
            quality: anchor.quality)

        panel.setFrame(frame, display: false)
        // The window is transparent, so its shadow is computed from the card's
        // alpha mask and has to be recomputed whenever the card changes size.
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        // Never `makeKeyAndOrderFront`: the application the user is typing into
        // has to keep its key window, and an accessory app ordering a window in
        // regardless is the only way to raise one without disturbing that.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }

        // One hop later than the window itself, and only if the offer is still
        // standing by then.
        //
        // This is the flag the tap thread reads to decide whether to swallow
        // Tab and Escape, so setting it commits the panel's keys to a card the
        // pipeline may already have withdrawn: the withdrawal arrives here as a
        // `dismiss()` hopped onto this queue, and the caret lookup that got us
        // here was queued ahead of it. Deferring by one hop puts the two back in
        // the order the pipeline decided them in — the dismissal bumps the
        // generation, and this is skipped. Nothing is lost by the delay: the
        // card is still fading in, and the keys are the pipeline's to answer
        // only once it has an offer to answer them with.
        let displayFrame = ScreenCoordinates.displayRect(
            fromAppKit: frame, primaryScreenMaxY: geometry.primaryMaxY)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.state.show(displayFrame: displayFrame)
        }

        Log.pipeline.debug(
            "suggestion panel shown, anchor quality \(anchor.quality.rawValue, privacy: .public)")

        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autoDismissDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dismiss()
            self.onTimeout?()
        }
        // Common modes, or the card would outstay its welcome for as long as a
        // menu is open or a window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func makePanel() -> SuggestionPanel {
        let panel = SuggestionPanel()
        let hosting = NSHostingView(
            rootView: SuggestionCard(
                insertText: "", replacedText: "", rightToLeft: false, clickOnly: false))
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    /// The card's natural size, measured off-screen.
    ///
    /// A throwaway hosting view rather than the live one: measuring the live one
    /// would need the new content installed first, and installing it while the
    /// old card is still fading out makes the old card change under the user.
    ///
    /// Measured twice on purpose. `fittingSize` answers for an unconstrained
    /// line, which decides the width but reports the height of a long proposal
    /// as one line when the card is about to wrap it into three. The second
    /// pass asks at the width the card will actually get.
    private func measure(_ card: SuggestionCard) -> CGSize {
        let natural = NSHostingView(rootView: card).fittingSize
        let width = min(max(natural.width, 140), SuggestionCard.maximumWidth)
        let wrapped = NSHostingView(rootView: card.frame(width: width)).fittingSize
        return CGSize(width: width, height: max(wrapped.height, 40))
    }
}
