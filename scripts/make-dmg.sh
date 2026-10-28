#!/bin/bash
# Packages build/app.noindex/Loupe.app into build/Loupe-<version>.dmg (LZMA-compressed, with an
# Applications shortcut for drag-to-install). Run scripts/build-app.sh release first.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/app.noindex/Loupe.app"
[[ -d "$APP" ]] || { echo "missing $APP — run scripts/build-app.sh release"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Loupe-$VER.dmg"
STAGE="$(mktemp -d)/Loupe"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
cp README.md "$STAGE/使用说明.md" 2>/dev/null || true
rm -f "$DMG"
hdiutil create -volname "Loupe $VER" -srcfolder "$STAGE" -fs HFS+ -format ULMO -ov "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
