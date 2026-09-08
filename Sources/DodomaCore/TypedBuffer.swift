import Foundation

/// Why the typed buffer was cleared. Recorded so the debug window (and later the
/// fix engine) can explain why a candidate word disappeared.
public enum ResetReason: String, Equatable, Hashable, Sendable, CaseIterable {
    case enterKey
    case tabKey
    case escapeKey
    case arrowNav
    case modifierChord
    case mouseDown
    case appChanged
    case focusChanged
    case inputSourceChanged
    case idleTimeout
    case manual
    case secureInput
    case overflow

    /// Whether clearing the buffer must also throw away everything else that
    /// holds the user's text: the debug event log, and the undo slot.
    ///
    /// The log keeps the produced text of the last fifty keystrokes and
    /// deliberately survives an ordinary reset — watching what happened either
    /// side of a reset is most of what the debug window is for. The undo slot
    /// survives one for the same kind of reason: an ordinary reset is the user
    /// carrying on, not a reason to withdraw the escape hatch.
    ///
    /// `secureInput` is the one reason that says those keystrokes were never
    /// ours to keep. It is set when the focused field turns out to be a
    /// password field, and by then the characters are already in the log; the
    /// clear has to be retroactive or the drop protects nothing. Keyed off the
    /// reason rather than left to each caller so that no future reset path can
    /// forget it.
    public var purgesHistory: Bool {
        switch self {
        case .secureInput:
            return true
        case .enterKey, .tabKey, .escapeKey, .arrowNav, .modifierChord, .mouseDown, .appChanged,
             .focusChanged, .inputSourceChanged, .idleTimeout, .manual, .overflow:
            return false
        }
    }
}

/// Ordered record of the keys the user has typed since the last reset.
///
/// Plain class, not thread safe: it is owned by a single serial queue (the
/// typing pipeline). It emits no notifications; the owner observes it directly.
public final class TypedBuffer {
    /// Maximum retained keys. Appending past the cap drops from the head.
    /// How many keystrokes the buffer will hold at once.
    ///
    /// This is the only number that says how much of your typing exists in
    /// memory at any moment, so it is a privacy control before it is a
    /// performance one. The default holds roughly a long sentence; lowering it
    /// shortens the window in which anything is retained, at the cost of not
    /// being able to reach back as far when a mistake started early in a line.
    public static let defaultCapacity = 200
    public static let minimumCapacity = 20
    public static let maximumCapacity = 500

    /// The limit this buffer is running with.
    public private(set) var capacity: Int = defaultCapacity

    /// Applies a new limit, trimming immediately rather than at the next
    /// keystroke: lowering the setting has to take effect on what is already
    /// held, or the control would be a promise about the future only.
    public func setCapacity(_ requested: Int) {
        capacity = min(max(requested, Self.minimumCapacity), Self.maximumCapacity)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    private var storage: [CapturedKey] = []

    public private(set) var lastResetReason: ResetReason?

    public init() {
        storage.reserveCapacity(Self.defaultCapacity)
    }

    public var keys: [CapturedKey] { storage }

    public var count: Int { storage.count }

    public var isEmpty: Bool { storage.isEmpty }

    /// Concatenation of every retained key's produced text.
    public var currentText: String {
        storage.map(\.producedText).joined()
    }

    public var lastKey: CapturedKey? { storage.last }

    public func append(_ key: CapturedKey) {
        storage.append(key)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Removes the most recent key. No-op when the buffer is already empty.
    public func backspace() {
        guard !storage.isEmpty else { return }
        storage.removeLast()
    }

    public func reset(reason: ResetReason) {
        storage.removeAll(keepingCapacity: true)
        lastResetReason = reason
    }
}
