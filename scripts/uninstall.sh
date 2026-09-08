#!/bin/bash
set -euo pipefail

pkill -x Harf || true
rm -rf /Applications/Harf.app
tccutil reset Accessibility com.ali.dodoma || true
tccutil reset ListenEvent com.ali.dodoma || true

echo "Dodoma removed and privacy grants reset."
echo
echo "If start-at-login was on, switch it off from Settings > General BEFORE"
echo "uninstalling: only the app itself can unregister with SMAppService. An"
echo "orphaned entry is harmless — it points at a bundle that no longer exists —"
echo "and can be removed under System Settings > General > Login Items."
echo
echo "Preferences are left alone. To remove them too:"
echo "    defaults delete com.ali.dodoma"
echo
echo "The 'Dodoma Dev' code-signing certificate, its private key and its trust"
echo "setting remain in the login keychain. To remove those as well, run:"
echo "    security delete-identity -c \"Dodoma Dev\" -t \"\$HOME/Library/Keychains/login.keychain-db\""
