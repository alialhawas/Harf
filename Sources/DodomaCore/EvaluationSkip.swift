/// Why an evaluation did nothing, and the bound on how often it says so.
///
/// The pipeline had seven paths out of the evaluation that returned without a
/// word: the tap not running, a fix in flight, the gate open, the pause, an
/// empty buffer, a detector that declined to answer, and — the one that cost
/// two days — no usable English/Arabic pair. From outside the process every one
/// of them looks exactly like a healthy app that has nothing to correct, so the
/// only way to tell a working install from a wedged one was to restart it.
///
/// The rule these two types encode: every refusal is named, and named once.
/// Naming them is `SkipReason`; once is `SkipLedger`.

/// The refusals, in the order the safety checks apply them.
///
/// Raw values are what reaches os_log and the debug window, so they are the
/// user-facing wording rather than the Swift case name wherever the two differ.
public enum SkipReason: String, CaseIterable, Sendable {
    /// The event tap is not running, which is the app's proxy for "the
    /// permissions have not been granted or have been revoked".
    case captureInactive
    /// A rewrite is being typed into the screen right now.
    case applyInFlight
    /// A decision is waiting on the accessibility round trip.
    case gateOpen
    /// Paused, secure input is up, or the frontmost app is set to Off.
    case suppressed
    /// The trigger fired without a single keystroke behind it.
    case nothingTyped
    /// The one the ledger exists for. Verbatim from `docs/manual-checklist.md`
    /// row 29, which has expected this sentence since before the code could
    /// produce it: the checklist is the contract, not the other way round.
    case noLayoutPair = "no English/Arabic layout pair enabled"
    /// The session declined to evaluate — nothing is held.
    case emptyBuffer
}

/// Remembers the last refusal reported so the next identical one is silent.
///
/// A value rather than a logger wrapper because the thing worth testing is the
/// remembering. The pipeline owns one on its own queue, reports through it, and
/// clears it whenever an evaluation gets far enough to matter — so a refusal
/// that returns after a period of normal work is news again.
///
/// Deliberately one slot deep, not a set: the failure mode being bounded is one
/// reason repeating at the trigger's cadence, and a set would also suppress a
/// refusal alternating with a different one, which is exactly the pattern worth
/// seeing in full.
public struct SkipLedger: Sendable {
    private var lastReported: String?

    public init() {}

    /// Whether this refusal should be logged. True on the first occurrence and
    /// whenever the reason differs from the last one reported.
    public mutating func shouldReport(_ reason: String) -> Bool {
        guard lastReported != reason else { return false }
        lastReported = reason
        return true
    }

    /// Forgets what was last reported, so the next refusal is reported however
    /// recently the same one was.
    public mutating func clear() {
        lastReported = nil
    }
}
