#!/usr/bin/env bash
# build-app.sh - Produce a self-contained Flow42.app bundle.
#
# Contents:
#
#   Flow42.app/
#     Contents/
#       Info.plist                 — LSUIElement bundle, NSScreenCaptureUsage…
#       MacOS/
#         Flow42                   — Flow42Menu binary (status item + glow)
#       Resources/
#         bin/
#           flow42                 — CLI binary
#         models/
#           ggml-base.en.bin       — whisper model (when --with-whisper-model)
#         whisper/
#           whisper-cli            — vendored whisper-cli binary
#                                    (when WHISPER_CLI_PATH is set)
#         chrome-extension/        — DOM sidecar dist/ tree
#         skills/                  — flow42-cli, flow-creator, flow-recorder
#         AppIcon.icns             — when scripts/templates/AppIcon.icns exists
#
# Two flags:
#   --with-whisper-model   download + bundle ggml-base.en.bin (~142 MB)
#   --skip-codesign        skip the codesign step (useful while iterating)
#
# Codesigning uses the same identity as scripts/dev-build.sh
# (FLOW42_SIGN_IDENTITY env var, falling back to "Apple Development" /
# "Flow42 Dev"). The bundle gets signed deep so embedded binaries inherit
# the signature.

set -euo pipefail

cd "$(dirname "$0")/.."

WITH_MODEL=0
SKIP_SIGN=0
for arg in "$@"; do
    case "$arg" in
        --with-whisper-model) WITH_MODEL=1 ;;
        --skip-codesign)      SKIP_SIGN=1 ;;
        --help|-h)
            grep '^# ' "$0" | sed 's/^# //'
            exit 0 ;;
    esac
done

OUT="build/Flow42.app"
CONTENTS="$OUT/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> swift build -c release (flow42 + Flow42Menu)"
# Note: SwiftPM honors only the last --product flag, so build them separately.
swift build -c release --product flow42
swift build -c release --product Flow42Menu

# ---- Layout ---------------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$MACOS_DIR" "$RES_DIR/bin" "$RES_DIR/models" "$RES_DIR/whisper" \
         "$RES_DIR/chrome-extension" "$RES_DIR/skills"

cp .build/release/Flow42Menu "$MACOS_DIR/Flow42"
cp .build/release/flow42     "$RES_DIR/bin/flow42"

# ---- Info.plist ----------------------------------------------------------

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>          <string>en</string>
  <key>CFBundleExecutable</key>                 <string>Flow42</string>
  <key>CFBundleIdentifier</key>                 <string>com.web42.flow42.menu</string>
  <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
  <key>CFBundleName</key>                       <string>Flow42</string>
  <key>CFBundleDisplayName</key>                <string>Flow42</string>
  <key>CFBundlePackageType</key>                <string>APPL</string>
  <key>CFBundleShortVersionString</key>         <string>0.1</string>
  <key>CFBundleVersion</key>                    <string>1</string>
  <key>LSMinimumSystemVersion</key>             <string>14.0</string>
  <key>LSUIElement</key>                        <true/>
  <key>NSHumanReadableCopyright</key>           <string>© Web42</string>
  <key>NSScreenCaptureUsageDescription</key>
    <string>Flow42 captures the region you select with Cmd+Shift+A so an agent can read the visual context you want it to know about.</string>
  <key>NSAppleEventsUsageDescription</key>
    <string>Flow42 reads window titles and app state to enrich the events it records.</string>
  <key>NSMicrophoneUsageDescription</key>
    <string>Flow42 captures narration during recordings; the audio stays on your Mac and is transcribed locally with whisper.</string>
</dict>
</plist>
PLIST

# ---- Optional icon -------------------------------------------------------

if [[ -f "scripts/templates/AppIcon.icns" ]]; then
    cp scripts/templates/AppIcon.icns "$RES_DIR/AppIcon.icns"
fi

