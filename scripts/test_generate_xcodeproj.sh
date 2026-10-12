#!/bin/bash
# 產生腳本必須把 XcodeGen 版號寫死，而且不准在腳本裡安裝套件。
# 從哪個目錄呼叫都可以：路徑以本檔所在位置（scripts/）為準。
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GEN="$HERE/generate_xcodeproj.sh"
SPEC="$HERE/project.yml"
if [[ ! -f "$GEN" ]]; then
  echo "missing $GEN" >&2
  exit 1
fi
if [[ ! -f "$SPEC" ]]; then
  echo "missing $SPEC" >&2
  exit 1
fi
grep -q '2.45.4' "$GEN"
if grep -q 'brew install' "$GEN"; then
  echo "script must not install packages" >&2
  exit 1
fi
# project.yml 的路徑相對於樹根目錄（scripts/ 的上一層）：App 原始碼資料夾要在那裡。
if [[ ! -d "$HERE/../ZhuyinTai" ]]; then
  echo "missing ../ZhuyinTai (project.yml paths are relative to the tree root)" >&2
  exit 1
fi
echo "ok"
