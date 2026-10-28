#!/bin/bash
# Dev helper: scripts/snap.sh OUTDIR [harness args…] files…
set -e
cd "$(dirname "$0")/.."
OUT="$1"; shift
./build/app.noindex/Loupe.app/Contents/MacOS/Loupe --snapshot "$OUT" --size 1100x720 "$@" 2>&1 | grep -v "^snapshot" || true
