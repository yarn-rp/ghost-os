#!/usr/bin/env bash
# fetch-models.sh - Download (and verify) the heavy assets a Flow42.app bundle
# needs to ship offline-capable.
#
# Currently fetches:
#   - ggml-base.en.bin   ~142 MB whisper model (narration transcription)
#
# Each asset is cached at .build/vendor/<name> with a sibling .sha256 file so
# CI doesn't redownload on every run, and a corrupted or interrupted download
# is caught by the integrity check.
#
# Usage:
#   ./scripts/fetch-models.sh           # fetch all known assets
#   ./scripts/fetch-models.sh --check   # only verify checksums, no download
#
# Future: vision models (YOLO / ShowUI) once those land. Each new asset adds
# one entry to the ASSETS array below — same pattern.

set -euo pipefail

cd "$(dirname "$0")/.."

VENDOR_DIR=".build/vendor"
mkdir -p "$VENDOR_DIR"

# Asset format: "<filename>|<url>|<sha256>"
# Whisper base.en model — published checksum from huggingface mirror.
ASSETS=(
    "ggml-base.en.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin|60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
)

CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
    esac
done

verify() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "  ✘ checksum mismatch:"
        echo "      expected: $expected"
        echo "      got:      $actual"
        return 1
    fi
    return 0
}

for asset in "${ASSETS[@]}"; do
    IFS='|' read -r name url sha <<<"$asset"
    out="$VENDOR_DIR/$name"

    if [[ -f "$out" ]] && verify "$out" "$sha" >/dev/null 2>&1; then
        echo "[ok] $name (cached)"
        continue
    fi

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        echo "[missing] $name"
        exit 1
    fi

    echo "[fetch] $name from $url"
    tmp="$out.partial"
    curl -L --fail --output "$tmp" "$url"
    if verify "$tmp" "$sha"; then
        mv "$tmp" "$out"
        echo "[ok] $name"
    else
        rm -f "$tmp"
        echo "error: refusing to keep corrupt download $name" >&2
        exit 1
    fi
done

echo "All assets present in $VENDOR_DIR"
