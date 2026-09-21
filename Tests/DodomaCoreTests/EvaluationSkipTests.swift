import XCTest

@testable import DodomaCore

/// `SkipLedger`, which is the only thing standing between "every refusal says
/// so" and a log line once a second forever.
final class EvaluationSkipTests: XCTestCase {
    func testTheFirstOccurrenceOfAReasonIsReported() {
        var ledger = SkipLedger()
        XCTAssertTrue(ledger.shouldReport(SkipReason.noLayoutPair.rawValue))
    }

    /// The bug this exists for: an idle trigger that re-arms itself would
    /// otherwise emit the same sentence every second for two days.
    func testTheSameReasonIsNotReportedTwiceInARow() {
        var ledger = SkipLedger()
        XCTAssertTrue(ledger.shouldReport(SkipReason.noLayoutPair.rawValue))
        XCTAssertFalse(ledger.shouldReport(SkipReason.noLayoutPair.rawValue))
        XCTAssertFalse(ledger.shouldReport(SkipReason.noLayoutPair.rawValue))
    }

    /// A different refusal is different news, even arriving immediately after.
    func testAChangedReasonIsReported() {
        var ledger = SkipLedger()
        XCTAssertTrue(ledger.shouldReport(SkipReason.noLayoutPair.rawValue))
        XCTAssertTrue(ledger.shouldReport(SkipReason.gateOpen.rawValue))
        XCTAssertFalse(ledger.shouldReport(SkipReason.gateOpen.rawValue))
    }

    /// Clearing is what the successful path does, so the next time the same
    /// thing goes wrong it is reported again rather than swallowed.
    func testClearingReEnablesTheLastReason() {
        var ledger = SkipLedger()
        XCTAssertTrue(ledger.shouldReport(SkipReason.emptyBuffer.rawValue))
        XCTAssertFalse(ledger.shouldReport(SkipReason.emptyBuffer.rawValue))
        ledger.clear()
        XCTAssertTrue(ledger.shouldReport(SkipReason.emptyBuffer.rawValue))
    }

    /// Two reasons sharing a raw value would collapse into one ledger entry, so
    /// the second of them would go unreported for as long as the first stood.
    func testEveryRawValueIsDistinct() {
        let values = SkipReason.allCases.map(\.rawValue)
        XCTAssertEqual(Set(values).count, values.count)
    }

    /// The sentence row 29 of `docs/manual-checklist.md` says the app prints
    /// when the pair is unavailable. It is a contract with that document.
    func testTheMissingPairReasonReadsAsTheChecklistExpects() {
        XCTAssertEqual(SkipReason.noLayoutPair.rawValue, "no English/Arabic layout pair enabled")
    }
}
