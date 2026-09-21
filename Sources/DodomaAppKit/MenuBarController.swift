import AppKit
import DodomaCore

final class MenuBarController: NSObject, NSMenuDelegate {
    /// How long the status item shows what just happened before going back to
    /// its idle icon.
    private static let flashDuration: TimeInterval = 1.5
    /// Title shown while a fix is being applied.
    private static let autoApplyFlash = "⇄ ع/E"
    /// Title shown when the user asked for something — accepting a suggestion,
    /// an undo — and the text in front of the caret turned out not to be what
    /// it was computed from. Applying it anyway would delete the wrong
    /// characters, so nothing happens and the refusal has to be visible;
    /// otherwise the key looks broken.
    private static let rejectedFlash = "✕"
    /// Title shown when a fix has just been taken back.
    private static let undoFlash = "↩"
    /// Titles for the pause hot key, which has no other feedback: the menu is
    /// not open when it is pressed.
    private static let pausedFlash = "⏸"
    private static let resumedFlash = "▶"
    /// Appended to the "Last fix" line once that fix has been undone.
    static let undoneSuffix = " (undone)"
    /// Longest each field of the "Last fix" line may be before it is
    /// middle-ellipsised.
    private static let fieldLimit = 20
    /// Longest an app name may be in the "Mode for …" title.
    private static let appNameLimit = 24

    private let settings: SettingsStore
    private let frontmost: FrontmostAppTracker

    private let statusItem: NSStatusItem
    private let statusLineItem: NSMenuItem
    private let lastFixItem: NSMenuItem
    private let undoItem: NSMenuItem
    private let flipItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let modeItem: NSMenuItem
    private var modeOptions: [AppPolicy: NSMenuItem] = [:]
    private let idleImage: NSImage?

    /// Bumped by every flash so a stale restore cannot undo a newer one.
    private var flashToken = 0

    /// The menu's rendering of `Hotkeys.undoLastFix`. The letter is spelled out
    /// because a key equivalent is a character and a hot key is a key code, and
    /// nothing translates one into the other without asking the active layout.
    /// Key code 6 is Z; `SettingsCopyTests` pins the pair together.
    static let undoKeyEquivalent = "z"
    static var undoModifiers: NSEvent.ModifierFlags {
        modifierFlags(Hotkeys.undoLastFix.modifiers)
    }

    /// The same pairing for `Hotkeys.flipSelection`. Key code 3 is F.
    static let flipKeyEquivalent = "f"
    static var flipModifiers: NSEvent.ModifierFlags {
        modifierFlags(Hotkeys.flipSelection.modifiers)
    }

