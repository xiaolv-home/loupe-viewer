#!/bin/bash
# Everything a change should pass before it is pushed. With --visual, also compares screenshots
# with the baseline from `scripts/visual-check.py baseline` (take that before changing anything).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 格式"
scripts/lint.sh
echo "== 架构"
python3 scripts/check-architecture.py
echo "== 单元测试"
scripts/test.sh 2>&1 | grep -E "error:|✘|Test run with"
echo "== 构建"
scripts/build-app.sh debug
if [[ "${1:-}" == "--visual" ]]; then
  echo "== 截图对比"
  python3 scripts/visual-check.py
fi
echo "== 渲染器端到端"
python3 scripts/verify-renderers.py | tail -1
