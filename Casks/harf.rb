cask "harf" do
  version "1.0.0"
  sha256 "787a7f7e2c143cac01f6fa9bb9f66e54140b8ce305bfbdb9323d92044ae5ee1d"

  url "https://github.com/alialhawas/Language-changer/releases/download/v#{version}/Harf-#{version}.dmg"
  name "Harf"
  desc "Fixes text typed with the wrong keyboard layout, Arabic and English"
  homepage "https://github.com/alialhawas/Language-changer"

  depends_on macos: :sonoma

  app "Harf.app"
  # The same binary serves the menu-bar app and the command line, so `harf
  # --status` works without shipping a second executable.
  binary "#{appdir}/Harf.app/Contents/MacOS/Harf", target: "harf"

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
  CAVEATS

  zap trash: [
    "~/Library/Preferences/com.ali.dodoma.plist",
  ]
end