    static func modifierFlags(_ flags: KeyFlags) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if flags.contains(.command) { mask.insert(.command) }
        if flags.contains(.option) { mask.insert(.option) }
        if flags.contains(.shift) { mask.insert(.shift) }
        if flags.contains(.control) { mask.insert(.control) }
        return mask
    }

    /// Invoked when the user picks "Debug Window".
    var onShowDebugWindow: (() -> Void)?
    /// Invoked when the user picks "Settings…".
    var onShowSettings: (() -> Void)?
    /// Invoked when the user picks "Onboarding…".
    var onShowOnboarding: (() -> Void)?
    /// Invoked after the user toggles the pause item, with the new value.
    var onPauseChanged: ((Bool) -> Void)?
    /// Invoked when the user picks "Undo Last Fix".
    var onUndo: (() -> Void)?
    /// Asked, on the main thread, while the menu is opening: is there anything
    /// to undo *right now*? It expires on a timer as well as on events, so it
    /// cannot be a value pushed here after the fact.
    var isUndoAvailable: (() -> Bool)?
    /// Invoked when the user picks "Flip Selection".
    var onFlip: (() -> Void)?
    /// Asked, on the main thread, while the menu is opening, for the same
    /// reason `isUndoAvailable` is: the pipeline can be busy or suspended by
    /// the time the menu opens, and an item that answers with a ✕ is worse
    /// than a greyed-out one.
    var isFlipAvailable: (() -> Bool)?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(settings: SettingsStore, frontmost: FrontmostAppTracker) {
        self.settings = settings
        self.frontmost = frontmost

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        lastFixItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastFixItem.isEnabled = false
        lastFixItem.isHidden = true
        // The key equivalent is decoration: the shortcut is registered with
        // Carbon, which is what makes it work when Dodoma is not frontmost —
        // i.e. always. Setting it here is what renders "⌘⌥Z" beside the title.
        undoItem = NSMenuItem(
            title: "Undo Last Fix", action: nil,
            keyEquivalent: Self.undoKeyEquivalent)
        undoItem.keyEquivalentModifierMask = Self.undoModifiers
        undoItem.isEnabled = false
        // The key equivalent is decoration here too: Carbon dispatches ⌃⌘F,
        // and setting it renders the chord beside the title.
        flipItem = NSMenuItem(
            title: "Flip Selection", action: nil,
            keyEquivalent: Self.flipKeyEquivalent)
        flipItem.keyEquivalentModifierMask = Self.flipModifiers
        flipItem.isEnabled = false
        pauseItem = NSMenuItem(title: "Pause Harf", action: nil, keyEquivalent: "")
        modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")

        idleImage = NSImage(
            systemSymbolName: "character.book.closed", accessibilityDescription: "Harf")

        super.init()

        if let button = statusItem.button {
            if let idleImage {
                button.image = idleImage
            } else {
                button.title = "⇄"
            }
        }

        statusItem.menu = makeMenu()
    }

    func update(with state: PermissionState, capturing: Bool, secureInput: Bool, degraded: Bool) {
        statusLineItem.title = Self.statusText(
            for: state, capturing: capturing, paused: settings.paused, secureInput: secureInput,
            degraded: degraded)
        pauseItem.state = settings.paused ? .on : .off
    }

    // MARK: - Fix feedback

    /// Main thread only.
    func showAutoApply(_ applied: AppliedFix) {
        flash(Self.autoApplyFlash)
        lastFixItem.title = Self.lastFixText(
            replaced: applied.fix.replacedText,
            inserted: applied.fix.insertText,
            app: applied.bundleID ?? "unknown",
            at: applied.appliedAt)
        lastFixItem.isHidden = false
    }

    /// Main thread only.
    func showRejected() {
        flash(Self.rejectedFlash)
    }

    /// Takes the chord off the menu item, for when the shortcut could not be
    /// registered — another application already owns ⌘⌥Z. The item still
    /// works; advertising a chord that does nothing would send the user
    /// looking for a broken keyboard. Main thread only.
    func clearUndoShortcut() {
        undoItem.keyEquivalent = ""
        undoItem.keyEquivalentModifierMask = []
    }

    /// The same, for ⌃⌘F. Main thread only.
    func clearFlipShortcut() {
        flipItem.keyEquivalent = ""
        flipItem.keyEquivalentModifierMask = []
    }

    /// Main thread only.
    func showUndo() {
        flash(Self.undoFlash)
        lastFixItem.title = Self.undoneText(lastFixItem.title)
    }

    /// Main thread only. The pause hot key has no other feedback: the menu that
    /// carries the checkmark is not open when it is pressed.
    func showPauseChanged(paused: Bool) {
        flash(paused ? Self.pausedFlash : Self.resumedFlash)
    }

    static func lastFixText(replaced: String, inserted: String, app: String, at date: Date)
        -> String
    {
        let field = { TextDisplay.middleTruncate($0, limit: fieldLimit) }
        return "Last fix: \(field(replaced)) → \(field(inserted)) "
            + "(\(field(app))) \(timeFormatter.string(from: date))"
    }

    /// Idempotent: an undo cannot happen twice, but a second flash arriving for
    /// any reason must not stack the suffix.
    static func undoneText(_ lastFixTitle: String) -> String {
        guard !lastFixTitle.isEmpty, !lastFixTitle.hasSuffix(undoneSuffix) else {
            return lastFixTitle
        }
        return lastFixTitle + undoneSuffix
    }

    private func flash(_ title: String) {
        guard let button = statusItem.button else { return }
        flashToken += 1
        let token = flashToken

        button.image = nil
        button.title = title

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration) { [weak self] in
            guard let self, self.flashToken == token else { return }
            button.title = self.idleImage == nil ? "⇄" : ""
            button.image = self.idleImage
        }
    }

    /// The one sentence that says what the app is doing, for the menu's first
    /// line — and, since it is the only place that sentence is composed, for
    /// `harf --status`'s `state` line as well. Internal rather than private for
    /// that second reader: two renderings of the same five values would
    /// eventually disagree, and the whole point of `--status` reporting the
    /// running copy is that it says what the menu says.
    static func statusText(
        for state: PermissionState, capturing: Bool, paused: Bool, secureInput: Bool,
        degraded: Bool
    ) -> String {
        // Permissions first: without them nothing else in this line is true.
        if !state.accessibility { return "Needs Accessibility permission" }
        if !state.inputMonitoring { return "Needs Input Monitoring permission" }
        if paused { return "Paused" }
        if secureInput { return "Paused — secure input" }
        let base = capturing ? "Active (capturing)" : "Active"
        // The watchdog has switched off event consumption for the session, so
        // the accept key no longer works and the user needs to be told why
        // clicking is now the only way to take a suggestion.
        return degraded ? "\(base) — degraded, click suggestions to accept" : base
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(statusLineItem)
        menu.addItem(lastFixItem)
        menu.addItem(.separator())

        undoItem.target = self
        undoItem.action = #selector(undoLastFix)
        menu.addItem(undoItem)

        flipItem.target = self
        flipItem.action = #selector(flipSelection)
        menu.addItem(flipItem)

        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        modeItem.submenu = makeModeSubmenu()
        menu.addItem(modeItem)

        menu.addItem(.separator())

        // ⌘, is the standard chord, and it is decoration for the same reason
        // the undo chord is: Dodoma is an accessory app, so nothing dispatches
        // a key equivalent to it unless one of its own windows is key.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let onboardingItem = NSMenuItem(title: "Onboarding…",
                                        action: #selector(showOnboarding),
                                        keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(.separator())

        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…",
                                           action: #selector(openAccessibilitySettings),
                                           keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let inputMonitoringItem = NSMenuItem(title: "Open Input Monitoring Settings…",
                                             action: #selector(openInputMonitoringSettings),
                                             keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)

        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Debug Window",
                                   action: #selector(showDebugWindow),
                                   keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Harf",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeModeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (policy, title) in Self.modeTitles {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy.rawValue
            submenu.addItem(item)
            modeOptions[policy] = item
        }
        return submenu
    }

    /// Ordered most permissive first, which is also the order they read in.
    private static let modeTitles: [(AppPolicy, String)] = [
        (.normal, "Normal"),
        (.suggestOnly, "Suggest only"),
        (.off, "Off"),
    ]

    /// The menu is rebuilt from the live frontmost app every time it opens.
    ///
    /// Opening a status-item menu does not change the frontmost application for
    /// an accessory app, so this reads the app the user was actually typing in.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = frontmost.lastNonSelfApp
        let policy = settings.policy(for: app.bundleID)

        modeItem.title =
            "Mode for \(TextDisplay.middleTruncate(app.displayName, limit: Self.appNameLimit))"
        modeItem.isEnabled = app.bundleID != nil
        for (option, item) in modeOptions {
            item.state = option == policy ? .on : .off
            item.isEnabled = app.bundleID != nil
        }
        pauseItem.state = settings.paused ? .on : .off
        // Asked now rather than pushed on every apply: the offer expires on a
        // timer, so a value published when the fix landed would be a lie by the
        // time the user opens the menu.
        undoItem.isEnabled = isUndoAvailable?() ?? false
        flipItem.isEnabled = isFlipAvailable?() ?? false
    }

    // MARK: - Actions

    /// Also the hot key's target, so the two cannot drift: whatever the menu
    /// item does, ⌘⌥P does.
    @objc func togglePause() {
        let paused = !settings.paused
        settings.setPaused(paused)
        pauseItem.state = paused ? .on : .off
        onPauseChanged?(paused)
    }

    @objc private func undoLastFix() {
        onUndo?()
    }

    @objc private func flipSelection() {
        onFlip?()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = AppPolicy(rawValue: raw),
              let bundleID = frontmost.lastNonSelfApp.bundleID
        else { return }
        settings.setPolicy(policy, for: bundleID)
        Log.app.info(
            "policy for \(bundleID, privacy: .public) set to \(policy.rawValue, privacy: .public)")
        for (option, item) in modeOptions {
            item.state = option == policy ? .on : .off
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(PermissionPanes.accessibility)
    }

    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(PermissionPanes.inputMonitoring)
    }

    @objc private func showSettings() {
        onShowSettings?()
    }

    @objc private func showOnboarding() {
        onShowOnboarding?()
    }

    @objc private func showDebugWindow() {
        onShowDebugWindow?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
