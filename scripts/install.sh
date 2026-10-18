#!/bin/bash
# Installs Verbaline, or updates it to the newest version. The same command does both:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JLFinance25/Verbaline/main/scripts/install.sh)"
#
# It downloads the newest code into a temporary folder, builds it, replaces /Applications/Verbaline.app,
# then deletes the temporary folder. Your word list, history, snippets and speech model live in
# ~/Library/Application Support/Verbaline and are never touched.
#
# A Verbaline folder from the old install method (git clone into your home folder) is moved to the Trash,
# after its local.env (signing settings) is kept. You can get it back from the Trash if you need it.
set -euo pipefail

REPO="${VERBALINE_REPO:-https://github.com/JLFinance25/Verbaline.git}"   # override only for testing
SUPPORT="$HOME/Library/Application Support/Verbaline"
SAVED_ENV="$SUPPORT/build.env"          # local.env kept between installs, since the code folder is deleted
OLD_FOLDER="$HOME/Verbaline"

say()  { printf '\n==> %s\n' "$*"; }
stop() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" != 0 ]] || stop "don't run this with sudo; run it as yourself."

say "Checking this Mac"
[[ "$(uname -m)" == arm64 ]] || stop "Verbaline needs a Mac with an Apple chip (M1 or newer)."
MAC_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAC_MAJOR >= 26 )) || stop "Verbaline needs macOS 26 or newer (this Mac has $(sw_vers -productVersion))."
xcode-select -p >/dev/null 2>&1 || stop "Apple's command line tools are missing. Run: xcode-select --install
then run this command again."
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x "$b" ]] && eval "$("$b" shellenv)" && break; done
fi
command -v brew >/dev/null 2>&1 || stop "Homebrew is missing. Install it from https://brew.sh, then run this command again."

if brew list whisper-cpp >/dev/null 2>&1; then
  echo "Speech engine (whisper-cpp) is installed."
else
  say "Installing the speech engine (brew install whisper-cpp)"
  brew install whisper-cpp
fi

say "Downloading the newest Verbaline code"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verbaline-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet --depth 1 "$REPO" "$WORK/Verbaline"
cd "$WORK/Verbaline"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
echo "Newest version: $VERSION"

# Signing settings (local.env): from the last install, else from an old Verbaline folder.
mkdir -p "$SUPPORT"
OLD_IS_CLONE=0
if [[ -d "$OLD_FOLDER/.git" ]] && git -C "$OLD_FOLDER" remote get-url origin 2>/dev/null | grep -qi 'JLFinance25/Verbaline'; then
  OLD_IS_CLONE=1
fi
if [[ ! -f "$SAVED_ENV" && $OLD_IS_CLONE == 1 && -f "$OLD_FOLDER/local.env" ]]; then
  cp "$OLD_FOLDER/local.env" "$SAVED_ENV"
fi
[[ -f "$SAVED_ENV" ]] && cp "$SAVED_ENV" local.env

# Keep macOS permissions across updates: make (or reuse) the "Verbaline Local Signing" certificate.
if ! grep -q '^VERBALINE_SIGN_IDENTITY=' local.env 2>/dev/null; then
  say "Setting up signing so macOS remembers Verbaline's permissions"
  echo "If a keychain window asks about codesign, click \"Always Allow\"."
  scripts/make-signing-identity.sh
fi
cp local.env "$SAVED_ENV"

say "Building and installing Verbaline $VERSION (this takes a minute or two)"
if [[ "${VERBALINE_BUILD_ONLY:-}" == 1 ]]; then ./build.sh; else ./build.sh --install; fi   # BUILD_ONLY: testing

# Only a plain download is removed: not one with files changed or added, or commits of its own.
if [[ $OLD_IS_CLONE == 1 ]] && { [[ -n "$(git -C "$OLD_FOLDER" status --porcelain 2>/dev/null)" ]] ||
     [[ -n "$(git -C "$OLD_FOLDER" log --oneline '@{upstream}..HEAD' 2>/dev/null)" ]]; }; then
  say "Left $OLD_FOLDER in place: it has changes of your own. Delete it yourself if you don't need them."
  OLD_IS_CLONE=0
fi
if [[ $OLD_IS_CLONE == 1 ]]; then
  TRASHED="$HOME/.Trash/Verbaline (old install folder) $(date +%Y-%m-%d\ %H.%M.%S)"
  mv "$OLD_FOLDER" "$TRASHED"
  say "Moved the old $OLD_FOLDER folder to the Trash (it's no longer needed)"
fi

say "Done: Verbaline $VERSION is installed in Applications and running."
echo "Your word list, history, snippets and speech model were kept."
