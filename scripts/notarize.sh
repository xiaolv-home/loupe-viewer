#!/bin/bash
# Optional notarization hook. Ad-hoc builds (the default) cannot be notarized.
# Without the owner's Apple ID, team id, app password, and a Developer ID
# certificate this script succeeds without doing anything, so CI stays green.
set -euo pipefail

if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "notarize: 未设置 APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD，跳过公证"
  exit 0
fi

if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "Developer ID Application"; then
  echo "notarize: 钥匙串里没有 Developer ID Application 证书，跳过公证（ad-hoc 包不能提交公证）"
  exit 0
fi

echo "notarize: 已检测到 Developer ID 与公证凭据，但构建脚本仍使用 ad-hoc 签名，没有接上正式签名，跳过公证"
exit 0
