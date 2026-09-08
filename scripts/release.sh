#!/bin/bash
# Cut a release: build, package, publish the asset, refresh the cask.
#
# Everything a user needs to run `brew install --cask <tap>/<name>` comes from
# here, so the checksum in the cask and the file on the release can never drift
# apart: both are produced in one pass.
set -euo pipefail

REPO="${REPO:-alialhawas/Language-changer}"
TAP_REPO="${TAP_REPO:-}"          # e.g. alialhawas/homebrew-harf
APP_NAME="${APP_NAME:-Harf}"
CASK_TOKEN="${CASK_TOKEN:-harf}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v${VERSION}"
DMG="build/${APP_NAME}-${VERSION}.dmg"

# Notarisation has three hard prerequisites and fails late and cryptically when
# any is missing, so they are checked before anything is built or uploaded.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  : "${SIGN_IDENTITY:?NOTARY_PROFILE is set, so SIGN_IDENTITY must name your Developer ID Application certificate}"
  case "$SIGN_IDENTITY" in
    "Developer ID"*) ;;
    *) echo "error: '$SIGN_IDENTITY' is not a Developer ID. Apple only notarises Developer ID signatures." >&2; exit 1 ;;
  esac
  if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "error: no code-signing identity matching '$SIGN_IDENTITY' in the keychain." >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no stored notarytool credentials named '$NOTARY_PROFILE'. Create them once with:" >&2
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>" >&2
    exit 1
  fi
fi

echo "==> Building ${APP_NAME} ${VERSION}"
make build bundle sign >/dev/null
./scripts/make-dmg.sh >/dev/null
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    $DMG"
echo "    sha256 $SHA"

# Notarisation, when a Developer ID is available. Without it the build is
# self-signed: it opens on the machine that made it and is refused everywhere
# else, and Apple has no way to revoke it if a build is ever compromised. With
# NOTARY_PROFILE set, these three lines are the whole difference.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarising (profile $NOTARY_PROFILE)"
  # The disk image is signed too, so the download itself carries a verifiable
  # origin rather than only the app inside it.
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"   # stapling rewrites the file
  echo "    stapled; sha256 now $SHA"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
  NOTARISED=yes
else
  echo "==> Not notarised (set NOTARY_PROFILE to change that)"
  NOTARISED=no
fi

if [ "$NOTARISED" = yes ]; then
  NOTES="sha256  ${SHA}

Signed with a Developer ID, notarised by Apple and stapled, so it opens without
a Gatekeeper prompt.

Verify the download before you trust it:
    shasum -a 256 ${APP_NAME}-${VERSION}.dmg"
else
  NOTES="sha256  ${SHA}

Not notarised by Apple. macOS will refuse it the first time; allow it once under
System Settings > Privacy & Security > Open Anyway, which leaves Gatekeeper on.

Verify the download before you trust it:
    shasum -a 256 ${APP_NAME}-${VERSION}.dmg"
fi

echo "==> Publishing $TAG to $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" --repo "$REPO" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"
fi

echo "==> Refreshing the cask"
python3 - "$SHA" "$VERSION" "$CASK_TOKEN" <<'PY'
import re, sys
sha, version = sys.argv[1], sys.argv[2]
path = "Casks/%s.rb" % sys.argv[3]
body = open(path).read()
body = re.sub(r'version "[^"]+"', 'version "%s"' % version, body)
body = re.sub(r'sha256 "[a-f0-9]+"', 'sha256 "%s"' % sha, body)
open(path, "w").write(body)
print("    Casks updated to %s" % version)
PY

if [ "$NOTARISED" = yes ] && grep -q "not notarised" "Casks/${CASK_TOKEN}.rb"; then
  echo "    NOTE: this build is notarised but Casks/${CASK_TOKEN}.rb still tells"
  echo "          users to click Open Anyway. Edit the caveats block."
fi

if [ -n "$TAP_REPO" ]; then
  echo "==> Pushing the cask to $TAP_REPO"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  gh repo clone "$TAP_REPO" "$TMP/tap" -- --depth 1 >/dev/null 2>&1
  mkdir -p "$TMP/tap/Casks"
  cp "Casks/${CASK_TOKEN}.rb" "$TMP/tap/Casks/"
  git -C "$TMP/tap" add -A
  git -C "$TMP/tap" commit -q -m "${CASK_TOKEN} ${VERSION}" || echo "    (nothing to commit)"
  git -C "$TMP/tap" push -q
  # The qualified form is deliberate: Homebrew 6 treats installing a fully
  # qualified cask as trusting that one cask, so it needs no `brew trust` step
  # and grants nothing to the rest of the tap.
  echo "    users can now run:"
  echo "        brew tap ${TAP_REPO%%/*}/${TAP_REPO##*homebrew-}"
  echo "        brew install --cask ${TAP_REPO%%/*}/${TAP_REPO##*homebrew-}/${CASK_TOKEN}"
else
  echo "==> TAP_REPO not set; the cask was refreshed locally but not published"
fi
