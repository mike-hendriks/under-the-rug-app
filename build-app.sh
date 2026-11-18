#!/usr/bin/env bash
# Builds "Under the Rug.app" into ./build with the Command Line Tools only (no Xcode needed).
#
#   ./build-app.sh                       # this Mac's architecture
#   UNIVERSAL=1 VERSION=1.2.0 ./build-app.sh   # Apple silicon + Intel, with a version number (needs Xcode)
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/UnderTheRug
else
  swift build -c release
  BIN=.build/release/UnderTheRug
fi
APP="build/Under the Rug.app"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UnderTheRug"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
  # Only versioned builds update themselves from GitHub Releases; local development builds never do.
  /usr/libexec/PlistBuddy -c "Add :UTRReleaseBuild bool true" "$APP/Contents/Info.plist"
fi

# The app draws its own icon with the same code that weaves the rugs.
"$BIN" --export-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
