#!/bin/bash
set -euo pipefail
# 部署脚本
for f in "$@"; do
  echo "处理 ${f}"
done
