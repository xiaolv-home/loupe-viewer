#!/bin/bash
# Runs the Swift Testing unit tests. Command Line Tools ship Testing.framework outside the
# default search path, so point the compiler and the runtime at it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
F="$DEV/Library/Developer/Frameworks"
L="$DEV/Library/Developer/usr/lib"
if [[ -d "$DEV/Platforms" ]]; then exec swift test "$@"; fi   # full Xcode: nothing special needed
swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
