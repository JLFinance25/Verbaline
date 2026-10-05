#!/bin/bash
# Builds Verbaline.app from src/*.swift.
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications, and restart Verbaline
#
# Optional settings live in an untracked `local.env` next to this script:
#   VERBALINE_BUNDLE_ID=local.verbaline.app       # app identifier (macOS ties permissions to it)
#   VERBALINE_SIGN_IDENTITY="My Signing Cert"  # a code-signing identity in your keychain; see README
# Without a signing identity the app is ad-hoc signed, and macOS asks for permissions again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")"
# local.env is read as plain KEY=value lines, never run as shell code.
setting() { [[ -f local.env ]] && sed -n -E "s/^$1=\"?([^\"]*)\"?[[:space:]]*$/\1/p" local.env | tail -1 || true; }
BUNDLE_ID="$(setting VERBALINE_BUNDLE_ID)"; BUNDLE_ID="${BUNDLE_ID:-local.verbaline.app}"
IDENTITY="$(setting VERBALINE_SIGN_IDENTITY)"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "VERBALINE_BUNDLE_ID may only contain letters, digits, dots and hyphens"; exit 1; }
FLAGS=()
[[ "${VERBALINE_TESTING:-}" == 1 ]] && FLAGS+=(-D VERBALINE_TESTING)   # self-test modes, used by tests/run_all.sh

# The app is assembled outside the source folder (cloud-synced folders add extended attributes that
# codesign refuses), in a ".noindex" folder so Spotlight doesn't list a second copy of the app.
OUT="$HOME/Library/Caches/Verbaline-build.noindex"
APP="$OUT/Verbaline.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

swiftc -swift-version 5 -O -target arm64-apple-macos26.0 ${FLAGS[@]+"${FLAGS[@]}"} \
  src/*.swift -o "$APP/Contents/MacOS/Verbaline"

xattr -cr "$APP"
# Hardened runtime: other processes can't inject code into the app and borrow its permissions.
SIGN=(--force --options runtime --entitlements Verbaline.entitlements --identifier "$BUNDLE_ID")
if [[ -n "$IDENTITY" ]] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign "${SIGN[@]}" --sign "$IDENTITY" "$APP"
else
  codesign "${SIGN[@]}" --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application "Verbaline" to quit' 2>/dev/null || true
  sleep 1
  pkill -x Verbaline 2>/dev/null || true
  rm -rf /Applications/Verbaline.app
  ditto "$APP" /Applications/Verbaline.app
  open /Applications/Verbaline.app
  echo "Installed /Applications/Verbaline.app and restarted it"
fi
