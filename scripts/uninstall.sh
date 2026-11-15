#!/bin/bash
# Removes Interspace and everything the install made: the app, its login item, its two permissions,
# its settings, its signing identity, and the copy of the source.
set -uo pipefail

APP_NAME="Interspace"
BUNDLE_ID="com.cnrad.interspace"
SOURCE="${INTERSPACE_SOURCE:-$HOME/.interspace}"
KEYCHAIN="$HOME/Library/Keychains/interspace-signing.keychain-db"

for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    [ -d "$candidate" ] || continue
    # Only the app can take itself out of the login items, so ask it before it is deleted.
    "$candidate/Contents/MacOS/$APP_NAME" --unregister-login-item >/dev/null 2>&1 || true
done

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1

# macOS can only do this while it still knows the app, so before the app is deleted.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true

rm -rf "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

if [ -f "$KEYCHAIN" ]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
fi
rm -rf "$HOME/.config/interspace"

echo "Interspace is removed."
# Last, because this script can be inside that folder.
if [ -d "$SOURCE/.git" ]; then
    rm -rf "$SOURCE"
fi
