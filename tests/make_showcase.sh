#!/bin/bash
# Makes the README pictures from made-up sample data (never your own history or stats):
#   tests/make_showcase.sh [out-dir]      (default: docs/images)
# panel.png, icon.png, insights-light/dark.png, pill-1/2/3 stills and pill.gif (needs ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/images}"
export VERBALINE_BUILD_DIR="${VERBALINE_BUILD_DIR:-$HOME/Library/Caches/Verbaline-showcase.noindex}"
VERBALINE_TESTING=1 ./build.sh > /dev/null
TMP="$(mktemp -d)"
"$VERBALINE_BUILD_DIR/Verbaline.app/Contents/MacOS/Verbaline" --rendershowcase "$TMP" > /dev/null 2>&1
mkdir -p "$OUT"
ffmpeg -loglevel error -y -framerate 30 -i "$TMP/pill-frames/f%04d.png" \
  -vf "fps=30,split[a][b];[a]palettegen[p];[b][p]paletteuse=dither=none" -loop 0 "$OUT/pill.gif"
cp "$TMP"/panel.png "$TMP"/icon.png "$TMP"/insights-light.png "$TMP"/insights-dark.png "$TMP"/pill-*.png "$OUT/"
rm -rf "$TMP"
ls -1 "$OUT"
