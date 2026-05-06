#!/usr/bin/env bash
# sign-debug.sh - Apply stable codesign identifiers to the debug binaries.
#
# Why: SwiftPM produces adhoc-signed binaries whose identifier embeds a
# content hash (flow42-<sha>). macOS TCC remembers Screen Recording /
# Accessibility grants by identifier, so every `swift build` invalidates
# the previous grant — the user has to re-add the binary in System
# Settings after every rebuild. Re-signing with a stable identifier
# (com.flow42.cli / com.flow42.menu) makes the grant persist across
# rebuilds.
#
# Run this after `swift build` (or wire it into a build phase).

set -euo pipefail

cd "$(dirname "$0")/.."

ARCH="$(uname -m)-apple-macosx"
BUILD_DIR=".build/${ARCH}/debug"

if [[ ! -d "$BUILD_DIR" ]]; then
    echo "no build dir at $BUILD_DIR — run swift build first" >&2
    exit 1
fi

echo "Signing $BUILD_DIR/flow42 → com.flow42.cli"
codesign --sign - --identifier com.flow42.cli --force "$BUILD_DIR/flow42"

if [[ -f "$BUILD_DIR/Flow42Menu" ]]; then
    echo "Signing $BUILD_DIR/Flow42Menu → com.flow42.menu"
    codesign --sign - --identifier com.flow42.menu --force "$BUILD_DIR/Flow42Menu"
fi

if [[ -f "$BUILD_DIR/Flow42App" ]]; then
    echo "Signing $BUILD_DIR/Flow42App → com.flow42.app"
    codesign --sign - --identifier com.flow42.app --force "$BUILD_DIR/Flow42App"
fi

echo "Done. macOS Screen Recording / Accessibility grants now persist across rebuilds."
