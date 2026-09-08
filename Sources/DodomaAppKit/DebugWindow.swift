import AppKit
import DodomaCore
import SwiftUI

/// Main-thread mirror of the latest `BufferSnapshot` and `DecisionSnapshot`.
final class DebugWindowModel: ObservableObject {
    @Published var snapshot = BufferSnapshot(
        text: "",
        keyCount: 0,
        lastReset: nil,
        frontmostBundleID: nil,
        recentEvents: [],
        capturedAt: 0)
    @Published var decision: DecisionSnapshot?
}

/// Lazily created window that mirrors the typed buffer.
///
/// The app has no SwiftUI `App` lifecycle, so the window is a plain `NSWindow`
/// hosting a SwiftUI view. Snapshots arrive on the pipeline queue and are
/// coalesced to roughly 10 Hz before touching the UI.
final class DebugWindowController {
    private static let refreshInterval: TimeInterval = 0.1

    private let model = DebugWindowModel()
    private var window: NSWindow?

    private var pending: BufferSnapshot?
    private var flushScheduled = false
    private var lastFlush: TimeInterval = 0

    /// Callable from any queue; the work is hopped onto the main thread.
    func accept(_ snapshot: BufferSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.enqueue(snapshot)
        }
    }

    /// Decisions arrive at most about once a second, so they are not coalesced.
    func accept(_ decision: DecisionSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.model.decision = decision
        }
    }

    /// Main thread only.
    private func enqueue(_ snapshot: BufferSnapshot) {
        pending = snapshot

        // Keep the newest snapshot around but do no UI work while hidden.
        guard window?.isVisible == true, !flushScheduled else { return }

        let elapsed = Date().timeIntervalSinceReferenceDate - lastFlush
        if elapsed >= Self.refreshInterval {
            flush()
        } else {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.refreshInterval - elapsed)) {
                [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flush()
            }
        }
    }

    private func flush() {
        guard let snapshot = pending else { return }
        pending = nil
        lastFlush = Date().timeIntervalSinceReferenceDate
        model.snapshot = snapshot
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Deliberately not `makeKeyAndOrderFront` / `NSApp.activate`: the point of
        // the debug window is to watch keystrokes typed into some *other* app.
        window.orderFrontRegardless()
        flush()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Harf Debug — keystrokes visible"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: DebugView(model: model))
        window.center()
        window.setFrameAutosaveName("HarfDebugWindow")
        return window
    }
}

private struct DebugView: View {
    @ObservedObject var model: DebugWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live keystroke capture. Contents are sensitive.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Buffer") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.snapshot.text.isEmpty ? "(empty)" : model.snapshot.text)
                        .font(.system(size: 18))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)

                    HStack(spacing: 16) {
                        LabelledValue("Keys", "\(model.snapshot.keyCount)")
                        LabelledValue("Last reset", model.snapshot.lastReset?.rawValue ?? "—")
                        LabelledValue("Frontmost", model.snapshot.frontmostBundleID ?? "—")
                    }
                }
                .padding(4)
            }

            GroupBox("Decisions") {
                DecisionPanel(decision: model.decision)
                    .padding(4)
            }

            Text("Last \(TypingSession.debugEventLimit) events")
                .font(.headline)

            EventTable(
                events: model.snapshot.recentEvents,
                referenceTime: model.snapshot.capturedAt)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 520)
    }
}

/// Last evaluation: what was looked at, how it scored and what happened next.
private struct DecisionPanel: View {
    let decision: DecisionSnapshot?

    var body: some View {
        if let decision {
            VStack(alignment: .leading, spacing: 6) {
                Text(decision.regionText.isEmpty ? "(no region)" : decision.regionText)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    LabelledValue("Verdict", decision.verdict)
                    LabelledValue("cur / alt", Self.scores(decision))
                    LabelledValue("Guards", decision.guards)
                    LabelledValue("Policy", decision.policy)
                    LabelledValue("Took", String(format: "%.1f ms", decision.durationMillis))
                }

                HStack(spacing: 16) {
                    LabelledValue("Reason", decision.reason.isEmpty ? "—" : decision.reason)
                    LabelledValue("Delete", decision.deleteCount.map(String.init) ?? "—")
                    LabelledValue("Insert", decision.insertText ?? "—")
                    LabelledValue("Result", decision.result ?? "—")
                }
            }
        } else {
            Text("No evaluation yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func scores(_ decision: DecisionSnapshot) -> String {
        String(format: "%.2f / %.2f", decision.currentScore, decision.alternateScore)
    }
}

private struct LabelledValue: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct EventTable: View {
    let events: [DebugEvent]
    let referenceTime: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        row(for: event)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("code").frame(width: 52, alignment: .leading)
            Text("mods").frame(width: 52, alignment: .leading)
            Text("text").frame(width: 64, alignment: .leading)
            Text("action").frame(width: 150, alignment: .leading)
            Text("age").frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func row(for event: DebugEvent) -> some View {
        HStack(spacing: 8) {
            Text(event.keycodeText).frame(width: 52, alignment: .leading)
            Text(event.flagsText).frame(width: 52, alignment: .leading)
            Text(event.producedText.isEmpty ? "·" : event.producedText)
                .frame(width: 64, alignment: .leading)
            Text(event.actionText).frame(width: 150, alignment: .leading)
            Text(Self.age(of: event, relativeTo: referenceTime))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private static func age(of event: DebugEvent, relativeTo reference: TimeInterval) -> String {
        let seconds = max(0, reference - event.timestamp)
        return String(format: "%.1fs", seconds)
    }
}
