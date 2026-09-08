import AppKit
import Carbon.HIToolbox
import CoreGraphics
import DodomaCore
import Foundation

/// Why a fix could not be written to the screen.
enum FixError: Error, CustomStringConvertible {
    /// A command chord was in progress; rewriting under it would send the
    /// deletes to whatever the chord is doing.
    case modifierHeld
    /// The frontmost application is no longer the one the decision was made
    /// for. Everything the safety layer says about which apps may be rewritten
    /// is about *that* app, so the sequence must not continue into another one.
    case frontmostChanged
    /// The target input source is no longer enabled.
    case layoutNotFound
    /// CoreGraphics refused to make an event, which in practice means the
    /// Accessibility grant went away mid-sequence.
    case eventCreationFailed
    /// Input arrived after the caret was verified, so the verification no
    /// longer describes the screen the burst is about to delete from.
    case inputSinceVerification

    var description: String {
        switch self {
        case .modifierHeld: return "modifierHeld"
        case .frontmostChanged: return "frontmostChanged"
        case .layoutNotFound: return "layoutNotFound"
        case .eventCreationFailed: return "eventCreationFailed"
        case .inputSinceVerification: return "inputSinceVerification"
        }
    }

    /// True for the failures that say "not now" rather than "not ever": the
    /// same fix is worth attempting again on the next quiet period.
    var isTransient: Bool {
        switch self {
        case .modifierHeld, .inputSinceVerification: return true
        case .frontmostChanged, .layoutNotFound, .eventCreationFailed: return false
        }
    }
}

/// How far the sequence got before it stopped.
///
/// The caller needs this to tell "nothing happened" from "the screen was
/// changed": only the second case invalidates the typed buffer.
struct FixProgress: Equatable {
    var deletedClusters = 0
    var insertedUTF16Units = 0

    /// No event was posted, so the screen is exactly as the user left it.
    var touchedNothing: Bool { deletedClusters == 0 && insertedUTF16Units == 0 }
}

/// A failed apply, together with how much of it had already happened.
struct FixFailure: Error {
    let error: FixError
    let progress: FixProgress
}

/// What asking the frontmost application for its selection produced.
///
/// Three cases, deliberately: "there was nothing selected" and "the question
/// could not be asked" must never collapse into one nil, or a held modifier
/// turns "flip my selection" into "flip whatever was typed last" — a rewrite of
/// a completely different span of the document.
enum CopyResult: Equatable {
    /// The application answered, and this is what it had selected.
    case copied(String)
    /// The application answered and there was nothing selected, or what it put
    /// on the pasteboard was not text a flip can be about.
    case noSelection
    /// The copy was never attempted, or was attempted and cannot be trusted.
    case couldNotTry(FixError)
}

/// The things the typing pipeline asks of the injector.
///
/// A protocol because the alternative, in a test, is posting real backspaces
/// into whatever window happens to be frontmost on the machine running them.
protocol FixApplying: AnyObject {
    func apply(
        _ fix: Fix,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void)

    /// Asks the frontmost application for its selection, by ⌘C, and puts the
    /// user's clipboard back afterwards.
    func copySelection(in bundleID: String?, completion: @escaping (CopyResult) -> Void)

    /// Types `text` over the selection `copySelection` read, then switches the
    /// layout. Nothing is deleted: see `replaceSelection` on the engine.
    func replaceSelection(
        with text: String,
        targetLayoutID: String,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void)
}

