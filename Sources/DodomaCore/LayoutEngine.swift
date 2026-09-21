import Carbon.HIToolbox
import Foundation

/// Enumerates the keyboard layouts the user has enabled and caches the result.
///
/// The enabled-sources list only changes when the user edits it in System
/// Settings, and enumeration copies every `uchr` table, so the list is cached
/// until `invalidate()` is called. The app layer drives invalidation from the
/// `kTISNotifyEnabledKeyboardInputSourcesChanged` distributed notification.
///
/// The selected source is cached alongside the list, because the pair depends
/// on it and it changes far more often than the list does — every ⌃Space,
/// without an enabled-sources notification. The app layer feeds it from the
/// `kTISNotifySelectedKeyboardInputSourceChanged` handler through
/// `noteSelectedLayout(_:)`; both that notification and `invalidate()` arrive
/// on the main thread, which is where Text Input Sources calls belong.
///
/// That feed is the one part of this with no safety net of its own, and it is
/// where a running instance was observed to wedge for two days: the cache was
/// *warm* and the list was right, but the cached selection was wrong, so
/// `cachedPair()` refused every evaluation and nothing ever re-read it. A
/// distributed notification is best-effort — it can be coalesced away while the
/// app is inactive, which for an LSUIElement is always — and a Text Input
/// Sources read taken in the middle of a switch can answer `nil`. Two rules
/// answer that: `noteSelectedLayout(nil)` refuses to overwrite a good
/// selection, and `refreshSelection()` lets a caller that has just been refused
/// ask for the selection to be read again rather than wait for a notification
/// that may never come.
public final class LayoutEngine: @unchecked Sendable {
    /// The enabled list and the source selected when it was taken. Kept as one
    /// value so a reader off the main thread cannot see a list from one moment
    /// against a selection from another.
    private struct Snapshot {
        var layouts: [KeyboardLayout]
        var selectedID: String?
    }

    private let lock = NSLock()
    private var cached: Snapshot?

    public init() {}

