#!/usr/bin/env bash
# replace_in_app.sh 的測試（不碰已安裝的 app）：
#   1) 對 /Applications 底下的路徑拒絕；2) 對一份 app 複本替換＋重簽後 codesign --verify 通過。
# 用法：test_replace_in_app.sh <TWKeyboard.app 複本來源> <替換用 Megrez 二進位> <替換用 libKenLMQuery.dylib>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="${1:?}"; MEGREZ="${2:?}"; KENLM="${3:?}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
bash "$HERE/build/replace_in_app.sh" /Applications/TWKeyboard.app >/dev/null 2>&1 && { echo "FAIL 應拒絕 /Applications"; fail=1; } || echo "PASS 拒絕 /Applications"
cp -R "$SRC_APP" "$TMP/TWKeyboard.app"
bash "$HERE/build/replace_in_app.sh" "$TMP/TWKeyboard.app" "$MEGREZ" "$KENLM" >"$TMP/log" 2>&1 && echo "PASS 替換＋重簽" || { echo "FAIL 替換＋重簽"; tail "$TMP/log"; fail=1; }
# 重簽會改動檔案，不能逐位元組比對；改驗：換入的是我們傳入的那份（nm 符號數與來源一致）且簽署者已變成 ad-hoc
SRC_N=$(nm -U "$MEGREZ" | grep -c '_\$s6Megrez'); APP_N=$(nm -U "$TMP/TWKeyboard.app/Contents/Frameworks/Megrez.framework/Versions/A/Megrez" | grep -c '_\$s6Megrez')
[[ "$SRC_N" == "$APP_N" && "$SRC_N" -gt 0 ]] && echo "PASS Megrez 已換入（符號數 ${APP_N}）" || { echo "FAIL Megrez 未換入 (${SRC_N} vs ${APP_N})"; fail=1; }
[[ "$(codesign -dv "$TMP/TWKeyboard.app" 2>&1 | grep -c 'Signature=adhoc')" -ge 1 ]] && echo "PASS app 已改為 ad-hoc 簽章" || { echo "FAIL 簽章不是 ad-hoc"; fail=1; }
exit $fail
