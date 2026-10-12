#!/usr/bin/env bash
# 把重建的程式庫換進「你自己的複本」TWKeyboard.app，並重簽整個 app。
# Replace the rebuilt libraries inside YOUR OWN COPY of TWKeyboard.app and re-sign the whole app.
#
# 用法 / usage:
#   bash build/replace_in_app.sh <TWKeyboard.app 的複本> [Megrez 二進位] [libKenLMQuery.dylib]
#   例 / e.g.  bash build/replace_in_app.sh ~/Desktop/TWKeyboard.app out/Megrez out/libKenLMQuery.dylib
#
# 為什麼要重簽 / why re-sign: 出貨的 app 以 Developer ID 簽章並開 hardened runtime（含 library
#   validation），不同簽署者的程式庫會被拒絕載入。重簽整個 app 之後，app 與你的程式庫同一簽署者即可載入。
#   The shipped app is Developer-ID signed with hardened runtime (library validation on), which
#   refuses libraries signed by anyone else. Re-signing the whole app makes app and libraries share a signer.
#   重簽後這份 app 不再是原作者簽章版本。 / After re-signing it is no longer the author's signed build.
# 簽署身分 / identity：預設 ad-hoc（"-"）；可用環境變數 SIGN_IDENTITY 指定你自己的身分。
# 本腳本不安裝、不碰 /Applications 或 ~/Library/Input Methods。
set -euo pipefail
APP="${1:?用法: replace_in_app.sh <TWKeyboard.app 複本> [Megrez] [libKenLMQuery.dylib]}"
MEGREZ_BIN="${2:-}"
KENLM_DYLIB="${3:-}"
IDENT="${SIGN_IDENTITY:--}"
case "$APP" in /Applications/*|"$HOME/Library/Input Methods"/*) echo "拒絕：請對複本操作，不要直接改已安裝的 app" >&2; exit 1;; esac
FW="$APP/Contents/Frameworks"
[[ -d "$FW" ]] || { echo "找不到 $FW" >&2; exit 1; }
if [[ -n "$MEGREZ_BIN" ]]; then cp "$MEGREZ_BIN" "$FW/Megrez.framework/Versions/A/Megrez"; fi
if [[ -n "$KENLM_DYLIB" ]]; then cp "$KENLM_DYLIB" "$FW/libKenLMQuery.dylib"; fi
# 由內而外重簽：先程式庫，再整個 app。--preserve-metadata=entitlements 保留 app 的 sandbox 等 entitlements
# （不帶的話 --force 會把它們丟掉，輸入法就不在沙箱內、也註冊不了它的 mach 服務名）。
# RUNTIME=1：重簽時加 --options runtime（hardened runtime）。預設不加（見 README 的實測說明）。
OPTS=(--force --sign "$IDENT" --preserve-metadata=entitlements)
if [[ "${RUNTIME:-0}" == "1" ]]; then OPTS+=(--options runtime); fi
codesign "${OPTS[@]}" "$FW/libKenLMQuery.dylib"
codesign "${OPTS[@]}" "$FW/Megrez.framework"
codesign "${OPTS[@]}" --deep "$APP"
codesign --verify --deep --strict "$APP" && echo "re-signed OK: $APP"
