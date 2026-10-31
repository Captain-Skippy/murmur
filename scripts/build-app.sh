#!/bin/zsh
# Build Murmur.app from the Swift package and sign it. Usage: scripts/build-app.sh (makes build/Murmur.app)
#
# Signing: MURMUR_SIGN_IDENTITY if set (a Developer ID makes a build to notarize), else your one Apple
# Development identity, else ad-hoc.
# With a certificate, Microphone, Accessibility and Input Monitoring grants survive rebuilds: they
# follow the designated requirement (bundle id plus certificate name). An ad-hoc build works the
# same, but macOS asks for those permissions again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"  # Metal shaders need Xcode

APP=build/Murmur.app

# Never pin a certificate: a new one replaces it when Apple renews or revokes.
if [[ -n "${MURMUR_SIGN_IDENTITY:-}" ]]; then
  IDENTITY=$MURMUR_SIGN_IDENTITY
else
  ids=(${(f)"$(security find-identity -v -p codesigning | awk '/"Apple Development: /{print $2}')"})
  if (( ${#ids} == 0 )); then
    IDENTITY=-
    echo "no Apple Development identity: signing ad hoc (permissions are asked again after each rebuild)" >&2
  elif (( ${#ids} == 1 )); then
    IDENTITY=${ids[1]}
  else
    echo "found ${#ids} Apple Development identities; set MURMUR_SIGN_IDENTITY to one" >&2; exit 1
  fi
fi

# Before the long build, prove this session can sign and macOS still runs what the certificate signs:
# over SSH the login keychain is closed (errSecInternalComponent), and a revoked or expired
# certificate (security find-identity still calls it valid) gets its code killed at exec.
if [[ $IDENTITY != - ]]; then
  probe=$(mktemp -d)
  trap 'rm -rf "$probe"' EXIT
  print 'int main(void) { return 0; }' | clang -x c -o "$probe/probe" -
  codesign --force --sign "$IDENTITY" "$probe/probe" 2>"$probe/err" ||
    { cat "$probe/err" >&2; echo "cannot sign in this session: run it in a logged-in GUI session, not over SSH" >&2; exit 1; }
  "$probe/probe" || { echo "macOS kills code signed by $IDENTITY (certificate revoked or expired)" >&2; exit 1; }
fi

swift build -c release --product MurmurApp
swift build -c release --product murmur
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MurmurApp" "$APP/Contents/MacOS/Murmur"
cp "$BIN/murmur" "$APP/Contents/MacOS/murmur-cli"  # case-insensitive disk: not "murmur"
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
cp eval/script.json "$APP/Contents/Resources/script.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # drawn by scripts/make-icon.swift

VERSION="0.1.$(git rev-list --count HEAD)"
COMMIT=$(git describe --always --dirty --abbrev=12)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cjhorning.murmur</string>
  <key>CFBundleName</key><string>Murmur</string>
  <key>CFBundleDisplayName</key><string>Murmur</string>
  <key>CFBundleExecutable</key><string>Murmur</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>MurmurCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Murmur records while you hold the dictation key and transcribes on this Mac. Audio never leaves the Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Murmur can use Apple's on-device speech recognizer.</string>
</dict></plist>
PLIST

# Nested code first, then the app. A Developer ID build gets what notarization requires (hardened
# runtime, secure timestamp, the microphone entitlement); scripts/notarize.sh then submits it.
SIGN=(--force --sign "$IDENTITY")
APP_SIGN=()
if [[ $IDENTITY == "Developer ID Application"* ]] ||
   security find-identity -v -p codesigning | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application'; then
  SIGN+=(--options runtime --timestamp)
  APP_SIGN=(--entitlements Resources/Murmur.entitlements)
fi
for b in "$APP/Contents/Resources"/*.bundle; do codesign "${SIGN[@]}" "$b"; done
codesign "${SIGN[@]}" "$APP/Contents/MacOS/murmur-cli"
codesign "${SIGN[@]}" "${APP_SIGN[@]}" --identifier com.cjhorning.murmur "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/murmur-cli" >/dev/null  # the kernel runs what was signed
codesign -d -r- "$APP" 2>&1 | grep designated
echo "built $APP ($VERSION, $COMMIT)"
