#!/bin/bash
# Obtain and install a Developer ID Application certificate, in two passes.
#
#   scripts/devid-setup.sh request          # before: makes the CSR to upload
#   scripts/devid-setup.sh install <file>   # after: installs the issued .cer
#
# Split in two because Apple's half happens in a browser: you upload a signing
# request, they hand back a certificate, and only then is there anything to
# install. The private key is generated here and never leaves this machine —
# Apple only ever sees the public half.
set -euo pipefail

WORKDIR="$HOME/.harf-devid"
KEY="$WORKDIR/devid.key"
CSR="$WORKDIR/devid.csr"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 1 ] || usage

case "$1" in
request)
    if [ -f "$KEY" ]; then
        echo "A signing request already exists at $CSR"
        echo "Upload that one, or delete $WORKDIR and re-run to start over."
        exit 1
    fi
    # 0700/0600 from the moment of creation rather than fixed up afterwards:
    # the private key is the whole credential, and a window where it is
    # world-readable is a window worth not having.
    mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
    ( umask 077; openssl genrsa -out "$KEY" 2048 2>/dev/null )
    chmod 600 "$KEY"

    read -r -p "Your name, as enrolled with Apple: " NAME
    read -r -p "Your Apple ID email:               " EMAIL
    openssl req -new -key "$KEY" -out "$CSR" \
        -subj "/emailAddress=${EMAIL}/CN=${NAME}"

    echo
    echo "Signing request written to:"
    echo "    $CSR"
    echo
    echo "Now, in a browser:"
    echo "  1. developer.apple.com/account/resources/certificates/list"
    echo "  2. + (add), then choose 'Developer ID Application'"
    echo "  3. Profile Type: leave as the default (G2 Sub-CA)"
    echo "  4. Upload the .csr above, Continue, then Download"
    echo
    echo "Then run:"
    echo "    scripts/devid-setup.sh install ~/Downloads/developerID_application.cer"
    ;;

install)
    [ $# -eq 2 ] || usage
    CER="$2"
    [ -f "$CER" ] || { echo "error: no such file: $CER" >&2; exit 1; }
    [ -f "$KEY" ] || { echo "error: no private key at $KEY — run 'request' first." >&2; exit 1; }

    P12="$WORKDIR/devid.p12"
    PEM="$WORKDIR/devid.pem"
    trap 'rm -f "$P12" "$PEM"' EXIT

    # Apple hands back DER; the key and certificate have to be married into one
    # PKCS#12 archive before the keychain will accept them as an identity.
    openssl x509 -inform DER -in "$CER" -out "$PEM"

    export P12_PASS
    P12_PASS="$(openssl rand -hex 16)"
    # -legacy: OpenSSL 3.x defaults to AES-256-CBC/PBKDF2 archives that
    # Security.framework refuses to read. Same workaround as make-cert.sh.
    openssl pkcs12 -export -legacy -inkey "$KEY" -in "$PEM" \
        -out "$P12" -passout env:P12_PASS

    security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
    unset P12_PASS

    echo
    echo "==> Authorising codesign to use the key without a GUI prompt each build"
    printf "    Login keychain password: "
    read -r -s KEYCHAIN_PASSWORD; echo
    IDENTITY="$(openssl x509 -in "$PEM" -noout -subject -nameopt multiline \
        | awk -F' = ' '/commonName/ {print $2}')"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -l "$IDENTITY" -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    unset KEYCHAIN_PASSWORD

    # The key exists in the keychain now; leaving a second copy in a dotfile is
    # just a credential lying around.
    rm -f "$KEY" "$CSR"

    echo
    if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
        echo "SUCCESS. Identity installed:"
        security find-identity -v -p codesigning | grep "Developer ID Application"
        echo
        echo "Next: store notary credentials, then release."
        echo "    xcrun notarytool store-credentials harf-notary \\"
        echo "        --apple-id <you@example.com> --team-id <TEAMID> \\"
        echo "        --password <app-specific-password>"
    else
        echo "FAILURE: no Developer ID Application identity is available."
        echo "If the certificate imported but shows as untrusted, macOS is missing"
        echo "Apple's intermediate. Install it from https://www.apple.com/certificateauthority/"
        echo "(Developer ID - G2) and re-check with:"
        echo "    security find-identity -v -p codesigning"
        exit 1
    fi
    ;;

*) usage ;;
esac
