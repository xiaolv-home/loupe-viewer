#!/bin/bash
# Measures main-thread hitches during everyday actions in an optimised build. The automation only
# exists with DEBUG set, so this builds release code with that flag, kept apart from real builds.
# Only fixtures are opened.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh
swift build -c release -Xswiftc -DDEBUG --scratch-path build/perf-build 2>&1 | tail -1
scripts/build-app.sh debug >/dev/null 2>&1
rm -rf build/perf.noindex && mkdir -p build/perf.noindex
cp -R build/app.noindex/Loupe.app build/perf.noindex/Loupe.app
cp build/perf-build/release/Loupe build/perf.noindex/Loupe.app/Contents/MacOS/Loupe
codesign --force --deep --sign - --timestamp=none build/perf.noindex/Loupe.app >/dev/null
out="$(mktemp -d)"
build/perf.noindex/Loupe.app/Contents/MacOS/Loupe --snapshot "$out" --size 1200x800 --delay 0.5 --cmd "perf:$PWD/fixtures" 2>/dev/null | grep "^PERF" | sed 's/^PERF //'
rm -rf "$out"
