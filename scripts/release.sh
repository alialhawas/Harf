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
PLIST="Resources/Info.plist"
CASK="Casks/${CASK_TOKEN}.rb"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
TAG="v${VERSION}"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"

# Whether SIGN_IDENTITY was given, before the default is applied: NOTARY_PROFILE
# demands an explicit Developer ID and must not be satisfied by the fallback.
SIGN_IDENTITY_GIVEN="${SIGN_IDENTITY+yes}"
# Same default as the Makefile's SIGN_IDENTITY; keep the two in step, since the
# check below has to test the identity `make sign` will actually reach for.
SIGN_IDENTITY="${SIGN_IDENTITY:-Dodoma Dev}"
export SIGN_IDENTITY

# A release must never be cut from a tree that does not match the tag. Anything
# uncommitted is either in the build and not in the tag, or in the tag and not
# in the build; both make the released binary unreproducible.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree is dirty. Commit or stash before releasing:" >&2
  git status --short >&2
  exit 1
fi

COMMIT="$(git rev-parse HEAD)"
# GitHub can only tag a commit it already has. Without this the failure comes
# from `gh release create` after the build and the upload, not before them.
if [ -z "$(git branch -r --contains "$COMMIT" 2>/dev/null)" ]; then
  echo "error: HEAD ($COMMIT) is not on any remote branch. Push it first," >&2
  echo "       otherwise GitHub cannot create the tag on the commit that was built." >&2
  exit 1
fi

# The signing check is unconditional, not tied to NOTARY_PROFILE: `make sign`
# falls back to ad-hoc signing when the identity is missing, and an ad-hoc DMG
# published under this tag rewrites the cask sha256 and drops every user's
# Accessibility and Input Monitoring grants when they update. The fallback stays
# available for local builds; a release has to ask for it.
if security find-identity -v -p codesigning | grep -qF -- "$SIGN_IDENTITY"; then
  :
elif [ "${ALLOW_ADHOC:-}" = "1" ]; then
  echo "warning: no identity matching '$SIGN_IDENTITY'; ALLOW_ADHOC=1, so this" >&2
  echo "         release will be ad-hoc signed. Everyone updating from an earlier" >&2
  echo "         build will have to grant both permissions again." >&2
else
  echo "error: no code-signing identity matching '$SIGN_IDENTITY' in the keychain." >&2
  echo "       'make sign' would fall back to ad-hoc signing, which changes the" >&2
  echo "       designated requirement on every build, so macOS treats the update" >&2
  echo "       as a different app and drops both privacy grants." >&2
  echo "       Fix it with scripts/make-cert.sh (or scripts/devid-setup.sh for a" >&2
  echo "       Developer ID). To publish an ad-hoc build anyway: ALLOW_ADHOC=1" >&2
  exit 1
fi

# Notarisation has two further hard prerequisites and fails late and cryptically
# when either is missing, so they are checked before anything is built.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ -z "$SIGN_IDENTITY_GIVEN" ]; then
    echo "error: NOTARY_PROFILE is set, so SIGN_IDENTITY must name your Developer ID Application certificate" >&2
    exit 1
  fi
  case "$SIGN_IDENTITY" in
    "Developer ID"*) ;;
    *) echo "error: '$SIGN_IDENTITY' is not a Developer ID. Apple only notarises Developer ID signatures." >&2; exit 1 ;;
  esac
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no stored notarytool credentials named '$NOTARY_PROFILE'. Create them once with:" >&2
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>" >&2
    exit 1
  fi
fi

# CFBundleShortVersionString is bumped by hand; the build number is bookkeeping
# and is bumped here so that two releases of the same short version are never
# indistinguishable to macOS. Bumped before the build so the shipped bundle
# carries it, and committed at the end together with the refreshed cask.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
case "$BUILD" in
  ''|*[!0-9]*) echo "error: CFBundleVersion '$BUILD' is not an integer." >&2; exit 1 ;;
esac
BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
# Undo the bump if anything below fails. The tree was verified clean above, so
# this can only discard the one line written on the line above — and without it
# an abandoned run leaves a dirty tree that the next run refuses to start from.
trap 'git checkout -- "$PLIST" 2>/dev/null || true' EXIT

echo "==> Building ${APP_NAME} ${VERSION} (build ${BUILD}) from ${COMMIT}"
make build bundle sign >/dev/null

# The app is notarised and stapled before the disk image is built, so the copy
# a user drags out of the DMG carries its own ticket. Stapling only the DMG
# leaves the installed app unverifiable the first time it is opened offline.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarising the app (profile $NOTARY_PROFILE)"
  # notarytool takes an archive, never a bundle: zip it, submit the zip, then
  # staple the ticket onto the bundle the DMG will be built from.
  ZIP="build/${APP_NAME}-${VERSION}-notarise.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

./scripts/make-dmg.sh >/dev/null
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    $DMG"
echo "    sha256 $SHA"

# Notarisation of the image itself, when a Developer ID is available. Without it
# the build is self-signed: it opens on the machine that made it and is refused
# everywhere else, and Apple has no way to revoke it if a build is ever
# compromised.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarising the disk image"
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
  # The notes carry the checksum of the asset. Re-uploading without rewriting
  # them leaves the previous build's sha256 published against the new file.
  gh release edit "$TAG" --repo "$REPO" --notes "$NOTES"
else
  # --target pins the tag to the commit that was built. Without it GitHub
  # creates the tag on the default branch, so a release cut from a feature
  # branch tags main with a disk image built from somewhere else.
  gh release create "$TAG" "$DMG" --repo "$REPO" \
    --target "$COMMIT" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"
fi

echo "==> Refreshing the cask"
python3 - "$SHA" "$VERSION" "$CASK" <<'PY'
import re, sys
sha, version, path = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path).read()
body = re.sub(r'version "[^"]+"', 'version "%s"' % version, body)
body = re.sub(r'sha256 "[a-f0-9]+"', 'sha256 "%s"' % sha, body)
open(path, "w").write(body)
print("    %s updated to %s" % (path, version))
PY

if [ "$NOTARISED" = yes ] && grep -q "not notarised" "$CASK"; then
  echo "    NOTE: this build is notarised but ${CASK} still tells"
  echo "          users to click Open Anyway. Edit the caveats block."
fi

# Both files this script writes are committed here, so the tree is clean again
# and Casks/<token>.rb in this repository keeps matching what the tap serves.
# Not pushed: the tag already points at the commit that was built, and pushing
# is the operator's decision.
echo "==> Recording the release in this repository"
git add "$PLIST" "$CASK"
if git diff --cached --quiet; then
  echo "    (nothing to commit)"
else
  git commit -q -m "${APP_NAME} ${VERSION} (build ${BUILD})"
  echo "    committed $PLIST and $CASK — push when ready"
fi
trap - EXIT   # the bump is committed; nothing left to undo

if [ -n "$TAP_REPO" ]; then
  echo "==> Pushing the cask to $TAP_REPO"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  gh repo clone "$TAP_REPO" "$TMP/tap" -- --depth 1 >/dev/null 2>&1
  mkdir -p "$TMP/tap/Casks"
  cp "$CASK" "$TMP/tap/Casks/"
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
