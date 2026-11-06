#!/bin/bash
# Builds Perlustra.app. Usage: scripts/build-app.sh [debug|release]
#   debug   – native arch, fast, for local testing
#   release – Universal (arm64 + x86_64), optimised, stripped, ad-hoc signed
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh
CONFIG="${1:-debug}"
# A ".noindex" folder keeps Spotlight (and so Launchpad / Apps) from listing this
# build next to the installed /Applications/Perlustra.app.
APP="build/app.noindex/Perlustra.app"

if [[ "$CONFIG" == "release" ]]; then
  # Newer SwiftPM writes every triple to the same folder, so copy each slice out before
  # building the next one.
  mkdir -p build/slices.noindex
  for arch in arm64 x86_64; do
    flags=(-c release --triple "${arch}-apple-macosx14.0" -Xswiftc -Osize)
    swift build "${flags[@]}"
    cp "$(swift build "${flags[@]}" --show-bin-path)/Perlustra" "build/slices.noindex/Perlustra-$arch"
  done
  BIN_ARM="build/slices.noindex/Perlustra-arm64"
  BIN_X86="build/slices.noindex/Perlustra-x86_64"
else
  swift build
  BIN_NATIVE="$(swift build --show-bin-path)/Perlustra"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$CONFIG" == "release" ]]; then
  lipo -create "$BIN_ARM" "$BIN_X86" -output "$APP/Contents/MacOS/Perlustra"
  strip -rSTx "$APP/Contents/MacOS/Perlustra" 2>/dev/null || strip -x "$APP/Contents/MacOS/Perlustra"
else
  cp "$BIN_NATIVE" "$APP/Contents/MacOS/Perlustra"
fi
cp Sources/PerlustraApp/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
rsync -a --delete --exclude '.DS_Store' Sources/PerlustraApp/Resources/web/ "$APP/Contents/Resources/web/"
rsync -a --delete --exclude '.DS_Store' Sources/PerlustraApp/Resources/skills/ "$APP/Contents/Resources/skills/"
# The app redistributes the vendored web libraries: ship the licence texts with it.
cp LICENSE NOTICE "$APP/Contents/Resources/"

codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
echo "built $APP ($(du -sh "$APP" | cut -f1))"
