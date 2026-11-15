#!/bin/bash
# Installs Interspace: gets the source, builds it on this Mac, and puts the app in /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/cnrad/interspace/main/scripts/install.sh | bash
#
# Run it again to update. It needs the Xcode Command Line Tools, and nothing else.
#
# Why it builds here and does not download an app: an app that is built on the Mac it runs on is not
# stopped by Gatekeeper, and you can read every line that goes into it before you give it permissions.
set -euo pipefail

REPO="${INTERSPACE_REPO:-https://github.com/cnrad/interspace.git}"
# The source stays here, so an update is a `git pull` and a build.
SOURCE="${INTERSPACE_SOURCE:-$HOME/.interspace}"
APP_NAME="Interspace"
BUNDLE_ID="com.cnrad.interspace"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\n%s\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "Interspace is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Interspace needs macOS 14 or newer. This Mac has $(sw_vers -productVersion)."

# The Command Line Tools have git and the Swift compiler.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    say "The Xcode Command Line Tools are needed, and are not installed."
    echo "A window from macOS asks you to install them now. When that is finished, run this command again."
    xcode-select --install >/dev/null 2>&1 || true
    exit 1
fi

if [ -d "$SOURCE/.git" ]; then
    say "Updating the source in $SOURCE"
    git -C "$SOURCE" pull --ff-only
elif [ -e "$SOURCE" ]; then
    fail "$SOURCE exists and is not a copy of the Interspace source. Move it away, or set INTERSPACE_SOURCE to a different folder."
else
    say "Getting the source into $SOURCE"
    git clone --depth 1 "$REPO" "$SOURCE"
fi

cd "$SOURCE"

say "Making a signing identity for this Mac (one time)"
# macOS ties the two permissions to the signature of the app. With an identity that stays the same,
# you allow them one time, and not again after each update.
./scripts/setup-signing.sh

say "Building (about a minute the first time)"
./scripts/bundle.sh

# /Applications when it can be written to, as on most Macs. If not, the Applications folder of the user.
DESTINATION="/Applications"
if [ ! -w "$DESTINATION" ]; then
    DESTINATION="$HOME/Applications"
    mkdir -p "$DESTINATION"
fi
TARGET="$DESTINATION/$APP_NAME.app"

say "Installing to $TARGET"
# An update replaces the app while it is not running.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
rm -rf "$TARGET"
# ditto keeps the signature as it is.
ditto "build/$APP_NAME.app" "$TARGET"

open "$TARGET"

say "Interspace is installed and open."
cat <<EOF
It is in the menu bar. Two things are left, and only you can do them:

  1. Allow it in System Settings > Privacy & Security > Accessibility
  2. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording

macOS has asked for both just now. After you have allowed both, choose "Relaunch Interspace"
in its menu bar menu. Then swipe between your desktops with three fingers.

Until both are allowed, Interspace does nothing and the normal macOS swipe works as before.

To update:    run this command again
To uninstall: $SOURCE/scripts/uninstall.sh
EOF
