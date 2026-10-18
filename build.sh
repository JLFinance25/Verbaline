#!/bin/bash
# Builds Verbaline.app from src/*.swift.
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications, and restart Verbaline
# Needs: brew install whisper-cpp, and models/ggml-large-v3-turbo.bin.
# Whisper's libraries are used from Homebrew's folder, so a `brew upgrade whisper-cpp` needs a rebuild.
set -euo pipefail
cd "$(dirname "$0")"
# local.env (untracked) holds the signing identity. A git worktree has no copy of its own, so fall back to the
# main checkout's: without it the app is ad-hoc signed, looks like a new app every build, and macOS asks for
# permissions (folders, mic, accessibility) again and again.
ENV_FILE=local.env
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../local.env"
setting() { [[ -f "$ENV_FILE" ]] && sed -n -E "s/^$1=\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$ENV_FILE" | tail -1 || true; }
IDENTITY="$(setting VERBALINE_SIGN_IDENTITY)"
BUNDLE_ID="$(setting VERBALINE_BUNDLE_ID)"; BUNDLE_ID="${BUNDLE_ID:-local.verbaline.app}"   # macOS ties permissions to it
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "VERBALINE_BUNDLE_ID may only contain letters, digits, dots and hyphens"; exit 1; }
FLAGS=()
[[ "${VERBALINE_TESTING:-}" == 1 ]] && FLAGS+=(-D VERBALINE_TESTING)   # self-test modes, used by tests/run_all.sh
WH="$(brew --prefix whisper-cpp)"; GG="$(brew --prefix ggml)"

OUT="${VERBALINE_BUILD_DIR:-$HOME/Library/Caches/Verbaline-build.noindex}"
APP="$OUT/Verbaline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # made by: Verbaline --renderlogo dir, then iconutil

swiftc -swift-version 5 -O -target arm64-apple-macos26.0 ${FLAGS[@]+"${FLAGS[@]}"} \
  -import-objc-header bridging.h -Xcc -I"$WH/include" -Xcc -I"$GG/include" \
  -L"$WH/lib" -lwhisper -L"$GG/lib" -lggml -Xlinker -rpath -Xlinker "$WH/lib" \
  src/*.swift -o "$APP/Contents/MacOS/Verbaline"

xattr -cr "$APP"
SIGN=(--force --options runtime --entitlements Verbaline.entitlements --identifier "$BUNDLE_ID")
if [[ -n "$IDENTITY" ]] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign "${SIGN[@]}" --sign "$IDENTITY" "$APP"
else
  echo "WARNING: no signing identity (local.env) — ad-hoc signing; macOS will ask for permissions again" >&2
  codesign "${SIGN[@]}" --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application "Verbaline" to quit' 2>/dev/null || true
  sleep 1; pkill -x Verbaline 2>/dev/null || true
  osascript -e 'tell application "Murmur" to quit' 2>/dev/null || true   # the app's old working name
  pkill -x "Murmur" 2>/dev/null || true
  rm -rf /Applications/Verbaline.app
  ditto "$APP" /Applications/Verbaline.app
  open /Applications/Verbaline.app
  echo "Installed /Applications/Verbaline.app and restarted it"
fi
