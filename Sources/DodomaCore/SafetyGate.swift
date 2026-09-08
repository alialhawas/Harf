import Foundation

/// What the accessibility layer could tell us about the focused field.
public enum SecureFieldState: String, Equatable, Sendable {
    /// The focused element is a password field.
    case secure
    /// The focused element was read and is not a password field.
    case notSecure
    /// No answer: no accessibility grant, no focused element, an app that does
    /// not implement the attributes, or the check ran out of time.
    case unknown
}

/// The order in which the safety checks are applied, as a pure function.
///
/// The sequencing is the part of the safety layer most likely to be broken by a
/// later edit — a check moved one line down is a check that no longer protects
/// anything — so it lives here, testable, rather than as a ladder of `if`s in
/// the pipeline.
///
/// ### Why the two accessibility checks fail in opposite directions
///
/// Both AX reads share one deadline and can time out. They then answer
/// differently on purpose:
///
/// - The **secure-field check fails open** (`.unknown` → carry on). Password
///   fields that matter almost always *also* enable secure event input, which
///   is checked separately, synchronously and without accessibility — belt one.
///   Failing this check closed would mean that any app slow to answer an AX
///   query is an app Dodoma refuses to work in, and the slow ones are the
///   Electron and web apps the product mostly exists for. The cost of failing
///   open is bounded by belt two.
/// - The **verify-before-delete check fails closed** (`.unknown` /
///   unreadable → downgrade to a suggestion). This is the one guarding the
///   destructive path, and a suggestion is a harmless outcome, so there is no
///   reason to gamble here.
public enum SafetyGate {
    /// Everything knowable before the detector runs.
    public enum Preflight: Equatable, Sendable {
        /// Do not evaluate. `resetBuffer` is non-nil when the buffer has to be
        /// thrown away rather than merely left alone.
        case blocked(reason: String, resetBuffer: ResetReason?)
        /// Evaluate under this policy.
        case proceed(policy: AppPolicy)
    }

    /// What to do with a decision once the accessibility checks have answered.
    public enum Resolution: Equatable, Sendable {
        /// Secure field: drop the buffer, show nothing, apply nothing.
        case drop(reason: String)
        /// Offer the fix. `downgradedFrom` carries the verification reason when
        /// this was an auto-apply that lost its nerve.
        case suggest(downgradedFrom: String?)
        case autoApply
        /// The detector found nothing worth doing.
        case nothing

        /// Whether the evaluation may be shown in the debug window and logged.
        ///
        /// A drop must show *nothing*. The published snapshot carries the
        /// region — the user's own text — and in a secure field that text is a
        /// password, so the whole evaluation is withheld until the focused
        /// field is known not to be one. This is why nothing is published
        /// before the gate resolves.
        public var mayPublishRegion: Bool {
            if case .drop = self { return false }
            return true
        }
    }

    /// What the accessibility layer has to be asked, for a given decision.
    public struct Inspection: Equatable, Sendable {
        /// Always true. The focused field is checked on *every* evaluation with
        /// something in the buffer, not only when the detector produced a fix:
        /// a password rarely reads as wrong-layout text, so gating the check on
        /// a fix existing would mean a password field with no secure event
        /// input is never noticed and the buffer simply accumulates.
        public let checksSecureField: Bool
        /// UTF-16 units of caret text to read back, or nil to skip the read.
        /// Only the auto path pays for it: it is the only path that deletes.
        public let caretTextLength: Int?

        public init(checksSecureField: Bool, caretTextLength: Int?) {
            self.checksSecureField = checksSecureField
            self.caretTextLength = caretTextLength
        }
    }

    /// - Parameter skipVerify: the app is in `axVerifySkip`.
    public static func inspection(for decision: Decision, skipVerify: Bool = false) -> Inspection {
        guard decision.isAuto, !skipVerify, let fix = decision.fix else {
            return Inspection(checksSecureField: true, caretTextLength: nil)
        }
        return Inspection(checksSecureField: true, caretTextLength: fix.replacedText.utf16.count)
    }

    /// Steps (a)–(c) of the evaluation order: global pause, then the frontmost
    /// app's policy, then the global secure-input flag.
    ///
    /// - Parameters:
    ///   - paused: the user's global pause switch.
    ///   - secureInputEnabled: `IsSecureEventInputEnabled()`. System-wide, so it
    ///     is nothing to do with which app is frontmost.
    ///   - policy: the resolved per-app policy for the frontmost app.
    public static func preflight(
        paused: Bool,
        secureInputEnabled: Bool,
        policy: AppPolicy
    ) -> Preflight {
        if paused {
            // The buffer was already dropped when the pause was switched on,
            // and nothing has been buffered since.
            return .blocked(reason: "paused", resetBuffer: nil)
        }
        if policy == .off {
            return .blocked(reason: "app policy is off", resetBuffer: nil)
        }
        if secureInputEnabled {
            return .blocked(reason: "secure input is enabled", resetBuffer: .secureInput)
        }
        return .proceed(policy: policy)
    }

    /// Steps (c)–(d): the accessibility half, applied to a decision the
    /// detector has already produced under the app's policy.
    ///
    /// - Parameters:
    ///   - decision: the detector's verdict. `.suggestOnly` capping already
    ///     happened inside the decision function, which is the single place
    ///     that reads `AppPolicy`.
    ///   - secureField: what the focused element turned out to be.
    ///   - verification: the caret check. Meaningless for anything but an
    ///     auto-apply, and ignored there; pass `.proceed`.
    public static func resolve(
        decision: Decision,
        secureField: SecureFieldState,
        verification: CaretVerification.Verdict = .proceed
    ) -> Resolution {
        if secureField == .secure {
            return .drop(reason: "the focused field is a password field")
        }
        switch decision {
        case .ignore:
            return .nothing
        case .suggest:
            return .suggest(downgradedFrom: nil)
        case .autoApply:
            switch verification {
            case .proceed:
                return .autoApply
            case .downgrade(let reason):
                return .suggest(downgradedFrom: reason)
            }
        }
    }

    /// Whether a command the user issued by name may touch the focused field
    /// at all, given only what that field turned out to be.
    ///
    /// `resolve` asks the same question one step too late for the manual
    /// flip. That command reads the selection *before* it has a fix to resolve
    /// — by posting ⌘C when accessibility is silent — and reading a password
    /// field's selection onto the pasteboard is itself the leak. So the
    /// secure-field rule has to be applied before anything is asked of the
    /// application, not only before anything is deleted from it.
    ///
    /// `.unknown` allows, for the reason given at the top of this file: the
    /// secure-field check fails open, because secure event input is the belt
    /// that catches what accessibility cannot see, and it is checked
    /// separately and synchronously by every explicit path.
    public static func allowsExplicitCommand(secureField: SecureFieldState) -> Bool {
        secureField != .secure
    }
}
