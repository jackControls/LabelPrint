#!/bin/bash
# Build "Label Print.app" into ./build and sign it. Also creates ./build/labelprint, the command line tool
# (a link to the app's own executable).
# Signing identity: $SIGN_IDENTITY if set, else the first "Developer ID Application" in the keychain,
# else the first "Apple Development", else ad-hoc. SIGN_IDENTITY=- forces ad-hoc.
# The first signed build shows a keychain prompt asking to let codesign use the key: choose Always Allow.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/LabelPrint"

APP="build/Label Print.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LabelPrint"
cp scripts/Info.plist "$APP/Contents/Info.plist"

pick() { security find-identity -v -p codesigning | grep -v REVOKED | grep "$1" | head -1 | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}).*/\1/'; }
ID="${SIGN_IDENTITY:-$(pick 'Developer ID Application')}"
[ -n "$ID" ] || ID="$(pick 'Apple Development')"
if [ -n "$ID" ] && [ "$ID" != "-" ]; then
  codesign --force --options runtime --timestamp --entitlements scripts/LabelPrint.entitlements --sign "$ID" "$APP"
  echo "signed with keychain identity"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc"
fi
codesign --verify --strict "$APP"
ln -sf "Label Print.app/Contents/MacOS/LabelPrint" build/labelprint
echo "built $APP and build/labelprint"
