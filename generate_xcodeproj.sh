#!/bin/bash
# 產生 ZhuyinTai.xcodeproj。需要 XcodeGen 2.45.4。
# 專案檔名故意不用 TWKeyboard.xcodeproj：在不分大小寫的磁碟上會蓋掉 twkeyboard.xcodeproj。
# 本腳本不會安裝或升級任何工具。
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

SPEC_DIR=$(cd "$(dirname "$0")" && pwd)
SPEC="$SPEC_DIR/project.yml"
if [[ ! -f "$SPEC" ]]; then
  echo "error: 找不到 project.yml" >&2
  exit 2
fi

# 腳本也可能放在 tools/oss/overlay/ 底下，這時來源在上三層。
# overlay 自己也可能有 MacIMESpike/（公開樹要蓋掉的顯示名稱），不能拿它當來源根。
if [[ -d "$SPEC_DIR/../../../MacIMESpike" ]]; then
  ROOT=$(cd "$SPEC_DIR/../../.." && pwd)
elif [[ -d "$SPEC_DIR/MacIMESpike" ]]; then
  ROOT="$SPEC_DIR"
else
  echo "error: 找不到 MacIMESpike。請在公開樹根目錄執行。" >&2
  exit 2
fi

# 公開樹的 Info.plist 與 entitlements 從官方那兩份產生：同一個 id 前綴換成 TWKeyboardOSS。
# 兩個檔必須成對：Info.plist 的 InputMethodConnectionName 與 entitlements 的
# mach-register.global-name 要是同一個字串，否則簽章後的沙盒 app 註冊不了連線名、打不出字。
# ⇒ 一次 python 呼叫：先驗證兩個來源都在、都含要換的 id，才寫兩個目標（不會只寫一半）。
# 只寫 overlay，不寫官方檔。公開樹裡來源與產物是同一路徑，不再套一次（避免 OSSOSS）。
if [[ "$ROOT" != "$SPEC_DIR" ]]; then
  # 第三個衍生檔：授權清單。官方版有一行內部說明，
  # 公開樹換成中性的一行；所有授權全文與聲明逐字不動（法律義務不能被順手刪掉）。
  mkdir -p "$SPEC_DIR/MacIMESpike/Resources"
  official_files=("$ROOT/MacIMESpike/Info.plist" "$ROOT/MacIMESpike/MacIMESpike.entitlements" "$ROOT/MacIMESpike/Resources/ThirdPartyNotices.txt")
  official_hash_before=$(cat "${official_files[@]}" 2>/dev/null | shasum -a 256 | awk '{ print $1 }')
  python3 - "$ROOT/MacIMESpike" "$SPEC_DIR/MacIMESpike" <<'PY' || exit 2
import pathlib, sys
src_dir, dst_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
old = b"com.kota.xrich.inputmethod.TWKeyboard"
new = old + b"OSS"
names = ("Info.plist", "MacIMESpike.entitlements")
out = {}
for name in names:
    src = src_dir / name
    if not src.is_file():
        sys.stderr.write(f"error: 找不到官方 {name}\n")
        sys.exit(2)
    data = src.read_bytes()
    if old not in data:
        sys.stderr.write(f"error: 官方 {name} 沒有要替換的 id\n")
        sys.exit(2)
    out[name] = data.replace(old, new)

notices_rel = "Resources/ThirdPartyNotices.txt"
notices_src = src_dir / notices_rel
if not notices_src.is_file():
    sys.stderr.write(f"error: 找不到官方 {notices_rel}\n")
    sys.exit(2)
lines = notices_src.read_text(encoding="utf-8").split("\n")
idx = [i for i, ln in enumerate(lines) if ln.startswith("說明：出貨詞庫")]
if len(idx) != 1:
    sys.stderr.write(f"error: 授權清單裡要換掉的內部說明行應有 1 行，實際 {len(idx)} 行（官方檔改過？）\n")
    sys.exit(2)
lines[idx[0]] = ("說明：公開版使用上游小麥注音的詞庫資料（Vendor/McBopomofo/Source/Data，pin 73d0379）。"
                 "詞頻來源是同一份快照的 phrase.occ。")
out[notices_rel] = "\n".join(lines).encode("utf-8")

for name, data in out.items():
    dst = dst_dir / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)
    print(f"wrote {dst}")
PY
  official_hash_after=$(cat "${official_files[@]}" | shasum -a 256 | awk '{ print $1 }')
  if [[ "$official_hash_before" != "$official_hash_after" ]]; then
    echo "error: 產生公開版 Info.plist／entitlements 時動到了官方檔，已中止。" >&2
    exit 2
  fi
fi

# 來源路徑以 --project-root 為準。產物必須寫在來源根，相對路徑才會是 MacIMESpike。
# 寫完後若既有的 twkeyboard.xcodeproj 被換掉（不分大小寫撞名），立刻失敗。
inode_before=""
if [[ -d "$ROOT/twkeyboard.xcodeproj" ]]; then
  inode_before=$(stat -f %i "$ROOT/twkeyboard.xcodeproj")
fi
xcodegen --no-env --spec "$SPEC" --project "$ROOT" --project-root "$ROOT"
if [[ -n "$inode_before" ]]; then
  inode_after=$(stat -f %i "$ROOT/twkeyboard.xcodeproj")
  if [[ "$inode_before" != "$inode_after" ]]; then
    echo "error: 產生專案時動到了 twkeyboard.xcodeproj，已中止。" >&2
    exit 2
  fi
fi
if [[ "$ROOT" != "$SPEC_DIR" ]]; then
  rm -rf "$SPEC_DIR/ZhuyinTai.xcodeproj" "$SPEC_DIR/TWKeyboard.xcodeproj"
  mv "$ROOT/ZhuyinTai.xcodeproj" "$SPEC_DIR/ZhuyinTai.xcodeproj"
fi
echo "wrote $SPEC_DIR/ZhuyinTai.xcodeproj"
