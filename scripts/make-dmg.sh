#!/bin/bash
# Build a distributable disk image containing the app and a drop target.
#
# Read scripts/make-cert.sh first if the app is not signed yet: an unsigned or
# self-signed build will open on the machine that made it and be refused by
# Gatekeeper on every other one. That is a distribution problem, not a build
# problem, and this script cannot solve it — see the release notes in README.
set -euo pipefail

APP_NAME="${APP_NAME:-Harf}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ -d "$APP" ] || { echo "no $APP — run 'make bundle sign' first" >&2; exit 1; }

echo "==> Staging ${APP_NAME} ${VERSION}"
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

# A background image would need a mounted-and-scripted layout pass; the plain
# window with the app beside an Applications alias is the convention users
# already know, and it survives every macOS version without maintenance.
echo "==> Building $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

SIZE=$(du -h "$DMG" | cut -f1)
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "==> $DMG  ($SIZE)"
echo "    sha256  $SHA"
echo
echo "The Homebrew cask needs that checksum. Regenerate it after any rebuild."