    /// Enabled layouts, from cache when warm.
    public func layouts() -> [KeyboardLayout] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached.layouts }
        let fresh = Snapshot(
            layouts: Self.enabledKeyboardLayouts(), selectedID: Self.selectedLayoutID())
        cached = fresh
        return fresh.layouts
    }

    /// Drops the cache; the next `layouts()` call re-enumerates.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Records the input source the user just switched to, so `cachedPair()`
    /// resolves against it without re-enumerating. Main thread.
    ///
    /// A no-op while the cache is cold: `layouts()` reads the selection itself
    /// when it repopulates, so there is nothing to keep in step yet.
    ///
    /// Also a no-op for `nil`. There is always a selected keyboard input
    /// source, so `nil` never means "nothing is selected" — it means
    /// `TISCopyCurrentKeyboardInputSource` did not answer, which is what a read
    /// taken inside the switch it was notified about does. Writing that through
    /// would trade a correct selection for one that resolves to no pair, and
    /// nothing would ever read it again.
    public func noteSelectedLayout(_ sourceID: String?) {
        guard let sourceID else { return }
        lock.lock()
        cached?.selectedID = sourceID
        lock.unlock()
    }

    /// Re-reads the selected input source and reports whether the cache now
    /// resolves to a pair. Main thread — it calls Text Input Sources.
    ///
    /// This is the recovery path for a caller that has just been refused by
    /// `cachedPair()`: it asks the system what is actually selected rather than
    /// trusting what the last notification said, and re-enumerates if the
    /// answer is a source the cached list does not contain. The return value is
    /// what lets the caller decide whether trying again is worth anything — a
    /// user typing with only English enabled is refused for good reasons, and
    /// retrying that on a timer is the loop this replaces.
    @discardableResult
    public func refreshSelection() -> Bool {
        refreshSelection(
            reading: Self.selectedLayoutID, enumerating: Self.enabledKeyboardLayouts)
    }

    /// The seam `refreshSelection()` is: both system reads passed in, so the
    /// decision table above them is testable without a machine that happens to
    /// have Arabic enabled.
    ///
    /// - Parameters:
    ///   - reading: the selected input source ID, as `TISCopyCurrentKeyboard
    ///     InputSource` would answer it — `nil` when the read failed.
    ///   - enumerating: the enabled layouts, called only when the selection
    ///     cannot be resolved against what is already cached.
    @discardableResult
    func refreshSelection(
        reading: () -> String?, enumerating: () -> [KeyboardLayout]
    ) -> Bool {
        // The read happens outside the lock: it is a system call, and holding
        // the lock across it would put `cachedPair()` on the pipeline queue
        // behind Text Input Sources.
        guard let selectedID = reading() else { return false }

        lock.lock()
        let known = cached?.layouts.contains { $0.sourceID == selectedID } ?? false
        lock.unlock()

        let layouts: [KeyboardLayout]
        if known {
            layouts = []
        } else {
            // Either the cache is cold, or the selection is a source the cached
            // list has never heard of. The second is indistinguishable from an
            // input method until the list is re-read — a coalesced
            // enabled-sources notification and a switch to a source with no
            // `uchr` table look identical from here — and it is the one case
            // that heals, so it is worth the enumeration.
            layouts = enumerating()
        }

        lock.lock()
        defer { lock.unlock() }
        if known {
            cached?.selectedID = selectedID
        } else {
            cached = Snapshot(layouts: layouts, selectedID: selectedID)
        }
        guard let cached else { return false }
        return Self.pair(all: cached.layouts, selectedID: cached.selectedID) != nil
    }

    /// The English/Arabic pair Dodoma arbitrates between, or `nil` when the
    /// user is not typing in one of them. Warms the cache when cold.
    public func currentPair() -> (english: KeyboardLayout, arabic: KeyboardLayout)? {
        Self.pair(all: layouts(), selectedID: Self.selectedLayoutID())
    }

    /// The English/Arabic pair from the cache *only when it is warm*.
    ///
    /// Returns `nil` when the cache is cold and never calls
    /// `TISCreateInputSourceList`, so it is safe to call off the main thread —
    /// unlike `currentPair()`, which repopulates. A caller on a background
    /// queue that gets `nil` should skip rather than force an off-main
    /// enumeration: `invalidate()` is always followed by a main-thread
    /// `warmLayoutCache()`, so the cache is warm again by the next quiet period.
    /// (Also `nil` when the cache is warm but the selected source is not one
    /// half of an enabled English/Arabic pair; a cold cache is the only case
    /// that would otherwise enumerate.)
    ///
    /// A warm cache with a wrong selection is the more dangerous of those two
    /// refusals, and the one that actually happened: unlike a cold cache, which
    /// is always followed by a main-thread repopulation, nothing re-reads a
    /// selection that has gone stale. A caller that treats `nil` as permanent
    /// stays wrong until the process restarts, which is why `refreshSelection()`
    /// exists and why the pipeline calls it here rather than simply trying
    /// again later.
    public func cachedPair() -> (english: KeyboardLayout, arabic: KeyboardLayout)? {
        lock.lock()
        let snapshot = cached
        lock.unlock()
        guard let snapshot else { return nil }
        return Self.pair(all: snapshot.layouts, selectedID: snapshot.selectedID)
    }

    /// The pair to arbitrate between, resolved against the source the user is
    /// actually typing in.
    ///
    /// The selected side must be the selected layout itself, not the first
    /// enabled layout of that language: a Dvorak user with ABC also enabled
    /// would otherwise have their keycodes read through ABC, and a fix would
    /// switch them to a layout they never chose. The other side has no such
    /// anchor — nothing says which Arabic layout a user typing English meant —
    /// so it stays the first enabled one, which is the order System Settings
    /// shows and the one ⌃Space cycles into.
    ///
    /// `nil` when the selection cannot be rendered (an input method carries no
    /// `uchr` table, so it is absent from `all`), when it is neither English
    /// nor Arabic, or when the other language is not enabled at all. Callers
    /// treat `nil` as "skip this evaluation".
    static func pair(all: [KeyboardLayout], selectedID: String?)
        -> (english: KeyboardLayout, arabic: KeyboardLayout)?
    {
        guard
            let selectedID,
            let selected = all.first(where: { $0.sourceID == selectedID })
        else { return nil }

        switch selected.language {
        case .english:
            guard let arabic = all.first(where: { $0.language == .arabic }) else { return nil }
            return (selected, arabic)
        case .arabic:
            guard let english = all.first(where: { $0.language == .english }) else { return nil }
            return (english, selected)
        case .other:
            return nil
        }
    }

    /// Every enabled, selectable keyboard input source that carries a `uchr`
    /// table. Sources without one (e.g. input methods) cannot be rendered
    /// through `UCKeyTranslate` and are skipped.
    public static func enabledKeyboardLayouts() -> [KeyboardLayout] {
        let filter =
            [
                kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
            ] as CFDictionary
        guard
            let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as NSArray?
                as? [TISInputSource]
        else { return [] }

        return sources.compactMap(makeLayout(from:))
    }

    /// Input source ID of the layout the user is currently typing in.
    public static func selectedLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    private static func makeLayout(from source: TISInputSource) -> KeyboardLayout? {
        guard
            boolProperty(source, kTISPropertyInputSourceIsEnabled),
            boolProperty(source, kTISPropertyInputSourceIsSelectCapable),
            let sourceID = stringProperty(source, kTISPropertyInputSourceID),
            let uchrData = uchrProperty(source)
        else { return nil }

        return KeyboardLayout(
            sourceID: sourceID,
            localizedName: stringProperty(source, kTISPropertyLocalizedName) ?? sourceID,
            languageCode: languagesProperty(source).first ?? "",
            uchrData: uchrData)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func languagesProperty(_ source: TISInputSource) -> [String] {
        guard
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return (array as NSArray as? [String]) ?? []
    }

    /// Copies the `uchr` bytes: the property is returned unretained and is only
    /// guaranteed to live as long as the input source.
    private static func uchrProperty(_ source: TISInputSource) -> Data? {
        guard
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        let length = CFDataGetLength(cfData)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        CFDataGetBytes(cfData, CFRangeMake(0, length), &bytes)
        return Data(bytes)
    }
}
