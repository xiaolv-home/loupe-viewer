#!/bin/bash
# Formatting and lint rules from .swift-format. With --fix, rewrites the files instead.
set -euo pipefail
cd "$(dirname "$0")/.."
paths=(Sources/Perlustra Sources/PerlustraApp Sources/PerlustraCore Tests Package.swift)
if [[ "${1:-}" == "--fix" ]]; then
  xcrun swift-format format --in-place --recursive --parallel "${paths[@]}"
else
  xcrun swift-format lint --strict --recursive --parallel "${paths[@]}"
fi