# ---- Vendor: skills -------------------------------------------------------

SKILLS_SRC="Sources/Flow42Core/Resources/skills"
if [[ -d "$SKILLS_SRC" ]]; then
    cp -R "$SKILLS_SRC"/* "$RES_DIR/skills/"
    echo "==> skills vendored ($(ls "$RES_DIR/skills" | wc -l | tr -d ' ') bundles)"
fi

# ---- Vendor: Chrome extension --------------------------------------------

EXT_SRC=""
for cand in "../dist" "dist" "../openclaw-web-flow/dist"; do
    if [[ -f "$cand/manifest.json" ]]; then
        EXT_SRC="$(cd "$cand" && pwd)"
        break
    fi
done
if [[ -n "$EXT_SRC" ]]; then
    cp -R "$EXT_SRC"/* "$RES_DIR/chrome-extension/"
    echo "==> chrome extension vendored from $EXT_SRC"
else
    echo "warning: chrome extension dist/ not found; bundle will run without DOM sidecar" >&2
fi

# ---- Vendor: whisper-cli (optional) --------------------------------------

WHISPER_BIN="${WHISPER_CLI_PATH:-}"
if [[ -z "$WHISPER_BIN" ]]; then
    for cand in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
        [[ -x "$cand" ]] && WHISPER_BIN="$cand" && break
    done
fi
if [[ -n "$WHISPER_BIN" && -x "$WHISPER_BIN" ]]; then
    cp "$WHISPER_BIN" "$RES_DIR/whisper/whisper-cli"
    echo "==> whisper-cli vendored from $WHISPER_BIN"
else
    echo "warning: whisper-cli not vendored — set WHISPER_CLI_PATH to override" >&2
fi

# ---- Vendor: whisper model (optional) ------------------------------------

if [[ "$WITH_MODEL" -eq 1 ]]; then
    ./scripts/fetch-models.sh
    cp ".build/vendor/ggml-base.en.bin" "$RES_DIR/models/ggml-base.en.bin"
    echo "==> whisper model vendored"
fi

# ---- Codesign (deep) -----------------------------------------------------

if [[ "$SKIP_SIGN" -eq 1 ]]; then
    echo "==> skipping codesign (--skip-codesign)"
else
    identity="${FLOW42_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        if security find-identity -v -p codesigning | grep -q "Apple Development:"; then
            identity=$(security find-identity -v -p codesigning \
                | grep "Apple Development:" | head -1 \
                | sed -E 's/.*"([^"]+)".*/\1/')
        elif security find-identity -v -p codesigning | grep -q '"Flow42 Dev"'; then
            identity="Flow42 Dev"
        fi
    fi
    if [[ -z "$identity" ]]; then
        echo "warning: no signing identity found; bundle will be ad-hoc signed" >&2
        codesign --force --deep --sign - --options runtime --timestamp=none "$OUT"
    else
        echo "==> codesign with: $identity"
        # Sign nested binaries first, then the bundle.
        codesign --force --sign "$identity" --options runtime --timestamp=none \
            --identifier com.web42.flow42         "$RES_DIR/bin/flow42"
        if [[ -f "$RES_DIR/whisper/whisper-cli" ]]; then
            codesign --force --sign "$identity" --options runtime --timestamp=none \
                --identifier com.web42.flow42.whisper "$RES_DIR/whisper/whisper-cli"
        fi
        codesign --force --sign "$identity" --options runtime --timestamp=none \
            --identifier com.web42.flow42.menu    "$MACOS_DIR/Flow42"
        codesign --force --deep --sign "$identity" --options runtime --timestamp=none \
            --identifier com.web42.flow42.menu    "$OUT"
    fi
fi

echo ""
echo "✓ Built $OUT"
echo "  size: $(du -sh "$OUT" | awk '{print $1}')"
echo ""
echo "Run it with:   open $OUT"
echo "Or move into Applications, then launch from Spotlight."
