#!/usr/bin/env bash
# Builds "Under the Rug.app" into ./build with the Command Line Tools only (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=.build/release/UnderTheRug
APP="build/Under the Rug.app"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UnderTheRug"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The app draws its own icon with the same code that weaves the rugs.
"$BIN" --export-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
