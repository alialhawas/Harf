import DodomaCore
import XCTest

@testable import DodomaAppKit

/// Turning a bundle identifier into a name a person recognises, and what
/// happens at each point the lookup can fail.
final class AppDirectoryTests: XCTestCase {
    func testTheBundleNameWinsWhenThereIsOne() {
        XCTAssertEqual(
            AppDirectory.displayName(
                bundleID: "com.googlecode.iterm2",
                bundleName: "iTerm2",
                bundleURL: URL(fileURLWithPath: "/Applications/iTerm.app")),
            "iTerm2")
    }

    /// A bundle whose plist carries neither `CFBundleDisplayName` nor
    /// `CFBundleName`: the file name is what the Finder shows for it.
    func testTheFileNameIsUsedWhenThePlistCarriesNoName() {
        XCTAssertEqual(
            AppDirectory.displayName(
                bundleID: "org.alacritty",
                bundleName: nil,
                bundleURL: URL(fileURLWithPath: "/Applications/Alacritty.app")),
            "Alacritty")
    }

    /// The case the fallback chain exists for: an app that is not installed on
    /// this machine, so LaunchServices has no URL for it. A policy set on
    /// another machine, or an app since deleted, must still be a row the user
    /// can see and remove — never a blank one.
    func testAnUninstalledAppFallsBackToTheRawIdentifier() {
        XCTAssertEqual(
            AppDirectory.displayName(
                bundleID: "dev.warp.Warp-Stable", bundleName: nil, bundleURL: nil),
            "dev.warp.Warp-Stable")
    }

    func testEmptyStringsAreTreatedAsAbsent() {
        XCTAssertEqual(
            AppDirectory.displayName(
                bundleID: "com.example.app",
                bundleName: "",
                bundleURL: URL(fileURLWithPath: "/Applications/Example.app")),
            "Example")
        XCTAssertEqual(
            AppDirectory.displayName(
                bundleID: "com.example.app", bundleName: "", bundleURL: nil),
            "com.example.app")
    }

    /// Every entry in the seed table resolves to something non-empty whether or
    /// not the app is installed here, which is what stops the settings list
    /// from having unclickable blank rows on a clean machine.
    func testEverySeededBundleIdentifierResolvesToANonEmptyName() {
        for bundleID in PolicySeeds.table.keys {
            XCTAssertFalse(AppDirectory.displayName(for: bundleID).isEmpty, bundleID)
        }
    }
}

/// The settings window's read-only rows say things that are true elsewhere in
/// the app. These pin them together.
final class SettingsCopyTests: XCTestCase {
    func testTheUndoWindowShownMatchesTheOneEnforced() {
        XCTAssertEqual(SettingsCopy.undoWindow, "30 s")
        XCTAssertEqual(FixHistory.undoWindow, 30)
    }

    func testTheDisplayedChordsMatchTheRegisteredHotkeys() {
        XCTAssertEqual(SettingsCopy.undoChord, Self.chord(Hotkeys.undoLastFix, letter: "Z"))
        XCTAssertEqual(SettingsCopy.pauseChord, Self.chord(Hotkeys.togglePause, letter: "P"))
        XCTAssertEqual(SettingsCopy.flipChord, Self.chord(Hotkeys.flipSelection, letter: "F"))
        // Key code 6 is Z, 35 is P and 3 is F on every layout; the letters
        // above are the only part of the rendering that cannot be derived.
        XCTAssertEqual(Hotkeys.undoLastFix.keycode, 6)
        XCTAssertEqual(Hotkeys.togglePause.keycode, 35)
        XCTAssertEqual(Hotkeys.flipSelection.keycode, 3)
        XCTAssertEqual(
            String(SettingsCopy.undoChord.suffix(1)),
            MenuBarController.undoKeyEquivalent.uppercased(),
            "the menu item and the settings window name the same key")
        XCTAssertEqual(
            String(SettingsCopy.flipChord.suffix(1)),
            MenuBarController.flipKeyEquivalent.uppercased(),
            "the menu item and the settings window name the same key")
    }

    /// macOS's canonical modifier order, ⌃⌥⇧⌘ — the order `NSMenuItem` renders
    /// a key equivalent in, which is what the settings window is asking the
    /// user to compare its read-only row against.
    private static func chord(_ binding: HotkeyBinding, letter: String) -> String {
        var text = ""
        if binding.modifiers.contains(.control) { text += "⌃" }
        if binding.modifiers.contains(.option) { text += "⌥" }
        if binding.modifiers.contains(.shift) { text += "⇧" }
        if binding.modifiers.contains(.command) { text += "⌘" }
        return text + letter
    }
}
