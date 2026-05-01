#!/usr/bin/env bash
# dev-build.sh - Build flow42 for development with a stable code signature so
# TCC permissions (Accessibility, Screen Recording, Input Monitoring,
# Microphone) survive rebuilds.
#
# TCC keys persistence off the binary's designated requirement. With plain
# ad-hoc signing (`codesign -s -`) that requirement is `cdhash H"..."`, which
# changes on every rebuild and forces re-granting permissions. Signing with a
# stable identity keeps the designated requirement stable across rebuilds.
#
# First-time setup (once per machine) — pick ONE:
#
# A. Apple Development cert via Xcode (recommended, most reliable):
#    1. Open Xcode > Settings (Cmd-,) > Accounts
#    2. + > Apple ID > sign in (free Apple ID is fine; no paid program needed)
#    3. Select your account, click "Manage Certificates"
#    4. + > "Apple Development". Done.
#    Then this script auto-detects the identity. Or set FLOW42_SIGN_IDENTITY
#    explicitly: export FLOW42_SIGN_IDENTITY="Apple Development: Your Name"
#
# B. Self-signed cert via Keychain Access:
#    1. Keychain Access > Certificate Assistant > Create a Certificate...
#    2. Name: "Flow42 Dev", Identity Type: Self Signed Root,
#       Certificate Type: Code Signing, check "Let me override defaults".
#    3. Click through, accept defaults. Save in login keychain.
#    4. Double-click the cert > Trust > Code Signing > Always Trust.
#    Then: export FLOW42_SIGN_IDENTITY="Flow42 Dev"
#
# Verify either with:
#    security find-identity -v -p codesigning

set -euo pipefail

CONFIG="${CONFIG:-debug}"

cd "$(dirname "$0")/.."

# Auto-detect a signing identity, in priority order:
#   1. $FLOW42_SIGN_IDENTITY (explicit override)
#   2. "Apple Development: ..." (Xcode-managed)
#   3. "Flow42 Dev"            (self-signed via Keychain Access)
identity=""
if [[ -n "${FLOW42_SIGN_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning | grep -q "$FLOW42_SIGN_IDENTITY"; then
        identity="$FLOW42_SIGN_IDENTITY"
    fi
fi
if [[ -z "$identity" ]]; then
    if line=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1); then
        identity="${line%\"}"
        identity="${identity#\"}"
    fi
fi
if [[ -z "$identity" ]]; then
    if security find-identity -v -p codesigning | grep -q '"Flow42 Dev"'; then
        identity="Flow42 Dev"
    fi
fi

if [[ -z "$identity" ]]; then
    cat >&2 <<'EOF'
error: no usable code signing identity found.

Set up one of the following (once per machine):

A. Apple Development cert via Xcode (recommended):
   1. Open Xcode > Settings (Cmd-,) > Accounts
   2. + > Apple ID > sign in
   3. Select your account > "Manage Certificates"
   4. + > "Apple Development"
   Re-run this script — it will auto-detect.

B. Self-signed via Keychain Access:
   1. Keychain Access > Certificate Assistant > Create a Certificate...
   2. Name: "Flow42 Dev", Self Signed Root, Code Signing,
      check "Let me override defaults", click through.
   3. Double-click the cert > Trust > Code Signing > Always Trust.
   Then: export FLOW42_SIGN_IDENTITY="Flow42 Dev" and re-run.

Verify with: security find-identity -v -p codesigning
EOF
    exit 1
fi

# Resolve to the SHA1 hash to avoid "ambiguous" errors when multiple certs
# happen to share the common name (e.g. leftover from a prior Keychain
# Assistant attempt sitting in a different keychain).
hash=$(security find-identity -v -p codesigning | grep "\"$identity\"" | head -1 | awk '{print $2}')
if [[ -z "$hash" ]]; then
    echo "error: could not resolve hash for identity '$identity'" >&2
    exit 1
fi

echo "Using signing identity: $identity ($hash)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/flow42"
codesign --force --sign "$hash" --identifier com.web42.flow42 \
    --options runtime --timestamp=none "$BIN"

echo "signed $BIN ($identity, cdhash $(codesign -dvvv "$BIN" 2>&1 | awk '/CDHash=/{print $1}'))"

# Auto-link into PATH if /usr/local/bin is writable by us, otherwise instruct.
LINK="/usr/local/bin/flow42"
if [[ -L "$LINK" ]] || [[ ! -e "$LINK" ]]; then
    if [[ -w "$(dirname "$LINK")" ]]; then
        ln -sf "$PWD/$BIN" "$LINK"
        echo "linked $LINK -> $PWD/$BIN"
    elif [[ ! -L "$LINK" ]]; then
        echo ""
        echo "To add 'flow42' to your PATH (one-time):"
        echo "  sudo ln -sf $PWD/$BIN $LINK"
    fi
fi
