#!/bin/zsh
# Notarize a Developer ID build and package it for download.
# Usage: MURMUR_SIGN_IDENTITY="Developer ID Application: NAME (TEAM)" scripts/build-app.sh
#        scripts/notarize.sh PROFILE    (PROFILE: a notarytool keychain profile, `xcrun notarytool store-credentials`)
# Makes build/Murmur-VERSION.zip: the stapled app, which opens without a Gatekeeper warning.
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE=${1:?usage: scripts/notarize.sh PROFILE}
APP=build/Murmur.app
[[ $(codesign -dvv "$APP" 2>&1) == *"Authority=Developer ID Application"* ]] ||
  { echo "$APP is not signed with a Developer ID: build with MURMUR_SIGN_IDENTITY set to one" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
SUBMIT=build/Murmur-notarize.zip
rm -f "$SUBMIT"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait | tee build/notarize.log
grep -q "status: Accepted" build/notarize.log || {
  id=$(awk '/^  id:/{print $2; exit}' build/notarize.log)
  [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
  echo "notarization failed" >&2; exit 1; }
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"
OUT=build/Murmur-$VERSION.zip
rm -f "$SUBMIT" "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
shasum -a 256 "$OUT"
echo "ready to publish: $OUT"
