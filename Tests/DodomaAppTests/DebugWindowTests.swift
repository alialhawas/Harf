import DodomaCore
import XCTest

@testable import DodomaAppKit

/// What the debug window holds on to while nobody is looking at it.
///
/// The window itself needs a live session to show anything, so only the
/// retention rule is covered here — which is the part that matters: the
/// snapshots it coalesces carry the buffer text and the produced text of the
/// last fifty keystrokes, and the window is opt-in precisely because that is
/// the one surface in the app where those are on screen.
final class DebugWindowTests: XCTestCase {
    private func snapshot(_ text: String) -> BufferSnapshot {
        BufferSnapshot(
            text: text,
            keyCount: text.count,
            recentEvents: [
                DebugEvent(
                    id: 1, keycodeText: "4", flagsText: "", producedText: text,
                    actionText: "append", timestamp: 0)
            ],
            capturedAt: 0)
    }

    /// Delivered on the pipeline queue, taken up on the main one; letting the
    /// main queue run is what makes the hop observable.
    private func settle() {
        let done = expectation(description: "the main queue caught up")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testAWindowThatWasNeverOpenedKeepsNothing() {
        let controller = DebugWindowController()
        controller.accept(snapshot("hgsghl"))
        settle()

        XCTAssertNil(controller.pending)
    }
}
