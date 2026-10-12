#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""把「開放集合」單獨型別檢查一次，列出未解析的符號——S2 的唯一可靠完成判準。

為什麼要這個：`deny_symbols` 是子字串逐字比對，放不進 `ZhuyinEngine` 這類會誤中
`MacZhuyinEnginePort` 的名字；而 Swift 在同一個 module 裡靠可見性解析，token 比對有漏。
最誠實的驗證是：只把 allowlist－denylist 展開的檔案放進一棵乾淨的樹，叫 swiftc 型別檢查，
任何還依賴被排除檔的外殼檔就會在這裡報「cannot find ... in scope」。

用法：
    python3 -I tools/oss/typecheck_open_tree.py [--src ROOT] [--work DIR] [--allow-missing NAME ...]

- 清單讀 `<src>/tools/oss/{allowlist,denylist}.txt`；展開語意與 `check_lists.py` 相同。
- `--allow-missing NAME`：容許「cannot find 'NAME'」（例：S3' 之前公開版引擎還沒寫的 `BasicEngine`）。
- 退出碼 0＝沒有非容許的錯誤。印出 `total=… tolerated=… unexpected=…` 與每個非容許錯誤。
- 不修改 `--src`；工作目錄預設是系統暫存目錄下的新資料夾，結束保留供檢查。
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ERROR_RE = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+): error: (?P<msg>.*)$")
MISSING_RE = re.compile(r"cannot find (?:type )?'(?P<name>[^']+)' in scope")
SUBPROJECT_IMPORT = "import UpdateCheck"
BRIDGING_HEADER_GLOB = "Shared/*-Bridging-Header.h"
BRIDGING_HEADER_FALLBACK = "Shared/OpenTree-Bridging-Header.h"


def read_list(path: Path):
    return [ln.strip() for ln in path.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


def expand(src: Path, patterns):
    out = set()
    for pat in patterns:
        for m in glob.glob(pat, recursive=True, root_dir=str(src), include_hidden=True):
            full = src / m
            if full.is_dir():
                for dp, _, fs in os.walk(full):
                    for f in fs:
                        out.add(os.path.relpath(os.path.join(dp, f), src))
            else:
                out.add(m)
    return out


def export_set(src: Path):
    lists = src / "tools" / "oss"
    allow = expand(src, read_list(lists / "allowlist.txt"))
    deny_file = lists / "denylist.txt"
    deny = expand(src, read_list(deny_file)) if deny_file.exists() else set()
    return sorted(f for f in allow - deny if (src / f).is_file() and not (src / f).is_symlink())


def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kw)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--work", default=None)
    ap.add_argument("--allow-missing", action="append", default=[])
    ns = ap.parse_args(argv)

    src = Path(ns.src).resolve()
    work = Path(ns.work).resolve() if ns.work else Path(tempfile.mkdtemp(prefix="oss-typecheck-"))
    if work.exists():
        shutil.rmtree(work)
    tree = work / "tree"
    tree.mkdir(parents=True)

    files = export_set(src)
    for rel in files:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src / rel, dst)

    swift_files = sorted(f for f in files if f.endswith(".swift") and not f.startswith(
        ("Vendor/", "third_party/", "tools/", "Packages/")))
    # 子套件（Packages/UpdateCheck）要當成獨立 module 先編，外殼才 `import UpdateCheck`。
    pkg_sources = sorted(f for f in files if f.startswith("Packages/UpdateCheck/Sources/") and f.endswith(".swift"))
    extra = []
    if pkg_sources:
        modules = work / "modules"
        modules.mkdir()
        r = run(["xcrun", "swiftc", "-emit-module", "-module-name", "UpdateCheck", "-swift-version", "5",
                 "-target", "arm64-apple-macosx14.0", "-parse-as-library",
                 "-o", str(modules / "UpdateCheck.swiftmodule"), *[str(tree / f) for f in pkg_sources]])
        if r.returncode != 0:
            print("UpdateCheck module build failed:\n" + r.stdout)
            return 2
        extra += ["-I", str(modules)]
    else:
        swift_files = [f for f in swift_files if SUBPROJECT_IMPORT not in (tree / f).read_text(encoding="utf-8")]

    found = sorted(tree.glob(BRIDGING_HEADER_GLOB))
    header = found[0] if found else tree / BRIDGING_HEADER_FALLBACK
    uses_objc = (tree / "Shared/KenLMQueryBridge.h").exists()
    if uses_objc and not found:
        # 公開樹的 bridging header 由 S4 overlay 提供；這裡補一份，只為型別檢查。
        header.parent.mkdir(parents=True, exist_ok=True)
        header.write_text('#import "KenLMQueryBridge.h"\n', encoding="utf-8")
    objc_args = ["-import-objc-header", str(header)] if header.exists() else []
    vendor = src / "Vendor" / "KenLMQuerySource"
    include = ["-I", str(vendor)] if vendor.exists() else []

    if not swift_files:
        print("total=0 tolerated=0 unexpected=0  (沒有 swift 檔)")
        return 0

    cmd = ["xcrun", "swiftc", "-typecheck", "-wmo", "-continue-building-after-errors",
           "-swift-version", "5", "-target", "arm64-apple-macosx14.0", "-D", "MEGREZ_DYNAMIC",
           *objc_args, *include, *extra, "-framework", "AppKit", "-framework", "InputMethodKit",
           *swift_files]
    r = run(cmd, cwd=str(tree))
    (work / "typecheck.log").write_text(r.stdout, encoding="utf-8")

    seen = []
    for line in r.stdout.splitlines():
        m = ERROR_RE.match(line)
        if m:
            seen.append((m.group("file"), int(m.group("line")), m.group("msg")))
    # 同一處錯誤 swiftc 會在 -wmo 下重複輸出，去重。
    uniq = sorted(set(seen))
    allowed = set(ns.allow_missing)
    tolerated, unexpected = [], []
    for f, ln, msg in uniq:
        mm = MISSING_RE.search(msg)
        (tolerated if mm and mm.group("name") in allowed else unexpected).append((f, ln, msg))

    print(f"total={len(uniq)} tolerated={len(tolerated)} unexpected={len(unexpected)}  work={work}")
    for f, ln, msg in unexpected:
        print(f"  {f}:{ln}: {msg}")
    if r.returncode != 0 and not uniq:
        print("swiftc 失敗但沒有可解析的錯誤：\n" + r.stdout[-2000:])
        return 2
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
