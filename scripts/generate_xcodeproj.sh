#!/bin/bash
# 產生 ZhuyinTai.xcodeproj（寫在樹根目錄）。需要 XcodeGen 2.45.4。
# 專案檔名故意不用 TWKeyboard.xcodeproj：在不分大小寫的磁碟上會蓋掉 twkeyboard.xcodeproj。
# 本腳本不會安裝或升級任何工具。從哪個目錄呼叫都可以（路徑以本檔所在位置為準）。
set -euo pipefail

NEED="2.45.4"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: 找不到 xcodegen。需要 XcodeGen ${NEED}。本腳本不會安裝它。" >&2
  exit 2
fi
got=$(xcodegen --version 2>/dev/null | awk 'NR==1 { print $2 }')
if [[ "$got" != "$NEED" ]]; then
  echo "error: xcodegen 版本是 ${got:-unknown}，需要 ${NEED}。本腳本不會安裝或升級。" >&2
  exit 2
fi

# 本檔與 project.yml 都在 scripts/，樹根目錄是上一層。
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SPEC="$SCRIPT_DIR/project.yml"
if [[ ! -f "$SPEC" ]]; then
  echo "error: 找不到 $SPEC" >&2
  exit 2
fi
if [[ ! -d "$ROOT/ZhuyinTai" ]]; then
  echo "error: 在 $ROOT 找不到 ZhuyinTai/（本腳本要放在公開樹的 scripts/ 底下）" >&2
  exit 2
fi

# project.yml 裡的路徑都相對於樹根目錄，所以 --project-root 指到根目錄；
# 產物（ZhuyinTai.xcodeproj）也寫在根目錄。
xcodegen --no-env --spec "$SPEC" --project "$ROOT" --project-root "$ROOT"
echo "wrote $ROOT/ZhuyinTai.xcodeproj"
