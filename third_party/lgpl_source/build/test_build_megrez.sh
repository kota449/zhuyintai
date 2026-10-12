#!/usr/bin/env bash
# build_megrez.sh 的測試：重建出來的 Megrez 二進位 install_name 對、且定義 Megrez 符號。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
bash "$HERE/build/build_megrez.sh" "$TMP" >"$TMP/log" 2>&1 || { echo "FAIL build_megrez.sh"; tail -20 "$TMP/log"; exit 1; }
[[ -f "$TMP/Megrez" ]] || { echo "FAIL 沒有產出 Megrez"; exit 1; }
otool -D "$TMP/Megrez" | tail -1 | grep -qx '@rpath/Megrez.framework/Versions/A/Megrez' && echo "PASS install_name" || { echo "FAIL install_name"; fail=1; }
N=$(nm -U "$TMP/Megrez" | grep -c '_\$s6Megrez'); [[ "$N" -gt 1000 ]] && echo "PASS 定義 Megrez 符號 ($N)" || { echo "FAIL 符號數 $N"; fail=1; }
exit $fail