/// The destructive half of Dodoma: deletes what the user typed, types the
/// corrected text in its place and switches the keyboard layout.
///
/// Everything runs on one serial queue, off the pipeline queue, because the
/// sequence deliberately sleeps between events — a burst posted with no gaps
/// arrives out of order in several apps, and the receiving app needs run-loop
/// turns to process each keystroke.
///
/// There is no rollback. If the sequence fails halfway the screen is left in
/// whatever state it reached and the failure is logged as a fault with the
/// counts. A silent half-repair would be worse than a visible one, and the
/// undo slot is only armed by a sequence that completed.
final class FixEngine: FixApplying {
    /// Every delay in the sequence, in one place, so per-app tuning later is a
    /// table lookup rather than a hunt through the injector.
    enum Timing {
        /// Between the individual backspace events.
        ///
        /// Each deleted cluster costs two events, so this number is the single
        /// biggest term in how long a fix takes and how long the user's own
        /// typing is dropped for. At 10 ms a 23-character fix spent almost half
        /// a second visibly erasing one letter at a time, which reads as the
        /// machine seizing up mid-sentence. Apps that coalesce key events can
        /// start dropping deletes when this goes too low; 3 ms is the fastest
        /// value that still left every surface in the manual runbook intact.
        static let backspaceInterval: TimeInterval = 0.003
        /// Let the app settle after the burst before text arrives.
        static let postDeleteGap: TimeInterval = 0.015
        /// Between the events of the insertion.
        static let insertInterval: TimeInterval = 0.002
        /// Wait between modifier pre-flight checks.
        static let modifierRetryDelay: TimeInterval = 0.150
        /// Pre-flight retries before giving up (so four checks in total).
        static let modifierRetryLimit = 3
        /// How long to wait for the input source change to be confirmed.
        static let layoutSwitchTimeout: TimeInterval = 0.250
        /// UTF-16 units per injected chunk.
        static let insertChunkLimit = 60
        /// Between the down and the up of an injected chord.
        ///
        /// Longer than the plain-keystroke intervals on purpose: a ⌘C whose up
        /// event arrives in the same run-loop turn as its down is dropped
        /// outright by apps that debounce the modifier, and a dropped copy is
        /// indistinguishable here from an empty selection.
        static let chordInterval: TimeInterval = 0.008
        /// How often the pasteboard's change count is re-read while waiting for
        /// the application to answer the copy.
        static let copyPollInterval: TimeInterval = 0.010
        /// How long the copy is given before the selection is called empty.
        /// Native views answer within a frame; Electron and Java ones take tens
        /// of milliseconds, and this covers the slowest of them.
        static let copyTimeout: TimeInterval = 0.300
        /// One last pause and one last look after the timeout.
        ///
        /// An application that answered a poll interval late looks exactly like
        /// an application with nothing selected, and calling that "nothing
        /// selected" sends the flip to the typed buffer — a rewrite of text the
        /// user was not pointing at.
        static let copyGrace: TimeInterval = 0.100
        /// How long after putting the clipboard back to check that it stayed
        /// put. Electron apps write their copy asynchronously and can land
        /// after ours, leaving the user's clipboard holding the flipped text.
        static let copyRestoreRecheck: TimeInterval = 0.150
        /// Modifier pre-flight retries for the selection flip: nine checks,
        /// about 1.2 s.
        ///
        /// The hotkey that starts a selection flip is itself a chord, so the
        /// user is physically holding ⌘ and friends at the moment the sequence
        /// begins. The 450 ms budget the typed-buffer fix runs on refuses an
        /// ordinary, unhurried key press.
        static let flipModifierRetryLimit = 8
    }

    /// The longest selection a flip will act on, in UTF-16 units.
    ///
    /// Past this it is not a mistyped word or sentence, it is a document, and
    /// retyping a document one chunk at a time is neither fast nor reversible.
    private static let selectionLimitUTF16 = 1000

