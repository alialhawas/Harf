import AppKit
import Foundation

/// Identity of a frontmost application, snapshotted so it can be read off the
/// main thread.
struct FrontmostApp: Equatable {
    var bundleID: String?
    var processIdentifier: pid_t?
    var localizedName: String?

    init(bundleID: String? = nil, processIdentifier: pid_t? = nil, localizedName: String? = nil) {
        self.bundleID = bundleID
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
    }

    init(_ app: NSRunningApplication?) {
        self.init(
            bundleID: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier,
            localizedName: app?.localizedName)
    }

    /// What the menu calls this app.
    var displayName: String { localizedName ?? bundleID ?? "the frontmost app" }
}

/// The one place the app learns which application is in front.
///
/// It is read from three very different contexts, which is why it is a cache
/// rather than a call:
///
/// - the injector re-checks between individual keystrokes — the backspace burst
///   alone runs for a few hundred milliseconds and every event in it is
///   destructive, so a main-thread round trip per event is out of the question;
/// - the pipeline needs the switch as an *event*, to reset the typed buffer;
/// - the menu needs the last non-Dodoma app, to label its per-app submenu.
///
/// All three used to be served by separate `NSWorkspace` observers. One
/// observer feeding one cache means they cannot disagree about when the switch
/// happened.
///
/// The cache is *best effort*: the notification lands on the main run loop some
/// small time after the switch, so a check can be that much stale. The hard
/// containment for the destructive path is the accessibility verification in
/// `FocusOracle`, not this.
final class FrontmostAppTracker {
    private let lock = NSLock()
    private var cached = FrontmostApp()
    private var lastNonSelf = FrontmostApp()

    /// Main-thread only, and an array rather than a dictionary so the fan-out
    /// runs in registration order. Two of these handlers act on the same
    /// switch — the pipeline resets its buffer, the secure-input monitor
    /// refreshes its flag — and a `Dictionary` hands them out in hash order,
    /// which is to say in whichever order the run happens to produce.
    private var observers: [(token: UUID, handler: (FrontmostApp) -> Void)] = []
    private var observer: NSObjectProtocol?

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    /// Must be created on the main thread; `NSWorkspace` is read once to seed
    /// the cache before any notification can arrive.
    init() {
        let current = FrontmostApp(NSWorkspace.shared.frontmostApplication)
        cached = current
        if current.processIdentifier != selfPID { lastNonSelf = current }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(FrontmostApp(app))
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Reading

    /// Cheap enough to call between individual injected key events.
    var bundleID: String? {
        lock.lock()
        defer { lock.unlock() }
        return cached.bundleID
    }

    var current: FrontmostApp {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// The last application that was frontmost and was not Dodoma.
    ///
    /// Opening a status-item menu does not change the frontmost application for
    /// an `LSUIElement` app, so `current` would almost always do — but "almost"
    /// is not a property to hang a destructive per-app setting on, and an
    /// accessory app *can* be activated (a panel, a settings window). The menu
    /// acts on this instead.
    var lastNonSelfApp: FrontmostApp {
        lock.lock()
        defer { lock.unlock() }
        return lastNonSelf
    }

    /// Authoritative read, straight from `NSWorkspace` on the main thread.
    ///
    /// Used at the coarse checkpoints, where the cost of a round trip is
    /// irrelevant and being a notification behind is not acceptable. Safe from
    /// the fix queue for the same reason as every other `main.sync` in the
    /// injector: nothing on the main thread ever waits on that queue.
    func currentBundleID() -> String? {
        var app = FrontmostApp()
        DispatchQueue.main.sync {
            app = FrontmostApp(NSWorkspace.shared.frontmostApplication)
        }
        store(app)
        return app.bundleID
    }

    // MARK: - Observing

    /// Registers a handler called on the main thread after every activation.
    /// Main thread only.
    @discardableResult
    func addObserver(_ handler: @escaping (FrontmostApp) -> Void) -> UUID {
        assert(Thread.isMainThread)
        let token = UUID()
        observers.append((token: token, handler: handler))
        return token
    }

    /// Main thread only.
    func removeObserver(_ token: UUID) {
        assert(Thread.isMainThread)
        observers.removeAll { $0.token == token }
    }

    // MARK: - Writing

    private func activated(_ app: FrontmostApp) {
        store(app)
        for observer in observers { observer.handler(app) }
    }

    private func store(_ app: FrontmostApp) {
        lock.lock()
        cached = app
        if app.processIdentifier != selfPID, app.bundleID != nil {
            lastNonSelf = app
        }
        lock.unlock()
    }
}
