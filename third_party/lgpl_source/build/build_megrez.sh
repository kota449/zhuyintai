#!/usr/bin/env bash
# 從本包的 Megrez 原始碼重建 Megrez 框架的二進位（可替換 TWKeyboard.app 內的版本）。
# Rebuild the Megrez framework binary from the sources in this package.
#
# 用法 / usage:   bash build/build_megrez.sh [輸出目錄 / output dir，預設 ./out]
# 產出 / output:  <輸出目錄>/Megrez   （install_name = @rpath/Megrez.framework/Versions/A/Megrez）
#
# 必須與出貨版相同 / must match the shipped build:
#   - Swift 編譯器大版本：出貨版用 Swift 6.4（Xcode 內建，swift-driver 1.168.6）。Swift 沒有穩定的
#     ABI 介面，換大版本編出來的 Megrez 可能與主程式的記憶體配置不符而無法使用。
#     The shipped build used Swift 6.4. Swift has no stable module interface here, so a
#     different major compiler version may produce a library the app cannot use.
#   - 旗標：-swift-version 5 -O -wmo -Xfrontend -disable-cmo，目標 arm64-apple-macosx14.0
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HERE/out}"
mkdir -p "$OUT"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -emit-library -module-name Megrez -swift-version 5 -O -wmo -Xfrontend -disable-cmo \
  -target arm64-apple-macosx14.0 -sdk "$SDK" \
  -Xlinker -install_name -Xlinker @rpath/Megrez.framework/Versions/A/Megrez \
  "$HERE"/megrez/*.swift \
  -o "$OUT/Megrez"
echo "built $OUT/Megrez  ($(xcrun swiftc --version 2>&1 | head -1))"
