#!/bin/bash
set -euo pipefail

# Creates a self-signed code-signing identity named "Dodoma Dev" in the login
# keychain. A stable identity is required so that macOS TCC keeps the
# Accessibility and Input Monitoring grants across rebuilds; ad-hoc signatures
# change on every build and the grants are dropped.

IDENTITY="Dodoma Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Guard on certificate existence rather than on `find-identity -v`, which lists
# only identities that are already valid. A run interrupted at the password or
# trust prompt leaves an untrusted certificate behind; without this check a
# re-run would add a second "Dodoma Dev" and codesign would then refuse to sign
# because the identity is ambiguous.
# Every keychain, not just the login one. An identity created by an earlier
# version of this script may live in a keychain of its own; a guard that looks
# only at the login keychain would not see it, would create a second "Dodoma
# Dev", and codesign would then refuse to sign at all because the identity is
# ambiguous.
EXISTING=""
for candidate in "$HOME"/Library/Keychains/*.keychain-db; do
    if security find-certificate -c "$IDENTITY" "$candidate" >/dev/null 2>&1; then
        EXISTING="$candidate"
        break
    fi
done

if [ -n "$EXISTING" ]; then
    if [ "$EXISTING" != "$KEYCHAIN" ]; then
        echo "'$IDENTITY' already exists, in a keychain of its own:"
        echo "    $EXISTING"
        echo
        echo "That is where an earlier version of this script put it. Nothing needs to"
        echo "be created. If signing fails with errSecInternalComponent, that keychain"
        echo "is locked rather than missing:"
        echo "    security unlock-keychain $EXISTING"
        echo
        echo "To start over instead, delete it first — note that a new certificate is a"
        echo "new designated requirement, so macOS will ask for Accessibility and Input"
        echo "Monitoring again, once:"
        echo "    security delete-keychain $EXISTING"
        exit 0
    fi
fi

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    if security find-identity -v -p codesigning | grep -qF -- "$IDENTITY"; then
        echo "Code-signing identity '$IDENTITY' already exists and is valid. Nothing to do."
        exit 0
    fi

    echo "A certificate named '$IDENTITY' is already in the login keychain, but it is"
    echo "not usable as a code-signing identity. A previous run most likely stopped at"
    echo "the keychain password prompt or the trust prompt."
    echo
    echo "Refusing to create a second '$IDENTITY' certificate: duplicates make codesign"
    echo "fail with an ambiguous-identity error."
    echo
    echo "Remove the existing certificate and re-run this script:"
    echo "    security delete-identity -c \"$IDENTITY\" -t \"$KEYCHAIN\""
    echo "    scripts/make-cert.sh"
    echo
    echo "If that reports no matching identity, the private key is missing; use:"
    echo "    security delete-certificate -c \"$IDENTITY\" -t \"$KEYCHAIN\""
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KEY_PEM="$WORKDIR/key.pem"
CERT_PEM="$WORKDIR/cert.pem"
P12="$WORKDIR/cert.p12"
CONF="$WORKDIR/codesign.cnf"

cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign

[ dn ]
CN = $IDENTITY

[ v3_codesign ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 \
    -keyout "$KEY_PEM" \
    -out "$CERT_PEM" \
    -days 3650 \
    -nodes \
    -subj "/CN=$IDENTITY" \
    -config "$CONF" \
    -extensions v3_codesign

# The PKCS#12 archive needs a non-empty passphrase: Security.framework rejects
# an empty-password p12 with "MAC verification failed during PKCS12 import",
# regardless of the encryption or MAC algorithm used to produce it. The archive
# is a temp file removed by the EXIT trap, so a random throwaway passphrase is
# enough and never has to be stored.
export P12_PASS
P12_PASS="$(openssl rand -hex 16)"

# $1 is an optional extra openssl flag, e.g. -legacy.
export_p12() {
    openssl pkcs12 -export ${1:+"$1"} \
        -inkey "$KEY_PEM" \
        -in "$CERT_PEM" \
        -out "$P12" \
        -name "$IDENTITY" \
        -passout env:P12_PASS
    # The archive holds the private key. WORKDIR is already 0700 from mktemp;
    # this narrows the file itself so the key is never group- or world-readable
    # for the few seconds it exists.
    chmod 600 "$P12"
}

echo "==> Bundling key and certificate into a PKCS#12 archive"
export_p12

echo "==> Importing into the login keychain"
# -P puts the archive passphrase in the argument list, where anyone on the
# machine can read it out of `ps` while the command runs. Accepted here, and
# only here: this passphrase is a random value generated seconds ago, guards a
# 0600 file inside a 0700 temporary directory, and is unset and thrown away
# immediately below. `security import` has no way to read it from a file
# descriptor, and prompting is not an option because nobody knows it.
if ! security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign; then
    if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
        # Expected on OpenSSL 3.x, whose default AES-256-CBC/PBKDF2 archives
        # Security.framework will not read.
        echo "    Default PKCS#12 encryption was rejected; re-exporting with -legacy."
        export_p12 -legacy
        if ! security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign; then
            unset P12_PASS
            echo "FAILURE: could not import the certificate into $KEYCHAIN."
            exit 1
        fi
    else
        unset P12_PASS
        echo "FAILURE: could not import the certificate into $KEYCHAIN."
        exit 1
    fi
fi
unset P12_PASS

echo
echo "==> Authorising /usr/bin/codesign to use the new private key"
echo "    macOS needs the login keychain password to update the key's"
echo "    partition list. Without this step every 'make sign' raises a GUI"
echo "    prompt asking you to allow keychain access."
echo "    Enter it at the prompt macOS raises."
echo

# -k is deliberately absent: passing the login keychain password as an argument
# puts it in this process's argument list, where every other process on the
# machine can read it out of `ps` for as long as the command runs. Without -k,
# `security` asks for it itself and it never becomes an argument.
#
# -l scopes the update to this key only. Without it, -s would rewrite the
# partition list of every signing key in the login keychain.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -l "$IDENTITY" \
    "$KEYCHAIN" >/dev/null

echo "==> Marking the certificate as trusted for code signing"
echo "    macOS may raise a GUI authorisation prompt here."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"

echo
if security find-identity -v -p codesigning | grep -qF -- "$IDENTITY"; then
    echo "SUCCESS: code-signing identity '$IDENTITY' is available."
    echo "Run 'make install' to build, bundle and sign Dodoma."
    exit 0
fi

echo "FAILURE: '$IDENTITY' is not listed by 'security find-identity -v -p codesigning'."
echo "Inspect the output above and retry, or sign ad-hoc (grants will not persist)."
exit 1
