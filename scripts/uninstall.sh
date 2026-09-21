#!/bin/bash
set -euo pipefail

BUNDLE_ID="com.ali.dodoma"
SUPPORT_DIR="$HOME/Library/Application Support/Harf"

# A Homebrew install must be removed by Homebrew. Running this script against
# one deletes the bundle out from under the cask, which leaves a dangling
# `harf` symlink on the PATH and a receipt claiming the app is still installed.
if command -v brew >/dev/null 2>&1 && brew list --cask harf >/dev/null 2>&1; then
    echo "Harf was installed with Homebrew. Remove it with Homebrew instead:"
    echo "    brew uninstall --zap --cask alialhawas/harf/harf"
    echo
    echo "--zap also deletes the preferences, the caches, the saved window state"
    echo "and the learned-word file. Without it those are left behind."
    echo
    echo "Switch start-at-login off from Settings > General BEFORE uninstalling:"
    echo "only the app itself can unregister with SMAppService."
    exit 1
fi

# Asked to quit, not signalled, and `-i` on the fallback: a copy started from
# the executable on the PATH is named `harf`, so `pkill -x Harf` walked straight
# past it and left it tapping the keyboard after its bundle and its privacy
# grants had been removed from under it.
/Applications/Harf.app/Contents/MacOS/Harf --quit 2>/dev/null || pkill -i -x Harf || true
rm -rf /Applications/Harf.app
# The learned-word file is the one thing here derived from what was typed, so
# uninstalling has to take it with the app rather than leave it on disk.
rm -rf "$SUPPORT_DIR"

# tccutil exits non-zero when it cannot reset a grant, and a blanket `|| true`
# followed by an unconditional success line reports the one outcome worth
# knowing about — a grant still standing for an app that is gone — as a clean
# uninstall. Each service is reported on its own.
TCC_STATUS=0
for service in Accessibility ListenEvent; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "$service: reset"
    else
        echo "$service: FAILED to reset for $BUNDLE_ID" >&2
        TCC_STATUS=1
    fi
done

if [ "$TCC_STATUS" -eq 0 ]; then
    echo "Harf removed and privacy grants reset."
else
    echo "Harf removed, but at least one privacy grant could not be reset." >&2
    echo "Remove the leftover entries by hand under System Settings > Privacy &" >&2
    echo "Security > Accessibility and > Input Monitoring." >&2
fi
echo
echo "If start-at-login was on, switch it off from Settings > General BEFORE"
echo "uninstalling: only the app itself can unregister with SMAppService. An"
echo "orphaned entry is harmless — it points at a bundle that no longer exists —"
echo "and can be removed under System Settings > General > Login Items."
echo
echo "Removed: /Applications/Harf.app and the learned-word file at"
echo "    $SUPPORT_DIR"
echo
echo "Preferences are left alone. To remove them too:"
echo "    defaults delete $BUNDLE_ID"
echo
echo "The 'Dodoma Dev' code-signing certificate, its private key and its trust"
echo "setting remain in the login keychain. To remove those as well, run:"
echo "    security delete-identity -c \"Dodoma Dev\" -t \"\$HOME/Library/Keychains/login.keychain-db\""

exit "$TCC_STATUS"
