import XCTest

@testable import DodomaCore

/// The evaluation order of the safety layer, which is the part most easily
/// broken by a later edit.
final class SafetyGateTests: XCTestCase {
    private func fix(_ replaced: String = "hgsghl") -> Fix {
        Fix(
            deleteCount: replaced.count,
            insertText: "السلام",
            targetLayoutID: "com.apple.keylayout.Arabic",
            sourceLayoutID: "com.apple.keylayout.ABC",
            replacedText: replaced,
            capsMode: .asTyped)
    }

    // MARK: - Preflight

    func testPausedBlocksEverythingAndKeepsTheBuffer() {
        // Nothing is buffered while the pause is on, and the buffer was already
        // dropped when it was switched on, so there is nothing left to reset.
        XCTAssertEqual(
            SafetyGate.preflight(paused: true, secureInputEnabled: false, policy: .normal),
            .blocked(reason: "paused", resetBuffer: nil))
    }

    func testPolicyOffBlocks() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: false, policy: .off),
            .blocked(reason: "app policy is off", resetBuffer: nil))
    }

    func testSecureInputBlocksAndDropsTheBuffer() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: true, policy: .normal),
            .blocked(reason: "secure input is enabled", resetBuffer: .secureInput))
    }

    func testNormalAndSuggestOnlyBothProceed() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: false, policy: .normal),
            .proceed(policy: .normal))
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: false, policy: .suggestOnly),
            .proceed(policy: .suggestOnly))
    }

    /// The order is pause, then policy, then secure input — asserted by making
    /// each earlier check win against every later one.
    func testTheOrderOfTheChecksIsFixed() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: true, secureInputEnabled: true, policy: .off),
            .blocked(reason: "paused", resetBuffer: nil))
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: true, policy: .off),
            .blocked(reason: "app policy is off", resetBuffer: nil))
    }

    // MARK: - Resolution

    func testSecureFieldDropsWhateverTheDecisionWas() {
        for decision in [Decision.ignore(reason: "x"), .suggest(fix()), .autoApply(fix())] {
            XCTAssertEqual(
                SafetyGate.resolve(decision: decision, secureField: .secure),
                .drop(reason: "the focused field is a password field"),
                "\(decision)")
        }
    }

    func testAutoApplyProceedsOnlyWhenTheCaretVerifies() {
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .notSecure, verification: .proceed),
            .autoApply)
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .notSecure,
                verification: .downgrade(reason: "no accessibility text at the caret")),
            .suggest(downgradedFrom: "no accessibility text at the caret"))
    }

    /// The rationale that the whole design hangs on: an unanswered secure-field
    /// check carries on, an unanswered caret check does not delete.
    func testUnknownFailsOpenForSecurityAndClosedForVerification() {
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .unknown, verification: .proceed),
            .autoApply,
            "an app that will not answer is not thereby a password field")
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .unknown,
                verification: .downgrade(reason: "no accessibility text at the caret")),
            .suggest(downgradedFrom: "no accessibility text at the caret"),
            "but it does not get to have text deleted unverified")
    }

    func testSuggestionsAreNeverVerified() {
        // The caret check only guards deletion, so a suggestion passes through
        // whatever it would have said.
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .suggest(fix()), secureField: .notSecure,
                verification: .downgrade(reason: "irrelevant")),
            .suggest(downgradedFrom: nil))
    }

    func testIgnoreDoesNothing() {
        XCTAssertEqual(
            SafetyGate.resolve(decision: .ignore(reason: "no gate met"), secureField: .notSecure),
            .nothing)
    }

    // MARK: - What has to be asked of the accessibility API

    /// The widening that makes the secure-field check useful: it runs on every
    /// evaluation with something in the buffer, not only on the ones that
    /// produced a fix. A password is not wrong-layout text and so produces no
    /// fix — if the check only ran when a fix existed, a password field that
    /// does not raise the secure event input flag would never be noticed and
    /// the buffer would simply keep growing.
    func testTheSecureFieldIsCheckedEvenWhenThereIsNoFix() {
        let inspection = SafetyGate.inspection(for: .ignore(reason: "no gate met"))
        XCTAssertTrue(inspection.checksSecureField)
        XCTAssertNil(inspection.caretTextLength, "nothing is deleted, so nothing is read")
    }

    func testOnlyTheAutoPathReadsTheCaretText() {
        let candidate = fix("hgsghl")

        XCTAssertEqual(
            SafetyGate.inspection(for: .autoApply(candidate)),
            SafetyGate.Inspection(checksSecureField: true, caretTextLength: 6))
        XCTAssertEqual(
            SafetyGate.inspection(for: .suggest(candidate)),
            SafetyGate.Inspection(checksSecureField: true, caretTextLength: nil),
            "a suggestion deletes nothing, so it never pays for the read")
    }

    func testCaretLengthIsCountedInUTF16Units() {
        // Six Arabic letters and a space: seven UTF-16 units, and the
        // accessibility range that will be asked for is counted the same way.
        let candidate = fix("السلام ")
        XCTAssertEqual(SafetyGate.inspection(for: .autoApply(candidate)).caretTextLength, 7)
    }

    func testAXVerifySkipSuppressesTheCaretReadButNotTheSecureCheck() {
        let inspection = SafetyGate.inspection(for: .autoApply(fix()), skipVerify: true)
        XCTAssertTrue(inspection.checksSecureField, "opting out of verification is not opting out "
            + "of password detection")
        XCTAssertNil(inspection.caretTextLength)
    }

    // MARK: - What may be shown

    /// The evaluation carries the region — the user's own text — so none of it
    /// reaches the debug window or the log until the focused field is known
    /// not to be a password field. §6(c): drop the buffer, show nothing.
    func testADropPublishesNothingAboutTheRegion() {
        XCTAssertFalse(SafetyGate.Resolution.drop(reason: "x").mayPublishRegion)
        XCTAssertTrue(SafetyGate.Resolution.nothing.mayPublishRegion)
        XCTAssertTrue(SafetyGate.Resolution.autoApply.mayPublishRegion)
        XCTAssertTrue(SafetyGate.Resolution.suggest(downgradedFrom: nil).mayPublishRegion)
        XCTAssertTrue(SafetyGate.Resolution.suggest(downgradedFrom: "r").mayPublishRegion)
    }

    /// An ignored decision in a password field is still a password: it must be
    /// dropped and withheld, exactly like a fix would be.
    func testAnIgnoredDecisionInASecureFieldIsWithheldAndDropped() {
        let resolution = SafetyGate.resolve(
            decision: .ignore(reason: "no gate met"), secureField: .secure)
        XCTAssertEqual(resolution, .drop(reason: "the focused field is a password field"))
        XCTAssertFalse(resolution.mayPublishRegion)
    }

    // MARK: - Policy capping, end to end through the decision function

    /// A region that auto-applies under `.normal` must come out as a suggestion
    /// under `.suggestOnly` — the terminal seeds depend on it.
    // MARK: - Explicit commands

    /// The manual flip reads the selection before it has a fix to resolve, so
    /// the secure-field rule has to hold one step earlier than `resolve`.
    func testASecureFieldRefusesAnExplicitCommand() {
        XCTAssertFalse(SafetyGate.allowsExplicitCommand(secureField: .secure))
    }

    func testAnOrdinaryFieldAllowsAnExplicitCommand() {
        XCTAssertTrue(SafetyGate.allowsExplicitCommand(secureField: .notSecure))
    }

    /// Pinned on purpose: the secure-field check fails open, matching
    /// `resolve`, because secure event input is the separate belt that
    /// covers what accessibility cannot see.
    func testAnUnknownSecurityVerdictAllowsAnExplicitCommand() {
        XCTAssertTrue(SafetyGate.allowsExplicitCommand(secureField: .unknown))
    }

    func testSuggestOnlyCapsAnAutoApplyAtSuggest() {
        let typedText = "aaaaa aaaaa"
        let region = CandidateRegion(
            keys: [], typedText: typedText, letterCount: 10, completedTokenCount: 1)
        let candidate = fix(typedText)
        let strong = Score(bigram: 0.75, dictCoverage: 0.75)
        let weak = Score(bigram: 0.0, dictCoverage: 0.0)

        func resolve(_ policy: AppPolicy) -> SafetyGate.Resolution {
            let decision = FixDecision.verdict(
                region: region, current: weak, alternate: strong, fix: candidate,
                guards: GuardResult(vetoes: []), policy: policy, thresholds: .balanced)
            return SafetyGate.resolve(decision: decision, secureField: .notSecure)
        }

        XCTAssertEqual(resolve(.normal), .autoApply)
        XCTAssertEqual(resolve(.suggestOnly), .suggest(downgradedFrom: nil))
        XCTAssertEqual(resolve(.off), .nothing, "and .off never even reaches the gate")
    }
}
