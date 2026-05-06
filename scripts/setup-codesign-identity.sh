#!/usr/bin/env bash
# setup-codesign-identity.sh - One-shot creation of a self-signed code-signing
# identity for flow42 dev builds. Deterministic, no GUI required.
#
# Generates a real cert + private key, imports them paired into the login
# keychain, marks the cert trusted for code signing. After this, dev-build.sh
# auto-detects "Flow42 Dev" and signs the binary.
#
# Usage: ./scripts/setup-codesign-identity.sh
#
# Prompts you for your login password during the trust-settings step (one
# password prompt, that's it). Otherwise non-interactive.

set -euo pipefail

NAME="Flow42 Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Bail early if it already exists and works.
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity '$NAME' already exists and is trusted for codeSign:"
    security find-identity -v -p codesigning | grep "\"$NAME\""
    exit 0
fi

# Remove any orphaned cert/key from a previous failed run so we can reimport
# cleanly. -t certificate filters to certs; we re-run for keys.
echo "Cleaning up any orphaned '$NAME' entries from prior runs…"
while security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; do :; done
# Private keys: identified by label. Best-effort.
security delete-generic-password -l "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "Creating self-signed code-signing identity '$NAME'…"
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT
cd "$TMP"

# 1. Private key + self-signed cert with codeSigning EKU.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem -days 1825 \
    -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    >/dev/null 2>&1

# 2. Bundle into .p12 (security needs a packaged identity).
#    openssl 3.x defaults to PBKDF2/AES which Apple's `security` can't unpack.
#    Use -legacy on openssl 3+ to fall back to the SHA1/3DES format Apple
#    accepts. On openssl 1.1 the flag doesn't exist; we detect and adapt.
PASS="flow42-temp-$$"
P12_FLAGS=(-export -out flow42-dev.p12 -inkey key.pem -in cert.pem
           -name "$NAME" -passout "pass:$PASS")
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    P12_FLAGS+=(-legacy)
fi
if ! openssl pkcs12 "${P12_FLAGS[@]}" 2>/tmp/flow42-p12-err; then
    echo "openssl pkcs12 export failed:" >&2
    cat /tmp/flow42-p12-err >&2
    exit 1
fi

# 3. Import into login keychain. -T grants codesign tool access without prompts.
security import flow42-dev.p12 \
    -k "$KEYCHAIN" \
    -P "$PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

# 4. Mark trusted for codeSign at the user level. No sudo needed; macOS will
#    pop a keychain-access prompt asking you to confirm the trust change.
#    `trustRoot` (not `trustAsRoot`) is the correct flag for a self-signed
#    root cert.
echo "  Adding codeSign trust (you'll get a Keychain Access prompt to confirm)…"
security add-trusted-cert -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    cert.pem

cd - >/dev/null

# 5. Verify.
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo ""
    echo "✓ Identity created and trusted:"
    security find-identity -v -p codesigning | grep "\"$NAME\""
    echo ""
    echo "Next: ./scripts/dev-build.sh"
else
    echo ""
    echo "✗ Identity was created but isn't showing as trusted for codeSign."
    echo "  Check: security find-identity -v"
    echo "  If it appears there, the trust step didn't take. Re-run this script."
    exit 1
fi
