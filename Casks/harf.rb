cask "harf" do
  version "1.0.1"
  sha256 "35d3bf35b3612855bb56a55d9dcdec0d7d5562ab551ee3478875d98957d9b955"

  url "https://github.com/alialhawas/Language-changer/releases/download/v#{version}/Harf-#{version}.dmg"
  name "Harf"
  desc "Fixes text typed with the wrong keyboard layout, Arabic and English"
  homepage "https://github.com/alialhawas/Language-changer"

  depends_on macos: :sonoma

  app "Harf.app"
  # The same binary serves the menu-bar app and the command line, so `harf
  # --status` works without shipping a second executable.
  binary "#{appdir}/Harf.app/Contents/MacOS/Harf", target: "harf"

  # Harf holds a keyboard event tap. Deleting the bundle under a running copy
  # leaves it tapping the keyboard with no app behind it, and the last 20
  # seconds of learned vocabulary are never flushed. Quit it first.
  uninstall quit: "com.ali.dodoma"

  # Deliberately does not tell anyone to pass --no-quarantine. That flag
  # switches Gatekeeper off for the install, and this app asks for the two most
  # powerful grants macOS has; teaching the habit is worse than the one-time
  # click below, which leaves Gatekeeper on and applies to this app alone.
  caveats <<~CAVEATS
    Harf is not notarised by Apple yet, so macOS will refuse to open it the
    first time. To allow it, once:

      System Settings > Privacy & Security > scroll to the message naming
      Harf > Open Anyway

    That keeps Gatekeeper on for everything else. Do not install this with
    --no-quarantine unless you understand what you are switching off.

    Harf then needs two permissions, both under Privacy & Security:

      Accessibility      — to replace the text
      Input Monitoring   — to see the keys you press

    Neither is optional; the app cannot work with only one. It is open
    source: read what it does before you grant them.

    Before uninstalling, switch start-at-login off under Harf's own
    Settings > General. Only the running app can unregister itself with
    SMAppService, so removing the bundle first strands the login item. It
    is harmless — it points at a bundle that is gone — and can be deleted
    under System Settings > General > Login Items.

    `brew uninstall --cask alialhawas/harf/harf` leaves your preferences and
    your learned words behind. Add `--zap` to remove those too.
  CAVEATS

  # --zap territory: everything the app writes outside its own bundle. The
  # first entry is the learned-word file, the only thing here derived from what
  # was typed, so it is the one that most needs to go on request.
  zap trash: [
    "~/Library/Application Support/Harf",
    "~/Library/Caches/com.ali.dodoma",
    "~/Library/Preferences/com.ali.dodoma.plist",
    "~/Library/Saved Application State/com.ali.dodoma.savedState",
  ]
end