    /// Written alongside the restored clipboard so clipboard managers skip it.
    ///
    /// Without these, every flip pushes the user's own clipboard back onto the
    /// top of their clipboard history as a fresh entry.
    private static let transientMarkerTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Flavours that mean the selection is not text a flip can be about.
    private static let nonTextPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .URL, .tiff, .png,
    ]

    /// Modifiers that mean the keystroke stream is not plain typing.
    ///
    /// Caps Lock is deliberately absent: typing Arabic through the English
    /// layout with Caps Lock on is the single most common way to produce the
    /// text this app exists to fix, so treating it as a blocker would disable
    /// the product.
    private static let blockingModifiers: CGEventFlags = [
        .maskShift, .maskCommand, .maskControl, .maskAlternate,
    ]

    private let queue = DispatchQueue(label: "com.ali.dodoma.fixengine", qos: .userInitiated)
    private let frontmost: FrontmostAppTracker

    /// - Parameter frontmost: the app's single tracker. Deliberately without a
    ///   default: a second tracker would mean a second activation observer and
    ///   two caches that can disagree about when the switch happened.
    init(frontmost: FrontmostAppTracker) {
        self.frontmost = frontmost
    }

    /// Applies `fix` and reports the outcome on the engine's own queue.
    ///
    /// - Parameters:
    ///   - bundleID: the app the decision was made for. The sequence refuses to
    ///     type into anything else.
    ///   - isStale: asked once, after the modifier pre-flight and before the
    ///     first destructive event. True means the caller's verification of the
    ///     text in front of the caret no longer holds. Called on the engine's
    ///     queue, so it must be safe to call off the caller's own queue.
    ///     Deliberately without a default: a caller that forgot to pass one
    ///     would silently get an unguarded delete burst.
    func apply(
        _ fix: Fix,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void
    ) {
        queue.async {
            completion(self.perform(fix, in: bundleID, isStale: isStale))
        }
    }

    /// Asks the frontmost application what it has selected, by pressing ⌘C for
    /// the user and reading the pasteboard, and puts the pasteboard back.
    ///
    /// Runs entirely on the engine's own queue, like `apply`, and for the same
    /// reason: it sleeps between events and polls the pasteboard for up to
    /// 400 ms. The main-thread invariant `selectInputSource` documents survives
    /// untouched — the only main-thread hops on this path are the `main.sync`
    /// inside `currentBundleID()` and, on the replace side, `selectInputSource`
    /// itself, and nothing on the main thread ever waits on this queue.
    func copySelection(in bundleID: String?, completion: @escaping (CopyResult) -> Void) {
        queue.async {
            completion(self.performCopy(in: bundleID))
        }
    }

    /// Types `text` over the application's current selection and switches the
    /// layout, reporting the outcome on the engine's own queue.
    ///
    /// - Parameters:
    ///   - isStale: asked once, after the modifier pre-flight and before the
    ///     first event, exactly as in `apply`.
    func replaceSelection(
        with text: String,
        targetLayoutID: String,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void
    ) {
        queue.async {
            completion(
                self.performReplace(
                    text, targetLayoutID: targetLayoutID, in: bundleID, isStale: isStale))
        }
    }

    // MARK: - The sequence

    private func perform(
        _ fix: Fix, in bundleID: String?, isStale: () -> Bool
    ) -> Result<FixProgress, FixFailure> {
        var progress = FixProgress()

        if let error = waitForModifiers() {
            return .failure(FixFailure(error: error, progress: progress))
        }
        // The caret was verified *before* the pre-flight above, which waits up
        // to 450 ms for a modifier to come up. Everything the user typed in
        // that window reached the screen but not the verification — the buffer
        // did not even see it, because the pipeline drops input while a fix is
        // in flight — so the span the burst is about to delete is no longer the
        // span that was checked. Nothing has been posted yet, so abandoning
        // here is free.
        if isStale() {
            Log.fix.info("fix abandoned: input arrived after the caret was verified")
            return .failure(FixFailure(error: .inputSinceVerification, progress: progress))
        }
        // The decision was made up to a second ago, and the pre-flight above may
        // have waited half a second more. A ⌘-Tab in that window would send the
        // whole burst into an app that was never allowed to be rewritten.
        guard frontmost.currentBundleID() == bundleID else {
            Log.fix.info("fix abandoned before it started: the frontmost app changed")
            return .failure(FixFailure(error: .frontmostChanged, progress: progress))
        }
        guard let source = makeSource() else {
            Log.fix.fault("could not create the injection event source; nothing was typed")
            return .failure(FixFailure(error: .eventCreationFailed, progress: progress))
        }

        // Re-checked before *every* destructive event, not just before the
        // loop: 23 clusters is nearly half a second of backspaces, and each one
        // that lands in the wrong window deletes somebody's text.
        while progress.deletedClusters < fix.deleteCount {
            guard frontmost.bundleID == bundleID else {
                return .failure(fault(.frontmostChanged, progress: progress, of: fix))
            }
            guard postBackspace(source: source) else {
                return .failure(fault(.eventCreationFailed, progress: progress, of: fix))
            }
            progress.deletedClusters += 1
        }

        Thread.sleep(forTimeInterval: Timing.postDeleteGap)

        // Authoritative check at the checkpoint between the two halves:
        // inserting Arabic into someone else's window would be worse still.
        guard frontmost.currentBundleID() == bundleID else {
            return .failure(fault(.frontmostChanged, progress: progress, of: fix))
        }

        for chunk in TextChunker.chunkUTF16(fix.insertText, max: Timing.insertChunkLimit) {
            guard frontmost.bundleID == bundleID else {
                return .failure(fault(.frontmostChanged, progress: progress, of: fix))
            }
            guard postText(chunk, source: source) else {
                return .failure(fault(.eventCreationFailed, progress: progress, of: fix))
            }
            progress.insertedUTF16Units += chunk.utf16.count
        }

        // Only now: the text was injected as unicode, so it does not depend on
        // the active layout, but the *next* thing the user types does.
        if let error = selectInputSource(fix.targetLayoutID) {
            return .failure(fault(error, progress: progress, of: fix))
        }

        Log.fix.info(
            "fix applied: deleted \(progress.deletedClusters, privacy: .public), inserted \(progress.insertedUTF16Units, privacy: .public) UTF-16 units, layout \(fix.targetLayoutID, privacy: .public)"
        )
        return .success(progress)
    }

    /// Types over whatever the application has selected.
    ///
    /// The same sequence as `perform` with the delete loop taken out, because
    /// typing over a selection replaces it natively — the application does the
    /// deletion, atomically, and `deletedClusters` stays 0. A selection flip
    /// must therefore never be routed through `apply`: its backspace burst
    /// would collapse the selection with the first press and then eat the
    /// characters in front of it with the rest.
    private func performReplace(
        _ text: String, targetLayoutID: String, in bundleID: String?, isStale: () -> Bool
    ) -> Result<FixProgress, FixFailure> {
        var progress = FixProgress()

        if let error = waitForModifiers(limit: Timing.flipModifierRetryLimit) {
            return .failure(FixFailure(error: error, progress: progress))
        }
        // The selection was read before the pre-flight above, which waits over a
        // second for the hotkey chord to come up. A keystroke in that window
        // moved the caret, replaced the selection, or both, and the text about
        // to be typed describes a selection that is gone. Nothing has been
        // posted yet, so abandoning here is free.
        if isStale() {
            Log.fix.info("flip abandoned: input arrived after the selection was read")
            return .failure(FixFailure(error: .inputSinceVerification, progress: progress))
        }
        guard frontmost.currentBundleID() == bundleID else {
            Log.fix.info("flip abandoned before it started: the frontmost app changed")
            return .failure(FixFailure(error: .frontmostChanged, progress: progress))
        }
        guard let source = makeSource() else {
            Log.fix.fault("could not create the injection event source; nothing was typed")
            return .failure(FixFailure(error: .eventCreationFailed, progress: progress))
        }

        let inserting = text.utf16.count
        for chunk in TextChunker.chunkUTF16(text, max: Timing.insertChunkLimit) {
            guard frontmost.bundleID == bundleID else {
                return .failure(
                    fault(.frontmostChanged, progress: progress, deleting: 0, inserting: inserting))
            }
            guard postText(chunk, source: source) else {
                return .failure(
                    fault(
                        .eventCreationFailed, progress: progress, deleting: 0, inserting: inserting)
                )
            }
            progress.insertedUTF16Units += chunk.utf16.count
        }

        // Only now: the text was injected as unicode, so it does not depend on
        // the active layout, but the *next* thing the user types does.
        if let error = selectInputSource(targetLayoutID) {
            return .failure(
                fault(error, progress: progress, deleting: 0, inserting: inserting))
        }

        Log.fix.info(
            "selection flipped: inserted \(progress.insertedUTF16Units, privacy: .public) UTF-16 units, layout \(targetLayoutID, privacy: .public)"
        )
        return .success(progress)
    }

    // MARK: - Reading the selection

    private func performCopy(in bundleID: String?) -> CopyResult {
        if let error = waitForModifiers(limit: Timing.flipModifierRetryLimit) {
            return .couldNotTry(error)
        }
        // Authoritative, not the cache: the wait above can run for over a
        // second, and a ⌘-Tab in that window would put the next app's selection
        // on the pasteboard and offer to rewrite it in this one.
        guard frontmost.currentBundleID() == bundleID else {
            Log.fix.info("selection copy abandoned: the frontmost app changed")
            return .couldNotTry(.frontmostChanged)
        }
        guard let source = makeSource() else {
            Log.fix.fault("could not create the injection event source; no copy was attempted")
            return .couldNotTry(.eventCreationFailed)
        }

        let board = NSPasteboard.general
        let before = board.changeCount
        let saved = snapshot(board)

        guard postChord(Keycode.c, flags: .maskCommand, source: source) else {
            Log.fix.fault("could not create the copy chord; the pasteboard was not touched")
            return .couldNotTry(.eventCreationFailed)
        }

        guard waitForPasteboard(board, toChangeFrom: before) else {
            // The application never wrote anything, so there is nothing to put
            // back: the user's clipboard is exactly as they left it.
            return .noSelection
        }

        guard let text = selectionText(on: board) else {
            // The pasteboard moved even though the answer is unusable, so it
            // still has to be restored.
            restore(saved, to: board)
            return .noSelection
        }
        restore(saved, to: board)
        return .copied(text)
    }

    /// True once the application has answered the copy.
    private func waitForPasteboard(_ board: NSPasteboard, toChangeFrom before: Int) -> Bool {
        var waited: TimeInterval = 0
        while waited < Timing.copyTimeout {
            Thread.sleep(forTimeInterval: Timing.copyPollInterval)
            waited += Timing.copyPollInterval
            if board.changeCount != before { return true }
        }
        Thread.sleep(forTimeInterval: Timing.copyGrace)
        return board.changeCount != before
    }

    /// The selection, if what the application wrote is text worth flipping.
    ///
    /// Everything rejected here is rejected because flipping it would be
    /// destructive rather than merely useless: a copied file, image or link
    /// retyped as Arabic letters replaces the thing the user selected with
    /// nonsense.
    private func selectionText(on board: NSPasteboard) -> String? {
        // More than one item is a multiple selection — a row of files, a set of
        // cells — and a single run of typed text cannot stand in for it.
        guard let items = board.pasteboardItems, items.count == 1 else { return nil }
        guard items[0].types.allSatisfy({ !Self.nonTextPasteboardTypes.contains($0) }) else {
            return nil
        }
        guard let text = board.string(forType: .string) else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.utf16.count <= Self.selectionLimitUTF16 else { return nil }
        return text
    }

    // MARK: - Borrowing the pasteboard

    /// The pasteboard's current contents, detached from the pasteboard.
    ///
    /// The limitation this accepts: promised and lazily-provided flavours — a
    /// file promise, RTF a word processor only renders when something asks for
    /// it — have no data yet and do not survive the round trip. Plain and rich
    /// text, which is all a text selection ever puts here, do.
    private func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map(Self.detachedCopy)
    }

    private static func detachedCopy(of original: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in original.types {
            if let data = original.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }

    /// Puts the user's clipboard back, and checks that it stayed back.
    private func restore(_ saved: [NSPasteboardItem], to board: NSPasteboard) {
        let ours = write(saved, to: board)
        Thread.sleep(forTimeInterval: Timing.copyRestoreRecheck)
        // Electron apps answer ⌘C asynchronously and can write well after the
        // change count first moved. One that lands here leaves the user's
        // clipboard holding the text Harf was only supposed to read.
        if board.changeCount != ours { _ = write(saved, to: board) }
    }

    /// - Returns: the change count the write produced.
    private func write(_ saved: [NSPasteboardItem], to board: NSPasteboard) -> Int {
        board.clearContents()
        board.writeObjects(items(restoring: saved))
        return board.changeCount
    }

    /// Fresh items for one write.
    ///
    /// An `NSPasteboardItem` belongs to the pasteboard it was written to and
    /// cannot be written a second time, and the restore runs twice whenever a
    /// late writer beats us to the board.
    private func items(restoring saved: [NSPasteboardItem]) -> [NSPasteboardItem] {
        var items = saved.map(Self.detachedCopy)
        // The markers need a carrier even when the clipboard was empty, so that
        // clearing it back to empty is still announced as ours.
        if items.isEmpty { items = [NSPasteboardItem()] }
        for type in Self.transientMarkerTypes { items[0].setData(Data(), forType: type) }
        return items
    }

    /// A half-applied edit is exactly what the log has to make visible.
    private func fault(_ error: FixError, progress: FixProgress, of fix: Fix) -> FixFailure {
        fault(
            error, progress: progress,
            deleting: fix.deleteCount, inserting: fix.insertText.utf16.count)
    }

    private func fault(
        _ error: FixError, progress: FixProgress, deleting: Int, inserting: Int
    ) -> FixFailure {
        Log.fix.fault(
            "fix failed (\(error.description, privacy: .public)) after deleting \(progress.deletedClusters, privacy: .public)/\(deleting, privacy: .public) and inserting \(progress.insertedUTF16Units, privacy: .public)/\(inserting, privacy: .public) UTF-16 units; no rollback attempted"
        )
        return FixFailure(error: error, progress: progress)
    }

    // MARK: - Pre-flight

    /// Holding a modifier turns our backspaces into something else entirely
    /// (⌥⌫ deletes a word, ⌘⌫ a line), so the sequence waits for a clear
    /// keyboard and abandons the fix rather than starting one it cannot finish.
    ///
    /// - Parameter limit: retries before giving up. The selection flip raises
    ///   it, because its own hotkey is a chord the user is still holding.
    private func waitForModifiers(limit: Int = Timing.modifierRetryLimit) -> FixError? {
        for attempt in 0...limit {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: Self.blockingModifiers) { return nil }
            if attempt < limit {
                Thread.sleep(forTimeInterval: Timing.modifierRetryDelay)
            }
        }
        Log.fix.info("fix abandoned: a modifier stayed down through every retry")
        return .modifierHeld
    }

    // MARK: - Event injection

    /// Events carry `EventTapController.injectedEventMarker` so our own tap
    /// discards them instead of feeding the replacement back into the buffer.
    private func makeSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        source.userData = EventTapController.injectedEventMarker
        return source
    }

    /// A key event whose modifier state is stated rather than inherited.
    ///
    /// The event source inherits whatever modifiers are physically down, and a
    /// stale Caps Lock or Shift bit would change what the receiving app makes
    /// of the keystroke. `postText` and `postBackspace` therefore pass no flags
    /// and must keep passing none — a backspace that arrives with ⌥ set deletes
    /// a whole word. Only `postChord` sets any. The flags are written here, at
    /// creation, so that nothing touches the event after its unicode payload is
    /// set.
    private func makeKeyEvent(
        source: CGEventSource, keycode: CGKeyCode, down: Bool, flags: CGEventFlags = []
    ) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down)
        else { return nil }
        event.flags = flags
        return event
    }

    /// A modified key press: down then up, both carrying `flags`.
    ///
    /// The up event carries `.maskCommand` as well, not just the down: an app
    /// that sees ⌘ come up before C does reads the pair as a bare C and types a
    /// letter into the document instead of copying. Posted from the marked
    /// source, so `EventTapController.isSelfInjected` passes it through to the
    /// app untouched rather than buffering it as something the user typed.
    private func postChord(_ keycode: UInt16, flags: CGEventFlags, source: CGEventSource) -> Bool {
        let key = CGKeyCode(keycode)
        guard
            let down = makeKeyEvent(source: source, keycode: key, down: true, flags: flags),
            let up = makeKeyEvent(source: source, keycode: key, down: false, flags: flags)
        else { return false }

        post(down, then: Timing.chordInterval)
        post(up, then: Timing.chordInterval)
        return true
    }

    private func postBackspace(source: CGEventSource) -> Bool {
        let keycode = CGKeyCode(Keycode.delete)
        guard
            let down = makeKeyEvent(source: source, keycode: keycode, down: true),
            let up = makeKeyEvent(source: source, keycode: keycode, down: false)
        else { return false }

        post(down, then: Timing.backspaceInterval)
        post(up, then: Timing.backspaceInterval)
        return true
    }

    private func postText(_ chunk: String, source: CGEventSource) -> Bool {
        var units = Array(chunk.utf16)
        guard
            let down = makeKeyEvent(source: source, keycode: 0, down: true),
            let up = makeKeyEvent(source: source, keycode: 0, down: false)
        else { return false }

        // Last write before posting. Setting any other field afterwards is
        // undocumented territory and has been observed to drop the payload.
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

        post(down, then: Timing.insertInterval)
        post(up, then: Timing.insertInterval)
        return true
    }

    private func post(_ event: CGEvent, then pause: TimeInterval) {
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: pause)
    }

    // MARK: - Input source

    /// Switches the keyboard layout and waits for the confirmation
    /// notification, so the caller can rely on the next keystroke being typed
    /// in the language the text is now in. Returns nil on success.
    private func selectInputSource(_ sourceID: String) -> FixError? {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        let confirmed = DispatchSemaphore(value: 0)

        var observer: NSObjectProtocol?
        var status: OSStatus = noErr
        var found = false

        // TIS is documented as main-thread only. Blocking this queue on the
        // main thread is safe: nothing on the main thread ever waits on the
        // fix engine.
        DispatchQueue.main.sync {
            guard let source = Self.inputSource(withID: sourceID) else { return }
            found = true
            observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                confirmed.signal()
            }
            status = TISSelectInputSource(source)
        }
        defer {
            if let observer {
                DispatchQueue.main.async { center.removeObserver(observer) }
            }
        }

        guard found else {
            Log.fix.error("input source \(sourceID, privacy: .public) is not enabled")
            return .layoutNotFound
        }
        guard status == noErr else {
            Log.fix.error(
                "TISSelectInputSource(\(sourceID, privacy: .public)) failed with \(status, privacy: .public)"
            )
            return .layoutNotFound
        }
        if confirmed.wait(timeout: .now() + Timing.layoutSwitchTimeout) == .timedOut {
            // The selection call succeeded, so the switch is almost certainly
            // in flight; the notification is a courtesy, not a precondition.
            Log.fix.debug("input source switch was not confirmed within the timeout")
        }
        return nil
    }

    private static func inputSource(withID sourceID: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard
            let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as NSArray?
                as? [TISInputSource]
        else { return nil }
        return sources.first
    }
}
