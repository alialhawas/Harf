import Foundation

/// One row of the debug window's event table. Values are pre-rendered because
/// the snapshot crosses a queue boundary and the view should do no formatting work.
public struct DebugEvent: Identifiable, Equatable, Hashable, Sendable {
    public let id: UInt64
    public let keycodeText: String
    public let flagsText: String
    public let producedText: String
    public let actionText: String
    public let timestamp: TimeInterval

    public init(
        id: UInt64,
        keycodeText: String,
        flagsText: String,
        producedText: String,
        actionText: String,
        timestamp: TimeInterval
    ) {
        self.id = id
        self.keycodeText = keycodeText
        self.flagsText = flagsText
        self.producedText = producedText
        self.actionText = actionText
        self.timestamp = timestamp
    }
}

/// Immutable view of the buffer, published after every processed input.
public struct BufferSnapshot: Equatable, Hashable, Sendable {
    public var text: String
    public var keyCount: Int
    public var lastReset: ResetReason?
    public var frontmostBundleID: String?
    /// Newest first, capped at `TypingSession.debugEventLimit`.
    public var recentEvents: [DebugEvent]
    /// When the snapshot was taken; event ages are measured against it.
    public var capturedAt: TimeInterval

    public init(
        text: String = "",
        keyCount: Int = 0,
        lastReset: ResetReason? = nil,
        frontmostBundleID: String? = nil,
        recentEvents: [DebugEvent] = [],
        capturedAt: TimeInterval = 0
    ) {
        self.text = text
        self.keyCount = keyCount
        self.lastReset = lastReset
        self.frontmostBundleID = frontmostBundleID
        self.recentEvents = recentEvents
        self.capturedAt = capturedAt
    }
}

/// Everything that can change the session state. Each case carries its own
/// timestamp so the session never reads the clock, which keeps it testable.
public enum SessionInput: Equatable, Hashable, Sendable {
    case key(CapturedKey)
    case mouseDown(at: TimeInterval)
    case appActivated(bundleID: String?, at: TimeInterval)
    case inputSourceChanged(at: TimeInterval)
}

public struct SessionOutcome: Equatable, Sendable {
    public let snapshot: BufferSnapshot
    /// Non-nil only when this input actually cleared the buffer.
    public let performedReset: ResetReason?
    /// The policy decision, for key inputs only.
    public let action: BufferAction?
}

/// The whole typing state machine: buffer plus reset policy plus idle
/// enforcement plus the debug event log.
///
/// Deliberately free of AppKit and of any clock access so it can be driven
/// deterministically from tests. `TypingPipeline` (app target) is a thin shell
/// that owns the serial queue, subscribes to AppKit notifications and turns
/// them into `SessionInput` values.
///
/// Not thread safe: single-threaded use via the owning queue.
public final class TypingSession {
    public static let debugEventLimit = 50

    /// Quiet period after the last keystroke before the buffer is evaluated.
    /// The single source of truth for the trigger; the owner schedules against
    /// it and re-checks with `isEvaluationDue` when its timer fires.
    public static let triggerDelay: TimeInterval = 1.0

    private let buffer = TypedBuffer()
    private var lastKeyTimestamp: TimeInterval?
    private var frontmostBundleID: String?
    private var recentEvents: [DebugEvent] = []
    private var nextEventID: UInt64 = 0

    public init(frontmostBundleID: String? = nil) {
        self.frontmostBundleID = frontmostBundleID
    }

    public var currentFrontmostBundleID: String? { frontmostBundleID }

    /// Timestamp of the last key that touched the buffer, nil after a reset.
    public var lastKeyTime: TimeInterval? { lastKeyTimestamp }

    public var isBufferEmpty: Bool { buffer.isEmpty }

    /// True once the user has been quiet for `triggerDelay`.
    ///
    /// Pure, and inclusive at the boundary: a timer scheduled exactly
    /// `triggerDelay` after the keystroke must find the evaluation due, or the
    /// trigger would need a second round to ever fire.
    public static func isEvaluationDue(lastKeyTimestamp: TimeInterval, now: TimeInterval) -> Bool {
        now - lastKeyTimestamp >= triggerDelay
    }

    /// Runs the detection engine over the current buffer. Nil when there is
    /// nothing buffered to look at.
    ///
    /// No clock, no timer and no mutation: the owner decides *when* to call
    /// this, the session only knows what the keys were.
    ///
    /// The layout the keys were typed under is read off the script of the text
    /// they produced. That is sound because a buffer never spans an input
    /// source change: switching layouts resets it.
    /// What the buffer currently puts on screen.
    public var currentText: String { buffer.currentText }

    /// Seconds of silence after which the buffer is dropped. Settable so the
    /// user can shorten how long anything is held.
    public var idleTimeout: TimeInterval = BufferResetPolicy.idleTimeout

    /// Passes a new limit to the buffer, trimming what is already held.
    public func setBufferCapacity(_ keys: Int) { buffer.setCapacity(keys) }

