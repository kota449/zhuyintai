#!/usr/bin/env bash
# build_kenlm.sh 的測試：重建出來的 dylib install_name 對、定義 KenLM 符號與 bridge 類別。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
bash "$HERE/build/build_kenlm.sh" "$TMP" >"$TMP/log" 2>&1 || { echo "FAIL build_kenlm.sh"; tail -20 "$TMP/log"; exit 1; }
D="$TMP/libKenLMQuery.dylib"
[[ -f "$D" ]] || { echo "FAIL 沒有產出 dylib"; exit 1; }
otool -D "$D" | tail -1 | grep -qx '@rpath/libKenLMQuery.dylib' && echo "PASS install_name" || { echo "FAIL install_name"; fail=1; }
N=$(nm -U "$D" | grep -c '__ZN2lm'); [[ "$N" -gt 100 ]] && echo "PASS 定義 lm:: 符號 ($N)" || { echo "FAIL lm:: 符號數 $N"; fail=1; }
[[ "$(nm -U "$D" | grep -c '_OBJC_CLASS_\$_KenLMQueryBridge')" -ge 1 ]] && echo "PASS 匯出 KenLMQueryBridge 類別" || { echo "FAIL 沒有 KenLMQueryBridge"; fail=1; }
exit $fail
