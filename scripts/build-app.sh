#!/bin/bash
# Builds Loupe.app. Usage: scripts/build-app.sh [debug|release]
#   debug   – native arch, fast, for local testing
#   release – Universal (arm64 + x86_64), optimised, stripped, ad-hoc signed
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
# A ".noindex" folder keeps Spotlight (and so Launchpad / Apps) from listing this
# build next to the installed /Applications/Loupe.app.
APP="build/app.noindex/Loupe.app"

if [[ "$CONFIG" == "release" ]]; then
  for arch in arm64 x86_64; do
    swift build -c release --triple "${arch}-apple-macosx14.0" -Xswiftc -Osize
  done
  BIN_ARM=".build/arm64-apple-macosx/release/Loupe"
  BIN_X86=".build/x86_64-apple-macosx/release/Loupe"
else
  swift build
  BIN_NATIVE="$(swift build --show-bin-path)/Loupe"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$CONFIG" == "release" ]]; then
  lipo -create "$BIN_ARM" "$BIN_X86" -output "$APP/Contents/MacOS/Loupe"
  strip -rSTx "$APP/Contents/MacOS/Loupe" 2>/dev/null || strip -x "$APP/Contents/MacOS/Loupe"
else
  cp "$BIN_NATIVE" "$APP/Contents/MacOS/Loupe"
fi
cp Sources/Loupe/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
rsync -a --delete --exclude '.DS_Store' Sources/Loupe/Resources/web/ "$APP/Contents/Resources/web/"
rsync -a --delete --exclude '.DS_Store' Sources/Loupe/Resources/skills/ "$APP/Contents/Resources/skills/"
# The app redistributes the vendored web libraries: ship the licence texts with it.
cp LICENSE NOTICE "$APP/Contents/Resources/"

codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
echo "built $APP ($(du -sh "$APP" | cut -f1))"