    public func evaluate(
        detector: Detector,
        policy: AppPolicy,
        aggressiveness: Aggressiveness,
        confidentScore: Double? = nil,
        recentlyUndone: Set<String> = []
    ) -> Detector.Detection? {
        let keys = buffer.keys
        guard !keys.isEmpty else { return nil }
        return detector.detect(
            keys: keys,
            typedLanguage: Detector.scriptLanguage(of: buffer.currentText),
            policy: policy,
            aggressiveness: aggressiveness, confidentScore: confidentScore,
            recentlyUndone: recentlyUndone)
    }

    /// Drops the buffer from outside the input stream.
    ///
    /// Used after Dodoma itself rewrote the text on screen: what is on screen
    /// is no longer what the user typed, so the key history is worthless and
    /// must not be re-evaluated. Clearing `lastKeyTimestamp` also disarms the
    /// owner's trigger, which keys off it.
    @discardableResult
    public func reset(reason: ResetReason, at now: TimeInterval) -> BufferSnapshot {
        clear(reason: reason)
        lastKeyTimestamp = nil
        return snapshot(at: now)
    }

    /// The single place the buffer is cleared, so that a reason which also
    /// requires the debug event log to go cannot be handled in one path and
    /// forgotten in another. See `ResetReason.purgesHistory`.
    private func clear(reason: ResetReason) {
        buffer.reset(reason: reason)
        if reason.purgesHistory { recentEvents.removeAll(keepingCapacity: true) }
    }

    public func snapshot(at now: TimeInterval) -> BufferSnapshot {
        BufferSnapshot(
            text: buffer.currentText,
            keyCount: buffer.count,
            lastReset: buffer.lastResetReason,
            frontmostBundleID: frontmostBundleID,
            recentEvents: recentEvents,
            capturedAt: now)
    }

    @discardableResult
    public func handle(_ input: SessionInput) -> SessionOutcome {
        var performedReset: ResetReason?
        var action: BufferAction?
        let now: TimeInterval

        switch input {
        case .key(let key):
            now = key.timestamp
            let decision = BufferResetPolicy.action(for: key)
            action = decision
            performedReset = apply(decision, for: key)
            record(
                DebugEvent(
                    id: takeEventID(),
                    keycodeText: String(key.keycode),
                    flagsText: key.flags.symbols,
                    producedText: key.producedText,
                    actionText: Self.describe(decision),
                    timestamp: key.timestamp))

        case .mouseDown(let at):
            now = at
            performedReset = resetIfNotEmpty(.mouseDown)
            record(
                DebugEvent(
                    id: takeEventID(),
                    keycodeText: "mouse",
                    flagsText: "",
                    producedText: "",
                    actionText: "reset(mouseDown)",
                    timestamp: at))

        case .appActivated(let bundleID, let at):
            now = at
            let changed = bundleID != frontmostBundleID
            frontmostBundleID = bundleID
            if changed {
                performedReset = resetIfNotEmpty(.appChanged)
            }

        case .inputSourceChanged(let at):
            now = at
            performedReset = resetIfNotEmpty(.inputSourceChanged)
        }

        return SessionOutcome(
            snapshot: snapshot(at: now),
            performedReset: performedReset,
            action: action)
    }

    private func apply(_ decision: BufferAction, for key: CapturedKey) -> ResetReason? {
        switch decision {
        case .append, .backspace:
            var performedReset: ResetReason?
            // The buffer only describes an uninterrupted burst of typing. A long
            // pause means the caret has probably moved somewhere unrelated. This
            // covers backspace as well as append: if it did not, a backspace
            // would refresh `lastKeyTimestamp` and the stale prefix would never
            // be dropped.
            if let last = lastKeyTimestamp,
               BufferResetPolicy.isIdle(
                   lastKeyTimestamp: last, now: key.timestamp, timeout: idleTimeout),
               !buffer.isEmpty {
                clear(reason: .idleTimeout)
                performedReset = .idleTimeout
            }
            lastKeyTimestamp = key.timestamp
            if decision == .append {
                buffer.append(key)
            } else {
                buffer.backspace()
            }
            return performedReset

        case .reset(let reason):
            lastKeyTimestamp = key.timestamp
            // Suppress no-op resets so that holding Return does not churn.
            guard !buffer.isEmpty || buffer.lastResetReason != reason else { return nil }
            clear(reason: reason)
            return reason

        case .ignore:
            return nil
        }
    }

    private func resetIfNotEmpty(_ reason: ResetReason) -> ResetReason? {
        guard !buffer.isEmpty else { return nil }
        clear(reason: reason)
        return reason
    }

    private func record(_ event: DebugEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > Self.debugEventLimit {
            recentEvents.removeLast(recentEvents.count - Self.debugEventLimit)
        }
    }

    private func takeEventID() -> UInt64 {
        nextEventID &+= 1
        return nextEventID
    }

    public static func describe(_ action: BufferAction) -> String {
        switch action {
        case .append: return "append"
        case .backspace: return "backspace"
        case .ignore: return "ignore"
        case .reset(let reason): return "reset(\(reason.rawValue))"
        }
    }
}
